import AppKit
import MarkdownDocument
import PlainDocument
import XCTest
@testable import EditorTextView

/// Release-only timings on a 1 MB document. Each prints `PERF <name> <value>`.
@MainActor
final class EditorPerformanceTests: XCTestCase {
    /// About 400 bytes of mixed Markdown repeated to at least 1,000,000 bytes.
    static let fixture: String = {
        let chunk = """
        ## Section heading

        A paragraph with **bold**, _italic_, `code`, a [link](https://example.com) and :smile: text.
        It wraps over two lines so the layout has some work to do on each one of them.

        - first item with ~~strike~~
        - [ ] a task item
        1. ordered item

        > a quote line

        ```swift
        let value = compute(1, 2)
        ```

        """
        var text = ""
        while text.utf8.count < 1_000_000 { text += chunk }
        return text
    }()

    static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }

    // Turns red if a keystroke on a 1 MB document takes over 8 ms p95 from insertText to laid-out viewport, or if
    // opening it takes over 300 ms to the first styled screen (for example, by restyling the whole file on load).
    func testKeystrokeAndLoad() async throws {
        #if DEBUG
        throw XCTSkip("Performance runs in release only")
        #else
        let text = Self.fixture
        let markdown = MarkdownDocument(text: text)
        _ = await markdown.currentSnapshot()
        let document = Document(text: text)

        let loadStart = ContinuousClock.now
        let editor = EditorTextView(document: document, markdown: markdown)
        host(editor)
        await editor.settle()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let load = ContinuousClock.now - loadStart
        let loadMs = Double(load.components.attoseconds) / 1e15 + Double(load.components.seconds) * 1000

        let middle = (text as NSString).length / 2
        let line = (text as NSString).lineRange(for: NSRange(location: middle, length: 0))
        editor.setSelectedRange(NSRange(location: line.location, length: 0))
        editor.scrollRangeToVisible(NSRange(location: line.location, length: 0))
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        await editor.settle()

        var times: [Double] = []
        for _ in 0..<200 {
            let start = ContinuousClock.now
            editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let elapsed = ContinuousClock.now - start
            times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            await editor.settle()
        }
        let p95 = Self.percentile95(times)
        print("PERF editor-keystroke-p95-ms \(String(format: "%.3f", p95))")
        print("PERF editor-load-visible-styled-ms \(String(format: "%.1f", loadMs))")
        XCTAssertLessThanOrEqual(p95, 8)
        XCTAssertLessThanOrEqual(loadMs, 300)
        #endif
    }

    // Turns red if switching back to a 1 MB tab takes over 50 ms to its styled screen, for example because the
    // tab's parser is rebuilt and the whole file reparsed, or the reattached editor restyles the whole file at once.
    func testTabSwitchBack() async throws {
        #if DEBUG
        throw XCTSkip("Performance runs in release only")
        #else
        let text = Self.fixture
        let markdown = MarkdownDocument(text: text)
        let document = Document(text: text)
        let first = EditorTextView(document: document, markdown: markdown)
        host(first)
        await first.settle()
        first.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        await first.settle()

        let other = await makeEditor("# Other tab\n")
        _ = other

        let start = ContinuousClock.now
        let back = EditorTextView(document: document, markdown: markdown)
        host(back)
        await back.settle()
        back.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("PERF tab-switch-1mb-ms \(String(format: "%.1f", ms))")
        XCTAssertEqual(back.snapshot?.text.utf16.count, document.textStorage.length)
        XCTAssertLessThanOrEqual(ms, 50)
        #endif
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
    }

    /// Waits until a measured editor's background restyle reaches the file's last code block, so it does not run into
    /// the next test's timing.
    static func drain(_ editor: EditorTextView) async {
        let last = (editor.text as NSString).range(of: "let value", options: .backwards).location
        _ = await waitUntil(timeout: 10) { editor.attribute(editor.isPage ? .plainPagePanel : .plainBand, at: last) != nil }
    }

    // Turns red if opening the 1 MB fixture with Show Markdown Source on takes over 300 ms to the first styled screen.
    func testLoadSourceView() async throws {
        #if DEBUG
        throw XCTSkip("Performance runs in release only")
        #else
        let text = Self.fixture
        let markdown = MarkdownDocument(text: text)
        _ = await markdown.currentSnapshot()
        let document = Document(text: text)
        let start = ContinuousClock.now
        let editor = EditorTextView(document: document, markdown: markdown, configuration: EditorConfiguration(showMarkdownSource: true))
        host(editor)
        await editor.settle()
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let ms = Self.milliseconds(ContinuousClock.now - start)
        print("PERF editor-load-visible-styled-source-ms \(String(format: "%.1f", ms))")
        await Self.drain(editor)
        XCTAssertLessThanOrEqual(ms, 300)
        #endif
    }

    // Turns red if a caret move on the page (snapping through hidden ranges) takes over 8 ms p95 to a laid-out viewport.
    func testCaretMove() async throws {
        #if DEBUG
        throw XCTSkip("Performance runs in release only")
        #else
        let text = Self.fixture
        let markdown = MarkdownDocument(text: text)
        let editor = EditorTextView(document: Document(text: text), markdown: markdown)
        host(editor)
        await editor.settle()
        let line = (text as NSString).lineRange(for: NSRange(location: (text as NSString).length / 2, length: 0))
        editor.setSelectedRange(NSRange(location: line.location, length: 0))
        editor.scrollRangeToVisible(NSRange(location: line.location, length: 0))
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        await editor.settle()
        var times: [Double] = []
        for index in 0..<200 {
            let start = ContinuousClock.now
            if index % 2 == 0 { editor.moveDown(nil) } else { editor.moveRight(nil) }
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            times.append(Self.milliseconds(ContinuousClock.now - start))
        }
        let p95 = Self.percentile95(times)
        print("PERF editor-caret-move-p95-ms \(String(format: "%.3f", p95))")
        await Self.drain(editor)
        XCTAssertLessThanOrEqual(p95, 8)
        #endif
    }

    // Turns red if Shift+Right with most of the 1 MB page selected lists every hidden range in the selection.
    func testShiftArrowOnLargeSelection() async throws {
        #if DEBUG
        throw XCTSkip("Performance runs in release only")
        #else
        let text = Self.fixture
        let markdown = MarkdownDocument(text: text)
        let editor = EditorTextView(document: Document(text: text), markdown: markdown)
        host(editor)
        await editor.settle()
        editor.setSelectedRange(NSRange(location: 0, length: editor.nsText.length - 200))
        var times: [Double] = []
        for _ in 0..<200 {
            let start = ContinuousClock.now
            editor.moveRightAndModifySelection(nil)
            editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
            times.append(Self.milliseconds(ContinuousClock.now - start))
        }
        let p95 = Self.percentile95(times)
        print("PERF editor-shift-arrow-selection-p95-ms \(String(format: "%.3f", p95))")
        await Self.drain(editor)
        XCTAssertLessThanOrEqual(p95, 8)
        #endif
    }

    // Turns red if Select All then Copy on the 1 MB page takes over 50 ms, for example when the separator pass in
    // `HiddenRanges.addSeparators` checks each blank line against every hidden range again.
    func testSelectAllCopyPage() async throws {
        #if DEBUG
        throw XCTSkip("Performance runs in release only")
        #else
        let text = Self.fixture
        let editor = EditorTextView(document: Document(text: text), markdown: MarkdownDocument(text: text))
        host(editor)
        await editor.settle()
        let start = ContinuousClock.now
        editor.selectAll(nil)
        editor.copy(nil)
        let ms = Self.milliseconds(ContinuousClock.now - start)
        print("PERF editor-select-all-page-ms \(String(format: "%.1f", ms))")
        XCTAssertEqual(NSPasteboard.general.string(forType: EditorTextView.markdownPasteboardType)?.utf16.count, (text as NSString).length)
        await Self.drain(editor)
        XCTAssertLessThanOrEqual(ms, 50)
        #endif
    }

    // Turns red if one query typed into the open Find bar on the 1 MB page takes over 50 ms, for example when each
    // query rebuilds the page's visible text through `HiddenRanges.list` instead of reusing it for the same snapshot.
    func testFindPage() async throws {
        #if DEBUG
        throw XCTSkip("Performance runs in release only")
        #else
        let text = Self.fixture
        let editor = EditorTextView(document: Document(text: text), markdown: MarkdownDocument(text: text))
        host(editor)
        await editor.settle()
        editor.openFind()
        let start = ContinuousClock.now
        editor.findQueryChanged("bold")
        let ms = Self.milliseconds(ContinuousClock.now - start)
        print("PERF editor-find-page-ms \(String(format: "%.1f", ms))")
        XCTAssertFalse(editor.find?.matches.isEmpty ?? true)
        editor.closeFind()
        await Self.drain(editor)
        XCTAssertLessThanOrEqual(ms, 50)
        #endif
    }

    // Turns red if handling one snapshot with Find open on the 1 MB page takes over 50 ms p95, for example when the
    // searched text's hidden-range list is built twice.
    func testKeystrokeWithFindOpen() async throws {
        #if DEBUG
        throw XCTSkip("Performance runs in release only")
        #else
        let text = Self.fixture
        let markdown = MarkdownDocument(text: text)
        let editor = EditorTextView(document: Document(text: text), markdown: markdown)
        host(editor)
        await editor.settle()
        editor.openFind()
        editor.findQueryChanged("xyzzy")
        let line = (text as NSString).lineRange(for: NSRange(location: (text as NSString).length / 2, length: 0))
        editor.setSelectedRange(NSRange(location: line.location, length: 0))
        editor.scrollRangeToVisible(NSRange(location: line.location, length: 0))
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        await editor.settle()
        var times: [Double] = []
        for _ in 0..<50 {
            editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            let snap = await markdown.snapshot(atLeast: editor.appliedVersion)
            let start = ContinuousClock.now
            editor.received(snap, initial: false)
            times.append(Self.milliseconds(ContinuousClock.now - start))
        }
        let p95 = Self.percentile95(times)
        print("PERF editor-keystroke-find-open-p95-ms \(String(format: "%.3f", p95))")
        editor.closeFind()
        await Self.drain(editor)
        XCTAssertLessThanOrEqual(p95, 50)
        #endif
    }

    // Turns red if moving a 200-line block in the 1 MB fixture takes over 50 ms from the edit to a laid-out viewport.
    func testBlockMove() async throws {
        #if DEBUG
        throw XCTSkip("Performance runs in release only")
        #else
        // The first chunk ends with its code block's closing fence; the new block goes after it, between blank lines.
        let chunkEnd = (Self.fixture as NSString).range(of: "```\n## ").location + 4
        let block = "\n```\n" + (0..<200).map { "line \($0) of the moved block" }.joined(separator: "\n") + "\n```\n\n"
        let text = (Self.fixture as NSString).replacingCharacters(in: NSRange(location: chunkEnd, length: 0), with: block)
        let markdown = MarkdownDocument(text: text)
        let editor = EditorTextView(document: Document(text: text), markdown: markdown)
        host(editor)
        await editor.settle()
        let nsText = text as NSString
        guard let snapshot = editor.snapshot,
              let moved = PageBlocks.block(at: chunkEnd + 6, snapshot: snapshot, text: nsText),
              let target = PageBlocks.block(at: nsText.lineRange(for: NSRange(location: nsText.length / 2, length: 0)).location, snapshot: snapshot, text: nsText)
                ?? PageBlocks.blocks(in: snapshot, text: nsText).first(where: { $0.range.location >= nsText.length / 2 }) else {
            return XCTFail("blocks not found")
        }
        XCTAssertEqual(moved.kind, .code)
        let change = PageBlocks.move(moved, before: target, text: nsText)
        let start = ContinuousClock.now
        editor.apply(change.edits, caret: change.caret)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let ms = Self.milliseconds(ContinuousClock.now - start)
        print("PERF editor-block-move-ms \(String(format: "%.1f", ms))")
        await editor.settle()
        XCTAssertLessThanOrEqual(ms, 50)
        #endif
    }
}
