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

    // States and limits. Turns red if page Find searches the stand-ins Copy writes for hidden Markdown, so a footnote's
    // drawn number matches `[^1]`.
    func testPageFindSkipsFootnoteNumbers() async {
        let editor = await makeEditor("a[^1]\n\n[^1]: note", configuration: EditorConfiguration())
        editor.openFind()
        editor.findQueryChanged("1")
        XCTAssertEqual(editor.find?.matches, [])
        editor.findQueryChanged("note")
        XCTAssertEqual(editor.find?.matches, [NSRange(location: 13, length: 4)])
        editor.closeFind()
    }

    // States and limits. Turns red if page Find falls back to the raw Markdown while a parse is pending, so `**`
    // matches the hidden markers of `**b**`.
    func testPageFindNeverMatchesHiddenMarkers() async {
        let editor = await makeEditor("**b**", configuration: EditorConfiguration())
        editor.openFind()
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertText("c", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(editor.snapshot)
        editor.findQueryChanged("**")
        XCTAssertEqual(editor.find?.matches, [])
        await editor.settle()
        XCTAssertEqual(editor.find?.query, "**")
        XCTAssertEqual(editor.find?.matches, [])
        editor.closeFind()
    }

    // Turns red if Cmd+G selects a match from before an unparsed edit.
    func testPageFindNextAfterEditsBeforeParseStaysInBounds() async {
        let editor = await makeEditor("aaa foo", configuration: EditorConfiguration())
        editor.openFind()
        editor.findQueryChanged("foo")
        XCTAssertEqual(editor.find?.matches, [NSRange(location: 4, length: 3)])
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.deleteBackward(nil)
        editor.deleteBackward(nil)
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.find?.matches, [NSRange(location: 4, length: 0)])
        XCTAssertNil(editor.snapshot)
        editor.findNext(backwards: false)
        XCTAssertLessThanOrEqual(NSMaxRange(editor.selectedRange()), 4)
        await editor.settle()
        XCTAssertEqual(editor.find?.matches, [])
        editor.closeFind()
    }

    // Turns red if a query typed while a parse is pending is never selected, scrolled to, or coloured when the snapshot
    // lands.
    func testPageFindQueryTypedDuringParseShowsWhenSnapshotArrives() async {
        let editor = await makeEditor("a b", configuration: EditorConfiguration())
        editor.openFind()
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.insertText("c", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(editor.snapshot)
        editor.findQueryChanged("b")
        await editor.settle()
        XCTAssertEqual(editor.find?.matches, [NSRange(location: 2, length: 1)])
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 1))
        XCTAssertEqual(editor.findBar?.showsError, false)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.insertText("d", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.findQueryChanged("zzz")
        await editor.settle()
        XCTAssertEqual(editor.findBar?.showsError, true)
        XCTAssertEqual(editor.find?.matches, [])
        editor.closeFind()
    }

    // Turns red if switching Show Markdown Source leaves Find's matches from the other view.
    func testToggleSourceWithFindOpenRefindsMatches() async {
        let editor = await makeEditor("**b**", configuration: EditorConfiguration())
        editor.openFind()
        editor.findQueryChanged("**")
        XCTAssertEqual(editor.find?.matches, [])
        editor.apply(EditorConfiguration(showMarkdownSource: true))
        XCTAssertEqual(editor.find?.matches, [NSRange(location: 0, length: 2)])
        editor.apply(EditorConfiguration())
        XCTAssertEqual(editor.find?.matches, [])
        editor.closeFind()
    }

    // Turns red if page Find matches across a table gap or a footnote reference.
    func testPageFindKeepsBoundariesAtCellsAndFootnotes() async {
        let table = await makeEditor("| foo | bar |\n|---|---|\n| c | d |", configuration: EditorConfiguration())
        table.openFind()
        table.findQueryChanged("foobar")
        XCTAssertEqual(table.find?.matches, [])
        table.findQueryChanged("bar")
        XCTAssertEqual(table.find?.matches, [NSRange(location: 8, length: 3)])
        table.closeFind()
        let footnote = await makeEditor("a[^1]b\n\n[^1]: note", configuration: EditorConfiguration())
        footnote.openFind()
        footnote.findQueryChanged("ab")
        XCTAssertEqual(footnote.find?.matches, [])
        footnote.closeFind()
    }

    // Turns red if page Find matches maths source, a front matter colon, or a picture's alt text.
    func testPageFindSkipsTextDrawnClear() async {
        let maths = await makeEditor("$$\n\\frac{1}{2}\n$$\n\ntext", configuration: EditorConfiguration())
        maths.openFind()
        maths.findQueryChanged("frac")
        XCTAssertEqual(maths.find?.matches, [])
        maths.closeFind()
        let front = await makeEditor("---\ntitle: Hello\n---\n\nbody", configuration: EditorConfiguration())
        front.openFind()
        front.findQueryChanged(":")
        XCTAssertEqual(front.find?.matches, [])
        front.findQueryChanged("Hello")
        XCTAssertEqual(front.find?.matches, [NSRange(location: 11, length: 5)])
        front.closeFind()
        let picture = await makeEditor("![cat](p.png)", configuration: EditorConfiguration())
        picture.openFind()
        picture.findQueryChanged("cat")
        XCTAssertEqual(picture.find?.matches, [])
        picture.closeFind()
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
