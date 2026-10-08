import Foundation

/// Servidor MCP (stdio, JSON-RPC 2.0 delimitado por saltos de línea) con las notas de revisión.
public struct MCPServer {
  public let storeRoot: URL

  public init(storeRoot: URL = ReviewNoteStore.defaultRoot) {
    self.storeRoot = storeRoot
  }

  /// Lee peticiones de stdin hasta EOF y escribe las respuestas en stdout.
  public func run() {
    while let line = readLine(strippingNewline: true) {
      guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      let response: [String: Any]?
      if let data = line.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        response = handle(obj)
      } else {
        response = Self.error(id: NSNull(), code: -32700, message: "Parse error")
      }
      guard let response, let out = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else { continue }
      FileHandle.standardOutput.write(out + Data("\n".utf8))
    }
  }

  public func handle(_ request: [String: Any]) -> [String: Any]? {
    let method = request["method"] as? String ?? ""
    let id = request["id"]
    let params = request["params"] as? [String: Any] ?? [:]
    guard let id else { return nil }  // notificaciones: sin respuesta

    switch method {
    case "initialize":
      return Self.result(id: id, [
        "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": "hexlens", "version": "1.0"],
      ])
    case "ping":
      return Self.result(id: id, [:])
    case "tools/list":
      return Self.result(id: id, ["tools": Self.tools])
    case "tools/call":
      let name = params["name"] as? String ?? ""
      let args = params["arguments"] as? [String: Any] ?? [:]
      switch name {
      case "list_review_notes": return Self.result(id: id, content(listNotes(args)))
      case "mark_notes_sent": return Self.result(id: id, content(markSent(args)))
      default: return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
      }
    default:
      return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
    }
  }

  // MARK: - Tools

  static let tools: [[String: Any]] = [
    [
      "name": "list_review_notes",
      "description": "Lista las notas de revisión de HexLens de un repo (todas las PRs, o solo la indicada).",
      "inputSchema": [
        "type": "object",
        "properties": [
          "repo": ["type": "string", "description": "Ruta del repo; por defecto el directorio actual"],
          "pr": ["type": "string", "description": "Número de PR (o base..head); por defecto todas"],
          "include_sent": ["type": "boolean", "description": "Incluir notas ya enviadas (por defecto false)"],
        ],
      ],
    ],
    [
      "name": "mark_notes_sent",
      "description": "Marca notas de revisión como enviadas/atendidas por sus ids.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "repo": ["type": "string", "description": "Ruta del repo; por defecto el directorio actual"],
          "ids": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["ids"],
      ],
    ],
  ]

  private func content(_ r: (text: String, isError: Bool)) -> [String: Any] {
    ["content": [["type": "text", "text": r.text]], "isError": r.isError]
  }

  /// Rutas de repo candidatas: la del toplevel (como la usa la app) y el repo principal si es un worktree.
  static func repoRoots(_ path: String) -> [String] {
    let dir = URL(fileURLWithPath: path)
    guard let top = try? Shell.run("git", ["rev-parse", "--show-toplevel"], cwd: dir).trimmed, !top.isEmpty else {
      return [path]
    }
    var roots = [top]
    if let common = try? Shell.run("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: dir).trimmed,
      common.hasSuffix("/.git")
    {
      let main = String(common.dropLast(5))
      if main != top { roots.append(main) }
    }
    return roots
  }

  /// Ficheros de notas (clave → store) de un repo.
  private func stores(repo: String) -> [(key: String, store: ReviewNoteStore)] {
    var out: [(String, ReviewNoteStore)] = []
    for root in Self.repoRoots(repo) {
      let dir = ReviewNoteStore(repoRoot: root, key: "x", root: storeRoot).url.deletingLastPathComponent()
      let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
      for f in files where f.pathExtension == "json" {
        let key = f.deletingPathExtension().lastPathComponent
        out.append((key, ReviewNoteStore(repoRoot: root, key: key, root: storeRoot)))
      }
    }
    return out.sorted { $0.0 < $1.0 }
  }

  private func repoArg(_ args: [String: Any]) -> String {
    (args["repo"] as? String) ?? FileManager.default.currentDirectoryPath
  }

  private func listNotes(_ args: [String: Any]) -> (text: String, isError: Bool) {
    let includeSent = args["include_sent"] as? Bool ?? false
    let pr = (args["pr"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let wanted = pr.map { Set([$0, "pr\($0)"]) }
    var out = ""
    for (key, store) in stores(repo: repoArg(args)) {
      if let wanted, !wanted.contains(key) { continue }
      let notes = store.load().filter { includeSent || $0.sentAt == nil }
      if notes.isEmpty { continue }
      out += "# \(key)\n"
      for n in notes {
        let range = n.startLine == n.endLine ? "\(n.startLine)" : "\(n.startLine)-\(n.endLine)"
        var flags = ""
        if n.outdated { flags += " (desactualizada)" }
        if n.sentAt != nil { flags += " (enviada)" }
        out += "\n## `\(n.path):\(range)`\(flags)\n\nid: \(n.id.uuidString)\n\n```\n\(n.snippet)\n```\n\n\(n.body)\n"
      }
      out += "\n"
    }
    return (out.isEmpty ? "No hay notas de revisión." : out, false)
  }

  private func markSent(_ args: [String: Any]) -> (text: String, isError: Bool) {
    guard let ids = args["ids"] as? [String] else { return ("Falta `ids`.", true) }
    let wanted = Set(ids.compactMap(UUID.init(uuidString:)))
    var marked = 0
    let now = Date()
    for (_, store) in stores(repo: repoArg(args)) {
      var notes = store.load()
      var changed = false
      for i in notes.indices where wanted.contains(notes[i].id) {
        notes[i].sentAt = now
        marked += 1
        changed = true
      }
      if changed { store.save(notes) }
    }
    return ("Marcadas \(marked) de \(ids.count) notas como enviadas.", false)
  }

  // MARK: - JSON-RPC

  static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "result": result]
  }

  static func error(id: Any, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
  }
}
