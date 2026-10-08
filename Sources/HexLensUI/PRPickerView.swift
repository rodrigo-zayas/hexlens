import HexLensCore
import SwiftUI

struct PRPickerView: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var number = ""
  @State private var base = "origin/develop"
  @State private var head = "HEAD"

  private var filtered: [PullRequestSummary] {
    guard !query.isEmpty else { return model.pullRequests }
    return model.pullRequests.filter {
      $0.title.localizedCaseInsensitiveContains(query) || "\($0.number)".contains(query)
        || ($0.author?.login.localizedCaseInsensitiveContains(query) ?? false)
        || $0.headRefName.localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(model.repo?.name ?? "").font(.title3.weight(.semibold))
        Spacer()
        Picker("", selection: $model.prFilter) {
          ForEach(PRFilter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 300)
        Button { model.refreshPRs() } label: { Image(systemName: "arrow.clockwise") }
      }

      TextField("Filtrar por título, número, autor o rama", text: $query)
        .textFieldStyle(.roundedBorder)

      Group {
        if model.loadingPRs {
          ProgressView("Consultando GitHub…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
          ContentUnavailableView("Sin PRs", systemImage: "tray", description: Text("Prueba con otro filtro o abre una por número."))
        } else {
          List(filtered) { pr in
            Button { model.open(pr) } label: { PRRow(pr: pr) }
              .buttonStyle(.plain)
          }
          .listStyle(.inset(alternatesRowBackgrounds: true))
        }
      }
      .frame(minHeight: 320)

      Divider()
      HStack(spacing: 8) {
        Text("PR nº").foregroundStyle(.secondary)
        TextField("12345", text: $number).frame(width: 90)
          .onSubmit(openNumber)
        Button("Abrir", action: openNumber).disabled(Int(number) == nil)
        Spacer()
        Text("o comparar").foregroundStyle(.secondary)
        TextField("base", text: $base).frame(width: 140)
        Text("…")
        TextField("cabeza", text: $head).frame(width: 140)
        Button("Comparar") { model.compare(base: base, head: head) }
      }
      .textFieldStyle(.roundedBorder)

      HStack {
        Spacer()
        Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(18)
    .frame(width: 820, height: 560)
  }

  private func openNumber() {
    if let n = Int(number) {
      model.showPRPicker = false
      model.openPR(number: n)
    }
  }
}

private struct PRRow: View {
  let pr: PullRequestSummary

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text("#\(pr.number)").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          if pr.isDraft == true { Tag(text: "draft") }
          Text(pr.title).lineLimit(2)
        }
        Text("\(pr.author?.login ?? "?") · \(pr.headRefName) → \(pr.baseRefName)")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        HStack(spacing: 4) {
          Text("+\(pr.additions ?? 0)").foregroundStyle(Semantic.added)
          Text("−\(pr.deletions ?? 0)").foregroundStyle(Semantic.removed)
        }
        Text("\(pr.changedFiles ?? 0) ficheros").foregroundStyle(.secondary)
      }
      .font(.caption.monospacedDigit())
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

struct WelcomeView: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "hexagon").font(.system(size: 56, weight: .thin)).foregroundStyle(.secondary)
      Text("HexLens").font(.largeTitle.weight(.semibold))
      Text("Revisa una PR de Java como un hexágono: capas, paquetes y relaciones, y el diff al pulsar.")
        .foregroundStyle(.secondary)
      Button("Abrir repositorio…") { model.chooseRepository() }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      if !model.recentRepos.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Recientes").font(.caption).foregroundStyle(.secondary)
          ForEach(model.recentRepos, id: \.self) { path in
            Button((path as NSString).lastPathComponent) { model.openRepository(URL(fileURLWithPath: path)) }
              .buttonStyle(.link)
              .help(path)
          }
        }
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
