import AppKit
import PlainCore
import XCTest
@testable import EditorTextView

@MainActor
final class TableEditingTests: XCTestCase {
    // Spec 146. Turns red if Enter after a header row stops adding the divider and an empty row.
    func testEnterAfterHeaderRowAddsDividerAndRow() async {
        let editor = await makeEditor()
        await editor.set("| a | b |", caret: "‸")
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        await editor.enter()
        XCTAssertEqual(editor.marked(caret: "‸"), "| a | b |\n|---|---|\n| ‸  |   |")
    }

    // Spec 147. Turns red if Enter in a body row stops adding an empty row below.
    func testEnterInBodyRowAddsRow() async {
        let editor = await makeEditor()
        await editor.set("| a | b |\n|---|---|\n| c‸ | d |", caret: "‸")
        await editor.enter()
        XCTAssertEqual(editor.marked(caret: "‸"), "| a | b |\n|---|---|\n| c | d |\n| ‸  |   |")
    }

    // Spec 148. Turns red if Enter on an empty last row stops deleting it.
    func testEnterOnEmptyLastRowLeavesTable() async {
        let editor = await makeEditor()
        await editor.set("| a | b |\n|---|---|\n| c | d |\n|   |   |‸", caret: "‸")
        await editor.enter()
        XCTAssertEqual(editor.marked(caret: "‸"), "| a | b |\n|---|---|\n| c | d |\n‸")
    }

    // Spec 149. Turns red if `|` on the line after a table stops starting a new row.
    func testPipeAfterTableStartsRow() async {
        let editor = await makeEditor()
        await editor.set("| a | b |\n|---|---|\n| c | d |\n‸", caret: "‸")
        await editor.type("|")
        XCTAssertEqual(editor.marked(caret: "‸"), "| a | b |\n|---|---|\n| c | d |\n| ‸  |   |")
    }

    // Spec 150. Turns red if Tab and Shift+Tab stop selecting the next and previous cell's text.
    func testTabSelectsCells() async {
        let editor = await makeEditor()
        await editor.set("| a | bb |\n|---|----|\n| c | dd |", caret: "‸")
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        await editor.tab()
        XCTAssertEqual(editor.marked, "| a | «bb» |\n|---|----|\n| c | dd |")
        await editor.tab()
        XCTAssertEqual(editor.marked, "| a | bb |\n|---|----|\n| «c» | dd |")
        editor.insertBacktab(nil)
        XCTAssertEqual(editor.marked, "| a | «bb» |\n|---|----|\n| c | dd |")
    }

    // Spec 151. Turns red if typing in a cell stops re-padding its column and rebuilding the divider with its colons.
    func testTypingRepadsColumn() async {
        let editor = await makeEditor()
        await editor.set("| a | b |\n|:--|--:|\n| c‸ | d |", caret: "‸")
        await editor.type("cc")
        XCTAssertEqual(editor.marked(caret: "‸"), "| a   | b |\n|:----|--:|\n| ccc‸ | d |")
    }

    // A18. Turns red if adding a row or column stops writing an empty row as wide as the divider's cells, or a new
    // cell on every line, with the caret in the new cell.
    func testPageAddRowAndColumn() async {
        let editor = await makeEditor("| a | b |\n|---|---|\n| c | d |", configuration: EditorConfiguration())
        let table = editor.table(at: 0)!
        let row = PageBlocks.addRow(table, text: editor.nsText)
        editor.apply(row.edits, caret: row.caret)
        await editor.settle()
        XCTAssertEqual(editor.text, "| a | b |\n|---|---|\n| c | d |\n|   |   |")
        XCTAssertEqual(editor.selectedRange().location, 32)
        let column = PageBlocks.addColumn(editor.table(at: 0)!, text: editor.nsText)
        editor.apply(column.edits, caret: column.caret)
        await editor.settle()
        XCTAssertEqual(editor.text, "| a | b |   |\n|---|---|---|\n| c | d |   |\n|   |   |   |")
    }

    // MARK: Page grid

    private static let grid = "| a | b |\n|---|---|\n| c | d |"

    private func page(_ text: String) async -> EditorTextView { await makeEditor(text, configuration: EditorConfiguration()) }

    private func edges(_ editor: EditorTextView, line: Int) -> [CGFloat] {
        (editor.attribute(.plainPageTableRow, at: line) as? PageTableRow)?.columnEdges ?? []
    }

