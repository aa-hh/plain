import XCTest
@testable import PlainCore

final class SlugifyTests: XCTestCase {
    // Turns red if `slugify` stops lower-casing, stripping accents or collapsing punctuation into one hyphen.
    func testSlugify() {
        XCTAssertEqual(slugify("Héllo World!"), "hello-world")
        XCTAssertEqual(slugify("  A -- b  "), "a-b")
    }

    // Turns red if `SlugCounter` stops appending -1, -2 to repeated slugs.
    func testRepeats() {
        var counter = SlugCounter()
        XCTAssertEqual(counter.unique("hello"), "hello")
        XCTAssertEqual(counter.unique("hello"), "hello-1")
        XCTAssertEqual(counter.unique("hello"), "hello-2")
    }
}
