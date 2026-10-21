import XCTest

@testable import GitStatus

final class GitStatusPerformanceTests: XCTestCase {
    func testTenThousandLineDiff() throws {
        #if DEBUG
            throw XCTSkip("Performance targets apply to release builds only.")
        #else
            // Fails if `lineDiff` on two 10,000-line texts differing in 20 lines takes over 30 ms (median of 5).
            let old = (0..<10_000).map { "Line \($0) of the committed text, with some words after it." }
            var new = old
            for change in 0..<20 { new[change * 500 + 7] = "Edited line \(change)" }
            let clock = ContinuousClock()
            var times: [Double] = []
            var marks: [LineMark] = []
            for _ in 0..<5 {
                let time = clock.measure { marks = lineDiff(old: old, new: new) }
                times.append(Double(time.components.attoseconds) / 1e15 + Double(time.components.seconds) * 1000)
            }
            XCTAssertEqual(marks.count, 20)
            let median = times.sorted()[2]
            print(String(format: "PERF git-line-diff-10k-lines %.2f ms", median))
            XCTAssertLessThanOrEqual(median, 30)
        #endif
    }
}
