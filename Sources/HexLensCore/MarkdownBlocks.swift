import Foundation

/// Elemento de lista, con sus sublistas anidadas por sangría.
public struct MarkdownListItem: Equatable, Sendable {
  public var number: Int?  // nil = viñeta
  public var checked: Bool?  // nil = no es tarea
  public var text: String
  public var children: [MarkdownListItem]
}

public enum MarkdownBlock: Equatable, Sendable {
  case heading(level: Int, text: String)
  case paragraph(String)
  case list([MarkdownListItem])
  case quote([MarkdownBlock])
  case code(language: String?, text: String)
  case table(header: [String], rows: [[String]])
  case rule
}

/// Parser de bloques de Markdown (subconjunto habitual de GFM). El inline se resuelve en la vista.
public enum MarkdownBlocks {
  public static func parse(_ source: String) -> [MarkdownBlock] {
    parse(lines: source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
  }

  /// Como `parse`, con el rango de líneas (base 0, sobre el texto original) que ocupa cada bloque.
  public static func parseWithLines(_ source: String) -> [(block: MarkdownBlock, lines: Range<Int>)] {
    parseRanged(lines: source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
  }

  private static func parse(lines: [String]) -> [MarkdownBlock] { parseRanged(lines: lines).map(\.block) }

  private static func parseRanged(lines: [String]) -> [(block: MarkdownBlock, lines: Range<Int>)] {
    var blocks: [MarkdownBlock] = []
    var ranges: [Range<Int>] = []
    var i = 0
    while i < lines.count {
      let start = i
      let before = blocks.count
      defer { if blocks.count > before { ranges.append(start..<i) } }
      let line = lines[i]
      let t = line.trimmingCharacters(in: .whitespaces)
      if t.isEmpty { i += 1; continue }

      if let fence = fenceOpening(t) {
        let lang = String(t.drop(while: { $0 == fence.char })).trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        i += 1
        while i < lines.count {
          let tt = lines[i].trimmingCharacters(in: .whitespaces)
          if tt.hasPrefix(String(repeating: fence.char, count: fence.count)) && tt.allSatisfy({ $0 == fence.char }) { i += 1; break }
          body.append(lines[i])
          i += 1
        }
        blocks.append(.code(language: lang.isEmpty ? nil : lang.split(separator: " ").first.map(String.init), text: body.joined(separator: "\n")))
      } else if let h = heading(t) {
        blocks.append(h)
        i += 1
      } else if isRule(t) {
        blocks.append(.rule)
        i += 1
      } else if t.hasPrefix(">") {
        var inner: [String] = []
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
          var s = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
          if s.hasPrefix(" ") { s = s.dropFirst() }
          inner.append(String(s))
          i += 1
        }
        blocks.append(.quote(parse(lines: inner)))
      } else if t.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
        let header = cells(t)
        var rows: [[String]] = []
        i += 2
        while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
          rows.append(cells(lines[i]))
          i += 1
        }
        blocks.append(.table(header: header, rows: rows))
      } else if listMarker(line) != nil {
        var raw: [String] = []
        let firstOrdered = listMarker(line)?.number != nil
        while i < lines.count {
          let l = lines[i]
          if let m = listMarker(l), m.indent == 0, (m.number != nil) != firstOrdered, !raw.isEmpty { break }
          if l.trimmingCharacters(in: .whitespaces).isEmpty {
            // una línea en blanco sigue la lista solo si continúa con otro elemento o con sangría
            if i + 1 < lines.count, let m = listMarker(lines[i + 1]) ?? (lines[i + 1].hasPrefix("  ") ? Marker(indent: 1, number: firstOrdered ? 1 : nil, rest: "") : nil),
            m.indent > 0 || (m.number != nil) == firstOrdered
          { i += 1; continue }
            break
          }
          if listMarker(l) == nil, !l.hasPrefix(" "), !l.hasPrefix("\t") { break }
          raw.append(l)
          i += 1
        }
        blocks.append(.list(buildList(raw)))
      } else {
        var para: [String] = []
        while i < lines.count {
          let l = lines[i]
          let lt = l.trimmingCharacters(in: .whitespaces)
          if lt.isEmpty || fenceOpening(lt) != nil || heading(lt) != nil || isRule(lt) || lt.hasPrefix(">") || listMarker(l) != nil { break }
          if !para.isEmpty, lt.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) { break }
          para.append(lt)
          i += 1
        }
        if para.isEmpty { i += 1 } else { blocks.append(.paragraph(para.joined(separator: " "))) }
      }
    }
    return Array(zip(blocks, ranges)).map { (block: $0, lines: $1) }
  }

  // MARK: - Piezas

  private static func fenceOpening(_ t: String) -> (char: Character, count: Int)? {
    guard let c = t.first, c == "`" || c == "~" else { return nil }
    let n = t.prefix(while: { $0 == c }).count
    guard n >= 3 else { return nil }
    if c == "`", t.dropFirst(n).contains("`") { return nil }
    return (c, n)
  }

  private static func heading(_ t: String) -> MarkdownBlock? {
    let n = t.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(n) else { return nil }
    let rest = t.dropFirst(n)
    guard rest.isEmpty || rest.first == " " else { return nil }
    var text = rest.trimmingCharacters(in: .whitespaces)
    if let r = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(r) }
    else if text.allSatisfy({ $0 == "#" }) { text = "" }
    return .heading(level: n, text: text)
  }

  private static func isRule(_ t: String) -> Bool {
    let s = t.filter { $0 != " " }
    guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
    return s.allSatisfy { $0 == c }
  }

  private static func isTableSeparator(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.contains("-"), t.contains("|") || t.hasPrefix(":") else { return false }
    return t.allSatisfy { "|-: ".contains($0) }
  }

  private static func cells(_ line: String) -> [String] {
    var t = line.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("|") { t.removeFirst() }
    if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
    var out: [String] = []
    var cur = ""
    var escaped = false
    for ch in t {
      if escaped { cur.append(ch); escaped = false; continue }
      if ch == "\\" { escaped = true; continue }
      if ch == "|" { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
      cur.append(ch)
    }
    out.append(cur.trimmingCharacters(in: .whitespaces))
    return out
  }

  private struct Marker { var indent: Int; var number: Int?; var rest: String }

  private static func listMarker(_ line: String) -> Marker? {
    var indent = 0
    var idx = line.startIndex
    while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
      indent += line[idx] == "\t" ? 4 : 1
      idx = line.index(after: idx)
    }
    let s = line[idx...]
    guard let f = s.first else { return nil }
    if "-*+".contains(f), s.dropFirst().first == " " {
      if isRule(String(s)) { return nil }
      return Marker(indent: indent, number: nil, rest: String(s.dropFirst(2)))
    }
    let digits = s.prefix(while: \.isNumber)
    if !digits.isEmpty, digits.count <= 9 {
      let after = s.dropFirst(digits.count)
      if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " {
        return Marker(indent: indent, number: Int(digits), rest: String(after.dropFirst(2)))
      }
    }
    return nil
  }

  private static func buildList(_ raw: [String]) -> [MarkdownListItem] {
    var flat: [(indent: Int, item: MarkdownListItem)] = []
    for line in raw {
      if let m = listMarker(line) {
        var text = m.rest
        var checked: Bool?
        for (p, v) in [("[ ]", false), ("[x]", true), ("[X]", true)] where text == p || text.hasPrefix(p + " ") {
          checked = v
          text = String(text.dropFirst(3))
        }
        flat.append((m.indent, MarkdownListItem(number: m.number, checked: checked, text: text.trimmingCharacters(in: .whitespaces), children: [])))
      } else if !flat.isEmpty {
        let extra = line.trimmingCharacters(in: .whitespaces)
        flat[flat.count - 1].item.text += flat[flat.count - 1].item.text.isEmpty ? extra : " " + extra
      }
    }
    var i = 0
    func build(base: Int) -> [MarkdownListItem] {
      var out: [MarkdownListItem] = []
      while i < flat.count, flat[i].indent >= base {
        var item = flat[i].item
        let indent = flat[i].indent
        i += 1
        if i < flat.count, flat[i].indent > indent { item.children = build(base: indent + 1) }
        out.append(item)
      }
      return out
    }
    return build(base: 0)
  }
}

