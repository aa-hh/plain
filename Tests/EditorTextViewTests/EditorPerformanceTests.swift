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
}
