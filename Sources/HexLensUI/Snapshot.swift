import AppKit
import HexLensCore
import SwiftUI

/// Pinta el grafo de una sesión a PNG sin abrir ventana (CLI y pruebas visuales).
@MainActor
public enum Snapshot {
  public static func render(session: ReviewSession, context: ContextMode, showTests: Bool, to url: URL, selected: String? = nil) throws {
    let g = session.graph
    let units = g.units.filter { u in
      guard u.isCode else { return false }
      if u.isTest { return showTests && !u.isGhost }
      if u.isGhost { return context == .all || (context == .key && u.isKeyContext) }
      return true
    }
    let ids = Set(units.map(\.id))
    let layout = GraphLayout.compute(units: units, edges: g.edges.filter { ids.contains($0.from) && ids.contains($0.to) })
    let view = GraphCanvas(graph: g, layout: layout, selectedID: selected)
      .background(Color(nsColor: .textBackgroundColor))
      .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage else { throw ShellError(command: "render", status: 1, stderr: "sin imagen") }
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
  }
}
