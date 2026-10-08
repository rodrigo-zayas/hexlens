import HexLensCore
import SwiftUI

/// Lienzo del mapa: zonas, módulos, contextos, nodos por fichero y aristas.
public struct GraphCanvas: View {
  let graph: PRGraph
  let layout: GraphLayout
  var selectedID: String?
  var hoveredID: String?
  var reviewed: Set<String> = []
  var onSelect: (String) -> Void = { _ in }
  var onHover: (String?) -> Void = { _ in }
  private(set) var zoom: CGFloat = 1

  public init(
    graph: PRGraph, layout: GraphLayout, selectedID: String? = nil, hoveredID: String? = nil,
    reviewed: Set<String> = [], onSelect: @escaping (String) -> Void = { _ in },
    onHover: @escaping (String?) -> Void = { _ in }, zoom: CGFloat = 1
  ) {
    self.zoom = zoom
    self.graph = graph
    self.layout = layout
    self.selectedID = selectedID
    self.hoveredID = hoveredID
    self.reviewed = reviewed
    self.onSelect = onSelect
    self.onHover = onHover
  }

  mutating func zoomOverride(_ z: CGFloat) { zoom = z }

  static let zoneColors: [Color] = [.blue, .green, .orange, .purple, .gray]

  static func symbol(forTechnology tech: String) -> String {
    switch tech {
    case "rest": "network"
    case "pipe", "kafka": "arrow.left.arrow.right"
    case "grpc": "point.3.connected.trianglepath.dotted"
    case "mongo": "leaf"
    case "db2", "jdbc", "jpa": "cylinder"
    case "redis": "memorychip"
    default: "cube"
    }
  }

  private var showLabels: Bool { zoom >= 0.5 }

  private var focus: String? { hoveredID ?? selectedID }

  private var visibleEdges: [Dependency] {
    graph.edges.filter { layout.frames[$0.from] != nil && layout.frames[$0.to] != nil }
  }

  private var neighborhood: Set<String> {
    guard let f = focus else { return [] }
    var s: Set<String> = [f]
    for e in visibleEdges where e.from == f || e.to == f { s.insert(e.from); s.insert(e.to) }
    return s
  }

  private var violatingEdges: Set<String> {
    Set(graph.violations.compactMap { v in v.targetID.map { "\(v.unitID)→\($0)" } })
  }

  public var body: some View {
    let near = neighborhood
    ZStack(alignment: .topLeading) {
      Text("Perfil: \(layout.profileName)")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .offset(x: GraphLayout.margin, y: 5)

      ForEach(layout.zones) { band in
        let tint = Self.zoneColors[band.index % Self.zoneColors.count]
        RoundedRectangle(cornerRadius: 14)
          .fill(tint.opacity(0.07))
          .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.28)))
          .frame(width: band.frame.width, height: band.frame.height)
          .offset(x: band.frame.minX, y: band.frame.minY)
        VStack(alignment: .leading, spacing: 2) {
          Text(band.zone.title).font(.system(size: 22, weight: .bold)).foregroundStyle(tint)
          Text(band.zone.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(width: band.frame.width - 28, alignment: .leading)
        .offset(x: band.frame.minX + 14, y: band.frame.minY + 12)
      }

      ForEach(layout.containers) { box in
        let radius: CGFloat = box.level == 1 ? 10 : 7
        RoundedRectangle(cornerRadius: radius)
          .fill(box.level == 1 ? Color(nsColor: .windowBackgroundColor).opacity(0.75) : Color.primary.opacity(0.03))
          .overlay(
            RoundedRectangle(cornerRadius: radius)
              .strokeBorder(box.level == 1 ? Color.secondary.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1))
          .frame(width: box.frame.width, height: box.frame.height)
          .offset(x: box.frame.minX, y: box.frame.minY)
        HStack(spacing: 5) {
          if let tech = box.technology {
            Label(tech, systemImage: Self.symbol(forTechnology: tech))
              .font(.system(size: 10, weight: .medium))
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Color.accentColor.opacity(0.14), in: Capsule())
          }
          Text(box.title).font(.system(size: box.level == 1 ? 13 : 11, weight: box.level == 1 ? .semibold : .medium))
          if !box.subtitle.isEmpty {
            Text(box.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
        .lineLimit(1)
        .frame(width: box.frame.width - 16, alignment: .leading)
        .offset(x: box.frame.minX + 8, y: box.frame.minY + (box.level == 1 ? 8 : 4))
      }

      Canvas { ctx, _ in
        let bad = violatingEdges
        // Primero las aristas apagadas, encima las del foco.
        let edges = visibleEdges.sorted { a, _ in !(near.contains(a.from) && near.contains(a.to)) }
        for e in edges {
          guard let a = layout.frames[e.from], let b = layout.frames[e.to] else { continue }
          let inFocus = (focus == nil || e.from == focus || e.to == focus)
          drawEdge(ctx, from: a, to: b, kind: e.kind, violation: bad.contains(e.id), emphasised: focus != nil && inFocus, dimmed: !inFocus)
        }
      }
      .frame(width: layout.size.width, height: layout.size.height)
      .allowsHitTesting(false)

      ForEach(graph.units.filter { layout.frames[$0.id] != nil }) { unit in
        let frame = layout.frames[unit.id]!
        NodeView(
          unit: unit,
          selected: unit.id == selectedID,
          dimmed: focus != nil && !near.contains(unit.id),
          reviewed: reviewed.contains(unit.id),
          isEntry: unit.id == graph.entryPoint,
          tests: graph.tests(of: unit.id).count,
          violations: graph.violations(of: unit.id).count,
          showLabels: showLabels)
          .frame(width: frame.width, height: frame.height)
          .contentShape(Rectangle())
          .onTapGesture { onSelect(unit.id) }
          .onHover { inside in onHover(inside ? unit.id : nil) }
          .id(unit.id)
          .position(x: frame.midX, y: frame.midY)
      }
    }
    .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
  }

  private func drawEdge(
    _ ctx: GraphicsContext, from a: CGRect, to b: CGRect, kind: Dependency.Kind,
    violation: Bool, emphasised: Bool, dimmed: Bool
  ) {
    var start: CGPoint, end: CGPoint, c1: CGPoint, c2: CGPoint
    if a.maxX < b.minX {
      start = CGPoint(x: a.maxX, y: a.midY); end = CGPoint(x: b.minX, y: b.midY)
      let dx = max(40, (end.x - start.x) / 2)
      c1 = CGPoint(x: start.x + dx, y: start.y); c2 = CGPoint(x: end.x - dx, y: end.y)
    } else if a.minX > b.maxX {
      start = CGPoint(x: a.minX, y: a.midY); end = CGPoint(x: b.maxX, y: b.midY)
      let dx = max(40, (start.x - end.x) / 2)
      c1 = CGPoint(x: start.x - dx, y: start.y); c2 = CGPoint(x: end.x + dx, y: end.y)
    } else {
      // Misma columna: bucle por la derecha.
      start = CGPoint(x: a.maxX, y: a.midY); end = CGPoint(x: b.maxX, y: b.midY)
      let dx = 30 + min(60, abs(end.y - start.y) / 6)
      c1 = CGPoint(x: start.x + dx, y: start.y); c2 = CGPoint(x: end.x + dx, y: end.y)
    }

    var path = Path()
    path.move(to: start)
    path.addCurve(to: end, control1: c1, control2: c2)

    let base: Color = violation ? .red : emphasised ? .accentColor : .secondary
    let color = base.opacity(dimmed ? 0.08 : emphasised ? 0.95 : 0.28)
    let width: CGFloat = emphasised ? 2 : 0.9
    let dash: [CGFloat] = kind == .implements || kind == .extends ? [6, 4] : kind == .tests ? [2, 3] : []
    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))

