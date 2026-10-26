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
        let first = EditorTextView(document: document, markdown: markdown, configuration: EditorConfiguration(showMarkdownSource: true))
        host(first)
        await first.settle()
        first.replace(all: "## Title\n\ntext\n")
        await first.settle()

        let second = EditorTextView(document: document, markdown: markdown, configuration: EditorConfiguration(showMarkdownSource: true))
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
        var first: EditorTextView? = EditorTextView(document: document, markdown: markdown, configuration: EditorConfiguration(showMarkdownSource: true))
        await first?.settle()
        weak var released = first
        first = nil
        let gone = await waitUntil { released == nil }
        XCTAssertTrue(gone)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Head\n\n")

        let second = EditorTextView(document: document, markdown: markdown, configuration: EditorConfiguration(showMarkdownSource: true))
        host(second)
        await second.settle()
        let parsed = await markdown.currentSnapshot()
        XCTAssertEqual(parsed.text, "# Head\n\ntext\n")
        XCTAssertEqual(second.snapshot?.text, document.text)
        XCTAssertTrue(second.isBold(at: 3))
        XCTAssertEqual(parsed.headings.map(\.text), ["Head"])
    }

    // MARK: Page

    private func page(_ text: String, url: URL? = nil) async -> EditorTextView {
        await makeEditor(text, url: url, configuration: EditorConfiguration())
    }

    private func isHidden(_ editor: EditorTextView, _ offsets: Range<Int>) -> Bool {
        offsets.allSatisfy { (editor.font(at: $0)?.pointSize ?? 99) < 0.1 && editor.attribute(.foregroundColor, at: $0) as? NSColor == .clear }
    }

    private func lineHeight(_ editor: EditorTextView, at offset: Int) -> CGFloat? {
        (editor.attribute(.paragraphStyle, at: offset) as? NSParagraphStyle)?.minimumLineHeight
    }

    // Turns red if a page paragraph stops using 16 pt body text in page-text on a 24 pt line.
    func testPageText() async {
        let editor = await page("plain words\n")
        XCTAssertEqual(editor.font(at: 0)?.pointSize, 16)
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 0) as? NSColor, Tokens.page.text)
        XCTAssertEqual(lineHeight(editor, at: 0), 24)
    }

    // Turns red if a page heading shows its `#` run or a level label, or stops being bold at 24 pt on a 36 pt line.
    func testPageHeadingHidesHashes() async {
        let editor = await page("## Title\n")
        XCTAssertTrue(isHidden(editor, 0..<3))
        XCTAssertTrue(editor.isBold(at: 3))
        XCTAssertEqual(editor.font(at: 3)?.pointSize, 24)
        XCTAssertEqual(lineHeight(editor, at: 3), 36)
        XCTAssertEqual((editor.attribute(.paragraphStyle, at: 3) as? NSParagraphStyle)?.paragraphSpacingBefore, 24)
        XCTAssertNil(editor.attribute(.plainHeadingLabel, at: 0))
    }

    // Turns red if bold, italic or strikethrough markers show on the page, or the styles stop applying.
    func testPageEmphasisHidesMarkers() async {
        let editor = await page("a **b** _c_ ~~d~~\n")
        for offset in [2, 3, 5, 6, 8, 10, 12, 13, 15, 16] { XCTAssertTrue(isHidden(editor, offset..<(offset + 1)), "offset \(offset)") }
        XCTAssertTrue(editor.isBold(at: 4))
        XCTAssertTrue(editor.font(at: 9)?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 14) as? NSColor, Tokens.page.textSecondary)
        XCTAssertNotNil(editor.attribute(.strikethroughStyle, at: 14))
    }

    // Turns red if inline code shows its backticks, loses its chip, or stops being Roboto Mono 14 in color-red.
    func testPageInlineCodeChip() async {
        let editor = await page("a `x` b\n")
        XCTAssertTrue(isHidden(editor, 2..<3))
        XCTAssertTrue(isHidden(editor, 4..<5))
        XCTAssertNotNil(editor.attribute(.plainPageChip, at: 3))
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 3) as? NSColor, Tokens.colorRed)
        XCTAssertEqual(editor.font(at: 3)?.fontName, "RobotoMono-Regular")
        XCTAssertEqual(editor.font(at: 3)?.pointSize, 14)
    }

    // Turns red if a highlight shows its colons or loses its selection-yellow background.
    func testPageHighlight() async {
        let editor = await page("a ::hi:: b\n")
        XCTAssertTrue(isHidden(editor, 2..<4))
        XCTAssertTrue(isHidden(editor, 6..<8))
        XCTAssertEqual(editor.attribute(.backgroundColor, at: 4) as? NSColor, Tokens.selectionYellow)
    }

    // Turns red if a page link shows its brackets or URL, or loses its underline or its destination tooltip.
    func testPageLinkHidesSyntax() async {
        let editor = await page("see [here](https://x.y) now\n")
        XCTAssertTrue(isHidden(editor, 4..<5))
        XCTAssertTrue(isHidden(editor, 9..<23))
        XCTAssertNotNil(editor.attribute(.underlineStyle, at: 5))
        XCTAssertEqual(editor.attribute(.underlineColor, at: 5) as? NSColor, Tokens.page.textTertiary)
        XCTAssertEqual(editor.attribute(.toolTip, at: 5) as? String, "https://x.y")
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 5) as? NSColor, Tokens.page.text)
    }

    // Turns red if a bulleted item shows its `- `, stops drawing a bullet, or loses its 28 pt indent.
    func testPageBulletedItem() async {
        let bullets = await page("- item\n")
        XCTAssertTrue(isHidden(bullets, 0..<2))
        XCTAssertEqual((bullets.attribute(.plainPageMarker, at: 0) as? PageMarker)?.kind, .bullet)
        XCTAssertEqual((bullets.attribute(.paragraphStyle, at: 2) as? NSParagraphStyle)?.headIndent, 28)
    }

    // Turns red if a numbered item shows its `1. ` as text or stops drawing its number.
    func testPageNumberedItem() async {
        let numbers = await page("1. one\n")
        XCTAssertTrue(isHidden(numbers, 0..<3))
        XCTAssertEqual((numbers.attribute(.plainPageMarker, at: 0) as? PageMarker)?.kind, .number("1."))
    }

    // Turns red if a task shows its `[x]`, stops drawing a ticked box, or its ticked text stops being struck through.
    func testPageTaskBox() async {
        let editor = await page("- [x] done\n")
        XCTAssertTrue(isHidden(editor, 0..<6))
        XCTAssertEqual((editor.attribute(.plainPageMarker, at: 0) as? PageMarker)?.kind, .task(checked: true))
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 6) as? NSColor, Tokens.page.textTertiary)
        XCTAssertNotNil(editor.attribute(.strikethroughStyle, at: 6))
    }

    // Turns red if a quote shows its `>` or stops drawing its bar.
    func testPageQuoteBar() async {
        let editor = await page("> quoted\n")
        XCTAssertTrue(isHidden(editor, 0..<2))
        XCTAssertEqual(editor.attribute(.plainPageQuote, at: 2) as? Int, 1)
        XCTAssertEqual((editor.attribute(.paragraphStyle, at: 2) as? NSParagraphStyle)?.headIndent, 17)
    }

    // Turns red if a divider shows its dashes, stops drawing its rule, or its line stops being 25 pt.
    func testPageDivider() async {
        let editor = await page("a\n\n---\n\nb\n")
        XCTAssertTrue(isHidden(editor, 3..<7))
        XCTAssertNotNil(editor.attribute(.plainPageDivider, at: 3))
        XCTAssertEqual(lineHeight(editor, at: 3), 25)
        XCTAssertEqual(lineHeight(editor, at: 2), 2, "the blank line before it is a 2 pt separator")
    }

    // Turns red if `EditorLayoutFragment.panelLeft` starts a code panel inside a list item at the column's left edge
    // instead of the item's text indent, on the fence lines or the code line.
    func testPageCodePanelInListItemStartsAtItemText() async throws {
        let editor = await page("- item\n\n  ```\n  x\n  ```")
        let itemIndent = try XCTUnwrap(editor.attribute(.paragraphStyle, at: 2) as? NSParagraphStyle).headIndent
        XCTAssertEqual(itemIndent, 28)
        for offset in [8, 14, 18] {
            let manager = try XCTUnwrap(editor.textLayoutManager)
            let range = try XCTUnwrap(editor.textRange(for: NSRange(location: offset, length: 0)))
            manager.ensureLayout(for: range)
            let fragment = try XCTUnwrap(manager.textLayoutFragment(for: range.location) as? EditorLayoutFragment)
            XCTAssertEqual(fragment.panelLeft, itemIndent, "offset \(offset)")
        }
    }

    // Turns red if a code block shows its fences, loses its panel or language label, or its fence lines stop being
    // 54 pt (top padding, label row, gap) and 24 pt (bottom padding) tall.
    func testPageCodePanel() async {
        let editor = await page("```swift\nlet x\n```\n")
        XCTAssertTrue(isHidden(editor, 0..<9))
        XCTAssertTrue(isHidden(editor, 14..<18))
        let top = editor.attribute(.plainPagePanel, at: 0) as? PagePanelSlice
        XCTAssertEqual(top?.slice, .top)
        XCTAssertEqual(top?.label, "Swift")
        XCTAssertEqual((editor.attribute(.plainPagePanel, at: 15) as? PagePanelSlice)?.slice, .bottom)
        XCTAssertEqual(editor.font(at: 9)?.fontName, "RobotoMono-Regular")
        XCTAssertEqual(lineHeight(editor, at: 0), 54)
        XCTAssertEqual(lineHeight(editor, at: 15), 24)
        XCTAssertEqual(lineHeight(editor, at: 9) ?? 0, 22.4, accuracy: 0.01)
    }

    // Turns red if a table that fits shows its pipes or divider row, or stops drawing its grid and bold header.
    func testPageTableGrid() async {
        let editor = await page("| a | b |\n|---|---|\n| c | d |\n")
        XCTAssertTrue(isHidden(editor, 0..<2))
        XCTAssertTrue(isHidden(editor, 3..<6))
        XCTAssertTrue(isHidden(editor, 7..<9))
        XCTAssertTrue(isHidden(editor, 10..<20))
        XCTAssertEqual((editor.attribute(.plainPageTableRow, at: 0) as? PageTableRow)?.isHeader, true)
        XCTAssertEqual((editor.attribute(.plainPageTableRow, at: 20) as? PageTableRow)?.isHeader, false)
        XCTAssertTrue(editor.isBold(at: 2))
        XCTAssertEqual(editor.font(at: 22)?.pointSize, 14)
        XCTAssertEqual(lineHeight(editor, at: 20), 37)
    }

    // Turns red if a table wider than the column hides its pipes or loses its "Too wide to show as a table" note.
    func testPageWideTableStaysSource() async {
        let wide = String(repeating: "wide ", count: 60)
        let editor = await page("| \(wide) | b |\n|---|---|\n| c | d |\n")
        XCTAssertFalse(isHidden(editor, 0..<1))
        let lastRow = (editor.text as NSString).range(of: "| c").location
        XCTAssertEqual(editor.attribute(.plainPageNote, at: lastRow) as? String, "Too wide to show as a table")
    }

    // Turns red if table columns stop being as wide as their widest cell plus 10 pt padding each side, with the last
    // column taking what is left of the page column.
    func testPageTableColumnEdges() async {
        let editor = await page("| Name | b |\n|---|---|\n| x | y |\n")
        let table = editor.snapshot!.blocks[0]
        let columns = HiddenRanges.tableColumns(table: table, text: editor.nsText, columnWidth: 600)
        let name = NSAttributedString(string: "Name", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]).size().width
        XCTAssertFalse(columns.wide)
        XCTAssertEqual(columns.edges, [0, ceil(name + 20), 600])
    }

    // Turns red if a picture line on the page loses its alt-text caption or the caption's 8 + 21 pt below the picture.
    func testPageImageCaption() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 100, height: 50))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 50).fill()
        image.unlockFocus()
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            .write(to: folder.appendingPathComponent("photo.png"))
        let editor = await page("before\n\n![A view](photo.png)\n\nafter\n", url: folder.appendingPathComponent("doc.md"))
        _ = await waitUntil { editor.attribute(.plainOverlay, at: 8) != nil }
        XCTAssertEqual(editor.attribute(.plainPageCaption, at: 8) as? String, "A view")
        XCTAssertEqual(lineHeight(editor, at: 8), 50 + 2 * EditorTextView.imageSpacing + 8 + 21)
    }

    // Turns red if a page maths block stops rendering, or its picture stops being centred in the column.
    func testPageMathsCentred() async {
        let editor = await page("text\n\n$$\nx^2\n$$\n\nend\n")
        editor.setSelectedRange(NSRange(location: editor.text.utf16.count, length: 0))
        let rendered = await waitUntil(timeout: 10) { editor.attribute(.plainOverlay, at: 6) != nil }
        XCTAssertTrue(rendered)
        let overlay = editor.attribute(.plainOverlay, at: 6) as? OverlayImage
        XCTAssertEqual(overlay?.left ?? 0, ((editor.textContainer?.size.width ?? 0) - (overlay?.size.width ?? 0)) / 2, accuracy: 0.5)
    }

    // Turns red if a footnote reference shows its `[^1]` instead of a number, or a definition shows its label.
    func testPageFootnotes() async {
        let editor = await page("a[^1] b\n\n[^1]: note\n")
        XCTAssertTrue(isHidden(editor, 1..<5))
        XCTAssertEqual(editor.attribute(.plainPageFootnote, at: 1) as? String, "1")
        XCTAssertTrue(isHidden(editor, 9..<15))
        XCTAssertEqual((editor.attribute(.plainPageMarker, at: 9) as? PageMarker)?.kind, .footnote("1."))
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 15) as? NSColor, Tokens.page.textSecondary)
        XCTAssertEqual(editor.font(at: 15)?.pointSize, 14)
    }

    // Turns red if front matter away from the selection stops showing as key and value rows, or near it stops
    // showing its YAML.
    func testPageFrontMatterRows() async {
        let editor = await page("---\ntitle: Hi\n---\n\ntext\n")
        editor.setSelectedRange(NSRange(location: 23, length: 0))
        XCTAssertTrue(isHidden(editor, 0..<3))
        XCTAssertTrue(isHidden(editor, 9..<11))
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 4) as? NSColor, Tokens.page.textSecondary)
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 11) as? NSColor, Tokens.page.text)
        XCTAssertGreaterThan(editor.attribute(.kern, at: 9) as? CGFloat ?? 0, 0)
        XCTAssertFalse(editor.styler.frontMatterShownAsSource)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(editor.styler.frontMatterShownAsSource)
        XCTAssertFalse(isHidden(editor, 0..<3))
        XCTAssertNotNil(editor.attribute(.plainPagePanel, at: 0))
    }

    // Turns red if inline HTML, Liquid tags, emoji shortcodes or `{…}` attributes are hidden, or stop being drawn in
    // page-text-secondary.
    func testPageShownAsWrittenInSecondary() async {
        let editor = await page("a <b>x</b> {{ y }} :smile: z {.cls}\n")
        for offset in [2, 11, 19, 29] {
            XCTAssertFalse(isHidden(editor, offset..<(offset + 1)), "offset \(offset)")
            XCTAssertEqual(editor.attribute(.foregroundColor, at: offset) as? NSColor, Tokens.page.textSecondary, "offset \(offset)")
        }
    }

    // Turns red if a list inside a quote keeps either prefix visible.
    func testPageQuotedListHidesBothPrefixes() async {
        let editor = await page("> - x\n")
        XCTAssertTrue(isHidden(editor, 0..<4))
        XCTAssertFalse(isHidden(editor, 4..<5))
    }

    // Turns red if a nested item's lines get a continuation indent from the item above them.
    func testPageNestedItemHasNoParentIndent() async {
        let editor = await page("- a\n  - b\n")
        let ranges = HiddenRanges.list(in: NSRange(location: 0, length: editor.nsText.length), snapshot: editor.snapshot!,
                                       text: editor.nsText, columnWidth: editor.styler.pageColumnWidth, caret: nil)
        XCTAssertFalse(ranges.contains { $0.kind == .continuationIndent })
        XCTAssertTrue(ranges.contains { $0.kind == .blockPrefix && $0.range == NSRange(location: 4, length: 4) })
    }

    // Turns red if a setext underline holding the caret is hidden, so the caret sits in hidden characters.
    func testPageSetextUnderlineAtCaretStaysVisible() async {
        let editor = await page("Title\n")
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        await editor.type("---")
        XCTAssertEqual(editor.snapshot?.blocks.first?.kind, .setextHeading(level: 2))
        XCTAssertFalse(isHidden(editor, 6..<9))
        XCTAssertEqual(editor.attribute(.foregroundColor, at: 7) as? NSColor, Tokens.page.text)
    }

    // Turns red if the styler stops hearing about selection changes made while a parse is pending.
    func testPageSelectionsReachStylerWithoutSnapshot() async {
        let editor = await page("hello\n")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(editor.snapshot)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertEqual(editor.styler.pageSelections, [NSRange(location: 2, length: 0)])
    }
}
