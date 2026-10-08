import HexLensCore
import SwiftUI

/// Lista de la PR en el orden de lectura elegido, agrupada por capa.
struct SidebarView: View {
  @EnvironmentObject var model: AppModel

  private struct Section_: Identifiable {
    let id: String
    let title: String
    let color: Color
    var items: [String]
  }

  private var sections: [Section_] {
    guard let g = model.graph else { return [] }
    var result: [Section_] = []
    for id in model.order {
      guard let u = g.unit(id) else { continue }
      // Los tests van con su clase; los huérfanos y lo que no es código, aparte.
      let key: String, title: String, color: Color
      if let subject = g.subjectByTest[id], let s = g.unit(subject) {
        key = s.layer.rawValue; title = s.layer.title; color = s.layer.color
      } else if u.isTest {
        key = "tests"; title = "Tests y fixtures"; color = .green
      } else if !u.isCode {
        key = "files"; title = "Otros ficheros"; color = .gray
      } else {
        key = u.layer.rawValue; title = u.layer.title; color = u.layer.color
      }
      if result.last?.id == key {
        result[result.count - 1].items.append(id)
      } else {
        result.append(Section_(id: key + "\(result.count)", title: title, color: color, items: [id]))
      }
    }
    return result
  }

  var body: some View {
    List(selection: Binding(get: { model.selectedID }, set: { id in
      // Fuera del callback de la tabla: cambiar la selección dentro de él es reentrante.
      if id != model.selectedID { DispatchQueue.main.async { model.select(id) } }
    })) {
      if let s = model.session {
        VStack(alignment: .leading, spacing: 6) {
          Text(s.title).font(.headline).lineLimit(3)
          ProgressView(value: Double(model.reviewedCount), total: Double(max(model.changedCount, 1)))
          Text("\(model.reviewedCount) de \(model.changedCount) revisados").font(.caption).foregroundStyle(.secondary)
          Picker("Orden", selection: $model.strategy) {
            ForEach(ReadingStrategy.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden()
        }
        .padding(.vertical, 4)
        .selectionDisabled()

        if !model.notes.isEmpty || !model.claudeSessions.isEmpty { NotesSection().selectionDisabled() }

        let numbers = Dictionary(model.order.enumerated().map { ($1, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        ForEach(sections) { section in
          Section {
            ForEach(section.items, id: \.self) { id in
              if let u = model.graph?.unit(id) {
                FileRow(unit: u, number: numbers[id] ?? 0,
                        nested: model.graph?.subjectByTest[id] != nil,
                        reviewed: model.reviewed.contains(id),
                        violations: model.graph?.violations(of: id).count ?? 0) {
                  model.toggleReviewed(id)
                }
                .tag(id)
              }
            }
          } header: {
            HStack(spacing: 5) {
              Circle().fill(section.color).frame(width: 7, height: 7)
              Text(section.title)
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
  }
}

private struct FileRow: View {
  let unit: CodeUnit
  let number: Int
  let nested: Bool
  let reviewed: Bool
  let violations: Int
  let toggle: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button(action: toggle) {
        Image(systemName: reviewed ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(reviewed ? .green : .secondary)
      }
      .buttonStyle(.plain)
      .help("Marcar revisado")

      Text("\(number)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary).frame(width: 20, alignment: .trailing)
      if nested { Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
      Text(unit.status.letter)
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(unit.status.color)
      Image(systemName: unit.isTest ? "testtube.2" : unit.role.symbol)
        .font(.system(size: 11))
        .foregroundStyle(unit.isTest ? .green : unit.layer.color)
      VStack(alignment: .leading, spacing: 0) {
        Text(unit.isCode ? unit.typeName : unit.fileName)
          .lineLimit(1).truncationMode(.middle)
          .strikethrough(unit.status == .deleted)
          .foregroundStyle(reviewed ? .secondary : .primary)
        Text(unit.isCode ? "\(unit.role.label) · \(unit.packageLabel)" : unit.path)
          .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
      }
      Spacer(minLength: 0)
      if violations > 0 { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 10)) }
      Text("+\(unit.additions)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.green)
    }
  }
}


/// Notas de la PR: fichero:líneas y primera línea del texto; clic salta al código.
private struct NotesSection: View {
  @EnvironmentObject var model: AppModel
  @State private var expanded = true

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      ClaudeSessionRow()
      ForEach(model.notes) { n in
        Button { model.goToNote(n.id) } label: {
          VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
              Text("\((n.path as NSString).lastPathComponent):\(n.startLine == n.endLine ? "\(n.startLine)" : "\(n.startLine)-\(n.endLine)")")
                .font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
              if n.outdated { Pill(text: "desactualizada", color: .gray) }
            }
            Text(n.body.split(separator: "\n").first.map(String.init) ?? "")
              .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(n.path)
      }
    } label: {
      Label("Notas (\(model.notes.count))", systemImage: "note.text").font(.subheadline.weight(.semibold))
    }
  }
}

/// Sesión de Claude enlazada a la rama: título y antigüedad, con menú para cambiarla.
private struct ClaudeSessionRow: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    Menu {
      ForEach(model.claudeSessions) { s in
        Button { model.linkSession(s.id) } label: {
          Text("\(s.id == model.linkedSessionID ? "✓ " : "")\(s.title) · \(Self.ago(s.lastActivity))")
        }
      }
      if !model.claudeSessions.isEmpty { Divider() }
      Button("Nueva sesión") { model.linkSession(nil) }
      Button("Quitar enlace") { model.linkSession(nil) }.disabled(model.linkedSessionID == nil)
    } label: {
      if let s = model.linkedSession {
        Text("Sesión de Claude: \(s.title) · \(Self.ago(s.lastActivity))").lineLimit(1)
      } else {
        Text("Sesión de Claude: nueva")
      }
    }
    .menuStyle(.borderlessButton)
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
  }

  static func ago(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "es")
    f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
  }
}
