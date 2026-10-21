import AppKit
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
}
