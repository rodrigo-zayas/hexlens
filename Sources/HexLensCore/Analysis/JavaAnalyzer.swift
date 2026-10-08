import Foundation

/// Extractor ligero de Java: paquete, imports, tipos, supertipos, anotaciones y miembros.
/// No resuelve tipos; trabaja sobre el texto sin comentarios ni literales.
public struct JavaAnalyzer: LanguageAnalyzer {
  public init() {}

  public let language = "java"

  public func handles(_ path: String) -> Bool { path.hasSuffix(".java") }

  public func qualifiedName(forPath path: String) -> String? {
    guard path.hasSuffix(".java"), let range = path.range(of: "/java/", options: .backwards) else { return nil }
    return String(path[range.upperBound...].dropLast(5)).replacingOccurrences(of: "/", with: ".")
  }

  public func analyze(path: String, source: String) -> SourceFacts {
    let clean = Self.blankOut(source)
    let ns = clean as NSString
    var facts = SourceFacts()

    if let m = Rx.package.firstMatch(in: clean, range: ns.fullRange) {
      facts.packageName = ns.substring(with: m.range(at: 1))
    }

    var headerEnd = 0
    for m in Rx.imports.matches(in: clean, range: ns.fullRange) {
      let name = ns.substring(with: m.range(at: 2))
      facts.imports.append(ImportDecl(
        name: name,
        isStatic: m.range(at: 1).location != NSNotFound,
        isWildcard: name.hasSuffix(".*"),
        line: ns.substring(with: m.range).trimmed))
      headerEnd = max(headerEnd, NSMaxRange(m.range))
    }

    let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    var primaryRange: NSRange?
    for m in Rx.typeDecl.matches(in: clean, range: ns.fullRange) {
      let keyword = ns.substring(with: m.range(at: 1))
      let decl = TypeDecl(name: ns.substring(with: m.range(at: 2)), kind: Self.kind(keyword))
      facts.types.append(decl)
      if facts.primary == nil || (decl.name == stem && facts.primary?.name != stem) {
        facts.primary = decl
        primaryRange = m.range
      }
    }

    if let r = primaryRange {
      facts.primaryLine = ns.substring(to: r.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
      // Anotaciones entre los imports y la declaración del tipo principal.
      let lead = ns.substring(with: NSRange(location: headerEnd, length: max(0, r.location - headerEnd)))
      facts.annotations = Rx.annotation.matches(in: lead, range: (lead as NSString).fullRange)
        .map { (lead as NSString).substring(with: $0.range(at: 1)) }
        .map { $0.components(separatedBy: ".").last ?? $0 }
        .filter { $0 != "interface" }

      let rest = ns.substring(from: NSMaxRange(r))
      let header = String(rest.prefix { $0 != "{" })
      facts.supertypes = Self.supertypes(in: header)
    }

    let body = ns.substring(from: headerEnd)
    facts.identifiers = Set(Rx.capitalized.matches(in: body, range: (body as NSString).fullRange)
      .map { (body as NSString).substring(with: $0.range) })
    facts.members = Self.members(in: clean)
    return facts
  }

  // MARK: - Detalles

  static func kind(_ keyword: String) -> TypeKind {
    switch keyword {
    case "class": .class
    case "interface": .interface
    case "enum": .enum
    case "record": .record
    default: keyword.hasPrefix("@") ? .annotation : .unknown
    }
  }

  static func supertypes(in header: String) -> [String] {
    var h = header
    h = h.replacingAll(Rx.generics, with: "")
    h = h.replacingAll(Rx.parens, with: "")
    var result: [String] = []
    for re in [Rx.extendsClause, Rx.implementsClause] {
      let ns = h as NSString
      guard let m = re.firstMatch(in: h, range: ns.fullRange) else { continue }
      result += ns.substring(with: m.range(at: 1))
        .split(separator: ",")
        .map { $0.trimmed.components(separatedBy: ".").last ?? "" }
        .filter { !$0.isEmpty }
    }
    return result
  }

  /// Miembros de los tipos de primer nivel: cualquier `{` que abre a profundidad 2.
  static func members(in clean: String) -> [Member] {
    let chars = Array(clean.utf16)
    var lineStarts = [0]
    for (i, c) in chars.enumerated() where c == 10 { lineStarts.append(i + 1) }
    func line(_ offset: Int) -> Int {
      var lo = 0, hi = lineStarts.count - 1
      while lo < hi {
        let mid = (lo + hi + 1) / 2
        if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
      }
      return lo + 1
    }

    var result: [Member] = []
    var depth = 0
    var boundary = 0
    var open: (start: Int, header: String)?
    let ns = clean as NSString

    for (i, c) in chars.enumerated() {
      switch c {
      case 123:  // {
        if depth == 1 {
          let header = ns.substring(with: NSRange(location: boundary, length: i - boundary))
          let tail = header.trimmed.last
          // `@Ann({…})` o inicializadores de array no son miembros.
          if tail != "(" && tail != "," && tail != "=" { open = (boundary, header) }
        }
        depth += 1
        boundary = i + 1
      case 125:  // }
        depth -= 1
        if depth == 1, let o = open {
          if let m = member(header: o.header, start: line(o.start), end: line(i)) { result.append(m) }
          open = nil
        }
        boundary = i + 1
      case 59:  // ;
        if depth == 1 && open == nil {
          // Campo o método abstracto: también cuenta como miembro de una línea.
          let header = ns.substring(with: NSRange(location: boundary, length: i - boundary))
          if header.contains("("), let m = member(header: header, start: line(boundary), end: line(i)) {
            result.append(m)
          }
        }
        boundary = i + 1
      default: break
      }
    }
    return result
  }

  static func member(header raw: String, start: Int, end: Int) -> Member? {
    let header = raw.replacingAll(Rx.annotationWithArgs, with: " ")
    let squashed = header.replacingAll(Rx.whitespace, with: " ").trimmed
    guard !squashed.isEmpty else { return nil }
    let ns = squashed as NSString
    // El header empieza tras el `;`/`}` anterior: recolocar la primera línea real.
    let firstLine = start + raw.prefix { $0 == "\n" || $0 == " " || $0 == "\t" }.filter { $0 == "\n" }.count

    if let m = Rx.typeDecl.firstMatch(in: squashed, range: ns.fullRange) {
      let name = ns.substring(with: m.range(at: 2))
      return Member(name: name, key: "type:\(name)", signature: squashed, startLine: firstLine, endLine: end)
    }
    if squashed == "static" {
      return Member(name: "static {}", key: "static", signature: "static {}", startLine: firstLine, endLine: end)
    }
    if let eq = squashed.firstIndex(of: "="), !squashed[..<eq].contains("(") {
      let name = squashed[..<eq].trimmed.components(separatedBy: " ").last ?? "campo"
      return Member(name: name, key: "field:\(name)", signature: squashed, startLine: firstLine, endLine: end)
    }
    for m in Rx.call.matches(in: squashed, range: ns.fullRange) {
      let name = ns.substring(with: m.range(at: 1))
      if Rx.keywords.contains(name) { continue }
      let afterParen = ns.substring(from: NSMaxRange(m.range))
      let arity = Self.arity(afterParen)
      let signature = squashed.count > 140 ? String(squashed.prefix(140)) + "…" : squashed
      return Member(name: name, key: "\(name)/\(arity)", signature: signature, startLine: firstLine, endLine: end)
    }
    let name = squashed.components(separatedBy: " ").last ?? squashed
    return Member(name: name, key: "block:\(name)", signature: squashed, startLine: firstLine, endLine: end)
  }

  static func arity(_ afterOpenParen: String) -> Int {
    var depth = 0, commas = 0, any = false
    for c in afterOpenParen {
      switch c {
      case "(", "<": depth += 1
      case ">": depth -= 1
      case ")":
        if depth == 0 { return any ? commas + 1 : 0 }
        depth -= 1
      case ",": if depth == 0 { commas += 1 }
      case " ": break
      default: any = true
      }
    }
    return any ? commas + 1 : 0
  }

  /// Sustituye comentarios y contenido de literales por espacios, conservando saltos de línea.
  static func blankOut(_ source: String) -> String {
    var b = Array(source.utf8)
    let n = b.count
    var i = 0
    func blank(_ from: Int, _ to: Int) {
      var k = from
      while k < min(to, n) {
        if b[k] != 10 { b[k] = 32 }
        k += 1
      }
    }
    while i < n {
      let c = b[i]
      if c == 47, i + 1 < n, b[i + 1] == 47 {  // //
        let s = i
        while i < n && b[i] != 10 { i += 1 }
        blank(s, i)
      } else if c == 47, i + 1 < n, b[i + 1] == 42 {  // /* */
        let s = i
        i += 2
        while i + 1 < n && !(b[i] == 42 && b[i + 1] == 47) { i += 1 }
        i = min(i + 2, n)
        blank(s, i)
      } else if c == 34, i + 2 < n, b[i + 1] == 34, b[i + 2] == 34 {  // """
        i += 3
        let s = i
        while i + 2 < n && !(b[i] == 34 && b[i + 1] == 34 && b[i + 2] == 34) { i += 1 }
        blank(s, i)
        i = min(i + 3, n)
      } else if c == 34 || c == 39 {  // "…" '…'
        let quote = c
        i += 1
        let s = i
        while i < n && b[i] != quote && b[i] != 10 {
          if b[i] == 92 { i += 1 }
          i += 1
        }
        blank(s, i)
        i += 1
      } else {
        i += 1
      }
    }
    return String(decoding: b, as: UTF8.self)
  }
}

enum Rx {
  static let package = re(#"\bpackage\s+([\w.]+)\s*;"#)
  static let imports = re(#"(?m)^\s*import\s+(static\s+)?([\w.]+(?:\.\*)?)\s*;"#)
  static let typeDecl = re(#"(?<![\w.])(class|interface|enum|record|@\s*interface)\s+([A-Za-z_]\w*)"#)
  static let annotation = re(#"@([A-Za-z_][\w.]*)"#)
  static let annotationWithArgs = re(#"@[\w.]+\s*(\((?:[^()]|\([^()]*\))*\))?"#)
  static let capitalized = re(#"\b[A-Z][A-Za-z0-9_]*\b"#)
  static let generics = re(#"<[^<>]*>"#)
  static let parens = re(#"\([^()]*\)"#)
  static let extendsClause = re(#"\bextends\s+([\w.,\s]+?)(?=\bimplements\b|\bpermits\b|$)"#)
  static let implementsClause = re(#"\bimplements\s+([\w.,\s]+?)(?=\bpermits\b|$)"#)
  static let call = re(#"([A-Za-z_]\w*)\s*\("#)
  static let whitespace = re(#"\s+"#)
  static let keywords: Set<String> = ["if", "for", "while", "switch", "catch", "synchronized", "new", "return", "try", "throw"]

  static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
}

extension NSString {
  var fullRange: NSRange { NSRange(location: 0, length: length) }
}

extension String {
  /// Aplica la regex hasta que deja de cambiar (para estructuras anidadas como genéricos).
  func replacingAll(_ re: NSRegularExpression, with template: String) -> String {
    var current = self
    while true {
      let next = re.stringByReplacingMatches(
        in: current, range: (current as NSString).fullRange, withTemplate: template)
      if next == current { return next }
      current = next
    }
  }
}
