import HexLensCore
import SwiftUI

/// Espaciado base y tipografía compartidos: tres tamaños y una escala 4/8/12.
enum Metrics {
  static let xs: CGFloat = 4
  static let s: CGFloat = 8
  static let m: CGFloat = 12
}

enum Typo {
  static let title = Font.system(size: 13, weight: .semibold)
  static let body = Font.system(size: 12)
  static let secondary = Font.system(size: 11)
  static let code = Font.system(size: 12, design: .monospaced)
}

/// Color solo con significado: añadido/quitado y errores. El resto, colores del sistema.
enum Semantic {
  static let added = Color.green
  static let removed = Color.red
  static let error = Color.red
}

extension ChangeStatus {
  public var color: Color {
    switch self {
    case .added: Semantic.added
    case .deleted: Semantic.removed
    case .modified, .renamed, .unchanged: .secondary
    }
  }
}

extension MemberChange.Change {
  var color: Color {
    switch self {
    case .added: Semantic.added
    case .removed: Semantic.removed
    case .modified: .secondary
    }
  }

  var sign: String {
    switch self {
    case .added: "+"
    case .removed: "−"
    case .modified: "~"
    }
  }
}

/// Estado en texto secundario con símbolo opcional; solo se tiñe si es un error.
struct Tag: View {
  let text: String
  var symbol: String?
  var isError = false

  var body: some View {
    HStack(spacing: 3) {
      if let symbol { Image(systemName: symbol) }
      Text(text)
    }
    .font(Typo.secondary)
    .foregroundStyle(isError ? Semantic.error : .secondary)
  }
}

/// Cabecera de sección al estilo IDE: pequeña y secundaria.
struct SectionTitle: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
  }
}

/// Coloca vistas en filas que se parten al llegar al ancho disponible.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let height = rows.last.map { $0.y + $0.height } ?? 0
    let width = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for i in row.items {
        let size = subviews[i].sizeThatFits(.unspecified)
        subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
    }
  }

  private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = [Row()]
    for (i, view) in subviews.enumerated() {
      let size = view.sizeThatFits(.unspecified)
      if rows[rows.count - 1].width + size.width > width && !rows[rows.count - 1].items.isEmpty {
        let last = rows[rows.count - 1]
        rows.append(Row(y: last.y + last.height + spacing))
      }
      rows[rows.count - 1].items.append(i)
      rows[rows.count - 1].width += size.width + (rows[rows.count - 1].items.count > 1 ? spacing : 0)
      rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
    }
    return rows
  }
}
