import AppKit
import HexLensCore
import SwiftUI

/// Colores de IntelliJ (Light y New UI Dark).
struct CodeTheme {
  let background, gutter, gutterText, text, keyword, string, number, comment, annotation, field, method: NSColor
  let added, removed, separator, addedBar, removedBar, guide, findMatch, findCurrent, usage: NSColor

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
    findMatch: color(0xFFE48C, 0.6), findCurrent: color(0xF2C55C), usage: color(0xE3E8F4))

  static let dark = CodeTheme(
    background: color(0x1E1F22), gutter: color(0x1E1F22), gutterText: color(0x4B5059), text: color(0xBCBEC4),
    keyword: color(0xCF8E6D), string: color(0x6AAB73), number: color(0x2AACB8), comment: color(0x7A7E85),
    annotation: color(0xB3AE60), field: color(0xC77DBB), method: color(0x56A8F5),
    added: color(0x253A2B), removed: color(0x3F2A2C), separator: color(0x25272C),
    addedBar: color(0x549159), removedBar: color(0xBD5757), guide: color(0x34363B),
    findMatch: color(0x5F5338), findCurrent: color(0x8A6E2F), usage: color(0x32373F))

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
  /// Estructura del fichero (líneas del fichero nuevo).
  var outline: [OutlineEntry] = []
  /// El plegado por llaves solo tiene sentido en Java.
  var isJava = true
}

struct ScrollRequest: Equatable {
  let line: Int  // índice de línea del documento
  let serial: Int
}

/// Rango de una nota en números de línea del fichero nuevo, para el margen y el fondo.
struct NoteSpan: Equatable {
  let id: UUID
  let start: Int
  let end: Int
  let outdated: Bool
}

