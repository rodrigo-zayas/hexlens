import AppKit
import HexLensCore
import SwiftUI

public enum CenterMode: String, CaseIterable, Identifiable {
  case flows, map
  public var id: String { rawValue }
  public var title: String { self == .flows ? "Flujos" : "Mapa" }
}

/// Modelo de Claude por ID explícito, para saber siempre qué versión corre.
public struct ClaudeModel: Hashable, Identifiable {
  /// "" = lo que tenga configurado el Claude Code del usuario.
  public let id: String
  public let name: String
  public let hint: String

  public static let automatic = ClaudeModel(id: "", name: "Por defecto", hint: "")
  public static let catalog: [ClaudeModel] = [
    ClaudeModel(id: "claude-fable-5-1", name: "Fable 5.1", hint: "el más capaz"),
    ClaudeModel(id: "claude-opus-5-5", name: "Opus 5.5", hint: "profundo"),
    ClaudeModel(id: "claude-sonnet-5-5", name: "Sonnet 5.5", hint: "equilibrado"),
    ClaudeModel(id: "claude-opus-5", name: "Opus 5", hint: "generación anterior"),
    ClaudeModel(id: "claude-sonnet-5", name: "Sonnet 5", hint: "generación anterior"),
    ClaudeModel(id: "claude-haiku-4-5-20251001", name: "Haiku 4.5", hint: "rápido y barato"),
  ]
  static let aliases = ["fable": "claude-fable-5-1", "opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-4-5-20251001"]

  /// Nombre legible de un ID o alias (`claude-opus-5-5` → "Opus 5.5"); si no se conoce, el propio ID.
  public static func displayName(_ raw: String) -> String {
    let base = raw.replacingOccurrences(of: "[1m]", with: "")
    let id = aliases[base] ?? base
    let name = catalog.first { $0.id == id }?.name ?? id
    return raw.hasSuffix("[1m]") ? "\(name) · 1M" : name
  }

  /// Modelo configurado en `~/.claude/settings.json`, para etiquetar "Por defecto".
  public static var configuredDefault: String? {
    for file in ["settings.local.json", "settings.json"] {
      let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/\(file)")
      if let data = try? Data(contentsOf: url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let model = json["model"] as? String
      {
        return model
      }
    }
    return nil
  }

  public var label: String {
    if id.isEmpty { return "Por defecto (\(Self.configuredDefault.map(Self.displayName) ?? "el de tu plan"))" }
    return Self.catalog.contains(self) ? "\(name) — \(hint)" : "\(id) (personalizado)"
  }
}

public enum AppAppearance: String, CaseIterable, Identifiable {
  case dark, light, system
  public var id: String { rawValue }
  public var title: String { self == .dark ? "Oscuro" : self == .light ? "Claro" : "Sistema" }
  public var scheme: ColorScheme? { self == .dark ? .dark : self == .light ? .light : nil }
}

/// Fichero (y línea) que enseña el visor de código.
public struct CodeLocation: Hashable {
  public let path: String
  public var line: Int?
}

@MainActor
public final class AppModel: ObservableObject {
  @Published public private(set) var repo: GitRepo?
  @Published public private(set) var recentRepos: [String] = UserDefaults.standard.stringArray(forKey: "recentRepos") ?? []
  @Published public var prFilter: PRFilter = .reviewRequested { didSet { refreshPRs() } }
  @Published public private(set) var pullRequests: [PullRequestSummary] = []
  @Published public private(set) var loadingPRs = false
  @Published public private(set) var session: ReviewSession?
  @Published public private(set) var currentPR: PullRequestSummary?
  /// Rama contra la que se compara la PR abierta, si no es su base real.
  @Published public private(set) var baseOverride: String?
  @Published public private(set) var selectedID: String?
  @Published public var hoveredID: String?
  @Published public private(set) var busy: String?
  @Published public var errorMessage: String?
  @Published public var showPRPicker = false
  @Published public var showTests = false { didSet { relayout() } }
  @Published public var contextMode: ContextMode = .none { didSet { relayout() } }
  @Published public var strategy: ReadingStrategy = .insideOut { didSet { recomputeOrder() } }
  @Published public var centerMode: CenterMode = .flows
  @Published public var zoom: CGFloat = 1
  @Published public var appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark {
    didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
  }
  /// Columnas visibles: por defecto flujos + código; "solo código" deja el visor a pantalla completa.
  @Published public var columns: NavigationSplitViewVisibility = .doubleColumn
  public func toggleCodeOnly() { columns = columns == .detailOnly ? .doubleColumn : .detailOnly }
  @Published public private(set) var layout = GraphLayout()
  @Published public private(set) var order: [String] = []
  @Published public private(set) var reviewed: Set<String> = []
  @Published public private(set) var impact: [String: [String]] = [:]

