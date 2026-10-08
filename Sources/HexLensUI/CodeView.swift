import AppKit
import HexLensCore
import SwiftUI

/// Colores de IntelliJ (Light y New UI Dark).
struct CodeTheme {
  let background, gutter, gutterText, text, keyword, string, number, comment, annotation, field, method: NSColor
  let added, removed, separator, addedBar, removedBar, guide, findMatch, findCurrent: NSColor

  static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }

  static let light = CodeTheme(
    background: color(0xFFFFFF), gutter: color(0xF7F8FA), gutterText: color(0xAEB3C2), text: color(0x080808),
    keyword: color(0x0033B3), string: color(0x067D17), number: color(0x1750EB), comment: color(0x8C8C8C),
    annotation: color(0x9E880D), field: color(0x871094), method: color(0x00627A),
    added: color(0xE5F4E5), removed: color(0xFBE4E4), separator: color(0xEEF2FB),
    addedBar: color(0x6CC56C), removedBar: color(0xE07070), guide: color(0xE4E6EB),
    findMatch: color(0xFFE48C, 0.6), findCurrent: color(0xF2C55C))

  static let dark = CodeTheme(
    background: color(0x1E1F22), gutter: color(0x1E1F22), gutterText: color(0x4B5059), text: color(0xBCBEC4),
    keyword: color(0xCF8E6D), string: color(0x6AAB73), number: color(0x2AACB8), comment: color(0x7A7E85),
    annotation: color(0xB3AE60), field: color(0xC77DBB), method: color(0x56A8F5),
    added: color(0x253A2B), removed: color(0x3F2A2C), separator: color(0x25272C),
    addedBar: color(0x549159), removedBar: color(0xBD5757), guide: color(0x34363B),
    findMatch: color(0x5F5338), findCurrent: color(0x8A6E2F))

  /// JetBrains Mono: la del IntelliJ instalado si no está en el sistema.
  static let font: NSFont = {
    let dir = "/Applications/IntelliJ IDEA.app/Contents/jbr/Contents/Home/lib/fonts"
    if NSFont(name: "JetBrainsMono-Regular", size: 13) == nil {
      for f in ["JetBrainsMono-Regular", "JetBrainsMono-Italic", "JetBrainsMono-Bold"] {
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "\(dir)/\(f).ttf") as CFURL, .process, nil)
      }
    }
    return NSFont(name: "JetBrainsMono-Regular", size: 13.5) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  }()

  static let italic: NSFont = NSFont(name: "JetBrainsMono-Italic", size: 13.5)
    ?? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)

  static let paragraph: NSParagraphStyle = {
    let p = NSMutableParagraphStyle()
    p.lineSpacing = 6
    return p
  }()
}

/// Lo que pinta el visor: documento, tokens y enlaces ya resueltos.
struct CodeContent {
  let id: String
  let document: CodeDocument
  let tokens: [Token]
  let semantics: JavaSemantics
  let links: [(NSRange, CodeLink)]
  /// Métodos importados estáticamente: sus llamadas van en cursiva, como en IntelliJ.
  var staticNames: Set<String> = []
}

struct ScrollRequest: Equatable {
  let line: Int  // índice de línea del documento
  let serial: Int
}

struct CodeTextView: NSViewRepresentable {
  let content: CodeContent
  let scroll: ScrollRequest?
  let matches: [NSRange]
  let currentMatch: Int?
  let onLink: (CodeLink) -> Void
  @Environment(\.colorScheme) private var scheme

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder

