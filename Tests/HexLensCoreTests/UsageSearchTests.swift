import XCTest
@testable import HexLensCore

final class UsageSearchTests: XCTestCase {
  func testParseStripsRevAndKeepsColonsInText() {
    let out = "abc123:src/A.java:12:  Foo x = a ? b : c;\nabc123:src/B.java:3:new Foo()\n"
    let hits = UsageSearch.parse(out, rev: "abc123")
    XCTAssertEqual(hits.count, 2)
    XCTAssertEqual(hits[0], UsageHit(path: "src/A.java", line: 12, text: "  Foo x = a ? b : c;"))
    XCTAssertEqual(hits[1].path, "src/B.java")
  }

  func testParseWithoutRevAndGarbage() {
    let hits = UsageSearch.parse("junk\nsrc/A.java:1:x\nsrc/A.java:x:y\n")
    XCTAssertEqual(hits, [UsageHit(path: "src/A.java", line: 1, text: "x")])
  }

  func testGroupKeepsOrder() {
    let hits = [UsageHit(path: "b", line: 1, text: ""), UsageHit(path: "a", line: 2, text: ""), UsageHit(path: "b", line: 3, text: "")]
    let g = UsageSearch.group(hits)
    XCTAssertEqual(g.map(\.path), ["b", "a"])
    XCTAssertEqual(g[0].hits.map(\.line), [1, 3])
  }
}
