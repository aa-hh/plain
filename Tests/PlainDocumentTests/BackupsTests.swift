import XCTest
import PlainCore
@testable import PlainDocument

final class BackupsTests: TempFolderTestCase {
    private func makeBackups() -> Backups {
        Backups(folder: folder.appendingPathComponent("file-revisions"), store: StateStore(folder: folder.appendingPathComponent("state")))
    }

    private let path = "/Users/a/Notes/x.md"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // Turns red if the folder encoding stops swapping "/" for "__--__" or stops dropping the extension.
    func testFolderNameEncoding() async throws {
        let name = try await makeBackups().folderName(for: path)
        XCTAssertEqual(name, "__--__Users__--__a__--__Notes__--__x")
    }

    // Turns red if a path too long for a folder name stops getting a remembered random 16-character name.
    func testLongPathGetsRememberedRandomName() async throws {
        let long = "/" + String(repeating: "abcdefghij/", count: 30) + "x.md"
        let backups = makeBackups()
        let first = try await backups.folderName(for: long)
        XCTAssertEqual(first.count, 16)
        let again = try await makeBackups().folderName(for: long)
        XCTAssertEqual(first, again)
    }

    // Turns red if the due rule changes: none, or newest over an hour old with a different length.
    func testDueRule() async throws {
        let backups = makeBackups()
        let none = try await backups.isDue(path: path, text: "abc", now: start)
        XCTAssertTrue(none)
        try await backups.requestBackup(path: path, text: "abc", now: start)
        let written = try await backups.recordLineBreakInserted(path: path, text: "abc", now: start)
        XCTAssertTrue(written)
        let recent = try await backups.isDue(path: path, text: "abcdef", now: start.addingTimeInterval(1800))
        XCTAssertFalse(recent)
        let oldSameLength = try await backups.isDue(path: path, text: "xyz", now: start.addingTimeInterval(7200))
        XCTAssertFalse(oldSameLength)
        let oldDifferent = try await backups.isDue(path: path, text: "abcdef", now: start.addingTimeInterval(7200))
        XCTAssertTrue(oldDifferent)
    }

    // Turns red if a backup is written without a line break, or the file name stops being a yyyy-MM-dd'T'HH-mm-ss timestamp.
    func testBackupWrittenOnlyAtLineBreakWithTimestampName() async throws {
        let backups = makeBackups()
        let early = try await backups.recordLineBreakInserted(path: path, text: "abc", now: start)
        XCTAssertFalse(early)
        try await backups.requestBackup(path: path, text: "abc", now: start)
        try await backups.recordLineBreakInserted(path: path, text: "abc", now: start)
        let list = try await backups.list(for: path)
        XCTAssertEqual(list.count, 1)
        XCTAssertNotNil(list[0].name.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}$"#, options: .regularExpression))
        let text = try await backups.text(of: list[0])
        XCTAssertEqual(text, "abc")
        let again = try await backups.recordLineBreakInserted(path: path, text: "abcd", now: start.addingTimeInterval(5))
        XCTAssertFalse(again)
    }

    // Turns red if list stops returning newest first, or rename stops moving the folder.
    func testListNewestFirstAndRename() async throws {
        let backups = makeBackups()
        for (i, text) in ["a", "bb", "ccc"].enumerated() {
            let now = start.addingTimeInterval(Double(i) * 7200)
            try await backups.requestBackup(path: path, text: text, now: now)
            try await backups.recordLineBreakInserted(path: path, text: text, now: now)
        }
        let list = try await backups.list(for: path)
        let texts = try await list.asyncMap { try await backups.text(of: $0) }
        XCTAssertEqual(texts, ["ccc", "bb", "a"])
        try await backups.rename(from: path, to: "/Users/a/Notes/y.md")
        let old = try await backups.list(for: path)
        let moved = try await backups.list(for: "/Users/a/Notes/y.md")
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(moved.count, 3)
    }

    // Turns red if any slot size in the thinning rule changes (1 per hour today, 8 days, 4 weeks, 23 months).
    func testThinningOverFortyTimestamps() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        var dates: [Date] = []
        // 10 within hour 11 today.
        for i in 1...10 { dates.append(now.addingTimeInterval(-Double(i) * 300)) }
        // 2 on each of the 8 days before today.
        for day in 1...8 {
            let noon = calendar.date(byAdding: .day, value: -day, to: now)!
            dates.append(noon)
            dates.append(noon.addingTimeInterval(-3600))
        }
        // 2 in each of 4 weeks.
        for day in [10, 12, 17, 19, 24, 26, 31, 33] { dates.append(calendar.date(byAdding: .day, value: -day, to: now)!) }
        // Months ago: 2, 2, 5, 5, 24, 30.
        for months in [2, 5] {
            let a = calendar.date(byAdding: .month, value: -months, to: now)!
            dates.append(a)
            dates.append(a.addingTimeInterval(-86400 * 3))
        }
        for months in [24, 30] { dates.append(calendar.date(byAdding: .month, value: -months, to: now)!) }
        XCTAssertEqual(dates.count, 40)

        let result = Backups.thin(dates, now: now, calendar: calendar)
        XCTAssertEqual(result.keep.count, 1 + 8 + 4 + 2)
        XCTAssertEqual(result.keep.count + result.delete.count, 40)
        XCTAssertTrue(result.keep.contains(now.addingTimeInterval(-300)), "newest in the hour is kept")
        XCTAssertFalse(result.keep.contains(calendar.date(byAdding: .month, value: -24, to: now)!))
    }

    // Turns red if the diff stops showing the removed line before the added one, with unchanged lines as same.
    func testDiffOfThreeLineChange() {
        let lines = BackupDiff.lines(old: "a\nb\nc", new: "a\nB\nc")
        XCTAssertEqual(lines, [
            DiffLine(kind: .same, text: "a"),
            DiffLine(kind: .removed, text: "b"),
            DiffLine(kind: .added, text: "B"),
            DiffLine(kind: .same, text: "c"),
        ])
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
