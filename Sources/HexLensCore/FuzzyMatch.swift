import Foundation

/// Coincidencia difusa estilo IntelliJ: iniciales CamelCase, subsecuencia y prefijo.
public enum FuzzyMatch {
  /// Puntuación (mayor = mejor) o `nil` si `query` no encaja en `candidate`.
  public static func score(query: String, candidate: String) -> Int? {
    if query.isEmpty { return 0 }
    let q = Array(query.lowercased())
    let c = Array(candidate)
    let lower = Array(candidate.lowercased())
    guard q.count <= lower.count, lower.count == c.count else { return nil }

    var best: Int?
    func consider(_ s: Int?) { if let s, s > (best ?? Int.min) { best = s } }

    if lower.starts(with: q) { consider(1000 + (q.count == lower.count ? 200 : 0) - lower.count) }
    consider(subsequence(q, lower, c))
    return best
  }

  private static func isBoundary(_ c: [Character], _ i: Int) -> Bool {
    if i == 0 { return true }
    let p = c[i - 1], ch = c[i]
    if !p.isLetter && !p.isNumber { return true }
    return (ch.isUppercase && !p.isUppercase) || (ch.isNumber && !p.isNumber)
  }

  /// Mejor alineación de la consulta como subsecuencia, premiando inicios de palabra y rachas.
  private static func subsequence(_ q: [Character], _ lower: [Character], _ c: [Character]) -> Int? {
    let n = lower.count, m = q.count
    // dp[j][i]: mejor puntuación con q[j] casada en la posición i.
    var prev = [Int?](repeating: nil, count: n)
    for j in 0..<m {
      var cur = [Int?](repeating: nil, count: n)
      var bestBefore: Int?
      for i in 0..<n {
        if j > 0, i > 0, let p = prev[i - 1] { bestBefore = max(bestBefore ?? Int.min, p) }
        guard lower[i] == q[j] else { continue }
        let boundary = isBoundary(c, i)
        var gain = boundary ? 30 : 5
        if j == 0 {
          gain += i == 0 ? 50 : -min(i, 20)
          cur[i] = gain
        } else {
          var options: [Int] = []
          if let b = bestBefore { options.append(b - 1) }
          if i > 0, let p = prev[i - 1] { options.append(p + 15) }
          guard let o = options.max() else { continue }
          cur[i] = o + gain
        }
      }
      prev = cur
    }
    guard let top = prev.compactMap({ $0 }).max() else { return nil }
    return top - (n - m)
  }
}
