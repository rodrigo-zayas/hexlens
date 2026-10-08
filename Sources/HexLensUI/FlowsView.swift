import HexLensCore
import SwiftUI

/// Flujos de la PR: los que describe el agente (Claude) o los del análisis estático.
struct FlowsView: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("", selection: $model.flowSource) {
          ForEach(FlowSource.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        Spacer()
      }
      .padding(.horizontal, 14).padding(.top, 10)
      switch model.flowSource {
      case .agent: AgentFlowsView()
      case .automatic: AutomaticFlowsView()
      }
    }
    .background(Color(nsColor: .textBackgroundColor))
  }
}

/// "Qué pasa cuando…": cada punto de entrada de la PR y la cadena de llamadas hasta salida.
struct AutomaticFlowsView: View {
  @EnvironmentObject var model: AppModel
  @State private var collapsed: Set<String> = []

  var body: some View {
    if let flows = model.flows {
      let shown = model.flowsOnlyChanges ? flows.map { $0.pruned() } : flows
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Qué pasa cuando entra una petición o un evento, paso a paso. Pulsa un paso para ver su código.")
              .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Toggle("Solo lo que cambia", isOn: $model.flowsOnlyChanges).toggleStyle(.checkbox).controlSize(.small)
          }
          if shown.isEmpty {
            Text("No se han encontrado puntos de entrada en la PR.").foregroundStyle(.secondary)
          }
          ForEach(shown) { flow in card(flow) }
        }
        .padding(14)
      }
    } else {
      ProgressView("Siguiendo las llamadas…").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func card(_ flow: FlowNode) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: flow.role.symbol).foregroundStyle(flow.layer.color)
        Button { open(flow) } label: {
          HStack(spacing: 0) {
            Text(flow.typeName).foregroundStyle(.secondary)
            Text(".\(flow.method)()").fontWeight(.semibold)
          }
          .font(.system(size: 13, design: .monospaced))
        }
        .buttonStyle(.plain)
        changeBadge(flow)
        Text(flow.role.label).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button { model.explainFlow(flow) } label: { Label("Explicar", systemImage: "sparkles") }
          .controlSize(.small)
          .help("Abre Claude en Terminal explicando este flujo")
      }
      .padding(.horizontal, 10).padding(.vertical, 8)
      .background(flow.layer.color.opacity(0.08))

      ForEach(rows(flow), id: \.node.id) { row in
        stepRow(row.node, depth: row.depth)
      }
      .padding(.vertical, 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(flow.layer.color.opacity(0.3)))
  }

  private func rows(_ flow: FlowNode) -> [(node: FlowNode, depth: Int)] {
    var out: [(FlowNode, Int)] = []
    func walk(_ n: FlowNode, _ d: Int) {
      out.append((n, d))
      if !collapsed.contains(n.id) { (n.children ?? []).forEach { walk($0, d + 1) } }
    }
    (flow.children ?? []).forEach { walk($0, 1) }
    return out.map { (node: $0.0, depth: $0.1) }
  }

  private func stepRow(_ n: FlowNode, depth: Int) -> some View {
    let selected = model.location?.path == n.path && model.location?.line == n.line
    return HStack(spacing: 6) {
      Color.clear.frame(width: CGFloat(depth - 1) * 20)
      if n.children != nil {
        Button {
          if collapsed.contains(n.id) { collapsed.remove(n.id) } else { collapsed.insert(n.id) }
        } label: {
          Image(systemName: collapsed.contains(n.id) ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(.plain).frame(width: 12)
      } else {
        Text("→").foregroundStyle(.tertiary).frame(width: 12)
      }
      Image(systemName: n.role.symbol).font(.system(size: 11)).foregroundStyle(n.layer.color).frame(width: 16)
      Button { open(n) } label: {
        HStack(spacing: 0) {
          Text(n.typeName).foregroundStyle(n.inPR ? .primary : .secondary)
          Text(".\(n.method)()").foregroundStyle(n.change == nil ? .secondary : .primary)
        }
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
      }
      .buttonStyle(.plain)
      if let note = n.note { Pill(text: note, color: .purple) }
      changeBadge(n)
      Text(n.role.label).font(.system(size: 10)).foregroundStyle(.tertiary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10).padding(.vertical, 3)
    .background(selected ? Color.accentColor.opacity(0.15) : .clear)
    .contentShape(Rectangle())
    .onTapGesture { open(n) }
  }

  @ViewBuilder
  private func changeBadge(_ n: FlowNode) -> some View {
    switch n.change {
    case .added: Pill(text: "nuevo", color: .green)
    case .modified: Pill(text: "cambia", color: .orange)
    case .removed: Pill(text: "quitado", color: .red)
    case nil: if !n.inPR { Text("sin cambios").font(.system(size: 10)).italic().foregroundStyle(.tertiary) }
    }
  }

  private func open(_ n: FlowNode) {
    model.go(to: CodeLocation(path: n.path, line: n.line))
  }
}
