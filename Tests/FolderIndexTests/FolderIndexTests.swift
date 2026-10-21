import XCTest

@testable import FolderIndex

/// A fresh folder under the temporary directory with symbolic links resolved, as FSEvents reports it.
func makeTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("FolderIndexTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: resolvedPath(url), isDirectory: true)
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: false, encoding: .utf8)
}

final class FolderIndexTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTempFolder()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSkipsDotFilesJunkAndSkippedFolders() async throws {
        // Fails if `FolderIndex.isSkipped` stops filtering dot names, junk names or `node_modules`.
        try write("x", to: folder.appendingPathComponent(".hidden"))
        try write("x", to: folder.appendingPathComponent(".DS_Store"))
        try write("x", to: folder.appendingPathComponent("node_modules/lib.md"))
        try write("x", to: folder.appendingPathComponent("kept.md"))
        let index = FolderIndex(root: folder)
        await index.start()
        let names = await index.tree.children.map(\.name)
        XCTAssertEqual(names, ["kept.md"])
    }

    func testFoldersFirstThenNaturalCaseInsensitiveOrder() async throws {
        // Fails if the sort in `FolderIndex.list` drops folders-first or uses plain string comparison.
        for name in ["C.md", "b.md", "a10.md", "a2.md"] { try write("x", to: folder.appendingPathComponent(name)) }
        for name in ["Zeta", "alpha"] {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let index = FolderIndex(root: folder)
        await index.start()
        let names = await index.tree.children.map(\.name)
        XCTAssertEqual(names, ["alpha", "Zeta", "a2.md", "a10.md", "b.md", "C.md"])
    }

    func testNewFileAppearsInChanges() async throws {
        // Fails if the FSEvents watcher is not started or `handle` stops yielding to `changes`.
        let index = FolderIndex(root: folder)
        await index.start()
        let newFile = folder.appendingPathComponent("new.md")
        let seen = expectation(description: "new file reported")
        let listener = Task {
            for await urls in index.changes where urls.contains(where: { $0.path == newFile.path }) {
                seen.fulfill()
                return
            }
        }
        try write("hello", to: newFile)
        await fulfillment(of: [seen], timeout: 3)
        listener.cancel()
        let files = await index.allFiles().map(\.path)
        XCTAssertTrue(files.contains(newFile.path))
    }

    func testTextCacheInvalidatesOnRewrite() async throws {
        // Fails if `text(of:)` returns the cached text without comparing the modification date.
        let file = folder.appendingPathComponent("note.md")
        try write("first", to: file)
        let index = FolderIndex(root: folder)
        let first = await index.text(of: file)
        XCTAssertEqual(first, "first")
        try write("second", to: file)
        let later = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: file.path)
        let second = await index.text(of: file)
        XCTAssertEqual(second, "second")
    }

    func testSearchFindsOnlyChunkStarts() async throws {
        // Fails if `hits(of:in:url:)` switches from `chunkStartMatch` to a plain substring match.
        try write("a foo b", to: folder.appendingPathComponent("yes.md"))
        try write("afoo b", to: folder.appendingPathComponent("no.md"))
        let index = FolderIndex(root: folder)
        await index.start()
        var hits: [SearchHit] = []
        for await batch in search("FOO", in: index) { hits += batch }
        XCTAssertEqual(hits.map(\.url.lastPathComponent), ["yes.md"])
        XCTAssertEqual(hits.first?.range, NSRange(location: 2, length: 3))
        XCTAssertEqual(hits.first?.lineText, "a foo b")
    }

    func testSearchTrimsLineToWordBoundary() async throws {
        // Fails if the 12-character left trim in `hit(line:…)` is removed or cuts mid-word.
        let line = "one two three four five six needle seven"
        let found = hits(of: "needle", in: line, url: folder)
        XCTAssertEqual(found.first?.lineText, "five six needle seven")
        XCTAssertEqual(found.first?.rangeInLineText, NSRange(location: 9, length: 6))
    }

    func testCancellationStopsTheStream() async throws {
        // Fails if `search` stops cancelling its task in `onTermination` or ignores `Task.isCancelled`.
        for number in 0..<400 {
            try write(String(repeating: "word hit\n", count: 20), to: folder.appendingPathComponent("f\(number).md"))
        }
        let index = FolderIndex(root: folder)
        await index.start()
        let consumer = Task { () -> Int in
            var total = 0
            for await batch in search("hit", in: index) {
                total += batch.count
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return total
        }
        let total = await consumer.value
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThan(total, 400 * 20)
    }

    func testFileOperations() throws {
        // Fails if `createFile` stops adding `.md` or handling a trailing `/`, `rename` overwrites, or
        // `freeName` puts the suffix anywhere but after the first dot-separated part.
        let created = try FileOperations.createFile(in: folder, name: "draft")
        XCTAssertEqual(created.lastPathComponent, "draft.md")
        let madeFolder = try FileOperations.createFile(in: folder, name: "Notes/")
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: madeFolder.path, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)

        try write("x", to: folder.appendingPathComponent("taken.md"))
        XCTAssertThrowsError(try FileOperations.rename(created, to: "taken.md")) { error in
            XCTAssertEqual(error as? FileOperationError, .renameClash)
        }

        let source = folder.appendingPathComponent("Notes/a.tar.gz")
        try write("x", to: source)
        let first = try FileOperations.copy([source], to: madeFolder)
        let second = try FileOperations.copy([source], to: madeFolder)
        XCTAssertEqual(first.map(\.lastPathComponent), ["a-1.tar.gz"])
        XCTAssertEqual(second.map(\.lastPathComponent), ["a-2.tar.gz"])
    }
}
