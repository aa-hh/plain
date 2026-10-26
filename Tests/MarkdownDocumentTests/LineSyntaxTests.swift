import Foundation
import XCTest
@testable import MarkdownDocument

final class LineSyntaxTests: XCTestCase {
    // Turns red if a line holding only indentation and a list marker stops being recognised, or one with anything after
    // the marker starts being.
    func testBareListMarker() {
        XCTAssertEqual(LineSyntax.bareListMarker(in: "-"), NSRange(location: 0, length: 1))
        XCTAssertEqual(LineSyntax.bareListMarker(in: "  1)"), NSRange(location: 2, length: 2))
        XCTAssertEqual(LineSyntax.bareListMarker(in: "123456789."), NSRange(location: 0, length: 10))
        for line in ["-x", "- ", "1234567890.", ""] {
            XCTAssertNil(LineSyntax.bareListMarker(in: line), line)
        }
    }
}
