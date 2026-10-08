import XCTest

@testable import HexLensCore

final class ReviewNotesTests: XCTestCase {
  private func note(_ start: Int, _ end: Int, _ snippet: String, path: String = "A.java") -> ReviewNote {
    ReviewNote(path: path, startLine: start, endLine: end, snippet: snippet, body: "n", anchorSHA: "old")
  }

  func testUnchangedStaysPut() {
    let r = reanchor([note(2, 3, "b\nc")], files: ["A.java": "a\nb\nc\nd"], head: "new")
    XCTAssertEqual(r[0].startLine, 2)
    XCTAssertEqual(r[0].endLine, 3)
    XCTAssertFalse(r[0].outdated)
    XCTAssertEqual(r[0].anchorSHA, "new")
  }

  func testMovesToNewPosition() {
    let r = reanchor([note(2, 3, "b\nc")], files: ["A.java": "x\ny\nz\na\nb\nc"], head: "new")
    XCTAssertEqual([r[0].startLine, r[0].endLine], [5, 6])
    XCTAssertFalse(r[0].outdated)
  }

  func testPicksClosestOccurrence() {
    let text = "k\nx\nk\nx\nx\nx\nk"
    let r = reanchor([note(6, 6, "k")], files: ["A.java": text], head: "h")
    XCTAssertEqual(r[0].startLine, 7)
  }

  func testOutdatedWhenGoneOrMissing() {
    let r = reanchor(
      [note(1, 1, "gone"), note(1, 1, "a", path: "B.java")], files: ["A.java": "a\nb"], head: "h")
    XCTAssertTrue(r[0].outdated)
    XCTAssertEqual(r[0].startLine, 1)
    XCTAssertTrue(r[1].outdated)
  }

  func testCodableRoundTripAndStore() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ReviewNoteStore(repoRoot: "/tmp/repo", key: "feature/x..main", root: dir)
    XCTAssertTrue(store.load().isEmpty)
    var n = note(3, 4, "x\ny")
    n.sentAt = Date(timeIntervalSince1970: 1_700_000_000)
    store.save([n])
    let back = store.load()
    XCTAssertEqual(back.count, 1)
    XCTAssertEqual(back[0].id, n.id)
    XCTAssertEqual(back[0].snippet, "x\ny")
    XCTAssertEqual(back[0].sentAt, n.sentAt)
    XCTAssertFalse(store.url.lastPathComponent.contains("/"))
  }
}
