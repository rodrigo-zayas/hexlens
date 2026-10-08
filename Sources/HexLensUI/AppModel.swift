import AppKit
import HexLensCore
import SwiftUI

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

enum QuickOpenMode: Identifiable {
  case file, type
  var id: Int { self == .file ? 0 : 1 }
}

struct QuickOpenEntry: Identifiable {
  let name: String
  let detail: String
  let layer: String
  let changed: Bool
  let path: String
  let line: Int?
  var id: String { "\(path)#\(line ?? 0)#\(name)" }
}

struct UsagePopupState: Equatable, Identifiable {
  var word: String
  var id: String { word }
  var groups: [UsageGroup]
  var loading: Bool
  var changed: Set<String> = []
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
  @Published public private(set) var busy: String?
  @Published public var errorMessage: String?
  @Published public var showPRPicker = false
  @Published var quickOpen: QuickOpenMode?
  @Published public var showTests = false { didSet { relayout() } }
  @Published public var contextMode: ContextMode = .none { didSet { relayout() } }
  @Published public var strategy: ReadingStrategy = .insideOut { didSet { recomputeOrder() } }
  @Published public var zoom: CGFloat = 1
  /// Cada incremento pide ajustar el mapa a la ventana.
  @Published public private(set) var fitRequest = 0
  public func fitToWindow() { fitRequest += 1 }
  public func zoomIn() { zoom = min(3, zoom * 1.25) }
  public func zoomOut() { zoom = max(0.2, zoom / 1.25) }
  @Published public var appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark {
    didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
  }
  /// Columnas visibles: por defecto lista + código; "solo código" deja el visor a pantalla completa.
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
  /// Diff lado a lado en vez de unificado (se recuerda entre sesiones).
  @Published public var sideBySide = UserDefaults.standard.bool(forKey: "sideBySide") {
    didSet { UserDefaults.standard.set(sideBySide, forKey: "sideBySide") }
  }
  @Published private(set) var scrollRequest: ScrollRequest?
  private var scrollSerial = 0
  /// Línea del fichero nuevo bajo el cursor del visor (para las migas).
  @Published var cursorLine: Int?
  @Published var showStructure = false

  // Búsqueda en el visor (⌘F)
  @Published public private(set) var notes: [ReviewNote] = []
  @Published var noteDraft: NoteDraft?
  @Published private(set) var addNoteSerial = 0
  @Published private(set) var findUsagesSerial = 0
  @Published var usagePopup: UsagePopupState?
  private var noteStore: ReviewNoteStore?
  /// Sesiones de Claude detectadas para la rama de la PR y la enlazada (`nil` = ninguna / nueva).
  @Published public private(set) var claudeSessions: [ClaudeSession] = []
  @Published public private(set) var linkedSessionID: String?
  private var branchName: String?
  @Published var selectedNoteIDs: Set<UUID> = []

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

