import Foundation

/// Diff lado a lado: dos documentos con el mismo número de filas. A la izquierda la base
/// (líneas con `oldNumber`), a la derecha la cabeza (`newNumber`); donde un lado no tiene
/// línea hay una fila de relleno (`.filler`).
public enum SideBySide {
  public struct Result: Sendable {
    public let left: CodeDocument
    public let right: CodeDocument
  }

  /// `nil` si el fichero es nuevo, borrado o no tiene cambios: ahí solo hay un lado que enseñar.
  public static func build(from document: CodeDocument) -> Result? {
    let kinds = Set(document.lines.map(\.kind))
    guard kinds.contains(.added) || kinds.contains(.removed), kinds.contains(.context) else { return nil }

    var left: [CodeLine] = []
    var right: [CodeLine] = []
    var removed: [CodeLine] = []
    var added: [CodeLine] = []
    func filler() -> CodeLine { CodeLine(kind: .filler, text: "", oldNumber: nil, newNumber: nil) }
    func flush() {
      for i in 0..<max(removed.count, added.count) {
        left.append(i < removed.count ? removed[i] : filler())
        right.append(i < added.count ? added[i] : filler())
      }
      removed = []
      added = []
    }
    for l in document.lines {
      switch l.kind {
      case .removed: removed.append(CodeLine(kind: .removed, text: l.text, oldNumber: l.oldNumber, newNumber: nil))
      case .added: added.append(l)
      case .context:
        flush()
        left.append(CodeLine(kind: .context, text: l.text, oldNumber: l.oldNumber, newNumber: nil))
        right.append(l)
      case .separator, .filler:
        flush()
        left.append(l)
        right.append(l)
      }
    }
    flush()
    return Result(left: CodeDocument(lines: left), right: CodeDocument(lines: right))
  }
}
