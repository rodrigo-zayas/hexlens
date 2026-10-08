import HexLensCore
import SwiftUI

/// Flujos descritos por Claude Code, anclados a código real y navegables.
struct AgentFlowsView: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    switch model.agentState {
    case .idle: empty
    case .running(let started): running(started)
    case .failed(let message): failed(message)
    case .done: report
    }
  }

  // MARK: - Estados

  private var empty: some View {
    VStack(spacing: 14) {
      Image(systemName: "sparkles").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
      Text("Flujos de la PR").font(.title2.weight(.semibold))
      Text("Un agente de Claude Code lee la PR con git (solo lectura) y describe cada flujo de punta a punta: qué lo dispara, qué pasa en cada paso y qué revisar. Cada paso se comprueba contra el código.")
        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
      switch model.claudeAuth {
      case .loggedOut:
        Button { model.loginClaude() } label: { Label("Iniciar sesión en Claude", systemImage: "person.crop.circle.badge.checkmark") }
          .buttonStyle(.borderedProminent).controlSize(.large)
        Text("Se abre Terminal con `claude auth login` (inicio de sesión en el navegador). Solo hace falta una vez; al terminar, el agente arranca solo.")
          .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
      case .checking, .unknown:
        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Comprobando la sesión de Claude…").foregroundStyle(.secondary) }
      case .loggedIn(let who):
        HStack(spacing: 10) {
          ModelPicker()
          Button { model.runAgent() } label: { Label("Generar con Claude", systemImage: "sparkles") }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        Text("Sesión de Claude Code\(who.map { ": \($0)" } ?? " iniciada")").font(.caption).foregroundStyle(.secondary)
      }
      Button("Ver el análisis automático") { model.flowSource = .automatic }.buttonStyle(.link)
    }
    .padding(30)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func running(_ started: Date) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text("\(model.agentModelID.map(ClaudeModel.displayName) ?? model.claudeModel.name) está leyendo la PR…").font(.headline)
          .help(model.agentModelID ?? "")
        TimelineView(.periodic(from: started, by: 1)) { ctx in
          Text(Duration.seconds(ctx.date.timeIntervalSince(started)).formatted(.time(pattern: .minuteSecond)))
            .monospacedDigit().foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancelar") { model.cancelAgent() }
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.agentLog.enumerated()), id: \.offset) { i, line in
              Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(2).id(i)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.agentLog.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
      }
    }
    .padding(16)
  }

  private func failed(_ message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle").font(.system(size: 32)).foregroundStyle(.orange)
      Text("El agente no ha podido terminar").font(.headline)
      Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
        .frame(maxWidth: 520)
      if message.contains("authenticate") || message.contains("login") {
        Text("La CLI `claude` no tiene sesión propia (la de la app de escritorio de Claude no le sirve).").font(.callout)
        Button("Iniciar sesión en Claude") { model.loginClaude() }.buttonStyle(.borderedProminent)
      }
      HStack {
        ModelPicker()
        Button("Reintentar") { model.runAgent() }.buttonStyle(.borderedProminent)
        Button("Ver el análisis automático") { model.flowSource = .automatic }
      }
    }
    .padding(30)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var report: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        if let r = model.agentReport {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
              Text(r.summary).font(.system(size: 14)).textSelection(.enabled)
              Text("Generado con \(model.agentModelID.map { "\(ClaudeModel.displayName($0)) (\($0))" } ?? "Claude")")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            ModelPicker()
            Button { model.runAgent() } label: { Image(systemName: "arrow.clockwise") }
              .buttonStyle(.borderless).help("Volver a generar con el modelo elegido")
          }
          .padding(12)
          .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
        ForEach(model.agentFlows) { flow in FlowCard(flow: flow) }
        if let notes = model.agentReport?.notes, !notes.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("Además").font(.subheadline.weight(.semibold))
            ForEach(notes, id: \.self) { Text("· \($0)").font(.callout).foregroundStyle(.secondary) }
          }
        }
      }
      .padding(14)
    }
  }
}

private struct FlowCard: View {
  @EnvironmentObject var model: AppModel
  let flow: VerifiedFlow

