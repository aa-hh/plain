import Foundation
import XCTest
@testable import MarkdownDocument

final class CodeHighlighterTests: XCTestCase {
    func testSwiftKeyword() {
        // Fails if Prism's tokens stop being flattened to leaf tokens with UTF-16 offsets.
        let tokens = CodeHighlighter.shared.tokens(for: "let x = 1", language: "swift")
        XCTAssertTrue(tokens?.contains(CodeToken(range: NSRange(location: 0, length: 3), type: "keyword")) == true, "\(String(describing: tokens))")
    }

    func testUnknownLanguageIsNil() {
        // Fails if a language missing from components.json returns tokens instead of nil.
        XCTAssertNil(CodeHighlighter.shared.tokens(for: "x", language: "no-such-language"))
    }

    func testCppLoadsCFirst() {
        // Fails if a language's `require` entries stop loading before the language itself.
        XCTAssertNotNil(CodeHighlighter.shared.tokens(for: "int x;", language: "cpp"))
        let loaded = CodeHighlighter.shared.loadedLanguageIDs()
        let c = loaded.firstIndex(of: "c")
        let cpp = loaded.firstIndex(of: "cpp")
        XCTAssertNotNil(c)
        XCTAssertNotNil(cpp)
        if let c, let cpp { XCTAssertLessThan(c, cpp) }
    }
}
