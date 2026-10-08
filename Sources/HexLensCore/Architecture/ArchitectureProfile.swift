import Foundation

public struct ArchInfo: Hashable, Sendable {
  public var module: String
  public var layer: Layer
  public var role: Role
  public var context: String?
  public var packageLabel: String
  public var isTest: Bool
}

/// Convenciones de arquitectura de un tipo de repo. La de ITX es la primera; otras (Clean,
/// Spring Modulith, jMolecules…) serían perfiles nuevos sin tocar el resto.
public protocol ArchitectureProfile: Sendable {
  var name: String { get }
  func classify(path: String, facts: SourceFacts?) -> ArchInfo
  /// Regla de dependencias violada por `importing`, si la hay.
  func violation(from: ArchInfo, fromPackage: String, importing fqn: String) -> (String, Violation.Severity)?
}

/// Hexagonal de AMIGA (ITX): módulos `*-domain`, `*-application`, `*-infrastructure`,
/// `*-infrastructure-components/*-{sistema}-{rest|pipe|grpc|mongo}` y `*-boot`; paquetes
/// `com.inditex.<app>.<capa>.<contexto>…`.
public struct ItxHexagonalProfile: ArchitectureProfile {
  public init() {}

  public let name = "ITX hexagonal (AMIGA)"

  static let markers = ["domain", "application", "infrastructure", "components", "boot"]
  static let techs: Set<String> = ["rest", "pipe", "grpc", "mongo", "db2", "kafka", "jdbc", "jpa", "redis"]

  static let inboundAnnotations: Set<String> = [
    "RestController", "Controller", "ControllerAdvice", "RestControllerAdvice", "KafkaListener",
    "RabbitListener", "StreamListener", "SqsListener", "EventListener", "Scheduled", "GrpcService",
  ]
  static let configAnnotations: Set<String> = [
    "Configuration", "ConfigurationProperties", "AutoConfiguration", "SpringBootApplication",
  ]
  static let inboundSegments: Set<String> = [
    "controller", "controllers", "consumer", "consumers", "listener", "listeners", "scheduler",
    "schedulers", "handler", "handlers", "operations", "api", "web", "inbound", "driving", "in",
  ]
  static let outboundSegments: Set<String> = [
    "mongo", "repository", "repositories", "dao", "client", "clients", "db2", "jpa", "jdbc", "producer",
    "producers", "publisher", "publishers", "gateway", "persistence", "cache", "outbound", "driven", "out",
  ]
  static let frameworkPrefixes = [
    "org.springframework.", "jakarta.persistence.", "javax.persistence.", "com.mongodb.", "org.bson.",
    "org.apache.kafka.", "io.grpc.", "com.fasterxml.jackson.",
  ]

  public func classify(path: String, facts: SourceFacts?) -> ArchInfo {
    let comps = path.split(separator: "/").map(String.init)
    let fileName = comps.last ?? path
    let srcIndex = comps.firstIndex(of: "src")
    let module = srcIndex.flatMap { $0 > 0 ? comps[$0 - 1] : nil } ?? (comps.count > 1 ? comps[comps.count - 2] : "raíz")
    let stem = (fileName as NSString).deletingPathExtension
    let isTest = path.contains("/src/test/") || path.contains("/src/it/")
      || (!path.contains("/src/main/") && Self.testSubject(of: stem) != nil)

    guard let facts else {
      let (layer, role) = Self.nonCode(fileName: fileName, path: path)
      return ArchInfo(module: module, layer: layer, role: role, context: nil, packageLabel: module, isTest: isTest)
    }

    let primaryName = facts.primary?.name ?? stem
    // Un test hereda el rol de la clase que prueba.
    let typeName = isTest ? (Self.testSubject(of: primaryName) ?? primaryName) : primaryName
    var info = classify(
      packageName: facts.packageName, typeName: typeName, kind: facts.primary?.kind ?? .unknown,
      annotations: Set(facts.annotations), supertypes: facts.supertypes, module: module)
    info.isTest = isTest
    return info
  }

