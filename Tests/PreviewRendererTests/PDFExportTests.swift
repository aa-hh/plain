import XCTest
import PDFKit
import MarkdownDocument
@testable import PreviewRenderer

@MainActor
final class PDFExportTests: XCTestCase {
    // Turns red if `+++` stops forcing a new page in PDF export, or PDF export stops working off screen.
    func testPageBreakGivesTwoPages() async throws {
        let controller = PreviewController(math: FakeMathRenderer())
        await controller.show(document: MarkdownDocument(text: "Page one\n\n+++\n\nPage two"), fileURL: nil)
        await controller.webPage?.waitUntilLoaded()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plain-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let done = expectation(description: "PDF written")
        Task {
            do { try await controller.exportPDF(to: url) } catch { XCTFail("export failed: \(error)") }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        let pages = PDFDocument(url: url)?.pageCount ?? 0
        print("PDF pages: \(pages)")
        XCTAssertEqual(pages, 2)
    }
}
