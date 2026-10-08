import XCTest

@testable import HexLensCore

final class OutlineTests: XCTestCase {
  private let source = """
    package a;

    public class Foo {
      private final Bar bar;
      private int n = 3;

      public Foo(Bar bar) {
        this.bar = bar;
      }

      void run() {
        bar.go();
      }
    }
    """

  func testEntriesWithLines() {
    let o = Outline.java(source)
    XCTAssertEqual(o.map(\.name), ["Foo", "bar", "n", "Foo", "run"])
    XCTAssertEqual(o.map(\.kind), [.type, .field, .field, .method, .method])
    XCTAssertEqual(o.map(\.line), [3, 4, 5, 7, 11])
  }

  func testTrail() {
    let o = Outline.java(source)
    XCTAssertEqual(Outline.trail(o, line: 12).map(\.name), ["Foo", "run"])
    XCTAssertEqual(Outline.trail(o, line: 1).map(\.name), [])
  }
}
