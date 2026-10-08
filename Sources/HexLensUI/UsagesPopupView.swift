import HexLensCore
import SwiftUI

/// Resultados de "Buscar usos", agrupados por fichero, con filtro y teclado.
struct UsagesPopupView: View {
  @EnvironmentObject var model: AppModel
  @State private var filter = ""
  @State private var query = ""
  @State private var selection: UsageHit?
  @FocusState private var filterFocused: Bool

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
      }.padding(10)
      if state.global {
        TextField("Texto a buscar en todo el repo (↩)", text: $query)
          .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
          .padding(.horizontal, 10).padding(.bottom, 8)
          .focused($filterFocused)
          .onSubmit { model.searchRepo(query) }
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
                  .listRowBackground(selection == h ? Color.accentColor.opacity(0.25) : Color.clear)
                  .contentShape(Rectangle())
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
    .onAppear { query = state.word; filterFocused = true; selection = flat.first }
    .onChange(of: filter) { _, _ in selection = flat.first }
    .onChange(of: state.groups) { _, _ in selection = flat.first }
    .onKeyPress(.downArrow) { move(1); return .handled }
    .onKeyPress(.upArrow) { move(-1); return .handled }
    .onKeyPress(.return) {
      if state.global, query != state.word { model.searchRepo(query) } else if let s = selection { open(s) }
      return .handled
    }
    .onKeyPress(.escape) { model.usagePopup = nil; return .handled }
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

  private func move(_ d: Int) {
    let items = flat
    guard !items.isEmpty else { return }
    let i = selection.flatMap { items.firstIndex(of: $0) } ?? (d > 0 ? -1 : items.count)
    selection = items[max(0, min(items.count - 1, i + d))]
  }

  private func open(_ h: UsageHit) {
    model.usagePopup = nil
    model.go(to: CodeLocation(path: h.path, line: h.line))
  }
}
