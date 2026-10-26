import AppKit
import XCTest
@testable import EditorTextView

@MainActor
final class FormatCommandTests: XCTestCase {
    /// A private pasteboard, so other processes and test runs cannot change it mid-test.
    let board = NSPasteboard(name: NSPasteboard.Name("plain-tests-\(UUID().uuidString)"))

    override func tearDown() async throws {
        board.releaseGlobally()
    }

    func makeEditor(_ text: String = "", url: URL? = nil,
                    configuration: EditorConfiguration = EditorConfiguration(showMarkdownSource: true)) async -> EditorTextView {
        let editor = await EditorTextViewTests.makeEditor(text, url: url, configuration: configuration)
        editor.pasteboard = board
        return editor
    }

    // Spec 160. Turns red if Bold stops wrapping the word at the caret or stops removing markers inside bold text.
    func testBoldWrapsWordAndUnwraps() async {
        let editor = await makeEditor()
        await editor.set("a wo|rd b")
        await editor.command("editor:bold")
        XCTAssertEqual(editor.marked, "a **wo|rd** b")
        await editor.command("editor:bold")
        XCTAssertEqual(editor.marked, "a wo|rd b")
        await editor.set("«x y»")
        await editor.command("editor:italic")
        XCTAssertEqual(editor.marked, "_«x y»_")
        await editor.set("«x»")
        await editor.command("editor:code")
        XCTAssertEqual(editor.text, "`x`")
    }

    // Spec 161. Turns red if Link stops building `[text]()` with the caret in the URL, or a selected URL stops
    // becoming the link target.
    func testLink() async {
        let editor = await makeEditor()
        await editor.set("«text»")
        await editor.command("editor:link")
        XCTAssertEqual(editor.marked, "[text](|)")
        await editor.set("«https://a.b»")
        await editor.command("editor:link")
        XCTAssertEqual(editor.marked, "[|](https://a.b)")
        await editor.set("[te|xt](u)")
        await editor.command("editor:link")
        XCTAssertEqual(editor.text, "text")
        board.clearContents()
        board.setString("https://c.d/pic.png", forType: .string)
        await editor.set("«pic»")
        await editor.command("editor:link")
        XCTAssertEqual(editor.marked, "![pic](https://c.d/pic.png)|")
    }

    // Spec 162. Turns red if Image stops building `![…](…)`.
    func testImage() async {
        let editor = await makeEditor()
        await editor.set("«alt»")
        await editor.command("editor:image")
        XCTAssertEqual(editor.marked, "![alt](|)")
    }

    // Spec 163. Turns red if Code Block stops wrapping lines in fences or stops removing them inside a block.
    func testCodeBlockWrapsAndUnwraps() async {
        let editor = await makeEditor()
        await editor.set("«a\nb»")
        await editor.command("editor:code-block")
        XCTAssertEqual(editor.text, "```\na\nb\n```")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        await editor.command("editor:code-block")
        XCTAssertEqual(editor.text, "a\nb")
        await editor.set("«x»")
        await editor.command("editor:math-block")
        XCTAssertEqual(editor.text, "$$$\nx\n$$$")
    }

    // Spec 164–165. Turns red if the table of contents stops going at the top or breaks stop following the block.
    func testTocAndBreaks() async {
        let editor = await makeEditor()
        await editor.set("para|\n")
        await editor.command("editor:table-of-contents")
        XCTAssertEqual(editor.text, "[[toc]]\n\npara\n")
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        await editor.command("editor:thematic-break")
        XCTAssertEqual(editor.text, "[[toc]]\n\npara\n\n---\n")
        await editor.command("editor:page-break")
        XCTAssertEqual(editor.text, "[[toc]]\n\npara\n\n---\n\n+++\n")
    }

    // Spec 166. Turns red if Comment stops wrapping lines in `<!-- -->` or stops unwrapping them.
    func testComment() async {
        let editor = await makeEditor()
        await editor.set("«note»")
        await editor.command("editor:comment")
        XCTAssertEqual(editor.text, "<!-- note -->")
        await editor.command("editor:comment")
        XCTAssertEqual(editor.text, "note")
    }

