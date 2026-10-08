import XCTest

@testable import HexLensCore

final class FuzzyMatchTests: XCTestCase {
  func testEmptyQueryMatchesAll() { XCTAssertEqual(FuzzyMatch.score(query: "", candidate: "Foo"), 0) }

  func testCamelCaseInitials() {
    XCTAssertNotNil(FuzzyMatch.score(query: "NIMR", candidate: "NewInMarkRepository"))
  }

  func testNoMatch() {
    XCTAssertNil(FuzzyMatch.score(query: "xyz", candidate: "NewInMarkRepository"))
    XCTAssertNil(FuzzyMatch.score(query: "abcd", candidate: "abc"))
  }

  func testSubsequence() { XCTAssertNotNil(FuzzyMatch.score(query: "nmrp", candidate: "NewInMarkRepository")) }

  func testPrefixBeatsScattered() {
    let prefix = FuzzyMatch.score(query: "Repo", candidate: "RepositoryImpl")!
    let scattered = FuzzyMatch.score(query: "Repo", candidate: "NewInMarkRepository")!
    XCTAssertGreaterThan(prefix, scattered)
  }

  func testInitialsBeatMidWord() {
    let initials = FuzzyMatch.score(query: "NIM", candidate: "NewInMark")!
    let mid = FuzzyMatch.score(query: "NIM", candidate: "Cnnimmy")
    XCTAssertGreaterThan(initials, mid ?? Int.min)
  }

  func testExactBeatsLongerPrefix() {
    XCTAssertGreaterThan(FuzzyMatch.score(query: "foo", candidate: "Foo")!, FuzzyMatch.score(query: "foo", candidate: "FooBar")!)
  }

  func testCaseInsensitive() { XCTAssertNotNil(FuzzyMatch.score(query: "newin", candidate: "NewInMark")) }
}
