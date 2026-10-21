import AppKit
import XCTest
@testable import PlainDocument

@MainActor
final class DocumentTests: TempFolderTestCase {
    private func type(_ text: String, into document: Document) {
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    }

    // Turns red if open stops converting CRLF and CR line endings to \n.
    func testOpenNormalisesLineEndings() async throws {
        let url = try write("a\r\nb\r\nc\r")
        let document = try await Document.open(url: url)
        XCTAssertEqual(document.text, "a\nb\nc\n")
    }

    // Turns red if the Latin-1 fallback for non-UTF-8 files is removed.
    func testOpenFallsBackToLatin1() async throws {
        let url = folder.appendingPathComponent("old.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: url)
        let document = try await Document.open(url: url)
        XCTAssertEqual(document.text, "café")
    }

    // Turns red if open stops throwing readProtected for an unreadable file.
    func testOpenUnreadableFileThrowsReadProtected() async throws {
        let url = try write("secret")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        do {
            _ = try await Document.open(url: url)
            XCTFail("expected readProtected")
        } catch DocumentError.readProtected {}
    }

    // Turns red if save writes in place instead of replacing the file (the file number would stay the same).
    func testSaveIsAtomic() async throws {
        let url = try write("old")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        let document = try await Document.open(url: url)
        type("new ", into: document)
        try await document.save()
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["note.md"])
    }

    // Turns red if save stops checking the folder before an atomic write.
    func testSaveInReadOnlyFolderThrowsFolderProtected() async throws {
        let url = try write("old")
        let document = try await Document.open(url: url)
        type("x", into: document)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        do {
            try await document.save()
            XCTFail("expected folderProtected")
        } catch DocumentError.folderProtected {}
        XCTAssertTrue(document.isEdited)
    }

    // Turns red if save stops refusing a read-only file in a writable folder.
    func testSaveReadOnlyFileThrowsWriteProtectedAndMakeWritableFixesIt() async throws {
        let url = try write("old")
        let document = try await Document.open(url: url)
        type("x", into: document)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        do {
            try await document.save()
            XCTFail("expected writeProtected")
        } catch DocumentError.writeProtected {}
        try document.makeWritable()
        try await document.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "xold")
    }

    // Turns red if isEdited starts reading the disk or stops resetting on save.
    func testEditedFlagFollowsEditsAndSave() async throws {
        let url = try write("old")
        let document = try await Document.open(url: url)
        XCTAssertFalse(document.isEdited)
        type("x", into: document)
        XCTAssertTrue(document.isEdited)
        try await document.save()
        XCTAssertFalse(document.isEdited)
    }

    // Turns red if untitled documents stop being backed by an empty file named with 10 random characters.
    func testUntitledDocumentHasEmptyBackingFile() async throws {
        let document = try Document.untitled(in: folder)
        XCTAssertTrue(document.isUntitled)
        XCTAssertEqual(document.displayName, "Untitled")
        let file = try XCTUnwrap(document.untitledURL)
        XCTAssertEqual(file.deletingPathExtension().lastPathComponent.count, 10)
        XCTAssertEqual(try Data(contentsOf: file).count, 0)
        do {
            try await document.save()
            XCTFail("expected untitled")
        } catch DocumentError.untitled {}
    }

    // Turns red if Save As stops adopting the new URL or removing the untitled backing file.
    func testSaveAsGivesUntitledDocumentAURL() async throws {
        let document = try Document.untitled(in: folder)
        type("hello", into: document)
        let target = folder.appendingPathComponent("Named.md")
        let backing = try XCTUnwrap(document.untitledURL)
        try await document.saveAs(url: target)
        XCTAssertEqual(document.displayName, "Named")
        XCTAssertEqual(document.fileExtension, "md")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "hello")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backing.path))
        XCTAssertFalse(document.isEdited)
    }

    // Turns red if the file presenter stops posting diskChanged for another process's write.
    func testPresenterNoticesOutsideWrite() async throws {
        let url = try write("old")
        let document = try await Document.open(url: url)
        document.startWatching()
        defer { document.stopWatching() }
        let noticed = expectation(description: "diskChanged")
        noticed.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(forName: .documentDiskChanged, object: document, queue: .main) { _ in
            noticed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await Task.sleep(for: .milliseconds(300))
        try Data("changed outside".utf8).write(to: url, options: .atomic)
        await fulfillment(of: [noticed], timeout: 2)
    }

    // Turns red if the presenter reports the document's own save as an outside change.
    func testPresenterIgnoresOwnSave() async throws {
        let url = try write("old")
        let document = try await Document.open(url: url)
        document.startWatching()
        defer { document.stopWatching() }
        let quiet = expectation(description: "no diskChanged")
        quiet.isInverted = true
        let token = NotificationCenter.default.addObserver(forName: .documentDiskChanged, object: document, queue: .main) { _ in
            quiet.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        type("x", into: document)
        try await document.save()
        await fulfillment(of: [quiet], timeout: 1)
    }

    // Turns red if finishWrite stops ignoring an older write that finishes after a newer one, which leaves an old
    // modification date behind and makes the next disk check reload the file.
    func testOverlappingSavesKeepNewestModificationDate() async throws {
        let url = try write("old")
        let document = try await Document.open(url: url)
        type("a", into: document)
        let pending = Task { try await document.save() }
        await Task.yield()
        // Block the main actor until the async write is on disk, so its result is taken in only after saveSync.
        let deadline = Date().addingTimeInterval(2)
        while (try? String(contentsOf: url, encoding: .utf8)) != "aold", Date() < deadline { usleep(1000) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "aold")
        type("b", into: document)
        try document.saveSync()
        let newest = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        try await pending.value
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "baold")
        XCTAssertEqual(document.lastDiskModificationDate, newest)
        XCTAssertFalse(document.isEdited)
    }
}
