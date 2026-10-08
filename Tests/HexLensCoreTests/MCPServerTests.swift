import XCTest

@testable import HexLensCore

final class MCPServerTests: XCTestCase {
  private var root: URL!
  private let repo = "/tmp/hexlens-mcp-test-no-git"

  override func setUp() {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  override func tearDown() { try? FileManager.default.removeItem(at: root) }

  private func call(_ server: MCPServer, _ name: String, _ args: [String: Any]) -> String {
    let r = server.handle(["id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])
    let content = (r?["result"] as? [String: Any])?["content"] as? [[String: Any]]
    return content?.first?["text"] as? String ?? ""
  }

  func testInitializeAndList() {
    let s = MCPServer(storeRoot: root)
    let r = s.handle(["id": 1, "method": "initialize", "params": ["protocolVersion": "2024-11-05"]])
    XCTAssertEqual((r?["result"] as? [String: Any])?["protocolVersion"] as? String, "2024-11-05")
    XCTAssertNil(s.handle(["method": "notifications/initialized"]))
    let t = s.handle(["id": 2, "method": "tools/list"])
    let tools = (t?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["list_review_notes", "mark_notes_sent"])
    let e = s.handle(["id": 3, "method": "nope"])
    XCTAssertEqual((e?["error"] as? [String: Any])?["code"] as? Int, -32601)
  }

  func testListAndMark() {
    let s = MCPServer(storeRoot: root)
    let n = ReviewNote(path: "A.java", startLine: 3, endLine: 4, snippet: "x", body: "arregla esto", anchorSHA: "h")
    ReviewNoteStore(repoRoot: repo, key: "pr7", root: root).save([n])

    let listed = call(s, "list_review_notes", ["repo": repo])
    XCTAssertTrue(listed.contains("A.java:3-4"))
    XCTAssertTrue(listed.contains(n.id.uuidString))
    XCTAssertTrue(call(s, "list_review_notes", ["repo": repo, "pr": "8"]).contains("No hay notas"))

    XCTAssertTrue(call(s, "mark_notes_sent", ["repo": repo, "ids": [n.id.uuidString]]).contains("Marcadas 1"))
    XCTAssertNotNil(ReviewNoteStore(repoRoot: repo, key: "pr7", root: root).load()[0].sentAt)
    XCTAssertTrue(call(s, "list_review_notes", ["repo": repo]).contains("No hay notas"))
    XCTAssertTrue(call(s, "list_review_notes", ["repo": repo, "include_sent": true]).contains("(enviada)"))
  }
}
