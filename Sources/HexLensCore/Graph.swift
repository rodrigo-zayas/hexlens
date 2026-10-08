import Foundation

public struct PRGraph: Sendable {
  public let units: [CodeUnit]
  public let edges: [Dependency]
  public let violations: [Violation]
  public let subjectByTest: [String: String]
  /// Pieza de la PR con más conexiones dentro de la PR: buen punto de entrada.
  public let entryPoint: String?
  private let index: [String: Int]
  private let outgoingByID: [String: [Dependency]]
  private let incomingByID: [String: [Dependency]]

  public init(units: [CodeUnit], edges: [Dependency], violations: [Violation], subjectByTest: [String: String]) {
    self.units = units
    self.edges = edges
    self.violations = violations
    self.subjectByTest = subjectByTest
    index = Dictionary(units.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    outgoingByID = Dictionary(grouping: edges, by: \.from)
    incomingByID = Dictionary(grouping: edges, by: \.to)

    entryPoint = Self.salient(units: units, outgoing: outgoingByID, incoming: incomingByID)
  }

  private static func salient(units: [CodeUnit], outgoing: [String: [Dependency]], incoming: [String: [Dependency]]) -> String? {
    let changedIDs = Set(units.filter { !$0.isGhost }.map(\.id))
    func score(_ u: CodeUnit) -> (Int, Int) {
      let out = (outgoing[u.id] ?? []).filter { changedIDs.contains($0.to) && $0.kind != .tests }.count
      let inc = (incoming[u.id] ?? []).filter { changedIDs.contains($0.from) && $0.kind != .tests }.count
      return (out + inc, u.additions + u.deletions)
    }
    return units.filter { !$0.isGhost && !$0.isTest && $0.isCode }.max { score($0) < score($1) }?.id
  }

  public func unit(_ id: String) -> CodeUnit? { index[id].map { units[$0] } }
  public func outgoing(_ id: String) -> [Dependency] { outgoingByID[id] ?? [] }
  public func incoming(_ id: String) -> [Dependency] { incomingByID[id] ?? [] }
  public func violations(of id: String) -> [Violation] { violations.filter { $0.unitID == id } }
  public func tests(of id: String) -> [String] { subjectByTest.filter { $0.value == id }.map(\.key).sorted() }
  public var changed: [CodeUnit] { units.filter { !$0.isGhost } }

  // MARK: - Orden de lectura

  /// Ficheros de la PR en el orden sugerido. Cada test va pegado a la clase que prueba.
  public func readingOrder(_ strategy: ReadingStrategy) -> [String] {
    let changed = units.filter { !$0.isGhost }
    let primaries = changed.filter { $0.isCode && !$0.isTest }
    let orphanTests = changed.filter { $0.isCode && $0.isTest && subjectByTest[$0.id] == nil }
    let nonCode = changed.filter { !$0.isCode }

    var ordered: [String]
    switch strategy {
    case .largestFirst:
      ordered = primaries.sorted { ($0.additions + $0.deletions, $1.fqn) > ($1.additions + $1.deletions, $0.fqn) }.map(\.id)
    case .insideOut, .testsFirst:
      ordered = layered(primaries, ranks: [.domain, .application, .outbound, .inbound, .config, .other], dependenciesFirst: true)
    case .outsideIn:
      ordered = layered(primaries, ranks: [.inbound, .application, .domain, .outbound, .config, .other], dependenciesFirst: false)
    }

    var result: [String] = []
    if strategy == .testsFirst { result += orphanTests.map(\.id).sorted() }
    for id in ordered {
      let tests = self.tests(of: id)
      result += strategy == .testsFirst ? tests + [id] : [id] + tests
    }
    if strategy != .testsFirst { result += orphanTests.map(\.id).sorted() }
    return result + nonCode.map(\.id).sorted()
  }

  private func layered(_ units: [CodeUnit], ranks: [Layer], dependenciesFirst: Bool) -> [String] {
    let byLayer = Dictionary(grouping: units, by: \.layer)
    return ranks.flatMap { layer in topological(byLayer[layer] ?? [], dependenciesFirst: dependenciesFirst) }
  }

  /// Kahn dentro de una capa; empates por rol, paquete y nombre. Los ciclos se rompen por el menor.
  private func topological(_ units: [CodeUnit], dependenciesFirst: Bool) -> [String] {
    let ids = Set(units.map(\.id))
    func tie(_ a: CodeUnit, _ b: CodeUnit) -> Bool {
      (a.role.rank, a.packageName, a.typeName) < (b.role.rank, b.packageName, b.typeName)
    }
    var pending: [String: Set<String>] = [:]
    for u in units {
      let deps = dependenciesFirst
        ? outgoing(u.id).map(\.to) : incoming(u.id).map(\.from)
      pending[u.id] = Set(deps).intersection(ids).subtracting([u.id])
    }
    var remaining = units.sorted(by: tie)
    var result: [String] = []
    while !remaining.isEmpty {
      let pick = remaining.firstIndex { pending[$0.id]!.isEmpty } ?? 0
      let next = remaining.remove(at: pick)
      result.append(next.id)
      for k in pending.keys { pending[k]!.remove(next.id) }
    }
    return result
  }
}

struct GraphBuilder {
  let repo: GitRepo
  let headSHA: String
  var units: [CodeUnit]
  let facts: [String: SourceFacts]
  let diffs: [String: FileDiff]
  let profile: ArchitectureProfile
  let analyzers: [LanguageAnalyzer]
  let index: RepoIndex
  var maxGhosts = 250

