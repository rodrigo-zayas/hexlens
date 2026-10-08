import Foundation

/// Extractor ligero de Ruby (Rails/Zeitwerk): namespace, clase o módulo principal, `include`s,
/// `def` con su rango y referencias a constantes. Va por líneas; no es un parser.
public struct RubyAnalyzer: LanguageAnalyzer {
  public init() {}

  public let language = "ruby"

  public func handles(_ path: String) -> Bool {
    path.hasSuffix(".rb") || path.hasSuffix(".rake") || path.hasSuffix(".jbuilder")
  }

  /// Convención Zeitwerk: `app/<dir>/a/b_c.rb` o `lib/a/b_c.rb` → `A.BC`. Los specs no se indexan.
  public func qualifiedName(forPath path: String) -> String? {
    guard path.hasSuffix(".rb"), let rest = Self.autoloadRoot(path) else { return nil }
    var segments = rest.dropLast(3).split(separator: "/").map(String.init)
    if segments.first == "concerns" { segments.removeFirst() }
    guard !segments.isEmpty else { return nil }
    return segments.map(Self.camelize).joined(separator: ".")
  }

  /// Parte de la ruta que cuelga de la raíz de autocarga (`app/<dir>/` o `lib/`).
  static func autoloadRoot(_ path: String) -> String? {
    let comps = path.split(separator: "/").map(String.init)
    for (i, c) in comps.enumerated() {
      if c == "app", i + 2 < comps.count, !["javascript", "views", "assets"].contains(comps[i + 1]) {
        return comps[(i + 2)...].joined(separator: "/")
      }
      if c == "lib", i + 1 < comps.count, i == 0 || comps[i - 1] != "app" {
        return comps[(i + 1)...].joined(separator: "/")
      }
    }
    return nil
  }

  static func camelize(_ segment: String) -> String {
    segment.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
  }

  struct Declaration {
    let name: String
    let kind: String
    let indent: Int
    let line: Int
  }

  public func analyze(path: String, source: String) -> SourceFacts {
    let lines = Self.cleanLines(source)
    var facts = SourceFacts()
    var stack: [(name: String, indent: Int)] = []
    var openDefs: [(indent: Int, name: String, signature: String, arity: Int, line: Int)] = []
    var declarations: [(qualified: [String], decl: Declaration)] = []
    var members: [Member] = []
    var references: [String] = []
    var supertypes: [String] = []
    var superByLine: [Int: String] = [:]
    var annotations: [String] = []
    var seenRefs = Set<String>()

    for (i, raw) in lines.enumerated() {
      let lineNo = i + 1
      let trimmed = raw.trimmed
      if trimmed.isEmpty { continue }
      let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
      var scanText = raw

      if let m = Rx.rbDecl.firstMatch(in: raw, range: (raw as NSString).fullRange) {
        let ns = raw as NSString
        let kind = ns.substring(with: m.range(at: 1))
        let parts = ns.substring(with: m.range(at: 2)).components(separatedBy: "::").filter { !$0.isEmpty }
        let tail = ns.substring(from: NSMaxRange(m.range))
        let enclosing = stack.map(\.name)
        let decl = Declaration(name: parts.last ?? "", kind: kind, indent: indent, line: lineNo)
        declarations.append((enclosing + parts, decl))
        // El nombre declarado no es una referencia; sí lo es lo que sigue (`< Base`).
        scanText = tail
        if kind == "class", let base = Rx.rbSuper.firstMatch(in: tail, range: (tail as NSString).fullRange) {
          let chain = (tail as NSString).substring(with: base.range(at: 1))
          superByLine[lineNo] = chain.components(separatedBy: "::").last ?? chain
        }
        if !Self.endsInline(trimmed) { stack.append((parts.joined(separator: "."), indent)) }
      } else if let m = Rx.rbDef.firstMatch(in: raw, range: (raw as NSString).fullRange) {
        let ns = raw as NSString
        let selfPrefix = m.range(at: 1).location != NSNotFound
        let name = ns.substring(with: m.range(at: 2))
        let rest = ns.substring(from: NSMaxRange(m.range))
        let arity = Self.arity(of: rest)
        let signature = "def \(selfPrefix ? "self." : "")\(name)" + Self.paramList(of: rest)
        let oneLiner = Self.endsInline(trimmed) || rest.trimmed.hasPrefix("=") || rest.contains(") =")
        if oneLiner {
          members.append(Member(name: name, key: "\(name)/\(arity)", signature: signature, startLine: lineNo, endLine: lineNo))
        } else {
          openDefs.append((indent, name, signature, arity, lineNo))
        }
        scanText = rest
      } else if trimmed == "end" || trimmed.hasPrefix("end ") || trimmed.hasPrefix("end.") || trimmed == "end)" {
        if let d = openDefs.last, d.indent == indent {
          openDefs.removeLast()
          members.append(Member(name: d.name, key: "\(d.name)/\(d.arity)", signature: d.signature, startLine: d.line, endLine: lineNo))
        } else if let s = stack.last, s.indent == indent {
          stack.removeLast()
        }
      } else if let m = Rx.rbMixin.firstMatch(in: raw, range: (raw as NSString).fullRange), openDefs.isEmpty {
        let ns = raw as NSString
        let args = ns.substring(from: m.range(at: 1).location)
        for c in Rx.rbConstChain.matches(in: args, range: (args as NSString).fullRange) {
          let chain = (args as NSString).substring(with: c.range(at: 2))
          supertypes.append(chain.components(separatedBy: "::").last ?? chain)
        }
      }

      if openDefs.isEmpty, let m = Rx.rbMacro.firstMatch(in: raw, range: (raw as NSString).fullRange) {
        annotations.append((raw as NSString).substring(with: m.range(at: 1)))
      }

      for c in Rx.rbConstChain.matches(in: scanText, range: (scanText as NSString).fullRange) {
        let ns = scanText as NSString
        let absolute = c.range(at: 1).location != NSNotFound
        let chain = ns.substring(with: c.range(at: 2))
        for part in chain.components(separatedBy: "::") { facts.identifiers.insert(part) }
        let key = (absolute ? "::" : "") + chain
        if seenRefs.insert(key).inserted { references.append(key) }
      }
    }

    let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    let expected = Self.camelize(stem)
    let types = declarations.filter { $0.decl.kind == "class" || $0.decl.kind == "module" }
    let primary = types.first { $0.decl.name == expected }
      ?? types.first { $0.decl.kind == "class" }
      ?? types.last
    if let p = primary {
      facts.packageName = p.qualified.dropLast().joined(separator: ".")
      let decl = TypeDecl(name: p.decl.name, kind: .class)
      facts.primary = decl
      facts.primaryLine = p.decl.line
      facts.types = [decl]
    }
    if let line = primary?.decl.line, let base = superByLine[line] { supertypes.insert(base, at: 0) }
    facts.supertypes = Self.unique(supertypes)
    facts.annotations = Self.unique(annotations)
    facts.members = members.sorted { $0.startLine < $1.startLine }

    // Lookup léxico de Ruby: del namespace más interno al raíz. `resolve` descarta lo que no existe.
    let namespace = facts.packageName.isEmpty ? [] : facts.packageName.components(separatedBy: ".")
    for ref in references {
      let absolute = ref.hasPrefix("::")
      let chain = (absolute ? String(ref.dropFirst(2)) : ref).components(separatedBy: "::").joined(separator: ".")
      let scopes = absolute ? [0] : Array(stride(from: namespace.count, through: 0, by: -1))
      for k in scopes {
        let name = (Array(namespace.prefix(k)) + [chain]).joined(separator: ".")
        facts.imports.append(ImportDecl(
          name: name, isStatic: false, isWildcard: false, line: ref, candidateGroup: "\(path)|\(ref)"))
      }
    }
    return facts
  }

