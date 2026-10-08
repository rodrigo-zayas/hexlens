import HexLensCore
import SwiftUI

public struct RootView: View {
  @EnvironmentObject var model: AppModel

  public init() {}

  public var body: some View {
    NavigationSplitView(columnVisibility: $model.columns) {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
    } content: {
      Group {
        if model.repo == nil {
          WelcomeView()
        } else if model.session == nil {
          ContentUnavailableView {
            Label("Elige una PR", systemImage: "arrow.triangle.pull")
          } actions: {
            Button("Ver PRs…") { model.showPRPicker = true }
          }
        } else {
          CenterPane()
        }
      }
      .navigationSplitViewColumnWidth(min: 380, ideal: 560)
    } detail: {
      DetailView()
        .navigationSplitViewColumnWidth(min: 520, ideal: 980)
    }
    .preferredColorScheme(model.appearance.scheme)
    .toolbar { toolbar }
    .navigationTitle(model.repo?.name ?? "HexLens")
    .navigationSubtitle(model.session?.title ?? "")
    .sheet(isPresented: $model.showPRPicker) { PRPickerView().environmentObject(model) }
    .overlay {
      if let busy = model.busy {
        VStack(spacing: 10) {
          ProgressView()
          Text(busy).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      }
    }
    .alert("Algo ha fallado", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
      Button("Vale", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button { model.chooseRepository() } label: { Label("Repositorio", systemImage: "folder") }
        .help("Abrir repositorio (⌘O)")
      Button { model.showPRPicker = true } label: { Label("PRs", systemImage: "arrow.triangle.pull") }
        .disabled(model.repo == nil)
        .help("Elegir PR (⌘P)")
    }
    ToolbarItemGroup(placement: .principal) {
      if let pr = model.currentPR {
        Menu {
          Button("\(pr.baseRefName) (base de la PR)") { model.open(pr) }
          ForEach(["develop", "main"].filter { $0 != pr.baseRefName }, id: \.self) { b in
            Button(b) { model.open(pr, base: b) }
          }
        } label: {
          Label("Base: \(model.baseOverride ?? pr.baseRefName)", systemImage: "arrow.triangle.branch")
        }
        .help("Comparar la PR contra otra rama sin cambiarla en GitHub (útil en PRs apiladas)")
      }
    }
    ToolbarItemGroup(placement: .primaryAction) {
      Picker("Contexto", selection: $model.contextMode) {
        ForEach(ContextMode.allCases) { Text($0.title).tag($0) }
      }
      .help("Ficheros sin cambios que conectan piezas de la PR")
      Toggle(isOn: $model.showTests) { Label("Tests", systemImage: "testtube.2") }
        .help("Mostrar los tests como nodos")
      Button { model.step(-1) } label: { Label("Anterior", systemImage: "chevron.up") }
        .help("Anterior en el orden de lectura (⌘[)")
      Button { model.step(1) } label: { Label("Siguiente", systemImage: "chevron.down") }
        .help("Siguiente en el orden de lectura (⌘])")
      Button { model.toggleReviewed() } label: { Label("Revisado", systemImage: "checkmark.circle") }
        .help("Marcar revisado (⌘D)")
      Button { model.toggleCodeOnly() } label: {
        Label("Solo código", systemImage: model.columns == .detailOnly ? "rectangle.split.3x1" : "rectangle.righthalf.filled")
      }
      .help("Código a pantalla completa (⌘⇧C)")
      Menu {
        Picker("Apariencia", selection: $model.appearance) {
          ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
        }
      } label: { Label("Apariencia", systemImage: "circle.lefthalf.filled") }
      Button { model.explainPR() } label: { Label("Explicar PR", systemImage: "sparkles") }
        .disabled(model.session == nil)
        .help("Abre Claude en Terminal con un resumen de qué hace la PR")
      Button { model.reload() } label: { Label("Recargar", systemImage: "arrow.clockwise") }
        .disabled(model.session == nil)
      if model.currentPR?.url != nil {
        Button { model.openOnGitHub() } label: { Label("GitHub", systemImage: "safari") }
      }
    }
  }
}

/// Centro: flujos (qué hace) o mapa (dónde está), con el resumen por capa encima.
struct CenterPane: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Picker("", selection: $model.centerMode) {
          ForEach(CenterMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .padding(.leading, 12)
        SummaryBar()
      }
      Divider()
      switch model.centerMode {
      case .flows: FlowsView()
      case .map: GraphPane()
      }
    }
  }
}