/// Qué líneas de un Markdown cambian, sacado del diff existente (sin algoritmo propio).
public struct MarkdownDiff: Equatable, Sendable {
  public struct Removal: Equatable, Sendable {
    /// Líneas de la cabeza (base 0) que preceden a la eliminación: se muestra antes del primer bloque que empieza en o tras este valor.
    public var anchor: Int
    /// Primera línea eliminada en la base (base 1), para abrir el código en ella.
    public var oldLine: Int
    public var lines: [String]
  }

  public var isNewFile: Bool
  /// Líneas añadidas de la cabeza (base 1).
  public var added: Set<Int>
  public var removals: [Removal]

  public init(diff: FileDiff, isNewFile: Bool) {
    self.isNewFile = isNewFile
    var added = Set<Int>()
    var removals: [Removal] = []
    var headSeen = 0
    var run: Removal?
    for l in diff.lines {
      if l.kind == .removed {
        if run == nil { run = Removal(anchor: headSeen, oldLine: l.oldNumber ?? 0, lines: []) }
        run?.lines.append(l.text)
        continue
      }
      if let r = run { removals.append(r); run = nil }
      switch l.kind {
      case .added: added.insert(l.newNumber ?? 0); headSeen = l.newNumber ?? headSeen
      case .context: headSeen = l.newNumber ?? headSeen
      default: break
      }
    }
    if let r = run { removals.append(r) }
    self.added = added
    self.removals = removals
  }
}
