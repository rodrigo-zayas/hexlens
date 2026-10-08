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
  /// Solo se crean vistas para lo que cae en este rectángulo (coordenadas del mapa).
  var visibleRect: CGRect = .infinite

  public init(
    graph: PRGraph, layout: GraphLayout, selectedID: String? = nil, hoveredID: String? = nil,
    reviewed: Set<String> = [], onSelect: @escaping (String) -> Void = { _ in },
    onHover: @escaping (String?) -> Void = { _ in }, visibleRect: CGRect = .infinite
  ) {
    self.visibleRect = visibleRect
    self.graph = graph
    self.layout = layout
    self.selectedID = selectedID
    self.hoveredID = hoveredID
    self.reviewed = reviewed
    self.onSelect = onSelect
    self.onHover = onHover
  }

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

  private var focus: String? { hoveredID ?? selectedID }

  private var visibleEdges: [Dependency] {
    graph.edges.filter { layout.frames[$0.from] != nil && layout.frames[$0.to] != nil }
  }

  private var neighborhood: Set<String> {
    guard let f = focus else { return [] }
    var s: Set<String> = [f]
    for e in graph.edges where e.from == f || e.to == f { s.insert(e.from); s.insert(e.to) }
    return s
  }

  private var violatingEdges: Set<String> {
    Set(graph.violations.compactMap { v in v.targetID.map { "\(v.unitID)→\($0)" } })
  }

  /// Tests y violaciones por nodo en una pasada (antes era O(nodos × tests) en cada render).
  private var counts: (tests: [String: Int], violations: [String: Int]) {
    var t: [String: Int] = [:], v: [String: Int] = [:]
    for subject in graph.subjectByTest.values { t[subject, default: 0] += 1 }
    for x in graph.violations { v[x.unitID, default: 0] += 1 }
    return (t, v)
  }

  public var body: some View {
    let near = neighborhood
    let counts = self.counts
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

      ForEach(layout.containers.filter { $0.frame.intersects(visibleRect) }) { box in
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
          Text(box.title)
            .font(.system(size: box.level == 1 ? 13 : 10, weight: box.level == 1 ? .semibold : .medium))
          if !box.subtitle.isEmpty {
            Text(box.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
        .lineLimit(1)
        .frame(width: box.frame.width - 16, alignment: .leading)
        .offset(x: box.frame.minX + 8, y: box.frame.minY + (box.level == 1 ? 8 : 4))
      }

      EdgeLayer(buckets: edgeBuckets(near: near))
        .frame(width: layout.size.width, height: layout.size.height)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.18), value: focus)
        // Con un layout nuevo las aristas antiguas se funden con las nuevas.
        .id(layout.revision)
        .transition(.opacity)

      ForEach(graph.units.filter { layout.frames[$0.id]?.intersects(visibleRect) == true }) { unit in
        let frame = layout.frames[unit.id]!
        NodeView(
          unit: unit,
          selected: unit.id == selectedID,
          dimmed: focus != nil && !near.contains(unit.id),
          reviewed: reviewed.contains(unit.id),
          isEntry: unit.id == graph.entryPoint,
          tests: counts.tests[unit.id] ?? 0,
          violations: counts.violations[unit.id] ?? 0)
          .frame(width: frame.width, height: frame.height)
          .contentShape(Rectangle())
          .onTapGesture { onSelect(unit.id) }
          .onHover { inside in onHover(inside ? unit.id : nil) }
          .id(unit.id)
          .position(x: frame.midX, y: frame.midY)
          .transition(.opacity.combined(with: .scale(scale: 0.85)))
      }
    }
    .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    .animation(.smooth(duration: 0.4), value: layout.revision)
  }

  /// Agrupa las aristas por estilo en pocos `Path` vectoriales (nítidos a cualquier zoom).
  private func edgeBuckets(near: Set<String>) -> [EdgeBucket] {
    let bad = violatingEdges
    var buckets: [String: EdgeBucket] = [:]
    for e in visibleEdges {
      guard let a = layout.frames[e.from], let b = layout.frames[e.to] else { continue }
      // La curva cabe en la unión de ambos nodos más el bucle lateral.
      guard a.union(b).insetBy(dx: -90, dy: 0).intersects(visibleRect) else { continue }
      let inFocus = focus == nil || e.from == focus || e.to == focus
      let emphasised = focus != nil && inFocus
      let violation = bad.contains(e.id)
      let hollow = e.kind == .implements || e.kind == .extends
      let dash: [CGFloat] = hollow ? [6, 4] : e.kind == .tests ? [2, 3] : []
      let base: Color = violation ? .red : emphasised ? .accentColor : .secondary
      let opacity = !inFocus ? 0.08 : emphasised ? 0.95 : 0.28
      let key = "\(violation)-\(emphasised)-\(inFocus)-\(e.kind)"
      var bucket = buckets[key] ?? EdgeBucket(
        id: key, color: base.opacity(opacity), width: emphasised ? 2 : 0.9, dash: dash, hollow: hollow,
        order: emphasised ? 2 : inFocus ? 1 : 0)
      Self.addEdge(&bucket, from: a, to: b, headSize: emphasised ? 9 : 7)
      buckets[key] = bucket
    }
    return buckets.values.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
  }

  private static func addEdge(_ bucket: inout EdgeBucket, from a: CGRect, to b: CGRect, headSize size: CGFloat) {
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
    bucket.lines.move(to: start)
    bucket.lines.addCurve(to: end, control1: c1, control2: c2)

    // Punta: triángulo hueco para implementa/extiende, flecha llena para usa.
    let angle = atan2(end.y - c2.y, end.x - c2.x)
    bucket.heads.move(to: end)
    bucket.heads.addLine(to: CGPoint(x: end.x - size * cos(angle - .pi / 7), y: end.y - size * sin(angle - .pi / 7)))
    bucket.heads.addLine(to: CGPoint(x: end.x - size * cos(angle + .pi / 7), y: end.y - size * sin(angle + .pi / 7)))
    bucket.heads.closeSubpath()
  }
}

struct EdgeBucket: Identifiable {
  let id: String
  let color: Color
  let width: CGFloat
  let dash: [CGFloat]
  let hollow: Bool
  let order: Int
  var lines = Path()
  var heads = Path()
}

struct EdgeLayer: View {
  let buckets: [EdgeBucket]

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(buckets) { b in
        b.lines.stroke(b.color, style: StrokeStyle(lineWidth: b.width, lineCap: .round, dash: b.dash))
        if b.hollow {
          b.heads.fill(Color(nsColor: .windowBackgroundColor))
          b.heads.stroke(b.color, lineWidth: 1.2)
        } else {
          b.heads.fill(b.color)
        }
      }
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

  var body: some View {
    full
    .scaleEffect(selected ? 1.03 : 1)
    .shadow(color: selected ? Color.accentColor.opacity(0.35) : .clear, radius: selected ? 8 : 0)
    .animation(.easeOut(duration: 0.18), value: dimmed)
    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
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
