import Foundation
import XCTest
@testable import MarkdownDocument

final class IncrementalTests: XCTestCase {
    /// Seeded generator so a failing run repeats exactly.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    /// Twenty lines touching most block and inline kinds, repeated ten times.
    static let fixture: String = {
        let chunk = """
        # Heading with *emphasis* {.note}

        A paragraph with **strong**, `code`, $x^2$, a [link](https://example.com) and :smile: café.
        It continues on a second line with ::marked:: text and https://plain.example/path.

        - item one
        - [x] done task
          continued item
        > quoted [ref] line
        > more quote

        ```swift
        let value = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        [ref]: https://ref.example

        """
        return String(repeating: chunk, count: 10)
    }()

    /// Block kinds, ranges, line ranges and inline kinds, depth first, for comparing two parses.
    private func describe(_ snapshot: Snapshot) -> [String] {
        func inlineKinds(_ list: [Inline]) -> [String] {
            list.flatMap { ["\($0.kind)"] + inlineKinds($0.children) }
        }
        return snapshot.blocks(where: { _ in true }).map {
            "\($0.kind) \($0.range) \($0.lineRange) \(inlineKinds($0.inlines))"
        }
    }

    /// Applies the edit to the document and the model, then checks the incremental snapshot against a fresh parse.
    private func check(_ document: MarkdownDocument, _ model: NSMutableString, _ edit: TextEdit, _ message: String,
                       file: StaticString = #filePath, line: UInt = #line) async {
        model.replaceCharacters(in: edit.range, with: edit.replacement)
        let snapshot = await document.snapshot(atLeast: document.apply(edit))
        XCTAssertEqual(snapshot.text, model as String, message, file: file, line: line)
        let fresh = await MarkdownDocument(text: model as String).currentSnapshot()
        XCTAssertEqual(describe(snapshot), describe(fresh), message, file: file, line: line)
        XCTAssertEqual(snapshot.headings.map(\.slug), fresh.headings.map(\.slug), message, file: file, line: line)
        XCTAssertEqual(snapshot.referenceDefinitions, fresh.referenceDefinitions, message, file: file, line: line)
    }

    private func type(_ text: String, at offset: Int, in document: MarkdownDocument, _ model: NSMutableString) async {
        for (index, unit) in text.utf16.enumerated() {
            let edit = TextEdit(range: NSRange(location: offset + index, length: 0), replacement: String(utf16CodeUnits: [unit], count: 1))
            await check(document, model, edit, "typing \(text.debugDescription) at \(offset), step \(index)")
        }
    }

    func testRandomEditsMatchFullParse() async {
        // Fails if the window, the line table update or the block shifting after an edit drifts from a full parse.
        let alphabet = Array("#*_`$[]()>-+:|~!{}=\\ \n\nab1.é".utf16)
        var random = SplitMix64(state: 42)
        let model = NSMutableString(string: Self.fixture)
        let document = MarkdownDocument(text: Self.fixture)
        for step in 0..<300 {
            var offset = random.below(model.length + 1)
            if offset < model.length { offset = model.rangeOfComposedCharacterSequence(at: offset).location }
            let edit: TextEdit
            if model.length > 0 && random.below(3) == 0 {
                let target = model.rangeOfComposedCharacterSequence(at: min(offset, model.length - 1))
                edit = TextEdit(range: target, replacement: "")
            } else {
                let unit = alphabet[random.below(alphabet.count)]
                edit = TextEdit(range: NSRange(location: offset, length: 0), replacement: String(utf16CodeUnits: [unit], count: 1))
            }
            await check(document, model, edit, "step \(step): \(edit.range) \(edit.replacement.debugDescription)")
        }
    }

    func testTypingFenceOpenerMidDocument() async {
        // Fails if an open fence stops extending the window to where it closes or to a full reparse.
        let model = NSMutableString(string: Self.fixture)
        let document = MarkdownDocument(text: Self.fixture)
        let offset = model.range(of: "- item one", options: [], range: NSRange(location: 600, length: model.length - 600)).location
        await type("```\n", at: offset, in: document, model)
    }

    func testClosingFence() async {
        // Fails if closing a fence stops ending the code block and restoring the blocks after it.
        let text = "para\n\n```\ncode\n\n# not a heading\n\nmore"
        let model = NSMutableString(string: text)
        let document = MarkdownDocument(text: text)
        await type("```\n", at: (text as NSString).range(of: "# not").location, in: document, model)
    }

    func testEditingReferenceDefinition() async {
        // Fails if changing a definition label stops reparsing references elsewhere in the document.
        let model = NSMutableString(string: Self.fixture)
        let document = MarkdownDocument(text: Self.fixture)
        let offset = model.range(of: "[ref]:", options: .backwards).location + 1
        await check(document, model, TextEdit(range: NSRange(location: offset, length: 3), replacement: "other"), "rename label")
        await check(document, model, TextEdit(range: NSRange(location: offset, length: 5), replacement: "ref"), "restore label")
    }

    func testJoiningTwoParagraphs() async {
        // Fails if deleting the blank line between paragraphs stops merging them into one block.
        let text = "first para\n\nsecond para\n\n# H"
        let model = NSMutableString(string: text)
        let document = MarkdownDocument(text: text)
        await check(document, model, TextEdit(range: NSRange(location: 10, length: 1), replacement: ""), "join")
    }

    func testBlankLineInsideList() async {
        // Fails if a blank line between items stops being reparsed as part of the same list.
        let text = "- a\n- b\n- c\n\nafter"
        let model = NSMutableString(string: text)
        let document = MarkdownDocument(text: text)
        await check(document, model, TextEdit(range: NSRange(location: 4, length: 0), replacement: "\n"), "blank line")
    }

    func testUnderlineUnderParagraph() async {
        // Fails if typing `===` under a paragraph stops turning the block before it into a setext heading.
        let text = "intro\n\nTitle line\n\nnext"
        let model = NSMutableString(string: text)
        let document = MarkdownDocument(text: text)
        await type("\n===", at: NSMaxRange((text as NSString).range(of: "Title line")), in: document, model)
    }
}
