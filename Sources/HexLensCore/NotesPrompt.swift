import Foundation

/// Prompt en español con las notas de revisión para que Claude aplique los cambios.
public enum NotesPrompt {
  public static func build(notes: [ReviewNote], pr: String, branch: String, repo: String) -> String {
    var out = """
      Estoy revisando \(pr) (rama `\(branch)`, repo `\(repo)`) y he dejado estas notas sobre el código. \
      Aplica los cambios que piden, uno por nota, y dime qué has hecho en cada una.

      """
    if notes.contains(where: \.outdated) {
      out += "\nAviso: las notas marcadas como «desactualizada» ya no coinciden con su código; localiza el fragmento por su contenido.\n"
    }
    for (i, n) in notes.enumerated() {
      let range = n.startLine == n.endLine ? "\(n.startLine)" : "\(n.startLine)-\(n.endLine)"
      out += "\n## \(i + 1). `\(n.path):\(range)`\(n.outdated ? " (desactualizada)" : "")\n\n"
      out += "```java\n\(n.snippet)\n```\n\n\(n.body)\n"
    }
    return out
  }
}
