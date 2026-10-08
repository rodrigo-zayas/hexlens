import Foundation

public struct ImportDecl: Hashable, Codable, Sendable {
  public let name: String
  public let isStatic: Bool
  public let isWildcard: Bool
  public let line: String
}

public struct TypeDecl: Hashable, Codable, Sendable {
  public let name: String
  public let kind: TypeKind
}

public struct Member: Hashable, Codable, Sendable {
  public let name: String
  /// Nombre + aridad, para casar sobrecargas entre base y cabeza.
  public let key: String
  public let signature: String
  public let startLine: Int
  public let endLine: Int
}

/// Lo que un analizador sabe extraer de un fichero sin compilarlo.
public struct SourceFacts: Hashable, Codable, Sendable {
  public var packageName = ""
  public var imports: [ImportDecl] = []
  public var types: [TypeDecl] = []
  public var primary: TypeDecl?
  public var primaryLine: Int?
  public var annotations: [String] = []
  public var supertypes: [String] = []
  public var identifiers: Set<String> = []
  public var members: [Member] = []

  public init() {}
}

/// Punto de extensión por lenguaje. Hoy solo Java; TypeScript o Kotlin entrarían aquí.
public protocol LanguageAnalyzer: Sendable {
  var language: String { get }
  func handles(_ path: String) -> Bool
  func analyze(path: String, source: String) -> SourceFacts
  /// Ruta de fichero → nombre cualificado, para indexar el repo sin parsearlo.
  func qualifiedName(forPath path: String) -> String?
}
