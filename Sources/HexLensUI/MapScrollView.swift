import AppKit
import HexLensCore
import SwiftUI

/// Lienzo acotado: deja moverse más allá del mapa hasta que su borde llega al centro de la vista,
/// así nunca queda pegado a una esquina y se puede desplazar aunque quepa entero.
final class MapClipView: NSClipView {
  static let marginFraction: CGFloat = 0.5

  override var documentRect: NSRect {
    guard let doc = documentView else { return super.documentRect }
    return doc.frame.insetBy(dx: -bounds.width * Self.marginFraction, dy: -bounds.height * Self.marginFraction)
  }

  override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
    guard let doc = documentView else { return super.constrainBoundsRect(proposed) }
    var r = proposed
    let area = doc.frame.insetBy(dx: -r.width * Self.marginFraction, dy: -r.height * Self.marginFraction)
    func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo <= hi ? min(max(v, lo), hi) : (lo + hi) / 2 }
    r.origin.x = clamp(r.origin.x, area.minX, area.maxX - r.width)
    r.origin.y = clamp(r.origin.y, area.minY, area.maxY - r.height)
    return r
  }
}

/// Mapa desplazable con zoom del trackpad (pellizco, smart zoom), ⌘+rueda y arrastre del fondo.
/// El zoom se aplica en SwiftUI (`scaleEffect`) y no con la magnificación de NSScrollView: con
/// esta, NSHostingView desalinea el hover, los clics y las aristas.
final class MapNSScrollView: NSScrollView {
  var onLayout: (() -> Void)?
  /// Factor multiplicativo y punto del gesto en coordenadas de la vista.
  var onZoom: ((CGFloat, NSPoint) -> Void)?
  var onSmartZoom: ((NSPoint) -> Void)?

  override func layout() {
    super.layout()
    onLayout?()
  }

  override func magnify(with event: NSEvent) {
    onZoom?(1 + event.magnification, convert(event.locationInWindow, from: nil))
  }

  override func smartMagnify(with event: NSEvent) {
    onSmartZoom?(convert(event.locationInWindow, from: nil))
  }

  override func scrollWheel(with event: NSEvent) {
    guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
    let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)
    onZoom?(exp(delta), convert(event.locationInWindow, from: nil))
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseDragged(with event: NSEvent) {
    var origin = contentView.bounds.origin
    origin.x -= event.deltaX
    origin.y -= documentView?.isFlipped == true ? event.deltaY : -event.deltaY
    contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
    reflectScrolledClipView(contentView)
  }
}

struct MapScrollView: NSViewRepresentable {
  @ObservedObject var model: AppModel
  let graph: PRGraph

  static let minZoom: CGFloat = 0.2
  static let maxZoom: CGFloat = 3

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> MapNSScrollView {
    let scroll = MapNSScrollView()
    scroll.contentView = MapClipView()
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = true
    scroll.backgroundColor = .textBackgroundColor

    let c = context.coordinator
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    scroll.documentView = host
    c.scroll = scroll
    c.host = host
    c.model = model
    c.graph = graph
    c.render()
    scroll.onLayout = { [weak c] in c?.attemptFit() }
    scroll.onZoom = { [weak c] factor, point in
      guard let c else { return }
      c.setZoom(c.zoom * factor, around: point)
    }
    scroll.onSmartZoom = { [weak c] point in
      guard let c else { return }
      if abs(c.zoom - 1) < 0.05 { c.fit() } else { c.setZoom(1, around: point) }
    }
    return scroll
  }

