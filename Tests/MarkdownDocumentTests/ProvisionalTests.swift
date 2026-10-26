import Foundation
import XCTest
@testable import MarkdownDocument

/// Issue 1: while the caret sits inside a block whose kind is still ambiguous, that block renders in its most likely
/// kind, and every other block keeps the kind it settled with.
final class ProvisionalTests: XCTestCase {
    private var model: NSMutableString!
    private var document: MarkdownDocument!

    private func open(_ text: String) {
        model = NSMutableString(string: text)
        document = MarkdownDocument(text: text)
    }

    /// Block kinds, ranges, line ranges and inline kinds, depth first, for comparing two parses.
    private func describe(_ snapshot: Snapshot) -> [String] {
        func inlineKinds(_ list: [Inline]) -> [String] {
            list.flatMap { ["\($0.kind)"] + inlineKinds($0.children) }
        }
        return snapshot.blocks(where: { _ in true }).map {
            "\($0.kind) \($0.range) \($0.lineRange) \(inlineKinds($0.inlines))"
        }
    }

    /// Applies the edit, then checks the snapshot's text and its settled blocks against a fresh parse.
    @discardableResult
    private func edit(_ range: NSRange, replacement: String, _ message: String) async -> Snapshot {
        model.replaceCharacters(in: range, with: replacement)
        let snapshot = await document.snapshot(atLeast: document.apply(TextEdit(range: range, replacement: replacement)))
        XCTAssertEqual(snapshot.text, model as String, message)
        let fresh = await MarkdownDocument(text: model as String).currentSnapshot()
        XCTAssertEqual(describe(snapshot), describe(fresh), message)
        return snapshot
    }

    /// Types `text` one character at a time at `offset`, returning the snapshot after each character.
    private func type(_ text: String, at offset: Int, _ message: String) async -> [Snapshot] {
        var result: [Snapshot] = []
        for (index, unit) in text.utf16.enumerated() {
            let edit = TextEdit(range: NSRange(location: offset + index, length: 0),
                                replacement: String(utf16CodeUnits: [unit], count: 1))
            result.append(await self.edit(edit.range, replacement: edit.replacement, "\(message), step \(index)"))
        }
        return result
    }

    /// The kind the snapshot renders for the block holding `offset`, and whether that kind is provisional.
    private func rendered(_ snapshot: Snapshot, at offset: Int) -> (kind: BlockKind, provisional: Bool)? {
        guard let block = snapshot.block(at: offset) else { return nil }
        guard let provisional = snapshot.provisional, provisional.id == block.id else { return (block.kind, false) }
        return (provisional.kind, true)
    }

    // Turns red if a table row under the caret stops rendering as a table before its delimiter row exists.
    func testTypingTableRowByRow() async {
        open("")
        let snapshots = await type("| a | b |", at: 0, "typing the header row")
        for (index, snapshot) in snapshots.enumerated() {
            // The settled kind stays a paragraph: only the kind to show is provisional.
            XCTAssertEqual(snapshot.block(at: index + 1)?.kind, .paragraph, "step \(index)")
            XCTAssertEqual(rendered(snapshot, at: index + 1)?.kind, .table, "step \(index)")
            XCTAssertEqual(rendered(snapshot, at: index + 1)?.provisional, true, "step \(index)")
        }
    }

    // Turns red if rows typed under a header row stop being held as one provisional table, or the row above moves.
    func testTypingRowsUnderAHeaderRow() async {
        open("| a | b |")
        let snapshots = await type("\n| c | d |", at: 9, "typing a second row")
        // The caret is between blocks just after the return, so nothing is provisional yet.
        XCTAssertEqual(rendered(snapshots[0], at: 10)?.kind, nil)
        XCTAssertNil(snapshots[0].provisional)
        // From the first pipe of the new row on, both rows are one provisional table.
        for (index, snapshot) in snapshots.dropFirst().enumerated() {
            let caret = 10 + index + 1
            XCTAssertEqual(rendered(snapshot, at: caret)?.kind, .table, "step \(index)")
            XCTAssertEqual(snapshot.block(at: caret)?.lineRange, 0..<2, "step \(index)")
        }
    }

