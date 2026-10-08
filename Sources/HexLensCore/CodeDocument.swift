import Foundation

public struct CodeLine: Sendable, Hashable {
  public enum Kind: Sendable, Hashable { case context, added, removed, separator, filler }
  public let kind: Kind
  public let text: String
  public let oldNumber: Int?
  public let newNumber: Int?
}

/// Texto que enseña el visor: el fichero entero con las líneas quitadas intercaladas
/// (como el diff unificado de IntelliJ) o solo los hunks.
public struct CodeDocument: Sendable {
  public let lines: [CodeLine]
  public let text: String
  /// Offset UTF-16 donde empieza cada línea.
  public let lineStarts: [Int]

  public init(lines: [CodeLine]) {
    self.lines = lines
    text = lines.map(\.text).joined(separator: "\n")
    var starts: [Int] = []
    var offset = 0
    for l in lines {
      starts.append(offset)
      offset += (l.text as NSString).length + 1
    }
    lineStarts = starts
  }

  public func lineIndex(at offset: Int) -> Int {
    var lo = 0, hi = lineStarts.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
    }
    return max(0, lo)
  }

  public func index(ofNewLine n: Int) -> Int? { lines.firstIndex { $0.newNumber == n } }
  public var changeIndices: [Int] {
    lines.indices.filter { i in lines[i].kind != .context && lines[i].kind != .separator && lines[i].kind != .filler
        && (i == 0 || lines[i - 1].kind == .context || lines[i - 1].kind == .separator) }
  }

  public static func build(head: String?, base: String?, diff: FileDiff?, full: Bool) -> CodeDocument {
    func split(_ s: String) -> [String] {
      var parts = s.components(separatedBy: "\n")
      if parts.last == "" { parts.removeLast() }
      return parts
    }

    guard let diff, !diff.lines.isEmpty else {
      if let head { return CodeDocument(lines: split(head).enumerated().map { CodeLine(kind: .context, text: $1, oldNumber: $0 + 1, newNumber: $0 + 1) }) }
      if let base { return CodeDocument(lines: split(base).enumerated().map { CodeLine(kind: .removed, text: $1, oldNumber: $0 + 1, newNumber: nil) }) }
      return CodeDocument(lines: [])
    }

    if !full || head == nil {
      var out: [CodeLine] = []
      for l in diff.lines {
        switch l.kind {
        case .hunk: out.append(CodeLine(kind: .separator, text: l.text, oldNumber: nil, newNumber: nil))
        case .added: out.append(CodeLine(kind: .added, text: l.text, oldNumber: nil, newNumber: l.newNumber))
        case .removed: out.append(CodeLine(kind: .removed, text: l.text, oldNumber: l.oldNumber, newNumber: nil))
        case .context: out.append(CodeLine(kind: .context, text: l.text, oldNumber: l.oldNumber, newNumber: l.newNumber))
        }
      }
      return CodeDocument(lines: out)
    }

    let headLines = split(head!)
    var out: [CodeLine] = []
    var next = 1  // siguiente línea de la cabeza por emitir
    var delta = 0  // old - new en la zona sin cambios
    func fill(upTo n: Int) {
      while next < n && next <= headLines.count {
        out.append(CodeLine(kind: .context, text: headLines[next - 1], oldNumber: next + delta, newNumber: next))
        next += 1
      }
    }
    for l in diff.lines {
      switch l.kind {
      case .hunk:
        continue
      case .removed:
        out.append(CodeLine(kind: .removed, text: l.text, oldNumber: l.oldNumber, newNumber: nil))
      case .added, .context:
        guard let n = l.newNumber else { continue }
        fill(upTo: n)
        out.append(CodeLine(kind: l.kind == .added ? .added : .context, text: l.text, oldNumber: l.oldNumber, newNumber: n))
        if let o = l.oldNumber { delta = o - n }
        next = n + 1
      }
    }
    fill(upTo: headLines.count + 1)
    return CodeDocument(lines: out)
  }
}

/// Destino de un clic en el código.
public enum CodeLink: Hashable, Sendable {
  case type(path: String)
  case member(path: String, name: String)
}

public enum CodeLinker {
  /// Enlaces navegables de un documento: tipos del repo y llamadas cuyo receptor se conoce.
  public static func links(
    text: String, tokens: [Token], semantics: JavaSemantics, facts: SourceFacts, ownPath: String, index: RepoIndex
  ) -> [(NSRange, CodeLink)] {
    var out: [(NSRange, CodeLink)] = []
    var typeCache: [String: String?] = [:]
    func resolve(_ name: String) -> String? {
      if let c = typeCache[name] { return c }
      let p = index.resolve(name, from: facts)
      typeCache[name] = .some(p)
      return p
    }
    let own = Set(facts.members.map(\.name))

    for ref in semantics.typeRefs {
      if let p = resolve(ref.name), p != ownPath { out.append((ref.range, .type(path: p))) }
    }
    for call in semantics.calls {
      if let r = call.receiver {
        let type = semantics.varTypes[r] ?? (r.first?.isUppercase == true ? r : nil)
        if let t = type, let p = resolve(t) { out.append((call.nameRange, .member(path: p, name: call.name))) }
      } else if own.contains(call.name) {
        out.append((call.nameRange, .member(path: ownPath, name: call.name)))
      }
    }
    return out
  }
}