    let textView = CodeNSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.allowsUndo = false
    textView.textContainerInset = NSSize(width: CodeNSTextView.gutterWidth + 8, height: 6)
    textView.isHorizontallyResizable = true
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width, .height]
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
    textView.delegate = context.coordinator
    scrollView.documentView = textView
    // El margen va fijo a la izquierda: hay que repintarlo al desplazar.
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
    ) { [weak textView] _ in textView?.needsDisplay = true }
    return scrollView
  }

  private func applyHighlights(_ textView: CodeNSTextView, theme: CodeTheme, coordinator c: Coordinator, textChanged: Bool) {
    guard let lm = textView.layoutManager else { return }
    let length = (textView.string as NSString).length
    let valid = matches.filter { NSMaxRange($0) <= length }
    let current = currentMatch.flatMap { valid.indices.contains($0) ? $0 : nil }
    let state = Coordinator.Highlight(matches: valid, current: current, dark: scheme == .dark)
    guard textChanged || state != c.highlight else { return }
    let previous = c.highlight
    c.highlight = state
    lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
    for (i, r) in valid.enumerated() {
      lm.addTemporaryAttribute(.backgroundColor, value: i == current ? theme.findCurrent : theme.findMatch, forCharacterRange: r)
    }
    if let current, textChanged || current != previous.current || valid != previous.matches {
      let r = valid[current]
      DispatchQueue.main.async {
        textView.scrollRangeToVisible(r)
        textView.showFindIndicator(for: r)
      }
    }
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? CodeNSTextView else { return }
    let theme = scheme == .dark ? CodeTheme.dark : CodeTheme.light
    let c = context.coordinator
    c.onLink = onLink
    let key = "\(content.id)|\(scheme)"
    let textChanged = c.key != key
    if textChanged {
      c.key = key
      c.links = content.links.map(\.1)
      textView.lines = content.document.lines
      textView.lineStarts = content.document.lineStarts
      textView.computeIndents()
      // Fichero nuevo entero: sin fondo verde, solo la barra del margen (como IntelliJ).
      textView.allAdded = !content.document.lines.isEmpty && content.document.lines.allSatisfy { $0.kind == .added }
      textView.theme = theme
      textView.backgroundColor = theme.background
      textView.textStorage?.setAttributedString(Self.attributed(content, theme: theme))
      textView.scroll(.zero)
    }
    applyHighlights(textView, theme: theme, coordinator: c, textChanged: textChanged)
    if let scroll, scroll != c.lastScroll, scroll.line < content.document.lineStarts.count {
      c.lastScroll = scroll
      DispatchQueue.main.async { textView.reveal(line: scroll.line, document: content.document) }
    }
  }

  static func attributed(_ c: CodeContent, theme: CodeTheme) -> NSAttributedString {
    let text = c.document.text
    let ns = text as NSString
    let s = NSMutableAttributedString(
      string: text,
      attributes: [.font: CodeTheme.font, .foregroundColor: theme.text, .paragraphStyle: CodeTheme.paragraph, .ligature: 0])
    let italic = CodeTheme.italic
    let declarations = Set(c.semantics.declarations.map(\.location))
    let calls = Set(c.semantics.calls.map(\.nameRange.location))
    // Llamadas estáticas: Tipo.metodo( o metodo( importado con import static.
    let staticCalls = Set(c.semantics.calls.filter { call in
      if let r = call.receiver { return r.first?.isUppercase == true }
      return c.staticNames.contains(call.name)
    }.map(\.nameRange.location))

    for t in c.tokens {
      switch t.kind {
      case .keyword: s.addAttribute(.foregroundColor, value: theme.keyword, range: t.range)
      case .string: s.addAttribute(.foregroundColor, value: theme.string, range: t.range)
      case .number: s.addAttribute(.foregroundColor, value: theme.number, range: t.range)
      case .annotation: s.addAttribute(.foregroundColor, value: theme.annotation, range: t.range)
      case .comment:
        s.addAttributes([.foregroundColor: theme.comment, .font: italic], range: t.range)
      case .identifier:
        let word = ns.substring(with: t.range)
        if declarations.contains(t.range.location) {
          s.addAttribute(.foregroundColor, value: theme.method, range: t.range)
        } else if staticCalls.contains(t.range.location) {
          s.addAttribute(.font, value: italic, range: t.range)
        } else if word.count > 1, word.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) {
          // Constantes (static final): morado en cursiva.
          s.addAttributes([.foregroundColor: theme.field, .font: italic], range: t.range)
        } else if !calls.contains(t.range.location), c.semantics.fields.contains(word) {
          s.addAttribute(.foregroundColor, value: theme.field, range: t.range)
        }
      case .punct: break
      }
    }
    for (i, (range, _)) in c.links.enumerated() where NSMaxRange(range) <= ns.length {
      s.addAttribute(.link, value: URL(string: "hexlens://l/\(i)")!, range: range)
    }
    return s
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var key = ""
    var links: [CodeLink] = []
    var lastScroll: ScrollRequest?
    struct Highlight: Equatable {
      var matches: [NSRange] = []
      var current: Int?
      var dark = false
    }
    var highlight = Highlight()
    var onLink: (CodeLink) -> Void = { _ in }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      guard let url = link as? URL, url.scheme == "hexlens", let i = Int(url.lastPathComponent), links.indices.contains(i) else { return false }
      onLink(links[i])
      return true
    }
  }
}

/// NSTextView que pinta el fondo de las líneas añadidas/quitadas a todo el ancho.
final class CodeNSTextView: NSTextView {
  var lines: [CodeLine] = []
  var lineStarts: [Int] = []
  var theme = CodeTheme.light
  var allAdded = false
  private var indents: [Int] = []
  private var indentUnit = 2

