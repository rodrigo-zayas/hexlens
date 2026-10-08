import HexLensCore
import SwiftUI

/// Ir a fichero (⌘⇧O) / ir a clase (⌘O) con coincidencia difusa.
struct QuickOpenView: View {
  let mode: QuickOpenMode
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var selection = 0
  @State private var entries: [QuickOpenEntry] = []
  @FocusState private var focused: Bool

  private var results: [QuickOpenEntry] {
    guard !query.isEmpty else { return Array(entries.sorted { $0.name < $1.name }.prefix(200)) }
    let scored: [(QuickOpenEntry, Int)] = entries.compactMap { e in
      FuzzyMatch.score(query: query, candidate: e.name).map { (e, $0 + (e.changed ? 1 : 0)) }
    }
    return scored.sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }.prefix(200).map(\.0)
  }

  var body: some View {
    let shown = results
    VStack(spacing: 0) {
      TextField(mode == .file ? "Ir a fichero…" : "Ir a clase…", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .padding(12)
        .focused($focused)
        .onSubmit { open(shown) }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(shown.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
      Divider()
      if shown.isEmpty {
        Text("Sin coincidencias").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                row(e, selected: i == selection)
                  .id(i)
                  .contentShape(Rectangle())
                  .onTapGesture { model.openQuickOpen(e) }.handCursor()
              }
            }
          }
          .onChange(of: selection) { _, new in proxy.scrollTo(new) }
        }
      }
    }
    .frame(width: 640, height: 420)
    .onAppear { entries = model.quickOpenEntries(mode); focused = true }
    .onChange(of: query) { _, _ in selection = 0 }
  }

  private func open(_ shown: [QuickOpenEntry]) {
    guard shown.indices.contains(selection) else { return }
    model.openQuickOpen(shown[selection])
  }

  private func row(_ e: QuickOpenEntry, selected: Bool) -> some View {
    HStack(spacing: 8) {
      Text(e.name).fontWeight(.bold)
      Text(e.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
      Spacer(minLength: 8)
      if e.changed { Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("Cambia en la PR") }
      Text(e.layer).font(.caption).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .background(selected ? Color.accentColor.opacity(0.25) : .clear)
  }
}
