import XCTest
@testable import Spellcheck

// Each test turns red if the matching rule in SpellcheckController (excluded ranges, word filter, debounce, autocorrect memory) changes.
@MainActor
final class SpellcheckControllerTests: XCTestCase {
    private func makeController(autocorrect: Bool = false) -> SpellcheckController {
        let engine = WordListSpellingEngine(words: ["the", "cat", "sat", "on", "mat", "hello", "world", "python"],
                                            guesses: ["teh": ["the", "tech"], "speling": ["spelling", "spieling", "spewing", "spelling's", "extra"]])
        let c = SpellcheckController(engine: engine)
        c.autocorrect = autocorrect
        return c
    }

    private func change(_ c: SpellcheckController, _ text: String, at loc: Int = 0, length: Int? = nil, excluded: [NSRange] = [], typed: Character? = " ") {
        c.textChanged(text: text, changedRange: NSRange(location: loc, length: length ?? (text as NSString).length), excludedRanges: excluded, typedCharacter: typed)
    }

    func testMisspellingReported() async throws {
        let c = makeController()
        change(c, "the cat sat on the mta")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(c.misspellings, [NSRange(location: 19, length: 3)])
    }

    func testExcludedRangeIgnored() async throws {
        let c = makeController()
        change(c, "the mta cat", excluded: [NSRange(location: 4, length: 3)])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(c.misspellings, [])
    }

    func testOneLetterAndSpecialCharacterWordsIgnored() async throws {
        let c = makeController()
        change(c, "I use C++ and x86 with hello")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(c.misspellings.map { ("I use C++ and x86 with hello" as NSString).substring(with: $0) }, ["use", "and", "with"])
    }

    func testSpaceRechecksNowLetterWaitsAboutASecond() async throws {
        let c = makeController()
        change(c, "teh", typed: "h")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(c.misspellings, [])
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(c.misspellings, [NSRange(location: 0, length: 3)])
        change(c, "teh teh ", at: 7, length: 1, typed: " ")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(c.misspellings.count, 2)
    }

    func testCorrectionsAreCappedAtFour() async {
        let c = makeController()
        change(c, "speling")
        let list = await c.corrections(for: NSRange(location: 0, length: 7))
        XCTAssertEqual(list, ["spelling", "spieling", "spewing", "spelling's"])
    }

    func testLearnRemovesMisspelling() async throws {
        let c = makeController()
        change(c, "hello wrld")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(c.misspellings.count, 1)
        await c.learn(word: "wrld")
        XCTAssertEqual(c.misspellings, [])
    }

    func testAutocorrectOnceNotTwice() async {
        let c = makeController(autocorrect: true)
        func type(_ text: String) {
            for (i, ch) in text.enumerated() { change(c, String(text.prefix(i + 1)), at: i, length: 1, typed: ch) }
        }
        type("teh")
        let first = await c.didTypeSpace(at: 3, in: "teh ")
        XCTAssertEqual(first, Correction(range: NSRange(location: 0, length: 3), replacement: "the"))
        type("teh")
        let second = await c.didTypeSpace(at: 3, in: "teh ")
        XCTAssertNil(second)
    }

    func testAutocorrectSkipsPastedWord() async {
        let c = makeController(autocorrect: true)
        change(c, "teh", typed: "h")
        let result = await c.didTypeSpace(at: 3, in: "teh ")
        XCTAssertNil(result)
    }

    func testSystemEngineSmoke() async throws {
        try XCTSkipIf(NSSpellChecker.shared.availableLanguages.isEmpty, "no spelling languages installed")
        let engine = SystemSpellingEngine()
        let guesses = await engine.guesses(for: "teh")
        XCTAssertFalse(guesses.isEmpty)
        let found = await engine.check(paragraph: "this is teh test")
        XCTAssertEqual(found, [NSRange(location: 8, length: 3)])
    }
}
