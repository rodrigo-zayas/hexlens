import Foundation

public struct UsageHit: Hashable, Sendable {
  public let path: String
  public let line: Int
  public let text: String
  public init(path: String, line: Int, text: String) { self.path = path; self.line = line; self.text = text }
}

public struct UsageGroup: Hashable, Sendable {
  public let path: String
  public let hits: [UsageHit]
  public init(path: String, hits: [UsageHit]) { self.path = path; self.hits = hits }
}

/// Resultado de `git grep -n -w` para "Buscar usos".
public enum UsageSearch {
  /// Parsea `rev:ruta:línea:texto` (el prefijo `rev:` es opcional).
  public static func parse(_ output: String, rev: String? = nil) -> [UsageHit] {
    var hits: [UsageHit] = []
    for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
      var s = Substring(raw)
      if let rev, s.hasPrefix(rev + ":") { s = s.dropFirst(rev.count + 1) }
      guard let c1 = s.firstIndex(of: ":") else { continue }
      let rest = s[s.index(after: c1)...]
      guard let c2 = rest.firstIndex(of: ":"), let line = Int(rest[..<c2]) else { continue }
      hits.append(UsageHit(path: String(s[..<c1]), line: line, text: String(rest[rest.index(after: c2)...])))
    }
    return hits
  }

  /// Agrupa por fichero conservando el orden de aparición.
  public static func group(_ hits: [UsageHit]) -> [UsageGroup] {
    var order: [String] = []
    var byPath: [String: [UsageHit]] = [:]
    for h in hits {
      if byPath[h.path] == nil { order.append(h.path) }
      byPath[h.path, default: []].append(h)
    }
    return order.map { UsageGroup(path: $0, hits: byPath[$0]!) }
  }
}
