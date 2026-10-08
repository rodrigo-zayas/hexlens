import HexLensCore
import SwiftUI

/// Panel derecho: el fichero abierto como en el IDE, con su ficha y sus relaciones.
struct DetailView: View {
  @EnvironmentObject var model: AppModel
  @State private var tab = Tab.code
  @State private var sync = ScrollSync()
  @AppStorage("markdownPreview") private var markdownPreview = true

  enum Tab: String, CaseIterable { case code = "Código", relations = "Relaciones" }

  var body: some View {
    if let location = model.location, let session = model.session {
      let unit = session.graph.unit(location.path)
      VStack(spacing: 0) {
        header(location.path, unit: unit, session: session)
        Divider()
        switch tab {
        case .code where Self.isMarkdown(location.path) && markdownPreview:
          if model.findVisible { FindBar() }
          markdownPane(location.path, unit: unit, session: session)
        case .code:
          if let content = model.content(for: location.path) {
            if model.findVisible { FindBar() }
            let matches = model.findMatches
            Breadcrumbs(path: location.path, content: content, changed: unit?.members ?? [])
            codePane(content, path: location.path, matches: matches)
          } else {
            ContentUnavailableView("Sin contenido", systemImage: "doc", description: Text("Fichero binario o vacío."))
          }
        case .relations:
          if let unit {
            ScrollView { RelationsView(unit: unit).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
          } else {
            ContentUnavailableView("Fuera de la PR", systemImage: "arrow.uturn.backward", description: Text("Este fichero no cambia en la PR."))
          }
        }
      }
      .sheet(item: $model.noteDraft) { _ in NoteEditor() }
      .sheet(isPresented: $model.showStructure) {
        if let content = model.content(for: location.path) {
          StructurePopup(path: location.path, entries: content.outline, changed: unit?.members ?? [])
        }
      }
    } else {
      ContentUnavailableView("Elige una pieza", systemImage: "hexagon", description: Text("Pulsa un nodo del mapa o un fichero de la lista."))
    }
  }

  static func isMarkdown(_ path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return ext == "md" || ext == "markdown"
  }

  @ViewBuilder
  private func markdownPane(_ path: String, unit: CodeUnit?, session: ReviewSession) -> some View {
    let isDeleted = unit?.status == .deleted
    let source = isDeleted
      ? session.store.text(unit?.oldPath ?? path, at: session.baseSHA)
      : session.store.text(path, at: session.headSHA)
    if let source {
      let inPR = unit.map { !$0.isGhost } ?? false
      MarkdownPreview(
        text: source, path: path,
        changes: inPR ? unit.map { ($0.additions, $0.deletions) } : nil,
        diff: inPR && !isDeleted ? unit.flatMap(session.diff(for:)).map { MarkdownDiff(diff: $0, isNewFile: unit?.status == .added) } : nil,
        find: model.findVisible ? .init(query: model.findQuery, caseSensitive: model.findCaseSensitive, wholeWord: model.findWholeWord, index: model.findIndex) : nil,
        onMatchCount: { model.previewFindCount = $0 },
        onShowChanges: { markdownPreview = false },
        onOpenLine: { line in
          markdownPreview = false
          model.go(to: CodeLocation(path: path, line: line))
        },
        onOpenPath: { model.go(to: CodeLocation(path: $0, line: nil)) })
        .id(path)
        .onDisappear { model.previewFindCount = nil }
    } else {
      ContentUnavailableView("Sin contenido", systemImage: "doc", description: Text("Fichero binario o vacío."))
    }
  }

  @ViewBuilder
  private func codePane(_ content: CodeContent, path: String, matches: [NSRange]) -> some View {
    let pane = CodeTextView(
              content: content, scroll: model.scrollRequest, matches: matches,
              currentMatch: matches.isEmpty ? nil : min(model.findIndex, matches.count - 1),
              notes: model.notes(in: path).map { NoteSpan(id: $0.id, start: $0.startLine, end: $0.endLine, outdated: $0.outdated) },
              addNoteSerial: model.addNoteSerial,
              onAddNote: { model.beginNote(path: path, start: $0, end: $1) },
              onOpenNote: { model.editNote($0) },
              findUsagesSerial: model.findUsagesSerial,
              onFindUsages: { model.findUsages(of: $0) },
              onCursor: { model.cursorLine = $0 },
              onLink: { model.follow($0) },
              sync: model.baseContent(for: path) == nil ? nil : sync)
    if let base = model.baseContent(for: path) {
      HSplitView {
        CodeTextView(
          content: base, scroll: nil, matches: [], currentMatch: nil, onLink: { _ in }, readOnlyLeft: true, sync: sync)
          .frame(minWidth: 200)
        pane.frame(minWidth: 200)
      }
    } else {
      pane
    }
  }

  private func header(_ path: String, unit: CodeUnit?, session: ReviewSession) -> some View {
    let info = unit.map { ($0.module, $0.layer, $0.role, $0.packageLabel) } ?? {
      let i = session.profile.classify(path: path, facts: session.store.parsed(path, at: session.headSHA)?.facts)
      return (i.module, i.layer, i.role, i.packageLabel)
    }()
    let inPR = unit.map { !$0.isGhost } ?? false
    let name = unit?.typeName ?? session.store.parsed(path, at: session.headSHA)?.facts.primary?.name ?? (path as NSString).lastPathComponent

    return VStack(alignment: .leading, spacing: Metrics.s) {
      HStack(spacing: Metrics.s) {
        Button { model.back() } label: { Image(systemName: "chevron.left") }
          .disabled(model.backStack.isEmpty).help("Atrás (⌘←)").handCursor(!model.backStack.isEmpty)
        Button { model.forward() } label: { Image(systemName: "chevron.right") }
          .disabled(model.forwardStack.isEmpty).help("Adelante (⌘→)").handCursor(!model.forwardStack.isEmpty)
        HStack(spacing: 4) {
          Text(info.0)
          Image(systemName: "chevron.right").font(.system(size: 8))
          Text(info.1.title)
          if !info.3.isEmpty {
            Image(systemName: "chevron.right").font(.system(size: 8))
            Text(info.3)
          }
        }
        .font(Typo.secondary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        Spacer()
      }
      .buttonStyle(.borderless)

      HStack(alignment: .firstTextBaseline, spacing: Metrics.s) {
        Text(name).font(.system(size: 15, weight: .semibold)).textSelection(.enabled).lineLimit(1)
        Text(info.2.label).font(Typo.secondary).foregroundStyle(.secondary)
        if let unit, inPR {
          Text(unit.status.label).font(Typo.secondary).foregroundStyle(unit.status.color)
          Text("+\(unit.additions) −\(unit.deletions)").font(Typo.secondary.monospacedDigit()).foregroundStyle(.secondary)
        } else {
          Text("fuera de la PR").font(Typo.secondary).foregroundStyle(.secondary)
        }
        Spacer()
      }

      if let unit, inPR {
        ForEach(session.graph.violations(of: unit.id)) { v in
          Tag(text: v.message, symbol: "exclamationmark.triangle", isError: v.severity == .error)
            .help(v.imported)
        }
        if !unit.members.isEmpty { MembersDisclosure(unit: unit, session: session) }
      }

      let impls = model.implementations(of: path)
      if !impls.isEmpty {
        HStack(spacing: Metrics.s) {
          SectionTitle("Implementado por")
          ForEach(impls, id: \.self) { impl in
            Button { model.goToImplementation(impl) } label: {
              Text(((impl as NSString).lastPathComponent as NSString).deletingPathExtension).font(Typo.secondary)
            }
            .buttonStyle(.link).handCursor()
            .help(impl)
          }
        }
      }

      HStack(spacing: Metrics.s) {
        Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
          .pickerStyle(.segmented).labelsHidden().fixedSize().handCursor()
        if tab == .code, Self.isMarkdown(path) {
          Picker("", selection: $markdownPreview) {
            Text("Renderizado").tag(true)
            Text("Código").tag(false)
          }
          .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small).handCursor()
          .help("Documento renderizado o código fuente con los cambios")
        }
        if tab == .code, !(Self.isMarkdown(path) && markdownPreview) {
          Toggle("Completo", isOn: Binding(get: { model.fullFile }, set: { _ in model.toggleFullFile() }))
            .toggleStyle(.checkbox).fixedSize().handCursor()
            .help("Fichero entero con los cambios marcados, o solo los fragmentos cambiados")
          if inPR {
            Picker("", selection: Binding(get: { model.sideBySide }, set: { _ in model.toggleSideBySide() })) {
              Text("Unificado").tag(false)
              Text("Lado a lado").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small).handCursor()
            .help("Diff unificado o lado a lado (⌥⌘D)")
          }
          if inPR {
            Button { model.jumpChange(-1) } label: { Image(systemName: "arrow.up") }.help("Cambio anterior (⌘⌥↑)").handCursor()
            Button { model.jumpChange(1) } label: { Image(systemName: "arrow.down") }.help("Cambio siguiente (⌘⌥↓)").handCursor()
          }
        }
        Spacer()
        if inPR {
          Button {
            model.toggleReviewed(path)
          } label: {
            Label("Revisado", systemImage: model.reviewed.contains(path) ? "checkmark.circle.fill" : "circle")
              .labelStyle(.titleAndIcon)
          }
          .handCursor()
        }
        Menu {
          Button("Explicar con Claude") { model.explainFile(path) }
          Button("Abrir en el editor") { model.openInEditor(path) }
          Button("Copiar ruta") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
          }
        } label: { Image(systemName: "ellipsis.circle") }
          .menuStyle(.borderlessButton).fixedSize().handCursor()
      }
      .controlSize(.small)
    }
    .padding(.horizontal, Metrics.m)
    .padding(.vertical, Metrics.s)
  }
}

