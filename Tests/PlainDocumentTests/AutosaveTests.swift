import AppKit
import XCTest
@testable import PlainDocument

@MainActor
final class AutosaveTests: TempFolderTestCase {
    private func type(_ text: String, into document: Document) {
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    }

    // Turns red if the delay stops being 500 ms (earlier write at 200 ms, or no write by 900 ms).
    func testSavesAfterDelayNotBefore() async throws {
        let url = try write("old")
        let document = try await Document.open(url: url)
        let autosave = AutosaveController(document: document)
        type("new ", into: document)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new old")
        XCTAssertFalse(document.isEdited)
        XCTAssertNil(autosave.lastError)
    }

    // Turns red if autosave starts writing untitled documents.
    func testNeverSavesUntitled() async throws {
        let document = try Document.untitled(in: folder)
        let autosave = AutosaveController(document: document)
        type("draft", into: document)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(document.untitledURL)).count, 0)
        XCTAssertTrue(document.isEdited)
        XCTAssertTrue(autosave.showsEditedMark)
    }

    // Turns red if autosave starts writing the Preferences file, which is parsed on a hand save.
    func testNeverSavesPreferencesFile() async throws {
        let url = try write("a: 1")
        let document = try await Document.open(url: url)
        document.isPreferencesFile = true
        let autosave = AutosaveController(document: document)
        type("b", into: document)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a: 1")
        XCTAssertTrue(autosave.showsEditedMark)
    }

    // Turns red if flushSync returns before the file is written.
    func testFlushSyncWritesImmediately() async throws {
        let url = try write("old")
        let document = try await Document.open(url: url)
        let autosave = AutosaveController(document: document)
        type("x", into: document)
        autosave.flushSync()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "xold")
    }

    // Turns red if the edited mark shows while autosave is on, or hides while it is off.
    func testEditedMarkHiddenOnlyWhileAutosaveOn() async throws {
        let url = try write("old")
        let document = try await Document.open(url: url)
        let autosave = AutosaveController(document: document, delay: .seconds(60))
        type("x", into: document)
        XCTAssertFalse(autosave.showsEditedMark)
        autosave.enabled = false
        XCTAssertTrue(autosave.showsEditedMark)
    }
}
