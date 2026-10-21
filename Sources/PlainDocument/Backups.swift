import Foundation
import PlainCore

public struct BackupInfo: Equatable, Sendable {
    public let name: String
    public let date: Date
    public let url: URL
    /// "Today at 14:32", "12 Mar 2026 at 09:05".
    public let friendlyDate: String
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case same, added, removed }
    public let kind: Kind
    public let text: String
}

public enum BackupDiff {
    /// Lines of `new` merged with the lines of `old` that are gone; a removed line comes before its replacement.
    public static func lines(old: String, new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [DiffLine] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                result.append(DiffLine(kind: .removed, text: oldLines[i])); i += 1
            } else if j < newLines.count, inserted.contains(j) {
                result.append(DiffLine(kind: .added, text: newLines[j])); j += 1
            } else {
                result.append(DiffLine(kind: .same, text: newLines[j])); i += 1; j += 1
            }
        }
        return result
    }
}

/// Backups in `file-revisions/<encoded path>/`, one file per backup named by its timestamp.
public actor Backups {
    public static let metadataName = "metadata.json"
    static let separator = "__--__"
    /// Folder names longer than this fall back to a random name.
    static let maxNameBytes = 200

    private let folder: URL
    private let store: StateStore
    private var pending: Set<String> = []

    public init(folder: URL = UserData.fileRevisions, store: StateStore = StateStore()) {
        self.folder = folder
        self.store = store
    }

    /// `/a/b/c.md` becomes `__--__a__--__b__--__c`.
    static func encodePath(_ path: String, dropExtension: Bool = true) -> String {
        let base = dropExtension ? (path as NSString).deletingPathExtension : path
        return base.replacingOccurrences(of: "/", with: separator)
    }

    /// The folder name for a file. A path too long for a folder name gets a random 16-character name that is remembered.
    public func folderName(for path: String) async throws -> String {
        let encoded = Self.encodePath(path)
        guard encoded.utf8.count > Self.maxNameBytes else { return encoded }
        var names = await store.load("file-revisions", as: [String: String].self) ?? [:]
        if let known = names[path] { return known }
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let name = String((0..<16).map { _ in letters.randomElement()! })
        names[path] = name
        try await store.save("file-revisions", names)
        return name
    }

    private func backupFolder(for path: String) async throws -> URL {
        folder.appendingPathComponent(try await folderName(for: path), isDirectory: true)
    }

    // MARK: Taking backups

    /// A backup is due when there is none, or the newest is over an hour old and its length differs from `text`.
    public func isDue(path: String, text: String, now: Date = Date()) async throws -> Bool {
        guard let newest = try await list(for: path).first else { return true }
        return now.timeIntervalSince(newest.date) > 3600 && (try? self.text(of: newest))?.count != text.count
    }

    /// Called on tab open or switch, before a switch or close, and every 10 minutes. Arms a backup if one is due.
    public func requestBackup(path: String, text: String, now: Date = Date()) async throws {
        if try await isDue(path: path, text: text, now: now) { pending.insert(path) }
    }

    /// Called when the user inserts or deletes a line break. Writes the armed backup, if any, and reports whether it did.
    @discardableResult
    public func recordLineBreakInserted(path: String, text: String, now: Date = Date()) async throws -> Bool {
        guard pending.remove(path) != nil else { return false }
        let dir = try await backupFolder(for: path)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"path":\#(try Self.jsonString(path))}"#.utf8).write(to: dir.appendingPathComponent(Self.metadataName), options: .atomic)
        // Thin before saving, so the new backup is never the one removed.
        let existing = try await list(for: path)
        let result = Self.thin(existing.map(\.date), now: now)
        for gone in existing where result.delete.contains(gone.date) { try? fm.removeItem(at: gone.url) }
        try Data(text.utf8).write(to: dir.appendingPathComponent(Self.timestamp(now)), options: .atomic)
        return true
    }

    private static func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    // MARK: Listing, renaming, reverting

    /// Newest first.
    public func list(for path: String) async throws -> [BackupInfo] {
        let dir = try await backupFolder(for: path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let friendly = DateFormatter()
        friendly.dateStyle = .medium
        friendly.timeStyle = .short
        friendly.doesRelativeDateFormatting = true
        return names.compactMap { name in
            guard let date = Self.date(from: name) else { return nil }
            return BackupInfo(name: name, date: date, url: dir.appendingPathComponent(name), friendlyDate: friendly.string(from: date))
        }.sorted { $0.date > $1.date }
    }

    public func text(of backup: BackupInfo) throws -> String {
        try String(contentsOf: backup.url, encoding: .utf8)
    }

    /// The text to put back with `Document.revert(to:)`.
    public func revert(to backup: BackupInfo) throws -> String {
        try text(of: backup)
    }

    /// Moves a file's backups when the file is renamed.
    public func rename(from oldPath: String, to newPath: String) async throws {
        let old = try await backupFolder(for: oldPath)
        let new = try await backupFolder(for: newPath)
        guard FileManager.default.fileExists(atPath: old.path), old != new else { return }
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: new)
        try Data(#"{"path":\#(try Self.jsonString(newPath))}"#.utf8).write(to: new.appendingPathComponent(Self.metadataName), options: .atomic)
    }

    // MARK: Names and thinning

    static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter
    }

    static func timestamp(_ date: Date) -> String { formatter().string(from: date) }
    static func date(from name: String) -> Date? { formatter().date(from: name) }

    /// Keeps the newest backup in each slot: one per hour today, one per day for the 8 days before, one per week for the
    /// next 4 weeks, one per month for 23 months. Everything older, and the rest of each slot, goes in `delete`.
    public static func thin(_ dates: [Date], now: Date, calendar: Calendar = .current) -> (keep: [Date], delete: [Date]) {
        func slot(_ date: Date) -> String? {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
            if days <= 0 { return "h\(days)-\(calendar.component(.hour, from: date))" }
            if days <= 8 { return "d\(days)" }
            if days <= 8 + 28 { return "w\((days - 9) / 7)" }
            let a = calendar.dateComponents([.year, .month], from: date)
            let b = calendar.dateComponents([.year, .month], from: now)
            let months = (b.year! * 12 + b.month!) - (a.year! * 12 + a.month!)
            return months <= 23 ? "m\(months)" : nil
        }
        var keep: [Date] = []
        var seen = Set<String>()
        for date in dates.sorted(by: >) {
            if let key = slot(date), seen.insert(key).inserted { keep.append(date) }
        }
        return (keep, dates.filter { !keep.contains($0) })
    }
}
