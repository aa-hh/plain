import AppKit
import MarkdownDocument
import PlainCore
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

    // MARK: Page blocks

    private func page(_ text: String) async -> EditorTextView { await makeEditor(text, configuration: EditorConfiguration()) }

    /// Applies `make`'s edit to `text`'s blocks, checks the result, then checks one undo restores the text.
    private func check(_ text: String, _ expected: String, _ make: ([PageBlock], NSString) -> (edits: [TextEdit], caret: Int?)) async {
        let editor = await page(text)
        let change = make(editor.pageBlocks(), editor.nsText)
        editor.apply(change.edits, caret: change.caret)
        await editor.settle()
        XCTAssertEqual(editor.text, expected)
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, text)
    }

    // A18 examples. Turns red if duplicate, move or delete stop keeping one blank line between blocks (none between
    // items), or take more than one undo step.
    func testPageBlockEdits() async {
        await check("A\n\nB", "A\n\nA\n\nB") { blocks, text in PageBlocks.duplicate(blocks[0], text: text) }
        await check("A\n\nB", "B\n\nA") { blocks, text in PageBlocks.move(blocks[1], before: blocks[0], text: text) }
        await check("A\n\nB", "B\n\nA") { blocks, text in PageBlocks.move(blocks[0], before: nil, text: text) }
        await check("- a\n- b", "- a\n- a\n- b") { blocks, text in PageBlocks.duplicate(blocks[0], text: text) }
        await check("A\n\nB", "A") { blocks, text in PageBlocks.delete(blocks[1], text: text) }
    }

    // Spec 3. Turns red if moving a list item leaves its nested items behind.
    func testPageMoveTakesNestedItems() async {
        await check("- x\n- a\n  - a1", "- a\n  - a1\n- x") { blocks, text in
            let a = blocks.first { text.substring(with: $0.range) == "- a" }!
            return PageBlocks.move(a, before: blocks[0], text: text)
        }
    }

    // MARK: Block handle

    private func hover(_ editor: EditorTextView, at offset: Int) {
        editor.mouseMoved(with: mouseEvent(.mouseMoved, at: offset, in: editor))
    }

    private func hover(_ editor: EditorTextView, x: CGFloat, y: CGFloat) {
        editor.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint(x: x, y: y, in: editor), modifierFlags: [],
                                                   timestamp: 0, windowNumber: editor.window?.windowNumber ?? 0, context: nil,
                                                   eventNumber: 0, clickCount: 0, pressure: 0)!)
    }

    // C6. Turns red if hovering a paragraph stops placing the grip's right edge 4 pt left of the column, level with
    // the block's first line.
    func testHandleShowsAtFirstLine() async throws {
        let editor = await page("First para\n\nSecond para")
        hover(editor, at: 15)
        let block = editor.pageBlocks()[1]
        XCTAssertEqual(editor.blockHandle.hovered, block)
        let handle = try XCTUnwrap(editor.blockHandle.handle)
        XCTAssertFalse(handle.isHidden)
        XCTAssertEqual(handle.frame.maxX, editor.columnLeft - 4)
        XCTAssertEqual(handle.frame.width, 48)
        XCTAssertEqual(handle.frame.midY, editor.firstLineRect(of: block).midY, accuracy: 0.5)
    }

    // C6. Turns red if hovering a nested item picks its parent item instead of the item itself.
    func testHandlePicksNestedItem() async {
        let editor = await page("- a\n  - b")
        hover(editor, at: 8)
        XCTAssertEqual(editor.blockHandle.hovered.map { editor.nsText.substring(with: $0.range) }, "  - b")
        XCTAssertEqual(editor.blockHandle.hovered?.depth, 1)
    }

    // C6. Turns red if hovering blocks or the handle restyles the text instead of only moving views.
    func testHoverNeverRestyles() async {
        let editor = await page("# Title\n\nText\n\n- a\n  - b")
        var restyles = 0
        editor.styler.didRestyle = { _ in restyles += 1 }
        for index in 0..<20 {
            if index % 4 == 3 {
                let first = editor.rect(forCharacterRange: NSRange(location: 10, length: 0))
                hover(editor, x: editor.columnLeft - 16, y: first.midY)
            } else {
                hover(editor, at: [3, 10, 23][index % 4])
            }
        }
        XCTAssertEqual(restyles, 0)
        XCTAssertNotNil(editor.blockHandle.hovered)
    }

    // C3. Turns red if `+` stops adding an empty line below the block with the caret on it, or takes more than one
    // undo step.
    func testPlusAddsLineBelow() async {
        let editor = await page("A\n\nB")
        hover(editor, at: 0)
        editor.blockHandlePlus()
        await editor.settle()
        XCTAssertEqual(editor.marked, "A\n\n|\n\nB")
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "A\n\nB")
    }

    // C5. Turns red if a block menu action stops editing the hovered block, leaves the menu open, or takes more than
    // one undo step.
    func testBlockMenuActions() async {
        func run(_ text: String, hover offset: Int, _ expected: String, _ action: (EditorTextView) -> Void) async {
            let editor = await page(text)
            hover(editor, at: offset)
            editor.openBlockMenu()
            XCTAssertNotNil(editor.blockHandle.menu)
            action(editor)
            await editor.settle()
            XCTAssertEqual(editor.text, expected)
            XCTAssertNil(editor.blockHandle.menu)
            editor.undoManager?.undo()
            await editor.settle()
            XCTAssertEqual(editor.text, text)
        }
        await run("A\n\nB", hover: 0, "A\n\nA\n\nB") { $0.blockMenuDuplicate() }
        await run("A\n\nB", hover: 3, "A") { $0.blockMenuDelete() }
        await run("A\n\nB", hover: 0, "# A\n\nB") { $0.blockMenuTurnInto(.heading(1)) }

        let editor = await page("- a\n  - a1\n\nB")
        hover(editor, at: 2)
        editor.openBlockMenu()
        editor.blockMenuCopyMarkdown()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "- a\n  - a1")
        XCTAssertNil(editor.blockHandle.menu)
    }

    // Turns red if the block menu shows its Turn into row for a block that holds no text (`PageBlockKind.canTurnInto`),
    // seen as a menu four rows tall over a divider instead of three.
    func testBlockMenuHasNoTurnIntoForDivider() async throws {
        let editor = await page("A\n\n---\n\nB")
        hover(editor, at: 3)
        XCTAssertEqual(editor.blockHandle.hovered?.kind, .divider)
        editor.openBlockMenu()
        XCTAssertEqual(try XCTUnwrap(editor.blockHandle.menu).frame.height, 3 * Tokens.page.menuRow + 8)
        editor.closeBlockHandle()
        hover(editor, at: 0)
        XCTAssertEqual(editor.blockHandle.hovered?.kind, .text)
        editor.openBlockMenu()
        XCTAssertEqual(try XCTUnwrap(editor.blockHandle.menu).frame.height, 4 * Tokens.page.menuRow + 8)
    }

    // Turns red if typing stops hiding the block handle, or a block menu action uses the ranges captured at the last
    // hover instead of finding the block again at the handle's line, so it edits text the typing moved.
    func testBlockMenuAfterTypingActsOnCurrentBlock() async {
        let editor = await page("A\n\nB")
        hover(editor, at: 3)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        await editor.type("xxxxx")
        XCTAssertNil(editor.blockHandle.hovered)
        XCTAssertEqual(editor.blockHandle.handle?.isHidden, true)
        editor.openBlockMenu()
        editor.blockMenuDelete()
        await editor.settle()
        XCTAssertEqual(editor.text, "Axxxxx")
    }

    // C4. Turns red if a drop stops moving the hovered block to the nearest block top in one undo step, or a drop
    // onto the block itself changes the text.
    func testDropMovesBlock() async {
        let editor = await page("A\n\nB")
        hover(editor, at: 3)
        editor.blockHandleDrop(at: NSPoint(x: editor.columnLeft, y: editor.firstLineRect(of: editor.pageBlocks()[1]).minY))
        await editor.settle()
        XCTAssertEqual(editor.text, "A\n\nB")
        hover(editor, at: 3)
        XCTAssertEqual(editor.blockHandle.hovered, editor.pageBlocks()[1])
        editor.blockHandleDrop(at: NSPoint(x: editor.columnLeft, y: editor.firstLineRect(of: editor.pageBlocks()[0]).minY))
        await editor.settle()
        XCTAssertEqual(editor.text, "B\n\nA")
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, "A\n\nB")
    }
}
