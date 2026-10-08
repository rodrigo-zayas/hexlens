import Foundation

/// Rails con autoload Zeitwerk: `app/<tipo>/<namespace>/<clase>.rb`, `lib/<integración>/…`,
/// `config/`, `db/` y `spec/`. Se agrupa por tipo de directorio y namespace de primer nivel.
public struct RailsProfile: ArchitectureProfile {
  public init() {}

  public let id = "rails"
  public let name = "Ruby on Rails"
  public let languages: Set<String> = ["ruby"]

  static let entryZone = MapZone(id: "entry", title: "Entrada", order: 1, subtitle: "API y eventos")
  static let jobsZone = MapZone(id: "jobs", title: "Jobs", order: 2, subtitle: "Sidekiq / ActiveJob")
  static let servicesZone = MapZone(id: "services", title: "Servicios / Dominio", order: 3, subtitle: "lógica y policies")
  static let modelsZone = MapZone(id: "models", title: "Modelos", order: 4, subtitle: "ActiveRecord")
  static let outputZone = MapZone(id: "output", title: "Salida", order: 5, subtitle: "integraciones")
  static let configZone = MapZone(id: "config", title: "Configuración / BD", order: 6, subtitle: "config, rutas y migraciones")
  static let otherZone = MapZone(id: "other", title: "Otros", order: 7, subtitle: "sin capa reconocida")

  public func zone(for info: ArchInfo) -> MapZone {
    if info.role == .job { return Self.jobsZone }
    switch info.layer {
    case .inbound: return Self.entryZone
    case .application: return Self.servicesZone
    case .domain: return Self.modelsZone
    case .outbound: return Self.outputZone
    case .config: return Self.configZone
    case .other: return Self.otherZone
    }
  }

  public func matchScore(paths: [String]) -> Double {
    let railsMarkers = ["app/models/", "app/controllers/", "app/services/"]
    if paths.contains(where: { p in railsMarkers.contains { p.hasPrefix($0) || p.contains("/" + $0) } || p.hasSuffix("config/routes.rb") }) {
      return 0.9
    }
    return paths.contains { $0.hasSuffix(".rb") } ? 0.3 : 0
  }

  // MARK: - Clasificación

  static let appDirs: [String: (Layer, Role)] = [
    "controllers": (.inbound, .controller), "views": (.inbound, .resource), "channels": (.inbound, .handler),
    "consumers": (.inbound, .consumer), "listeners": (.inbound, .handler),
    "jobs": (.application, .job), "workers": (.application, .job),
    "services": (.application, .appService), "policies": (.application, .policy),
    "models": (.domain, .entity),
    "producers": (.outbound, .publisher), "mailers": (.outbound, .publisher),
  ]
  static let libDirs: [String: (Layer, Role)] = [
    "api_clients": (.outbound, .client), "pub_sub": (.outbound, .publisher),
    "ftp": (.outbound, .client), "microsoft_graph": (.outbound, .client),
  ]
  /// Directorio de `app/` al que pertenece cada tipo de spec.
  static let specDirs: [String: String] = [
    "requests": "controllers", "controllers": "controllers", "features": "controllers", "routing": "controllers",
    "system": "controllers", "views": "views", "models": "models", "services": "services", "jobs": "jobs",
    "workers": "workers", "consumers": "consumers", "listeners": "listeners", "channels": "channels",
    "policies": "policies", "producers": "producers", "mailers": "mailers",
  ]

  struct Location {
    var dir: String
    var namespace: [String]
    var tail: [String]
    var isLib = false
  }

  static func isTestPath(_ comps: [String]) -> Bool {
    guard let last = comps.last else { return false }
    return comps.first == "spec" || comps.first == "test" || last.hasSuffix("_spec.rb")
  }

  /// Tipo de directorio y directorios que cuelgan de él, con el spec reflejado sobre `app/`.
  static func location(of comps: [String]) -> Location? {
    var comps = comps
    if comps.first == "spec" || comps.first == "test" {
      guard comps.count > 2, let dir = specDirs[comps[1]] else {
        if comps.count > 2, comps[1] == "lib" { comps = Array(comps.dropFirst()) } else { return nil }
        return location(of: comps)
      }
      comps = ["app", dir] + comps.dropFirst(2)
    }
    var dirs = Array(comps.dropLast())
    if let i = dirs.firstIndex(of: "app"), i + 1 < dirs.count {
      let dir = dirs[i + 1]
      guard dir != "javascript", dir != "assets" else { return nil }
      dirs = Array(dirs[(i + 2)...])
      return Location(dir: dir, namespace: dirs.filter { $0 != "concerns" }, tail: dirs)
    }
    if let i = dirs.firstIndex(of: "lib") {
      let rest = Array(dirs[(i + 1)...])
      guard let first = rest.first else { return Location(dir: "lib", namespace: [], tail: [], isLib: true) }
      return Location(dir: first, namespace: Array(rest.dropFirst()), tail: Array(rest.dropFirst()), isLib: true)
    }
    return nil
  }

