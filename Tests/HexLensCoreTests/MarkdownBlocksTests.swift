import XCTest

@testable import HexLensCore

final class MarkdownBlocksTests: XCTestCase {
  func testHeadings() {
    let b = MarkdownBlocks.parse("# Título\n\n### Sub ###\n\n#nohead")
    XCTAssertEqual(b, [.heading(level: 1, text: "Título"), .heading(level: 3, text: "Sub"), .paragraph("#nohead")])
  }

  func testNestedListsAndTasks() {
    let b = MarkdownBlocks.parse("- a\n  - b\n  - [x] c\n- d\n\n1. uno\n2. dos")
    guard case .list(let l1) = b[0], case .list(let l2) = b[1] else { return XCTFail("\(b)") }
    XCTAssertEqual(l1.map(\.text), ["a", "d"])
    XCTAssertEqual(l1[0].children.map(\.text), ["b", "c"])
    XCTAssertEqual(l1[0].children[1].checked, true)
    XCTAssertNil(l1[0].children[0].checked)
    XCTAssertEqual(l2.map(\.number), [1, 2])
  }

  func testCodeWithLanguage() {
    let b = MarkdownBlocks.parse("```java\nclass A {}\n# no es título\n```\nfin")
    XCTAssertEqual(b, [.code(language: "java", text: "class A {}\n# no es título"), .paragraph("fin")])
  }

  func testTable() {
    let b = MarkdownBlocks.parse("| A | B |\n|---|:-:|\n| 1 | 2 |\n| 3 | x\\|y |")
    XCTAssertEqual(b, [.table(header: ["A", "B"], rows: [["1", "2"], ["3", "x|y"]])])
  }

  func testQuoteAndRule() {
    let b = MarkdownBlocks.parse("> uno\n> dos\n\n---\n\ntexto")
    XCTAssertEqual(b, [.quote([.paragraph("uno dos")]), .rule, .paragraph("texto")])
  }
}

final class MarkdownBlocksLinesTests: XCTestCase {
  func testLineRanges() {
    let r = MarkdownBlocks.parseWithLines("# T\n\npárrafo\nsigue\n\n- a\n- b\n\n```\nx\n\ny\n```\n> q\n> r")
    XCTAssertEqual(r.map(\.lines), [0..<1, 2..<4, 5..<7, 8..<13, 13..<15])
    XCTAssertEqual(r.count, 5)
  }

  func testWrapperMatchesAndCRLF() {
    let s = "a\r\n\r\n| h |\r\n|---|\r\n| c |"
    XCTAssertEqual(MarkdownBlocks.parseWithLines(s).map(\.block), MarkdownBlocks.parse(s))
    XCTAssertEqual(MarkdownBlocks.parseWithLines(s).map(\.lines), [0..<1, 2..<5])
  }

  func testDiffAddedAndRemovals() {
    let d = DiffParser.parse("diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/a.md\n@@ -1,4 +1,4 @@\n # T\n-viejo\n-otro\n+nuevo\n fin\n-final\n")["a.md"]!
    let m = MarkdownDiff(diff: d, isNewFile: false)
    XCTAssertEqual(m.added, [2])
    XCTAssertEqual(m.removals.map(\.anchor), [1, 3])
    XCTAssertEqual(m.removals[0].lines, ["viejo", "otro"])
    XCTAssertEqual(m.removals[0].oldLine, 2)
  }
}
