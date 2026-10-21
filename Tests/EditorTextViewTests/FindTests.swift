import AppKit
import XCTest
@testable import EditorTextView

@MainActor
final class FindTests: XCTestCase {
    // Spec 302. Turns red if Find stops pre-filling a single-line selection and selecting the next match.
    func testPrefillsSelectionAndSelectsNextMatch() async {
        let editor = await makeEditor()
        await editor.set("«cat» dog cat")
        editor.openFind()
        XCTAssertEqual(editor.findBar?.field.stringValue, "cat")
        XCTAssertEqual(editor.marked, "cat dog «cat»")
        XCTAssertTrue(editor.findBarVisible)
    }

    // Spec 303. Turns red if the first pass stops preferring matches that start a chunk, or the fallback to any
    // substring stops.
    func testChunkStartFirstThenSubstring() async {
        XCTAssertEqual(EditorTextView.findMatches("ile", in: "Profile ile" as NSString), [NSRange(location: 8, length: 3)])
        XCTAssertEqual(EditorTextView.findMatches("ile", in: "Profile" as NSString), [NSRange(location: 4, length: 3)])
        XCTAssertEqual(EditorTextView.findMatches("CAT", in: "cat Cat" as NSString).count, 2)
    }

    // Spec 304. Turns red if next and previous stop wrapping around.
    func testNextAndPreviousWrap() async {
        let editor = await makeEditor()
        await editor.set("|a x a x a")
        editor.openFind()
        editor.findQueryChanged("a")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 1))
        editor.findNext(backwards: false)
        editor.findNext(backwards: false)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 8, length: 1))
        editor.findNext(backwards: false)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 1))
        editor.findNext(backwards: true)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 8, length: 1))
    }

    // Spec 305. Turns red if the box stops turning the error colour when nothing matches.
    func testNoMatchShowsError() async {
        let editor = await makeEditor()
        await editor.set("|abc")
        editor.openFind()
        editor.findQueryChanged("zzz")
        XCTAssertEqual(editor.findBar?.showsError, true)
        editor.findQueryChanged("ab")
        XCTAssertEqual(editor.findBar?.showsError, false)
    }

    // Spec 306. Turns red if Esc after no matches stops restoring the selection Find opened with.
    func testEscapeRestoresSelectionWhenNothingMatched() async {
        let editor = await makeEditor()
        await editor.set("ab|c abc")
        editor.openFind()
        editor.findQueryChanged("zzz")
        editor.closeFind()
        XCTAssertEqual(editor.marked, "ab|c abc")
        XCTAssertFalse(editor.findBarVisible)
        editor.openFind()
        editor.findQueryChanged("abc")
        editor.closeFind()
        XCTAssertEqual(editor.selectedRange().length, 3)
    }

    // Spec 307. Turns red if matches stop updating when the document changes.
    func testMatchesFollowEdits() async {
        let editor = await makeEditor()
        await editor.set("|a b")
        editor.openFind()
        editor.findQueryChanged("b")
        XCTAssertEqual(editor.find?.matches.count, 1)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertText(" b", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.find?.matches.count, 2)
    }
}
