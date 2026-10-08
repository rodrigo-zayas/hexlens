import Foundation

public enum ChangeStatus: String, Codable, Sendable {
  case added, modified, deleted, renamed, unchanged

  public var letter: String {
    switch self {
    case .added: "A"
    case .modified: "M"
    case .deleted: "D"
    case .renamed: "R"
    case .unchanged: "·"
    }
  }

  public var label: String {
    switch self {
    case .added: "nuevo"
    case .modified: "modificado"
    case .deleted: "borrado"
    case .renamed: "renombrado"
    case .unchanged: "sin cambios"
    }
  }
}

/// Columnas del hexágono, de izquierda a derecha: quien llama → dominio → a quien se llama.
public enum Layer: String, CaseIterable, Codable, Sendable {
  case inbound, application, domain, outbound, config, other

  public var title: String {
    switch self {
    case .inbound: "Entrada"
    case .application: "Aplicación"
    case .domain: "Dominio"
    case .outbound: "Salida"
    case .config: "Configuración"
    case .other: "Otros"
    }
  }

  public var subtitle: String {
    switch self {
    case .inbound: "controllers, consumers, operations"
    case .application: "casos de uso y servicios"
    case .domain: "entidades, puertos, eventos"
    case .outbound: "repositorios, clientes, publishers"
    case .config: "arranque y wiring"
    case .other: "sin capa reconocida"
    }
  }

  public var column: Int { Layer.allCases.firstIndex(of: self)! }
}

public enum Role: String, CaseIterable, Codable, Sendable {
  case entity, port, domainService, event, exception
  case useCase, appService, params
  case controller, consumer, handler, scheduler, operation
  case adapter, client, publisher, infraService, mapper, dto
  case configuration, bootstrap, build, resource, other

  public var label: String {
    switch self {
    case .entity: "modelo"
    case .port: "puerto"
    case .domainService: "servicio de dominio"
    case .event: "evento"
    case .exception: "excepción"
    case .useCase: "caso de uso"
    case .appService: "servicio"
    case .params: "params / respuesta"
    case .controller: "controller"
    case .consumer: "consumer"
    case .handler: "handler / worker"
    case .scheduler: "scheduler"
    case .operation: "operation"
    case .adapter: "adaptador"
    case .client: "cliente"
    case .publisher: "publisher"
    case .infraService: "servicio de infra"
    case .mapper: "mapper"
    case .dto: "DTO"
    case .configuration: "configuración"
    case .bootstrap: "arranque"
    case .build: "build"
    case .resource: "recurso"
    case .other: "otro"
    }
  }

  public var symbol: String {
    switch self {
    case .entity: "cube"
    case .port: "arrow.left.arrow.right.circle"
    case .domainService: "gearshape.2"
    case .event: "bolt"
    case .exception: "exclamationmark.octagon"
    case .useCase: "play.rectangle"
    case .appService: "gearshape"
    case .params: "shippingbox"
    case .controller: "network"
    case .consumer: "tray.and.arrow.down"
    case .handler: "tray.full"
    case .scheduler: "clock"
    case .operation: "wrench.and.screwdriver"
    case .adapter: "externaldrive"
    case .client: "arrow.up.forward.app"
    case .publisher: "paperplane"
    case .infraService: "gearshape"
    case .mapper: "arrow.triangle.swap"
    case .dto: "doc.plaintext"
    case .configuration: "slider.horizontal.3"
    case .bootstrap: "power"
    case .build: "hammer"
    case .resource: "doc"
    case .other: "questionmark.square"
    }
  }

  /// Orden dentro de un paquete: primero lo que define comportamiento, después el andamiaje.
  public var rank: Int { Role.allCases.firstIndex(of: self)! }
}

public enum TypeKind: String, Codable, Sendable {
  case `class`, interface, `enum`, record, annotation, unknown
}

public struct MemberChange: Hashable, Codable, Sendable {
  public enum Change: String, Codable, Sendable { case added, removed, modified }
  public let name: String
  public let signature: String
  public let change: Change
}

/// Un fichero de la PR (o uno sin cambios que da contexto).
public struct CodeUnit: Identifiable, Hashable, Codable, Sendable {
  public var id: String { path }
  public var path: String
  public var oldPath: String?
  public var status: ChangeStatus
  public var additions: Int
  public var deletions: Int
  public var language: String
  public var packageName: String
  public var typeName: String
  public var kind: TypeKind
  public var module: String
  public var layer: Layer
  public var role: Role
  public var context: String?
  public var packageLabel: String
  public var isTest: Bool
  public var component: String? = nil
  public var annotations: [String]
  public var supertypes: [String]
  public var members: [MemberChange]
  public var touchesOutsideMembers: Bool
  /// Contexto sin cambios: `true` si une piezas de la PR o es supertipo de alguna.
  public var isKeyContext: Bool

  public var isGhost: Bool { status == .unchanged }
  public var fqn: String { packageName.isEmpty ? typeName : "\(packageName).\(typeName)" }
  public var fileName: String { (path as NSString).lastPathComponent }
  public var isCode: Bool { language != "other" }
}

public struct Dependency: Identifiable, Hashable, Codable, Sendable {
  public enum Kind: String, Codable, Sendable { case uses, implements, extends, tests }
  public let from: String
  public let to: String
  public let kind: Kind
  public var id: String { "\(from)→\(to)" }
}

public struct Violation: Identifiable, Hashable, Codable, Sendable {
  public enum Severity: String, Codable, Sendable { case error, warning }
  public let unitID: String
  public let imported: String
  public let targetID: String?
  public let message: String
  public let severity: Severity
  /// El import aparece en líneas añadidas por la PR.
  public let introduced: Bool
  public var id: String { "\(unitID)|\(imported)" }
}

public enum ReadingStrategy: String, CaseIterable, Identifiable, Sendable {
  case insideOut, outsideIn, testsFirst, largestFirst

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .insideOut: "Dominio → fuera"
    case .outsideIn: "Entrada → dentro"
    case .testsFirst: "Tests primero"
    case .largestFirst: "Más grande primero"
    }
  }
}

public enum ContextMode: String, CaseIterable, Identifiable, Sendable {
  case none, key, all

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .none: "Solo la PR"
    case .key: "Contexto clave"  // supertipos y lo que une capas
    case .all: "Todo el contexto"
    }
  }
}

extension CodeUnit {
  public var archInfo: ArchInfo {
    ArchInfo(module: module, layer: layer, role: role, context: context, packageLabel: packageLabel, isTest: isTest, component: component)
  }
}
