import HexLensCore
import SwiftUI

extension Layer {
  public var color: Color {
    switch self {
    case .inbound: Color(red: 0.20, green: 0.48, blue: 0.92)
    case .application: Color(red: 0.16, green: 0.62, blue: 0.40)
    case .domain: Color(red: 0.86, green: 0.52, blue: 0.10)
    case .outbound: Color(red: 0.55, green: 0.33, blue: 0.85)
    case .config: Color(red: 0.45, green: 0.47, blue: 0.50)
    case .other: Color(red: 0.55, green: 0.45, blue: 0.38)
    }
  }
}

extension ChangeStatus {
  public var color: Color {
    switch self {
    case .added: .green
    case .modified: .orange
    case .deleted: .red
    case .renamed: .blue
    case .unchanged: .gray
    }
  }
}

extension MemberChange.Change {
  var color: Color {
    switch self {
    case .added: .green
    case .removed: .red
    case .modified: .orange
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

struct Pill: View {
  let text: String
  var color: Color = .secondary
  var symbol: String?

  var body: some View {
    HStack(spacing: 3) {
      if let symbol { Image(systemName: symbol) }
      Text(text)
    }
    .font(.system(size: 11, weight: .medium))
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(color.opacity(0.14), in: Capsule())
    .foregroundStyle(color)
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
