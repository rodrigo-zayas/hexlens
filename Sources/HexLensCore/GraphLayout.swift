import CoreGraphics
import Foundation

/// Jerarquía del perfil: zona (columna) → módulo/componente → contexto → nodo-fichero.
/// Dentro de cada nivel se ordena por baricentro para reducir cruces de aristas.
public struct GraphLayout: Sendable {
  public struct Zone: Identifiable, Sendable {
    public let zone: MapZone
    public let index: Int
    public let frame: CGRect
    public var id: String { zone.id }
  }

  public struct Container: Identifiable, Sendable {
    public let id: String
    /// 1 = módulo/componente, 2 = contexto.
    public let level: Int
    public let title: String
    public let subtitle: String
    public let technology: String?
    public let zoneID: String
    public let frame: CGRect
  }

  public var profileName = ""
  /// Cambia en cada cálculo; la UI lo usa para animar la transición entre layouts.
  public var revision = 0
  public var zones: [Zone] = []
  public var containers: [Container] = []
  public var frames: [String: CGRect] = [:]
  public var size: CGSize = .zero

  public init() {}

  nonisolated(unsafe) private static var nextRevision = 0

  public static let node = CGSize(width: 270, height: 50)
  public static let margin: CGFloat = 24
  static let zoneGap: CGFloat = 80
  static let zonePad: CGFloat = 14
  static let zoneHeader: CGFloat = 76
  static let modulePad: CGFloat = 10
  static let moduleHeader: CGFloat = 34
  static let moduleGap: CGFloat = 16
  static let contextPad: CGFloat = 8
  static let contextHeader: CGFloat = 24
  static let contextGap: CGFloat = 10
  static let nodeGap: CGFloat = 8

  struct ContextGroup { var title: String?; var ids: [String] }
  struct ModuleGroup { var id: String; var title: String; var subtitle: String; var tech: String?; var contexts: [ContextGroup] }
  struct ZoneGroup { var zone: MapZone; var modules: [ModuleGroup] }

  public static func compute(units: [CodeUnit], edges: [Dependency], profile: ArchitectureProfile) -> GraphLayout {
    let unitByID = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var zones = group(units: units, profile: profile)

    var neighbors: [String: [String]] = [:]
    for e in edges where unitByID[e.from] != nil && unitByID[e.to] != nil {
      neighbors[e.from, default: []].append(e.to)
      neighbors[e.to, default: []].append(e.from)
    }
    let zoneOf = Dictionary(units.map { ($0.id, profile.zone(for: $0.archInfo).id) }, uniquingKeysWith: { a, _ in a })

    var layout = place(zones, name: profile.name)
    for _ in 0..<6 {
      let y = layout.frames.mapValues(\.midY)
      func bary(_ id: String) -> CGFloat {
        let ns = (neighbors[id] ?? []).filter { zoneOf[$0] != zoneOf[id] }.compactMap { y[$0] }
        return ns.isEmpty ? (y[id] ?? 0) : ns.reduce(0, +) / CGFloat(ns.count)
      }
      func mean(_ ids: [String]) -> CGFloat { ids.map(bary).reduce(0, +) / CGFloat(max(ids.count, 1)) }
      for zi in zones.indices {
        for mi in zones[zi].modules.indices {
          for ci in zones[zi].modules[mi].contexts.indices {
            zones[zi].modules[mi].contexts[ci].ids.sort { bary($0) < bary($1) }
          }
          zones[zi].modules[mi].contexts.sort { mean($0.ids) < mean($1.ids) }
        }
        zones[zi].modules.sort { a, b in
          mean(a.contexts.flatMap(\.ids)) < mean(b.contexts.flatMap(\.ids))
        }
      }
      layout = place(zones, name: profile.name)
    }
    nextRevision &+= 1
    layout.revision = nextRevision
    return layout
  }