  /// Clasificación solo con paquete y nombre: sirve también para lo que importa un fichero.
  public func classify(
    packageName: String, typeName: String, kind: TypeKind = .unknown,
    annotations: Set<String> = [], supertypes: [String] = [], module: String = ""
  ) -> ArchInfo {
    let segs = packageName.split(separator: ".").map(String.init)
    let markerIndex = segs.firstIndex { Self.markers.contains($0) }
    let marker = markerIndex.map { segs[$0] } ?? Self.moduleMarker(module)
    let after = markerIndex.map { Array(segs[($0 + 1)...]) } ?? []
    let context = after.first
    let label = markerIndex != nil ? after.joined(separator: ".") : Self.trimRoot(packageName)
    let all = Set(segs)

    func info(_ layer: Layer, _ role: Role, _ ctx: String? = context) -> ArchInfo {
      ArchInfo(module: module, layer: layer, role: role, context: ctx, packageLabel: label, isTest: false)
    }
    func suffix(_ s: String...) -> Bool { s.contains { typeName.hasSuffix($0) } }

    switch marker {
    case "domain":
      if suffix("Exception") || all.contains("exceptions") || all.contains("exception") { return info(.domain, .exception) }
      if suffix("Event") || all.contains("events") || all.contains("event") { return info(.domain, .event) }
      if kind == .interface && (all.contains("repository") || all.contains("port") || all.contains("ports")
        || all.contains("gateway") || suffix("Repository", "Port", "Gateway", "Client", "Publisher", "Provider"))
      {
        return info(.domain, .port)
      }
      if all.contains("service") || all.contains("services") || suffix("Service") { return info(.domain, .domainService) }
      if all.contains("configuration") { return info(.domain, .configuration) }
      return info(.domain, .entity)

    case "application":
      if suffix("Exception") { return info(.application, .exception) }
      if suffix("Params", "Response", "Result", "Request", "Command", "Query")
        || !all.isDisjoint(with: ["params", "responses", "result", "results", "command", "query"])
      {
        return info(.application, .params)
      }
      if all.contains("usecase") || all.contains("usecases") || suffix("UseCase") { return info(.application, .useCase) }
      if kind == .interface { return info(.application, .port) }
      return info(.application, .appService)

    case "infrastructure", "components":
      return adapter(
        marker: marker, after: after, all: all, typeName: typeName, kind: kind,
        annotations: annotations, supertypes: supertypes, info: info)

    case "boot":
      return info(.config, annotations.contains("SpringBootApplication") ? .bootstrap : .configuration)

    default:
      if !annotations.isDisjoint(with: Self.configAnnotations) { return info(.config, .configuration) }
      return info(.other, .other, nil)
    }
  }

  private func adapter(
    marker: String, after: [String], all: Set<String>, typeName: String, kind: TypeKind,
    annotations: Set<String>, supertypes: [String], info: (Layer, Role, String?) -> ArchInfo
  ) -> ArchInfo {
    func suffix(_ s: String...) -> Bool { s.contains { typeName.hasSuffix($0) } }
    // components.<sistema>.<tecnología>; sin sistema (components.rest) es el propio API del micro.
    let system = marker == "components" && !(after.first.map(Self.techs.contains) ?? true) ? after.first : nil
    let context = marker == "components" ? (system ?? after.first) : after.first

    if !annotations.isDisjoint(with: Self.configAnnotations)
      || all.contains("configuration") || all.contains("config") || all.contains("properties")
    {
      return info(.config, .configuration, context)
    }

    let role: Role
    if annotations.contains("RestController") || annotations.contains("Controller") || suffix("Controller")
      || all.contains("controller")
    {
      role = .controller
    } else if !annotations.isDisjoint(with: ["KafkaListener", "RabbitListener", "StreamListener", "SqsListener", "EventListener"])
      || suffix("Consumer", "Listener") || all.contains("consumer") || all.contains("listener")
    {
      role = .consumer
    } else if suffix("Handler") && !suffix("ExceptionHandler", "ErrorHandler") {
      role = .handler
    } else if annotations.contains("Scheduled") || suffix("Scheduler", "Job") || all.contains("scheduler") {
      role = .scheduler
    } else if all.contains("operations") || supertypes.contains("Operation") {
      role = .operation
    } else if suffix("Exception") {
      role = .exception
    } else if suffix("Mapper") || all.contains("mapper") || all.contains("mappers") {
      role = .mapper
    } else if suffix("DTO", "Dto", "Request", "Response") || all.contains("dto") || all.contains("dtos") {
      role = .dto
    } else if suffix("Producer", "Publisher", "Sender") || all.contains("producer") || all.contains("publisher") {
      role = .publisher
    } else if suffix("Client") || all.contains("client") || all.contains("clients")
      || (system != nil && (all.contains("service") || all.contains("dao")))
    {
      role = .client
    } else if suffix("Repository", "RepositoryMongo", "RepositoryImpl", "Adapter", "Dao", "Template")
      || !all.isDisjoint(with: Self.outboundSegments)
    {
      role = .adapter
    } else {
      // Sin pistas de a qué habla: no se acusa como adaptador de salida.
      role = .infraService
    }

    // Dirección por el paquete: en AMIGA `infrastructure.<ctx>.components.rest` y `components.rest`
    // son el API del propio micro; `components.<sistema>.*` habla con otro sistema.
    let inboundByPackage = !all.isDisjoint(with: Self.inboundSegments)
      || (marker == "infrastructure" && all.contains("rest"))
      || (marker == "components" && system == nil && after.first == "rest")
    let outboundByPackage = !all.isDisjoint(with: Self.outboundSegments) || system != nil

    switch role {
    case .controller, .consumer, .handler, .scheduler, .operation:
      return info(.inbound, role, context)
    case .client, .publisher:
      return info(.outbound, role, context)
    default:
      return info(inboundByPackage && !outboundByPackage ? .inbound : .outbound, role, context)
    }
  }

