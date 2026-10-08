import XCTest

@testable import HexLensCore

final class NotesPromptTests: XCTestCase {
  func testNotesPrompt() {
    let n = ReviewNote(path: "src/A.java", startLine: 3, endLine: 4, snippet: "int a;\nint b;", body: "Renombra", anchorSHA: "s", outdated: true)
    let p = NotesPrompt.build(notes: [n], pr: "#7 Algo", branch: "feat", repo: "r")
    XCTAssertTrue(p.contains("`src/A.java:3-4`"))
    XCTAssertTrue(p.contains("```java\nint a;\nint b;\n```"))
    XCTAssertTrue(p.contains("Renombra"))
    XCTAssertTrue(p.contains("desactualizada"))
  }
}
