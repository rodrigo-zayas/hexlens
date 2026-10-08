import Foundation

/// Lexer de Ruby para el coloreado del visor. Reutiliza `Token.Kind`: los símbolos (`:foo`, `foo:`)
/// salen como `.annotation` y las variables de instancia/clase/globales como `.identifier`
/// (su nombre va en `fields` de `semantics(...)` para pintarlas como campos).
public enum RubyLexer {
  public static let keywords: Set<String> = [
    "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif",
    "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry",
    "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield",
    "__FILE__", "__LINE__", "__method__",
    // Métodos de Kernel/Module que se leen como palabras clave.
    "require", "require_relative", "include", "extend", "prepend", "attr_reader", "attr_writer", "attr_accessor",
    "private", "protected", "public", "raise", "lambda", "proc", "loop",
  ]

  public static func isRuby(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    return path.hasSuffix(".rb") || path.hasSuffix(".rake") || path.hasSuffix(".jbuilder") || path.hasSuffix(".gemspec")
      || path.hasSuffix(".ru") || ["Gemfile", "Rakefile", "Guardfile", "Capfile"].contains(name)
  }

  public static func tokens(_ text: String) -> [Token] {
    let c = Array(text.utf16)
    let n = c.count
    var out: [Token] = []
    var i = 0
    var heredocs: [(id: [UInt16], squiggly: Bool)] = []
    var lineStart = true

    func isIdentStart(_ u: UInt16) -> Bool { (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u > 127 }
    func isIdent(_ u: UInt16) -> Bool { isIdentStart(u) || (u >= 48 && u <= 57) }
    func add(_ k: Token.Kind, _ s: Int) { if i > s { out.append(Token(kind: k, range: NSRange(location: s, length: i - s))) } }
    func startsWith(_ word: String, at p: Int) -> Bool {
      let w = Array(word.utf16)
      return p + w.count <= n && Array(c[p..<(p + w.count)]) == w
    }
    func closing(_ u: UInt16) -> UInt16 {
      switch u { case 40: 41; case 91: 93; case 123: 125; case 60: 62; default: u }
    }
    /// Salta un literal delimitado (con anidamiento si el delimitador es de apertura).
    func skipDelimited(open: UInt16) {
      let close = closing(open)
      var depth = 1
      while i < n {
        let u = c[i]
        if u == 92 { i += 2; continue }
        if open != close && u == open { depth += 1 } else if u == close { depth -= 1; if depth == 0 { i += 1; return } }
        i += 1
      }
    }
    var prevSignificant: Token? { out.last(where: { $0.kind != .comment }) }
    /// `/` empieza una regex si no viene detrás de un valor (identificador, número, cierre).
    func regexAllowed() -> Bool {
      guard let p = prevSignificant else { return true }
      switch p.kind {
      case .identifier, .number, .string, .annotation: return false
      case .keyword: return !["end", "self", "true", "false", "nil"].contains(word(p.range))
      case .punct: let u = c[p.range.location]; return !(u == 41 || u == 93 || u == 125)
      case .comment: return true
      }
    }
    func word(_ r: NSRange) -> String { String(utf16CodeUnits: Array(c[r.location..<NSMaxRange(r)]), count: r.length) }

    while i < n {
      let u = c[i]
      let s = i
      if u == 10 {
        i += 1
        lineStart = true
        // Cuerpo de los heredocs pendientes: hasta la línea con el terminador.
        while let h = heredocs.first {
          heredocs.removeFirst()
          let bodyStart = i
          while i < n {
            var e = i
            while e < n && c[e] != 10 { e += 1 }
            var a = i
            if h.squiggly { while a < e && (c[a] == 32 || c[a] == 9) { a += 1 } }
            var b = e
            while b > a && (c[b - 1] == 32 || c[b - 1] == 9 || c[b - 1] == 13) { b -= 1 }
            i = min(e + 1, n)
            if Array(c[a..<b]) == h.id { break }
          }
          add(.string, bodyStart)
        }
        continue
      }
      defer { lineStart = false }
      if u == 32 || u == 9 || u == 13 {
        i += 1
        lineStart = lineStart && true
        continue
      }
      if lineStart, startsWith("=begin", at: i) {
        while i < n {
          var e = i
          while e < n && c[e] != 10 { e += 1 }
          let isEnd = startsWith("=end", at: i)
          i = min(e + (isEnd ? 0 : 1), n)
          if isEnd { break }
        }
        add(.comment, s)
      } else if u == 35 {
        while i < n && c[i] != 10 { i += 1 }
        add(.comment, s)
      } else if u == 34 || u == 39 || u == 96 {
        i += 1
        skipDelimited(open: u)
        add(.string, s)
      } else if u == 60, i + 2 < n, c[i + 1] == 60,
        c[i + 2] == 126 || c[i + 2] == 45 || (c[i + 2] >= 65 && c[i + 2] <= 90),
        prevSignificant.map({ $0.kind != .identifier || word($0.range).first?.isLowercase == true }) ?? true
      {
        // Heredoc: <<~SQL, <<-EOS, <<EOS, también con comillas.
        var p = i + 2
        let squiggly = c[p] == 126 || c[p] == 45
        if squiggly { p += 1 }
        let quote = p < n && (c[p] == 39 || c[p] == 34) ? c[p] : nil
        if quote != nil { p += 1 }
        let idStart = p
        while p < n && isIdent(c[p]) { p += 1 }
        if p > idStart {
          heredocs.append((Array(c[idStart..<p]), squiggly))
          i = p + (quote != nil && p < n && c[p] == quote! ? 1 : 0)
          add(.string, s)
        } else {
          i += 2
          add(.punct, s)
        }
      } else if u == 37, i + 1 < n, [119, 87, 105, 73, 113, 81, 114].contains(c[i + 1]), i + 2 < n,
        !isIdent(c[i + 2]), c[i + 2] != 32
      {
        // %w[...] %i[...] %q(...) %Q{...} %r{...}
        let kind: Token.Kind = (c[i + 1] == 105 || c[i + 1] == 73) ? .annotation : .string
        let open = c[i + 2]
        i += 3
        skipDelimited(open: open)
        add(kind, s)
      } else if u == 47, regexAllowed() {
        i += 1
        skipDelimited(open: 47)
        while i < n && isIdent(c[i]) { i += 1 }
        add(.string, s)
      } else if u >= 48 && u <= 57 {
        while i < n && (isIdent(c[i]) || (c[i] == 46 && i + 1 < n && c[i + 1] >= 48 && c[i + 1] <= 57)) { i += 1 }
        add(.number, s)
      } else if u == 58, i + 1 < n, c[i + 1] != 58, prevSignificant.map({ !($0.kind == .punct && c[$0.range.location] == 58) }) ?? true,
        isIdentStart(c[i + 1]) || c[i + 1] == 34 || c[i + 1] == 64
      {
        // Símbolo :foo, :"foo", :@ivar
        i += 1
        if c[i] == 34 {
          i += 1
          skipDelimited(open: 34)
        } else {
          while i < n && (isIdent(c[i]) || c[i] == 64) { i += 1 }
          if i < n && (c[i] == 63 || c[i] == 33 || c[i] == 61) && !(i + 1 < n && c[i + 1] == 61) { i += 1 }
        }
        add(.annotation, s)
      } else if u == 64 || u == 36 {
        // @ivar, @@cvar, $global
        i += 1
        if i < n && c[i] == 64 { i += 1 }
        while i < n && isIdent(c[i]) { i += 1 }
        add(.identifier, s)
      } else if isIdentStart(u) {
        while i < n && isIdent(c[i]) { i += 1 }
        if i < n && (c[i] == 63 || c[i] == 33) && !(i + 1 < n && c[i + 1] == 61) { i += 1 }
        // Etiqueta de hash `clave: valor` (pero no `A::B` ni el ternario `a ? b : c`).
        if i + 1 < n, c[i] == 58, c[i + 1] != 58, i == s || !(c[i - 1] == 63 || c[i - 1] == 33) {
          i += 1
          add(.annotation, s)
          continue
        }
        let w = String(utf16CodeUnits: Array(c[s..<i]), count: i - s)
        // Tras un punto es una llamada a método aunque se llame como una palabra clave (`x.class`).
        let afterDot = prevSignificant.map { $0.kind == .punct && c[$0.range.location] == 46 } ?? false
        add(!afterDot && keywords.contains(w) ? .keyword : .identifier, s)
      } else {
        i += 1
        add(.punct, s)
      }
    }
    return out
  }

  /// Semántica para coloreado y navegación: declaraciones (`def`), variables `@x`/`@@x`/`$x` como campos,
  /// constantes (`A::B::C` → `A.B.C`) como `typeRefs` y llamadas (`X.metodo`, `metodo` propio) como `calls`.
  public static func semantics(text: String, tokens: [Token]) -> JavaSemantics {
    let ns = text as NSString
    var sem = JavaSemantics()
    let sig = tokens.filter { $0.kind != .comment }
    func str(_ i: Int) -> String { i >= 0 && i < sig.count ? ns.substring(with: sig[i].range) : "" }
    func isConst(_ i: Int) -> Bool {
      i >= 0 && i < sig.count && sig[i].kind == .identifier && str(i).first?.isUppercase == true
    }
    func isColons(_ i: Int) -> Bool {
      i + 1 < sig.count && sig[i].kind == .punct && str(i) == ":" && sig[i + 1].kind == .punct && str(i + 1) == ":"
        && sig[i + 1].range.location == NSMaxRange(sig[i].range)
    }
    var lineStarts = [0]
    for (i, u) in text.utf16.enumerated() where u == 10 { lineStarts.append(i + 1) }
    func line(_ offset: Int) -> Int {
      var lo = 0, hi = lineStarts.count - 1
      while lo < hi {
        let mid = (lo + hi + 1) / 2
        if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
      }
      return lo + 1
    }

    // Pasada 1: declaraciones y campos.
    var afterDef = false
    var declared = Set<Int>()
    var methodNames = Set<String>()
    for k in sig.indices {
      let t = sig[k]
      let w = str(k)
      if t.kind == .identifier, let f = w.first, f == "@" || f == "$" { sem.fields.insert(w) }
      if t.kind == .keyword && w == "def" { afterDef = true; continue }
      guard afterDef else { continue }
      if (t.kind == .keyword && w == "self") || (t.kind == .punct && w == ".") { continue }
      afterDef = false
      if t.kind == .identifier || t.kind == .keyword, k > 0 {
        sem.declarations.append(t.range)
        declared.insert(k)
        methodNames.insert(w)
      }
    }

    // Pasada 2: constantes y llamadas.
    var k = 0
    while k < sig.count {
      let t = sig[k]
      let prev = str(k - 1)
      let prevKind = k > 0 ? sig[k - 1].kind : .punct
      if isConst(k), !(prevKind == .punct && prev == "."), !(prevKind == .keyword && (prev == "class" || prev == "module")) {
        var parts = [str(k)]
        var end = k
        while isColons(end + 1), isConst(end + 3) {
          end += 3
          parts.append(str(end))
        }
        let isDecl = k >= 2 && isColons(k - 2) && k >= 3 && sig[k - 3].kind == .keyword
          && (str(k - 3) == "class" || str(k - 3) == "module")
        if !isDecl {
          let range = NSRange(location: t.range.location, length: NSMaxRange(sig[end].range) - t.range.location)
          sem.typeRefs.append((parts.joined(separator: "."), range))
        }
        k = end + 1
        continue
      }
      if t.kind == .identifier, let f = str(k).first, f != "@", f != "$", !f.isUppercase, !declared.contains(k) {
        let name = str(k)
        if prevKind == .punct, prev == "." {
          // Receptor: constante (cadena `A::B`), identificador o variable; `self` equivale a sin receptor.
          var receiver: String?
          var p = k - 2
          if p >= 0, sig[p].kind == .punct, str(p) == "&" { p -= 1 }
          if p >= 0, sig[p].kind == .keyword, str(p) == "self" {
            if methodNames.contains(name) { sem.calls.append(.init(name: name, nameRange: t.range, receiver: nil, line: line(t.range.location))) }
          } else {
            if p >= 0, sig[p].kind == .identifier {
              var parts = [str(p)]
              if isConst(p) {
                while p >= 3, isColons(p - 2), isConst(p - 3) { p -= 3; parts.insert(str(p), at: 0) }
              }
              receiver = parts.joined(separator: ".")
            }
            if let receiver {
              sem.calls.append(.init(name: name, nameRange: t.range, receiver: receiver, line: line(t.range.location)))
            }
          }
        } else if methodNames.contains(name), !(prevKind == .keyword && prev == "def") {
          sem.calls.append(.init(name: name, nameRange: t.range, receiver: nil, line: line(t.range.location)))
        }
      }
      k += 1
    }
    return sem
  }
}
