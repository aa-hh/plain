import Foundation
import XCTest
import MarkdownDocument

final class MarkdownDocumentPerformanceTests: XCTestCase {
    /// A mixed chunk of about 400 bytes repeated to at least 1,000,000 bytes.
    static let fixture: String = {
        let chunk = """
        # Section heading

        Some *emphasis*, **strong**, `code`, a [link](https://example.com), :smile: and $x^2$ in a sentence that runs on.
        - item one
        - [x] task item
        > a quoted line with [ref] in it

        ```swift
        let value = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        [ref]: https://ref.example
        A closing paragraph with ::marked:: text and https://plain.example/path.


        """
        var text = ""
        while text.utf8.count < 1_000_000 { text += chunk }
        return text
    }()

    private func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    func testInitialParse() throws {
        // Fails if a full parse of 1 MB takes longer than 600 ms in a release build.
        #if DEBUG
        throw XCTSkip("Performance targets apply to release builds only")
        #else
        let clock = ContinuousClock()
        let start = clock.now
        _ = MarkdownDocument(text: Self.fixture)
        let elapsed = milliseconds(clock.now - start)
        print("PERF markdown_init_ms \(String(format: "%.1f", elapsed))")
        XCTAssertLessThanOrEqual(elapsed, 600)
        #endif
    }

    func testTypingOneCharacter() async throws {
        // Fails if `apply` stops returning at once or a one-character edit stops reparsing only a window.
        #if DEBUG
        throw XCTSkip("Performance targets apply to release builds only")
        #else
        let document = MarkdownDocument(text: Self.fixture)
        let text = Self.fixture as NSString
        let offset = text.range(of: "runs on", options: [], range: NSRange(location: text.length / 2, length: text.length / 2)).location
        let clock = ContinuousClock()
        var applyTimes: [Double] = []
        var snapshotTimes: [Double] = []
        for index in 0..<200 {
            let start = clock.now
            let version = document.apply(TextEdit(range: NSRange(location: offset + index, length: 0), replacement: "x"))
            let applied = clock.now
            _ = await document.snapshot(atLeast: version)
            let done = clock.now
            applyTimes.append(milliseconds(applied - start))
            snapshotTimes.append(milliseconds(done - start))
        }
        let applyP95 = percentile95(applyTimes)
        let snapshotP95 = percentile95(snapshotTimes)
        print("PERF markdown_apply_p95_ms \(String(format: "%.3f", applyP95))")
        print("PERF markdown_snapshot_p95_ms \(String(format: "%.2f", snapshotP95))")
        XCTAssertLessThanOrEqual(applyP95, 1)
        XCTAssertLessThanOrEqual(snapshotP95, 16)
        #endif
    }
}