struct CodeTextView: NSViewRepresentable {
  let content: CodeContent
  let scroll: ScrollRequest?
  let matches: [NSRange]
  let currentMatch: Int?
  var notes: [NoteSpan] = []
  var addNoteSerial = 0
  var onAddNote: (Int, Int) -> Void = { _, _ in }
  var onOpenNote: (UUID) -> Void = { _ in }
  var findUsagesSerial = 0
  var onFindUsages: (String) -> Void = { _ in }
  /// Línea del fichero nuevo bajo el cursor, para las migas.
  var onCursor: (Int?) -> Void = { _ in }
  let onLink: (CodeLink) -> Void
  /// Panel izquierdo del lado a lado: solo lectura, sin notas ni enlaces ni migas.
  var readOnlyLeft = false
  /// Sincroniza el scroll vertical con el otro panel.
  var sync: ScrollSync?
  @Environment(\.colorScheme) private var scheme

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> CodeContainerView {
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
    textView.textContainerInset = NSSize(width: 8, height: 6)
    textView.isHorizontallyResizable = true
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width, .height]
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
    textView.delegate = context.coordinator
    scrollView.documentView = textView
    if let lm = textView.layoutManager, lm.delegate == nil { lm.delegate = textView }
    scrollView.verticalRulerView = CodeGutterView(scrollView: scrollView, textView: textView)
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true
    textView.typingAttributes = [.font: CodeTheme.font, .paragraphStyle: CodeTheme.paragraph]
    textView.readOnlySide = readOnlyLeft
    context.coordinator.readOnly = readOnlyLeft
    sync?.register(scrollView)
    let container = CodeContainerView(scrollView: scrollView, textView: textView)
    context.coordinator.textView = textView
    return container
  }

  private func applyHighlights(_ textView: CodeNSTextView, theme: CodeTheme, coordinator c: Coordinator, textChanged: Bool) {
    let length = (textView.string as NSString).length
    let valid = matches.filter { NSMaxRange($0) <= length }
    let current = currentMatch.flatMap { valid.indices.contains($0) ? $0 : nil }
    let state = Coordinator.Highlight(matches: valid, current: current, dark: scheme == .dark)
    guard textChanged || state != c.highlight else { return }
    let previous = c.highlight
    c.highlight = state
    textView.findMatches = valid
    textView.findCurrent = current
    textView.repaintHighlights()
    if let current, textChanged || current != previous.current || valid != previous.matches {
      let r = valid[current]
      DispatchQueue.main.async {
        textView.unfold(line: textView.lineIndex(at: r.location))
        textView.revealMatch(r)
      }
    }
  }

  func updateNSView(_ container: CodeContainerView, context: Context) {
    let textView = container.textView
    let theme = scheme == .dark ? CodeTheme.dark : CodeTheme.light
    let c = context.coordinator
    c.onLink = onLink
    c.onCursor = onCursor
    textView.onAddNote = onAddNote
    textView.onOpenNote = onOpenNote
    textView.onFindUsages = onFindUsages
    if findUsagesSerial != c.lastUsagesSerial {
      let first = c.lastUsagesSerial == nil
      c.lastUsagesSerial = findUsagesSerial
      if !first { DispatchQueue.main.async { textView.findUsagesAtCursor() } }
    }
    if textView.noteSpans != notes { textView.noteSpans = notes; textView.needsDisplay = true; container.strip.needsDisplay = true }
    container.scrollView.verticalRulerView?.needsDisplay = true
    if addNoteSerial != c.lastNoteSerial {
      let first = c.lastNoteSerial == nil
      c.lastNoteSerial = addNoteSerial
      if !first { DispatchQueue.main.async { textView.addNoteAtSelection() } }
    }
    let key = "\(content.id)|\(scheme)"
    let textChanged = c.key != key
    if textChanged {
      c.key = key
      c.links = content.links.map(\.1)
      textView.lines = content.document.lines
      textView.lineStarts = content.document.lineStarts
      textView.computeIndents()
      textView.configureFolding(Self.foldRegions(for: content.document.lines, isJava: content.isJava))
      textView.indexIdentifiers(tokens: content.tokens)
      textView.declarations = content.semantics.declarations
      c.reportCursor(textView)
      // Fichero nuevo entero: sin fondo verde, solo la barra del margen (como IntelliJ).
      textView.allAdded = !content.document.lines.isEmpty && content.document.lines.allSatisfy { $0.kind == .added }
      textView.theme = theme
      textView.backgroundColor = theme.background
      container.strip.theme = theme
      textView.textStorage?.setAttributedString(Self.attributed(content, theme: theme))
      textView.scroll(NSPoint(x: textView.leftEdge, y: 0))
    }
    applyHighlights(textView, theme: theme, coordinator: c, textChanged: textChanged)
    container.strip.needsDisplay = true
    if let scroll, scroll != c.lastScroll, scroll.line < content.document.lineStarts.count {
      c.lastScroll = scroll
      DispatchQueue.main.async { textView.reveal(line: scroll.line) }
    }
  }

  /// Regiones plegables en índices del documento. Sin hunks sueltos ni relleno del lado a lado (descuadraría los paneles) la llave de cierre no cuadraría.
  static func foldRegions(for lines: [CodeLine], isJava: Bool) -> [FoldRegion] {
    guard isJava, !lines.contains(where: { $0.kind == .separator || $0.kind == .filler }) else { return [] }
    let index = lines.indices.filter { lines[$0].kind != .removed }
    let found = FoldRegions.compute(lines: index.map { lines[$0].text })
    return found.map { FoldRegion(kind: $0.kind, start: index[$0.start], hiddenEnd: index[$0.hiddenEnd], end: index[$0.end]) }
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
    var lastUsagesSerial: Int?
    var key = ""
    var links: [CodeLink] = []
    var lastScroll: ScrollRequest?
    var lastNoteSerial: Int?
    struct Highlight: Equatable {
      var matches: [NSRange] = []
      var current: Int?
      var dark = false
    }
    var highlight = Highlight()
    var onLink: (CodeLink) -> Void = { _ in }
    var onCursor: (Int?) -> Void = { _ in }
    var readOnly = false
    weak var textView: CodeNSTextView?

    func reportCursor(_ tv: CodeNSTextView) {
      guard !readOnly else { return }
      let line = tv.currentNewLine()
      DispatchQueue.main.async { [onCursor] in onCursor(line) }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let tv = notification.object as? CodeNSTextView else { return }
      tv.updateUsages()
      reportCursor(tv)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      guard let url = link as? URL, url.scheme == "hexlens", let i = Int(url.lastPathComponent), links.indices.contains(i) else { return false }
      onLink(links[i])
      return true
    }
  }
}

/// NSTextView que pinta el fondo de las líneas añadidas/quitadas a todo el ancho.
final class CodeNSTextView: NSTextView {
  /// Último visor con el foco, para que ⌘F tome su selección.
  static weak var focused: CodeNSTextView?

