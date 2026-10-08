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

/// NSScrollView con magnificación: pellizco, pan con inercia y smart zoom del trackpad, ⌘+rueda
/// y arrastre del fondo. El contenido sigue siendo SwiftUI vectorial, así que el texto no se pixela.
final class MapNSScrollView: NSScrollView {
  var onLayout: (() -> Void)?

  override func layout() {
    super.layout()
    onLayout?()
  }

  override func scrollWheel(with event: NSEvent) {
    guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
    let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)
    let point = contentView.convert(event.locationInWindow, from: nil)
    setMagnification(min(max(magnification * exp(delta), minMagnification), maxMagnification), centeredAt: point)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: self)
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseDragged(with event: NSEvent) {
    var origin = contentView.bounds.origin
    origin.x -= event.deltaX / magnification
    origin.y -= (documentView?.isFlipped == true ? event.deltaY : -event.deltaY) / magnification
    contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size)).origin)
    reflectScrolledClipView(contentView)
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
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
    scroll.allowsMagnification = true
    scroll.minMagnification = Self.minZoom
    scroll.maxMagnification = Self.maxZoom
    scroll.contentView.postsBoundsChangedNotifications = true

    let host = NSHostingView(rootView: canvas(zoom: 1))
    scroll.documentView = host

    let c = context.coordinator
    c.scroll = scroll
    c.host = host
    c.model = model
    scroll.onLayout = { [weak c] in c?.attemptFit() }
    let nc = NotificationCenter.default
    nc.addObserver(c, selector: #selector(Coordinator.magnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
    nc.addObserver(c, selector: #selector(Coordinator.boundsChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    return scroll
  }

  func updateNSView(_ scroll: MapNSScrollView, context: Context) {
    let c = context.coordinator
    c.model = model
    guard let host = c.host else { return }
    host.rootView = canvas(zoom: c.detailZoom)
    let size = model.layout.size
    if host.frame.size != size { host.setFrameSize(size) }

    if model.fitRequest != c.lastFit {
      c.lastFit = model.fitRequest
      c.pendingFit = true
    }
    if c.pendingFit {
      c.attemptFit()
    } else if model.zoom != c.lastSeenZoom {
      c.lastSeenZoom = model.zoom
      if abs(model.zoom - scroll.magnification) > 0.001 {
        let centre = scroll.contentView.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), from: scroll)
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.2
          scroll.animator().setMagnification(model.zoom, centeredAt: centre)
        }
      }
    }
    if model.selectedID != c.lastSelected {
      c.lastSelected = model.selectedID
      if !c.pendingFit, let id = model.selectedID, let frame = model.layout.frames[id] { c.reveal(frame) }
    }
  }

  private func canvas(zoom: CGFloat) -> GraphCanvas {
    GraphCanvas(
      graph: graph, layout: model.layout, selectedID: model.selectedID, hoveredID: model.hoveredID,
      reviewed: model.reviewed,
      onSelect: { [model] in model.select($0) }, onHover: { [model] in model.hoveredID = $0 }, zoom: zoom)
  }

  @MainActor
  final class Coordinator: NSObject {
    weak var scroll: MapNSScrollView?
    var host: NSHostingView<GraphCanvas>?
    var model: AppModel?
    var lastFit = 0
    var pendingFit = false
    var lastSeenZoom: CGFloat = 1
    var lastSelected: String?
    var detailZoom: CGFloat = 1
    private var syncTask: Task<Void, Never>?

    func attemptFit() {
      guard pendingFit, let scroll, let model else { return }
      let area = scroll.contentSize
      let size = model.layout.size
      guard area.width > 1, area.height > 1, size.width > 1, host?.frame.size == size else { return }
      pendingFit = false
      let m = min(max(min(area.width / size.width, area.height / size.height), MapScrollView.minZoom), 1)
      scroll.magnification = m
      let visible = scroll.contentView.bounds.size
      let centred = NSPoint(x: (size.width - visible.width) / 2, y: (size.height - visible.height) / 2)
      scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: centred, size: visible)).origin)
      scroll.reflectScrolledClipView(scroll.contentView)
      publishZoom()
    }

    func reveal(_ frame: CGRect) {
      guard let scroll else { return }
      let visible = scroll.contentView.bounds
      guard !visible.insetBy(dx: 20, dy: 20).contains(frame) else { return }
      let target = NSPoint(x: frame.midX - visible.width / 2, y: frame.midY - visible.height / 2)
      let origin = scroll.contentView.constrainBoundsRect(NSRect(origin: target, size: visible.size)).origin
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.25
        scroll.contentView.animator().setBoundsOrigin(origin)
      }, completionHandler: { scroll.reflectScrolledClipView(scroll.contentView) })
    }

    @objc func magnifyEnded() { publishZoom() }

    @objc func boundsChanged() {
      guard let scroll else { return }
      let m = scroll.magnification
      // Cambio de nivel de detalle inmediato; el resto se sincroniza al terminar el gesto.
      if (m < 0.5) != (detailZoom < 0.5), let host {
        detailZoom = m
        host.rootView.zoomOverride(m)
      }
      syncTask?.cancel()
      syncTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 200_000_000)
        if !Task.isCancelled { self?.publishZoom() }
      }
    }

    private func publishZoom() {
      guard let scroll, let model else { return }
      detailZoom = scroll.magnification
      lastSeenZoom = scroll.magnification
      if abs(model.zoom - scroll.magnification) > 0.001 { model.zoom = scroll.magnification }
    }
  }
}