  static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  static func endsInline(_ line: String) -> Bool {
    line.hasSuffix(" end") || line.hasSuffix(";end") || line.hasSuffix("; end")
  }

  static func paramList(of rest: String) -> String {
    let t = rest.trimmed
    if t.hasPrefix("("), let close = t.firstIndex(of: ")") { return String(t[...close]) }
    let bare = t.split(separator: "=", maxSplits: 1).first.map { String($0).trimmed } ?? ""
    return bare.isEmpty ? "" : "(\(bare))"
  }

  static func arity(of rest: String) -> Int {
    let params = paramList(of: rest).dropFirst().dropLast().trimmed
    return params.isEmpty ? 0 : params.split(separator: ",").count
  }

  /// Sin comentarios `#`, `=begin…=end`, heredocs ni literales de texto (se conservan las interpolaciones).
  /// Mantiene el número de líneas.
  static func cleanLines(_ source: String) -> [String] {
    var out: [String] = []
    var heredocs: [String] = []
    var inBlockComment = false
    for raw in source.components(separatedBy: "\n") {
      if inBlockComment {
        if raw.hasPrefix("=end") { inBlockComment = false }
        out.append("")
        continue
      }
      if raw.hasPrefix("=begin") { inBlockComment = true; out.append(""); continue }
      if let terminator = heredocs.first {
        if raw.trimmed == terminator { heredocs.removeFirst() }
        out.append("")
        continue
      }
      let line = stripLiterals(raw)
      for m in Rx.rbHeredoc.matches(in: raw, range: (raw as NSString).fullRange) {
        heredocs.append((raw as NSString).substring(with: m.range(at: 1)))
      }
      out.append(line)
    }
    return out
  }

  static func stripLiterals(_ line: String) -> String {
    let chars = Array(line)
    var result = ""
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c == "#" { break }
      if c == "'" || c == "\"" {
        var j = i + 1
        result.append(c)
        while j < chars.count, chars[j] != c {
          if chars[j] == "\\" { j += 2; result.append(" "); continue }
          if c == "\"", chars[j] == "#", j + 1 < chars.count, chars[j + 1] == "{" {
            var depth = 0
            var k = j + 1
            while k < chars.count {
              if chars[k] == "{" { depth += 1 }
              if chars[k] == "}" { depth -= 1; if depth == 0 { break } }
              k += 1
            }
            result += " " + String(chars[(j + 2)..<min(k, chars.count)]) + " "
            j = k + 1
            continue
          }
          result.append(" ")
          j += 1
        }
        if j < chars.count { result.append(c) }
        i = j + 1
        continue
      }
      result.append(c)
      i += 1
    }
    return result
  }
}

extension Rx {
  static let rbDecl = re(#"^\s*(class|module)\s+((?:::)?[A-Z]\w*(?:::[A-Z]\w*)*)"#)
  static let rbSuper = re(#"^\s*<\s*((?:::)?[A-Z]\w*(?:::[A-Z]\w*)*)"#)
  static let rbDef = re(#"^\s*(?:(?:private|protected|public)\s+)?def\s+(self\.)?([\w]+[?!=]?)"#)
  static let rbMixin = re(#"^\s*(?:include|extend|prepend)\s+(.*)$"#)
  static let rbMacro = re(#"^\s*(queue_as|before_action|after_action|around_action|rescue_from|retry_on|discard_on|has_many|has_one|belongs_to|validates|scope|topic)\b"#)
  static let rbConstChain = re(#"(?<![\w.@$:])(::)?([A-Z]\w*(?:::[A-Z]\w*)*)"#)
  static let rbHeredoc = re(#"<<[~-]?['"]?([A-Z_][A-Z0-9_]*)['"]?"#)
}
