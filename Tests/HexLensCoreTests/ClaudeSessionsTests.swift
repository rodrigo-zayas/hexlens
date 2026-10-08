import XCTest

@testable import HexLensCore

final class ClaudeSessionsTests: XCTestCase {
  private func write(_ root: URL, cwd: String, id: String, branch: String, lines: [String]) throws {
    let dir = root.appendingPathComponent(ClaudeSessions.encode(cwd))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
  }

  private func line(_ cwd: String, _ branch: String, _ ts: String, user: String? = nil) -> String {
    let msg = user.map { ",\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\($0)\"}" } ?? ",\"type\":\"assistant\""
    return "{\"sessionId\":\"x\",\"cwd\":\"\(cwd)\",\"gitBranch\":\"\(branch)\",\"timestamp\":\"\(ts)\"\(msg)}"
  }

  func testFindsByCwdAndBranchSortedByActivity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let a = "/tmp/repo.x", b = "/tmp/wt"
    try write(root, cwd: a, id: "old", branch: "feat", lines: [line(a, "feat", "2026-01-01T10:00:00.000Z", user: "Primera tarea"), line(a, "feat", "2026-01-01T11:00:00.000Z")])
    try write(root, cwd: b, id: "new", branch: "feat", lines: [line(b, "feat", "2026-02-01T10:00:00.000Z", user: "Otra"), line(b, "feat", "2026-02-01T12:00:00.000Z")])
    try write(root, cwd: a, id: "other", branch: "main", lines: [line(a, "main", "2026-03-01T10:00:00.000Z", user: "x")])
    let r = ClaudeSessions.find(root: root, cwds: [a, b], branch: "feat")
    XCTAssertEqual(r.map(\.id), ["new", "old"])
    XCTAssertEqual(r[1].title, "Primera tarea")
    XCTAssertEqual(r[1].lastActivity, ISO8601DateFormatter().date(from: "2026-01-01T11:00:00Z"))
  }
}
