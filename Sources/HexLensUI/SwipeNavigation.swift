import AppKit

/// Atrás/adelante con el gesto de dos dedos, como en el navegador. Solo cuando la vista bajo el ratón
/// ya no puede desplazarse en esa dirección; en el mapa los dos dedos siempre mueven el lienzo.
@MainActor enum SwipeNavigation {
  private static var monitor: Any?
  private static var undecided = false

  static func install(_ model: AppModel) {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak model] event in
      // Se decide una vez por gesto, con el primer evento que trae movimiento.
      if event.phase == .began { undecided = true }
      guard undecided, event.phase == .began || event.phase == .changed else { return event }
      guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return event }
      undecided = false
      guard let model, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
        abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 2
      else { return event }
      let back = event.scrollingDeltaX > 0
      guard back ? !model.backStack.isEmpty : !model.forwardStack.isEmpty, canSwipe(event, back: back) else { return event }
      var done = false
      event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount], dampenAmountThresholdMin: back ? 0 : -1, max: back ? 1 : 0) {
        amount, phase, complete, _ in
        if complete, !done, phase == .ended, abs(amount) >= 1 {
          done = true
          if back { model.back() } else { model.forward() }
        }
      }
      return nil
    }
  }

  private static func canSwipe(_ event: NSEvent, back: Bool) -> Bool {
    guard let content = event.window?.contentView,
      let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
    else { return false }
    var view: NSView? = hit
    while let v = view {
      if v is MapNSScrollView { return false }
      if let sv = v as? NSScrollView, sv.hasHorizontalScroller {
        let clip = sv.contentView, b = clip.bounds
        let minX = clip.constrainBoundsRect(NSRect(x: -1e7, y: b.minY, width: b.width, height: b.height)).minX
        let maxX = clip.constrainBoundsRect(NSRect(x: 1e7, y: b.minY, width: b.width, height: b.height)).minX
        if back ? b.minX > minX + 0.5 : b.minX < maxX - 0.5 { return false }
      }
      view = v.superview
    }
    return true
  }
}
