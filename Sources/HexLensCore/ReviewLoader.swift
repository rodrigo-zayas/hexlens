import Foundation

public struct ReviewSession: Sendable {
  public let repo: GitRepo
  public let title: String
  public let baseRef: String
  public let headRef: String
  public let baseSHA: String
  public let headSHA: String
  public let graph: PRGraph
  public let diffs: [String: FileDiff]
  public let profile: ArchitectureProfile
  public let index: RepoIndex
  public let store: SourceStore

  public var profileName: String { profile.name }

  public func diff(for unit: CodeUnit) -> FileDiff? {
    diffs[unit.path] ?? unit.oldPath.flatMap { diffs[$0] }
  }
}

public enum ReviewLoader {
  public static func load(
    repo: GitRepo, base: String, head: String, title: String? = nil,
    profile: ArchitectureProfile? = nil,
    analyzers: [LanguageAnalyzer] = Analyzers.all,
    progress: (String) -> Void = { _ in }
  ) throws -> ReviewSession {
    let headSHA = try repo.commit(head)
    let baseSHA = try repo.mergeBase(try repo.commit(base), headSHA)

    progress("Calculando el diff…")
    let changes = try repo.changes(from: baseSHA, to: headSHA)
    let diffs = DiffParser.parse(try repo.unifiedDiff(from: baseSHA, to: headSHA))

    let profile = profile ?? ProfileRegistry.detect(paths: changes.map(\.path))

    progress("Analizando \(changes.count) ficheros…")
    let analyzed = changes.map { c in (c, analyzers.first { $0.handles(c.path) }) }
    let headSources = repo.files(analyzed.map { (headSHA, $0.0.path) })
    let baseSources = repo.files(analyzed.map { (baseSHA, $0.0.oldPath ?? $0.0.path) })
    let store = SourceStore(repo: repo)
    for (i, (change, _)) in analyzed.enumerated() {
      store.prime(rev: headSHA, path: change.path, text: headSources[i])
      store.prime(rev: baseSHA, path: change.oldPath ?? change.path, text: baseSources[i])
    }

    var units: [CodeUnit] = []
    var facts: [String: SourceFacts] = [:]
    for (i, (change, analyzer)) in analyzed.enumerated() {
      let headFacts = change.status == .deleted ? nil : headSources[i].flatMap { s in analyzer?.analyze(path: change.path, source: s) }
      let baseFacts = change.status == .added ? nil : baseSources[i].flatMap { s in analyzer?.analyze(path: change.oldPath ?? change.path, source: s) }
      let f = headFacts ?? baseFacts
      let info = profile.classify(path: change.path, facts: f)
      let diff = diffs[change.path] ?? change.oldPath.flatMap { diffs[$0] }
      let (members, outside) = memberChanges(head: headFacts, base: baseFacts, diff: diff)
      let stem = ((change.path as NSString).lastPathComponent as NSString).deletingPathExtension
      units.append(CodeUnit(
        path: change.path, oldPath: change.oldPath, status: change.status,
        additions: change.additions, deletions: change.deletions,
        language: f == nil ? "other" : (analyzer?.language ?? "other"),
        packageName: f?.packageName ?? "", typeName: f?.primary?.name ?? (f == nil ? (change.path as NSString).lastPathComponent : stem),
        kind: f?.primary?.kind ?? .unknown, module: info.module, layer: info.layer, role: info.role,
        context: info.context, packageLabel: info.packageLabel, isTest: info.isTest, component: info.component,
        annotations: f?.annotations ?? [], supertypes: f?.supertypes ?? [],
        members: members, touchesOutsideMembers: outside, isKeyContext: false))
      if let f { facts[change.path] = f }
    }

    progress("Enlazando con el resto del repositorio…")
    let index = RepoIndex(paths: try repo.files(at: headSHA), analyzers: analyzers)
    let graph = GraphBuilder(
      repo: repo, headSHA: headSHA, units: units, facts: facts, diffs: diffs,
      profile: profile, analyzers: analyzers, index: index
    ).build()

    return ReviewSession(
      repo: repo, title: title ?? "\(base) … \(head)", baseRef: base, headRef: head,
      baseSHA: baseSHA, headSHA: headSHA, graph: graph, diffs: diffs,
      profile: profile, index: index, store: store)
  }

  /// Métodos tocados: cruza las líneas cambiadas con los rangos de cada miembro en base y cabeza.
  static func memberChanges(head: SourceFacts?, base: SourceFacts?, diff: FileDiff?) -> ([MemberChange], Bool) {
    guard let diff else { return ([], false) }
    let added = diff.addedLineNumbers
    let removed = diff.removedLineNumbers
    let headMembers = head?.members ?? []
    let baseMembers = base?.members ?? []

    var touched = Set<String>()
    var covered = (added: Set<Int>(), removed: Set<Int>())
    for m in headMembers {
      let hits = added.filter { (m.startLine...m.endLine).contains($0) }
      if !hits.isEmpty { touched.insert(m.key); covered.added.formUnion(hits) }
    }
    for m in baseMembers {
      let hits = removed.filter { (m.startLine...m.endLine).contains($0) }
      if !hits.isEmpty { touched.insert(m.key); covered.removed.formUnion(hits) }
    }

    let headKeys = Set(headMembers.map(\.key))
    let baseKeys = Set(baseMembers.map(\.key))
    var seen = Set<String>()
    var result: [MemberChange] = []
    for m in headMembers where touched.contains(m.key) && seen.insert(m.key).inserted {
      result.append(MemberChange(name: m.name, signature: m.signature, change: baseKeys.contains(m.key) ? .modified : .added))
    }
    for m in baseMembers where touched.contains(m.key) && !headKeys.contains(m.key) && seen.insert(m.key).inserted {
      result.append(MemberChange(name: m.name, signature: m.signature, change: .removed))
    }
    // Mismo nombre añadido y quitado = cambio de firma.
    let removedNames = Set(result.filter { $0.change == .removed }.map(\.name))
    let addedNames = Set(result.filter { $0.change == .added }.map(\.name))
    let resigned = removedNames.intersection(addedNames)
    result = result.compactMap { m in
      guard resigned.contains(m.name) else { return m }
      return m.change == .added ? MemberChange(name: m.name, signature: m.signature, change: .modified) : nil
    }
    let outside = !added.subtracting(covered.added).isEmpty || !removed.subtracting(covered.removed).isEmpty
    return (result, outside)
  }
}