/// Métodos tocados del fichero, colapsados por defecto.
private struct MembersDisclosure: View {
  @EnvironmentObject var model: AppModel
  @AppStorage("membersExpanded") private var expanded = false
  let unit: CodeUnit
  let session: ReviewSession

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      FlowLayout(spacing: Metrics.s) {
        ForEach(unit.members, id: \.self) { m in
          Button {
            model.go(to: CodeLocation(path: unit.path, line: session.store.parsed(unit.path, at: session.headSHA)?.member(named: m.name)?.startLine))
          } label: {
            Text("\(m.change.sign) \(m.name)").font(Typo.code).foregroundStyle(m.change.color)
          }
          .buttonStyle(.plain).handCursor()
          .help(m.signature)
          .disabled(m.change == .removed)
        }
      }
      .padding(.top, Metrics.xs)
    } label: {
      SectionTitle("Métodos tocados (\(unit.members.count))")
    }
  }
}

/// Usa / lo usan / tests / impacto fuera de la PR, todo navegable.
struct RelationsView: View {
  @EnvironmentObject var model: AppModel
  let unit: CodeUnit

  var body: some View {
    let g = model.graph!
    let u = unit
    let uses = g.outgoing(u.id).filter { $0.kind != .tests }
    let usedBy = g.incoming(u.id).filter { $0.kind != .tests && g.unit($0.from)?.isTest == false }
    let tests = g.tests(of: u.id)
    VStack(alignment: .leading, spacing: Metrics.m) {
      if let subject = g.subjectByTest[u.id] { row("Prueba a", [subject], edges: nil) }
      row("Usa", uses.map(\.to), edges: uses)
      row("Lo usan", usedBy.map(\.from), edges: usedBy)
      if !tests.isEmpty { row("Tests", tests, edges: nil) }

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          SectionTitle("Fuera de la PR")
          if let files = model.impact[u.id] {
            Text("\(files.count) ficheros nombran \(u.typeName)").foregroundStyle(.secondary).font(.caption)
          } else {
            Button("Buscar quién lo usa") { model.loadImpact(u.id) }.controlSize(.small).handCursor()
            Button("Buscar usos") { model.findUsages(of: u.typeName) }.controlSize(.small).handCursor()
          }
        }
        if let files = model.impact[u.id] {
          ForEach(files.prefix(60), id: \.self) { f in
            Button((f as NSString).lastPathComponent) { model.go(to: CodeLocation(path: f, line: nil)) }
              .buttonStyle(.link).font(.system(size: 11, design: .monospaced)).help(f).handCursor()
          }
        }
      }
    }
  }

  @ViewBuilder
  private func row(_ title: String, _ ids: [String], edges: [Dependency]?) -> some View {
    if !ids.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        SectionTitle("\(title) (\(ids.count))")
        FlowLayout {
          ForEach(ids, id: \.self) { id in
            if let other = model.graph?.unit(id) {
              let kind = edges?.first { $0.from == id || $0.to == id }?.kind
              Button { model.select(id) } label: {
                HStack(spacing: 4) {
                  Text(other.typeName)
                  if kind == .implements { Text("implementa").foregroundStyle(.secondary) }
                  if kind == .extends { Text("extiende").foregroundStyle(.secondary) }
                }
                .font(Typo.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
              }
              .buttonStyle(.plain).handCursor()
              .help("\(other.layer.title) · \(other.role.label) · \(other.packageName)")
            }
          }
        }
      }
    }
  }
}