  private var active: Bool { model.activeFlow == flow.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text(flow.flow.title).font(.headline)
          if let trigger = flow.flow.trigger {
            Text(trigger).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          Button {
            model.activeFlow = active ? nil : flow.id
            if !active { model.centerMode = .map }
          } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
            .buttonStyle(.borderless).help("Ver este flujo en el mapa")
          Button { model.askAbout(flow) } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
            .buttonStyle(.borderless).help("Preguntar a Claude en Terminal sobre este flujo")
        }
        Text(flow.flow.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
        LayerStrip(steps: flow.steps)
      }
      .padding(12)
      .background(Color.accentColor.opacity(active ? 0.12 : 0.04))

      VStack(alignment: .leading, spacing: 0) {
        ForEach(flow.steps) { step in StepRow(step: step) }
      }
      .padding(.vertical, 4)

      if let review = flow.flow.review, !review.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(review, id: \.self) { r in
            Label(r, systemImage: "eye").font(.system(size: 12)).foregroundStyle(.orange)
          }
        }
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 2)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(active ? 0.5 : 0.2)))
  }
}

/// Recorrido del flujo por las capas: Entrada → Aplicación → Dominio → Salida.
private struct LayerStrip: View {
  let steps: [VerifiedStep]

  var body: some View {
    var layers: [Layer] = []
    for s in steps where layers.last != s.layer { layers.append(s.layer) }
    return HStack(spacing: 4) {
      ForEach(Array(layers.enumerated()), id: \.offset) { i, l in
        if i > 0 { Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
        Text(l.title).font(.system(size: 10, weight: .medium))
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(l.color.opacity(0.15), in: Capsule()).foregroundStyle(l.color)
      }
    }
  }
}

private struct StepRow: View {
  @EnvironmentObject var model: AppModel
  let step: VerifiedStep

  var body: some View {
    let selected = model.location?.path == step.path && model.location?.line == step.line
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Color.clear.frame(width: CGFloat(step.step.depth ?? 0) * 18, height: 1)
      Circle().fill(step.layer.color).frame(width: 7, height: 7)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text(step.step.symbol).font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(step.verified ? .primary : .secondary)
          switch step.change {
          case .added: Pill(text: "nuevo", color: .green)
          case .modified: Pill(text: "cambia", color: .orange)
          case .removed: Pill(text: "quitado", color: .red)
          case nil: EmptyView()
          }
          if !step.verified {
            Image(systemName: "questionmark.circle").foregroundStyle(.orange).help("No se ha encontrado en el código de la PR")
          }
        }
        Text(step.step.what).font(.system(size: 12)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12).padding(.vertical, 4)
    .background(selected ? Color.accentColor.opacity(0.15) : .clear)
    .contentShape(Rectangle())
    .onTapGesture {
      if let path = step.path { model.go(to: CodeLocation(path: path, line: step.line)) }
    }
  }
}

/// Modelo de Claude para el agente y para "Explicar", con versión explícita.
struct ModelPicker: View {
  @EnvironmentObject var model: AppModel
  @State private var askingCustom = false
  @State private var custom = ""

  var body: some View {
    Menu {
      Button(ClaudeModel.automatic.label) { model.claudeModelID = "" }
      Divider()
      ForEach(ClaudeModel.catalog) { m in
        Button { model.claudeModelID = m.id } label: {
          if m.id == model.claudeModelID { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
        }
      }
      Divider()
      Button("Otro ID…") { custom = model.claudeModelID; askingCustom = true }
    } label: {
      Label(model.claudeModelID.isEmpty ? ClaudeModel.automatic.label : model.claudeModel.name, systemImage: "cpu")
    }
    .fixedSize()
    .help(model.claudeModelID.isEmpty ? "Modelo configurado en tu Claude Code" : model.claudeModelID)
    .popover(isPresented: $askingCustom) {
      VStack(alignment: .leading, spacing: 8) {
        Text("ID del modelo").font(.headline)
        TextField("p. ej. claude-opus-4-5", text: $custom).frame(width: 260)
          .onSubmit(apply)
        HStack {
          Spacer()
          Button("Usar", action: apply).keyboardShortcut(.defaultAction).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      .padding(14)
    }
  }

  private func apply() {
    model.claudeModelID = custom.trimmingCharacters(in: .whitespaces)
    askingCustom = false
  }
}
