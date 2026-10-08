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
            Button("Ver PRs…") { model.showPRPicker = true }.handCursor()
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
    .overlay {
      // Flotante y no hoja: un clic fuera lo cierra.
      if model.usagePopup != nil {
        ZStack {
          Color.black.opacity(0.12).contentShape(Rectangle())
            .onTapGesture { model.usagePopup = nil }
          FloatingPopup {
            UsagesPopupView()
              .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
              .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
              .shadow(radius: 20)
          }
        }
        .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.12), value: model.usagePopup != nil)
    .onAppear { SwipeNavigation.install(model) }
    .sheet(isPresented: $model.showPRPicker) { PRPickerView().environmentObject(model) }
    .sheet(item: $model.quickOpen) { QuickOpenView(mode: $0).environmentObject(model) }
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
          Text("Base: \(model.baseOverride ?? pr.baseRefName)")
        }
        .help("Comparar la PR contra otra rama sin cambiarla en GitHub (útil en PRs apiladas)")
      }
    }
    ToolbarItemGroup(placement: .primaryAction) {
      Button { model.step(-1) } label: { Label("Anterior", systemImage: "chevron.up") }
        .help("Anterior en el orden de lectura (⌘[)")
      Button { model.step(1) } label: { Label("Siguiente", systemImage: "chevron.down") }
        .help("Siguiente en el orden de lectura (⌘])")
      Button { model.toggleReviewed() } label: { Label("Revisado", systemImage: "checkmark.circle") }
        .help("Marcar revisado (⌘D)")
      Button { model.explainPR() } label: { Label("Explicar PR", systemImage: "sparkles") }
        .disabled(model.session == nil)
        .help("Abre Claude en Terminal con un resumen de qué hace la PR")
      Menu {
        Picker("Contexto", selection: $model.contextMode) {
          ForEach(ContextMode.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Mostrar tests", isOn: $model.showTests)
        Button(model.columns == .detailOnly ? "Mostrar paneles" : "Solo código") { model.toggleCodeOnly() }
        Divider()
        Picker("Apariencia", selection: $model.appearance) {
          ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Button("Recargar") { model.reload() }.disabled(model.session == nil)
        if model.currentPR?.url != nil {
          Button("Abrir en GitHub") { model.openOnGitHub() }
        }
      } label: { Label("Más", systemImage: "ellipsis.circle") }
        .help("Contexto, tests, solo código, apariencia, recargar y GitHub")
    }
  }
}

/// Centro: barra de resumen y mapa.
struct CenterPane: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Metrics.m) {
        SummaryBar()
        Spacer(minLength: 0)
        Toggle(isOn: $model.showTests) {
          Label("Tests", systemImage: "testtube.2")
        }
        .toggleStyle(.button).handCursor()
        .controlSize(.small)
        .help("Mostrar u ocultar los tests en el mapa (⌘⇧T)")
      }
      .padding(.horizontal, Metrics.m).padding(.vertical, Metrics.s)
      Divider()
      GraphPane()
    }
  }
}

struct GraphPane: View {
  @EnvironmentObject var model: AppModel
  @State private var showPercent = false

  var body: some View {
    VStack(spacing: 0) {
      if let graph = model.graph {
        MapScrollView(model: model, graph: graph)
          .overlay(alignment: .bottomTrailing) {
            Text("\(Int(model.zoom * 100)) %")
              .font(.caption.monospacedDigit())
              .padding(.horizontal, 8).padding(.vertical, 4)
              .background(.regularMaterial, in: Capsule())
              .padding(10)
              .opacity(showPercent ? 1 : 0)
              .allowsHitTesting(false)
          }
          .onChange(of: model.zoom) { _, _ in
            withAnimation(.easeIn(duration: 0.1)) { showPercent = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
              withAnimation(.easeOut(duration: 0.4)) { showPercent = false }
            }
          }
      } else {
        Color(nsColor: .textBackgroundColor)
      }
    }
  }
}

/// Una línea: violaciones, avisos y punto de entrada sugerido.
struct SummaryBar: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    if let g = model.graph {
      let errors = g.violations.filter { $0.severity == .error }
      let warnings = g.violations.filter { $0.severity == .warning }
      HStack(spacing: Metrics.m) {
        if !errors.isEmpty { Tag(text: "\(errors.count) violaciones", symbol: "xmark.octagon", isError: true) }
        if !warnings.isEmpty { Tag(text: "\(warnings.count) avisos", symbol: "exclamationmark.triangle") }
        if let entry = g.entryPoint.flatMap(g.unit) {
          Button { model.select(entry.id) } label: { Tag(text: "Empieza por \(entry.typeName)", symbol: "flag") }
            .buttonStyle(.plain).handCursor()
            .help("Punto de entrada sugerido")
        }
      }
    }
  }
}

public struct ReviewCommands: Commands {
  @ObservedObject var model: AppModel

  public init(model: AppModel) { self.model = model }

  public var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Abrir repositorio…") { model.chooseRepository() }.keyboardShortcut("o", modifiers: [.command, .option])
      Button("Ir a clase…") { model.quickOpen = .type }.keyboardShortcut("o").disabled(model.session == nil)
      Button("Ir a fichero…") { model.quickOpen = .file }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.session == nil)
      Button("Elegir PR…") { model.showPRPicker = true }.keyboardShortcut("p").disabled(model.repo == nil)
    }
    CommandGroup(after: .textEditing) {
      Button("Estructura del fichero…") { model.showStructure = true }
        .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: .command)
        .disabled(model.location == nil)
      Button("Buscar…") { model.showFind() }.keyboardShortcut("f").disabled(model.location == nil)
      Button("Buscar siguiente") { model.findNext() }.keyboardShortcut("g").disabled(model.location == nil)
      Button("Buscar en el repo…") { model.showRepoSearch() }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(model.session == nil)
      Button("Buscar usos") { model.requestFindUsages() }
        .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)), modifiers: .option).disabled(model.location == nil)
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
      Button(model.sideBySide ? "Diff unificado" : "Diff lado a lado") { model.toggleSideBySide() }
        .keyboardShortcut("d", modifiers: [.command, .option]).disabled(model.location == nil)
      Button("Solo código") { model.toggleCodeOnly() }.keyboardShortcut("c", modifiers: [.command, .shift])
      Button(model.showTests ? "Ocultar tests" : "Mostrar tests") { model.showTests.toggle() }
        .keyboardShortcut("t", modifiers: [.command, .shift])
      Divider()
      Button("Acercar") { model.zoomIn() }.keyboardShortcut("+")
      Button("Alejar") { model.zoomOut() }.keyboardShortcut("-")
      Button("Tamaño real") { model.zoom = 1 }.keyboardShortcut("0")
      Button("Ajustar a la ventana") { model.fitToWindow() }.keyboardShortcut("9")
    }
  }
}
