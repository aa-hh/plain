import AppKit
import PlainCore
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

    // Spec 507. Turns red if EditorController.replace stops going through the editor's edit path, so the preview's
    // checkbox edit cannot be redone after an undo, or stops working while full preview makes the editor read-only.
    func testControllerReplaceUndoesAndRedoes() async {
        let editor = await makeEditor("- [ ] task\n")
        let controller = EditorController()
        controller.editor = editor
        controller.isReadOnly = true
        XCTAssertTrue(controller.replace(range: NSRange(location: 3, length: 1), with: "x"))
        await editor.settle()
        XCTAssertEqual(editor.text, "- [x] task\n")
        XCTAssertFalse(editor.isEditable)
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "- [ ] task\n")
        editor.undoManager?.redo()
        await editor.settle()
        XCTAssertEqual(editor.text, "- [x] task\n")
        XCTAssertEqual(editor.snapshot?.text, editor.text)
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

    // MARK: Page

    private func page(_ text: String) async -> EditorTextView { await makeEditor(text, configuration: EditorConfiguration()) }

    /// The selection after putting the caret at `offset` and running `move`.
    private func after(_ editor: EditorTextView, from offset: Int, _ move: (EditorTextView) -> Void) -> NSRange {
        editor.setSelectedRange(NSRange(location: offset, length: 0))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: offset, length: 0), "the start \(offset) is not a valid caret")
        move(editor)
        return editor.selectedRange()
    }

    // A12 worked offsets. Turns red if Left and Right stop stepping one visible character over hidden markers.
    func testPageArrowsStepOverHiddenMarkers() async {
        let editor = await page("**bold**")
        XCTAssertEqual(after(editor, from: 0) { $0.moveRight(nil) }.location, 3)
        XCTAssertEqual(after(editor, from: 5) { $0.moveRight(nil) }.location, 8)
        XCTAssertEqual(after(editor, from: 8) { $0.moveLeft(nil) }.location, 5)
        XCTAssertEqual(after(editor, from: 0) { $0.moveRightAndModifySelection(nil) }, NSRange(location: 0, length: 3))
        editor.moveRightAndModifySelection(nil)
        editor.moveRightAndModifySelection(nil)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 5))
        XCTAssertEqual(after(editor, from: 8) { $0.moveLeftAndModifySelection(nil) }, NSRange(location: 5, length: 3))
    }

    // Addendum 3. Turns red if a selection holding only hidden characters stays selected instead of collapsing to
    // its anchor.
    func testPageSelectionWithNothingShownCollapses() async {
        let editor = await page("**bold**")
        _ = after(editor, from: 0) { $0.moveRightAndModifySelection(nil) }
        editor.moveLeftAndModifySelection(nil)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        _ = after(editor, from: 8) { $0.moveLeftAndModifySelection(nil) }
        editor.moveRightAndModifySelection(nil)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 8, length: 0))
    }

    // A12 worked offsets. Turns red if Right stops crossing the hidden gap between two table cells in one press.
    func testPageRightCrossesTableGap() async {
        let editor = await page("| a | b |\n|---|---|\n| c | d |")
        XCTAssertEqual(after(editor, from: 3) { $0.moveRight(nil) }.location, 6)
    }

    // A12 worked offsets. Turns red if Up or Down stop skipping separators, dividers and fence lines.
    func testPageUpDownSkipHiddenLines() async {
        let paragraphs = await page("para\n\nnext")
        XCTAssertEqual(after(paragraphs, from: 6) { $0.moveUp(nil) }.location, 0)
        XCTAssertEqual(after(paragraphs, from: 0) { $0.moveDown(nil) }.location, 6)
        let divider = await page("a\n\n---\n\nb")
        XCTAssertEqual(after(divider, from: 8) { $0.moveUp(nil) }.location, 0)
        XCTAssertEqual(after(divider, from: 0) { $0.moveDown(nil) }.location, 8)
        let code = await page("```swift\nlet x\n```\n\nnext")
        XCTAssertEqual(after(code, from: 20) { $0.moveUp(nil) }.location, 9)
        XCTAssertEqual(after(code, from: 9) { $0.moveUp(nil) }.location, 9)
        let heading = await page("Two\n\n## Head")
        XCTAssertEqual(after(heading, from: 0) { $0.moveDown(nil) }.location, 8)
        XCTAssertEqual(after(heading, from: 8) { $0.moveUp(nil) }.location, 0)
    }

    // Turns red if a caret snapped off a divider stops on the next divider's hidden line because the hidden ranges
    // were listed only around the first point.
    func testPageClickBetweenDividersSnapsPastBoth() async {
        let editor = await page("a\n\n---\n\n---\n\nb")
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 13, length: 0))
    }

    // Addendum 2. Turns red if Down stops skipping a closing fence or a setext underline below the caret, or stops
    // keeping the caret's x on the line it lands on (code lines start 32 pt in, past the end of `next`).
    func testPageDownSkipsClosingFenceAndUnderline() async {
        let code = await page("```swift\nlet x\n```\n\nnext")
        XCTAssertEqual(after(code, from: 14) { $0.moveDown(nil) }.location, 24)
        XCTAssertEqual(after(code, from: 9) { $0.moveDown(nil) }.location, 24)
        let setext = await page("Title\n---\n\nnext")
        XCTAssertEqual(after(setext, from: 5) { $0.moveDown(nil) }.location, 15)
        XCTAssertEqual(after(setext, from: 0) { $0.moveDown(nil) }.location, 11)
    }

    // Addendum 2. Turns red if a divider that ends the text gets a caret position, or the blank line above it stops
    // being a caret stop that Down lands on.
    func testPageDividerAtTextEndHasNoCaretPosition() async {
        let editor = await page("a\n\n---")
        XCTAssertEqual(after(editor, from: 0) { $0.moveDown(nil) }.location, 2)
        for offset in 3...6 {
            editor.setSelectedRange(NSRange(location: offset, length: 0))
            XCTAssertLessThan(editor.selectedRange().location, 3, "offset \(offset)")
        }
    }

    // Addendum 2. Turns red if extra carets moving up or down stop skipping a separator line.
    func testPageUpDownMoveEveryCaretPastSeparator() async {
        let editor = await page("para\n\nnext")
        editor.setAllSelections([NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)])
        editor.moveDown(nil)
        XCTAssertEqual(editor.allSelections.count, 2)
        XCTAssertTrue(editor.allSelections.allSatisfy { $0.location >= 6 }, "\(editor.allSelections)")
        editor.moveUp(nil)
        XCTAssertTrue(editor.allSelections.allSatisfy { $0.location <= 4 }, "\(editor.allSelections)")
    }

    // A12 worked offsets. Turns red if Home or Cmd+Up put the caret before a heading's hidden `## `.
    func testPageHomeStaysAtVisibleStart() async {
        let editor = await page("## Head")
        XCTAssertEqual(after(editor, from: 3) { $0.moveToBeginningOfLine(nil) }.location, 3)
        XCTAssertEqual(after(editor, from: 3) { $0.moveToBeginningOfDocument(nil) }.location, 3)
    }

    // Turns red if a caret placed inside hidden markers (a click, or a programmatic selection) stays there.
    func testPageClickSnapsOutOfMarkers() async {
        let editor = await page("x **bold**")
        await editor.set("x *|*bold**")
        XCTAssertEqual(editor.marked, "x |**bold**")
        await editor.set("x **bold*|*")
        XCTAssertEqual(editor.marked, "x **bold**|")
    }

    // Turns red if Alt+click on the page adds a caret inside hidden markers.
    func testPageAltClickAddsSnappedCaret() async {
        let editor = await page("**bold** end")
        editor.setSelectedRange(NSRange(location: 12, length: 0))
        XCTAssertTrue(editor.handleSelectionClick(mouseEvent(.leftMouseDown, at: 1, in: editor, flags: .option)))
        XCTAssertEqual(editor.allSelections.count, 2)
        let ranges = editor.pageHiddenRanges(around: NSRange(location: 0, length: 12))!
        XCTAssertTrue(editor.allSelections.allSatisfy { HiddenRanges.isValidCaret($0.location, ranges: ranges) }, "\(editor.allSelections)")
    }

    // Turns red if `setAllSelections` merges duplicate carets before snapping them, so an Alt-click inside hidden
    // markers keeps an extra caret on the main caret's spot (and typing runs as multi-caret typing).
    func testPageAltClickSnappingOntoCaretLeavesOne() async {
        let editor = await page("x **b**")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        let event = mouseEvent(.leftMouseDown, at: 4, in: editor, flags: .option)
        XCTAssertEqual(editor.characterIndexForInsertion(at: editor.convert(event.locationInWindow, from: nil)), 4)
        XCTAssertTrue(editor.handleSelectionClick(event))
        XCTAssertEqual(editor.extraSelections, [])
        await editor.type("z")
        XCTAssertEqual(editor.text, "x z**b**")
    }

    // Turns red if `clickedTaskBox` acts on every click of a double-click, ticking the box twice in two undo steps.
    func testPageDoubleClickOnTaskBoxTicksOnce() async throws {
        let editor = await page("- [ ] task")
        let marker = try XCTUnwrap(editor.attribute(.plainPageMarker, at: 0) as? PageMarker)
        let first = editor.rect(forCharacterRange: NSRange(location: 0, length: 0))
        let point = windowPoint(x: editor.columnLeft + marker.x + Tokens.page.markerBox / 2, y: first.midY, in: editor)
        for clicks in 1...2 {
            editor.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                      windowNumber: editor.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                      clickCount: clicks, pressure: 1)!)
            await editor.settle()
        }
        XCTAssertEqual(editor.text, "- [x] task")
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "- [ ] task")
        XCTAssertEqual(editor.undoManager?.canUndo, false)
    }

    // Turns red if Option+Left or Option+Right can leave the caret inside hidden markers.
    func testPageWordMovesLandOnValidPositions() async {
        let editor = await page("**bold** and _it_ [link](u) end")
        let ranges = editor.pageHiddenRanges(around: NSRange(location: 0, length: editor.nsText.length))!
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        var seen: [Int] = []
        for _ in 0..<8 {
            editor.moveWordRight(nil)
            seen.append(editor.selectedRange().location)
        }
        for _ in 0..<8 {
            editor.moveWordLeft(nil)
            seen.append(editor.selectedRange().location)
        }
        XCTAssertTrue(seen.allSatisfy { HiddenRanges.isValidCaret($0, ranges: ranges) }, "\(seen)")
        XCTAssertEqual(seen[7], editor.nsText.length)
        XCTAssertEqual(seen.last, 0)
    }
}