    // Punta: triángulo hueco para implementa/extiende, flecha llena para usa.
    let angle = atan2(end.y - c2.y, end.x - c2.x)
    let size: CGFloat = emphasised ? 9 : 7
    var head = Path()
    head.move(to: end)
    head.addLine(to: CGPoint(x: end.x - size * cos(angle - .pi / 7), y: end.y - size * sin(angle - .pi / 7)))
    head.addLine(to: CGPoint(x: end.x - size * cos(angle + .pi / 7), y: end.y - size * sin(angle + .pi / 7)))
    head.closeSubpath()
    if kind == .implements || kind == .extends {
      ctx.fill(head, with: .color(Color(nsColor: .windowBackgroundColor)))
      ctx.stroke(head, with: .color(color), lineWidth: 1.2)
    } else {
      ctx.fill(head, with: .color(color))
    }
  }
}

struct NodeView: View {
  let unit: CodeUnit
  let selected: Bool
  let dimmed: Bool
  let reviewed: Bool
  let isEntry: Bool
  let tests: Int
  let violations: Int
  var showLabels = true

  var body: some View {
    if showLabels { full } else { compact }
  }

  private var compact: some View {
    RoundedRectangle(cornerRadius: 7)
      .fill(unit.status.color.opacity(0.55))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : .secondary.opacity(0.35), lineWidth: selected ? 3 : 1))
      .opacity(dimmed ? 0.35 : 1)
  }

  private var direction: String? {
    switch unit.layer {
    case .inbound: "arrow.down.right"
    case .outbound: "arrow.up.right"
    default: nil
    }
  }

  private var full: some View {
    HStack(spacing: 0) {
      Rectangle().fill(unit.status.color).frame(width: 4)
      HStack(spacing: 7) {
        VStack(alignment: .leading, spacing: 2) {
          Text(unit.typeName)
            .font(.system(size: 12, weight: .semibold))
            .strikethrough(unit.status == .deleted)
            .lineLimit(1)
            .truncationMode(.middle)
          HStack(spacing: 5) {
            if let direction {
              Image(systemName: direction).help(unit.layer == .inbound ? "Entrada" : "Salida")
            }
            Text(unit.role.label)
            if unit.isGhost {
              Text("sin cambios").italic()
            } else {
              Text("+\(unit.additions)").foregroundStyle(Semantic.added)
              Text("−\(unit.deletions)").foregroundStyle(Semantic.removed)
            }
          }
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
        Spacer(minLength: 0)
        VStack(alignment: .trailing, spacing: 2) {
          HStack(spacing: 3) {
            if isEntry { Image(systemName: "flag").help("Punto de entrada sugerido") }
            if violations > 0 { Image(systemName: "exclamationmark.triangle").foregroundStyle(Semantic.error) }
            if reviewed { Image(systemName: "checkmark") }
          }
          if tests > 0 {
            Text("\(tests) t")
          }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 7)
    }
    .background(
      RoundedRectangle(cornerRadius: 7)
        .fill(Color(nsColor: unit.isGhost ? .windowBackgroundColor : .controlBackgroundColor)))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay(
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(
          selected ? Color.accentColor : Color.secondary.opacity(unit.isGhost ? 0.5 : 0.35),
          style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: unit.isGhost ? [4, 3] : [])))
    .opacity(dimmed ? 0.35 : unit.isGhost ? 0.8 : 1)
  }
}
