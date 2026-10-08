import Foundation

/// Búsqueda de texto en el visor: rangos UTF-16 (los de NSString/NSTextView).
public enum TextSearch {
  public static func matches(of query: String, in text: String, caseSensitive: Bool, wholeWord: Bool) -> [NSRange] {
    guard !query.isEmpty, !text.isEmpty else { return [] }
    var pattern = NSRegularExpression.escapedPattern(for: query)
    if wholeWord { pattern = "(?<![\\p{L}\\p{N}_])" + pattern + "(?![\\p{L}\\p{N}_])" }
    let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
  }
}