  override func becomeFirstResponder() -> Bool {
    let ok = super.becomeFirstResponder()
    if ok { Self.focused = self }
    return ok
  }

  /// Nunca más estrecho que el área visible: si no, al pasar de un fichero ancho a uno estrecho
  /// el clip se queda con origen x negativo y el código aparece desplazado a la derecha.
  /// El margen es un `NSRulerView` superpuesto: el clip reserva su ancho con `contentInsets.left`, así que
  /// la columna 0 del texto se ve con el origen en x = -ancho del margen, no en 0.
  var leftEdge: CGFloat { -(enclosingScrollView?.contentView.contentInsets.left ?? 0) }

  override func setFrameSize(_ newSize: NSSize) {
    var size = newSize
    if let clip = enclosingScrollView?.contentView { size.width = max(size.width, clip.bounds.width + leftEdge) }
    super.setFrameSize(size)
  }

  var lines: [CodeLine] = []
  var lineStarts: [Int] = []
  var theme = CodeTheme.light
  var allAdded = false
  var readOnlySide = false
  var noteSpans: [NoteSpan] = []
  var onAddNote: (Int, Int) -> Void = { _, _ in }
  var onOpenNote: (UUID) -> Void = { _ in }
  var onFindUsages: (String) -> Void = { _ in }
  var findMatches: [NSRange] = []
  var findCurrent: Int?
  /// Nombres de métodos declarados: un clic simple abre sus usos.
  var declarations: [NSRange] = [] {
    didSet { window?.invalidateCursorRects(for: self) }
  }
  private var indents: [Int] = []
  private var indentUnit = 2
  private var identifierIndex: [String: [NSRange]] = [:]
  private var identifierTokens: [NSRange] = []
  private var usages: [NSRange] = []

  func indexIdentifiers(tokens: [Token]) {
    let ns = string as NSString
    identifierIndex = [:]
    identifierTokens = []
    usages = []
    for t in tokens where t.kind == .identifier && NSMaxRange(t.range) <= ns.length {
      identifierTokens.append(t.range)
      identifierIndex[ns.substring(with: t.range), default: []].append(t.range)
    }
  }