/// Migas sobre el visor: tipo › método según el cursor; clic salta a la declaración.
struct Breadcrumbs: View {
  @EnvironmentObject var model: AppModel
  let path: String
  let content: CodeContent
  let changed: [MemberChange]

  var body: some View {
    let trail = Outline.trail(content.outline, line: model.cursorLine ?? 0)
    let shown = trail.isEmpty ? Array(content.outline.prefix(1)) : trail
    if !shown.isEmpty {
      HStack(spacing: 4) {
        ForEach(Array(shown.enumerated()), id: \.offset) { i, e in
          if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
          Button { model.go(to: CodeLocation(path: path, line: e.line)) } label: {
            Text(e.kind == .method ? "\(e.name)()" : e.name)
          }
          .buttonStyle(.plain).handCursor()
        }
        Spacer()
      }
      .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
      .padding(.horizontal, 14).padding(.vertical, 3)
      Divider()
    }
  }
}

/// Estructura del fichero (⌘F12): filtra al escribir, Enter o clic saltan a la línea.
struct StructurePopup: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let path: String
  let entries: [OutlineEntry]
  let changed: [MemberChange]
  @State private var query = ""
  @State private var selected = 0
  @FocusState private var focused: Bool

  private var filtered: [OutlineEntry] {
    query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  private func change(_ e: OutlineEntry) -> MemberChange? {
    e.kind == .type ? nil : changed.first { $0.name == e.name && $0.change != .removed }
  }

  private func symbol(_ e: OutlineEntry) -> String {
    switch e.kind {
    case .type: "c.square"
    case .method: "m.square"
    case .field: "f.square"
    }
  }

  private func open(_ e: OutlineEntry) {
    dismiss()
    model.go(to: CodeLocation(path: path, line: e.line))
  }

  var body: some View {
    let items = filtered
    VStack(spacing: 0) {
      TextField("Buscar en la estructura", text: $query)
        .textFieldStyle(.plain).font(.system(size: 13))
        .padding(10)
        .focused($focused)
        .onSubmit { if items.indices.contains(selected) { open(items[selected]) } }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onChange(of: query) { _, _ in selected = 0 }
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, e in
              HStack(spacing: 6) {
                Image(systemName: symbol(e)).foregroundStyle(.secondary)
                Text(e.kind == .method ? "\(e.name)()" : e.name)
                  .font(.system(size: 12, weight: change(e) == nil ? .regular : .semibold, design: .monospaced))
                if let c = change(e) { Text(c.change.sign).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                Spacer()
                Text("\(e.line)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
              }
              .padding(.horizontal, 10).padding(.vertical, 3)
              .background(i == selected ? Color.accentColor.opacity(0.18) : .clear)
              .contentShape(Rectangle())
              .onTapGesture { open(e) }.handCursor()
              .id(i)
            }
          }
        }
        .onChange(of: selected) { _, i in proxy.scrollTo(i) }
      }
      if items.isEmpty {
        Text("Sin resultados").font(.caption).foregroundStyle(.secondary).padding(12)
      }
    }
    .frame(width: 440, height: 360)
    .onAppear { focused = true }
  }
}

