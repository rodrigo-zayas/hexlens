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
            CodeTextView(
              content: content, scroll: model.scrollRequest, matches: matches,
              currentMatch: matches.isEmpty ? nil : min(model.findIndex, matches.count - 1)
            ) { model.follow($0) }
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
