import Foundation

/// Fichero leído y analizado en una revisión concreta.
public struct ParsedFile: Sendable {
  public let path: String
  public let text: String
  public let facts: SourceFacts
  public let tokens: [Token]
  public let semantics: JavaSemantics

  public func member(named name: String) -> Member? {
    let methods = facts.members.filter { !$0.key.hasPrefix("type:") && !$0.key.hasPrefix("field:") }
    return methods.first { $0.name == name }
      // Los casos de uso de AMIGA se invocan con execute() y se implementan en doOperation().
      ?? (name == "execute" ? methods.first { $0.name == "doOperation" } : nil)
  }
}

/// Caché de ficheros por revisión. Se usa desde hilos de fondo.
public final class SourceStore: @unchecked Sendable {
  private let repo: GitRepo
  private var texts: [String: String?] = [:]
  private var parsed: [String: ParsedFile] = [:]
  private let lock = NSLock()

  init(repo: GitRepo) { self.repo = repo }

  func prime(rev: String, path: String, text: String?) {
    lock.withLock { texts["\(rev):\(path)"] = .some(text) }
  }

  public func text(_ path: String, at rev: String) -> String? {
    let key = "\(rev):\(path)"
    if let cached = lock.withLock({ texts[key] }) { return cached }
    let t = repo.file(at: rev, path: path)
    lock.withLock { texts[key] = .some(t) }
    return t
  }

  public func parsed(_ path: String, at rev: String) -> ParsedFile? {
    let key = "\(rev):\(path)"
    if let p = lock.withLock({ parsed[key] }) { return p }
    guard let analyzer = Analyzers.for(path), let text = text(path, at: rev) else { return nil }
    // El lexer es de Java: otros lenguajes se quedan sin tokens ni semántica.
    let tokens = analyzer.language == "java" ? JavaLexer.tokens(text) : []
    let p = ParsedFile(
      path: path, text: text, facts: analyzer.analyze(path: path, source: text), tokens: tokens,
      semantics: JavaSemantics.analyze(text: text, tokens: tokens))
    lock.withLock { parsed[key] = p }
    return p
  }

  /// Clases que implementan o extienden `typeName` en `rev` (git grep, cacheado).
  public func implementations(of typeName: String, at rev: String) -> [String] {
    let key = "impl:\(rev):\(typeName)"
    if let cached = lock.withLock({ texts[key] }) { return (cached ?? "").split(separator: "\n").map(String.init) }
    let out = (try? repo.git(["grep", "-l", "-E", "(implements|extends)[^{]*[^A-Za-z0-9_]\(typeName)([^A-Za-z0-9_]|$)", rev, "--", "*.java"])) ?? ""
    let paths = out.split(separator: "\n").map { line -> String in
      let s = String(line)
      return s.hasPrefix(rev + ":") ? String(s.dropFirst(rev.count + 1)) : s
    }.filter { !$0.contains("/src/test/") }
    lock.withLock { texts[key] = .some(paths.joined(separator: "\n")) }
    return paths
  }
}