  func updateNSView(_ scroll: MapNSScrollView, context: Context) {
    let c = context.coordinator
    c.model = model
    c.graph = graph
    if model.fitRequest != c.lastFit {
      c.lastFit = model.fitRequest
      c.pendingFit = true
    }
    if c.pendingFit {
      c.render()
      c.attemptFit()
    } else if model.zoom != c.lastModelZoom {
      // Zoom pedido desde el menú: centrado en la vista.
      c.lastModelZoom = model.zoom
      c.setZoom(model.zoom, around: NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY))
    } else {
      c.render()
    }
    if model.selectedID != c.lastSelected {
      c.lastSelected = model.selectedID
      if !c.pendingFit, let id = model.selectedID, let frame = model.layout.frames[id] { c.reveal(frame) }
    }
  }

  @MainActor
  final class Coordinator: NSObject {
    weak var scroll: MapNSScrollView?
    var host: NSHostingView<AnyView>?
    var model: AppModel?
    var graph: PRGraph?
    var zoom: CGFloat = 1
    /// Último valor de `model.zoom` visto o publicado; distingue cambios del menú de los propios.
    var lastModelZoom: CGFloat = 1
    var lastFit = 0
    var pendingFit = false
    var lastSelected: String?

    func render() {
      guard let host, let model, let graph else { return }
      let size = model.layout.size
      let z = zoom
      let canvas = GraphCanvas(
        graph: graph, layout: model.layout, selectedID: model.selectedID, hoveredID: model.hoveredID,
        reviewed: model.reviewed,
        onSelect: { [model] in model.select($0) }, onHover: { [model] in model.hoveredID = $0 }, zoom: z)
      host.rootView = AnyView(
        canvas
          .scaleEffect(z, anchor: .topLeading)
          .frame(width: size.width * z, height: size.height * z, alignment: .topLeading))
      let scaled = NSSize(width: size.width * z, height: size.height * z)
      if host.frame.size != scaled { host.setFrameSize(scaled) }
    }

    /// Cambia el zoom manteniendo fijo el punto `anchor` (coordenadas de la scroll view).
    func setZoom(_ value: CGFloat, around anchor: NSPoint) {
      guard let scroll else { return }
      let new = min(max(value, MapScrollView.minZoom), MapScrollView.maxZoom)
      guard abs(new - zoom) > 0.0001 else { return }
      let clip = scroll.contentView
      let inClip = clip.convert(anchor, from: scroll)
      let offset = NSPoint(x: inClip.x - clip.bounds.minX, y: inClip.y - clip.bounds.minY)
      let docPoint = NSPoint(x: inClip.x / zoom, y: inClip.y / zoom)
      zoom = new
      render()
      let origin = NSPoint(x: docPoint.x * new - offset.x, y: docPoint.y * new - offset.y)
      clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
      scroll.reflectScrolledClipView(clip)
      publishZoom()
    }

    func attemptFit() {
      guard pendingFit, let scroll, let model else { return }
      let area = scroll.contentSize
      let size = model.layout.size
      guard area.width > 1, area.height > 1, size.width > 1 else { return }
      pendingFit = false
      fit()
    }

    func fit() {
      guard let scroll, let model else { return }
      let area = scroll.contentSize
      let size = model.layout.size
      zoom = min(max(min(area.width / size.width, area.height / size.height) * 0.97, MapScrollView.minZoom), 1)
      render()
      let clip = scroll.contentView
      let visible = clip.bounds.size
      let centred = NSPoint(x: (size.width * zoom - visible.width) / 2, y: (size.height * zoom - visible.height) / 2)
      clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: centred, size: visible)).origin)
      scroll.reflectScrolledClipView(clip)
      publishZoom()
    }

    func reveal(_ docFrame: CGRect) {
      guard let scroll else { return }
      let frame = CGRect(x: docFrame.minX * zoom, y: docFrame.minY * zoom, width: docFrame.width * zoom, height: docFrame.height * zoom)
      let visible = scroll.contentView.bounds
      guard !visible.insetBy(dx: 20, dy: 20).contains(frame) else { return }
      let target = NSPoint(x: frame.midX - visible.width / 2, y: frame.midY - visible.height / 2)
      let origin = scroll.contentView.constrainBoundsRect(NSRect(origin: target, size: visible.size)).origin
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.25
        scroll.contentView.animator().setBoundsOrigin(origin)
      }, completionHandler: { scroll.reflectScrolledClipView(scroll.contentView) })
    }

    private func publishZoom() {
      guard let model else { return }
      let z = zoom
      lastModelZoom = z
      // Fuera del ciclo de actualización de SwiftUI; solo si no ha llegado otro gesto después.
      DispatchQueue.main.async { [weak self] in
        guard let self, self.zoom == z, model.zoom != z else { return }
        self.lastModelZoom = z
        model.zoom = z
      }
    }
  }
}
