import Foundation

/// Sesión de Claude Code (la CLI y la pestaña Code de Claude Desktop comparten registro en `~/.claude/projects`).
public struct ClaudeSession: Identifiable, Hashable, Sendable {
  public let id: String
  public let cwd: String
  public let branch: String
  public let lastActivity: Date
  public let title: String
}

public enum ClaudeSessions {
  public static var defaultRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
  }

  /// Sesiones cuyo cwd es uno de `cwds` y cuya rama es `branch`, la más reciente primero.
  public static func find(root: URL = defaultRoot, cwds: [String], branch: String) -> [ClaudeSession] {
    let fm = FileManager.default
    var found: [ClaudeSession] = []
    for cwd in Set(cwds) {
      let dir = root.appendingPathComponent(encode(cwd), isDirectory: true)
      guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
      for file in files where file.pathExtension == "jsonl" {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let s = read(file, modified: modified), s.cwd == cwd, s.branch == branch { found.append(s) }
      }
    }
    return found.sorted { $0.lastActivity > $1.lastActivity }
  }

  /// Claude sustituye `/` y `.` por `-` en el nombre de carpeta.
  static func encode(_ path: String) -> String {
    String(path.map { $0 == "/" || $0 == "." ? "-" : $0 })
  }

  private static func read(_ file: URL, modified: Date) -> ClaudeSession? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
    var cwd: String?, branch: String?, title: String?
    var last: Date?
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    func scan(_ obj: [String: Any]) {
      if cwd == nil { cwd = obj["cwd"] as? String }
      if branch == nil { branch = obj["gitBranch"] as? String }
      if title == nil, obj["type"] as? String == "user", let t = userText(obj) { title = t }
    }
    var lines = head.split(separator: UInt8(ascii: "\n")).prefix(200).map { Data($0) }
    // Si la lectura cortó la última línea, no es JSON válido y se descarta sola.
    for line in lines {
      if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { scan(obj) }
    }
    lines = []

    if let size = try? handle.seekToEnd(), size > 0 {
      let from = size > 64 * 1024 ? size - 64 * 1024 : 0
      try? handle.seek(toOffset: from)
      let tail = (try? handle.readToEnd()) ?? Data()
      for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
        if let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
           let ts = obj["timestamp"] as? String, let d = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) {
          last = d
          break
        }
      }
    }
    guard let cwd, let branch else { return nil }
    return ClaudeSession(
      id: file.deletingPathExtension().lastPathComponent, cwd: cwd, branch: branch,
      lastActivity: last ?? modified, title: title ?? "(sin título)")
  }

  private static func userText(_ obj: [String: Any]) -> String? {
    guard let message = obj["message"] as? [String: Any] else { return nil }
    var text: String?
    if let s = message["content"] as? String {
      text = s
    } else if let parts = message["content"] as? [[String: Any]] {
      text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
    }
    guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") else { return nil }
    let oneLine = t.replacingOccurrences(of: "\n", with: " ")
    return oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
  }
}

public struct Worktree: Hashable, Sendable {
  public let path: String
  public let branch: String?
}

extension GitRepo {
  /// Todos los worktrees del repo con su rama (`git worktree list --porcelain`).
  public func worktrees() -> [Worktree] {
    guard let out = try? git(["worktree", "list", "--porcelain"]) else { return [] }
    var result: [Worktree] = []
    var path: String?, branch: String?
    func flush() { if let path { result.append(Worktree(path: path, branch: branch)) }; path = nil; branch = nil }
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("worktree ") { flush(); path = String(line.dropFirst(9)) }
      else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
    }
    flush()
    return result
  }
}