    // Spec 167. Turns red if Clear Syntax stops deleting the markers of the element at the caret.
    func testClearSyntax() async {
        let editor = await makeEditor()
        await editor.set("a **b _c|_** d")
        await editor.command("editor:clear-syntax")
        XCTAssertEqual(editor.text, "a b c d")
    }

    // Spec 168. Turns red if pasting a URL over selected text stops making a link.
    func testPasteURLOverSelection() async {
        let editor = await makeEditor()
        await editor.set("see «docs» now")
        board.clearContents()
        board.setString("https://x.y", forType: .string)
        editor.paste(nil)
        await editor.settle()
        XCTAssertEqual(editor.text, "see [docs](https://x.y) now")
    }

    // Spec 172. Turns red if Cut with no selection stops cutting the whole line.
    func testCutWholeLine() async {
        let editor = await makeEditor()
        await editor.set("one\ntw|o\nthree")
        editor.cut(nil)
        await editor.settle()
        XCTAssertEqual(editor.text, "one\nthree")
        XCTAssertEqual(board.string(forType: .string), "two\n")
    }

    // Spec 93. Turns red if Heading 2 stops toggling the marker on the selected lines.
    func testHeadingToggle() async {
        let editor = await makeEditor()
        await editor.set("ti|tle")
        await editor.command("editor:heading2")
        XCTAssertEqual(editor.text, "## title")
        await editor.command("editor:heading2")
        XCTAssertEqual(editor.text, "title")
        await editor.set("- it|em")
        await editor.command("editor:heading1")
        XCTAssertEqual(editor.text, "# item")
    }

