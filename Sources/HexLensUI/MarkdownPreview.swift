import HexLensCore
import SwiftUI

/// Vista previa renderizada de un Markdown, sin dependencias externas.
struct MarkdownPreview: View {
  let text: String
  let path: String
  var changes: (additions: Int, deletions: Int)?
  var diff: MarkdownDiff?
  var onShowChanges: () -> Void = {}
  /// Abre el código en la línea de la cabeza (base 1) del bloque cambiado.
  var onOpenLine: (Int) -> Void = { _ in }
  var onOpenPath: (String) -> Void = { _ in }

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ScrollView { content }
      .background(Color(nsColor: .textBackgroundColor))
      .environment(\.openURL, OpenURLAction { url in handle(url) })
  }

  var content: some View {
    let rows = diffRows()
    return VStack(alignment: .leading, spacing: 0) {
        if let changes {
          HStack(spacing: 4) {
            Image(systemName: "plusminus.circle").foregroundStyle(.secondary)
            Text("+\(changes.additions) −\(changes.deletions) líneas en esta PR ·").foregroundStyle(.secondary)
            Button("Ver cambios", action: onShowChanges).buttonStyle(.link)
            Spacer()
          }
          .font(Typo.secondary)
          .padding(.horizontal, 10).padding(.vertical, 6)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10)))
          .padding(.bottom, 20)
        }
        VStack(alignment: .leading, spacing: 14) {
          if diff?.isNewFile == true {
            Label("Fichero nuevo", systemImage: "plus.circle.fill")
              .font(Typo.secondary).foregroundStyle(.green)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(Capsule().fill(Color.green.opacity(0.15)))
          }
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            rowView(row)
          }
        }
      }
      .textSelection(.enabled)
      .frame(maxWidth: 820, alignment: .leading)
      .padding(.horizontal, 32).padding(.vertical, 24)
      .frame(maxWidth: .infinity)
  }

  // MARK: - Diff

  private enum Mark { case none, added, removed }
  private struct Row { var block: MarkdownBlock; var mark: Mark; var line: Int }

  /// Bloques de la cabeza marcados como añadidos, con los bloques eliminados intercalados donde estaban.
  private func diffRows() -> [Row] {
    let parsed = MarkdownBlocks.parseWithLines(text)
    guard let diff, !diff.isNewFile else { return parsed.map { Row(block: $0.block, mark: .none, line: $0.lines.lowerBound + 1) } }
    var rows: [Row] = []
    var pending = diff.removals[...]
    func flush(before anchor: Int?) {
      while let r = pending.first, anchor.map({ r.anchor <= $0 }) ?? true {
        pending = pending.dropFirst()
        for b in MarkdownBlocks.parseWithLines(r.lines.joined(separator: "\n")) {
          rows.append(Row(block: b.block, mark: .removed, line: r.anchor + 1))
        }
      }
    }
    for p in parsed {
      flush(before: p.lines.lowerBound)
      let isAdded = p.lines.contains { diff.added.contains($0 + 1) }
      rows.append(Row(block: p.block, mark: isAdded ? .added : .none, line: p.lines.lowerBound + 1))
    }
    flush(before: nil)
    return rows
  }

  @ViewBuilder
  private func rowView(_ row: Row) -> some View {
    switch row.mark {
    case .none:
      blockView(row.block)
    case .added, .removed:
      let color: Color = row.mark == .added ? .green : .red
      HStack(alignment: .top, spacing: 0) {
        Rectangle().fill(color).frame(width: 3)
        blockView(row.block)
          .opacity(row.mark == .removed ? 0.65 : 1)
          .modifier(StrikeIf(on: row.mark == .removed))
          .padding(.horizontal, 10).padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(color.opacity(0.08))
      .contentShape(Rectangle())
      .onTapGesture { onOpenLine(row.line) }
      .help("Ver en el código")
    }
  }

  private struct StrikeIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { on ? AnyView(content.strikethrough()) : AnyView(content) }
  }

  // MARK: - Enlaces

  private func handle(_ url: URL) -> OpenURLAction.Result {
    if let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
      return ["http", "https", "mailto"].contains(scheme) ? .systemAction : .discarded
    }
    var rel = url.absoluteString
    if let cut = rel.firstIndex(where: { $0 == "#" || $0 == "?" }) { rel = String(rel[..<cut]) }
    rel = rel.removingPercentEncoding ?? rel
    if rel.isEmpty { return .handled }
    if let resolved = Self.resolve(rel, from: path) { onOpenPath(resolved) }
    return .handled
  }

  /// Resuelve una ruta relativa respecto al directorio del .md; `/x` es relativa a la raíz del repo.
  static func resolve(_ rel: String, from path: String) -> String? {
    var parts: [Substring] = rel.hasPrefix("/") ? [] : (path as NSString).deletingLastPathComponent.split(separator: "/")
    for p in rel.split(separator: "/") {
      switch p {
      case ".": continue
      case "..": if parts.isEmpty { return nil } else { parts.removeLast() }
      default: parts.append(p)
      }
    }
    return parts.isEmpty ? nil : parts.joined(separator: "/")
  }

  // MARK: - Bloques

  private func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
  }

  private func blockView(_ block: MarkdownBlock) -> AnyView {
    switch block {
    case .heading(let level, let t):
      let size: CGFloat = [28, 22, 18, 16, 14, 13][level - 1]
      return AnyView(
        VStack(alignment: .leading, spacing: 6) {
          Text(inline(t)).font(.system(size: size, weight: .semibold)).padding(.top, level <= 2 ? 10 : 4)
          if level <= 2 { Divider() }
        })
    case .paragraph(let t):
      return AnyView(Text(inline(t)).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true))
    case .list(let items):
      return AnyView(listView(items, depth: 0))
    case .quote(let inner):
      return AnyView(
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
          VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(inner.enumerated()), id: \.offset) { _, b in blockView(b) }
          }
          .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true))
    case .code(let lang, let t):
      return AnyView(
        Text(highlighted(t, language: lang)).font(Typo.code).lineSpacing(2)
          .fixedSize(horizontal: false, vertical: true)
          .padding(12).frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))))
    case .table(let header, let rows):
      return AnyView(tableView(header, rows))
    case .rule:
      return AnyView(Divider().padding(.vertical, 6))
    }
  }

  private func listView(_ items: [MarkdownListItem], depth: Int) -> AnyView {
    AnyView(
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              marker(item, depth: depth).frame(minWidth: 18, alignment: .trailing)
              Text(inline(item.text)).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            if !item.children.isEmpty { listView(item.children, depth: depth + 1).padding(.leading, 22) }
          }
        }
      })
  }

  @ViewBuilder
  private func marker(_ item: MarkdownListItem, depth: Int) -> some View {
    if let checked = item.checked {
      Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? Color.accentColor : .secondary)
    } else if let n = item.number {
      Text("\(n).").foregroundStyle(.secondary).font(.system(size: 14).monospacedDigit())
    } else {
      Text(depth == 0 ? "•" : "◦").foregroundStyle(.secondary).font(.system(size: 14))
    }
  }

  private func tableView(_ header: [String], _ rows: [[String]]) -> some View {
    let n = max(header.count, rows.map(\.count).max() ?? 0)
    return Group {
      Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(0..<n, id: \.self) { c in cell(c < header.count ? header[c] : "", bold: true) }
        }
        .background(Color.secondary.opacity(0.12))
        ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
          Divider().gridCellColumns(n)
          GridRow {
            ForEach(0..<n, id: \.self) { c in cell(c < row.count ? row[c] : "", bold: false) }
          }
          .background(r % 2 == 1 ? Color.secondary.opacity(0.04) : .clear)
        }
      }
      .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
      .clipShape(RoundedRectangle(cornerRadius: 4))
    }
  }

  private func cell(_ s: String, bold: Bool) -> some View {
    Text(inline(s)).font(.system(size: 13, weight: bold ? .semibold : .regular))
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10).padding(.vertical, 6)
  }

  // MARK: - Código

  private func highlighted(_ code: String, language: String?) -> AttributedString {
    let lang = language?.lowercased()
    let tokens: [Token]
    switch lang {
    case "java": tokens = JavaLexer.tokens(code)
    case "ruby", "rb": tokens = RubyLexer.tokens(code)
    default: return AttributedString(code)
    }
    let theme = scheme == .dark ? CodeTheme.dark : CodeTheme.light
    let out = NSMutableAttributedString(string: code, attributes: [.foregroundColor: theme.text])
    let length = (code as NSString).length
    for t in tokens where NSMaxRange(t.range) <= length {
      let color: NSColor?
      switch t.kind {
      case .keyword: color = theme.keyword
      case .string: color = theme.string
      case .number: color = theme.number
      case .comment: color = theme.comment
      case .annotation: color = theme.annotation
      default: color = nil
      }
      if let color { out.addAttribute(.foregroundColor, value: color, range: t.range) }
    }
    return (try? AttributedString(out, including: \.appKit)) ?? AttributedString(code)
  }
}