  static func group(units: [CodeUnit], profile: ArchitectureProfile) -> [ZoneGroup] {
    var byZone: [String: (MapZone, [CodeUnit])] = [:]
    for u in units {
      let z = profile.zone(for: u.archInfo)
      byZone[z.id, default: (z, [])].1.append(u)
    }
    let unitOrder: (CodeUnit, CodeUnit) -> Bool = {
      ($0.isGhost ? 1 : 0, $0.role.rank, $0.typeName) < ($1.isGhost ? 1 : 0, $1.role.rank, $1.typeName)
    }
    return byZone.values.sorted { ($0.0.order, $0.0.title) < ($1.0.order, $1.0.title) }.map { zone, zoneUnits in
      let byModule = Dictionary(grouping: zoneUnits) { $0.component ?? $0.module }
      let modules = byModule.keys.sorted().map { key -> ModuleGroup in
        let inModule = byModule[key]!
        let byContext = Dictionary(grouping: inModule) { $0.context }
        let contexts = byContext.keys.sorted { ($0 ?? "") < ($1 ?? "") }.map { ctx in
          ContextGroup(title: ctx, ids: byContext[ctx]!.sorted(by: unitOrder).map(\.id))
        }
        let module = inModule.first!.module
        return ModuleGroup(
          id: "\(zone.id):\(key)", title: key, subtitle: key == module ? "" : module,
          tech: technology(of: inModule.first!.component), contexts: contexts)
      }
      return ZoneGroup(zone: zone, modules: modules)
    }
  }

  /// `amanda · pipe` → `pipe`; `rest (API propio)` → `rest`; `mongo` → `mongo`.
  public static func technology(of component: String?) -> String? {
    guard let c = component else { return nil }
    let last = c.components(separatedBy: " · ").last ?? c
    return last.components(separatedBy: " (").first
  }

  /// Filas máximas de un contexto antes de partirlo en más columnas de nodos.
  static let maxRows = 9
  static let maxColumns = 4

  static func columns(for count: Int) -> Int {
    min(maxColumns, max(1, Int((Double(count) / Double(maxRows)).rounded(.up))))
  }

  static func place(_ zones: [ZoneGroup], name: String) -> GraphLayout {
    var layout = GraphLayout()
    layout.profileName = name
    let nodeWidth = node.width
    func gridWidth(_ cols: Int) -> CGFloat { CGFloat(cols) * nodeWidth + CGFloat(cols - 1) * nodeGap }
    var maxBottom: CGFloat = 0
    var bands: [(Int, MapZone, CGFloat, CGFloat)] = []
    var x = margin

    for (i, zg) in zones.enumerated() {
      // Todos los módulos de una zona comparten ancho para que la columna se lea limpia.
      let widestGrid = zg.modules.flatMap(\.contexts).map { gridWidth(columns(for: $0.ids.count)) }.max() ?? nodeWidth
      let contextWidth = widestGrid + contextPad * 2
      let moduleWidth = contextWidth + modulePad * 2
      let zoneWidth = moduleWidth + zonePad * 2
      var y = margin + zoneHeader
      for module in zg.modules {
        let moduleTop = y
        let mx = x + zonePad
        y += moduleHeader
        for ctx in module.contexts {
          let ctxX = mx + modulePad
          let top = y
          if ctx.title != nil { y += contextHeader }
          let cols = columns(for: ctx.ids.count)
          for (k, id) in ctx.ids.enumerated() {
            let col = k % cols, row = k / cols
            layout.frames[id] = CGRect(
              x: ctxX + contextPad + CGFloat(col) * (nodeWidth + nodeGap),
              y: y + CGFloat(row) * (node.height + nodeGap), width: nodeWidth, height: node.height)
          }
          let rows = (ctx.ids.count + cols - 1) / cols
          y += CGFloat(rows) * (node.height + nodeGap)
          if let title = ctx.title {
            y += contextPad - nodeGap
            layout.containers.append(Container(
              id: "\(module.id):\(title)", level: 2, title: title, subtitle: "", technology: nil,
              zoneID: zg.zone.id, frame: CGRect(x: ctxX, y: top, width: contextWidth, height: y - top)))
            y += contextGap
          } else {
            y += contextGap - nodeGap
          }
        }
        y += modulePad - contextGap
        layout.containers.append(Container(
          id: module.id, level: 1, title: module.title, subtitle: module.subtitle, technology: module.tech,
          zoneID: zg.zone.id, frame: CGRect(x: mx, y: moduleTop, width: moduleWidth, height: y - moduleTop)))
        y += moduleGap
      }
      maxBottom = max(maxBottom, y)
      bands.append((i, zg.zone, x, zoneWidth))
      x += zoneWidth + zoneGap
    }

    let height = max(maxBottom + margin, 300)
    layout.zones = bands.map { i, zone, x, w in
      Zone(zone: zone, index: i, frame: CGRect(x: x, y: margin, width: w, height: height - margin * 2))
    }
    let width = zones.isEmpty ? margin * 2 : x - zoneGap + margin
    layout.size = CGSize(width: max(width, 400), height: height)
    return layout
  }
}
