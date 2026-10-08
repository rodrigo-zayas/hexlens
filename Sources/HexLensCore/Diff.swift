import Foundation

public struct DiffLine: Identifiable, Hashable, Sendable {
  public enum Kind: Hashable, Sendable { case context, added, removed, hunk }
  public let id: Int
  public let kind: Kind
  public let text: String
  public let oldNumber: Int?
  public let newNumber: Int?
}

public struct FileDiff: Hashable, Sendable {
  public var oldPath: String?
  public var newPath: String?
  public var isBinary = false
  public var lines: [DiffLine] = []

  public var addedLineNumbers: Set<Int> { Set(lines.filter { $0.kind == .added }.compactMap(\.newNumber)) }
  public var removedLineNumbers: Set<Int> { Set(lines.filter { $0.kind == .removed }.compactMap(\.oldNumber)) }
  public var addedText: Set<String> { Set(lines.filter { $0.kind == .added }.map { $0.text.trimmed }) }
}

public enum DiffParser {
  /// Parte el diff unificado de la PR en un diff por fichero, indexado por ruta nueva
  /// (o la vieja si el fichero se borra).
  public static func parse(_ text: String) -> [String: FileDiff] {
    var result: [String: FileDiff] = [:]
    var current: FileDiff?
    var oldNo = 0, newNo = 0, seq = 0

    func flush() {
      if let c = current, let key = c.newPath ?? c.oldPath { result[key] = c }
      current = nil
    }

    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(raw)
      if line.hasPrefix("diff --git ") {
        flush()
        current = FileDiff()
        // Valor provisional por si no hay líneas ---/+++ (renombrado puro, binario).
        if let r = line.range(of: " b/", options: .backwards) {
          current?.newPath = String(line[r.upperBound...])
          current?.oldPath = String(line.dropFirst("diff --git a/".count).prefix(upTo: r.lowerBound))
        }
        continue
      }
      guard current != nil else { continue }
      if line.hasPrefix("--- ") && current!.lines.isEmpty {
        current!.oldPath = line == "--- /dev/null" ? nil : String(line.dropFirst(6))
      } else if line.hasPrefix("+++ ") && current!.lines.isEmpty {
        current!.newPath = line == "+++ /dev/null" ? nil : String(line.dropFirst(6))
      } else if line.hasPrefix("Binary files") {
        current!.isBinary = true
      } else if line.hasPrefix("@@") {
        let nums = Self.hunkNumbers(line)
        oldNo = nums.0
        newNo = nums.1
        seq += 1
        current!.lines.append(DiffLine(id: seq, kind: .hunk, text: line, oldNumber: nil, newNumber: nil))
      } else if current!.lines.isEmpty {
        continue  // cabeceras: index, mode, similarity, rename from/to
      } else if line.hasPrefix("+") {
        seq += 1
        current!.lines.append(DiffLine(id: seq, kind: .added, text: String(line.dropFirst()), oldNumber: nil, newNumber: newNo))
        newNo += 1
      } else if line.hasPrefix("-") {
        seq += 1
        current!.lines.append(DiffLine(id: seq, kind: .removed, text: String(line.dropFirst()), oldNumber: oldNo, newNumber: nil))
        oldNo += 1
      } else if line.hasPrefix(" ") {
        seq += 1
        current!.lines.append(DiffLine(id: seq, kind: .context, text: String(line.dropFirst()), oldNumber: oldNo, newNumber: newNo))
        oldNo += 1
        newNo += 1
      }
    }
    flush()
    return result
  }

  static func hunkNumbers(_ header: String) -> (Int, Int) {
    // @@ -12,7 +12,9 @@ contexto
    let parts = header.split(separator: " ")
    func start(_ s: Substring?) -> Int {
      guard let s else { return 0 }
      return Int(s.dropFirst().split(separator: ",").first ?? "0") ?? 0
    }
    return (start(parts.count > 1 ? parts[1] : nil), start(parts.count > 2 ? parts[2] : nil))
  }
}
