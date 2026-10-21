import AppKit
import MarkdownDocument
import PlainCore
import PlainDocument
import XCTest
@testable import EditorTextView

@MainActor
final class StylerTests: XCTestCase {
    // Turns red if the styler stops making strong text bold or stops fading its markers.
    func testBoldTextIsBoldAndMarkersFaded() async {
        let editor = await makeEditor("a **bold** b\n")
        XCTAssertTrue(editor.isBold(at: 5))
        XCTAssertTrue(editor.isBold(at: 2))
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 2) as? NSColor, Tokens.colorTertiary)
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 5) as? NSColor, Tokens.color)
        XCTAssertFalse(editor.isBold(at: 0))
    }

    // Turns red if ATX headings stop being bold, lose their margin label, or the `#` run stops collapsing to zero width.
    func testHeadingIsBoldWithLabelAndCollapsedMarker() async {
        let editor = await makeEditor("## Title\n\ntext\n")
        XCTAssertTrue(editor.isBold(at: 4))
        XCTAssertEqual(editor.font(at: 4)?.pointSize, 18)
        XCTAssertEqual(editor.attribute(.plainHeadingLabel, at: 0) as? String, "h2")
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 0) as? NSColor, .clear)
        let kern = editor.attribute(.kern, at: 0) as? CGFloat ?? 0
        XCTAssertLessThan(kern, 0)
        let style = editor.attribute(.paragraphStyle, at: 4) as? NSParagraphStyle
        XCTAssertEqual(style?.minimumLineHeight ?? 0, 28.8, accuracy: 0.01)
    }

    // Turns red if fenced code stops using the code font, loses its band or stops fading its fences.
    func testFencedCodeUsesCodeFontBandAndFadedFences() async {
        let editor = await makeEditor("```swift\nlet x = 1\n```\n")
        XCTAssertEqual(editor.font(at: 10)?.fontName, "RobotoMono-Regular")
        XCTAssertNotNil(editor.attribute(.plainBand, at: 10))
        XCTAssertNil(editor.attribute(.plainBand, at: 0))
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 0) as? NSColor, Tokens.colorTertiary)
        let keyword = editor.attribute(.foregroundColor, at: 9) as? NSColor
        XCTAssertEqual(keyword, MarkdownStyler.tokenColours["keyword"])
    }

    // Turns red if link text stops being blue or the brackets and URL stop being faded.
    func testLinkTextBlueAndRestFaded() async {
        let editor = await makeEditor("see [here](https://x.y) now\n")
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 5) as? NSColor, Tokens.colorBlue)
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 4) as? NSColor, Tokens.colorTertiary)
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 14) as? NSColor, Tokens.colorTertiary)
    }

    // Turns red if inline code stops using the code font or its gold colour.
    func testInlineCodeGoldInCodeFont() async {
        let editor = await makeEditor("a `code` b\n")
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 3) as? NSColor, Tokens.colorGold)
        XCTAssertEqual(editor.font(at: 3)?.fontName, "RobotoMono-Regular")
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 2) as? NSColor, Tokens.colorTertiary)
    }

    // Turns red if a list item's wrapped lines stop hanging under the text after the marker.
    func testListItemHangingIndent() async {
        let editor = await makeEditor("- item text\n")
        let style = editor.attribute(.paragraphStyle, at: 3) as? NSParagraphStyle
        XCTAssertGreaterThan(style?.headIndent ?? 0, 0)
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 0) as? NSColor, Tokens.colorSecondary)
    }

    // Turns red if typed text is no longer forwarded to MarkdownDocument and restyled.
    func testTypingRestylesFromSnapshot() async {
        let editor = await makeEditor("hello\n")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        await editor.type("# ")
        XCTAssertEqual(editor.text, "# hello\n")
        XCTAssertEqual(editor.snapshot?.blocks.first?.kind, .atxHeading(level: 1))
        XCTAssertTrue(editor.isBold(at: 3))
        XCTAssertEqual(editor.attribute(.plainHeadingLabel, at: 0) as? String, "h1")
    }

    // Turns red if an edit restyles blocks beyond the one it touched.
    func testOnlyTheEditedBlockRestyles() async {
        let editor = await makeEditor("first para\n\nsecond para\n\nthird para\n")
        let probe = NSAttributedString.Key("probe")
        editor.document.textStorage.addAttribute(probe, value: true, range: NSRange(location: 0, length: editor.text.utf16.count))
        editor.setSelectedRange(NSRange(location: 18, length: 0))
        await editor.type("x")
        XCTAssertNotNil(editor.attribute(probe, at: 2), "first block was restyled")
        XCTAssertNotNil(editor.attribute(probe, at: 30), "third block was restyled")
        XCTAssertNil(editor.attribute(probe, at: 15), "edited block was not restyled")
    }

    // Turns red if the styler's own restyle reports more than the blocks meeting the range.
    func testRestyleReturnsTouchedBlocksOnly() async {
        let editor = await makeEditor("one\n\ntwo\n\nthree\n")
        let snapshot = editor.snapshot!
        let ids = editor.styler.restyle(snapshot: snapshot, range: NSRange(location: 6, length: 0))
        XCTAssertEqual(ids, [snapshot.blocks[1].id])
    }

    // Turns red if the editor stops drawing its fragments with the subclass that draws labels and overlays.
    func testLayoutFragmentsUseEditorSubclass() async {
        let editor = await makeEditor("# Head\n")
        var found = false
        editor.textLayoutManager?.enumerateTextLayoutFragments(from: editor.textLayoutManager?.documentRange.location, options: [.ensuresLayout]) {
            found = $0 is EditorLayoutFragment
            return false
        }
        XCTAssertTrue(found)
    }

    // Turns red if the column stops being ceil(72 × width of "a") wide and centred with 80 pt minimum sides.
    func testColumnWidthAndCentring() async {
        let editor = await makeEditor("x\n")
        let a = NSAttributedString(string: "a", attributes: [.font: NSFont.systemFont(ofSize: 15)]).size().width
        XCTAssertEqual(editor.columnWidth, ceil(72 * a))
        XCTAssertEqual(editor.textContainer?.size.width, editor.columnWidth)
        XCTAssertEqual(editor.textContainerOrigin.x, ((editor.bounds.width - editor.columnWidth) / 2).rounded(.down))
        XCTAssertEqual(editor.textContainerOrigin.y, 48)
    }

    // Turns red if a new editor on a parser that has already taken edits starts at version 0 again and drops its
    // first snapshot, leaving the reattached text unstyled.
    func testReattachedEditorStylesFromUsedParser() async {
        let document = PlainDocument.Document(text: "text\n")
        let markdown = MarkdownDocument(text: "text\n")
        let first = EditorTextView(document: document, markdown: markdown)
        host(first)
        await first.settle()
        first.replace(all: "## Title\n\ntext\n")
        await first.settle()

        let second = EditorTextView(document: document, markdown: markdown)
        host(second)
        await second.settle()
        XCTAssertEqual(second.snapshot?.text, document.text)
        XCTAssertTrue(second.isBold(at: 4))
        XCTAssertEqual(second.attribute(.plainHeadingLabel, at: 0) as? String, "h2")
    }

    // Turns red if an editor attaching to a parser stops comparing the parser's text with the tab's text, so an
    // edit made while no editor was attached (a background tab) never reaches the parser.
    func testBackgroundEditReachesParserWhenEditorAttaches() async {
        let document = PlainDocument.Document(text: "text\n")
        let markdown = MarkdownDocument(text: "text\n")
        var first: EditorTextView? = EditorTextView(document: document, markdown: markdown)
        await first?.settle()
        weak var released = first
        first = nil
        let gone = await waitUntil { released == nil }
        XCTAssertTrue(gone)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Head\n\n")

        let second = EditorTextView(document: document, markdown: markdown)
        host(second)
        await second.settle()
        let parsed = await markdown.currentSnapshot()
        XCTAssertEqual(parsed.text, "# Head\n\ntext\n")
        XCTAssertEqual(second.snapshot?.text, document.text)
        XCTAssertTrue(second.isBold(at: 3))
        XCTAssertEqual(parsed.headings.map(\.text), ["Head"])
    }
}
