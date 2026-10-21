import AppKit
import XCTest
@testable import EditorTextView

@MainActor
final class ListEditingTests: XCTestCase {
    // Spec 125–126. Turns red if Enter stops repeating a line's pattern, incrementing numbers or unchecking boxes.
    func testEnterContinuesPatterns() async {
        let editor = await makeEditor()
        await editor.set("- a|")
        await editor.enter()
        XCTAssertEqual(editor.marked, "- a\n- |")
        await editor.set("1. a|")
        await editor.enter()
        XCTAssertEqual(editor.marked, "1. a\n2. |")
        await editor.set("- [x] done|")
        await editor.enter()
        XCTAssertEqual(editor.marked, "- [x] done\n- [ ] |")
        await editor.set("> quote|")
        await editor.enter()
        XCTAssertEqual(editor.marked, "> quote\n> |")
        await editor.set("// one\n// two|")
        await editor.enter()
        XCTAssertEqual(editor.marked, "// one\n// two\n// |")
    }

    // Spec 126. Turns red if a list of all `1.` items stops keeping `1.`.
    func testAllOnesListKeepsOne() async {
        let editor = await makeEditor()
        await editor.set("1. a\n1. b|")
        await editor.enter()
        XCTAssertEqual(editor.marked, "1. a\n1. b\n1. |")
    }

    // Spec 127. Turns red if Enter on an empty item stops clearing it, or stops outdenting to the parent's pattern.
    func testEnterOnEmptyItem() async {
        let editor = await makeEditor()
        await editor.set("- a\n- |")
        await editor.enter()
        XCTAssertEqual(editor.marked, "- a\n|")
        await editor.set("- a\n  - |")
        await editor.enter()
        XCTAssertEqual(editor.marked, "- a\n- |")
    }

    // Spec 128. Turns red if Esc on a pattern-only line stops deleting the pattern.
    func testEscapeClearsEmptyItem() async {
        let editor = await makeEditor()
        await editor.set("- a\n- |")
        editor.cancelOperation(nil)
        XCTAssertEqual(editor.marked, "- a\n|")
    }

    // Spec 129. Turns red if `[] ` on an empty line stops becoming a task item.
    func testBracketsBecomeTask() async {
        let editor = await makeEditor()
        await editor.set("[]|")
        await editor.type(" ")
        XCTAssertEqual(editor.marked, "- [ ] |")
    }

    // Spec 130. Turns red if `x` or space inside a task box stops checking or unchecking it.
    func testTypingInTaskBox() async {
        let editor = await makeEditor()
        await editor.set("- [|] a")
        await editor.type("x")
        XCTAssertEqual(editor.marked, "- [x|] a")
        await editor.set("- [|x] a")
        await editor.type(" ")
        XCTAssertEqual(editor.marked, "- [ |] a")
    }

    // Spec 131. Turns red if Tab on a list line stops taking the deeper level's pattern from nearby lines.
    func testTabTakesDeeperLevelPattern() async {
        let editor = await makeEditor()
        await editor.set("- a\n  * b\n- c|")
        await editor.tab()
        XCTAssertEqual(editor.text, "- a\n  * b\n  * c")
        editor.insertBacktab(nil)
        await editor.settle()
        XCTAssertEqual(editor.text, "- a\n  * b\n- c")
    }

    // Spec 132. Turns red if ordered items stop renumbering after Enter in the middle of a list.
    func testRenumberAfterEnter() async {
        let editor = await makeEditor()
        await editor.set("1. a|\n2. b\n3. c")
        await editor.enter()
        XCTAssertEqual(editor.marked, "1. a\n2. |\n3. b\n4. c")
    }

    // Spec 133. Turns red if pasting text that repeats the line's pattern stops dropping the duplicate.
    func testPasteDropsDuplicatePrefix() async {
        let editor = await makeEditor()
        await editor.set("- |")
        editor.paste(text: "- item")
        await editor.settle()
        XCTAssertEqual(editor.marked, "- item|")
    }

    // Spec 135. Turns red if Format › List stops toggling markers on the selected lines or Ordered List stops numbering.
    func testFormatListToggles() async {
        let editor = await makeEditor()
        await editor.set("«a\nb»")
        await editor.command("editor:list")
        XCTAssertEqual(editor.text, "- a\n- b")
        await editor.command("editor:list")
        XCTAssertEqual(editor.text, "a\nb")
        await editor.command("editor:ordered-list")
        XCTAssertEqual(editor.text, "1. a\n2. b")
        await editor.command("editor:quote")
        XCTAssertEqual(editor.text, "> a\n> b")
    }

    // Spec 136. Turns red if the list conversions behind the context menu stop rewriting the whole list.
    func testConvertList() async {
        let editor = await makeEditor()
        await editor.set("- a|\n- b")
        editor.convertList(at: 0, to: .ordered)
        XCTAssertEqual(editor.text, "1. a\n2. b")
        editor.convertList(at: 0, to: .task)
        XCTAssertEqual(editor.text, "- [ ] a\n- [ ] b")
    }
}