struct GraphPane: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView([.horizontal, .vertical]) {
          if let graph = model.graph {
            GraphCanvas(
              graph: graph, layout: model.layout, selectedID: model.selectedID, hoveredID: model.hoveredID,
              reviewed: model.reviewed,
              onSelect: { model.select($0) }, onHover: { model.hoveredID = $0 })
              .scaleEffect(model.zoom, anchor: .topLeading)
              .frame(width: model.layout.size.width * model.zoom, height: model.layout.size.height * model.zoom, alignment: .topLeading)
          }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: model.selectedID) { _, id in
          guard let id, model.layout.frames[id] != nil else { return }
          withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
        }
        .onAppear {
          // Al cargar, la selección (punto de entrada) llega antes que el lienzo.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let id = model.selectedID, model.layout.frames[id] != nil { proxy.scrollTo(id, anchor: .center) }
          }
        }
      }
      .overlay(alignment: .bottomTrailing) { zoomControls }
    }
  }

  private var zoomControls: some View {
    HStack(spacing: 2) {
      Button { model.zoom = max(0.3, model.zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
      Text("\(Int(model.zoom * 100)) %").font(.caption.monospacedDigit()).frame(width: 44)
      Button { model.zoom = min(2, model.zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
      Button("1:1") { model.zoom = 1 }
    }
    .buttonStyle(.borderless)
    .padding(6)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .padding(10)
  }
}

/// Macroestructura antes del detalle: cuánto toca cada capa y qué reglas rompe.
struct SummaryBar: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    if let g = model.graph {
      let changed = g.changed.filter { $0.isCode && !$0.isTest }
      let byLayer = Dictionary(grouping: changed, by: \.layer)
      let errors = g.violations.filter { $0.severity == .error }
      let warnings = g.violations.filter { $0.severity == .warning }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(Layer.allCases, id: \.self) { layer in
            if let us = byLayer[layer] {
              let roles = Dictionary(grouping: us, by: \.role).sorted { $0.key.rank < $1.key.rank }
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                  Circle().fill(layer.color).frame(width: 8, height: 8)
                  Text(layer.title).font(.system(size: 11, weight: .semibold))
                  Text("\(us.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(roles.map { "\($0.value.count) \($0.key.label)" }.joined(separator: " · "))
                  .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
              }
              .padding(.horizontal, 8).padding(.vertical, 5)
              .background(layer.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
          }
          let tests = g.changed.filter(\.isTest).count
          if tests > 0 { Pill(text: "\(tests) tests", color: .green, symbol: "testtube.2") }
          if !errors.isEmpty { Pill(text: "\(errors.count) violaciones", color: .red, symbol: "xmark.octagon.fill") }
          if !warnings.isEmpty { Pill(text: "\(warnings.count) avisos", color: .orange, symbol: "exclamationmark.triangle.fill") }
          if let entry = g.entryPoint.flatMap(g.unit) {
            Button { model.select(entry.id) } label: {
              Pill(text: "Empieza por \(entry.typeName)", color: .pink, symbol: "flag.fill")
            }
            .buttonStyle(.plain)
          }
          Legend()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
    }
  }
}

struct Legend: View {
  var body: some View {
    HStack(spacing: 12) {
      legendLine("usa", dash: [], color: .secondary)
      legendLine("implementa / extiende", dash: [6, 4], color: .secondary)
      legendLine("viola capas", dash: [], color: .red)
      HStack(spacing: 4) {
        RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: 16, height: 10)
        Text("sin cambios")
      }
      HStack(spacing: 6) {
        ForEach([ChangeStatus.added, .modified, .deleted], id: \.self) { s in
          HStack(spacing: 2) { Rectangle().fill(s.color).frame(width: 4, height: 10); Text(s.label) }
        }
      }
    }
    .font(.system(size: 10))
    .foregroundStyle(.secondary)
    .fixedSize()
    .padding(.leading, 8)
  }

  private func legendLine(_ text: String, dash: [CGFloat], color: Color) -> some View {
    HStack(spacing: 4) {
      Path { p in p.move(to: CGPoint(x: 0, y: 5)); p.addLine(to: CGPoint(x: 22, y: 5)) }
        .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dash))
        .frame(width: 22, height: 10)
      Text(text)
    }
  }
}

public struct ReviewCommands: Commands {
  @ObservedObject var model: AppModel

  public init(model: AppModel) { self.model = model }

  public var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Abrir repositorio…") { model.chooseRepository() }.keyboardShortcut("o")
      Button("Elegir PR…") { model.showPRPicker = true }.keyboardShortcut("p").disabled(model.repo == nil)
    }
    CommandGroup(after: .textEditing) {
      Button("Buscar…") { model.showFind() }.keyboardShortcut("f").disabled(model.location == nil)
      Button("Buscar siguiente") { model.findNext() }.keyboardShortcut("g").disabled(model.location == nil)
      Button("Buscar anterior") { model.findPrevious() }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(model.location == nil)
    }
    CommandMenu("Revisión") {
      Button("Siguiente") { model.step(1) }.keyboardShortcut("]")
      Button("Anterior") { model.step(-1) }.keyboardShortcut("[")
      Button("Siguiente sin revisar") { model.nextUnreviewed() }.keyboardShortcut("]", modifiers: [.command, .shift])
      Button("Marcar revisado") { model.toggleReviewed() }.keyboardShortcut("d")
      Button("Añadir nota…") { model.requestAddNote() }.keyboardShortcut("n", modifiers: [.command, .option])
      Button("Enviar notas a Claude") { model.sendNotesToClaude() }.keyboardShortcut(.return, modifiers: [.command, .option]).disabled(model.notesToSend.isEmpty)
      Button("Copiar notas para Claude") { model.copyNotesForClaude() }.disabled(model.notesToSend.isEmpty)
      Divider()
      Button("Atrás") { model.back() }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
      Button("Adelante") { model.forward() }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
      Button("Cambio siguiente") { model.jumpChange(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
      Button("Cambio anterior") { model.jumpChange(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
      Divider()
      Button("Explicar la PR con Claude") { model.explainPR() }.keyboardShortcut("e", modifiers: [.command, .shift])
      Button("Solo código") { model.toggleCodeOnly() }.keyboardShortcut("c", modifiers: [.command, .shift])
      Divider()
      Button("Acercar") { model.zoom = min(2, model.zoom + 0.1) }.keyboardShortcut("+")
      Button("Alejar") { model.zoom = max(0.3, model.zoom - 0.1) }.keyboardShortcut("-")
      Button("Tamaño real") { model.zoom = 1 }.keyboardShortcut("0")
    }
  }
}