  public func classify(path: String, facts: SourceFacts?) -> ArchInfo {
    let comps = path.split(separator: "/").map(String.init)
    let isTest = Self.isTestPath(comps)
    func info(_ layer: Layer, _ role: Role, module: String, component: String? = nil, context: String? = nil, label: String? = nil)
      -> ArchInfo
    {
      ArchInfo(
        module: module, layer: layer, role: role, context: context, packageLabel: label ?? component ?? module,
        isTest: isTest, component: component)
    }

    if let loc = Self.location(of: comps) {
      let known = loc.isLib ? Self.libDirs[loc.dir] : Self.appDirs[loc.dir]
      let (layer, role) = known ?? (.other, .other)
      let shown = Self.displayNamespace(loc.namespace)
      let component = shown.name.isEmpty ? loc.dir : "\(loc.dir) · \(shown.name)"
      let next = loc.namespace.dropFirst(shown.consumed).first
      return info(
        layer, role, module: component, component: component, context: next,
        label: shown.name.isEmpty ? loc.dir : shown.name)
    }
    let first = comps.first ?? ""
    switch first {
    case "config": return info(.config, .configuration, module: "config", component: "config")
    case "db": return info(.config, .resource, module: "db", component: "db")
    default:
      let file = comps.last ?? path
      if ["Gemfile", "Gemfile.lock", "Rakefile", "config.ru"].contains(file) || file.hasSuffix(".gemspec") {
        return info(.config, .build, module: "raíz", component: "raíz")
      }
      return info(.other, .other, module: comps.count > 1 ? first : "raíz")
    }
  }

  /// `["dam", "v1", "cards"]` → `Dam::V1` (versiones de API incluidas); `["flow", "cards"]` → `Flow`.
  static func displayNamespace(_ namespace: [String]) -> (name: String, consumed: Int) {
    guard let first = namespace.first else { return ("", 0) }
    var parts = [RubyAnalyzer.camelize(first)]
    if namespace.count > 1, namespace[1].range(of: #"^v\d+$"#, options: .regularExpression) != nil {
      parts.append(RubyAnalyzer.camelize(namespace[1]))
    }
    return (parts.joined(separator: "::"), parts.count)
  }

  // MARK: - Reglas

  public func violation(from: ArchInfo, fromPackage: String, importing fqn: String) -> (String, Violation.Severity)? {
    let name = fqn.split(separator: ".").last.map(String.init) ?? fqn
    if from.role == .entity {
      if name.hasSuffix("Controller") { return ("Un modelo no debería depender de un controller", .error) }
      if name.hasSuffix("Job") { return ("Un modelo no debería depender de un job", .error) }
    }
    if from.role == .appService, name.hasSuffix("Controller") {
      return ("Un servicio no debería depender de un controller", .warning)
    }
    return nil
  }

  // MARK: - Tests

  /// `spec/services/flow/x_spec.rb` → `app/services/flow/x.rb`; `spec/requests/dam/v1/y_spec.rb` →
  /// `app/controllers/dam/v1/y_controller.rb`.
  public func testSubject(of test: CodeUnit, among units: [CodeUnit]) -> CodeUnit? {
    let comps = test.path.split(separator: "/").map(String.init)
    guard comps.count > 2, comps.first == "spec" || comps.first == "test" else {
      return nil
    }
    var file = comps.last ?? ""
    for suffix in ["_spec.rb", "_test.rb"] where file.hasSuffix(suffix) { file = String(file.dropLast(suffix.count)) }
    let key = (comps[2..<(comps.count - 1)] + [file]).joined(separator: "/")
    let appDir = Self.specDirs[comps[1]]
    let wanted = [key + ".rb", key + "_controller.rb"]
    let candidates = units.filter { u in
      guard !u.isTest, u.isCode, u.status != .deleted else { return false }
      let p = u.path
      guard wanted.contains(where: { p.hasSuffix("/" + $0) || p == $0 }) else { return false }
      if let appDir { return p.contains("app/\(appDir)/") }
      return p.contains("lib/") || p.contains("app/")
    }
    return candidates.first
  }
}