  func build() -> PRGraph {
    // Índice del repo en la cabeza: nombre cualificado → ruta.
    var pathByFQN = index.pathByFQN
    var namesByPackage = index.namesByPackage
    func register(_ fqn: String, _ path: String) {
      pathByFQN[fqn] = pathByFQN[fqn] ?? path
      let (pkg, name) = Self.split(fqn)
      namesByPackage[pkg, default: []].insert(name)
    }

    var changedByFQN: [String: String] = [:]
    for u in units where u.isCode {
      for t in facts[u.id]?.types ?? [] {
        let fqn = u.packageName.isEmpty ? t.name : "\(u.packageName).\(t.name)"
        changedByFQN[fqn] = changedByFQN[fqn] ?? u.id
        register(fqn, u.id)
      }
    }

    func resolve(_ f: SourceFacts) -> Set<String> {
      var out = Set<String>()
      func add(_ name: String) {
        // a.b.Outer.Inner → a.b.Outer si Inner no es un fichero.
        var n = name
        while !n.isEmpty {
          if pathByFQN[n] != nil { out.insert(n); return }
          guard let dot = n.lastIndex(of: ".") else { return }
          n = String(n[..<dot])
        }
      }
      for imp in f.imports {
        if imp.isWildcard {
          let pkg = String(imp.name.dropLast(2))
          if imp.isStatic { add(pkg); continue }
          for name in (namesByPackage[pkg] ?? []).intersection(f.identifiers) { add("\(pkg).\(name)") }
        } else {
          add(imp.name)
        }
      }
      for name in (namesByPackage[f.packageName] ?? []).intersection(f.identifiers) {
        add(f.packageName.isEmpty ? name : "\(f.packageName).\(name)")
      }
      return out
    }

    var edges: [String: Dependency] = [:]
    func link(_ from: CodeUnit, _ to: String, _ fqn: String, _ toKind: TypeKind, _ fromFacts: SourceFacts) {
      guard from.id != to else { return }
      let name = Self.split(fqn).1
      var kind = Dependency.Kind.uses
      if fromFacts.supertypes.contains(name) {
        kind = toKind == .interface && from.kind != .interface ? .implements : .extends
      }
      let key = "\(from.id)→\(to)"
      if let existing = edges[key], existing.kind != .uses { return }
      edges[key] = Dependency(from: from.id, to: to, kind: kind)
    }

    // Aristas entre piezas de la PR y candidatos a contexto.
    var ghostReferrers: [String: Set<String>] = [:]
    var ghostIsSupertype: Set<String> = []
    let unitByID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for u in units where u.isCode {
      guard let f = facts[u.id] else { continue }
      for fqn in resolve(f) {
        if let target = changedByFQN[fqn] {
          link(u, target, fqn, unitByID[target]?.kind ?? .unknown, f)
        } else if !u.isTest {
          ghostReferrers[fqn, default: []].insert(u.id)
          if f.supertypes.contains(Self.split(fqn).1) { ghostIsSupertype.insert(fqn) }
        }
      }
    }

    // Contexto sin cambios: primero lo que une piezas o es supertipo.
    let ranked = ghostReferrers.keys.sorted {
      let a = (ghostIsSupertype.contains($0) || ghostReferrers[$0]!.count > 1, ghostReferrers[$0]!.count)
      let b = (ghostIsSupertype.contains($1) || ghostReferrers[$1]!.count > 1, ghostReferrers[$1]!.count)
      return a.0 != b.0 ? a.0 : a.1 != b.1 ? a.1 > b.1 : $0 < $1
    }.prefix(maxGhosts)
    let ghostPaths = ranked.compactMap { pathByFQN[$0] }
    let sources = repo.files(ghostPaths.map { (headSHA, $0) })
    var allUnits = units
    for (fqn, (path, source)) in zip(ranked, zip(ghostPaths, sources)) {
      guard let analyzer = analyzers.first(where: { $0.handles(path) }) else { continue }
      let f = source.map { analyzer.analyze(path: path, source: $0) }
      let info = profile.classify(path: path, facts: f)
      let referrers = ghostReferrers[fqn]!
      let ghost = CodeUnit(
        path: path, oldPath: nil, status: .unchanged, additions: 0, deletions: 0,
        language: analyzer.language, packageName: f?.packageName ?? Self.split(fqn).0,
        typeName: f?.primary?.name ?? Self.split(fqn).1, kind: f?.primary?.kind ?? .unknown,
        module: info.module, layer: info.layer, role: info.role, context: info.context,
        packageLabel: info.packageLabel, isTest: info.isTest, component: info.component, annotations: f?.annotations ?? [],
        supertypes: f?.supertypes ?? [], members: [], touchesOutsideMembers: false,
        isKeyContext: ghostIsSupertype.contains(fqn)
          || Set(referrers.compactMap { unitByID[$0]?.layer }).count > 1)
      allUnits.append(ghost)
      for r in referrers {
        if let from = unitByID[r], let ff = facts[r] { link(from, path, fqn, ghost.kind, ff) }
      }
      // Contexto que a su vez usa piezas de la PR (p.ej. un caso de uso sin cambios que usa un puerto cambiado).
      if let f {
        for targetFQN in resolve(f) {
          if let target = changedByFQN[targetFQN] {
            link(ghost, target, targetFQN, unitByID[target]?.kind ?? .unknown, f)
          }
        }
      }
    }

    // Tests → clase probada.
    var subjectByTest: [String: String] = [:]
    for t in units where t.isTest && t.isCode {
      guard let subject = ItxHexagonalProfile.testSubject(of: t.typeName) else { continue }
      let candidates = units.filter { !$0.isTest && $0.typeName == subject }
      if let s = candidates.first(where: { $0.packageName == t.packageName }) ?? candidates.first {
        subjectByTest[t.id] = s.id
        edges["\(t.id)→\(s.id)"] = Dependency(from: t.id, to: s.id, kind: .tests)
      }
    }

    // Reglas de dependencia sobre los imports de la PR.
    var violations: [Violation] = []
    for u in units where u.isCode && !u.isTest && u.status != .deleted {
      guard let f = facts[u.id] else { continue }
      let info = ArchInfo(
        module: u.module, layer: u.layer, role: u.role, context: u.context,
        packageLabel: u.packageLabel, isTest: false, component: u.component)
      let added = diffs[u.id]?.addedText ?? []
      for imp in f.imports {
        var fqn = imp.isWildcard ? String(imp.name.dropLast(2)) : imp.name
        if imp.isStatic && !imp.isWildcard, let dot = fqn.lastIndex(of: ".") { fqn = String(fqn[..<dot]) }
        guard let (message, severity) = profile.violation(from: info, fromPackage: u.packageName, importing: fqn) else { continue }
        violations.append(Violation(
          unitID: u.id, imported: fqn, targetID: changedByFQN[fqn] ?? pathByFQN[fqn],
          message: message, severity: severity,
          introduced: u.status == .added || added.contains(imp.line)))
      }
    }

    return PRGraph(
      units: allUnits, edges: Array(edges.values).sorted { $0.id < $1.id },
      violations: violations, subjectByTest: subjectByTest)
  }

  static func split(_ fqn: String) -> (String, String) {
    guard let dot = fqn.lastIndex(of: ".") else { return ("", fqn) }
    return (String(fqn[..<dot]), String(fqn[fqn.index(after: dot)...]))
  }
}