    // Turns red if the table settles before its delimiter row is complete, or stays provisional after it.
    func testTypingTheDelimiterRow() async {
        open("| a | b |\n")
        let snapshots = await type("|---|---|", at: 10, "typing the delimiter row")
        var settled: Int?
        for (index, snapshot) in snapshots.enumerated() {
            let caret = 10 + index + 1
            let block = snapshot.block(at: caret)
            if block?.kind == .table {
                if settled == nil { settled = index }
                XCTAssertNil(snapshot.provisional, "step \(index) kept a provisional kind after settling")
            } else {
                let held = block.map { "\($0.kind)" } ?? "no block"
                XCTAssertNil(settled, "step \(index) went back to \(held)")
                XCTAssertEqual(rendered(snapshot, at: caret)?.kind, .table, "step \(index)")
            }
        }
        XCTAssertNotNil(settled, "the delimiter row never settled the table")
    }

    // Turns red if underlining a paragraph makes it flicker, or holds it provisionally after the underline.
    func testTypingSetextUnderline() async {
        open("Title")
        let snapshots = await type("\n===", at: 5, "typing the underline")
        // The paragraph is never held provisionally: the first `=` settles it as a heading at once.
        for snapshot in snapshots { XCTAssertNil(snapshot.provisional) }
        // The caret sits between blocks just after the return.
        XCTAssertNil(snapshots[0].block(at: 6))
        for snapshot in snapshots.dropFirst() {
            let kinds: [BlockKind] = snapshot.blocks.map(\.kind)
            XCTAssertEqual(kinds, [.setextHeading(level: 1)])
        }
    }

    // Turns red if a bare list marker stops being a list from the first character, or is held provisionally.
    func testTypingBareListMarker() async {
        for marker in ["-", "*", "+", "1.", "1)"] {
            open("")
            let snapshots = await type(marker, at: 0, "typing \(marker)")
            let last = snapshots.last!
            XCTAssertEqual(rendered(last, at: marker.utf16.count)?.provisional, false, marker)
            XCTAssertEqual(last.block(at: marker.utf16.count)?.kind,
                           marker.first == "1" ? .orderedList(start: 1) : .bulletList, marker)
            XCTAssertNil(last.provisional, marker)
        }
    }

    // Turns red if deleting back out of a table stops giving the rows above their shape, or holds a stale kind.
    func testDeletingBackOutOfTable() async {
        open("| a | b |")
        await type("\n\n| c |", at: 9, "typing a second table")
        let snapshot = await document.currentSnapshot()
        XCTAssertEqual(rendered(snapshot, at: model.length)?.kind, .table)
        // Four deletions leave one pipe, and the row is still a provisional table.
        for _ in 0..<4 {
            let after = await edit(NSRange(location: model.length - 1, length: 1), replacement: "", "deleting a character")
            XCTAssertEqual(rendered(after, at: model.length)?.kind, .table)
            XCTAssertEqual(rendered(after, at: model.length)?.provisional, true)
        }
        // Deleting the last pipe leaves a paragraph with nothing provisional.
        let last = await edit(NSRange(location: model.length - 1, length: 1), replacement: "", "deleting the last pipe")
        let kinds: [BlockKind] = last.blocks.map(\.kind)
        XCTAssertEqual(kinds, [.paragraph])
        XCTAssertNil(last.provisional)
    }