  /// ⌘F: si hay texto seleccionado en el visor (una línea), se usa como búsqueda y se queda en esa coincidencia.
  func showFind() {
    if let tv = CodeNSTextView.focused, tv.window?.firstResponder === tv {
      let sel = tv.selectedRange()
      let text = (tv.string as NSString).substring(with: sel)
      if sel.length > 0, sel.length <= 200, !text.contains("\n") {
        findQuery = text
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.findIndex = self.findMatches.firstIndex { NSLocationInRange(sel.location, $0) } ?? 0
        }
      }
    }
    findVisible = true
    findFocusSerial += 1
  }
  func closeFind() { findVisible = false }
  func findNext() { stepFind(1) }
  func findPrevious() { stepFind(-1) }

  private func stepFind(_ d: Int) {
    guard findVisible else { return showFind() }
    let n = findMatches.count
    guard n > 0 else { return }
    findIndex = ((findIndex + d) % n + n) % n
  }
  private var contentCache: [String: (main: CodeContent, base: CodeContent?)] = [:]

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
    } catch {
      await MainActor.run { self.fail(error) }
    }
  }

  private func present(_ session: ReviewSession, pr: PullRequestSummary?) {
    self.session = session
    currentPR = pr
    impact = [:]
    contentCache = [:]
    backStack = []
    forwardStack = []
    reviewed = Set(UserDefaults.standard.stringArray(forKey: reviewKey) ?? [])
    loadNotes(for: session, pr: pr)
    detectClaudeSessions(for: session, pr: pr)
    busy = nil
    recomputeOrder()
    relayout()
    fitRequest += 1
    select(session.graph.entryPoint ?? order.first, recordHistory: false)
  }

  private func fail(_ error: Error) {
    busy = nil
    errorMessage = error.localizedDescription
  }

  // MARK: - Grafo visible

  public func isVisible(_ u: CodeUnit) -> Bool {
    guard u.isCode || (u.isDoc && !u.isGhost) else { return false }
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
    layout = GraphLayout.compute(
      units: units, edges: graph.edges.filter { ids.contains($0.from) && ids.contains($0.to) },
      profile: session?.profile ?? ProfileRegistry.detect(paths: graph.units.map(\.path)))
  }

  private func recomputeOrder() {
    order = graph?.readingOrder(strategy) ?? []
  }

  // MARK: - Ir a fichero / clase

  /// Candidatos de ⌘⇧O (ficheros) o ⌘O (tipos declarados) entre los ficheros cargados de la sesión.
  func quickOpenEntries(_ mode: QuickOpenMode) -> [QuickOpenEntry] {
    guard let s = session else { return [] }
    var out: [QuickOpenEntry] = []
    for u in s.graph.units where u.status != .deleted {
      let changed = !u.isGhost
      switch mode {
      case .file:
        out.append(QuickOpenEntry(
          name: u.fileName, detail: u.path, layer: u.layer.title, changed: changed, path: u.path, line: nil))
      case .type:
        guard u.isCode else { continue }
        let entries = s.store.text(u.path, at: s.headSHA).map { Outline.entries(path: u.path, source: $0) }?.filter { $0.kind == .type } ?? []
        if entries.isEmpty {
          out.append(QuickOpenEntry(
            name: u.typeName, detail: u.packageName.isEmpty ? u.path : u.packageName, layer: u.layer.title,
            changed: changed, path: u.path, line: nil))
        }
        for e in entries {
          out.append(QuickOpenEntry(
            name: e.name, detail: u.packageName.isEmpty ? u.path : u.packageName, layer: u.layer.title,
            changed: changed, path: u.path, line: e.line))
        }
      }
    }
    return out
  }

  func openQuickOpen(_ entry: QuickOpenEntry) {
    quickOpen = nil
    go(to: CodeLocation(path: entry.path, line: entry.line))
  }

  // MARK: - Navegación

  /// Selecciona un fichero de la PR (grafo o lista) y lo abre en el visor.
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

  /// Contenido que manda en el visor: el unificado, o la cabeza en lado a lado.
  func content(for path: String) -> CodeContent? { contents(for: path)?.main }

  /// Lado izquierdo (base) del diff lado a lado; `nil` en modo unificado o si el fichero solo tiene un lado.
  func baseContent(for path: String) -> CodeContent? { sideBySide ? contents(for: path)?.base : nil }

  private func contents(for path: String) -> (main: CodeContent, base: CodeContent?)? {
    guard let s = session else { return nil }
    let key = "\(path)|\(fullFile)|\(sideBySide)"
    if let c = contentCache[key] { return c }

    let unit = s.graph.unit(path)
    let changed = unit.map { !$0.isGhost } ?? false
    let head = unit?.status == .deleted ? nil : s.store.text(path, at: s.headSHA)
    let base = changed ? s.store.text(unit?.oldPath ?? path, at: s.baseSHA) : nil
    let diff = changed ? unit.flatMap(s.diff(for:)) : nil
    var document = CodeDocument.build(head: head, base: base, diff: diff, full: fullFile)
    guard !document.lines.isEmpty || head != nil else { return nil }
    var baseDocument: CodeDocument?
    if sideBySide, let split = SideBySide.build(from: document) {
      document = split.right
      baseDocument = split.left
    }

    let isJava = path.hasSuffix(".java")
    let isRuby = RubyLexer.isRuby(path)
    func lex(_ text: String) -> ([Token], JavaSemantics) {
      if isJava { let t = JavaLexer.tokens(text); return (t, JavaSemantics.analyze(text: text, tokens: t)) }
      if isRuby { let t = RubyLexer.tokens(text); return (t, RubyLexer.semantics(text: text, tokens: t)) }
      return ([], JavaSemantics())
    }
    let (tokens, semantics) = lex(document.text)
    let facts = (s.store.parsed(path, at: unit?.status == .deleted ? s.baseSHA : s.headSHA))?.facts ?? SourceFacts()
    let links =
      isJava
      ? CodeLinker.links(text: document.text, tokens: tokens, semantics: semantics, facts: facts, ownPath: path, index: s.index)
      : isRuby ? CodeLinker.rubyLinks(semantics: semantics, facts: facts, ownPath: path, index: s.index) : []
    let statics = Set(facts.imports.filter(\.isStatic).compactMap { $0.name.components(separatedBy: ".").last })
    let c = CodeContent(
      id: "\(s.headSHA)|\(key)", document: document, tokens: tokens, semantics: semantics, links: links, staticNames: statics,
      outline: unit?.status != .deleted ? head.map { Outline.entries(path: path, source: $0) } ?? [] : [], isJava: isJava)
    var baseContent: CodeContent?
    if let baseDocument {
      let (baseTokens, baseSemantics) = lex(baseDocument.text)
      baseContent = CodeContent(
        id: "\(s.headSHA)|\(key)|base", document: baseDocument, tokens: baseTokens,
        semantics: baseSemantics, links: [], staticNames: statics, isJava: isJava)
    }
    contentCache[key] = (c, baseContent)
    return (c, baseContent)
  }

  private func requestScroll(to target: CodeLocation) {
    guard let c = content(for: target.path) else { return }
    let index: Int?
    if let line = target.line {
      index = c.document.lines.firstIndex { ($0.newNumber ?? 0) >= line && $0.kind != .removed }
    } else {
      switch session?.profile.opening(for: graph?.unit(target.path)) ?? .firstChange {
      case .firstChange: index = c.document.changeIndices.first
      case .top: index = 0
      }
    }
    scrollSerial += 1
    scrollRequest = ScrollRequest(line: index ?? 0, serial: scrollSerial)
  }

  public func toggleSideBySide() {
    sideBySide.toggle()
    if let l = location { requestScroll(to: CodeLocation(path: l.path, line: nil)) }
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

  // MARK: - Notas

  /// Carga las notas de la PR (clave por repo + PR, no por commit) y las reancla contra la cabeza actual.
  private func loadNotes(for s: ReviewSession, pr: PullRequestSummary?) {
    noteDraft = nil
    let key = pr.map { "pr\($0.number)" } ?? "\(s.baseRef)..\(s.headRef)"
    let store = ReviewNoteStore(repoRoot: s.repo.root.path, key: key)
    noteStore = store
    let loaded = store.load()
    var files: [String: String] = [:]
    for path in Set(loaded.map(\.path)) { files[path] = s.store.text(path, at: s.headSHA) }
    notes = reanchor(loaded, files: files, head: s.headSHA)
    if notes != loaded { store.save(notes) }
  }

  func notes(in path: String) -> [ReviewNote] { notes.filter { $0.path == path } }

  public func requestFindUsages() {
    guard location != nil else { return }
    findUsagesSerial += 1
  }

  /// Busca `word` en todo el repo en la cabeza de la PR, en segundo plano.
  func findUsages(of word: String) {
    guard let s = session else { return }
    let ruby = location.map { RubyLexer.isRuby($0.path) || $0.path.hasSuffix(".erb") } ?? false
    let globs = ruby ? ["*.rb", "*.rake", "*.jbuilder", "*.erb"] : ["*.java"]
    let declPattern =
      ruby
      ? "\\b(def\\s+(self\\.)?|class\\s+|module\\s+)" + NSRegularExpression.escapedPattern(for: word) + "\\b"
      : "\\b(class|interface|enum|record|@interface)\\s+" + NSRegularExpression.escapedPattern(for: word) + "\\b"
    usagePopup = UsagePopupState(word: word, groups: [], loading: true)
    let changed = Set(s.graph.changed.map(\.path))
    let decl = try? NSRegularExpression(pattern: declPattern)
    Task.detached {
      let hits = s.repo.usages(of: word, at: s.headSHA, globs: globs).filter { h in
        let r = NSRange(h.text.startIndex..., in: h.text)
        return decl?.firstMatch(in: h.text, range: r) == nil
      }
      let groups = UsageSearch.group(hits)
      await MainActor.run {
        guard self.usagePopup?.word == word else { return }
        self.usagePopup = UsagePopupState(word: word, groups: groups, loading: false, changed: changed)
      }
    }
  }

  public func requestAddNote() {
    guard location != nil else { return }
    addNoteSerial += 1
  }

  /// Abre el editor para una nota nueva sobre las líneas (del fichero nuevo) indicadas.
  func beginNote(path: String, start: Int, end: Int) {
    noteDraft = NoteDraft(noteID: nil, path: path, startLine: min(start, end), endLine: max(start, end), body: "")
  }

  func editNote(_ id: UUID) {
    guard let n = notes.first(where: { $0.id == id }) else { return }
    noteDraft = NoteDraft(noteID: id, path: n.path, startLine: n.startLine, endLine: n.endLine, body: n.body)
  }

  func commitDraft() {
    guard let d = noteDraft else { return }
    noteDraft = nil
    let body = d.body.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = d.noteID {
      if body.isEmpty { deleteNote(id) } else { updateNote(id, body: body) }
    } else if !body.isEmpty {
      addNote(path: d.path, start: d.startLine, end: d.endLine, body: body)
    }
  }

  public func addNote(path: String, start: Int, end: Int, body: String) {
    guard let s = session else { return }
    let lines = (s.store.text(path, at: s.headSHA) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
    guard start >= 1, end >= start, end <= lines.count else { return }
    let snippet = lines[(start - 1)..<end].joined(separator: "\n")
    notes.append(ReviewNote(path: path, startLine: start, endLine: end, snippet: snippet, body: body, anchorSHA: s.headSHA))
    noteStore?.save(notes)
  }

  public func updateNote(_ id: UUID, body: String) {
    guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
    notes[i].body = body
    notes[i].updatedAt = Date()
    noteStore?.save(notes)
  }

  public func deleteNote(_ id: UUID) {
    notes.removeAll { $0.id == id }
    noteStore?.save(notes)
  }

  public func goToNote(_ id: UUID) {
    guard let n = notes.first(where: { $0.id == id }) else { return }
    go(to: CodeLocation(path: n.path, line: n.startLine))
  }

  // MARK: - Sesión de Claude

  private func linkKey(_ s: ReviewSession, _ branch: String) -> String { "claudeSession:\(s.repo.root.path):\(branch)" }

  /// Busca las sesiones de Claude de la rama (en el repo y en sus worktrees) y aplica el enlace guardado o la más reciente.
  private func detectClaudeSessions(for s: ReviewSession, pr: PullRequestSummary?) {
    let branch = pr?.headRefName ?? s.headRef
    branchName = branch
    claudeSessions = []
    linkedSessionID = nil
    let repo = s.repo
    let key = linkKey(s, branch)
    Task.detached {
      let cwds = [repo.root.path] + repo.worktrees().map(\.path)
      let found = ClaudeSessions.find(cwds: cwds, branch: branch)
      await MainActor.run {
        guard self.session?.headSHA == s.headSHA else { return }
        self.claudeSessions = found
        let saved = UserDefaults.standard.string(forKey: key)
        // Cadena vacía = el usuario quitó el enlace a propósito: no autoseleccionar.
        if saved == "" { self.linkedSessionID = nil }
        else { self.linkedSessionID = saved ?? found.first?.id }
      }
    }
  }

  var linkedSession: ClaudeSession? { claudeSessions.first { $0.id == linkedSessionID } }

  /// Enlaza la rama con una sesión; `nil` quita el enlace y el envío abrirá una sesión nueva.
  func linkSession(_ id: String?) {
    guard let s = session, let branch = branchName else { return }
    linkedSessionID = id
    let key = linkKey(s, branch)
    if let id { UserDefaults.standard.set(id, forKey: key) } else { UserDefaults.standard.set("", forKey: key) }
  }

  // MARK: - Enviar notas a Claude

  /// La selección si la hay; si no, todas las no enviadas.
  var notesToSend: [ReviewNote] {
    let selected = notes.filter { selectedNoteIDs.contains($0.id) }
    return selected.isEmpty ? notes.filter { $0.sentAt == nil } : selected
  }

  private func notesPrompt(_ list: [ReviewNote]) -> String {
    guard let s = session else { return "" }
    return NotesPrompt.build(notes: list, pr: currentPR.map { "la PR #\($0.number) «\($0.title)»" } ?? s.title,
                             branch: branchName ?? s.headRef, repo: s.repo.name)
  }

  private func markSent(_ list: [ReviewNote]) {
    let ids = Set(list.map(\.id)), now = Date()
    for i in notes.indices where ids.contains(notes[i].id) { notes[i].sentAt = now }
    selectedNoteIDs = []
    noteStore?.save(notes)
  }

  /// Retoma la sesión enlazada o abre una nueva en el worktree de la rama (o en el repo).
  public func sendNotesToClaude() {
    guard let s = session else { return }
    let list = notesToSend
    guard !list.isEmpty else { return }
    let prompt = notesPrompt(list)
    let branch = branchName ?? s.headRef
    let dir = linkedSession.map { URL(fileURLWithPath: $0.cwd) }
      ?? s.repo.worktrees().first { $0.branch == branch }.map { URL(fileURLWithPath: $0.path) } ?? s.repo.root
    do {
      if let linked = linkedSession {
        try ClaudeLauncher.resume(sessionID: linked.id, prompt: prompt, in: dir)
      } else {
        try ClaudeLauncher.open(prompt: prompt, model: claudeModelID, in: dir)
      }
      markSent(list)
    } catch { errorMessage = error.localizedDescription }
  }

  /// Copia el prompt para pegarlo en un chat de Claude Desktop.
  public func copyNotesForClaude() {
    let list = notesToSend
    guard !list.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(notesPrompt(list), forType: .string)
    markSent(list)
  }

  func toggleNoteSelection(_ id: UUID) {
    if selectedNoteIDs.contains(id) { selectedNoteIDs.remove(id) } else { selectedNoteIDs.insert(id) }
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
    let globs = RubyLexer.isRuby(id) ? ["*.rb", "*.rake", "*.jbuilder", "*.erb"] : ["*.java"]
    Task.detached {
      let files = s.repo.filesMentioning(u.typeName, at: s.headSHA, globs: globs).filter { !changed.contains($0) }
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
    launchClaude(ExplainPrompt.pr(s))
  }

  public func explainFile(_ path: String) {
    guard let s = session else { return }
    launchClaude(ExplainPrompt.file(s, path: path))
  }

  private func launchClaude(_ prompt: String) {
    guard let s = session else { return }
    do { try ClaudeLauncher.open(prompt: prompt, model: claudeModelID, in: s.repo.root) } catch { errorMessage = error.localizedDescription }
  }
}

/// Nota en edición: `id == nil` si es nueva.
struct NoteDraft: Identifiable {
  let noteID: UUID?
  let path: String
  let startLine: Int
  let endLine: Int
  var body: String
  var id: String { "\(noteID?.uuidString ?? "new")|\(path)|\(startLine)" }
}
