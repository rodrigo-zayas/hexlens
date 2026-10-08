import HexLensCore
import SwiftUI

/// Vista previa renderizada de un Markdown, sin dependencias externas.
struct MarkdownPreview: View {
  let text: String
  let path: String
  var changes: (additions: Int, deletions: Int)?
  var diff: MarkdownDiff?
  /// Búsqueda en la página (⌘F): `nil` cuando la barra está oculta.
  var find: Find?
  /// Avisa de cuántas coincidencias hay en el texto renderizado.
  var onMatchCount: (Int) -> Void = { _ in }
  var onShowChanges: () -> Void = {}
  /// Abre el código en la línea de la cabeza (base 1) del bloque cambiado.
  var onOpenLine: (Int) -> Void = { _ in }
  var onOpenPath: (String) -> Void = { _ in }

  struct Find: Equatable {
    var query: String
    var caseSensitive: Bool
    var wholeWord: Bool
    var index: Int
  }

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let ctx = makeContext()
    ScrollViewReader { proxy in
      ScrollView { contentView(ctx) }
        .onChange(of: ctx.search.scrollID) { _, id in
          if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
        }
    }
    .background(Color(nsColor: .textBackgroundColor))
    .environment(\.openURL, OpenURLAction { url in handle(url) })
    .onAppear { onMatchCount(ctx.search.total) }
    .onChange(of: ctx.search.total) { _, n in onMatchCount(n) }
  }

  var content: some View { contentView(makeContext()) }

  private func contentView(_ ctx: Context) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let changes {
        HStack(spacing: 4) {
          Image(systemName: "plusminus.circle").foregroundStyle(.secondary)
          Text("+\(changes.additions) −\(changes.deletions) líneas en esta PR ·").foregroundStyle(.secondary)
          Button("Ver cambios", action: onShowChanges).buttonStyle(.link).handCursor()
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
        ForEach(Array(ctx.parsed.enumerated()), id: \.offset) { i, p in
          blockView(p.block, id: "b\(i)", at: Placement(lines: p.lines, parts: p.parts), ctx)
        }
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: 820, alignment: .leading)
    .padding(.horizontal, 32).padding(.vertical, 24)
    .frame(maxWidth: .infinity)
  }

  // MARK: - Contexto: cambios y búsqueda

  private struct Placement { var lines: Range<Int>; var parts: [Int] }

  private struct Context {
    var parsed: [(block: MarkdownBlock, lines: Range<Int>, parts: [Int])]
    /// Líneas añadidas de la cabeza (base 1); vacío en ficheros nuevos o sin diff.
    var added: Set<Int>
    var gutter: CGFloat
    var search: Search
    func changed(_ range: Range<Int>) -> Bool { range.contains { added.contains($0 + 1) } }
    func changed(line: Int?) -> Bool { line.map { added.contains($0 + 1) } ?? false }
  }

  private struct Unit { var id: String; var text: String; var scroll: String }

  private struct Search {
    var ranges: [String: [NSRange]] = [:]
    var first: [String: Int] = [:]
    var total = 0
    var scrollID: String?
    var current: Int?
  }

  private func makeContext() -> Context {
    let parsed = MarkdownBlocks.parseWithLines(text)
    let marking = diff.map { !$0.isNewFile } ?? false
    return Context(
      parsed: parsed, added: marking ? diff?.added ?? [] : [], gutter: marking ? 22 : 0,
      search: makeSearch(parsed))
  }

  private func makeSearch(_ parsed: [(block: MarkdownBlock, lines: Range<Int>, parts: [Int])]) -> Search {
    var out = Search()
    guard let find, !find.query.isEmpty else { return out }
    var units: [Unit] = []
    for (i, p) in parsed.enumerated() { units += self.units(p.block, id: "b\(i)") }
    var n = 0
    var order: [(Unit, Int)] = []
    for u in units {
      let r = TextSearch.matches(of: find.query, in: u.text, caseSensitive: find.caseSensitive, wholeWord: find.wholeWord)
      guard !r.isEmpty else { continue }
      out.ranges[u.id] = r
      out.first[u.id] = n
      order.append((u, n))
      n += r.count
    }
    out.total = n
    if n > 0 {
      let cur = min(max(find.index, 0), n - 1)
      out.current = cur
      out.scrollID = order.last { $0.1 <= cur }?.0.scroll
    }
    return out
  }

  /// Textos renderizados de un bloque, con el mismo esquema de ids que usan las vistas.
  private func units(_ block: MarkdownBlock, id: String) -> [Unit] {
    switch block {
    case .heading(_, let t), .paragraph(let t):
      return [Unit(id: id, text: plain(t), scroll: id)]
    case .list(let items):
      return flatten(items, depth: 0).enumerated().map { n, e in
        Unit(id: "\(id).l\(n)", text: plain(e.item.text), scroll: "\(id).l\(n)")
      }
    case .quote(let inner):
      return inner.enumerated().flatMap { units($1, id: "\(id).q\($0)") }
    case .code(_, let t):
      return t.components(separatedBy: "\n").enumerated().map { k, l in Unit(id: "\(id).c\(k)", text: l, scroll: "\(id).c\(k)") }
    case .table(let header, let rows):
      var out: [Unit] = []
      for (r, row) in ([header] + rows).enumerated() {
        for (c, cell) in row.enumerated() { out.append(Unit(id: "\(id).t\(r).\(c)", text: plain(cell), scroll: "\(id).t\(r)")) }
      }
      return out
    case .rule:
      return []
    }
  }

  private func plain(_ s: String) -> String { String(inline(s).characters) }

  private func flatten(_ items: [MarkdownListItem], depth: Int) -> [(item: MarkdownListItem, depth: Int)] {
    items.flatMap { [($0, depth)] + flatten($0.children, depth: depth + 1) }
  }

  /// Resalta las coincidencias de la unidad `id`: amarillo, y naranja la actual.
  private func highlight(_ attr: AttributedString, id: String, _ ctx: Context) -> AttributedString {
    guard let ranges = ctx.search.ranges[id], let first = ctx.search.first[id] else { return attr }
    var out = attr
    let str = String(attr.characters)
    for (k, nsr) in ranges.enumerated() {
      guard let r = Range(nsr, in: str) else { continue }
      let lo = out.index(out.startIndex, offsetByCharacters: str.distance(from: str.startIndex, to: r.lowerBound))
      let hi = out.index(out.startIndex, offsetByCharacters: str.distance(from: str.startIndex, to: r.upperBound))
      let isCurrent = ctx.search.current == first + k
      out[lo..<hi].swiftUI.backgroundColor = isCurrent ? Color.orange : Color.yellow.opacity(0.55)
    }
    return out
  }

  private func text(_ s: String, id: String, _ ctx: Context) -> Text { Text(highlight(inline(s), id: id, ctx)) }

  // MARK: - Marcas en el margen

  /// "+" verde del margen izquierdo; abre el código en `line` (base 1).
  private func mark(_ changed: Bool, line: Int, ctx: Context, font: Font = .system(size: 13, weight: .bold, design: .monospaced)) -> some View {
    Text(changed ? "+" : " ")
      .font(font).foregroundStyle(.green)
      .frame(width: ctx.gutter)
      .contentShape(Rectangle())
      .onTapGesture { if changed { onOpenLine(line) } }
      .modifier(CursorIf(on: changed))
      .help(changed ? "Ver en el código" : "")
  }

  private struct CursorIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View { on ? AnyView(content.handCursor()) : AnyView(content) }
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

  /// `at` solo viene en los bloques de primer nivel: son los que llevan marcas en el margen.
  private func blockView(_ block: MarkdownBlock, id: String, at: Placement?, _ ctx: Context) -> AnyView {
    func gutterRow(top: CGFloat = 0, _ body: some View) -> AnyView {
      guard let at else { return AnyView(body) }
      return AnyView(
        HStack(alignment: .top, spacing: 0) {
          mark(ctx.changed(at.lines), line: at.lines.lowerBound + 1, ctx: ctx).padding(.top, top)
          body
        })
    }
    switch block {
    case .heading(let level, let t):
      let size: CGFloat = [28, 22, 18, 16, 14, 13][level - 1]
      let top: CGFloat = level <= 2 ? 10 : 4
      return gutterRow(
        top: top + size * 0.25,
        VStack(alignment: .leading, spacing: 6) {
          text(t, id: id, ctx).font(.system(size: size, weight: .semibold)).padding(.top, top)
          if level <= 2 { Divider() }
        }.id(id))
    case .paragraph(let t):
      return gutterRow(text(t, id: id, ctx).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true).id(id))
    case .list(let items):
      return AnyView(listView(items, id: id, at: at, ctx))
    case .quote(let inner):
      return gutterRow(
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
          VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(inner.enumerated()), id: \.offset) { i, b in blockView(b, id: "\(id).q\(i)", at: nil, ctx) }
          }
          .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true))
    case .code(let lang, let t):
      return AnyView(codeView(highlighted(t, language: lang), id: id, at: at, ctx))
    case .table(let header, let rows):
      return AnyView(tableView(header, rows, id: id, at: at, ctx))
    case .rule:
      return gutterRow(Divider().padding(.vertical, 6))
    }
  }

  private func listView(_ items: [MarkdownListItem], id: String, at: Placement?, _ ctx: Context) -> some View {
    let flat = flatten(items, depth: 0)
    return VStack(alignment: .leading, spacing: 5) {
      ForEach(Array(flat.enumerated()), id: \.offset) { n, e in
        let uid = "\(id).l\(n)"
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          if at != nil { mark(ctx.changed(e.item.lines), line: e.item.lines.lowerBound + 1, ctx: ctx, font: .system(size: 14, weight: .bold, design: .monospaced)) }
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker(e.item, depth: e.depth).frame(minWidth: 18, alignment: .trailing)
            text(e.item.text, id: uid, ctx).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
          }
          .padding(.leading, CGFloat(e.depth) * 22)
        }
        .id(uid)
      }
    }
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

  private func tableView(_ header: [String], _ rows: [[String]], id: String, at: Placement?, _ ctx: Context) -> some View {
    let n = max(header.count, rows.map(\.count).max() ?? 0)
    let all = [header] + rows
    func line(_ r: Int) -> Int? { at.flatMap { r < $0.parts.count ? $0.parts[r] : nil } }
    let gutter = at != nil ? ctx.gutter : 0
    return Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
      ForEach(Array(all.enumerated()), id: \.offset) { r, row in
        let changed = ctx.changed(line: line(r))
        let bg: Color = r == 0 ? Color.secondary.opacity(0.12) : (r % 2 == 0 ? Color.secondary.opacity(0.04) : .clear)
        if r > 0 {
          GridRow {
            Color.clear.frame(width: gutter, height: 1)
            Divider().gridCellColumns(n)
          }
        }
        GridRow {
          if at != nil {
            mark(changed, line: (line(r) ?? 0) + 1, ctx: ctx).padding(.vertical, 6).id("\(id).t\(r)")
          }
          ForEach(0..<n, id: \.self) { c in
            cell(c < row.count ? row[c] : "", id: "\(id).t\(r).\(c)", bold: r == 0, ctx)
              .background(bg)
              .contentShape(Rectangle())
              .onTapGesture { if changed { onOpenLine((line(r) ?? 0) + 1) } }
          }
        }
      }
    }
    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)).padding(.leading, gutter))
  }

  private func cell(_ s: String, id: String, bold: Bool, _ ctx: Context) -> some View {
    text(s, id: id, ctx).font(.system(size: 13, weight: bold ? .semibold : .regular))
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10).padding(.vertical, 6)
  }

  private func codeView(_ code: AttributedString, id: String, at: Placement?, _ ctx: Context) -> some View {
    var lines: [AttributedString] = []
    var start = code.startIndex
    for i in code.characters.indices where code.characters[i] == "\n" {
      lines.append(AttributedString(code[start..<i]))
      start = code.characters.index(after: i)
    }
    lines.append(AttributedString(code[start...]))
    return VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(lines.enumerated()), id: \.offset) { k, l in
        let first = k == 0, last = k == lines.count - 1
        let ln = at.flatMap { k < $0.parts.count ? $0.parts[k] : nil }
        let uid = "\(id).c\(k)"
        HStack(alignment: .top, spacing: 0) {
          if at != nil {
            mark(ctx.changed(line: ln), line: (ln ?? 0) + 1, ctx: ctx, font: Typo.code.bold()).padding(.top, first ? 12 : 0)
          }
          Text(l.characters.isEmpty ? AttributedString(" ") : highlight(l, id: uid, ctx)).font(Typo.code)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.top, first ? 12 : 1).padding(.bottom, last ? 12 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              UnevenRoundedRectangle(
                topLeadingRadius: first ? 6 : 0, bottomLeadingRadius: last ? 6 : 0,
                bottomTrailingRadius: last ? 6 : 0, topTrailingRadius: first ? 6 : 0
              ).fill(Color.secondary.opacity(0.12)))
            .contentShape(Rectangle())
            .onTapGesture { if ctx.changed(line: ln) { onOpenLine((ln ?? 0) + 1) } }
        }
        .id(uid)
      }
    }
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