    // Turns red if deleting an underline or a list marker stops giving the block its settled kind back.
    func testDeletingBackOutOfUnderlineAndMarker() async {
        open("Title")
        await type("\n===", at: 5, "typing the underline")
        let steps: [[BlockKind]] = [[.setextHeading(level: 1)], [.setextHeading(level: 1)], [.paragraph]]
        for expected in steps {
            let snapshot = await edit(NSRange(location: model.length - 1, length: 1), replacement: "", "deleting a character")
            let kinds: [BlockKind] = snapshot.blocks.map(\.kind)
            XCTAssertEqual(kinds, expected)
            XCTAssertNil(snapshot.provisional)
        }

        open("para")
        await type("\n\n- x", at: 4, "typing a list marker and its text")
        let markerSteps: [[BlockKind]] = [[.paragraph, .bulletList], [.paragraph, .bulletList], [.paragraph]]
        for expected in markerSteps {
            let snapshot = await edit(NSRange(location: model.length - 1, length: 1), replacement: "", "deleting a character")
            let kinds: [BlockKind] = snapshot.blocks.map(\.kind)
            XCTAssertEqual(kinds, expected)
            XCTAssertNil(snapshot.provisional)
        }
    }

    // Turns red if a block stays provisional after the caret has moved to another block.
    func testCaretLeavingAnAmbiguousBlock() async {
        open("plain")
        await type("\n\n| a | b |", at: 5, "typing a table under a paragraph")
        let held = await document.currentSnapshot()
        XCTAssertEqual(rendered(held, at: model.length)?.kind, .table)
        // Typing in the first block moves the caret there, and the table block settles at once.
        let snapshot = await edit(NSRange(location: 0, length: 0), replacement: "x", "typing in the first block")
        let kinds: [BlockKind] = snapshot.blocks.map(\.kind)
        XCTAssertEqual(kinds, [.paragraph, .paragraph])
        XCTAssertNil(snapshot.provisional)
    }

    // Turns red if a fence inside a block of pipes stops being code, or the row above it stays provisional.
    func testFenceInsideAmbiguousBlock() async {
        open("| a | b |")
        let snapshots = await type("\n```\n| x | y |", at: 9, "typing a fence under a table row")
        guard let fence = snapshots.firstIndex(where: { $0.blocks.count == 2 }) else {
            return XCTFail("the fence never opened")
        }
        let last = snapshots.last!
        let kinds: [BlockKind] = last.blocks.map(\.kind)
        XCTAssertEqual(kinds, [.paragraph, .fencedCode(language: nil)])
        for snapshot in snapshots[fence...] { XCTAssertNil(snapshot.provisional) }
    }

    // Turns red if a line holding a `|` stops being held as a table while the caret is in it, which is the rule
    // Claude's scanner was measured to use.
    func testPipeInsideProseIsHeldAsATable() async {
        open("hello")
        await type(" | world", at: 5, "typing a pipe inside a sentence")
        let snapshot = await document.currentSnapshot()
        let kinds: [BlockKind] = snapshot.blocks.map(\.kind)
        XCTAssertEqual(kinds, [.paragraph])
        XCTAssertEqual(rendered(snapshot, at: model.length)?.kind, .table)
    }

    // Turns red if the snapshot stops carrying the pipe offsets the renderer splits cells on, or counts an
    // escaped `|` as one (issue 1).
    func testProvisionalBlockCarriesUnescapedPipeOffsets() async {
        open("| a | b |")
        await type("\n| c \\| d |", at: 9, "typing a row holding an escaped pipe")
        let snapshot = await document.currentSnapshot()
        let block = snapshot.block(at: model.length)!
        XCTAssertEqual(snapshot.provisional?.id, block.id)
        // Offsets of `|` in `| a | b |\n| c \| d |`, skipping the `|` the `\` escapes.
        let text = Array(snapshot.text.utf16)
        XCTAssertEqual(snapshot.provisional?.pipeOffsets, [0, 4, 8, 10, 19])
        for offset in snapshot.provisional!.pipeOffsets { XCTAssertEqual(text[offset], 124) }
    }

