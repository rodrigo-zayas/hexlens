import XCTest
@testable import HexLensCore

final class SideBySideTests: XCTestCase {
  private func line(_ k: CodeLine.Kind, _ t: String, old: Int? = nil, new: Int? = nil) -> CodeLine {
    CodeLine(kind: k, text: t, oldNumber: old, newNumber: new)
  }

  func testPairsBlocksAndPadsShorterSide() throws {
    let doc = CodeDocument(lines: [
      line(.context, "a", old: 1, new: 1),
      line(.removed, "b1", old: 2), line(.removed, "b2", old: 3), line(.removed, "b3", old: 4),
      line(.added, "c1", new: 2),
      line(.context, "d", old: 5, new: 3),
      line(.added, "e", new: 4),
    ])
    let r = try XCTUnwrap(SideBySide.build(from: doc))
    XCTAssertEqual(r.left.lines.count, r.right.lines.count)
    XCTAssertEqual(r.left.lines.map(\.kind), [.context, .removed, .removed, .removed, .context, .filler])
    XCTAssertEqual(r.right.lines.map(\.kind), [.context, .added, .filler, .filler, .context, .added])
    XCTAssertEqual(r.left.lines.map(\.oldNumber), [1, 2, 3, 4, 5, nil])
    XCTAssertEqual(r.right.lines.map(\.newNumber), [1, 2, nil, nil, 3, 4])
    XCTAssertEqual(r.left.lines[1].text, "b1")
    XCTAssertEqual(r.right.lines[2].text, "")
  }

  func testSeparatorsAppearOnBothSides() throws {
    let doc = CodeDocument(lines: [
      line(.separator, "@@"), line(.removed, "x", old: 1), line(.added, "y", new: 1), line(.context, "z", old: 2, new: 2),
    ])
    let r = try XCTUnwrap(SideBySide.build(from: doc))
    XCTAssertEqual(r.left.lines.map(\.kind), [.separator, .removed, .context])
    XCTAssertEqual(r.right.lines.map(\.kind), [.separator, .added, .context])
  }

  func testNewOrDeletedFilesShowOneSide() {
    XCTAssertNil(SideBySide.build(from: CodeDocument(lines: [line(.added, "a", new: 1)])))
    XCTAssertNil(SideBySide.build(from: CodeDocument(lines: [line(.removed, "a", old: 1)])))
    XCTAssertNil(SideBySide.build(from: CodeDocument(lines: [line(.context, "a", old: 1, new: 1)])))
  }
}
