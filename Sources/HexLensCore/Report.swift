import Foundation

/// Resumen en texto de una sesión, para la CLI y para depurar la clasificación.
public enum Report {
  public static func text(_ s: ReviewSession, strategy: ReadingStrategy = .insideOut) -> String {
    let g = s.graph
    var out: [String] = []
    let changed = g.changed
    out.append("\(s.title)  [\(s.baseSHA.prefix(8))…\(s.headSHA.prefix(8))]  perfil: \(s.profileName)")
    out.append("\(changed.count) ficheros, +\(changed.map(\.additions).reduce(0, +)) −\(changed.map(\.deletions).reduce(0, +))")

    let primaries = changed.filter { $0.isCode && !$0.isTest }
    let byLayer = Dictionary(grouping: primaries, by: \.layer)
    out.append("")
    out.append("Por capa:")
    for layer in Layer.allCases {
      guard let us = byLayer[layer] else { continue }
      let roles = Dictionary(grouping: us, by: \.role).map { "\($0.value.count) \($0.key.label)" }.sorted().joined(separator: ", ")
      out.append("  \(layer.title.padding(toLength: 14, withPad: " ", startingAt: 0)) \(us.count)  (\(roles))")
    }
    let tests = changed.filter(\.isTest).count
    if tests > 0 { out.append("  Tests          \(tests)") }
    let other = changed.filter { !$0.isCode }.count
    if other > 0 { out.append("  No código      \(other)") }
    if let entry = g.entryPoint.flatMap(g.unit) { out.append("\nPunto de entrada sugerido: \(entry.typeName) (\(entry.layer.title), \(entry.role.label))") }

    out.append("\nOrden de lectura (\(strategy.title)):")
    for (i, id) in g.readingOrder(strategy).enumerated() {
      guard let u = g.unit(id) else { continue }
      let indent = u.isTest && g.subjectByTest[id] != nil ? "     ↳ " : ""
      let members = u.members.prefix(6).map { m in
        (m.change == .added ? "+" : m.change == .removed ? "−" : "~") + m.name
      }.joined(separator: " ")
      out.append(String(format: "%3d. ", i + 1) + indent
        + "[\(u.status.letter)] \(u.typeName)  ·\(u.layer.title)/\(u.role.label)·  \(u.packageLabel)  +\(u.additions) −\(u.deletions)"
        + (members.isEmpty ? "" : "  { \(members) }"))
    }

    let deps = g.edges.filter { $0.kind != .tests }
    out.append("\nRelaciones (\(deps.count)):")
    for e in deps.prefix(80) {
      guard let a = g.unit(e.from), let b = g.unit(e.to) else { continue }
      out.append("  \(a.typeName) —\(e.kind.rawValue)→ \(b.typeName)\(b.isGhost ? " (sin cambios)" : "")")
    }

    if !g.violations.isEmpty {
      out.append("\nReglas de arquitectura:")
      for v in g.violations {
        let name = g.unit(v.unitID)?.typeName ?? v.unitID
        out.append("  \(v.severity == .error ? "✖" : "⚠") \(name) → \(v.imported): \(v.message)\(v.introduced ? " [nuevo en la PR]" : "")")
      }
    }
    return out.joined(separator: "\n")
  }
}