  /// Usos del identificador bajo el cursor (o seleccionado entero), con el fondo tenue.
  func updateUsages() {
    let sel = selectedRange()
    var found: [NSRange] = []
    var lo = 0, hi = identifierTokens.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if NSMaxRange(identifierTokens[mid]) < sel.location { lo = mid + 1 } else { hi = mid }
    }
    if lo < identifierTokens.count {
      let t = identifierTokens[lo]
      let touches = sel.length == 0 ? (t.location <= sel.location && sel.location <= NSMaxRange(t)) : t == sel
      if touches, let all = identifierIndex[(string as NSString).substring(with: t)], all.count > 1 { found = all }
    }
    guard found != usages else { return }
    usages = found
    repaintHighlights()
  }

  /// Usos debajo y búsqueda encima, para que ⌘F nunca quede tapado.
  func repaintHighlights() {
    guard let lm = layoutManager else { return }
    let length = (string as NSString).length
    lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
    for r in usages where NSMaxRange(r) <= length {
      lm.addTemporaryAttribute(.backgroundColor, value: theme.usage, forCharacterRange: r)
    }
    for (i, r) in findMatches.enumerated() where NSMaxRange(r) <= length {
      lm.addTemporaryAttribute(.backgroundColor, value: i == findCurrent ? theme.findCurrent : theme.findMatch, forCharacterRange: r)
    }
  }

  /// Línea del fichero nuevo bajo el cursor (la anterior más cercana si es una línea quitada).
  func currentNewLine() -> Int? {
    guard !lines.isEmpty else { return nil }
    let i = min(lineIndex(at: selectedRange().location), lines.count - 1)
    return lines[...i].last { $0.newNumber != nil }?.newNumber
  }

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
      case .filler: color = self.theme.gutterText.withAlphaComponent(0.10)
      }
      if let color {
        color.setFill()
        NSRect(x: 0, y: frag.minY + origin.y, width: max(self.bounds.width, rect.maxX), height: frag.height).fill()
      }
      if let n = line.newNumber, self.noteSpans.contains(where: { !$0.outdated && $0.start <= n && n <= $0.end }) {
        NSColor.systemBlue.withAlphaComponent(0.09).setFill()
        NSRect(x: 0, y: frag.minY + origin.y, width: max(self.bounds.width, rect.maxX), height: frag.height).fill()
      }
      let i = self.lineIndex(at: charIndex)
      if let region = self.regionByStart[i], self.folded.contains(i) {
        let pill = self.pillRect(region, glyph: glyphRange.location)
        self.theme.guide.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
        Self.pillText(region).draw(at: NSPoint(x: pill.minX + 4, y: pill.minY + (pill.height - Self.pillText(region).size().height) / 2))
      }
      // Guías de indentación, como las de IntelliJ.
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
  }

  static let gutterWidth: CGFloat = 62

  /// Margen con número de línea (nuevo o viejo), barra de cambio y marcas de nota. Lo pinta `CodeGutterView`.
  func drawGutter(in ruler: NSRulerView, rect dirty: NSRect) {
    let rect = dirty.intersection(ruler.bounds)
    NSBezierPath(rect: ruler.bounds).setClip()
    theme.gutter.setFill()
    rect.fill()
    theme.gutterText.withAlphaComponent(0.25).setFill()
    NSRect(x: ruler.bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    guard let lm = layoutManager, let tc = textContainer, !lines.isEmpty else { return }

    let origin = textContainerOrigin
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
      .foregroundColor: theme.gutterText,
    ]
    let maxX = ruler.bounds.maxX - 1
    let glyphs = lm.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
    lm.enumerateLineFragments(forGlyphRange: glyphs) { frag, _, _, glyphRange, _ in
      let line = self.lines[self.lineIndex(at: lm.characterIndexForGlyph(at: glyphRange.location))]
      let r = ruler.convert(NSRect(x: 0, y: frag.minY + origin.y, width: 1, height: frag.height), from: self)
      switch line.kind {
      case .added: self.theme.addedBar.setFill()
      case .removed: self.theme.removedBar.setFill()
      default: NSColor.clear.setFill()
      }
      NSRect(x: maxX - 4, y: r.minY, width: 3, height: r.height).fill()
      if let n = line.newNumber, let span = self.noteSpans.first(where: { $0.start <= n && n <= $0.end }) {
        (span.outdated ? self.theme.gutterText : NSColor.systemBlue).setFill()
        NSBezierPath(roundedRect: NSRect(x: 3, y: r.midY - 3.5, width: 7, height: 7), xRadius: 2, yRadius: 2).fill()
      }
      if let region = self.regionByStart[self.lineIndex(at: lm.characterIndexForGlyph(at: glyphRange.location))] {
        let folded = self.folded.contains(region.start)
        let c = NSPoint(x: maxX - 14, y: r.midY)
        let path = NSBezierPath()
        if folded {
          path.move(to: NSPoint(x: c.x - 2, y: c.y - 3.5)); path.line(to: NSPoint(x: c.x + 2.5, y: c.y)); path.line(to: NSPoint(x: c.x - 2, y: c.y + 3.5))
        } else {
          path.move(to: NSPoint(x: c.x - 3.5, y: c.y - 2)); path.line(to: NSPoint(x: c.x, y: c.y + 2.5)); path.line(to: NSPoint(x: c.x + 3.5, y: c.y - 2))
        }
        path.lineWidth = 1.2
        path.lineJoinStyle = .round
        self.theme.gutterText.setStroke()
        path.stroke()
      }
      guard let n = line.newNumber ?? line.oldNumber else { return }
      let label = NSAttributedString(string: "\(n)", attributes: attrs)
      let size = label.size()
      label.draw(at: NSPoint(x: maxX - 21 - size.width, y: r.minY + (r.height - size.height) / 2))
    }
  }

  /// Clic en el margen: pliega o despliega si cae en el chevron; si no, abre la nota de esa línea.
  /// `y` en coordenadas del visor y `x` en las del margen.
  func gutterClick(x: CGFloat, y: CGFloat) {
    guard let lm = layoutManager, let tc = textContainer, !lines.isEmpty else { return }
    let glyph = lm.glyphIndex(for: NSPoint(x: 1, y: y - textContainerOrigin.y), in: tc)
    let index = lineIndex(at: lm.characterIndexForGlyph(at: glyph))
    if x >= Self.gutterWidth - 23, regionByStart[index] != nil {
      toggleFold(index)
      return
    }
    let line = lines[index]
    if let n = line.newNumber, let span = noteSpans.first(where: { $0.start <= n && n <= $0.end }) {
      onOpenNote(span.id)
    }
  }

  // MARK: Plegado

  private(set) var regions: [FoldRegion] = []
  private(set) var folded: Set<Int> = []
  private(set) var regionByStart: [Int: FoldRegion] = [:]
  private var hiddenRanges: [NSRange] = []

  /// Fija las regiones del fichero y pliega los imports. No invalida el layout: se llama justo antes de cambiar el texto.
  func configureFolding(_ new: [FoldRegion]) {
    regions = new
    regionByStart = Dictionary(new.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
    folded = Set(new.filter { $0.kind == .imports }.map(\.start))
    rebuildHidden()
  }

  private func lineEnd(_ i: Int) -> Int { lineStarts[i] + (lines[i].text as NSString).length }

  private func rebuildHidden() {
    var out: [NSRange] = []
    for r in regions where folded.contains(r.start) && r.hiddenEnd > r.start && lineStarts.indices.contains(r.hiddenEnd) {
      let a = lineEnd(r.start)
      out.append(NSRange(location: a, length: lineEnd(r.hiddenEnd) - a))
    }
    out.sort { $0.location < $1.location }
    var merged: [NSRange] = []
    for r in out {
      if let last = merged.last, r.location <= NSMaxRange(last) {
        merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(r)) - last.location)
      } else {
        merged.append(r)
      }
    }
    hiddenRanges = merged
  }

  private func isHidden(_ offset: Int) -> Bool {
    var lo = 0, hi = hiddenRanges.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if NSMaxRange(hiddenRanges[mid]) <= offset { lo = mid + 1 } else { hi = mid }
    }
    return lo < hiddenRanges.count && hiddenRanges[lo].location <= offset
  }

  private func applyFold() {
    rebuildHidden()
    let sel = selectedRange()
    if let r = hiddenRanges.first(where: { NSLocationInRange(sel.location, $0) }) {
      setSelectedRange(NSRange(location: r.location, length: 0))
    }
    if let lm = layoutManager {
      let all = NSRange(location: 0, length: (string as NSString).length)
      lm.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
      lm.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
    }
    needsDisplay = true
    enclosingScrollView?.verticalRulerView?.needsDisplay = true
  }

  func toggleFold(_ start: Int) {
    guard regionByStart[start] != nil else { return }
    if folded.contains(start) { folded.remove(start) } else { folded.insert(start) }
    applyFold()
  }

  /// Despliega lo que oculte esa línea (navegación, notas, búsqueda y marcas).
  func unfold(line: Int) {
    let hiding = folded.filter { s in regionByStart[s].map { s < line && line <= $0.hiddenEnd } ?? false }
    guard !hiding.isEmpty else { return }
    folded.subtract(hiding)
    applyFold()
  }

  private var caretLine: Int { lineIndex(at: selectedRange().location) }

  func foldAtCaret() {
    let line = caretLine
    guard let r = regions.filter({ !folded.contains($0.start) && $0.hiddenEnd > $0.start && $0.start <= line && line <= $0.end }).max(by: { $0.start < $1.start }) else { return }
    folded.insert(r.start)
    applyFold()
  }

  func unfoldAtCaret() {
    let line = caretLine
    guard let r = regions.filter({ folded.contains($0.start) && $0.start <= line && line <= $0.hiddenEnd }).max(by: { $0.start < $1.start }) else { return }
    folded.remove(r.start)
    applyFold()
  }

  /// Pliega todo salvo los tipos de primer nivel, para que el fichero siga siendo navegable.
  func foldAll() {
    var topEnd = -1
    var top = Set<Int>()
    for r in regions where r.kind == .block && r.start > topEnd {
      top.insert(r.start)
      topEnd = r.end
    }
    folded = Set(regions.filter { $0.hiddenEnd > $0.start && !top.contains($0.start) }.map(\.start))
    applyFold()
  }

  func unfoldAll() {
    folded = []
    applyFold()
  }

  /// En el visor los atajos de plegado ganan a los del zoom del grafo (⌘+ / ⌘-).
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard event.type == .keyDown, window?.firstResponder === self, mods.contains(.command),
      mods.isDisjoint(with: [.option, .control]), !regions.isEmpty,
      let key = event.charactersIgnoringModifiers
    else { return super.performKeyEquivalent(with: event) }
    let shift = mods.contains(.shift)
    switch key {
    case "-", "_": shift ? foldAll() : foldAtCaret()
    case "+", "=", "*": shift ? unfoldAll() : unfoldAtCaret()
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }

  private static func pillText(_ region: FoldRegion) -> NSAttributedString {
    NSAttributedString(
      string: region.kind == .block && region.hidesClosing ? "…}" : "…",
      attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
  }

  /// Marcador tras el texto visible de la primera línea de una región plegada.
  private func pillRect(_ region: FoldRegion, glyph: Int) -> NSRect {
    let used = layoutManager?.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil) ?? .zero
    let w = Self.pillText(region).size().width + 8
    return NSRect(x: textContainerOrigin.x + used.maxX + 6, y: textContainerOrigin.y + used.minY + 1, width: w, height: max(used.height - 2, 4))
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if let lm = layoutManager, let tc = textContainer, !folded.isEmpty, !lines.isEmpty {
      let glyph = lm.glyphIndex(for: NSPoint(x: 1, y: p.y - textContainerOrigin.y), in: tc)
      let i = lineIndex(at: lm.characterIndexForGlyph(at: glyph))
      if folded.contains(i), let region = regionByStart[i], pillRect(region, glyph: glyph).contains(p) {
        toggleFold(i)
        return
      }
    }
    let flags = event.modifierFlags.intersection([.shift, .option, .control])
    if event.clickCount == 1, flags.isEmpty, let r = declarationRange(at: p) {
      super.mouseDown(with: event)
      let sel = selectedRange()
      if sel.length == 0, sel.location >= r.location, sel.location <= NSMaxRange(r), NSMaxRange(r) <= (string as NSString).length {
        onFindUsages((string as NSString).substring(with: r))
      }
      return
    }
    super.mouseDown(with: event)
  }

  private func declarationRange(at p: NSPoint) -> NSRange? {
    guard !declarations.isEmpty, let lm = layoutManager, let tc = textContainer else { return nil }
    let o = textContainerOrigin
    let pt = NSPoint(x: p.x - o.x, y: p.y - o.y)
    var fraction: CGFloat = 0
    let g = lm.glyphIndex(for: pt, in: tc, fractionOfDistanceThroughGlyph: &fraction)
    let rect = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
    guard rect.contains(pt) else { return nil }
    let c = lm.characterIndexForGlyph(at: g)
    return declarations.first { c >= $0.location && c < NSMaxRange($0) }
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard let lm = layoutManager, let tc = textContainer else { return }
    let o = textContainerOrigin
    let total = (string as NSString).length
    for r in declarations where NSMaxRange(r) <= total {
      let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
      var rect = lm.boundingRect(forGlyphRange: g, in: tc)
      rect.origin.x += o.x
      rect.origin.y += o.y
      if rect.height > 0 && rect.intersects(visibleRect) { addCursorRect(rect, cursor: .pointingHand) }
    }
  }

  // MARK: Notas

  /// Líneas del fichero nuevo cubiertas por la selección (o la del cursor si no hay selección).
  func addNoteAtSelection() {
    let sel = selectedRange()
    let total = (string as NSString).length
    guard !lines.isEmpty, sel.location <= total else { return }
    let first = lineIndex(at: sel.location)
    let last = sel.length > 0 ? lineIndex(at: max(sel.location, NSMaxRange(sel) - 1)) : first
    let numbers = lines[first...last].compactMap(\.newNumber)
    guard let lo = numbers.min(), let hi = numbers.max() else { NSSound.beep(); return }
    onAddNote(lo, hi)
  }

  /// Identificador bajo el cursor (o la selección entera si es un identificador).
  func identifierAtCursor() -> String? {
    let sel = selectedRange()
    let ns = string as NSString
    guard let t = identifierTokens.first(where: { sel.length == 0 ? ($0.location <= sel.location && sel.location <= NSMaxRange($0)) : $0 == sel }),
          NSMaxRange(t) <= ns.length else { return nil }
    return ns.substring(with: t)
  }

  func findUsagesAtCursor() {
    guard let w = identifierAtCursor() else { NSSound.beep(); return }
    onFindUsages(w)
  }

  @objc private func findUsagesFromMenu(_ sender: Any?) { findUsagesAtCursor() }

  @objc private func addNoteFromMenu(_ sender: Any?) { addNoteAtSelection() }

  override func menu(for event: NSEvent) -> NSMenu? {
    if selectedRange().length == 0 {
      let p = convert(event.locationInWindow, from: nil)
      let i = characterIndexForInsertion(at: p)
      if i != NSNotFound { setSelectedRange(NSRange(location: i, length: 0)) }
    }
    let menu = super.menu(for: event) ?? NSMenu()
    if readOnlySide { return menu }
    let item = NSMenuItem(title: "Añadir nota…", action: #selector(addNoteFromMenu(_:)), keyEquivalent: "n")
    item.keyEquivalentModifierMask = [.command, .option]
    item.target = self
    menu.insertItem(item, at: 0)
    let usesItem = NSMenuItem(title: "Buscar usos", action: #selector(findUsagesFromMenu(_:)), keyEquivalent: "")
    usesItem.target = self
    menu.insertItem(usesItem, at: 1)
    menu.insertItem(.separator(), at: 2)
    return menu
  }


  /// Muestra una coincidencia de búsqueda sin desplazar en horizontal salvo que no quepa desde la columna 0.
  func revealMatch(_ range: NSRange) {
    guard let lm = layoutManager, let tc = textContainer, let clip = enclosingScrollView?.contentView else {
      scrollRangeToVisible(range); return
    }
    let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    var r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
    r.origin.x += textContainerOrigin.x
    r.origin.y += textContainerOrigin.y
    let b = clip.bounds
    let x: CGFloat = r.maxX + 8 <= b.width + leftEdge ? leftEdge : r.maxX + 40 - b.width
    let y = (r.minY >= b.minY && r.maxY <= b.maxY) ? b.minY : max(0, r.minY - b.height / 3)
    scroll(NSPoint(x: x, y: y))
    enclosingScrollView?.reflectScrolledClipView(clip)
    showFindIndicator(for: range)
  }

  func reveal(line: Int) {
    guard lines.indices.contains(line), lineStarts.indices.contains(line) else { return }
    unfold(line: line)
    let start = lineStarts[line]
    let length = (lines[line].text as NSString).length
    let range = NSRange(location: start, length: length)
    guard let lm = layoutManager, let tc = textContainer else { return }
    let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    var r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
    r.origin.y += textContainerOrigin.y
    // Línea objetivo a un tercio de la altura visible, como al navegar en el IDE; siempre desde la columna 0.
    let bounds = enclosingScrollView?.contentView.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    scroll(NSPoint(x: leftEdge, y: max(0, r.minY - bounds.height / 3)))
    enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
    // El indicador hace scroll hasta ver todo su rango: se limita al texto de la línea que ya cabe
    // en pantalla (sin sangría) para que no desplace la vista en horizontal.
    let text = lines[line].text as NSString
    let indent = text.rangeOfCharacter(from: CharacterSet.whitespaces.inverted).location
    guard indent != NSNotFound else { return }
    let fits = lm.glyphRange(
      forBoundingRect: NSRect(x: 0, y: r.minY - textContainerOrigin.y, width: max(bounds.width + leftEdge - textContainerOrigin.x - 8, 1), height: max(r.height, 1)),
      in: tc)
    let visibleChars = lm.characterRange(forGlyphRange: fits, actualGlyphRange: nil)
    let end = min(start + length, NSMaxRange(visibleChars))
    if end > start + indent { showFindIndicator(for: NSRange(location: start + indent, length: end - start - indent)) }
  }
}

/// Margen fijo a la izquierda, fuera del área desplazable: ni el texto ni los fondos del diff lo tapan.
final class CodeGutterView: NSRulerView {
  init(scrollView: NSScrollView, textView: CodeNSTextView) {
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = CodeNSTextView.gutterWidth
    reservedThicknessForMarkers = 0
    reservedThicknessForAccessoryView = 0
    // Desde macOS 14 las vistas no recortan por defecto: sin esto el margen pinta encima del código.
    clipsToBounds = true
  }

  required init(coder: NSCoder) { fatalError() }

  private var codeView: CodeNSTextView? { clientView as? CodeNSTextView }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    codeView?.drawGutter(in: self, rect: rect)
  }

  override func mouseDown(with event: NSEvent) {
    guard let tv = codeView else { return }
    tv.gutterClick(x: convert(event.locationInWindow, from: nil).x, y: tv.convert(event.locationInWindow, from: nil).y)
  }
}

