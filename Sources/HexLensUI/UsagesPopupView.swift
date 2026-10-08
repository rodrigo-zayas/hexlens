import AppKit
import HexLensCore
import SwiftUI

/// Resultados de "Buscar usos", agrupados por fichero, con filtro y teclado.
struct UsagesPopupView: View {
  @EnvironmentObject var model: AppModel
  @State private var filter = ""
  @State private var query = ""
  @State private var hovered: UsageHit?
  @State private var selection: UsageHit?
  @FocusState private var filterFocused: Bool
  @State private var keyMonitor = PopupKeyMonitor()
  @State private var wasGlobal = false

  private var state: UsagePopupState { model.usagePopup ?? UsagePopupState(word: "", groups: [], loading: false) }

  private var groups: [UsageGroup] {
    let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return state.groups }
    return state.groups.compactMap { g in
      if g.path.lowercased().contains(q) { return g }
      let hits = g.hits.filter { $0.text.lowercased().contains(q) }
      return hits.isEmpty ? nil : UsageGroup(path: g.path, hits: hits)
    }
  }

  private var flat: [UsageHit] { groups.flatMap(\.hits) }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        if state.global {
          Text("Buscar en el repo").foregroundStyle(.secondary)
        } else {
          Text("Usos de ").foregroundStyle(.secondary) + Text(state.word).bold().font(.system(.body, design: .monospaced))
        }
        Spacer()
        if state.loading { ProgressView().controlSize(.small) }
        else if !state.word.isEmpty {
          Text("\(flat.count) \(state.global ? "resultados" : "usos") en \(groups.count) ficheros").foregroundStyle(.secondary).font(.caption)
        }
      }
      .padding(10)
      .frame(height: FloatingPopupPosition.handleHeight)
      if state.global {
        TextField("Texto a buscar en todo el repo (↩)", text: $query)
          .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
          .padding(.horizontal, 10).padding(.bottom, 8)
          .focused($filterFocused)
      } else {
        TextField("Filtrar", text: $filter)
          .textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
          .focused($filterFocused)
      }
      Divider()
      ScrollViewReader { proxy in
        List {
          ForEach(groups, id: \.path) { g in
            Section {
              ForEach(g.hits, id: \.self) { h in
                row(h).id(h)
                  .listRowBackground(
                    selection == h ? Color.accentColor.opacity(0.25) : hovered == h ? Color.primary.opacity(0.08) : Color.clear)
                  .contentShape(Rectangle())
                  .onHover { inside in
                    if inside { hovered = h } else if hovered == h { hovered = nil }
                  }
                  .onTapGesture { open(h) }.handCursor()
              }
            } header: { header(g) }
          }
        }
        .listStyle(.plain)
        .onChange(of: selection) { _, new in if let new { proxy.scrollTo(new) } }
      }
      if !state.loading && flat.isEmpty && !state.word.isEmpty {
        Text("Sin resultados").foregroundStyle(.secondary).padding()
      }
    }
    .frame(width: 720, height: 460)
    .onAppear {
      query = state.word; wasGlobal = state.global; filterFocused = true; selection = flat.first
      // Texto seleccionado al abrir: se puede seguir con él, borrarlo o escribir encima.
      selectFieldText()
    }
    .onChange(of: filter) { _, _ in selection = flat.first }
    .onChange(of: state.groups) { _, _ in selection = flat.first }
    .onAppear { keyMonitor.install(keys) }
    .onDisappear {
      keyMonitor.remove()
      // Al cerrar, model.usagePopup ya es nil: se usa lo capturado al abrir.
      if wasGlobal { model.rememberRepoQuery(query) }
    }
  }

  private func header(_ g: UsageGroup) -> some View {
    HStack(spacing: 6) {
      Text((g.path as NSString).lastPathComponent).bold()
      Text((g.path as NSString).deletingLastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
      if state.changed.contains(g.path) { Text("PR").font(.caption2).padding(.horizontal, 4).background(.orange.opacity(0.3), in: Capsule()) }
      Spacer()
      Text("\(g.hits.count)").foregroundStyle(.secondary).font(.caption)
    }.font(.system(size: 12))
  }

  private func row(_ h: UsageHit) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(h.line)").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
      Text(highlighted(h.text.trimmingCharacters(in: .whitespaces))).lineLimit(1)
    }.font(.system(size: 12, design: .monospaced))
  }

  private func highlighted(_ text: String) -> AttributedString {
    var a = AttributedString(String(text.prefix(200)))
    let word = state.word
    guard !word.isEmpty else { return a }
    var from = a.startIndex
    while let r = a[from...].range(of: word) {
      let before = r.lowerBound > a.startIndex ? a.characters[a.characters.index(before: r.lowerBound)] : " "
      let after = r.upperBound < a.endIndex ? a.characters[r.upperBound] : " "
      if !(before.isLetter || before.isNumber || before == "_") && !(after.isLetter || after.isNumber || after == "_") {
        a[r].font = .system(size: 12, design: .monospaced).bold()
      }
      from = r.upperBound
    }
    return a
  }

  /// Teclado como en el IDE: ↑/↓ recorren resultados (también desde el campo), ⇞/⇟ saltan 10, ↩ abre, Esc cierra.
  private var keys: PopupKeys {
    PopupKeys(
      move: move,
      submit: {
        if state.global, query != state.word { model.searchRepo(query) } else if let s = selection { open(s) }
      },
      close: { model.usagePopup = nil })
  }

  /// Selecciona el texto del campo del panel (nunca el del visor): espera a que el foco llegue al campo.
  private func selectFieldText(attempt: Int = 0) {
    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
      editor.selectAll(nil)
    } else if attempt < 10 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { selectFieldText(attempt: attempt + 1) }
    }
  }

  private func move(_ d: Int) {
    let items = flat
    guard !items.isEmpty else { return }
    let i = selection.flatMap { items.firstIndex(of: $0) } ?? (d > 0 ? -1 : items.count)
    selection = items[max(0, min(items.count - 1, i + d))]
  }

  private func open(_ h: UsageHit) {
    model.openSearchHit(h, query: state.word, global: state.global)
  }
}

