import Foundation

/// Elemento de la estructura de un fichero: tipo, método o campo con su rango de líneas (1-based).
public struct OutlineEntry: Hashable, Sendable {
  public enum Kind: Sendable { case type, method, field }
  public let name: String
  public let kind: Kind
  public let line: Int
  public let endLine: Int
}

public enum Outline {
  /// Estructura de un fichero Java: tipo principal, miembros de primer nivel y campos, ordenados por línea.
  public static func java(_ source: String) -> [OutlineEntry] {
    let facts = JavaAnalyzer().analyze(path: "", source: source)
    let total = source.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    var out: [OutlineEntry] = []
    if let primary = facts.primary, let line = facts.primaryLine {
      out.append(OutlineEntry(name: primary.name, kind: .type, line: line, endLine: total))
    }
    var fieldNames = Set<String>()
    for m in facts.members {
      if m.key.hasPrefix("type:") {
        out.append(OutlineEntry(name: m.name, kind: .type, line: m.startLine, endLine: m.endLine))
      } else if m.key.hasPrefix("field:") {
        fieldNames.insert(m.name)
        out.append(OutlineEntry(name: m.name, kind: .field, line: m.startLine, endLine: m.endLine))
      } else if !m.key.hasPrefix("block:"), m.key != "static" {
        out.append(OutlineEntry(name: m.name, kind: .method, line: m.startLine, endLine: m.endLine))
      }
    }
    for f in fields(source) where !fieldNames.contains(f.name) { out.append(f) }
    return out.sorted { ($0.line, $0.endLine) < ($1.line, $1.endLine) }
  }

  /// Campos (`private final Foo foo;`, `int n = 3;`) a profundidad 1 del tipo.
  private static func fields(_ source: String) -> [OutlineEntry] {
    let clean = JavaAnalyzer.blankOut(source)
    let chars = Array(clean.utf16)
    var depth = 0, line = 1, boundary = 0, boundaryLine = 1
    var result: [OutlineEntry] = []
    for (i, c) in chars.enumerated() {
      switch c {
      case 10: line += 1
      case 123: depth += 1; boundary = i + 1; boundaryLine = line
      case 125: depth -= 1; boundary = i + 1; boundaryLine = line
      case 59:
        if depth == 1 {
          let header = String(decoding: chars[boundary..<i], as: UTF16.self)
          let squashed = header.replacingAll(Rx.annotationWithArgs, with: " ").replacingAll(Rx.whitespace, with: " ").trimmed
          let declaration = squashed.split(separator: "=", maxSplits: 1).first.map { String($0).trimmed } ?? ""
          let words = declaration.split(separator: " ")
          if !declaration.contains("("), words.count >= 2, let name = words.last,
            name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" })
          {
            let lead = header.prefix { $0 == "\n" || $0 == " " || $0 == "\t" }.filter { $0 == "\n" }.count
            result.append(OutlineEntry(name: String(name), kind: .field, line: boundaryLine + lead, endLine: line))
          }
        }
        boundary = i + 1
        boundaryLine = line
      default: break
      }
    }
    return result
  }

  /// Camino de migas (tipo › miembro) de una línea: de fuera a dentro.
  public static func trail(_ entries: [OutlineEntry], line: Int) -> [OutlineEntry] {
    let containing = entries.filter { $0.line <= line && line <= $0.endLine }
    let types = containing.filter { $0.kind == .type }
    let member = containing.last { $0.kind != .type }
    return types + (member.map { [$0] } ?? [])
  }
}
