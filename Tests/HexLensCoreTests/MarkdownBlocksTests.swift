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
