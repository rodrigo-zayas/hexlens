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

  func testTableRowLines() {
    let r = MarkdownBlocks.parseWithLines("intro\n\n| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\nfin")
    XCTAssertEqual(r[1].parts, [2, 4, 5])
    XCTAssertEqual(r[1].lines, 2..<6)
  }

  func testListItemLines() {
    let r = MarkdownBlocks.parseWithLines("x\n\n- a\n  sigue\n  - b\n- c")
    guard case .list(let items) = r[1].block else { return XCTFail() }
    XCTAssertEqual(items.map(\.lines), [2..<4, 5..<6])
    XCTAssertEqual(items[0].children.map(\.lines), [4..<5])
  }

  func testCodeLineSources() {
    let r = MarkdownBlocks.parseWithLines("t\n\n```java\na\n\nb\n```\nfin")
    XCTAssertEqual(r[1].parts, [3, 4, 5])
    XCTAssertEqual(r[1].lines, 2..<7)
  }

  func testDiffKeepsOnlyAddedLines() {
    let d = DiffParser.parse("diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/a.md\n@@ -1,4 +1,4 @@\n # T\n-viejo\n-otro\n+nuevo\n fin\n-final\n")["a.md"]!
    let m = MarkdownDiff(diff: d, isNewFile: false)
    XCTAssertEqual(m.added, [2])
  }
}