    // Turns red if a pipe inside a quote or a list item starts being held as a table: only a top-level paragraph
    // whose kind is still ambiguous is ever provisional.
    func testPipeInsideAQuoteOrListItemIsNotProvisional() async {
        open("> quote")
        await type(" | more", at: 6, "typing a pipe inside a quote")
        let quoted = await document.currentSnapshot()
        let quoteKinds: [BlockKind] = quoted.blocks.map(\.kind)
        XCTAssertEqual(quoteKinds, [.blockQuote])
        XCTAssertNil(quoted.provisional)

        open("- item")
        await type(" | more", at: 5, "typing a pipe inside a list item")
        let listed = await document.currentSnapshot()
        let listKinds: [BlockKind] = listed.blocks.map(\.kind)
        XCTAssertEqual(listKinds, [.bulletList])
        XCTAssertNil(listed.provisional)
    }

    // Turns red if front matter above an ambiguous block stops being front matter, or becomes provisional itself.
    func testFrontMatterAboveAmbiguousBlock() async {
        open("---\ntitle: x\n---\n\nplain")
        await type("\n\n| a | b |", at: model.length, "typing a table under front matter")
        let snapshot = await document.currentSnapshot()
        let kinds: [BlockKind] = snapshot.blocks.map(\.kind)
        XCTAssertEqual(kinds, [.frontMatter, .paragraph, .paragraph])
        XCTAssertEqual(snapshot.provisional?.id, snapshot.blocks[2].id)
        XCTAssertEqual(snapshot.provisional?.kind, BlockKind.table)
    }

    // Turns red if a document opened from disk with a half-typed table shows anything but a fresh parse.
    func testDocumentReopenedWithHalfTypedTable() async {
        let snapshot = await MarkdownDocument(text: "| a | b |").currentSnapshot()
        let kinds: [BlockKind] = snapshot.blocks.map(\.kind)
        XCTAssertEqual(kinds, [.paragraph])
        XCTAssertNil(snapshot.provisional)
    }

    // Turns red if editing one block changes the kind or the id of a block that had already settled.
    func testSettledBlockKeepsItsKindWhenAnotherBlockIsEdited() async {
        open("| a | b |\n|---|---|\n\nplain")
        let before = await document.currentSnapshot()
        let table = before.blocks[0]
        let snapshot = await edit(NSRange(location: model.range(of: "plain").location, length: 0), replacement: "x",
                                  "typing in the paragraph below the table")
        XCTAssertEqual(snapshot.blocks[0].id, table.id)
        XCTAssertEqual(snapshot.blocks[0].kind, .table)
        XCTAssertEqual(snapshot.blocks[0].range, table.range)
        // Only the paragraph that was typed in changed: the table kept its id, kind and range.
        XCTAssertEqual(snapshot.changedBlockIDs, Set([snapshot.blocks[1].id]))
        XCTAssertEqual(snapshot.removedBlockIDs, Set([before.blocks[1].id]))
        XCTAssertNil(snapshot.provisional)
    }
}

/// Issue 4: the caret reaches the parser whether or not the user typed, so leaving an ambiguous block by clicking
/// or by arrow key clears it, and entering one shows it.
final class ProvisionalCaretTests: XCTestCase {
    private var document: MarkdownDocument!

    private func open(_ text: String) {
        document = MarkdownDocument(text: text)
    }

    /// Moves the caret to `offset`, returning the snapshot the parser published, or nil when it published nothing
    /// because the kind to show did not change.
    private func caret(to offset: Int) async -> Snapshot? {
        await document.caretMoved(to: offset)
    }