/// Visor + franja de marcas a la derecha (cambios, notas y coincidencias).
final class CodeContainerView: NSView {
  let scrollView: NSScrollView
  let textView: CodeNSTextView
  let strip: ScrollMarkStrip

  init(scrollView: NSScrollView, textView: CodeNSTextView) {
    self.scrollView = scrollView
    self.textView = textView
    strip = ScrollMarkStrip(textView: textView)
    super.init(frame: .zero)
    addSubview(scrollView)
    addSubview(strip)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let w = ScrollMarkStrip.width
    scrollView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - w), height: bounds.height)
    strip.frame = NSRect(x: bounds.width - w, y: 0, width: w, height: bounds.height)
  }
}

/// Marcas proporcionales a la altura del fichero; un clic salta a la línea.
final class ScrollMarkStrip: NSView {
  static let width: CGFloat = 12
  weak var textView: CodeNSTextView?
  var theme = CodeTheme.light { didSet { needsDisplay = true } }

  init(textView: CodeNSTextView) {
    self.textView = textView
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private func y(_ line: Int, count: Int) -> CGFloat { (CGFloat(line) + 0.5) / CGFloat(max(count, 1)) * bounds.height }

  override func draw(_ dirtyRect: NSRect) {
    theme.background.setFill()
    bounds.fill()
    theme.gutterText.withAlphaComponent(0.25).setFill()
    NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    guard let tv = textView, !tv.lines.isEmpty else { return }
    let n = tv.lines.count
    func mark(_ line: Int, lane: Int, _ color: NSColor) {
      color.setFill()
      NSRect(x: 2 + CGFloat(lane) * 3.5, y: y(line, count: n) - 1.5, width: 3, height: 3).fill()
    }
    for (i, l) in tv.lines.enumerated() {
      switch l.kind {
      case .added: mark(i, lane: 0, theme.addedBar)
      case .removed: mark(i, lane: 0, theme.removedBar)
      default: break
      }
      if let num = l.newNumber, tv.noteSpans.contains(where: { !$0.outdated && $0.start <= num && num <= $0.end }) {
        mark(i, lane: 1, .systemBlue)
      }
    }
    for r in tv.findMatches { mark(tv.lineIndex(at: r.location), lane: 2, theme.findCurrent) }
  }

  override func mouseDown(with event: NSEvent) {
    guard let tv = textView, !tv.lines.isEmpty else { return }
    let p = convert(event.locationInWindow, from: nil)
    let line = min(tv.lines.count - 1, max(0, Int(p.y / max(bounds.height, 1) * CGFloat(tv.lines.count))))
    guard tv.lines[line].kind != .separator else { return }
    tv.reveal(line: line)
  }
}

/// Une los scroll verticales de dos paneles; el horizontal es independiente.
final class ScrollSync {
  private var views: [Weak] = []
  private var syncing = false

