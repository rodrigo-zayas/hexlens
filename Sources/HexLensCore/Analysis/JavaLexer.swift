import Foundation

public struct Token: Sendable, Hashable {
  public enum Kind: Sendable, Hashable { case keyword, identifier, string, number, comment, annotation, punct }
  public let kind: Kind
  /// Rango en UTF-16, listo para NSString/NSAttributedString.
  public let range: NSRange
}

public enum JavaLexer {
  public static let keywords: Set<String> = [
    "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
    "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if",
    "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private",
    "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
    "throw", "throws", "transient", "try", "void", "volatile", "while", "true", "false", "null", "var",
    "record", "sealed", "permits", "yield", "non-sealed",
  ]
  static let primitives: Set<String> = ["void", "boolean", "byte", "char", "short", "int", "long", "float", "double", "var"]

  public static func tokens(_ text: String) -> [Token] {
    let c = Array(text.utf16)
    let n = c.count
    var out: [Token] = []
    var i = 0

    func isIdentStart(_ u: UInt16) -> Bool { (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u == 36 || u > 127 }
    func isIdent(_ u: UInt16) -> Bool { isIdentStart(u) || (u >= 48 && u <= 57) }
    func add(_ k: Token.Kind, _ s: Int) { out.append(Token(kind: k, range: NSRange(location: s, length: i - s))) }

    while i < n {
      let u = c[i]
      let s = i
      if u == 32 || u == 9 || u == 10 || u == 13 {
        i += 1
      } else if u == 47, i + 1 < n, c[i + 1] == 47 {
        while i < n && c[i] != 10 { i += 1 }
        add(.comment, s)
      } else if u == 47, i + 1 < n, c[i + 1] == 42 {
        i += 2
        while i + 1 < n && !(c[i] == 42 && c[i + 1] == 47) { i += 1 }
        i = min(i + 2, n)
        add(.comment, s)
      } else if u == 34, i + 2 < n, c[i + 1] == 34, c[i + 2] == 34 {
        i += 3
        while i + 2 < n && !(c[i] == 34 && c[i + 1] == 34 && c[i + 2] == 34) { i += 1 }
        i = min(i + 3, n)
        add(.string, s)
      } else if u == 34 || u == 39 {
        i += 1
        while i < n && c[i] != u && c[i] != 10 {
          if c[i] == 92 { i += 1 }
          i += 1
        }
        i = min(i + 1, n)
        add(.string, s)
      } else if u >= 48 && u <= 57 {
        while i < n && (isIdent(c[i]) || c[i] == 46) { i += 1 }
        add(.number, s)
      } else if u == 64, i + 1 < n, isIdentStart(c[i + 1]) {
        i += 1
        while i < n && (isIdent(c[i]) || c[i] == 46) { i += 1 }
        add(.annotation, s)
      } else if isIdentStart(u) {
        while i < n && isIdent(c[i]) { i += 1 }
        let word = String(utf16CodeUnits: Array(c[s..<i]), count: i - s)
        add(keywords.contains(word) ? .keyword : .identifier, s)
      } else {
        i += 1
        add(.punct, s)
      }
    }
    return out
  }
}

/// Lo que se puede saber de un fichero mirando sus tokens: campos, tipos de variables,
/// declaraciones de métodos y llamadas `receptor.metodo(`.
public struct JavaSemantics: Sendable {
  public struct Call: Sendable, Hashable {
    public let name: String
    public let nameRange: NSRange
    public let receiver: String?
    public let line: Int
  }

  public var fields: Set<String> = []
  public var varTypes: [String: String] = [:]
  public var declarations: [NSRange] = []
  public var calls: [Call] = []
  /// Identificadores en mayúscula: candidatos a tipo.
  public var typeRefs: [(name: String, range: NSRange)] = []

  public init() {}

  public static func analyze(text: String, tokens: [Token]) -> JavaSemantics {
    let ns = text as NSString
    let sig = tokens.filter { $0.kind != .comment }
    func str(_ i: Int) -> String { i >= 0 && i < sig.count ? ns.substring(with: sig[i].range) : "" }
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

    var s = JavaSemantics()
    var depth = 0
    for i in sig.indices {
      let t = sig[i]
      if t.kind == .punct {
        let p = str(i)
        if p == "{" { depth += 1 } else if p == "}" { depth -= 1 }
        continue
      }
      guard t.kind == .identifier else { continue }
      let name = str(i)
      let next = str(i + 1)
      let prev = str(i - 1)

      if next == "(" {
        if prev == "." {
          let r = str(i - 2)
          let receiver: String? = sig.indices.contains(i - 2) && (sig[i - 2].kind == .identifier || r == "this" || r == "super") ? r : nil
          s.calls.append(Call(name: name, nameRange: t.range, receiver: receiver == "this" ? nil : receiver, line: line(t.range.location)))
        } else if i > 0 && (sig[i - 1].kind == .identifier || prev == ">" || prev == "]" || JavaLexer.primitives.contains(prev)) {
          s.declarations.append(t.range)
        } else if prev != "new" {
          s.calls.append(Call(name: name, nameRange: t.range, receiver: nil, line: line(t.range.location)))
        }
      }

      if let first = name.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
        s.typeRefs.append((name, t.range))
        // Tipo [<…>] [[]] nombre (= ; , ) :)
        var j = i + 1
        if str(j) == "<" {
          var d = 0
          repeat {
            if str(j) == "<" { d += 1 } else if str(j) == ">" { d -= 1 }
            j += 1
          } while d > 0 && j < sig.count
        }
        while str(j) == "[" && str(j + 1) == "]" { j += 2 }
        if j < sig.count, sig[j].kind == .identifier, ["=", ";", ",", ")", ":"].contains(str(j + 1)) {
          let v = str(j)
          s.varTypes[v] = name
          if depth == 1 && ["=", ";"].contains(str(j + 1)) { s.fields.insert(v) }
        }
      } else if name == "var", str(i + 2) == "=", str(i + 3) == "new" {
        s.varTypes[str(i + 1)] = str(i + 4)
      }
    }
    return s
  }
}