/// Panel flotante que se arrastra por su franja superior. El arrastre vive aquí (y no en la vista
/// padre) para que cada movimiento solo redibuje este contenedor y vaya fluido.
struct FloatingPopup<Content: View>: View {
  @ViewBuilder var content: Content
  @State private var offset = FloatingPopupPosition.saved
  @GestureState private var drag = CGSize.zero

  var body: some View {
    content
      .overlay(alignment: .top) {
        Color.clear
          .frame(height: FloatingPopupPosition.handleHeight)
          .contentShape(Rectangle())
          .onContinuousHover { phase in
            // Durante el arrastre manda la mano cerrada aunque el ratón se salga de la franja.
            guard drag == .zero else { NSCursor.closedHand.set(); return }
            if case .active = phase { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
          }
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
              .updating($drag) { g, state, _ in state = g.translation }
              .onChanged { _ in NSCursor.closedHand.set() }
              .onEnded { g in
                offset.width += g.translation.width
                offset.height += g.translation.height
                FloatingPopupPosition.saved = offset
                NSCursor.openHand.set()
              }
          )
          .help("Arrastra para mover")
      }
      .compositingGroup()
      .offset(x: offset.width + drag.width, y: offset.height + drag.height)
  }
}

/// Posición del panel entre aperturas mientras la app sigue abierta.
@MainActor enum FloatingPopupPosition {
  static var saved = CGSize.zero
  static let handleHeight: CGFloat = 40
}

private struct PopupKeys {
  let move: (Int) -> Void
  let submit: () -> Void
  let close: () -> Void
}

/// Captura el teclado de la ventana mientras el panel está abierto, tenga quien tenga el foco.
private final class PopupKeyMonitor {
  private var monitor: Any?

  func install(_ keys: PopupKeys) {
    remove()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
      let mods = e.modifierFlags.intersection([.command, .option, .control])
      guard mods.isEmpty else { return e }
      switch e.keyCode {
      case 53: keys.close()
      case 125: keys.move(1)
      case 126: keys.move(-1)
      case 121: keys.move(10)
      case 116: keys.move(-10)
      case 36, 76: keys.submit()
      default: return e
      }
      return nil
    }
  }

  func remove() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  deinit { remove() }
}