  private struct Weak { weak var scrollView: NSScrollView? }

  func register(_ scrollView: NSScrollView) {
    views.removeAll { $0.scrollView == nil }
    views.append(Weak(scrollView: scrollView))
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
  }

  @objc private func boundsChanged(_ note: Notification) {
    guard !syncing, let clip = note.object as? NSClipView else { return }
    syncing = true
    defer { syncing = false }
    for case let other? in views.map(\.scrollView) where other.contentView !== clip {
      var origin = other.contentView.bounds.origin
      guard origin.y != clip.bounds.origin.y else { continue }
      origin.y = clip.bounds.origin.y
      other.contentView.scroll(to: origin)
      other.reflectScrolledClipView(other.contentView)
    }
  }
}

extension CodeNSTextView: NSLayoutManagerDelegate {
  /// Los caracteres plegados no generan glifos: el texto sigue en el almacén pero no ocupa espacio.
  func layoutManager(
    _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>,
    font aFont: NSFont, forGlyphRange glyphRange: NSRange
  ) -> Int {
    guard !hiddenRanges.isEmpty else { return 0 }
    var changed = false
    var out = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
    for i in 0..<glyphRange.length where isHidden(charIndexes[i]) {
      out[i] = .null
      changed = true
    }
    guard changed else { return 0 }
    layoutManager.setGlyphs(glyphs, properties: out, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
    return glyphRange.length
  }
}
