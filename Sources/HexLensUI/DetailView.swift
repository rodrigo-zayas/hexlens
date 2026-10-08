import HexLensCore
import SwiftUI

/// Panel derecho: el fichero abierto como en el IDE, con su ficha y sus relaciones.
struct DetailView: View {
  @EnvironmentObject var model: AppModel
  @State private var tab = Tab.code

  enum Tab: String, CaseIterable { case code = "Código", relations = "Relaciones" }

  var body: some View {
    if let location = model.location, let session = model.session {
      let unit = session.graph.unit(location.path)
      VStack(spacing: 0) {
        header(location.path, unit: unit, session: session)
        Divider()
        switch tab {
        case .code:
          if let content = model.content(for: location.path) {
            if model.findVisible { FindBar() }
            let matches = model.findMatches
            Breadcrumbs(path: location.path, content: content, changed: unit?.members ?? [])
            CodeTextView(
              content: content, scroll: model.scrollRequest, matches: matches,
              currentMatch: matches.isEmpty ? nil : min(model.findIndex, matches.count - 1),
              notes: model.notes(in: location.path).map { NoteSpan(id: $0.id, start: $0.startLine, end: $0.endLine, outdated: $0.outdated) },
              addNoteSerial: model.addNoteSerial,
              onAddNote: { model.beginNote(path: location.path, start: $0, end: $1) },
              onOpenNote: { model.editNote($0) },
              onCursor: { model.cursorLine = $0 },
              onLink: { model.follow($0) })
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
      ContentUnavailableView("Elige una pieza", systemImage: "hexagon", description: Text("Pulsa un paso de un flujo, un nodo del mapa o un fichero de la lista."))
    }
  }

  private func header(_ path: String, unit: CodeUnit?, session: ReviewSession) -> some View {
    let info = unit.map { ($0.module, $0.layer, $0.role, $0.packageLabel) } ?? {
      let i = session.profile.classify(path: path, facts: session.store.parsed(path, at: session.headSHA)?.facts)
      return (i.module, i.layer, i.role, i.packageLabel)
    }()
    let inPR = unit.map { !$0.isGhost } ?? false
    let name = unit?.typeName ?? session.store.parsed(path, at: session.headSHA)?.facts.primary?.name ?? (path as NSString).lastPathComponent

    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Button { model.back() } label: { Image(systemName: "chevron.left") }
          .disabled(model.backStack.isEmpty).help("Atrás (⌘⌥←)")
        Button { model.forward() } label: { Image(systemName: "chevron.right") }
          .disabled(model.forwardStack.isEmpty).help("Adelante (⌘⌥→)")
        HStack(spacing: 4) {
          Text(info.0)
          Image(systemName: "chevron.right").font(.system(size: 8))
          Text(info.1.title).foregroundStyle(info.1.color)
          if !info.3.isEmpty {
            Image(systemName: "chevron.right").font(.system(size: 8))
            Text(info.3)
          }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        Spacer()
      }
      .buttonStyle(.borderless)

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: info.2.symbol).foregroundStyle(info.1.color)
        Text(name).font(.title3.weight(.semibold)).textSelection(.enabled).lineLimit(1)
        Pill(text: info.2.label, color: info.1.color)
        if let unit, inPR {
          Pill(text: unit.status.label, color: unit.status.color)
          Text("+\(unit.additions) −\(unit.deletions)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else {
          Pill(text: "fuera de la PR", color: .gray)
        }
        Spacer()
      }

      if let unit, inPR, !unit.members.isEmpty || !session.graph.violations(of: unit.id).isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 5) {
            ForEach(session.graph.violations(of: unit.id)) { v in
              Pill(text: v.message, color: v.severity == .error ? .red : .orange, symbol: "exclamationmark.triangle.fill")
                .help(v.imported)
            }
            ForEach(unit.members, id: \.self) { m in
              Button {
                model.go(to: CodeLocation(path: unit.path, line: session.store.parsed(unit.path, at: session.headSHA)?.member(named: m.name)?.startLine))
              } label: {
                Text("\(m.change.sign) \(m.name)")
                  .font(.system(size: 11, design: .monospaced))
                  .padding(.horizontal, 6).padding(.vertical, 2)
                  .background(m.change.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                  .foregroundStyle(m.change.color)
              }
              .buttonStyle(.plain)
              .help(m.signature)
              .disabled(m.change == .removed)
            }
          }
        }
      }

      let impls = model.implementations(of: path)
      if !impls.isEmpty {
        HStack(spacing: 5) {
          Text("Implementado por").font(.caption).foregroundStyle(.secondary)
          ForEach(impls, id: \.self) { impl in
            Button { model.goToImplementation(impl) } label: {
              Pill(text: ((impl as NSString).lastPathComponent as NSString).deletingPathExtension, color: .purple, symbol: "arrow.down.right")
            }
            .buttonStyle(.plain)
            .help(impl)
          }
        }
      }

      HStack(spacing: 8) {
        Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
          .pickerStyle(.segmented).labelsHidden().fixedSize()
        if tab == .code {
          Toggle("Completo", isOn: Binding(get: { model.fullFile }, set: { _ in model.toggleFullFile() }))
            .toggleStyle(.checkbox).fixedSize()
            .help("Fichero entero con los cambios marcados, o solo los fragmentos cambiados")
          if inPR {
            Button { model.jumpChange(-1) } label: { Image(systemName: "arrow.up") }.help("Cambio anterior (⌘⌥↑)")
            Button { model.jumpChange(1) } label: { Image(systemName: "arrow.down") }.help("Cambio siguiente (⌘⌥↓)")
          }
        }
        Spacer()
        if inPR {
          Button {
            model.toggleReviewed(path)
          } label: {
            Label("Revisado", systemImage: model.reviewed.contains(path) ? "checkmark.circle.fill" : "circle")
          }
          .tint(model.reviewed.contains(path) ? .green : nil)
        }
        Button { model.explainFile(path) } label: { Label("Explicar", systemImage: "sparkles") }
          .help("Abre Claude en Terminal con este fichero")
        Menu {
          Button("Abrir en el editor") { model.openInEditor(path) }
          Button("Copiar ruta") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
          }
        } label: { Image(systemName: "ellipsis.circle") }
          .menuStyle(.borderlessButton).fixedSize()
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
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
    VStack(alignment: .leading, spacing: 12) {
      if let subject = g.subjectByTest[u.id] { row("Prueba a", [subject], edges: nil) }
      row("Usa", uses.map(\.to), edges: uses)
      row("Lo usan", usedBy.map(\.from), edges: usedBy)
      if !tests.isEmpty { row("Tests", tests, edges: nil) }

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("Fuera de la PR").font(.subheadline.weight(.semibold))
          if let files = model.impact[u.id] {
            Text("\(files.count) ficheros nombran \(u.typeName)").foregroundStyle(.secondary).font(.caption)
          } else {
            Button("Buscar quién lo usa") { model.loadImpact(u.id) }.controlSize(.small)
          }
        }
        if let files = model.impact[u.id] {
          ForEach(files.prefix(60), id: \.self) { f in
            Button((f as NSString).lastPathComponent) { model.go(to: CodeLocation(path: f, line: nil)) }
              .buttonStyle(.link).font(.system(size: 11, design: .monospaced)).help(f)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func row(_ title: String, _ ids: [String], edges: [Dependency]?) -> some View {
    if !ids.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(title) (\(ids.count))").font(.subheadline.weight(.semibold))
        FlowLayout {
          ForEach(ids, id: \.self) { id in
            if let other = model.graph?.unit(id) {
              let kind = edges?.first { $0.from == id || $0.to == id }?.kind
              Button { model.select(id) } label: {
                HStack(spacing: 4) {
                  Circle().fill(other.status.color).frame(width: 6, height: 6)
                  Image(systemName: other.role.symbol).foregroundStyle(other.layer.color)
                  Text(other.typeName)
                  if kind == .implements { Text("implementa").foregroundStyle(.secondary) }
                  if kind == .extends { Text("extiende").foregroundStyle(.secondary) }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(other.layer.color.opacity(0.1), in: Capsule())
              }
              .buttonStyle(.plain)
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
          .buttonStyle(.plain)
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
              .onTapGesture { open(e) }
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
    let count = model.findMatches.count
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
        .help("Anterior (⌘⇧G)").disabled(count == 0)
      Button { model.findNext() } label: { Image(systemName: "chevron.down") }
        .help("Siguiente (⌘G)").disabled(count == 0)
      Button { model.closeFind() } label: { Image(systemName: "xmark") }.help("Cerrar (Esc)")
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
      .toggleStyle(.button).controlSize(.small).help(help)
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
          Button("Borrar", role: .destructive) { model.noteDraft = nil; model.deleteNote(id) }
        }
        Spacer()
        Button("Cancelar") { model.noteDraft = nil }.keyboardShortcut(.cancelAction)
        Button("Guardar") { model.noteDraft?.body = text; model.commitDraft() }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(16)
    .onAppear { text = draft?.body ?? ""; focused = true }
  }
}
