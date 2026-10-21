import AppKit
import GitStatus
import XCTest
@testable import EditorTextView

@MainActor
final class GitMarksTests: XCTestCase {
    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    // Spec 376. Turns red if editing a committed file stops producing a changed mark for the edited line, or an added
    // line stops being marked added.
    func testMarksChangedAndAddedLines() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("a.md")
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["init", "-q"], in: folder)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "add", "."], in: folder)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "x"], in: folder)

        let editor = await makeEditor("one\ntwo\nthree\n", url: file)
        editor.bind(gitStatus: GitStatus(folder: folder))
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        await editor.type("X")
        let changed = await waitUntil { editor.gitMarks[1] == .changed }
        XCTAssertTrue(changed)
        editor.setSelectedRange(NSRange(location: editor.text.utf16.count, length: 0))
        await editor.type("four\n")
        let added = await waitUntil { editor.gitMarks[3] == .added }
        XCTAssertTrue(added)
        XCTAssertNil(editor.gitMarks[0])
    }

    // Spec 377. Turns red if marks stay after the editor is told there is no repository.
    func testNoRepositoryClearsMarks() async {
        let editor = await makeEditor("x\n", url: URL(fileURLWithPath: "/tmp/none.md"))
        editor.gitMarks = [0: .added]
        editor.bind(gitStatus: nil)
        XCTAssertTrue(editor.gitMarks.isEmpty)
    }

    // Spec 1511. Turns red if the mark is drawn anywhere but 30 pt right of the column for the marked line.
    func testMarkLineLookup() async {
        let editor = await makeEditor("a\nb\nc\n")
        editor.gitLineStarts = [0, 2, 4, 6]
        XCTAssertEqual(editor.gitLine(at: 0), 0)
        XCTAssertEqual(editor.gitLine(at: 3), 1)
        XCTAssertEqual(editor.gitLine(at: 4), 2)
    }
}
