import AppKit
import SwiftUI

extension View {
  /// Mano de enlace mientras el ratón está encima: indica que el elemento se puede pulsar.
  func handCursor(_ enabled: Bool = true) -> some View {
    onContinuousHover { phase in
      guard enabled else { return }
      switch phase {
      case .active: NSCursor.pointingHand.set()
      case .ended: NSCursor.arrow.set()
      }
    }
  }
}
