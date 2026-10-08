import Foundation

/// Paso de un flujo: un método y lo que llama.
public struct FlowNode: Identifiable, Sendable, Hashable {
  public let id: String
  public let path: String
  public let typeName: String
  public let method: String
  public let line: Int?
  public let layer: Layer
  public let role: Role
  public let change: MemberChange.Change?
  public let inPR: Bool
  public let note: String?
  public var children: [FlowNode]?

  public var title: String { "\(typeName).\(method)()" }

  /// Este paso o alguno de sus descendientes cambia en la PR.
  public var touchesPR: Bool { change != nil || (children ?? []).contains { $0.touchesPR } }

  /// Quita las ramas que no llevan a nada cambiado. Las implementaciones de un puerto se conservan.
  public func pruned() -> FlowNode {
    var copy = self
    let kept = (children ?? []).filter { $0.touchesPR || $0.note != nil }.map { $0.pruned() }
    copy.children = kept.isEmpty ? nil : kept
    return copy
  }
}

/// Recorre las llamadas desde los puntos de entrada de la PR (controllers, handlers, consumers…)
/// bajando por aplicación y dominio, y de cada puerto a su implementación.
public enum FlowBuilder {
  static let entryRoles: Set<Role> = [.controller, .consumer, .handler, .scheduler, .operation]
  static let noise: Set<Role> = [.mapper, .dto, .params, .exception, .configuration]

  public static func build(session s: ReviewSession, maxDepth: Int = 7) -> [FlowNode] {
    let g = s.graph
    let changed = g.changed.filter { $0.isCode && !$0.isTest && $0.status != .deleted }
    var entries = changed.filter { $0.layer == .inbound && entryRoles.contains($0.role) }
    if entries.isEmpty { entries = changed.filter { $0.role == .useCase } }
    if entries.isEmpty { entries = changed.filter { $0.layer == .application } }

    var expanded = Set<String>()
    var counter = 0

    func info(_ path: String, _ parsed: ParsedFile?) -> (Layer, Role) {
      if let u = g.unit(path) { return (u.layer, u.role) }
      let i = s.profile.classify(path: path, facts: parsed?.facts)
      return (i.layer, i.role)
    }

    func node(_ path: String, _ parsed: ParsedFile?, _ member: Member?, _ name: String, note: String?, depth: Int) -> FlowNode {
      counter += 1
      let (layer, role) = info(path, parsed)
      let unit = g.unit(path)
      let change = unit?.members.first { $0.name == (member?.name ?? name) }?.change
      let key = "\(path)#\(member?.key ?? name)"
      var children: [FlowNode]?
      if let parsed, let member, depth < maxDepth, expanded.insert(key).inserted {
        let c = expand(parsed, member, depth: depth + 1)
        children = c.isEmpty ? nil : c
      }
      return FlowNode(
        id: "\(counter)", path: path, typeName: parsed?.facts.primary?.name ?? unit?.typeName ?? (path as NSString).lastPathComponent,
        method: member?.name ?? name, line: member?.startLine, layer: layer, role: role, change: change,
        inPR: unit.map { !$0.isGhost } ?? false, note: note, children: children)
    }

    func expand(_ file: ParsedFile, _ member: Member, depth: Int) -> [FlowNode] {
      var seen = Set<String>()
      var out: [FlowNode] = []
      for call in file.semantics.calls where (member.startLine...member.endLine).contains(call.line) {
        // Llamada a un método del propio fichero.
        if call.receiver == nil {
          guard let m = file.member(named: call.name), m.key != member.key, seen.insert("self#\(m.key)").inserted else { continue }
          out.append(node(file.path, file, m, call.name, note: nil, depth: depth))
          continue
        }
        let r = call.receiver!
        guard let type = file.semantics.varTypes[r] ?? (r.first?.isUppercase == true ? r : nil),
          let path = s.index.resolve(type, from: file.facts),
          seen.insert("\(path)#\(call.name)").inserted
        else { continue }
        let target = s.store.parsed(path, at: s.headSHA)
        let (_, role) = info(path, target)
        let targetInPR = g.unit(path).map { !$0.isGhost } ?? false
        if noise.contains(role) && !targetInPR { continue }
        let m = target?.member(named: call.name)
        // Sin cuerpo localizable (getter de Lombok, método heredado): solo si es una frontera relevante.
        if m == nil && ![.port, .useCase, .client, .adapter, .publisher, .domainService, .appService].contains(role) { continue }

        var n = node(path, target, m, call.name, note: nil, depth: depth)
        if target?.facts.primary?.kind == .interface, depth < maxDepth {
          let impls = s.store.implementations(of: target?.facts.primary?.name ?? type, at: s.headSHA)
          let implNodes = impls.prefix(4).compactMap { implPath -> FlowNode? in
            guard let impl = s.store.parsed(implPath, at: s.headSHA) else { return nil }
            return node(implPath, impl, impl.member(named: call.name), call.name, note: "implementación", depth: depth + 1)
          }
          if !implNodes.isEmpty { n.children = (n.children ?? []) + implNodes }
        }
        out.append(n)
      }
      return out
    }

    var flows: [FlowNode] = []
    for entry in entries.sorted(by: { ($0.layer.column, $0.typeName) < ($1.layer.column, $1.typeName) }) {
      guard let file = s.store.parsed(entry.path, at: s.headSHA) else { continue }
      let methods = file.facts.members.filter { !$0.key.hasPrefix("type:") && !$0.key.hasPrefix("field:") && $0.name != entry.typeName }
      let touched = Set(entry.members.filter { $0.change != .removed }.map(\.name))
      var chosen = methods.filter { touched.contains($0.name) }
      if chosen.isEmpty { chosen = methods }
      // Solo puntos de entrada: los privados se verán como hijos.
      let called = Set(file.semantics.calls.filter { $0.receiver == nil }.map(\.name))
      let roots = chosen.filter { !called.contains($0.name) }
      for m in (roots.isEmpty ? chosen : roots) {
        flows.append(node(entry.path, file, m, m.name, note: nil, depth: 0))
      }
    }
    return flows
  }

  /// Flujos en texto indentado (para la CLI y para el prompt de explicación).
  public static func outline(_ flows: [FlowNode], pruned: Bool = true) -> String {
    let flows = pruned ? flows.map { $0.pruned() } : flows
    var lines: [String] = []
    func walk(_ n: FlowNode, _ depth: Int) {
      let mark = n.change.map { $0 == .added ? " [nuevo]" : $0 == .modified ? " [cambiado]" : " [quitado]" } ?? (n.inPR ? "" : " [sin cambios]")
      lines.append(String(repeating: "  ", count: depth) + (depth == 0 ? "▶ " : "→ ") + n.title
        + "  (\(n.layer.title.lowercased()), \(n.role.label))" + mark + (n.note.map { " — \($0)" } ?? ""))
      for c in n.children ?? [] { walk(c, depth + 1) }
    }
    flows.forEach { walk($0, 0) }
    return lines.joined(separator: "\n")
  }
}
