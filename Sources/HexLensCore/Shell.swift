import Foundation

public struct ShellError: LocalizedError {
  public let command: String
  public let status: Int32
  public let stderr: String

  public init(command: String, status: Int32, stderr: String) {
    self.command = command
    self.status = status
    self.stderr = stderr
  }

  public var errorDescription: String? {
    "`\(command)` terminó con \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
  }
}

public enum Shell {
  public static func run(_ tool: String, _ args: [String], cwd: URL? = nil) throws -> String {
    String(decoding: try runData(tool, args, cwd: cwd), as: UTF8.self)
  }

  public static func runData(_ tool: String, _ args: [String], cwd: URL? = nil, input: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + args
    process.currentDirectoryURL = cwd

    var env = cleanEnvironment()
    // Una app lanzada desde Finder no hereda el PATH del shell (gh vive en Homebrew).
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GH_PROMPT_DISABLED"] = "1"
    process.environment = env

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let stdin = input.map { _ in Pipe() }
    if let stdin { process.standardInput = stdin } else { process.standardInput = FileHandle.nullDevice }
    try process.run()
    if let stdin, let input {
      DispatchQueue.global().async {
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
      }
    }

    // stderr en paralelo para que ninguna tubería se llene y bloquee al proceso.
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      errData = err.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw ShellError(
        command: ([tool] + args.prefix(4)).joined(separator: " "),
        status: process.terminationStatus,
        stderr: String(decoding: errData, as: UTF8.self))
    }
    return outData
  }
}

extension Shell {
  /// Entorno sin rastro de una sesión de Claude Code anfitriona (si HexLens se lanzó desde ella,
  /// un `claude` hijo usaría su proxy y su sesión en vez de la del usuario).
  public static func cleanEnvironment() -> [String: String] {
    ProcessInfo.processInfo.environment.filter { key, _ in
      !(key.hasPrefix("CLAUDE") || key == "ANTHROPIC_BASE_URL" || key.hasPrefix("CLAUDE_CODE"))
    }
  }
}

extension StringProtocol {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
