import Foundation

/// Prompts para que `claude` explique la PR, un fichero o un flujo. Claude corre en el repo y
/// lee el diff él mismo; aquí solo se le da el mapa que HexLens ya ha calculado.
public enum ExplainPrompt {
  public static func pr(_ s: ReviewSession, flows: [FlowNode]) -> String {
    """
    Explícame qué hace el código de esta PR, de forma concisa. Soy el revisor y no la conozco.

    \(context(s))

    Responde así, sin relleno y sin repetir el diff:
    1. Qué hace, en 2-3 frases y en términos de negocio.
    2. Cada flujo de entrada (endpoint, handler, consumer) paso a paso hasta persistencia o eventos, nombrando `Clase.metodo`.
    3. Cambios de comportamiento o decisiones de diseño que no son obvios.
    4. Qué revisaría con atención: riesgos y casos borde, máximo 5 puntos.

    Ficheros por capa:
    \(layers(s))

    Flujos de llamadas detectados (aproximados, sin resolver tipos):
    \(FlowBuilder.outline(flows))
    """
  }

  public static func file(_ s: ReviewSession, path: String) -> String {
    let g = s.graph
    let u = g.unit(path)
    let name = u?.typeName ?? (path as NSString).lastPathComponent
    let uses = g.outgoing(path).compactMap { g.unit($0.to)?.typeName }
    let usedBy = g.incoming(path).compactMap { g.unit($0.from) }.filter { !$0.isTest }.map(\.typeName)
    let inPR = u.map { !$0.isGhost } ?? false
    return """
      Explícame de forma concisa qué hace `\(name)` (\(path))\(inPR ? " y qué cambia en esta PR" : ""). Soy el revisor.

      \(context(s))
      \(inPR ? "Su diff: `git diff \(s.baseSHA) \(s.headSHA) -- \(u?.oldPath.map { "\($0) " } ?? "")\(path)`" : "No cambia en la PR: `git show \(s.headSHA):\(path)`")

      Responde así, sin relleno:
      1. Qué responsabilidad tiene, en 1-2 frases\(u.map { " (capa: \($0.layer.title.lowercased()), rol: \($0.role.label))" } ?? "").
      2. \(inPR ? "Qué cambia y para qué, método a método." : "Qué hace cada método relevante.")
      3. Quién lo llama y a quién llama, y qué pasa en ese recorrido.
      4. Qué revisaría con atención, máximo 3 puntos.

      Lo usan: \(usedBy.isEmpty ? "—" : usedBy.joined(separator: ", "))
      Usa: \(uses.isEmpty ? "—" : uses.joined(separator: ", "))
      """
  }

  public static func flow(_ s: ReviewSession, flow: FlowNode) -> String {
    """
    Explícame paso a paso y de forma concisa qué pasa cuando se ejecuta `\(flow.title)` en esta PR: qué datos entran, qué decisiones se toman, qué se guarda o se publica y qué devuelve. Señala qué parte es nueva o cambia en la PR y qué revisaría.

    \(context(s))

    Recorrido detectado por HexLens (aproximado):
    \(FlowBuilder.outline([flow], pruned: false))
    """
  }

  public static func context(_ s: ReviewSession) -> String {
    """
    PR: \(s.title) en \(s.repo.name). Java con arquitectura hexagonal AMIGA (módulos domain / application / infrastructure / infrastructure-components).
    El diff está en local, sin hacer checkout: `git diff \(s.baseSHA) \(s.headSHA)`. Para leer un fichero tal como queda: `git show \(s.headSHA):<ruta>`.
    """
  }

  public static func layers(_ s: ReviewSession) -> String {
    let changed = s.graph.changed.filter { $0.isCode && !$0.isTest }
    return Layer.allCases.compactMap { layer -> String? in
      let names = changed.filter { $0.layer == layer }.map { "\($0.typeName) (\($0.role.label), \($0.status.label))" }
      return names.isEmpty ? nil : "- \(layer.title): " + names.joined(separator: ", ")
    }.joined(separator: "\n")
  }
}
