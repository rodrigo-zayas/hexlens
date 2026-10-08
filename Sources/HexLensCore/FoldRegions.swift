import Foundation

/// Región plegable de un fichero Java. Índices de línea (base 0) de la lista de líneas analizada.
public struct FoldRegion: Sendable, Hashable {
  public enum Kind: Sendable { case imports, comment, block }
  public let kind: Kind
  /// Línea que se queda visible con el marcador.
  public let start: Int
  /// Última línea que se oculta al plegar (`start + 1 ... hiddenEnd`).
  public let hiddenEnd: Int
  /// Última línea de la región (la de la llave de cierre, el último import o el fin del comentario).
  public let end: Int

  public init(kind: Kind, start: Int, hiddenEnd: Int, end: Int) {
    self.kind = kind
    self.start = start
    self.hiddenEnd = hiddenEnd
    self.end = end
  }

  /// Si al plegar desaparece también la llave de cierre.
  public var hidesClosing: Bool { hiddenEnd == end }
}

public enum FoldRegions {
  /// Bloque de imports, comentarios de varias líneas y bloques `{ … }` (tipos, métodos, clases internas)
  /// que ocupan más de una línea, ordenados por línea de inicio.
  public static func compute(lines: [String]) -> [FoldRegion] {
    guard !lines.isEmpty else { return [] }
    let text = lines.joined(separator: "\n")
    var starts: [Int] = []
    var offset = 0
    for l in lines {
      starts.append(offset)
      offset += (l as NSString).length + 1
    }
    func lineOf(_ o: Int) -> Int {
      var lo = 0, hi = starts.count - 1
      while lo < hi {
        let mid = (lo + hi + 1) / 2
        if starts[mid] <= o { lo = mid } else { hi = mid - 1 }
      }
      return lo
    }

    var out: [FoldRegion] = []

    var group: [Int] = []
    func flushImports() {
      if group.count >= 2, let first = group.first, let last = group.last {
        out.append(FoldRegion(kind: .imports, start: first, hiddenEnd: last, end: last))
      }
      group = []
    }
    for (i, l) in lines.enumerated() {
      let t = l.trimmingCharacters(in: .whitespaces)
      if t.hasPrefix("import ") { group.append(i) } else if !t.isEmpty { flushImports() }
    }
    flushImports()

    let units = Array(text.utf16)
    var open: [Int] = []
    var blocks: [Int: FoldRegion] = [:]
    for t in JavaLexer.tokens(text) {
      if t.kind == .comment, units[t.range.location] == 47, units[t.range.location + 1] == 42 {
        let a = lineOf(t.range.location), b = lineOf(NSMaxRange(t.range) - 1)
        if b > a { out.append(FoldRegion(kind: .comment, start: a, hiddenEnd: b, end: b)) }
      } else if t.kind == .punct, units[t.range.location] == 123 {
        open.append(lineOf(t.range.location))
      } else if t.kind == .punct, units[t.range.location] == 125, let a = open.popLast() {
        let b = lineOf(t.range.location)
        guard b > a else { continue }
        let lineEnd = starts[b] + (lines[b] as NSString).length
        let rest = String(utf16CodeUnits: Array(units[(t.range.location + 1)..<lineEnd]), count: lineEnd - t.range.location - 1)
        let closesAlone = rest.allSatisfy { $0 == ";" || $0 == "," || $0 == ")" || $0 == " " || $0 == "\t" }
        let hidden = closesAlone ? b : b - 1
        guard hidden > a else { continue }
        let region = FoldRegion(kind: .block, start: a, hiddenEnd: hidden, end: b)
        if let existing = blocks[a], existing.end >= b { continue }
        blocks[a] = region
      }
    }
    out.append(contentsOf: blocks.values)
    return out.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end }
  }
}
