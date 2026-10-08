import Foundation
import HexLensCore

/// Ejecuta Claude Code en segundo plano (`claude -p`, solo lectura de git) y va contando lo que hace.
final class ClaudeAgent: @unchecked Sendable {
  private var process: Process?
  private var buffer = Data()
  private var result: [String: Any]?

  func start(
    prompt: String, schema: String, model: String, in directory: URL,
    onEvent: @escaping @Sendable (String) -> Void,
    onModel: @escaping @Sendable (String) -> Void = { _ in },
    onFinish: @escaping @Sendable (Result<[String: Any], Error>) -> Void
  ) {
    let p = Process()
    // Vía el shell de login del usuario: mismo entorno (PATH, proxy, certificados) que su terminal.
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = [
      "-lc", "exec claude \"$@\"", "hexlens",
      "-p", "--output-format", "stream-json", "--verbose",
      "--json-schema", schema,
      "--allowedTools", "Bash(git show:*)", "Bash(git diff:*)", "Bash(git grep:*)", "Bash(git log:*)",
    ] + (model.isEmpty ? [] : ["--model", model])
    p.currentDirectoryURL = directory
    var env = Shell.cleanEnvironment()
    env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    p.environment = env

    let out = Pipe(), err = Pipe(), input = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = input
    out.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      guard !data.isEmpty, let self else { return }
      self.consume(data, onEvent: onEvent, onModel: onModel)
    }
    p.terminationHandler = { [weak self] proc in
      out.fileHandleForReading.readabilityHandler = nil
      let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      guard let self else { return }
      self.consume(out.fileHandleForReading.readDataToEndOfFile(), onEvent: onEvent, onModel: onModel)
      if let r = self.result, (r["is_error"] as? Bool) != true {
        onFinish(.success(r))
      } else {
        let message = (self.result?["result"] as? String) ?? stderr
        onFinish(.failure(ShellError(command: "claude", status: proc.terminationStatus, stderr: message)))
      }
    }
    do {
      try p.run()
      process = p
      input.fileHandleForWriting.write(Data(prompt.utf8))
      try? input.fileHandleForWriting.close()
    } catch {
      onFinish(.failure(error))
    }
  }

  func cancel() { process?.terminate() }

  private func consume(_ data: Data, onEvent: (String) -> Void, onModel: (String) -> Void) {
    buffer.append(data)
    while let nl = buffer.firstIndex(of: 10) {
      let line = buffer[buffer.startIndex..<nl]
      buffer = Data(buffer[buffer.index(after: nl)...])
      guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
      switch obj["type"] as? String {
      case "system":
        // Evento init: modelo real tras resolver alias y configuración.
        if let model = obj["model"] as? String { onModel(model) }
      case "assistant":
        let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        for item in content {
          if item["type"] as? String == "tool_use" {
            let input = item["input"] as? [String: Any]
            let detail = (input?["command"] as? String) ?? (input?["description"] as? String) ?? ""
            onEvent("\(item["name"] as? String ?? "herramienta"): \(detail.prefix(140))")
          } else if item["type"] as? String == "text", let text = item["text"] as? String, !text.isEmpty {
            onEvent(String(text.prefix(140)))
          }
        }
      case "result":
        result = obj
      default:
        break
      }
    }
  }
}