    // Spec 171. Turns red if a pasted image stops being saved as a PNG in `.pastes` and linked.
    func testPasteImageSavesFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let editor = await makeEditor("", url: folder.appendingPathComponent("doc.md"))
        editor.actions.pasteFolder = { folder.appendingPathComponent(".pastes") }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        board.clearContents()
        board.writeObjects([image])
        editor.paste(nil)
        await editor.settle()
        XCTAssertTrue(editor.text.hasPrefix("![](.pastes/"), editor.text)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".pastes").path)
        XCTAssertEqual(files.count, 1)
        editor.paste(nil)
        let again = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".pastes").path)
        XCTAssertEqual(again.count, 1, "an identical image should reuse the file")
    }

    // MARK: Page

    private func page(_ text: String) async -> EditorTextView { await makeEditor(text, configuration: EditorConfiguration()) }

    private func plain(_ text: String) async -> String {
        let editor = await page(text)
        return VisibleText.plain(text: editor.nsText, snapshot: editor.snapshot!, range: NSRange(location: 0, length: editor.nsText.length),
                                 columnWidth: editor.styler.pageColumnWidth)
    }

    // Spec 4. Turns red if the visible text of any block keeps Markdown or loses the bullets, boxes, tabs and numbers.
    func testVisibleTextPerBlock() async {
        let cases: [(String, String)] = [
            ("# Head", "Head"),
            ("Title\n---", "Title"),
            ("Some **bold**, _it_, ~~x~~, `c`, ::h:: and [link](u) text.", "Some bold, it, x, c, h and link text."),
            ("- a\n  - b", "• a\n\t• b"),
            ("- [ ] b\n- [x] c", "☐ b\n☑ c"),
            ("1. d\n2. e", "1. d\n2. e"),
            ("> quote", "quote"),
            ("```swift\nlet x\n```", "let x"),
            ("| a | b |\n|---|---|\n| c | d |", "a\tb\nc\td"),
            ("para\n\nnext", "para\n\nnext"),
            ("a\n\n---\n\nb", "a\n\n\nb"),
            ("![alt](p.png)", "alt"),
            ("---\ntitle: x\n---\n\ntext", "title: x\n\ntext"),
            ("$$\nx^2\n$$", "x^2"),
            ("a[^1]\n\n[^1]: n", "a1\n\n1. n"),
        ]
        for (markdown, expected) in cases {
            let result = await plain(markdown)
            XCTAssertEqual(result, expected, markdown)
        }
    }

    // Spec 4. Turns red if page Copy stops writing plain text plus Plain's Markdown type, or Paste stops preferring it.
    func testPageCopyThenPasteKeepsMarkdown() async {
        let editor = await page("a **bold** b")
        editor.setSelectedRange(NSRange(location: 2, length: 8))
        editor.copy(nil)
        XCTAssertEqual(board.string(forType: .string), "bold")
        XCTAssertEqual(board.string(forType: EditorTextView.markdownPasteboardType), "**bold**")
        editor.setSelectedRange(NSRange(location: 12, length: 0))
        editor.paste(nil)
        await editor.settle()
        XCTAssertEqual(editor.text, "a **bold** b**bold**")
    }

    // Spec 4. Turns red if `paste` reads Plain's own Markdown type only on the page, so a page copy pasted into the
    // source view loses its markers.
    func testPageCopyPastedIntoSourceKeepsMarkdown() async {
        let editor = await page("**b**")
        editor.setSelectedRange(NSRange(location: 0, length: 5))
        editor.copy(nil)
        XCTAssertEqual(board.string(forType: .string), "b")
        let source = await makeEditor("")
        source.paste(nil)
        await source.settle()
        XCTAssertEqual(source.text, "**b**")
    }

    // Spec 4. Turns red if copying part of a styled run writes unbalanced Markdown, or part of a link keeps its syntax.
    func testPagePartialCopyIsBalanced() async {
        let editor = await page("**bold** and [here](u)")
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        editor.copy(nil)
        XCTAssertEqual(board.string(forType: EditorTextView.markdownPasteboardType), "**ol**")
        editor.setSelectedRange(NSRange(location: 15, length: 2))
        editor.copy(nil)
        XCTAssertEqual(board.string(forType: EditorTextView.markdownPasteboardType), "er")
    }

    // States and limits. Turns red if Find on the page stops matching the visible text across hidden markers.
    func testPageFindMatchesVisibleText() async {
        let editor = await page("a **bold** text")
        editor.openFind()
        editor.findQueryChanged("bold text")
        XCTAssertEqual(editor.find?.matches, [NSRange(location: 4, length: 11)])
        editor.closeFind()
    }

    // Spec 3. Turns red if Turn into stops writing each kind's prefix, fences or quote markers, or takes more than one
    // undo step.
    func testPageTurnIntoEachKind() async {
        let expected: [String] = ["hello", "# hello", "## hello", "### hello", "- hello", "1. hello", "- [ ] hello", "> hello", "```\nhello\n```"]
        for (kind, result) in zip(PageBlockKind.turnIntoKinds, expected) {
            let editor = await page("hello")
            let block = editor.pageBlocks()[0]
            let change = PageBlocks.turnInto(block, to: kind, text: editor.nsText)
            editor.apply(change.edits, caret: change.caret)
            await editor.settle()
            XCTAssertEqual(editor.text, result, kind.title)
            editor.undoManager?.undo()
            await editor.settle()
            XCTAssertEqual(editor.text, "hello", kind.title)
        }
        let heading = await page("## hello")
        let change = PageBlocks.turnInto(heading.pageBlocks()[0], to: .bulleted, text: heading.nsText)
        heading.apply(change.edits, caret: change.caret)
        await heading.settle()
        XCTAssertEqual(heading.text, "- hello")
        let code = await page("```\nhello\n```")
        let back = PageBlocks.turnInto(code.pageBlocks()[0], to: .text, text: code.nsText)
        code.apply(back.edits, caret: back.caret)
        await code.settle()
        XCTAssertEqual(code.text, "hello")
    }

    // Spec 3. Turns red if `PageBlocks.turnInto` keeps a setext heading's `---` underline, so the block stays a heading.
    func testPageTurnIntoSetextHeadingDropsUnderline() async {
        for (kind, result) in [(PageBlockKind.text, "Title"), (.heading(1), "# Title"), (.bulleted, "- Title")] {
            let editor = await page("Title\n---")
            XCTAssertEqual(editor.pageBlocks().first?.kind, .heading(2))
            let change = PageBlocks.turnInto(editor.pageBlocks()[0], to: kind, text: editor.nsText)
            XCTAssertEqual(change.edits.count, 1)
            editor.apply(change.edits, caret: change.caret)
            await editor.settle()
            XCTAssertEqual(editor.text, result, kind.title)
        }
    }

    // Spec 3. Turns red if a `/` menu insertion stops writing its kind's Markdown with blank lines kept around it, or
    // takes more than one undo step.
    func testPageInsertEachKind() async {
        let bodies = ["", "# ", "## ", "### ", "- ", "1. ", "- [ ] ", "> ", "```\n\n```", "|   |   |\n|---|---|\n|   |   |", "---\n",
                      "![photo](photo.png)", "$$\n\n$$"]
        for (kind, body) in zip(PageBlockKind.slashKinds, bodies) {
            let editor = await page("above\n/\nbelow")
            let change = PageBlocks.insert(kind, replacing: NSRange(location: 6, length: 1), text: editor.nsText,
                                           image: kind == .image ? ("photo", "photo.png") : nil)
            editor.apply(change.edits, caret: change.caret)
            await editor.settle()
            XCTAssertEqual(editor.text, "above\n\n" + body + "\n\nbelow", kind.title)
            editor.undoManager?.undo()
            await editor.settle()
            XCTAssertEqual(editor.text, "above\n/\nbelow", kind.title)
        }
    }

    // MARK: Selection toolbar and link editor

    // Selection toolbar. Turns red if a style's active state stops skipping hidden markers and spaces, or the toolbar
    // stops opening for one mouse selection and closing when the selection changes.
    func testToolbarActiveStates() async {
        let editor = await page("a **b c** d")
        XCTAssertTrue(editor.styleActive(.bold, in: NSRange(location: 4, length: 3)))
        XCTAssertTrue(editor.styleActive(.bold, in: NSRange(location: 2, length: 7)))
        XCTAssertTrue(editor.styleActive(.bold, in: NSRange(location: 1, length: 9)))
        XCTAssertFalse(editor.styleActive(.bold, in: NSRange(location: 0, length: 11)))
        XCTAssertFalse(editor.styleActive(.bold, in: NSRange(location: 0, length: 1)))
        XCTAssertFalse(editor.styleActive(.italic, in: NSRange(location: 4, length: 3)))
        editor.setSelectedRange(NSRange(location: 4, length: 3))
        editor.selectionToolbarAfterMouseUp()
        XCTAssertNotNil(editor.selectionToolbar.toolbar)
        XCTAssertEqual(editor.selectionToolbar.model.active, [.bold])
        XCTAssertEqual(editor.selectionToolbar.model.title, "Text")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(editor.selectionToolbar.toolbar)
    }

    // Selection toolbar. Turns red if Bold over a mixed selection stops wrapping it with the inner markers removed, Bold
    // over a bold selection stops unwrapping it, or either takes more than one undo step.
    func testToolbarTogglesBold() async {
        let editor = await page("a **b** c")
        editor.setSelectedRange(NSRange(location: 0, length: 9))
        editor.selectionToolbarAfterMouseUp()
        editor.selectionToolbarClicked(.bold)
        await editor.settle()
        XCTAssertEqual(editor.marked, "**«a b c»**")
        XCTAssertNotNil(editor.selectionToolbar.toolbar)
        XCTAssertEqual(editor.selectionToolbar.model.active, [.bold])
        editor.selectionToolbarClicked(.bold)
        await editor.settle()
        XCTAssertEqual(editor.marked, "«a b c»")
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "**a b c**")
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "a **b** c")
    }

    // Selection toolbar. Turns red if turning a style off in the middle of a styled run stops keeping markers around the
    // parts outside the selection, or takes more than one undo step.
    func testToolbarSplitsStyleAroundSelection() async {
        let editor = await page("**abcdef**")
        editor.setSelectedRange(NSRange(location: 4, length: 2))
        editor.selectionToolbarAfterMouseUp()
        editor.selectionToolbarClicked(.bold)
        await editor.settle()
        XCTAssertEqual(editor.marked, "**ab**«cd»**ef**")
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "**abcdef**")
    }

    // Selection toolbar. Turns red if the kind picker stops turning every text block the selection touches, starts
    // rewriting a touched divider, or takes more than one undo step.
    func testToolbarTurnsTouchedBlocksInto() async {
        let editor = await page("one\n\ntwo")
        editor.setSelectedRange(NSRange(location: 1, length: 6))
        editor.selectionToolbarAfterMouseUp()
        editor.selectionToolbarTurnInto(.heading(2))
        await editor.settle()
        XCTAssertEqual(editor.text, "## one\n\n## two")
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "one\n\ntwo")

        let divider = await page("one\n\n---")
        divider.setSelectedRange(NSRange(location: 0, length: divider.nsText.length))
        divider.selectionToolbarAfterMouseUp()
        divider.selectionToolbarTurnInto(.heading(2))
        await divider.settle()
        XCTAssertEqual(divider.text, "## one\n\n---")
    }

    // Selection toolbar. Turns red if the picker's set of blocks that can be turned (`PageBlockKind.canTurnInto`) leaves
    // out headings 4 to 6.
    func testToolbarTurnsSmallHeadingIntoText() async {
        let editor = await page("#### Small")
        editor.setSelectedRange(NSRange(location: 5, length: 5))
        editor.selectionToolbarAfterMouseUp()
        editor.selectionToolbarTurnInto(.text)
        await editor.settle()
        XCTAssertEqual(editor.text, "Small")
    }

    // Link editor. Turns red if Return stops wrapping the selection, replacing a link's target, removing a link when the
    // field is empty or inserting a bare link at a caret, or any of these takes more than one undo step.
    func testLinkEditorWrapsReplacesAndRemoves() async {
        let editor = await page("see text now")
        let field = editor.selectionToolbar.linkField
        editor.setSelectedRange(NSRange(location: 4, length: 4))
        editor.openLinkEditor()
        XCTAssertEqual(field.stringValue, "")
        field.stringValue = "https://a.b"
        editor.linkEditorCommit()
        await editor.settle()
        XCTAssertEqual(editor.text, "see [text](https://a.b) now")
        XCTAssertNil(editor.selectionToolbar.linkEditor)
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "see text now")

        await editor.set("[te|xt](u)")
        editor.openLinkEditor()
        XCTAssertEqual(field.stringValue, "u")
        field.stringValue = "v"
        editor.linkEditorCommit()
        await editor.settle()
        XCTAssertEqual(editor.text, "[text](v)")

        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.openLinkEditor()
        field.stringValue = ""
        editor.linkEditorCommit()
        await editor.settle()
        XCTAssertEqual(editor.text, "text")
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "[text](v)")

        await editor.set("a |")
        editor.openLinkEditor()
        field.stringValue = "https://x.y"
        editor.linkEditorCommit()
        await editor.settle()
        XCTAssertEqual(editor.text, "a [https://x.y](https://x.y)")
    }

    // Link editor. Turns red if replacing a link's address in `commitLink` drops the link's title.
    func testLinkEditorKeepsTitle() async {
        let editor = await page("[t](old \"T\")")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.openLinkEditor()
        XCTAssertEqual(editor.selectionToolbar.linkField.stringValue, "old")
        editor.selectionToolbar.linkField.stringValue = "new"
        editor.linkEditorCommit()
        await editor.settle()
        XCTAssertEqual(editor.text, "[t](new \"T\")")
    }

    // Link editor. Turns red if the URL field taking focus makes the editor close its page tools.
    func testLinkFieldFocusKeepsEditorOpen() async {
        let editor = await page("see text now")
        editor.setSelectedRange(NSRange(location: 4, length: 4))
        editor.openLinkEditor()
        let field = editor.selectionToolbar.linkField
        XCTAssertTrue(editor.window?.makeFirstResponder(field) ?? false)
        XCTAssertTrue((editor.window?.firstResponder as? NSView)?.isDescendant(of: editor) ?? false)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(editor.selectionToolbar.linkEditor)
    }
}
