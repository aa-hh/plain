import AppKit
import MarkdownDocument
import XCTest
@testable import EditorTextView

@MainActor
final class TypingHelperTests: XCTestCase {
    // Spec 102. Turns red if typing an opener stops inserting its closer.
    func testOpenerInsertsCloser() async {
        let editor = await makeEditor()
        await editor.set("a |")
        await editor.type("(")
        XCTAssertEqual(editor.marked, "a (|)")
        await editor.set("|")
        await editor.type("[")
        XCTAssertEqual(editor.marked, "[|]")
    }

    // Spec 103. Turns red if pairs are inserted before a letter, after `:` or for `*` without a selection.
    func testPairingConditions() async {
        let editor = await makeEditor()
        await editor.set("|a")
        await editor.type("(")
        XCTAssertEqual(editor.marked, "(|a")
        await editor.set("x :|")
        await editor.type("(")
        XCTAssertEqual(editor.marked, "x :(|")
        await editor.set("a |")
        await editor.type("*")
        XCTAssertEqual(editor.marked, "a *|")
        await editor.set("don|")
        await editor.type("'")
        XCTAssertEqual(editor.marked, "don'|")
        await editor.set("«word»")
        await editor.type("*")
        XCTAssertEqual(editor.marked, "*«word»*")
    }

    // Spec 104 and 116. Turns red if retyping a selected marker stops changing both markers of the element.
    func testRetypeSelectedMarker() async {
        let editor = await makeEditor()
        await editor.set("«**»a** b")
        await editor.type("_")
        XCTAssertEqual(editor.text, "__a__ b")
    }

    // Spec 105. Turns red if a typed closer is inserted instead of stepping over the same character.
    func testStepOverCloser() async {
        let editor = await makeEditor()
        await editor.set("(a|)")
        await editor.type(")")
        XCTAssertEqual(editor.marked, "(a)|")
        await editor.set("\\|)")
        await editor.type(")")
        XCTAssertEqual(editor.text, "\\))")
    }

    // Spec 106. Turns red if `*` inside emphasis stops stepping over the closing `*`.
    func testStepOverMarkdownMarker() async {
        let editor = await makeEditor()
        await editor.set("x *ab|* y")
        await editor.type("*")
        XCTAssertEqual(editor.marked, "x *ab*| y")
    }

    // Spec 107. Turns red if Backspace in an empty pair deletes only one character.
    func testBackspaceDeletesEmptyPair() async {
        let editor = await makeEditor()
        await editor.set("a (|) b")
        await editor.backspace()
        XCTAssertEqual(editor.marked, "a | b")
        await editor.set("\\(|)")
        await editor.backspace()
        XCTAssertEqual(editor.text, "\\)")
    }

    // Spec 108. Turns red if `~` or `:` over a selection stops wrapping it, or wraps text with no letters.
    func testWrapSelectionWithTildeAndColon() async {
        let editor = await makeEditor()
        await editor.set("a «word » b")
        await editor.type("~")
        XCTAssertEqual(editor.marked, "a ~~«word»~~  b")
        await editor.set("«mark»")
        await editor.type(":")
        XCTAssertEqual(editor.text, "::mark::")
        await editor.set("«?!»")
        await editor.type(":")
        XCTAssertEqual(editor.text, ":")
    }

    // Spec 109. Turns red if a letter typed after a lone opener stops adding the closer.
    func testCompletesBoldOpener() async {
        let editor = await makeEditor()
        await editor.set("a **|")
        await editor.type("b")
        XCTAssertEqual(editor.marked, "a **b|**")
        await editor.set("(_|")
        await editor.type("x")
        XCTAssertEqual(editor.marked, "(_x|_")
    }

    // Spec 110. Turns red if typing a fence on its own line stops adding the closing fence.
    func testTypedFenceAddsClosingFence() async {
        let editor = await makeEditor()
        await editor.set("text\n\n|")
        await editor.type("```")
        XCTAssertEqual(editor.marked, "text\n\n```|\n```")
    }