  // Visor de código
  @Published public private(set) var location: CodeLocation?
  @Published public private(set) var backStack: [CodeLocation] = []
  @Published public private(set) var forwardStack: [CodeLocation] = []
  @Published public var fullFile = true
  @Published private(set) var scrollRequest: ScrollRequest?
  private var scrollSerial = 0

  // Búsqueda en el visor (⌘F)
  @Published var findVisible = false
  @Published var findQuery = ""
  @Published var findCaseSensitive = false
  @Published var findWholeWord = false
  @Published var findIndex = 0
  @Published private(set) var findFocusSerial = 0

  var findMatches: [NSRange] {
    guard findVisible, let path = location?.path, let c = content(for: path) else { return [] }
    return TextSearch.matches(of: findQuery, in: c.document.text, caseSensitive: findCaseSensitive, wholeWord: findWholeWord)
  }

  func showFind() { findVisible = true; findFocusSerial += 1 }
  func closeFind() { findVisible = false }
  func findNext() { stepFind(1) }
  func findPrevious() { stepFind(-1) }

  private func stepFind(_ d: Int) {
    guard findVisible else { return showFind() }
    let n = findMatches.count
    guard n > 0 else { return }
    findIndex = ((findIndex + d) % n + n) % n
  }
  private var contentCache: [String: CodeContent] = [:]

  // Flujos
  @Published public private(set) var flows: [FlowNode]?
  @Published public var flowsOnlyChanges = true

  @Published public var claudeModelID = UserDefaults.standard.string(forKey: "claudeModelID") ?? "" {
    didSet { UserDefaults.standard.set(claudeModelID, forKey: "claudeModelID") }
  }
  public var claudeModel: ClaudeModel {
    ClaudeModel.catalog.first { $0.id == claudeModelID }
      ?? (claudeModelID.isEmpty ? .automatic : ClaudeModel(id: claudeModelID, name: claudeModelID, hint: ""))
  }

  public init() {}

  public var graph: PRGraph? { session?.graph }
  public var selected: CodeUnit? { selectedID.flatMap { graph?.unit($0) } }
  public var changedCount: Int { order.count }
  public var reviewedCount: Int { order.filter(reviewed.contains).count }

  // MARK: - Repositorio y PRs

  public func chooseRepository() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Abrir"
    panel.message = "Elige un repositorio git"
    if panel.runModal() == .OK, let url = panel.url { openRepository(url) }
  }

