import AppKit
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
}