    // Turns red if moving the caret out of a half-typed table leaves it on screen.
    func testCaretLeavingAnAmbiguousBlockClearsIt() async {
        open("| a | b |\n\nplain")
        // The caret starts in the table row, which the first snapshot holds provisionally.
        let held = await caret(to: 4)
        XCTAssertEqual(held?.provisional?.kind, .table)
        let table = held?.blocks[0]
        let after = await caret(to: (held!.text as NSString).range(of: "plain").location)
        XCTAssertNil(after?.provisional)
        // The block that stopped being provisional is re-rendered, so the page patches it back to a paragraph.
        XCTAssertEqual(after?.changedBlockIDs, Set([table!.id]))
        XCTAssertEqual(after?.blocks[0].kind, .paragraph)
        // Nothing about the text changed.
        XCTAssertEqual(after?.text, held?.text)
    }

    // Turns red if moving the caret into a half-typed table does not show it.
    func testCaretEnteringAnAmbiguousBlockShowsIt() async {
        open("| a | b |\n\nplain")
        let after = await caret(to: 4)
        XCTAssertEqual(after?.provisional?.kind, .table)
        XCTAssertEqual(after?.changedBlockIDs, Set([after!.blocks[0].id]))
    }

    // Turns red if a caret move between two settled blocks publishes a snapshot, which would re-render on every
    // arrow key.
    func testCaretMoveBetweenSettledBlocksPublishesNothing() async {
        open("| a | b |\n|---|---|\n\nplain\n\nmore")
        // The table is settled, so the caret moving into it publishes nothing either.
        let intoTable = await caret(to: 4)
        XCTAssertNil(intoTable)
        let text = (await document.currentSnapshot()).text as NSString
        let plain = text.range(of: "plain").location
        let more = text.range(of: "more").location
        let toFirst = await caret(to: plain)
        XCTAssertNil(toFirst, "caret at the first paragraph")
        let toSecond = await caret(to: more)
        XCTAssertNil(toSecond, "caret at the second paragraph")
        let toTop = await caret(to: 0)
        XCTAssertNil(toTop, "caret at the top")
    }

    // Turns red if a round trip out of an ambiguous block and back leaves it stale.
    func testCaretRoundTripRestoresTheTable() async {
        open("| a | b |\n\nplain")
        let text = (await document.currentSnapshot()).text as NSString
        _ = await caret(to: 4)
        let away = await caret(to: text.range(of: "plain").location)
        XCTAssertNil(away?.provisional)
        let back = await caret(to: 4)
        XCTAssertEqual(back?.provisional?.kind, .table)
    }

    // Turns red if an edit after a caret move forgets where the caret was.
    func testEditAfterCaretMoveKeepsTheCaret() async {
        open("plain")
        // The caret is in the paragraph, which is not ambiguous, so nothing is published for the move itself.
        let moved = await caret(to: 0)
        XCTAssertNil(moved)
        // Typing a table row at the caret has to show it as a table, because the caret is inside it.
        let version = document.apply(TextEdit(range: NSRange(location: 0, length: 0), replacement: "| a | b |\n\n"))
        let snapshot = await document.snapshot(atLeast: version)
        XCTAssertEqual(snapshot.blocks[0].kind, .paragraph)
        XCTAssertEqual(snapshot.provisional?.kind, .table)
        XCTAssertEqual(snapshot.provisional?.id, snapshot.blocks[0].id)
    }

    // Turns red if a caret move after an edit loses the edit's provisional classification, or disturbs its text.
    func testCaretMoveAfterAnEditKeepsTheEdit() async {
        open("| a | b |\n\nplain")
        // Typing inside the row leaves the caret inside it, so the edit's own snapshot holds it provisionally.
        let version = document.apply(TextEdit(range: NSRange(location: 4, length: 0), replacement: "x"))
        let typed = await document.snapshot(atLeast: version)
        XCTAssertEqual(typed.provisional?.kind, .table)
        // Moving the caret into the paragraph below must clear it without disturbing the table row's text.
        let after = await caret(to: (typed.text as NSString).range(of: "plain").location)
        XCTAssertNil(after?.provisional)
        XCTAssertEqual(after?.text, typed.text)
        XCTAssertEqual(after?.blocks.count, typed.blocks.count)
    }
}