    /// A mouse event at (`x`, `y`) in the editor's coordinates.
    private func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, in editor: EditorTextView, clickCount: Int = 1,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: windowPoint(x: x, y: y, in: editor), modifierFlags: flags, timestamp: 0,
                           windowNumber: editor.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    /// Posts `events` to the editor's window and checks the first can be read back, so a click's event loop never waits forever.
    private func post(_ events: [NSEvent], to editor: EditorTextView) -> Bool {
        guard let window = editor.window else { return false }
        for event in events { window.postEvent(event, atStart: false) }
        return window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(timeIntervalSinceNow: 1), inMode: .eventTracking, dequeue: false) != nil
    }

    // E2. Turns red if a click in a cell's left padding stops putting the caret in that cell (it would land at the end of
    // the cell to its left).
    func testPageClickInCellPaddingLandsInCell() async {
        let editor = await page(Self.grid)
        let edges = edges(editor, line: 0)
        XCTAssertEqual(edges.count, 3)
        let row = editor.rect(forCharacterRange: NSRange(location: 0, length: 0))
        let x = editor.columnLeft + edges[1] + 2
        guard post([event(.leftMouseUp, x: x, y: row.midY, in: editor)], to: editor) else {
            return XCTFail("a posted mouse-up does not reach the window, so the click loop cannot be tested headlessly")
        }
        editor.mouseDown(with: event(.leftMouseDown, x: x, y: row.midY, in: editor))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 0))
    }

    // E2. Turns red if dragging after a cell click stops extending the selection to the dragged point.
    func testPageDragFromCellExtendsSelection() async {
        let editor = await page(Self.grid)
        let edges = edges(editor, line: 0)
        let row = editor.rect(forCharacterRange: NSRange(location: 0, length: 0))
        let x = editor.columnLeft + edges[1] + 2
        let end = editor.rect(forCharacterRange: NSRange(location: 26, length: 0))
        let drag = event(.leftMouseDragged, x: end.minX + 0.5, y: end.midY, in: editor)
        let up = event(.leftMouseUp, x: end.minX + 0.5, y: end.midY, in: editor)
        guard post([drag, up], to: editor) else {
            return XCTFail("posted drag events do not reach the window, so the drag loop cannot be tested headlessly")
        }
        editor.mouseDown(with: event(.leftMouseDown, x: x, y: row.midY, in: editor))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 20))
    }

    // E2. Turns red if the grid takes double-clicks or Alt-clicks, which belong to word selection and extra carets.
    func testPageDoubleAndAltClickPassThrough() async {
        let editor = await page(Self.grid)
        let edges = edges(editor, line: 0)
        let row = editor.rect(forCharacterRange: NSRange(location: 0, length: 0))
        let x = editor.columnLeft + edges[1] + 2
        XCTAssertFalse(editor.tableGridMouseDown(event(.leftMouseDown, x: x, y: row.midY, in: editor, clickCount: 2)))
        XCTAssertFalse(editor.tableGridMouseDown(event(.leftMouseDown, x: x, y: row.midY, in: editor, flags: .option)))
    }

    // E5. Turns red if Tab in a page table's last cell stops adding a row with the caret in its first cell, takes more
    // than one undo step, or Tab in another cell stops moving to the next cell.
    func testPageTabInLastCellAddsRow() async {
        let editor = await page(Self.grid)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        await editor.tab()
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 1))
        editor.setSelectedRange(NSRange(location: 27, length: 0))
        await editor.tab()
        XCTAssertEqual(editor.text, Self.grid + "\n|   |   |")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 32, length: 0))
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, Self.grid)
    }

    // E4. Turns red if hovering a table stops showing the bars along its right and bottom edges, they stop hiding when
    // the pointer leaves, or a bar's click stops adding a column or row as one undo step.
    func testPageBarsAddColumnAndRow() async {
        let editor = await page(Self.grid)
        let edges = edges(editor, line: 0)
        let row = editor.rect(forCharacterRange: NSRange(location: 0, length: 0))
        let hover = event(.mouseMoved, x: editor.columnLeft + edges[0] + 2, y: row.midY, in: editor)
        editor.tableGridMouseMoved(hover)
        XCTAssertEqual(editor.tableGrid.columnBar?.frame.minX, editor.columnLeft + edges[2])
        XCTAssertEqual(editor.tableGrid.columnBar?.frame.width, Tokens.page.addBar)
        XCTAssertEqual(editor.tableGrid.rowBar?.frame.height, Tokens.page.addBar)
        editor.tableGridMouseMoved(event(.mouseMoved, x: editor.columnLeft + 2, y: 650, in: editor))
        XCTAssertNil(editor.tableGrid.columnBar)
        XCTAssertNil(editor.tableGrid.rowBar)

        editor.tableGridMouseMoved(hover)
        editor.tableGridAddColumn()
        await editor.settle()
        XCTAssertEqual(editor.text, "| a | b |   |\n|---|---|---|\n| c | d |   |")
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, Self.grid)

        editor.tableGridMouseMoved(hover)
        editor.tableGridAddRow()
        await editor.settle()
        XCTAssertEqual(editor.text, Self.grid + "\n|   |   |")
        editor.undoManager?.undo()
        await editor.settle()
        XCTAssertEqual(editor.text, Self.grid)
    }

    // Turns red if the `+` bars and their hover area are placed only when the pointer enters the table, so after Tab adds
    // a row the bottom bar stays over the new row instead of below it.
    func testPageBarsFollowRowAddedByTab() async throws {
        let editor = await page(Self.grid)
        let edges = edges(editor, line: 0)
        let row = editor.rect(forCharacterRange: NSRange(location: 0, length: 0))
        editor.tableGridMouseMoved(event(.mouseMoved, x: editor.columnLeft + edges[0] + 2, y: row.midY, in: editor))
        let before = try XCTUnwrap(editor.tableGrid.rowBar).frame
        editor.setSelectedRange(NSRange(location: 27, length: 0))
        await editor.tab()
        XCTAssertEqual(editor.text, Self.grid + "\n|   |   |")
        let newRow = editor.rect(forCharacterRange: NSRange(location: (Self.grid as NSString).length + 1, length: 0))
        let after = try XCTUnwrap(editor.tableGrid.rowBar).frame
        XCTAssertGreaterThan(after.minY, before.minY)
        XCTAssertEqual(after.minY, newRow.maxY, accuracy: 0.5)
        XCTAssertTrue(editor.tableGrid.zone?.contains(NSPoint(x: after.midX, y: after.midY)) ?? false)
    }

    // Turns red if the cell outline is placed only when the selection moves, before the typed character's restyle
    // widens the column, so it lags one edit behind the cell.
    func testPageOutlineFollowsTypingInCell() async throws {
        let editor = await page(Self.grid)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        await editor.type("wider")
        let edges = edges(editor, line: 0)
        let outline = try XCTUnwrap(editor.tableGrid.outline).frame
        XCTAssertEqual(outline.minX, editor.columnLeft + edges[0])
        XCTAssertEqual(outline.width, edges[1] - edges[0])
    }

    // Turns red if `mouseDown` returns after `tableGridMouseDown` without `selectionToolbarAfterMouseUp`, so a drag
    // that selects text in a table shows no selection toolbar.
    func testPageDragInTableShowsToolbar() async {
        let editor = await page(Self.grid)
        let edges = edges(editor, line: 0)
        let row = editor.rect(forCharacterRange: NSRange(location: 0, length: 0))
        let end = editor.rect(forCharacterRange: NSRange(location: 26, length: 0))
        let drag = event(.leftMouseDragged, x: end.minX + 0.5, y: end.midY, in: editor)
        let up = event(.leftMouseUp, x: end.minX + 0.5, y: end.midY, in: editor)
        guard post([drag, up], to: editor) else {
            return XCTFail("posted drag events do not reach the window, so the drag loop cannot be tested headlessly")
        }
        editor.mouseDown(with: event(.leftMouseDown, x: editor.columnLeft + edges[1] + 2, y: row.midY, in: editor))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 20))
        XCTAssertNotNil(editor.selectionToolbar.toolbar)
    }

    // E3. Turns red if the outline stops matching the caret's cell (column edges by row height) or stays up when the
    // caret leaves the table or the selection is not a caret.
    func testPageOutlineFramesCell() async {
        let editor = await page(Self.grid + "\n\npara")
        let edges = edges(editor, line: 0)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        let line = editor.rect(forCharacterRange: NSRange(location: 6, length: 0))
        XCTAssertEqual(editor.tableGrid.outline?.frame,
                       NSRect(x: editor.columnLeft + edges[1], y: line.minY, width: edges[2] - edges[1], height: line.height))
        editor.setSelectedRange(NSRange(location: 6, length: 1))
        XCTAssertNil(editor.tableGrid.outline)
        editor.setSelectedRange(NSRange(location: 22, length: 0))
        XCTAssertNotNil(editor.tableGrid.outline)
        editor.setSelectedRange(NSRange(location: (Self.grid as NSString).length + 3, length: 0))
        XCTAssertNil(editor.tableGrid.outline)
    }
}