  /// Sangría por línea (las vacías heredan la menor de sus vecinas) y unidad de sangría del fichero.
  func computeIndents() {
    let raw = lines.map { l -> Int? in
      guard l.kind != .separator, !l.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
      return l.text.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }
    var out = [Int](repeating: 0, count: raw.count)
    var prev = 0
    for i in raw.indices {
      if let v = raw[i] { out[i] = v; prev = v; continue }
      let next = raw[(i + 1)...].lazy.compactMap { $0 }.first ?? 0
      out[i] = min(prev, next)
    }
    indents = out
    let steps = raw.compactMap { $0 }.filter { $0 > 0 }
    indentUnit = steps.contains { $0 % 4 != 0 } ? 2 : 4
  }

  func lineIndex(at offset: Int) -> Int {
    var lo = 0, hi = lineStarts.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
    }
    return max(0, lo)
  }

  override func drawBackground(in rect: NSRect) {
    super.drawBackground(in: rect)
    guard let lm = layoutManager, let tc = textContainer, !lines.isEmpty else { return }
    let origin = textContainerOrigin
    let glyphs = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
    lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, glyphRange, _ in
      let charIndex = lm.characterIndexForGlyph(at: glyphRange.location)
      let line = self.lines[self.lineIndex(at: charIndex)]
      let color: NSColor?
      switch line.kind {
      case .added: color = self.allAdded ? nil : self.theme.added
      case .removed: color = self.theme.removed
      case .separator: color = self.theme.separator
      case .context: color = nil
      }
      if let color {
        color.setFill()
        NSRect(x: 0, y: frag.minY + origin.y, width: max(self.bounds.width, rect.maxX), height: frag.height).fill()
      }
      // Guías de indentación, como las de IntelliJ.
      let i = self.lineIndex(at: charIndex)
      if i < self.indents.count, self.indents[i] > self.indentUnit {
        let charWidth = (" " as NSString).size(withAttributes: [.font: CodeTheme.font]).width
        self.theme.guide.setFill()
        var col = self.indentUnit
        while col < self.indents[i] {
          NSRect(x: origin.x + 5 + CGFloat(col) * charWidth, y: frag.minY + origin.y, width: 1, height: frag.height).fill()
          col += self.indentUnit
        }
      }
    }
    drawGutter(rect)
  }

  static let gutterWidth: CGFloat = 50

  /// Margen con número de línea (nuevo o viejo) y barra de cambio, fijo al borde izquierdo visible.
  private func drawGutter(_ dirtyRect: NSRect) {
    guard let lm = layoutManager, let tc = textContainer else { return }
    let visible = visibleRect
    let gutter = NSRect(x: visible.minX, y: dirtyRect.minY, width: Self.gutterWidth, height: dirtyRect.height)
    theme.gutter.setFill()
    gutter.fill()
    theme.gutterText.withAlphaComponent(0.25).setFill()
    NSRect(x: gutter.maxX, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    guard !lines.isEmpty else { return }

    let origin = textContainerOrigin
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
      .foregroundColor: theme.gutterText,
    ]
    let glyphs = lm.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
    lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, glyphRange, _ in
      let line = self.lines[self.lineIndex(at: lm.characterIndexForGlyph(at: glyphRange.location))]
      let y = frag.minY + origin.y
      switch line.kind {
      case .added: self.theme.addedBar.setFill()
      case .removed: self.theme.removedBar.setFill()
      default: NSColor.clear.setFill()
      }
      NSRect(x: gutter.maxX - 4, y: y, width: 3, height: frag.height).fill()
      guard let n = line.newNumber ?? line.oldNumber else { return }
      let label = NSAttributedString(string: "\(n)", attributes: attrs)
      let size = label.size()
      label.draw(at: NSPoint(x: gutter.maxX - 9 - size.width, y: y + (frag.height - size.height) / 2))
    }
  }

  func reveal(line: Int, document: CodeDocument) {
    let start = document.lineStarts[line]
    let length = (document.lines[line].text as NSString).length
    let range = NSRange(location: start, length: length)
    guard let lm = layoutManager, let tc = textContainer else { return }
    let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    var r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
    r.origin.y += textContainerOrigin.y
    // Línea objetivo a un tercio de la altura visible, como al navegar en el IDE.
    let visible = enclosingScrollView?.contentView.bounds.height ?? 600
    scroll(NSPoint(x: 0, y: max(0, r.minY - visible / 3)))
    enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
    if length > 0 { showFindIndicator(for: range) }
  }
}