  public func openRepository(_ url: URL) {
    do {
      let repo = try GitRepo(at: url)
      self.repo = repo
      recentRepos = [repo.root.path] + recentRepos.filter { $0 != repo.root.path }.prefix(7)
      UserDefaults.standard.set(recentRepos, forKey: "recentRepos")
      session = nil
      currentPR = nil
      selectedID = nil
      location = nil
      showPRPicker = true
      refreshPRs()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  public func refreshPRs() {
    guard let repo else { return }
    loadingPRs = true
    let filter = prFilter
    Task.detached {
      let result = Result { try GitHub.pullRequests(in: repo, filter: filter) }
      await MainActor.run {
        self.loadingPRs = false
        switch result {
        case .success(let prs): self.pullRequests = prs
        case .failure(let e): self.pullRequests = []; self.errorMessage = "gh: \(e.localizedDescription)"
        }
      }
    }
  }

  public func open(_ pr: PullRequestSummary, base override: String? = nil) {
    guard let repo else { return }
    showPRPicker = false
    let override = override == pr.baseRefName ? nil : override
    baseOverride = override
    busy = "Descargando la PR #\(pr.number)\(override.map { " contra \($0)" } ?? "")…"
    Task.detached {
      do {
        let (base, head) = try GitHub.fetch(pr, into: repo, baseOverride: override)
        let title = "#\(pr.number) \(pr.title)" + (override.map { "  ·  contra \($0)" } ?? "")
        await self.load(repo: repo, base: base, head: head, title: title, pr: pr)
      } catch {
        await MainActor.run { self.fail(error) }
      }
    }
  }

  public func openPR(number: Int, base override: String? = nil) {
    guard let repo else { return }
    busy = "Buscando la PR #\(number)…"
    Task.detached {
      do {
        let pr = try GitHub.pullRequest(number, in: repo)
        await MainActor.run { self.open(pr, base: override) }
      } catch {
        await MainActor.run { self.fail(error) }
      }
    }
  }

  public func compare(base: String, head: String) {
    guard let repo else { return }
    showPRPicker = false
    Task.detached { await self.load(repo: repo, base: base, head: head, title: "\(base) … \(head)", pr: nil) }
  }

  public func reload() {
    if let pr = currentPR { open(pr, base: baseOverride) } else if let s = session { compare(base: s.baseRef, head: s.headRef) }
  }

  nonisolated private func load(repo: GitRepo, base: String, head: String, title: String, pr: PullRequestSummary?) async {
    await MainActor.run { self.busy = "Analizando…" }
    do {
      let session = try ReviewLoader.load(repo: repo, base: base, head: head, title: title) { message in
        Task { @MainActor in self.busy = message }
      }
      await MainActor.run { self.present(session, pr: pr) }
      let flows = FlowBuilder.build(session: session)
      await MainActor.run { if self.session?.headSHA == session.headSHA { self.flows = flows } }
    } catch {
      await MainActor.run { self.fail(error) }
    }
  }

  private func present(_ session: ReviewSession, pr: PullRequestSummary?) {
    self.session = session
    currentPR = pr
    impact = [:]
    flows = nil
    contentCache = [:]
    backStack = []
    forwardStack = []
    reviewed = Set(UserDefaults.standard.stringArray(forKey: reviewKey) ?? [])
    busy = nil
    recomputeOrder()
    relayout()
    select(session.graph.entryPoint ?? order.first, recordHistory: false)
  }

  private func fail(_ error: Error) {
    busy = nil
    errorMessage = error.localizedDescription
  }

  // MARK: - Grafo visible

  public func isVisible(_ u: CodeUnit) -> Bool {
    guard u.isCode else { return false }
    if u.isTest { return showTests && !u.isGhost }
    if u.isGhost {
      switch contextMode {
      case .none: return false
      case .key: return u.isKeyContext
      case .all: return true
      }
    }
    return true
  }

  private func relayout() {
    guard let graph else { layout = GraphLayout(); return }
    let units = graph.units.filter(isVisible)
    let ids = Set(units.map(\.id))
    layout = GraphLayout.compute(units: units, edges: graph.edges.filter { ids.contains($0.from) && ids.contains($0.to) })
  }

  private func recomputeOrder() {
    order = graph?.readingOrder(strategy) ?? []
  }

  // MARK: - Navegación

  /// Selecciona un fichero de la PR (grafo, lista, flujos) y lo abre en el visor.
  public func select(_ id: String?, line: Int? = nil, recordHistory: Bool = true) {
    guard let id else { selectedID = nil; return }
    go(to: CodeLocation(path: id, line: line), recordHistory: recordHistory)
  }

  public func go(to target: CodeLocation, recordHistory: Bool = true) {
    if recordHistory, let current = location, current != target {
      backStack.append(current)
      forwardStack = []
    }
    location = target
    // El grafo sigue al visor solo si el fichero está en él.
    if graph?.unit(target.path) != nil { selectedID = target.path } else { selectedID = nil }
    requestScroll(to: target)
  }

  public func back() {
    guard let previous = backStack.popLast() else { return }
    if let current = location { forwardStack.append(current) }
    go(to: previous, recordHistory: false)
  }

  public func forward() {
    guard let next = forwardStack.popLast() else { return }
    if let current = location { backStack.append(current) }
    go(to: next, recordHistory: false)
  }

  /// Clic en un tipo o una llamada dentro del código.
  func follow(_ link: CodeLink) {
    guard let s = session else { return }
    switch link {
    case .type(let path):
      go(to: CodeLocation(path: path, line: s.store.parsed(path, at: s.headSHA)?.facts.primaryLine))
    case .member(let path, let name):
      let parsed = s.store.parsed(path, at: s.headSHA)
      go(to: CodeLocation(path: path, line: parsed?.member(named: name)?.startLine ?? parsed?.facts.primaryLine))
    }
  }

  /// Depuración: sigue el primer enlace del fichero abierto cuyo texto sea `text`.
  public func followLink(text: String) -> Bool {
    guard let l = location, let c = content(for: l.path) else { return false }
    let ns = c.document.text as NSString
    guard let link = c.links.first(where: { ns.substring(with: $0.0) == text }) else { return false }
    follow(link.1)
    return true
  }

  /// Implementaciones de la interfaz abierta (como ⌥⌘B en IntelliJ).
  func implementations(of path: String) -> [String] {
    guard let s = session, let p = s.store.parsed(path, at: s.headSHA), p.facts.primary?.kind == .interface,
      let name = p.facts.primary?.name
    else { return [] }
    return s.store.implementations(of: name, at: s.headSHA)
  }

  /// Abre la implementación en el mismo método que se está viendo en la interfaz.
  func goToImplementation(_ implPath: String) {
    guard let s = session else { return }
    var line: Int?
    if let l = location, let iface = s.store.parsed(l.path, at: s.headSHA), let impl = s.store.parsed(implPath, at: s.headSHA) {
      let current = l.line.flatMap { n in iface.facts.members.first { ($0.startLine...$0.endLine).contains(n) } }
      line = current.flatMap { impl.member(named: $0.name)?.startLine } ?? impl.facts.primaryLine
    }
    go(to: CodeLocation(path: implPath, line: line))
  }

  public func step(_ delta: Int) {
    guard !order.isEmpty else { return }
    let i = selectedID.flatMap(order.firstIndex(of:)) ?? (delta > 0 ? -1 : order.count)
    select(order[max(0, min(order.count - 1, i + delta))])
  }

  public func nextUnreviewed() {
    let start = selectedID.flatMap(order.firstIndex(of:)) ?? -1
    let rotated = Array(order[(start + 1)...]) + Array(order[...max(start, 0)])
    if let id = rotated.first(where: { !reviewed.contains($0) }) { select(id) }
  }

  // MARK: - Visor de código

  func content(for path: String) -> CodeContent? {
    guard let s = session else { return nil }
    let key = "\(path)|\(fullFile)"
    if let c = contentCache[key] { return c }

    let unit = s.graph.unit(path)
    let changed = unit.map { !$0.isGhost } ?? false
    let head = unit?.status == .deleted ? nil : s.store.text(path, at: s.headSHA)
    let base = changed ? s.store.text(unit?.oldPath ?? path, at: s.baseSHA) : nil
    let diff = changed ? unit.flatMap(s.diff(for:)) : nil
    let document = CodeDocument.build(head: head, base: base, diff: diff, full: fullFile)
    guard !document.lines.isEmpty || head != nil else { return nil }

    let isJava = path.hasSuffix(".java")
    let tokens = isJava ? JavaLexer.tokens(document.text) : []
    let semantics = JavaSemantics.analyze(text: document.text, tokens: tokens)
    let facts = (s.store.parsed(path, at: unit?.status == .deleted ? s.baseSHA : s.headSHA))?.facts ?? SourceFacts()
    let links = isJava
      ? CodeLinker.links(text: document.text, tokens: tokens, semantics: semantics, facts: facts, ownPath: path, index: s.index)
      : []
    let statics = Set(facts.imports.filter(\.isStatic).compactMap { $0.name.components(separatedBy: ".").last })
    let c = CodeContent(
      id: "\(s.headSHA)|\(key)", document: document, tokens: tokens, semantics: semantics, links: links, staticNames: statics)
    contentCache[key] = c
    return c
  }

  private func requestScroll(to target: CodeLocation) {
    guard let c = content(for: target.path) else { return }
    let index: Int?
    if let line = target.line {
      index = c.document.lines.firstIndex { ($0.newNumber ?? 0) >= line && $0.kind != .removed }
    } else {
      index = c.document.changeIndices.first
    }
    scrollSerial += 1
    scrollRequest = ScrollRequest(line: index ?? 0, serial: scrollSerial)
  }

  public func toggleFullFile() {
    fullFile.toggle()
    if let l = location { requestScroll(to: CodeLocation(path: l.path, line: nil)) }
  }

  /// Salta al siguiente/anterior bloque cambiado del fichero abierto.
  public func jumpChange(_ delta: Int) {
    guard let l = location, let c = content(for: l.path) else { return }
    let changes = c.document.changeIndices
    guard !changes.isEmpty else { return }
    let current = scrollRequest?.line ?? -1
    let target = delta > 0 ? changes.first { $0 > current } ?? changes.first! : changes.last { $0 < current } ?? changes.last!
    scrollSerial += 1
    scrollRequest = ScrollRequest(line: target, serial: scrollSerial)
  }

  // MARK: - Revisión

  public func toggleReviewed(_ id: String? = nil) {
    guard let id = id ?? selectedID, graph?.unit(id)?.isGhost == false else { return }
    if reviewed.contains(id) { reviewed.remove(id) } else { reviewed.insert(id) }
    UserDefaults.standard.set(Array(reviewed), forKey: reviewKey)
  }

  private var reviewKey: String {
    guard let s = session else { return "reviewed" }
    return "reviewed:\(s.repo.root.path):\(s.headSHA)"
  }

  /// Ficheros fuera de la PR que nombran al tipo: lo que podría romperse.
  public func loadImpact(_ id: String) {
    guard let s = session, let u = s.graph.unit(id) else { return }
    let changed = Set(s.graph.changed.map(\.path))
    Task.detached {
      let files = s.repo.filesMentioning(u.typeName, at: s.headSHA).filter { !changed.contains($0) }
      await MainActor.run { self.impact[id] = files }
    }
  }

  public func openInEditor(_ path: String) {
    guard let s = session else { return }
    NSWorkspace.shared.open(s.repo.root.appendingPathComponent(path))
  }

  public func openOnGitHub() {
    if let url = currentPR?.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
  }

  // MARK: - Claude

  public func explainPR() {
    guard let s = session else { return }
    launchClaude(ExplainPrompt.pr(s, flows: flows ?? []))
  }

  public func explainFile(_ path: String) {
    guard let s = session else { return }
    launchClaude(ExplainPrompt.file(s, path: path))
  }

  public func explainFlow(_ flow: FlowNode) {
    guard let s = session else { return }
    launchClaude(ExplainPrompt.flow(s, flow: flow))
  }

  private func launchClaude(_ prompt: String) {
    guard let s = session else { return }
    do { try ClaudeLauncher.open(prompt: prompt, model: claudeModelID, in: s.repo.root) } catch { errorMessage = error.localizedDescription }
  }
}
