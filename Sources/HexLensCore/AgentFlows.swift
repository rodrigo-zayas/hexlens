import Foundation

/// Contrato con el agente: lo que Claude Code devuelve (JSON con esquema fijo).
public struct AgentReport: Codable, Sendable {
  public struct Step: Codable, Sendable, Hashable {
    public var file: String?
    public var symbol: String
    public var line: Int?
    public var what: String
    public var depth: Int?
    public var change: String?
  }

  public struct Flow: Codable, Sendable, Hashable {
    public var title: String
    public var trigger: String?
    public var summary: String
    public var steps: [Step]
    public var review: [String]?
  }

  public var summary: String
  public var flows: [Flow]
  public var notes: [String]?
}

/// Paso del agente comprobado contra el código de la cabeza.
public struct VerifiedStep: Identifiable, Sendable, Hashable {
  public let id: Int
  public let step: AgentReport.Step
  public let path: String?
  public let line: Int?
  public let layer: Layer
  public let role: Role
  public let change: MemberChange.Change?
  /// El fichero existe y el método se ha encontrado en él.
  public let verified: Bool

  public var typeName: String { step.symbol.components(separatedBy: ".").first ?? step.symbol }
  public var method: String? {
    let parts = step.symbol.components(separatedBy: ".")
    return parts.count > 1 ? parts.last?.replacingOccurrences(of: "()", with: "") : nil
  }
}

public struct VerifiedFlow: Identifiable, Sendable, Hashable {
  public let id: Int
  public let flow: AgentReport.Flow
  public let steps: [VerifiedStep]
  public var files: Set<String> { Set(steps.compactMap(\.path)) }
}

public enum AgentFlows {
  public static let schema = """
    {"type":"object","required":["summary","flows"],"properties":{
      "summary":{"type":"string"},
      "flows":{"type":"array","items":{"type":"object","required":["title","summary","steps"],"properties":{
        "title":{"type":"string"},
        "trigger":{"type":"string"},
        "summary":{"type":"string"},
        "steps":{"type":"array","items":{"type":"object","required":["symbol","what"],"properties":{
          "file":{"type":"string"},
          "symbol":{"type":"string"},
          "line":{"type":"integer"},
          "what":{"type":"string"},
          "depth":{"type":"integer"},
          "change":{"type":"string","enum":["added","modified","unchanged"]}}}},
        "review":{"type":"array","items":{"type":"string"}}}}},
      "notes":{"type":"array","items":{"type":"string"}}}}
    """

  public static func prompt(_ s: ReviewSession, skeleton: [FlowNode]) -> String {
    """
    Analiza esta PR y devuelve sus flujos funcionales para una app que los dibuja junto al código.

    \(ExplainPrompt.context(s))

    Reglas:
    - Solo lectura y solo con git: `git diff`, `git show \(s.headSHA):<ruta>`, `git grep -n <patrón> \(s.headSHA) -- <ruta>`, `git log`. No leas el working tree: puede estar en otra rama.
    - Un flujo es lo que pasa desde un disparador (endpoint REST, evento o consumer, job, scheduler) hasta su efecto (persistencia, evento publicado, llamada externa, respuesta). Agrupa por intención de negocio, no por clase. Incluye solo los flujos que la PR crea o cambia.
    - title: nombre de negocio, máximo 6 palabras. trigger: qué lo dispara, concreto (p. ej. `PUT /new-ins/{id}/marks` o el tipo de job).
    - summary del flujo: máximo 2 frases, qué consigue y cuándo ocurre.
    - steps en orden de ejecución. depth 0 es el punto de entrada y sube 1 por cada llamada anidada. Para cada paso:
      file (ruta en el repo), symbol `Clase.metodo`, line (línea de la declaración del método en la cabeza; sácala con git grep -n),
      change (added si el método es nuevo, modified si cambia en la PR, unchanged si no), what (qué hace, máximo 12 palabras).
    - Pon los pasos que explican el comportamiento: entrada, caso de uso, reglas de dominio, puerto y su implementación, persistencia, eventos, llamadas externas. Omite mappers, DTOs y getters salvo que la PR cambie su lógica.
    - review: máximo 3 riesgos concretos del flujo, de 15 palabras como mucho cada uno.
    - summary global: máximo 2 frases sobre qué hace la PR. notes: cambios que no son flujo (configuración, migraciones, índices), 15 palabras como mucho cada uno.
    - En español, sin relleno.

    Ficheros por capa:
    \(ExplainPrompt.layers(s))

    Punto de partida: análisis estático de HexLens. Puede tener huecos (Lombok, llamadas encadenadas) o ruido; verifícalo leyendo el código.
    \(FlowBuilder.outline(skeleton))
    """
  }

  /// Saca el informe de la salida de `claude -p --output-format json|stream-json`.
  public static func parse(resultEvent: [String: Any]) -> AgentReport? {
    if let structured = resultEvent["structured_output"],
      let data = try? JSONSerialization.data(withJSONObject: structured),
      let report = try? JSONDecoder().decode(AgentReport.self, from: data)
    {
      return report
    }
    guard var text = resultEvent["result"] as? String else { return nil }
    if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") { text = String(text[start...end]) }
    return try? JSONDecoder().decode(AgentReport.self, from: Data(text.utf8))
  }

  /// ID del modelo que ha respondido (claves de `modelUsage` del evento final).
  public static func modelID(resultEvent: [String: Any]) -> String? {
    guard let usage = resultEvent["modelUsage"] as? [String: Any], !usage.isEmpty else { return nil }
    // Si hubo varios (p. ej. un subagente barato), el que más tokens de salida generó.
    return usage.max { a, b in
      ((a.value as? [String: Any])?["outputTokens"] as? Int ?? 0) < ((b.value as? [String: Any])?["outputTokens"] as? Int ?? 0)
    }?.key
  }

  /// Ancla cada paso a un fichero y una línea reales de la cabeza.
  public static func verify(_ report: AgentReport, session s: ReviewSession) -> [VerifiedFlow] {
    var counter = 0
    return report.flows.enumerated().map { i, flow in
      let steps = flow.steps.map { step -> VerifiedStep in
        counter += 1
        let parts = step.symbol.replacingOccurrences(of: "()", with: "").components(separatedBy: ".")
        let type = parts.first ?? step.symbol
        let method = parts.count > 1 ? parts.last : nil

        var path = step.file.flatMap { s.store.text($0, at: s.headSHA) != nil ? $0 : nil }
        if path == nil {
          let candidates = s.index.pathsBySimpleName[type] ?? []
          path = candidates.first { s.graph.unit($0).map { !$0.isGhost } ?? false } ?? candidates.first
        }
        let parsed = path.flatMap { s.store.parsed($0, at: s.headSHA) }
        let member = method.flatMap { parsed?.member(named: $0) }
        let line = member?.startLine ?? parsed?.facts.primaryLine ?? step.line

        let unit = path.flatMap { s.graph.unit($0) }
        let info = unit.map { ($0.layer, $0.role) }
          ?? path.map { let a = s.profile.classify(path: $0, facts: parsed?.facts); return (a.layer, a.role) }
          ?? (.other, .other)
        let change = unit?.members.first { $0.name == method }?.change
          ?? (step.change == "added" ? .added : step.change == "modified" ? .modified : nil)

        return VerifiedStep(
          id: counter, step: step, path: path, line: line, layer: info.0, role: info.1, change: change,
          verified: path != nil && (method == nil || member != nil))
      }
      return VerifiedFlow(id: i, flow: flow, steps: steps)
    }
  }
}
