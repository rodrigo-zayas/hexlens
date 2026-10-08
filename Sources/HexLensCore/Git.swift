import Foundation

public struct FileChange: Hashable, Sendable {
  public var path: String
  public var oldPath: String?
  public var status: ChangeStatus
  public var additions: Int
  public var deletions: Int
}

public struct GitRepo: Sendable, Hashable {
  public let root: URL

  public init(at url: URL) throws {
    let top = try Shell.run("git", ["rev-parse", "--show-toplevel"], cwd: url)
    root = URL(fileURLWithPath: top.trimmed)
  }

  public var name: String { root.lastPathComponent }

  @discardableResult
  public func git(_ args: [String]) throws -> String {
    try Shell.run("git", args, cwd: root)
  }

  public func commit(_ ref: String) throws -> String {
    try git(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"]).trimmed
  }

  public func mergeBase(_ a: String, _ b: String) throws -> String {
    try git(["merge-base", a, b]).trimmed
  }

  public func changes(from base: String, to head: String) throws -> [FileChange] {
    let numstat = try git(["diff", "--no-color", "-M", "--numstat", "-z", base, head])
    var counts: [String: (Int, Int)] = [:]
    var tokens = numstat.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
    while let record = tokens.popFirst(), !record.isEmpty {
      let parts = record.split(separator: "\t", omittingEmptySubsequences: false)
      guard parts.count >= 3 else { continue }
      var path = String(parts[2])
      // Renombrado: "a\td\t\0viejo\0nuevo\0"
      if path.isEmpty {
        _ = tokens.popFirst()
        path = tokens.popFirst() ?? ""
      }
      counts[path] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
    }

    let nameStatus = try git(["diff", "--no-color", "-M", "--name-status", "-z", base, head])
    var result: [FileChange] = []
    var t = nameStatus.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
    while let code = t.popFirst(), let letter = code.first {
      if letter == "R" || letter == "C" {
        let old = t.popFirst() ?? ""
        let new = t.popFirst() ?? ""
        let c = counts[new] ?? (0, 0)
        result.append(FileChange(
          path: new, oldPath: old, status: letter == "R" ? .renamed : .added,
          additions: c.0, deletions: c.1))
      } else {
        let path = t.popFirst() ?? ""
        let c = counts[path] ?? (0, 0)
        let status: ChangeStatus = letter == "A" ? .added : letter == "D" ? .deleted : .modified
        result.append(FileChange(path: path, oldPath: nil, status: status, additions: c.0, deletions: c.1))
      }
    }
    return result
  }

  /// Diff unificado de toda la PR. Las cabeceras de hunk usan el driver `java` de git.
  public func unifiedDiff(from base: String, to head: String) throws -> String {
    let attributes = FileManager.default.temporaryDirectory.appendingPathComponent("hexlens.gitattributes")
    try? "*.java diff=java\n".write(to: attributes, atomically: true, encoding: .utf8)
    return try git([
      "-c", "core.attributesFile=\(attributes.path)",
      "diff", "--no-color", "--no-ext-diff", "-M", "-U3", base, head,
    ])
  }

  public func file(at rev: String, path: String) -> String? {
    try? git(["show", "\(rev):\(path)"])
  }

  /// Lee muchos blobs `rev:path` con un solo proceso (`git cat-file --batch`).
  public func files(_ specs: [(rev: String, path: String)]) -> [String?] {
    guard !specs.isEmpty else { return [] }
    let input = specs.map { "\($0.rev):\($0.path)\n" }.joined()
    guard let data = try? Shell.runData("git", ["cat-file", "--batch"], cwd: root, input: Data(input.utf8)) else {
      return specs.map { file(at: $0.rev, path: $0.path) }
    }
    var result: [String?] = []
    var i = data.startIndex
    while result.count < specs.count, i < data.endIndex {
      guard let nl = data[i...].firstIndex(of: 10) else { break }
      let header = String(decoding: data[i..<nl], as: UTF8.self)
      i = data.index(after: nl)
      let parts = header.split(separator: " ")
      guard parts.count == 3, let size = Int(parts[2]) else {
        result.append(nil)  // "<spec> missing"
        continue
      }
      let end = data.index(i, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
      result.append(String(decoding: data[i..<end], as: UTF8.self))
      i = min(data.index(after: end), data.endIndex)
    }
    while result.count < specs.count { result.append(nil) }
    return result
  }

  public func files(at rev: String) throws -> [String] {
    try git(["ls-tree", "-r", "--name-only", "-z", rev])
      .split(separator: "\0").map(String.init)
  }

  /// Ficheros Java en `rev` que mencionan `word` como palabra completa.
  public func filesMentioning(_ word: String, at rev: String) -> [String] {
    guard let out = try? git(["grep", "-l", "-w", "-F", "-e", word, rev, "--", "*.java"]) else { return [] }
    return out.split(separator: "\n").map { line in
      let s = String(line)
      return s.hasPrefix(rev + ":") ? String(s.dropFirst(rev.count + 1)) : s
    }
  }

  /// Usos de `word` (palabra completa) en los .java de `rev`.
  public func usages(of word: String, at rev: String) -> [UsageHit] {
    guard let out = try? git(["grep", "-n", "-w", "-F", "-e", word, rev, "--", "*.java"]) else { return [] }
    return UsageSearch.parse(out, rev: rev)
  }

  public func branches() -> [String] {
    let out = (try? git(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"])) ?? ""
    return out.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
  }
}
