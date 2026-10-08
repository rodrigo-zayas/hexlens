import CryptoKit
import Foundation

/// Nota del revisor sobre un rango de líneas del fichero nuevo (1-based, ambos incluidos).
public struct ReviewNote: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var path: String
  public var startLine: Int
  public var endLine: Int
  /// Texto de esas líneas al crear la nota; sirve para reanclarla.
  public var snippet: String
  public var body: String
  public var createdAt: Date
  public var updatedAt: Date
  public var anchorSHA: String
  public var outdated: Bool
  public var sentAt: Date?

  public init(
    id: UUID = UUID(), path: String, startLine: Int, endLine: Int, snippet: String, body: String,
    createdAt: Date = Date(), updatedAt: Date? = nil, anchorSHA: String, outdated: Bool = false, sentAt: Date? = nil
  ) {
    self.id = id
    self.path = path
    self.startLine = startLine
    self.endLine = endLine
    self.snippet = snippet
    self.body = body
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
    self.anchorSHA = anchorSHA
    self.outdated = outdated
    self.sentAt = sentAt
  }
}

/// Reancla las notas contra el texto actual de cada fichero. `files` mapea ruta → texto en `head`.
/// Sin cambios si el fragmento sigue en sus líneas; se mueve a la ocurrencia más cercana si aparece
/// en otro sitio; si no aparece (o el fichero no existe) queda marcada como desactualizada.
public func reanchor(_ notes: [ReviewNote], files: [String: String], head: String) -> [ReviewNote] {
  var cache: [String: [Substring]] = [:]
  return notes.map { note in
    var n = note
    guard let text = files[note.path] else { n.outdated = true; return n }
    let lines = cache[note.path] ?? text.split(separator: "\n", omittingEmptySubsequences: false)
    cache[note.path] = lines
    let snippet = note.snippet.split(separator: "\n", omittingEmptySubsequences: false)
    let count = snippet.count
    guard !note.snippet.isEmpty, count <= lines.count else { n.outdated = true; return n }

    func matches(at start: Int) -> Bool {
      guard start >= 0, start + count <= lines.count else { return false }
      return (0..<count).allSatisfy { lines[start + $0] == snippet[$0] }
    }
    let current = note.startLine - 1
    if matches(at: current) {
      n.outdated = false
      n.anchorSHA = head
      return n
    }
    var best: Int?
    for start in 0...(lines.count - count) where matches(at: start) {
      if best.map({ abs(start - current) < abs($0 - current) }) ?? true { best = start }
    }
    if let best {
      n.startLine = best + 1
      n.endLine = best + count
      n.outdated = false
      n.anchorSHA = head
    } else {
      n.outdated = true
    }
    return n
  }
}

/// Guarda las notas de una PR (o de un rango base..head) en JSON, por repo y PR, no por commit.
public struct ReviewNoteStore: Sendable {
  public let url: URL

  public static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("HexLens/notes", isDirectory: true)
  }

  public init(repoRoot: String, key: String, root: URL = ReviewNoteStore.defaultRoot) {
    let hash = Insecure.SHA1.hash(data: Data(repoRoot.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
    let safe = key.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? String($0) : "_" }.joined()
    url = root.appendingPathComponent(hash, isDirectory: true).appendingPathComponent("\(safe).json")
  }

  public func load() -> [ReviewNote] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([ReviewNote].self, from: data)) ?? []
  }

  public func save(_ notes: [ReviewNote]) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(notes) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
  }
}