    // Spec 111. Turns red if Enter on an unclosed fence stops adding the closing fence.
    func testEnterClosesOpenFence() async {
        let editor = await makeEditor()
        await editor.set("```js|")
        await editor.enter()
        XCTAssertEqual(editor.marked, "```js\n|\n```")
    }

    // Spec 112. Turns red if Enter between braces stops indenting and moving the closer to its own line.
    func testEnterBetweenBraces() async {
        let editor = await makeEditor()
        await editor.set("f {|}")
        await editor.enter()
        XCTAssertEqual(editor.marked, "f {\n  |\n}")
    }

    // Spec 113. Turns red if Tab inside an inline element stops jumping to its end, or to the URL from link text.
    func testTabJumpsOutOfInline() async {
        let editor = await makeEditor()
        await editor.set("x *a|b* y")
        await editor.tab()
        XCTAssertEqual(editor.marked, "x *ab*| y")
        await editor.set("[te|xt](url) z")
        await editor.tab()
        XCTAssertEqual(editor.marked, "[text](|url) z")
        await editor.tab()
        XCTAssertEqual(editor.marked, "[text](url)| z")
        await editor.set("x *a|b* y")
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.marked, "x |*ab* y")
    }

    // Spec 114. Turns red if Tab stops indenting to the next 2-space stop, Shift+Tab stops outdenting, or Backspace
    // in leading spaces stops deleting two.
    func testTabIndentsAndBackspaceDeletesTwoSpaces() async {
        let editor = await makeEditor()
        await editor.set("ab|")
        await editor.tab()
        XCTAssertEqual(editor.marked, "  ab|")
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.marked, "ab|")
        await editor.set("    |x")
        await editor.backspace()
        XCTAssertEqual(editor.marked, "  |x")
    }

    // Spec 115. Turns red if Home stops going to the first non-space character first.
    func testHomeGoesToTextThenLineStart() async {
        let editor = await makeEditor()
        await editor.set("  ab|")
        editor.moveToBeginningOfLine(nil)
        XCTAssertEqual(editor.marked, "  |ab")
        editor.moveToBeginningOfLine(nil)
        XCTAssertEqual(editor.marked, "|  ab")
    }

    // Spec 89–90. Turns red if typing in a heading's marker stops jumping past it, or `#` stops raising the level.
    func testTypingInHeadingMarker() async {
        let editor = await makeEditor()
        await editor.set("#|# Title")
        await editor.type("#")
        XCTAssertEqual(editor.text, "### Title")
        await editor.set("#|# Title")
        await editor.type("x")
        XCTAssertEqual(editor.marked, "## x|Title")
    }

    // Spec 91. Turns red if Backspace in a heading marker stops removing one `#`, or the whole marker at level 1.
    func testBackspaceInHeadingMarker() async {
        let editor = await makeEditor()
        await editor.set("### |Title")
        await editor.backspace()
        XCTAssertEqual(editor.marked, "## |Title")
        await editor.set("# |Title")
        await editor.backspace()
        XCTAssertEqual(editor.marked, "|Title")
    }

    // Spec 92. Turns red if Enter at the end of a setext underline stops matching it to the heading's length.
    func testSetextUnderlineRewritten() async {
        let editor = await makeEditor()
        await editor.set("Heading\n===|")
        await editor.enter()
        XCTAssertEqual(editor.marked, "Heading\n=======\n|")
    }

    // MARK: Page

    private func page(_ text: String) async -> EditorTextView { await makeEditor(text, configuration: EditorConfiguration()) }

    private func isHidden(_ editor: EditorTextView, _ offset: Int) -> Bool { (editor.font(at: offset)?.pointSize ?? 99) < 0.1 }

    // Spec 2. Turns red if `## ` or `- ` typed at a line start stay visible once the parse lands.
    func testPageTypedPrefixesHide() async {
        let heading = await page("")
        await heading.type("## Head")
        XCTAssertTrue(isHidden(heading, 0) && isHidden(heading, 2))
        let list = await page("")
        await list.type("- item")
        XCTAssertTrue(isHidden(list, 0) && isHidden(list, 1))
        XCTAssertNotNil(list.attribute(.plainPageMarker, at: 0))
    }

    // Settled decision 11. Turns red if `- ` typed under a paragraph stops getting a blank line above, so it stays a
    // setext underline or paragraph text instead of a list.
    func testPageListMarkerUnderParagraph() async {
        let editor = await page("para\n")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        await editor.type("- ")
        XCTAssertEqual(editor.marked, "para\n\n- |")
        XCTAssertEqual(editor.snapshot?.blocks.last?.kind, .bulletList)
    }

    // Turns red if the page typing rules (`listMarkerUnderParagraph` here) stop checking `isMarkdownFile`, so a plain
    // text file gets a blank line added above `- `.
    func testPageListMarkerUnderParagraphSkipsTextFiles() async {
        let editor = await makeEditor("Groceries\n", url: URL(fileURLWithPath: "/tmp/groceries.txt"), configuration: EditorConfiguration())
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        await editor.type("- ")
        XCTAssertEqual(editor.text, "Groceries\n- ")
    }

    // Spec 2. Turns red if `---` then Return under a paragraph makes a setext heading instead of a divider.
    func testPageDividerUnderParagraph() async {
        let editor = await page("para\n")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        await editor.type("---")
        await editor.enter()
        XCTAssertEqual(editor.marked, "para\n\n---\n|")
    }

    // Spec 2. Turns red if the page adds closing markers while `**b**` is typed.
    func testPageNoAutoCloserForBold() async {
        let editor = await page("")
        await editor.type("**b**")
        XCTAssertEqual(editor.text, "**b**")
        XCTAssertTrue(editor.isBold(at: 2))
    }

    // A15 rule 1. Turns red if Backspace at a block's visible start stops removing its whole hidden prefix, putting a
    // line break in its place when the line above has text.
    func testPageBackspaceRemovesBlockPrefix() async {
        let item = await page("para\n- item")
        item.setSelectedRange(NSRange(location: 7, length: 0))
        await item.backspace()
        XCTAssertEqual(item.marked, "para\n\n|item")
        let spaced = await page("para\n\n- item")
        spaced.setSelectedRange(NSRange(location: 8, length: 0))
        await spaced.backspace()
        XCTAssertEqual(spaced.marked, "para\n\n|item")
        let heading = await page("## Head")
        heading.setSelectedRange(NSRange(location: 3, length: 0))
        await heading.backspace()
        XCTAssertEqual(heading.marked, "|Head")
    }

    // A15 rule 2. Turns red if Backspace at the start of an item's continuation line stops joining it to the line above.
    func testPageBackspaceJoinsContinuationLine() async {
        let editor = await page("- a\n  b")
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        await editor.backspace()
        XCTAssertEqual(editor.marked, "- a|b")
    }

    // A15 rule 3. Turns red if Backspace after a separator stops joining paragraphs, deleting a divider above, or
    // stepping the caret back past a code block's closing fence.
    func testPageBackspaceAfterSeparator() async {
        let paragraphs = await page("para\n\nnext")
        paragraphs.setSelectedRange(NSRange(location: 6, length: 0))
        await paragraphs.backspace()
        XCTAssertEqual(paragraphs.marked, "para|next")
        let divider = await page("a\n\n---\n\nb")
        divider.setSelectedRange(NSRange(location: 8, length: 0))
        await divider.backspace()
        XCTAssertEqual(divider.marked, "a\n\n|b")
        let code = await page("```\nx\n```\n\nnext")
        code.setSelectedRange(NSRange(location: 11, length: 0))
        await code.backspace()
        XCTAssertEqual(code.marked, "```\nx|\n```\n\nnext")
    }

    // A15 rules 4 and 5. Turns red if Backspace after a divider stops deleting it, or Backspace at a table cell's or a
    // code block's first character deletes hidden table or fence syntax.
    func testPageBackspaceAtDividerCellAndFence() async {
        let divider = await page("a\n\n---\nb")
        divider.setSelectedRange(NSRange(location: 7, length: 0))
        await divider.backspace()
        XCTAssertEqual(divider.marked, "a\n\n|b")
        let table = await page("| a | b |\n|---|---|\n| c | d |")
        table.setSelectedRange(NSRange(location: 22, length: 0))
        await table.backspace()
        XCTAssertEqual(table.text, "| a | b |\n|---|---|\n| c | d |")
        let code = await page("```\nx\n```")
        code.setSelectedRange(NSRange(location: 4, length: 0))
        await code.backspace()
        XCTAssertEqual(code.text, "```\nx\n```")
    }

    // A15 rules 6 and 7. Turns red if Backspace after a footnote number stops deleting the whole reference, or after
    // hidden markers stops deleting the visible character before them (the whole inline when it was the last one).
    func testPageBackspaceAfterReferenceAndMarkers() async {
        let footnote = await page("a[^1] b\n\n[^1]: note")
        footnote.setSelectedRange(NSRange(location: 5, length: 0))
        await footnote.backspace()
        XCTAssertEqual(footnote.text, "a b\n\n[^1]: note")
        let bold = await page("**bold**")
        bold.setSelectedRange(NSRange(location: 8, length: 0))
        await bold.backspace()
        XCTAssertEqual(bold.text, "**bol**")
        let single = await page("**b** x")
        single.setSelectedRange(NSRange(location: 5, length: 0))
        await single.backspace()
        XCTAssertEqual(single.text, " x")
    }

    // A15. Turns red if a Backspace made while a parse is pending stops using the last snapshot's ranges before the edit.
    func testPageBackspaceWithPendingParse() async {
        let editor = await page("## Head\n\nmore")
        editor.setSelectedRange(NSRange(location: 13, length: 0))
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(editor.snapshot)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.text, "Head\n\nmorex")
    }

    // Addendum 1. Turns red if an out-of-date snapshot resets the lowest unparsed edit, so Backspace trusts hidden
    // ranges that lie after an edit the snapshot does not contain.
    func testPageBackspaceIgnoresRangesAfterUnparsedEdit() async {
        let original = "0123456789 abcdefghijklmnopq\n\n## Head\n\nzzzzzzzzzzzzzzzzzzzz end\n"
        let editor = await page(original)
        let other = MarkdownDocument(text: original)
        _ = other.apply(TextEdit(range: NSRange(location: 10, length: 0), replacement: "A"))
        let stale = await other.snapshot(atLeast: TextVersion(rawValue: 1))
        let storage = editor.document.textStorage
        storage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "A")
        storage.replaceCharacters(in: NSRange(location: 50, length: 0), with: "B")
        editor.received(stale, initial: false)
        XCTAssertNil(editor.snapshot)
        XCTAssertEqual(editor.lowestEditSinceApplied, 10)
        let prefixEnd = (editor.text as NSString).range(of: "## ").location + 3
        editor.setSelectedRange(NSRange(location: prefixEnd, length: 0))
        editor.deleteBackward(nil)
        XCTAssertTrue(editor.text.contains("\n# Head"), editor.text)
    }

    // A16. Turns red if Cmd+B at an empty caret stops waiting for the next characters, so `ab` is not typed bold.
    func testPageBoldAtCaretWrapsWhatIsTyped() async {
        let editor = await page("")
        await editor.command("editor:bold")
        await editor.type("ab")
        XCTAssertEqual(editor.marked, "**ab|**")
    }
}
