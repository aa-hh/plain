import XCTest

@testable import GitStatus

/// Runs git in `folder` with the user's global and system settings ignored, so signing or hooks cannot interfere.
@discardableResult
func runGit(_ arguments: [String], in folder: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Plain Tests", "-c", "user.email=tests@example.com"] + arguments
    process.currentDirectoryURL = folder
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    return String(decoding: data, as: UTF8.self)
}

final class GitStatusTests: XCTestCase {
    var repo: URL!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GitStatusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        repo = URL(fileURLWithPath: resolvedPath(url), isDirectory: true)
        try runGit(["init", "-q"], in: repo)
        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "keep\n".write(to: repo.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: repo)
        try runGit(["commit", "-q", "-m", "first"], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
    }

    func testCommittedTextEqualsTheCommit() async throws {
        // Fails if `committedText(of:)` reads the working file instead of `git show HEAD:<path>`.
        try "edited\n".write(to: repo.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        let status = GitStatus(folder: repo)
        let text = await status.committedText(of: repo.appendingPathComponent("a.md"))
        XCTAssertEqual(text, "one\ntwo\n")
        let missing = await status.committedText(of: repo.appendingPathComponent("never.md"))
        XCTAssertNil(missing)
    }

    func testStatusMarksChangedUntrackedAndDeleted() async throws {
        // Fails if `parseStatus` maps `M`, `??` or `D` to the wrong mark or drops the folder rule.
        try "one\nTWO\n".write(to: repo.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("b.md"))
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "new\n".write(to: repo.appendingPathComponent("sub/c.md"), atomically: true, encoding: .utf8)
        let status = GitStatus(folder: repo)
        await status.refreshStatus()
        let marks = await status.marks
        XCTAssertEqual(marks[repo.appendingPathComponent("a.md")], .changed)
        XCTAssertEqual(marks[repo.appendingPathComponent("b.md")], .deleted)
        XCTAssertEqual(marks[repo.appendingPathComponent("sub/c.md")], .added)
        XCTAssertEqual(marks[repo.appendingPathComponent("sub")], .added)
    }

    func testLineDiffFiveLines() {
        // Fails if `markLines` stops marking replaced lines `changed`, inserted lines `added`, or a deletion on one row.
        let marks = lineDiff(old: ["a", "b", "c", "d", "e"], new: ["a", "B", "c", "e", "f"])
        XCTAssertEqual(
            marks,
            [LineMark(line: 1, kind: .changed), LineMark(line: 3, kind: .deleted), LineMark(line: 4, kind: .added)])
    }

    func testLineDiffMyersFallbackOnRepeatedLines() {
        // Fails if the Myers fallback in `lineDiff` produces a wrong script for lines too common to anchor on.
        let old = Array(repeating: ["x", "y"], count: 200).flatMap { $0 }
        var new = old
        new.insert("z", at: 10)
        new.remove(at: 380)
        XCTAssertEqual(lineDiff(old: old, new: new), [LineMark(line: 10, kind: .added), LineMark(line: 380, kind: .deleted)])
    }
}
