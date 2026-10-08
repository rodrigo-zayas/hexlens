import XCTest
@testable import HexLensCore

final class FoldRegionsTests: XCTestCase {
  private let sample = """
    package a;

    import java.util.List;
    import java.util.Map;

    import static x.Y.z;

    /**
     * Doc.
     */
    public class A {
      void f() {
        if (x) {
          g();
        } else {
          h();
        }
      }

      class Inner {
        int v;
      }

      void one() { }
    }
    """

  private func regions() -> [FoldRegion] { FoldRegions.compute(lines: sample.components(separatedBy: "\n")) }

  func testImportsGroupedAcrossBlankLines() {
    let r = regions().first { $0.kind == .imports }
    XCTAssertEqual(r?.start, 2)
    XCTAssertEqual(r?.hiddenEnd, 5)
  }

  func testMultilineCommentFolds() {
    let r = regions().first { $0.kind == .comment }
    XCTAssertEqual(r?.start, 7)
    XCTAssertEqual(r?.end, 9)
  }

  func testMethodAndInnerClassBodies() {
    let blocks = regions().filter { $0.kind == .block }
    XCTAssertEqual(blocks.map(\.start), [10, 11, 12, 14, 19])
    let method = blocks.first { $0.start == 11 }
    XCTAssertEqual(method?.end, 17)
    XCTAssertEqual(method?.hiddenEnd, 17)
    XCTAssertTrue(method?.hidesClosing ?? false)
    XCTAssertEqual(blocks.first { $0.start == 19 }?.end, 21)
  }

  func testElseKeepsClosingLineVisible() {
    let b = regions().first { $0.kind == .block && $0.start == 12 }
    XCTAssertEqual(b?.end, 14)
    XCTAssertEqual(b?.hiddenEnd, 13)
    XCTAssertFalse(b?.hidesClosing ?? true)
  }

  func testSingleLineBlocksAndUnbalancedAreIgnored() {
    XCTAssertTrue(regions().allSatisfy { $0.start != 23 })
    XCTAssertTrue(FoldRegions.compute(lines: ["void f() {", "  x();"]).isEmpty)
    XCTAssertTrue(FoldRegions.compute(lines: []).isEmpty)
  }
}
