import XCTest
@testable import PlainCore

final class FuzzyFilterTests: XCTestCase {
    // Turns red if `fuzzyMatch` stops matching query letters in order at the earliest positions.
    func testFuzzyMatchIndexes() {
        XCTAssertEqual(fuzzyMatch(query: "gtf", in: "Go to File")?.indexes, [0, 3, 6])
        XCTAssertNil(fuzzyMatch(query: "ftg", in: "Go to File"))
    }

    // Turns red if a capital in the query stops making the match case-sensitive.
    func testCapitalMakesCaseSensitive() {
        XCTAssertNil(fuzzyMatch(query: "Gtf", in: "go to file"))
        XCTAssertNotNil(fuzzyMatch(query: "gtf", in: "GO TO FILE"))
    }

    // Turns red if `filter` stops ranking word-start matches first or stops keeping input order on ties.
    func testFilterOrdering() {
        let result = filter(items: ["axbycz", "a b c", "a b c."], query: "abc") { $0 }.map(\.item)
        XCTAssertEqual(result, ["a b c", "a b c.", "axbycz"])
    }

    // Turns red if `chunkStartMatch` accepts a match in the middle of a chunk, or `substringMatch` stops finding it.
    func testChunkStartAndSubstring() {
        XCTAssertNil(chunkStartMatch(query: "ile", in: "Profile.md"))
        let text = "Profile.md"
        let range = substringMatch(query: "ile", in: text)
        XCTAssertEqual(range.map { text.distance(from: text.startIndex, to: $0.lowerBound) }, 4)
        XCTAssertEqual(range.map { text.distance(from: text.startIndex, to: $0.upperBound) }, 7)
        XCTAssertNotNil(chunkStartMatch(query: "file", in: "my File.md"))
    }
}
