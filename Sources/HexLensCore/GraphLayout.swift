import CoreGraphics
import Foundation

/// Columnas por capa, cajas por paquete y nodos por fichero. Orden dentro de cada columna
/// por baricentro para reducir cruces de aristas.
public struct GraphLayout: Sendable {
  public struct Column: Identifiable, Sendable {
    public let layer: Layer
    public let frame: CGRect
    public var id: String { layer.rawValue }
  }

  public struct Group: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let layer: Layer
    public let frame: CGRect
  }

  public var columns: [Column] = []
  public var groups: [Group] = []
  public var frames: [String: CGRect] = [:]
  public var size: CGSize = .zero

  public init() {}

  public static let node = CGSize(width: 270, height: 50)
  static let margin: CGFloat = 24
  static let columnGap: CGFloat = 90
  static let columnPad: CGFloat = 12
  static let columnHeader: CGFloat = 52
  static let groupPad: CGFloat = 8
  static let groupHeader: CGFloat = 26
  static let groupGap: CGFloat = 14
  static let nodeGap: CGFloat = 8

  public static func compute(units: [CodeUnit], edges: [Dependency]) -> GraphLayout {
    let layers = Layer.allCases.filter { l in units.contains { $0.layer == l } }
    let unitByID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    // Grupos por paquete dentro de cada capa.
    var order: [Layer: [[String]]] = [:]
    for layer in layers {
      let inLayer = units.filter { $0.layer == layer }
      let byPackage = Dictionary(grouping: inLayer, by: { $0.packageName.isEmpty ? $0.module : $0.packageName })
      order[layer] = byPackage.keys.sorted().map { key in
        byPackage[key]!.sorted { ($0.isGhost ? 1 : 0, $0.role.rank, $0.typeName) < ($1.isGhost ? 1 : 0, $1.role.rank, $1.typeName) }.map(\.id)
      }
    }

    var neighbors: [String: [String]] = [:]
    for e in edges where unitByID[e.from] != nil && unitByID[e.to] != nil {
      neighbors[e.from, default: []].append(e.to)
      neighbors[e.to, default: []].append(e.from)
    }

    var layout = place(layers: layers, order: order, units: unitByID)
    for _ in 0..<6 {
      let y = layout.frames.mapValues(\.midY)
      func bary(_ id: String) -> CGFloat {
        let ns = (neighbors[id] ?? []).filter { unitByID[$0]?.layer != unitByID[id]?.layer }.compactMap { y[$0] }
        return ns.isEmpty ? (y[id] ?? 0) : ns.reduce(0, +) / CGFloat(ns.count)
      }
      for layer in layers {
        var groups: [([String], CGFloat)] = []
        for group in order[layer]! {
          let sorted = group.sorted { bary($0) < bary($1) }
          let centre = sorted.map(bary).reduce(0, +) / CGFloat(max(sorted.count, 1))
          groups.append((sorted, centre))
        }
        order[layer] = groups.sorted { $0.1 < $1.1 }.map(\.0)
      }
      layout = place(layers: layers, order: order, units: unitByID)
    }
    return layout
  }

  static func place(layers: [Layer], order: [Layer: [[String]]], units: [String: CodeUnit]) -> GraphLayout {
    var layout = GraphLayout()
    let groupWidth = node.width + groupPad * 2
    let columnWidth = groupWidth + columnPad * 2
    var maxBottom: CGFloat = 0
    var columnRects: [(Layer, CGRect)] = []

    for (i, layer) in layers.enumerated() {
      let x = margin + CGFloat(i) * (columnWidth + columnGap)
      var y = margin + columnHeader
      for group in order[layer] ?? [] {
        guard let first = group.first.flatMap({ units[$0] }) else { continue }
        let top = y
        y += groupHeader
        for id in group {
          layout.frames[id] = CGRect(x: x + columnPad + groupPad, y: y, width: node.width, height: node.height)
          y += node.height + nodeGap
        }
        y += groupPad - nodeGap
        let label = first.packageLabel.isEmpty ? first.module : first.packageLabel
        let parts = label.split(separator: ".")
        layout.groups.append(Group(
          id: "\(layer.rawValue):\(first.packageName):\(first.module)",
          title: parts.first.map(String.init) ?? label,
          subtitle: parts.dropFirst().joined(separator: "."),
          layer: layer,
          frame: CGRect(x: x + columnPad, y: top, width: groupWidth, height: y - top)))
        y += groupGap
      }
      maxBottom = max(maxBottom, y)
      columnRects.append((layer, CGRect(x: x, y: margin, width: columnWidth, height: 0)))
    }

    let height = maxBottom + margin
    layout.columns = columnRects.map { Column(layer: $0.0, frame: CGRect(x: $0.1.minX, y: margin, width: columnWidth, height: height - margin * 2)) }
    let width = margin * 2 + CGFloat(layers.count) * columnWidth + CGFloat(max(layers.count - 1, 0)) * columnGap
    layout.size = CGSize(width: max(width, 400), height: max(height, 300))
    return layout
  }
}
