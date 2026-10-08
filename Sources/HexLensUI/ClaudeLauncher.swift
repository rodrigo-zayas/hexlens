import AppKit
import Foundation

/// Abre Terminal con una sesión interactiva de `claude` en el repo y el prompt ya escrito,
/// para poder seguir preguntando.
enum ClaudeLauncher {
  static func open(prompt: String, model: String, in directory: URL) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexlens-claude-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let promptFile = dir.appendingPathComponent("prompt.md")
    try prompt.write(to: promptFile, atomically: true, encoding: .utf8)

    try run(in: dir, name: "explicar", body: """
      cd \(quote(directory.path))
      clear
      exec claude \(model.isEmpty ? "" : "--model \(quote(model)) ")"$(cat \(quote(promptFile.path)))"
      """)
  }

  /// Inicio de sesión de la CLI (OAuth en el navegador). Solo hace falta una vez.
  static func login() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hexlens-login")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try run(in: dir, name: "login", body: """
      clear
      echo "HexLens necesita que la CLI de Claude Code tenga sesión propia."
      echo
      claude auth login && echo && echo "Listo. Puedes volver a HexLens y cerrar esta ventana."
      """)
  }

  private static func run(in dir: URL, name: String, body: String) throws {
    let script = dir.appendingPathComponent("\(name).command")
    // Sin rastro de una sesión de Claude anfitriona: la CLI debe usar su propia sesión.
    try """
      #!/bin/zsh -l
      unset ANTHROPIC_BASE_URL ${(k)parameters[(I)CLAUDE*]}
      \(body)
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
  }

  private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
