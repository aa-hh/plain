import XCTest
import MarkdownDocument
@testable import PreviewRenderer

/// A page that records every message instead of running a web view.
@MainActor
final class RecordingPage: PreviewPage {
    var onTask: ((Int) -> Void)?
    var onLink: ((String) -> Void)?
    var messages: [PreviewMessage] = []
    var computedVariables: [String: String] = [:]
    var padding: String? = "10px 20px"

    func send(_ message: PreviewMessage) { messages.append(message) }
    func blockTops() async -> [String: Double] { [:] }
    func computedStyle(variables: [String]) async -> (variables: [String: String], padding: String?) { (computedVariables, padding) }

    var updates: [(patches: [PreviewPatch], removals: [String])] {
        messages.compactMap { if case .update(let patches, let removals) = $0 { (patches, removals) } else { nil } }
    }
}

@MainActor
final class PreviewControllerTests: XCTestCase {
    func makeController(_ text: String) async -> (PreviewController, RecordingPage, MarkdownDocument) {
        let page = RecordingPage()
        let controller = PreviewController(page: page, math: FakeMathRenderer())
        let document = MarkdownDocument(text: text)
        await controller.show(document: document, fileURL: nil)
        page.messages.removeAll()
        return (controller, page, document)
    }

    func waitForMessages(_ page: RecordingPage, timeout: Duration = .seconds(1)) async {
        let deadline = ContinuousClock.now + timeout
        while page.messages.isEmpty && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(100))
    }

    // Turns red if editing one paragraph sends more than one patch, a removal or a full replace.
    func testEditedParagraphSendsOnePatch() async {
        let (controller, page, document) = await makeController("one\n\ntwo\n\nthree")
        document.apply(TextEdit(range: NSRange(location: 8, length: 0), replacement: "x"))
        await waitForMessages(page)
        withExtendedLifetime(controller) {}
        XCTAssertEqual(page.messages.count, 1)
        XCTAssertEqual(page.updates.first?.patches.count, 1)
        XCTAssertEqual(page.updates.first?.removals, [])
        XCTAssertTrue(page.updates.first?.patches.first?.html.contains(">twox</p>") == true)
        XCTAssertNil(page.updates.first?.patches.first?.before)
    }

    // Turns red if a new block is sent without the `before` neighbour that places it.
    func testInsertionUsesBefore() async {
        let (controller, page, document) = await makeController("one\n\ntwo\n\nthree")
        document.apply(TextEdit(range: NSRange(location: 5, length: 0), replacement: "new\n\n"))
        await waitForMessages(page)
        guard let update = page.updates.first else { return XCTFail("no update: \(page.messages)") }
        let inserted = update.patches.filter { $0.before != nil }
        XCTAssertFalse(inserted.isEmpty, "\(update.patches)")
        let threeID = controller.snapshot!.blocks.last!.id.rawValue
        XCTAssertEqual(inserted.last?.before, String(threeID))
        XCTAssertTrue(update.patches.contains { $0.html.contains(">new</p>") })
        XCTAssertEqual(controller.pageOrder.count, 4)
    }

    // Turns red if quick edits stop being merged into one page message per 16 ms.
    func testTenQuickEditsSendOneMessage() async {
        let (controller, page, document) = await makeController("alpha\n\nbeta\n\ngamma")
        for index in 0..<10 { document.apply(TextEdit(range: NSRange(location: 11 + index, length: 0), replacement: "z")) }
        try? await Task.sleep(for: .milliseconds(300))
        withExtendedLifetime(controller) {}
        XCTAssertEqual(page.messages.count, 1, "\(page.messages)")
        XCTAssertTrue(page.updates.first?.patches.first?.html.contains("betazzzzzzzzzz") == true)
    }

    // Turns red if a block the caret is still typing sends a full document replace instead of one patch (issue 1).
    func testProvisionalBlockSendsOnePatch() async {
        let (controller, page, document) = await makeController("one\n\n| a | b |\n\nthree")
        let table = controller.snapshot!.blocks[1]
        document.apply(TextEdit(range: NSRange(location: table.range.location + 1, length: 0), replacement: "x"))
        await waitForMessages(page)
        withExtendedLifetime(controller) {}
        XCTAssertEqual(page.messages.count, 1, "\(page.messages)")
        XCTAssertEqual(page.updates.first?.removals, [])
        XCTAssertEqual(page.updates.first?.patches.count, 1)
        XCTAssertEqual(page.updates.first?.patches.first?.id, String(table.id.rawValue))
        XCTAssertTrue(page.updates.first?.patches.first?.html.contains("<table") == true)
        XCTAssertNil(page.updates.first?.patches.first?.before)
    }

    // Turns red if a block that stops being provisional keeps its stale `<table>` on screen. The block keeps its id
    // and its settled kind when the caret leaves it, so it has to be named as changed to be patched back (issue 1).
    func testCaretLeavingAProvisionalBlockRepatchesIt() async {
        let (controller, page, document) = await makeController("one\n\n| a | b |\n\nthree")
        let first = controller.snapshot!.blocks[1]
        document.apply(TextEdit(range: NSRange(location: first.range.location + 1, length: 0), replacement: "x"))
        await waitForMessages(page)
        withExtendedLifetime(controller) {}
        let table = controller.snapshot!.blocks[1]
        XCTAssertTrue(page.updates.last?.patches.contains { $0.html.contains("<table") } == true, "\(page.messages)")
        page.messages.removeAll()

        // Typing in the first block moves the caret there, and the table block is a paragraph again.
        document.apply(TextEdit(range: NSRange(location: 0, length: 0), replacement: "y"))
        await waitForMessages(page)
        withExtendedLifetime(controller) {}
        guard let patch = page.updates.last?.patches.first(where: { $0.id == String(table.id.rawValue) }) else {
            return XCTFail("the block that stopped being provisional was never patched: \(page.messages)")
        }
        XCTAssertTrue(patch.html.contains("<p data-block=\"\(table.id.rawValue)\""), patch.html)
        XCTAssertFalse(patch.html.contains("<table"), patch.html)
    }
}
