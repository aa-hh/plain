import AppKit
import XCTest
@testable import EditorTextView

@MainActor
final class LineCommandTests: XCTestCase {
    // Spec 284. Turns red if Move Line Up/Down stops moving the touched lines or stops renumbering ordered lists.
    func testMoveLines() async {
        let editor = await makeEditor()
        await editor.set("a\nb|\nc")
        await editor.command("editor:move-line-up")
        XCTAssertEqual(editor.marked, "b|\na\nc")
        await editor.command("editor:move-line-down")
        await editor.command("editor:move-line-down")
        XCTAssertEqual(editor.marked, "a\nc\nb|")
        await editor.set("1. x\n2. y|")
        await editor.command("editor:move-line-up")
        XCTAssertEqual(editor.text, "1. y\n2. x")
    }

    // Spec 285. Turns red if Duplicate Line stops copying below with the selection on the copy.
    func testDuplicateLine() async {
        let editor = await makeEditor()
        await editor.set("one|\ntwo")
        await editor.command("editor:duplicate-line")
        XCTAssertEqual(editor.marked, "one\none|\ntwo")
    }

    // Spec 286. Turns red if Delete Line stops removing the line and its break.
    func testDeleteLine() async {
        let editor = await makeEditor()
        await editor.set("one\ntw|o\nthree")
        await editor.command("editor:delete-line")
        XCTAssertEqual(editor.marked, "one\n|three")
    }

    // Spec 287. Turns red if Toggle Case stops lowering text with capitals and raising text without.
    func testToggleCase() async {
        let editor = await makeEditor()
        await editor.set("«Hello»")
        await editor.command("editor:toggle-case")
        XCTAssertEqual(editor.text, "hello")
        await editor.command("editor:toggle-case")
        XCTAssertEqual(editor.text, "HELLO")
        await editor.set("wo|rd")
        await editor.command("editor:toggle-case")
        XCTAssertEqual(editor.text, "WORD")
    }

    // Spec 288. Turns red if Cmd+Enter / Cmd+Shift+Enter stop adding a line below / above, or Shift+Enter stops
    // inserting a plain break.
    func testNewLineBelowAboveAndPlainBreak() async {
        let editor = await makeEditor()
        await editor.set("a|b\nc")
        editor.newLine(above: false)
        XCTAssertEqual(editor.marked, "ab\n|\nc")
        await editor.set("a|b")
        editor.newLine(above: true)
        XCTAssertEqual(editor.marked, "|\nab")
        await editor.set("- item|")
        editor.insertLineBreak(nil)
        XCTAssertEqual(editor.marked, "- item\n|")
    }

    // Spec 292. Turns red if To Last Edit stops jumping back through earlier edit locations.
    func testLastEdit() async {
        let editor = await makeEditor()
        await editor.set("first\n\nsecond\n\nthird|")
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        await editor.type("A")
        editor.setSelectedRange(NSRange(location: 14, length: 0))
        await editor.type("B")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        await editor.command("editor:last-edit")
        XCTAssertEqual(editor.selectedRange().location, 15)
        await editor.command("editor:last-edit")
        XCTAssertEqual(editor.selectedRange().location, 6)
        await editor.command("editor:next-edit")
        XCTAssertEqual(editor.selectedRange().location, 15)
    }

    // Spec 292. Turns red if an edit location in another file stops going through `openFile`.
    func testLastEditOpensOtherFile() async {
        let editor = await makeEditor("x")
        var opened: (URL, Int)?
        editor.actions.openFile = { opened = ($0, $1) }
        let other = URL(fileURLWithPath: "/tmp/other.md")
        editor.editLocations.record(url: other, offset: 7, sameLine: false)
        await editor.command("editor:last-edit")
        XCTAssertEqual(opened?.0, other)
        XCTAssertEqual(opened?.1, 7)
    }
}
