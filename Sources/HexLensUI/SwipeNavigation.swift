import AppKit

/// Atrás/adelante con el gesto de dos dedos, como en el navegador. Solo cuando la vista bajo el ratón
/// ya no puede desplazarse en esa dirección; en el mapa los dos dedos siempre mueven el lienzo.
@MainActor enum SwipeNavigation {
  private enum Decision { case undecided, pass, swipe(back: Bool) }
  private static var monitor: Any?
  private static var keyMonitor: Any?
  private static var decision = Decision.pass
  private static var dx: CGFloat = 0
  private static var dy: CGFloat = 0
  private static var swallowMomentum = false
  /// Recorrido horizontal (pt) necesario para navegar al levantar los dedos.
  static let threshold: CGFloat = 90

  static func install(_ model: AppModel) {
    guard monitor == nil else { return }
    // ⌘← / ⌘→: atrás/adelante, salvo escribiendo en un campo (ahí mueven el cursor como siempre).
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] e in
      guard let model, e.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
        e.keyCode == 123 || e.keyCode == 124
      else { return e }
      if let tv = e.window?.firstResponder as? NSTextView, tv.isEditable { return e }
      if e.keyCode == 123 { model.back() } else { model.forward() }
      return nil
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak model] event in
      guard let model else { return event }
      // Inercia tras un gesto de navegación: no debe desplazar la vista.
      if event.phase.isEmpty, !event.momentumPhase.isEmpty { return swallowMomentum ? nil : event }
      switch event.phase {
      case .mayBegin: return event
      case .began:
        decision = .undecided; dx = 0; dy = 0; swallowMomentum = false
      case .changed: break
      case .ended, .cancelled:
        defer { decision = .pass }
        guard case .swipe(let back) = decision else { return event }
        swallowMomentum = true
        if event.phase == .ended, back ? dx >= threshold : dx <= -threshold {
          if back { model.back() } else { model.forward() }
        }
        return nil
      default: return event
      }
      // dx > 0 = dedos hacia la derecha, con o sin desplazamiento natural.
      dx += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
      dy += event.scrollingDeltaY
      switch decision {
      case .pass: return event
      case .swipe: return nil
      case .undecided:
        // Se decide una sola vez por gesto, cuando ya hay movimiento suficiente para saber la dirección.
        guard abs(dx) + abs(dy) >= 6 else { return event }
        let back = dx > 0
        if abs(dx) > abs(dy) * 1.5, back ? !model.backStack.isEmpty : !model.forwardStack.isEmpty,
          canSwipe(event, back: back) {
          decision = .swipe(back: back)
          return nil
        }
        decision = .pass
        return event
      }
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
