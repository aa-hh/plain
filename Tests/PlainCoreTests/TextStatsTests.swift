import XCTest
@testable import PlainCore

final class TextStatsTests: XCTestCase {
    // Turns red if `TextStats.wordCount` stops removing punctuation before splitting on whitespace.
    func testWordCount() {
        XCTAssertEqual(TextStats.wordCount("Hi, there - you?"), 3)
        XCTAssertEqual(TextStats.wordLabel("Hi, there - you?"), "3 W")
    }

    // Turns red if reading time stops using 200 words per minute or the mm:ss RT label form.
    func testReadingTime() {
        let text = Array(repeating: "word", count: 400).joined(separator: " ")
        XCTAssertEqual(TextStats.readingTimeLabel(text), "02:00 RT")
        XCTAssertEqual(TextStats.characterLabel("abc"), "3 C")
    }
}
