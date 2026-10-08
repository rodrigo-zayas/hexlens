import Foundation

/// Java en capas sin la estructura de módulos de ITX: controller/web → service → repository/model,
/// por segmentos del paquete.
public struct GenericLayeredJavaProfile: ArchitectureProfile {
  public init() {}

  public let id = "generic-layered-java"
  public let name = "Java en capas (genérico)"
  public let languages: Set<String> = ["java"]

  static let web: Set<String> = ["controller", "controllers", "web", "api", "rest", "resource", "resources", "endpoint", "endpoints"]
  static let service: Set<String> = ["service", "services", "usecase", "usecases", "application"]
  static let repository: Set<String> = ["repository", "repositories", "dao", "persistence", "client", "clients", "gateway"]
  static let model: Set<String> = ["model", "models", "entity", "entities", "domain", "dto", "dtos"]
  static let config: Set<String> = ["config", "configuration"]

  public func zone(for info: ArchInfo) -> MapZone {
    switch info.layer {
    case .inbound: MapZone(id: "web", title: "Controller / Web", order: 1, subtitle: "entrada")
    case .application: MapZone(id: "service", title: "Service", order: 2, subtitle: "lógica de negocio")
    case .domain, .outbound: MapZone(id: "data", title: "Repository / Modelo", order: 3, subtitle: "persistencia y modelo")
    case .config: MapZone(id: "config", title: "Configuración", order: 4, subtitle: "arranque y wiring")
    case .other: MapZone(id: "other", title: "Otros", order: 5, subtitle: "sin capa reconocida")
    }
  }

  public func matchScore(paths: [String]) -> Double {
    let java = paths.filter { $0.hasSuffix(".java") }
    guard !java.isEmpty else { return 0 }
    let layered = java.contains { p in
      !Set(p.split(separator: "/").dropLast().map { $0.lowercased() })
        .isDisjoint(with: Self.web.union(Self.service).union(Self.repository).union(Self.model))
    }
    return layered ? 0.6 : 0.5
  }

  public func classify(path: String, facts: SourceFacts?) -> ArchInfo {
    let comps = path.split(separator: "/").map(String.init)
    let stem = ((comps.last ?? path) as NSString).deletingPathExtension
    let srcIndex = comps.firstIndex(of: "src")
    let module = srcIndex.flatMap { $0 > 0 ? comps[$0 - 1] : nil } ?? (comps.count > 1 ? comps[comps.count - 2] : "raíz")
    let isTest = path.contains("/src/test/") || path.contains("/src/it/")
    let type = facts?.primary?.name ?? stem
    let segs = facts?.packageName.split(separator: ".").map { $0.lowercased() } ?? comps.dropLast().map { $0.lowercased() }
    let all = Set(segs)
    let label = facts?.packageName ?? module

    func info(_ layer: Layer, _ role: Role) -> ArchInfo {
      ArchInfo(module: module, layer: layer, role: role, context: nil, packageLabel: label, isTest: isTest)
    }
    if type.hasSuffix("Controller") || !all.isDisjoint(with: Self.web) { return info(.inbound, .controller) }
    if type.hasSuffix("Service") || !all.isDisjoint(with: Self.service) { return info(.application, .appService) }
    if type.hasSuffix("Repository") || type.hasSuffix("Dao") || !all.isDisjoint(with: Self.repository) {
      return info(.outbound, .adapter)
    }
    if !all.isDisjoint(with: Self.config) { return info(.config, .configuration) }
    if !all.isDisjoint(with: Self.model) { return info(.domain, .entity) }
    return info(.other, .other)
  }

  public func violation(from: ArchInfo, fromPackage: String, importing fqn: String) -> (String, Violation.Severity)? { nil }
}

/// Último recurso: cualquier lenguaje, una zona por módulo o directorio raíz.
public struct GenericProfile: ArchitectureProfile {
  public init() {}

  public let id = "generic"
  public let name = "Genérico"
  public let languages: Set<String> = []

  public func zone(for info: ArchInfo) -> MapZone {
    MapZone(id: "module:\(info.module)", title: info.module, order: 0)
  }

  public func matchScore(paths: [String]) -> Double { 0.01 }

  public func classify(path: String, facts: SourceFacts?) -> ArchInfo {
    let comps = path.split(separator: "/").map(String.init)
    let module = comps.count > 1 ? comps[0] : "raíz"
    return ArchInfo(module: module, layer: .other, role: .other, context: nil, packageLabel: module, isTest: false)
  }

  public func violation(from: ArchInfo, fromPackage: String, importing fqn: String) -> (String, Violation.Severity)? { nil }
}

/// Catálogo de perfiles. Añadir uno nuevo es solo añadirlo a `all`.
public enum ProfileRegistry {
  public static let all: [ArchitectureProfile] = [
    ItxHexagonalProfile(), RailsProfile(), GenericLayeredJavaProfile(), GenericProfile(),
  ]

  static let languageByExtension: [String: String] = [
    "java": "java", "kt": "kotlin", "kts": "kotlin", "scala": "scala", "py": "python", "ts": "typescript",
    "tsx": "typescript", "js": "javascript", "jsx": "javascript", "go": "go", "swift": "swift",
    "rs": "rust", "cs": "csharp", "rb": "ruby", "rake": "ruby", "jbuilder": "ruby", "php": "php",
  ]

  public static func dominantLanguage(paths: [String]) -> String? {
    var counts: [String: Int] = [:]
    for p in paths {
      if let lang = languageByExtension[(p as NSString).pathExtension.lowercased()] { counts[lang, default: 0] += 1 }
    }
    return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
  }

  public static func detect(paths: [String]) -> ArchitectureProfile {
    func best(_ profiles: [ArchitectureProfile]) -> (ArchitectureProfile, Double)? {
      profiles.map { ($0, $0.matchScore(paths: paths)) }.max { $0.1 < $1.1 }
    }
    if let lang = dominantLanguage(paths: paths),
      let (p, score) = best(all.filter { $0.languages.contains(lang) }), score > 0.2
    {
      return p
    }
    if let (p, score) = best(all), score > 0 { return p }
    return GenericProfile()
  }
}
