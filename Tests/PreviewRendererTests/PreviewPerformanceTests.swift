import XCTest
import MarkdownDocument
@testable import PreviewRenderer

final class PreviewPerformanceTests: XCTestCase {
    /// About 400 bytes of mixed Markdown, repeated to at least 1,000,000 bytes.
    static let chunk = """
    ## Section heading

    A paragraph with **bold**, *italic*, `code`, a [link](https://example.com) and :smile: emoji.

    - first item with ::mark::
    - [x] a finished task

    > A quote that runs on
    > over two lines.

    ```swift
    let total = values.reduce(0, +)
    ```

    | a | b |
    |---|---|
    | 1 | $x^2$ |


    """

    static func fixture() -> String {
        var text = ""
        while text.utf8.count < 1_000_000 { text += chunk }
        return text
    }

    // Turns red if rendering the whole 1 MB document takes over 500 ms in a release build.
    func testFullDocument() async throws {
        #if DEBUG
        throw XCTSkip("Performance thresholds apply to release builds only")
        #else
        let snapshot = await MarkdownDocument(text: Self.fixture()).currentSnapshot()
        let renderer = HTMLRenderer()
        // Load KaTeX and render the chunk's formula once, as the first preview of any document with math does.
        _ = renderer.html(for: await MarkdownDocument(text: Self.chunk).currentSnapshot())
        let start = ContinuousClock.now
        let html = renderer.html(for: snapshot)
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("PERF preview-full-html-ms \(String(format: "%.1f", ms)) (\(snapshot.blocks.count) blocks, \(html.utf8.count) bytes)")
        XCTAssertLessThanOrEqual(ms, 500)
        #endif
    }

    // Turns red if rendering one changed block of the 1 MB document takes over 20 ms (p95) in a release build.
    func testOneChangedBlock() async throws {
        #if DEBUG
        throw XCTSkip("Performance thresholds apply to release builds only")
        #else
        let snapshot = await MarkdownDocument(text: Self.fixture()).currentSnapshot()
        let renderer = HTMLRenderer()
        let block = snapshot.blocks[snapshot.blocks.count / 2 + 1]
        let p95 = Self.p95 { _ = renderer.html(for: block, in: snapshot) }
        print("PERF preview-one-block-p95-ms \(String(format: "%.2f", p95))")
        XCTAssertLessThanOrEqual(p95, 20)
        #endif
    }

    // Turns red if one preview flush (one changed block plus the footnotes section) of the 1 MB document takes over
    // 20 ms (p95) in a release build, when every section cites a footnote and an edit near the top moved every block.
    func testOneChangedBlockWithFootnotes() async throws {
        #if DEBUG
        throw XCTSkip("Performance thresholds apply to release builds only")
        #else
        let text = Self.fixture().replacingOccurrences(of: "emoji.", with: "emoji[^n].")
        let document = MarkdownDocument(text: "Intro[^n].\n\n" + text + "[^n]: The note.\n")
        let snapshot = await document.snapshot(atLeast: document.apply(TextEdit(range: NSRange(location: 0, length: 0), replacement: "x")))
        let renderer = HTMLRenderer()
        let block = snapshot.blocks[snapshot.blocks.count / 2 + 1]
        let p95 = Self.p95 { _ = renderer.html(for: [block], in: snapshot) }
        print("PERF preview-one-block-footnotes-p95-ms \(String(format: "%.2f", p95))")
        XCTAssertLessThanOrEqual(p95, 20)
        #endif
    }

    /// Milliseconds, 95th percentile of 50 timed runs after one untimed run.
    static func p95(_ body: () -> Void) -> Double {
        body()
        var samples: [Double] = []
        for _ in 0..<50 {
            let start = ContinuousClock.now
            body()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        samples.sort()
        return samples[Int(Double(samples.count) * 0.95) - 1]
    }
}
