import AppKit
import XCTest
import PlainCore
@testable import PlainDocument

final class FileHistoryTests: TempFolderTestCase {
    private func makeHistory() -> FileHistory {
        FileHistory(store: StateStore(folder: folder.appendingPathComponent("state")),
                    unsaved: UnsavedFiles(folder: folder.appendingPathComponent("unsaved")))
    }

    // Turns red if the limit stops being 50 or the drop picks an entry with unsaved edits.
    func testDropsOldestNonUnsavedAtFiftyOne() async throws {
        let history = makeHistory()
        let start = Date(timeIntervalSince1970: 1_000_000)
        // f0 is the oldest and has unsaved edits; f1 is the oldest without.
        for i in 0..<51 {
            try await history.record(FileHistoryEntry(path: "/f\(i)", hasUnsavedEdits: i == 0, lastUsed: start.addingTimeInterval(Double(i))))
        }
        let paths = await history.all().map(\.path)
        XCTAssertEqual(paths.count, 50)
        XCTAssertTrue(paths.contains("/f0"))
        XCTAssertFalse(paths.contains("/f1"))
        XCTAssertEqual(paths.first, "/f50")
    }

    // Turns red if the history stops being saved to or loaded from state/file-history.json.
    func testHistorySurvivesRestart() async throws {
        try await makeHistory().record(FileHistoryEntry(path: "/a", scrollOffset: 42, selection: [StoredRange(location: 3, length: 2)]))
        let again = await makeHistory().all()
        XCTAssertEqual(again.first?.scrollOffset, 42)
        XCTAssertEqual(again.first?.selection, [StoredRange(location: 3, length: 2)])
    }

    // Turns red if the six-hour limit moves, or unsaved text starts expiring with it.
    func testViewStateExpiresAfterSixHoursButUnsavedTextDoesNot() async throws {
        let history = makeHistory()
        let used = Date(timeIntervalSince1970: 2_000_000)
        try await history.record(FileHistoryEntry(path: "/a", scrollOffset: 9, lastUsed: used))
        try await history.record(FileHistoryEntry(path: "/b", hasUnsavedEdits: true, lastUsed: used))
        let unsaved = UnsavedFiles(folder: folder.appendingPathComponent("unsaved"))
        try unsaved.store("draft text", for: "/b")
        let fresh = await history.restorableState(for: "/a", now: used.addingTimeInterval(5 * 3600))
        XCTAssertEqual(fresh?.scrollOffset, 9)
        let stale = await history.restorableState(for: "/a", now: used.addingTimeInterval(6 * 3600 + 1))
        XCTAssertNil(stale)
        let text = await history.unsavedText(for: "/b")
        XCTAssertEqual(text, "draft text")
        let none = await history.unsavedText(for: "/a")
        XCTAssertNil(none)
    }

    // Turns red if "Don't save" stops removing both the entry and the stored unsaved text.
    func testDiscardRemovesEntryAndUnsavedText() async throws {
        let history = makeHistory()
        try await history.record(FileHistoryEntry(path: "/b", hasUnsavedEdits: true))
        let unsaved = UnsavedFiles(folder: folder.appendingPathComponent("unsaved"))
        try unsaved.store("draft", for: "/b")
        try await history.discard(path: "/b")
        let entries = await history.all()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(unsaved.text(for: "/b"))
    }

    // Turns red if record(document) stops writing the unsaved text of an edited document.
    @MainActor
    func testRecordingEditedDocumentStoresItsText() async throws {
        let history = makeHistory()
        let document = Document(text: "abc", url: folder.appendingPathComponent("x.md"))
        document.textStorage.replaceCharacters(in: NSRange(location: 3, length: 0), with: "d")
        document.scrollOffset = 12
        try await history.record(document)
        let text = await history.unsavedText(for: folder.appendingPathComponent("x.md").path)
        XCTAssertEqual(text, "abcd")
    }
}
