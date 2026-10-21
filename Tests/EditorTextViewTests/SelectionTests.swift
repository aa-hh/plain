import AppKit
import XCTest
@testable import EditorTextView

@MainActor
final class SelectionTests: XCTestCase {
    // Turns red if extra carets stop receiving typed text, which NSTextView alone does not do.
    func testTypingAtThreeCarets() async {
        let editor = await makeEditor()
        await editor.set("a|\nb|\nc|")
        await editor.type("x")
        XCTAssertEqual(editor.marked, "ax|\nbx|\ncx|")
    }

    // Turns red if Backspace stops deleting at every caret.
    func testBackspaceAtThreeCarets() async {
        let editor = await makeEditor()
        await editor.set("ab|\ncd|\nef|")
        await editor.backspace()
        XCTAssertEqual(editor.marked, "a|\nc|\ne|")
    }

    // Turns red if Enter at several carets stops continuing each line's list pattern.
    func testEnterWithListContinuationAtThreeCarets() async {
        let editor = await makeEditor()
        await editor.set("- a|\n- b|\n- c|")
        await editor.enter()
        XCTAssertEqual(editor.marked, "- a\n- |\n- b\n- |\n- c\n- |")
    }

    // Spec 274. Turns red if pasting N lines into N carets stops giving each caret one line, or plain paste stops
    // going to every caret.
    func testPasteAtThreeCarets() async {
        let editor = await makeEditor()
        await editor.set("1|\n2|\n3|")
        editor.paste(text: "a\nb\nc")
        await editor.settle()
        XCTAssertEqual(editor.marked, "1a|\n2b|\n3c|")
        await editor.set("x| y| z|")
        editor.paste(text: "!")
        await editor.settle()
        XCTAssertEqual(editor.marked, "x!| y!| z!|")
    }

    // Spec 291 and the work order's one-step rule. Turns red if an edit at several carets takes more than one undo.
    func testMultiCaretEditIsOneUndoStep() async {
        let editor = await makeEditor()
        await editor.set("a|\nb|\nc|")
        await editor.type("x")
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "a\nb\nc")
    }

    // Spec 267. Turns red if a column selection stops making one selection per line between the two points.
    func testColumnSelection() async {
        let editor = await makeEditor("aaaa\naaaa\naaaa\n")
        let start = editor.rect(forCharacterRange: NSRange(location: 1, length: 0))
        let end = editor.rect(forCharacterRange: NSRange(location: 13, length: 0))
        editor.columnSelection(from: NSPoint(x: start.minX + 0.5, y: start.midY), to: NSPoint(x: end.minX + 0.5, y: end.midY))
        XCTAssertEqual(editor.marked, "a«aa»a\na«aa»a\na«aa»a\n")
    }

    // Spec 267. Turns red if clicking without Alt stops clearing the extra carets, or Esc stops collapsing them.
    func testEscapeCollapsesToMainCaret() async {
        let editor = await makeEditor()
        await editor.set("a|\nb|")
        editor.cancelOperation(nil)
        XCTAssertEqual(editor.allSelections.count, 1)
    }

    // Spec 268. Turns red if Add Next Occurrence stops selecting the word first and then adding the next match, wrapping.
    func testAddNextOccurrence() async {
        let editor = await makeEditor()
        await editor.set("foo b|ar foo bar")
        await editor.command("editor:add-next-occurrence")
        XCTAssertEqual(editor.marked, "foo «bar» foo bar")
        await editor.command("editor:add-next-occurrence")
        XCTAssertEqual(editor.marked, "foo «bar» foo «bar»")
        await editor.command("editor:remove-last-occurrence")
        XCTAssertEqual(editor.marked, "foo «bar» foo bar")
        await editor.type("X")
        XCTAssertEqual(editor.text, "foo X foo bar")
    }

    // Spec 269. Turns red if Add Each Occurrence stops selecting every match.
    func testAddEachOccurrence() async {
        let editor = await makeEditor()
        await editor.set("«ab» x ab y ab")
        await editor.command("editor:add-each-occurrence")
        XCTAssertEqual(editor.marked, "«ab» x «ab» y «ab»")
        await editor.type("Z")
        XCTAssertEqual(editor.text, "Z x Z y Z")
    }

    // Spec 271. Turns red if Add Selection Below stops adding a caret at the same column on the next line.
    func testAddSelectionBelow() async {
        let editor = await makeEditor()
        await editor.set("ab|cd\nx\nefgh")
        await editor.command("editor:add-selection-below")
        XCTAssertEqual(editor.marked, "ab|cd\nx|\nefgh")
        await editor.set("a«bc»d\nx\nefgh")
        await editor.command("editor:add-selection-below")
        XCTAssertEqual(editor.marked, "a«bc»d\nx\ne«fg»h")
    }

    // Spec 272. Turns red if Split Selection Into Lines stops making one selection per line.
    func testSplitSelectionIntoLines() async {
        let editor = await makeEditor()
        await editor.set("«one\ntwo\nthree»")
        await editor.command("editor:split-selection-into-lines")
        XCTAssertEqual(editor.marked, "«one»\n«two»\n«three»")
    }

    // Spec 273. Turns red if Extend Selection stops growing word → line → paragraph, or Shrink stops stepping back.
    func testExtendAndShrink() async {
        let editor = await makeEditor()
        await editor.set("one tw|o three\nnext line\n\nother")
        await editor.command("editor:extend-selection")
        XCTAssertEqual(editor.marked, "one «two» three\nnext line\n\nother")
        await editor.command("editor:extend-selection")
        XCTAssertEqual(editor.marked, "«one two three»\nnext line\n\nother")
        await editor.command("editor:extend-selection")
        XCTAssertEqual(editor.marked, "«one two three\nnext line»\n\nother")
        await editor.command("editor:shrink-selection")
        XCTAssertEqual(editor.marked, "«one two three»\nnext line\n\nother")
    }

    // Spec 267. Turns red if Alt+click stops adding a caret.
    func testAltClickAddsCaret() async throws {
        let editor = await makeEditor("abc\ndef\n")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        let point = editor.rect(forCharacterRange: NSRange(location: 5, length: 0))
        let windowPoint = editor.convert(NSPoint(x: point.minX + 0.5, y: point.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: .option, timestamp: 0,
                                                    windowNumber: editor.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(editor.handleSelectionClick(event))
        XCTAssertEqual(editor.marked, "a|bc\nd|ef\n")
    }
}
