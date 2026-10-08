import Foundation

/// Tipos del repo en la cabeza de la PR: nombre cualificado → ruta. Base de la navegación.
public struct RepoIndex: Sendable {
  public private(set) var pathByFQN: [String: String] = [:]
  public private(set) var namesByPackage: [String: Set<String>] = [:]
  public private(set) var pathsBySimpleName: [String: [String]] = [:]

  public init() {}

  public init(paths: [String], analyzers: [LanguageAnalyzer]) {
    for path in paths {
      if let fqn = analyzers.first(where: { $0.handles(path) })?.qualifiedName(forPath: path) { register(fqn, path: path) }
    }
  }

  public mutating func register(_ fqn: String, path: String) {
    guard pathByFQN[fqn] == nil else { return }
    pathByFQN[fqn] = path
    let (pkg, name) = Self.split(fqn)
    namesByPackage[pkg, default: []].insert(name)
    pathsBySimpleName[name, default: []].append(path)
  }

  /// Ruta del tipo `name` tal como lo ve un fichero (imports, wildcards y mismo paquete).
  public func resolve(_ name: String, from facts: SourceFacts) -> String? {
    for imp in facts.imports where !imp.isStatic {
      if imp.isWildcard {
        let pkg = String(imp.name.dropLast(2))
        if namesByPackage[pkg]?.contains(name) == true { return pathByFQN["\(pkg).\(name)"] }
      } else if imp.name == name || imp.name.hasSuffix(".\(name)") {
        return enclosing(imp.name)
      }
    }
    // Tipo anidado de un import: Outer.Inner
    for imp in facts.imports where !imp.isStatic && !imp.isWildcard {
      if let p = pathByFQN["\(imp.name).\(name)"] { return p }
    }
    let local = facts.packageName.isEmpty ? name : "\(facts.packageName).\(name)"
    return pathByFQN[local]
  }

  /// `a.b.Outer.Inner` → fichero de `a.b.Outer`.
  public func enclosing(_ fqn: String) -> String? {
    var n = fqn
    while !n.isEmpty {
      if let p = pathByFQN[n] { return p }
      guard let dot = n.lastIndex(of: ".") else { return nil }
      n = String(n[..<dot])
    }
    return nil
  }

  static func split(_ fqn: String) -> (String, String) {
    guard let dot = fqn.lastIndex(of: ".") else { return ("", fqn) }
    return (String(fqn[..<dot]), String(fqn[fqn.index(after: dot)...]))
  }
}