  public func violation(from: ArchInfo, fromPackage: String, importing fqn: String) -> (String, Violation.Severity)? {
    if from.layer == .domain, let fw = Self.frameworkPrefixes.first(where: fqn.hasPrefix) {
      return ("El dominio importa framework (\(fw.dropLast()))", .warning)
    }
    // Solo se juzgan imports del propio ecosistema (mismo prefijo de dos segmentos, p.ej. com.inditex).
    let root = fromPackage.split(separator: ".").prefix(2).joined(separator: ".")
    guard !root.isEmpty, fqn.hasPrefix(root + ".") else { return nil }
    let segs = fqn.split(separator: ".").map(String.init)
    guard let typeName = segs.last(where: { $0.first?.isUppercase == true }) else { return nil }
    let pkg = segs.prefix { $0.first?.isUppercase != true }.joined(separator: ".")
    let target = classify(packageName: pkg, typeName: typeName)

    switch (from.layer, target.layer) {
    case (.domain, .application), (.domain, .inbound), (.domain, .outbound), (.domain, .config):
      return ("El dominio depende de \(target.layer.title.lowercased())", .error)
    case (.application, .inbound), (.application, .outbound), (.application, .config):
      return ("La aplicación depende de un adaptador (\(target.layer.title.lowercased()))", .error)
    case (.inbound, .outbound) where (target.role == .adapter || target.role == .client) && sameApp(fromPackage, fqn):
      return ("Un adaptador de entrada usa uno de salida sin pasar por aplicación", .warning)
    default:
      return nil
    }
  }

  // MARK: - Utilidades

  /// Mismo micro: comparten `com.inditex.<app>`. Las librerías comunes (lib-pacman) no cuentan.
  func sameApp(_ a: String, _ b: String) -> Bool {
    let ra = a.split(separator: ".").prefix(3), rb = b.split(separator: ".").prefix(3)
    return ra.count == 3 && ra == rb
  }

  /// `FooTest`, `FooIT`, `FooTests` → `Foo`.
  public static func testSubject(of name: String) -> String? {
    for s in ["Tests", "Test", "IT"] where name.hasSuffix(s) && name.count > s.count {
      return String(name.dropLast(s.count))
    }
    return nil
  }

  static func moduleMarker(_ module: String) -> String {
    if module.hasSuffix("-boot") { return "boot" }
    if module.contains("-components-") || module.hasSuffix("-components") { return "components" }
    for m in ["domain", "application", "infrastructure"] where module.contains(m) { return m }
    return ""
  }

  static func trimRoot(_ pkg: String) -> String {
    let segs = pkg.split(separator: ".")
    return segs.count > 3 ? segs.dropFirst(3).joined(separator: ".") : pkg
  }

  static func nonCode(fileName: String, path: String) -> (Layer, Role) {
    if ["pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle"].contains(fileName) { return (.config, .build) }
    let ext = (fileName as NSString).pathExtension
    if ["yml", "yaml", "properties", "json", "xml", "sql", "proto", "avsc"].contains(ext) || path.contains("/resources/") {
      return (.config, .resource)
    }
    return (.other, .resource)
  }
}