/// Barra de búsqueda del visor (⌘F).
struct FindBar: View {
  @EnvironmentObject var model: AppModel
  @FocusState private var focused: Bool

  var body: some View {
    let count = model.previewFindCount ?? model.findMatches.count
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Buscar", text: $model.findQuery)
        .textFieldStyle(.plain)
        .focused($focused)
        .onSubmit { NSEvent.modifierFlags.contains(.shift) ? model.findPrevious() : model.findNext() }
        .onKeyPress(.escape) { model.closeFind(); return .handled }
        .frame(minWidth: 120)
      Text(model.findQuery.isEmpty ? "" : count == 0 ? "Sin resultados" : "\(min(model.findIndex, count - 1) + 1) de \(count)")
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      toggle("Aa", $model.findCaseSensitive, help: "Distinguir mayúsculas")
      toggle("W", $model.findWholeWord, help: "Palabra completa")
      Button { model.findPrevious() } label: { Image(systemName: "chevron.up") }
        .help("Anterior (⌘⇧G)").disabled(count == 0).handCursor(count > 0)
      Button { model.findNext() } label: { Image(systemName: "chevron.down") }
        .help("Siguiente (⌘G)").disabled(count == 0).handCursor(count > 0)
      Button { model.closeFind() } label: { Image(systemName: "xmark") }.help("Cerrar (Esc)").handCursor()
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 10).padding(.vertical, 5)
    .background(.bar)
    .onAppear { focused = true }
    .onChange(of: model.findFocusSerial) { _, _ in focused = true }
    .onChange(of: model.findQuery) { _, _ in model.findIndex = 0 }
    .onChange(of: model.findCaseSensitive) { _, _ in model.findIndex = 0 }
    .onChange(of: model.findWholeWord) { _, _ in model.findIndex = 0 }
    Divider()
  }

  private func toggle(_ title: String, _ value: Binding<Bool>, help: String) -> some View {
    Toggle(isOn: value) { Text(title).font(.system(size: 11, weight: .medium, design: .monospaced)) }
      .toggleStyle(.button).controlSize(.small).help(help).handCursor()
  }
}


/// Editor de una nota: ⌘↩ guarda, Esc cancela.
struct NoteEditor: View {
  @EnvironmentObject var model: AppModel
  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    let draft = model.noteDraft
    let range = draft.map { $0.startLine == $0.endLine ? "\($0.startLine)" : "\($0.startLine)-\($0.endLine)" } ?? ""
    VStack(alignment: .leading, spacing: 10) {
      Text("\(((draft?.path ?? "") as NSString).lastPathComponent):\(range)")
        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
      TextEditor(text: $text)
        .font(.system(size: 13))
        .focused($focused)
        .frame(width: 420, height: 140)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
      HStack {
        if let id = draft?.noteID {
          Button("Borrar", role: .destructive) { model.noteDraft = nil; model.deleteNote(id) }.handCursor()
        }
        Spacer()
        Button("Cancelar") { model.noteDraft = nil }.keyboardShortcut(.cancelAction).handCursor()
        Button("Guardar") { model.noteDraft?.body = text; model.commitDraft() }
          .keyboardShortcut(.return, modifiers: .command).handCursor()
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(16)
    .onAppear { text = draft?.body ?? ""; focused = true }
  }
}
