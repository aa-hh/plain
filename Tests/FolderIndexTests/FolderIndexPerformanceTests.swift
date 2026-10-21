import XCTest

@testable import FolderIndex

final class FolderIndexPerformanceTests: XCTestCase {
    func testIndexAndSearchFiveThousandFiles() async throws {
        #if DEBUG
            throw XCTSkip("Performance targets apply to release builds only.")
        #else
            // Fails if indexing 5,000 files in 50 folders takes over 2 s, or a warm search over them over 300 ms.
            let folder = try makeTempFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let line = "The quick brown fox jumps over the lazy dog and keeps running far away.\n"
            let body = String(repeating: line, count: 2048 / line.utf8.count)
            for folderNumber in 0..<50 {
                let sub = folder.appendingPathComponent("folder \(folderNumber)")
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
                for fileNumber in 0..<100 {
                    let text = fileNumber == 0 ? body + "a needle here\n" : body
                    try text.write(
                        to: sub.appendingPathComponent("file \(fileNumber).md"), atomically: false, encoding: .utf8)
                }
            }

            let index = FolderIndex(root: folder)
            let clock = ContinuousClock()
            let indexTime = await clock.measure { await index.start() }
            let fileCount = await index.allFiles().count
            XCTAssertEqual(fileCount, 5000)

            for url in await index.allFiles() { _ = await index.text(of: url) }
            var hits = 0
            let searchTime = await clock.measure {
                for await batch in search("needle", in: index) { hits += batch.count }
            }
            XCTAssertEqual(hits, 50)

            let indexMS = Double(indexTime.components.attoseconds) / 1e15 + Double(indexTime.components.seconds) * 1000
            let searchMS = Double(searchTime.components.attoseconds) / 1e15 + Double(searchTime.components.seconds) * 1000
            print(String(format: "PERF folder-index-5000-files %.1f ms", indexMS))
            print(String(format: "PERF folder-search-5000-files %.1f ms", searchMS))
            XCTAssertLessThanOrEqual(indexMS, 2000)
            XCTAssertLessThanOrEqual(searchMS, 300)
        #endif
    }
}
