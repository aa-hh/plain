import Foundation
import PlainCore

public struct StoredRange: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// What Plain remembers about one file between visits.
public struct FileHistoryEntry: Codable, Equatable, Sendable {
    public var path: String
    public var scrollOffset: Double
    public var selection: [StoredRange]
    public var hasUnsavedEdits: Bool
    public var lastUsed: Date

    public init(path: String, scrollOffset: Double = 0, selection: [StoredRange] = [], hasUnsavedEdits: Bool = false, lastUsed: Date = Date()) {
        self.path = path
        self.scrollOffset = scrollOffset
        self.selection = selection
        self.hasUnsavedEdits = hasUnsavedEdits
        self.lastUsed = lastUsed
    }
}

struct HistorySnapshot: Sendable {
    let entry: FileHistoryEntry
    let text: String
}

extension Document {
    /// Nil for preferences and backup tabs, which are never remembered.
    func historySnapshot(now: Date) -> HistorySnapshot? {
        guard !isPreferencesFile, !isBackupTab, let path = (url ?? untitledURL)?.path else { return nil }
        let entry = FileHistoryEntry(
            path: path, scrollOffset: Double(scrollOffset),
            selection: selectedRanges.map { StoredRange(location: $0.location, length: $0.length) },
            hasUnsavedEdits: isEdited, lastUsed: now)
        return HistorySnapshot(entry: entry, text: textStorage.string)
    }
}

/// `state/file-history.json`: up to 50 entries, newest first. Entries with unsaved edits are never dropped.
public actor FileHistory {
    public static let limit = 50
    /// View state (scroll, selection) is restored only if the file was used less than this long ago.
    public static let restoreWindow: TimeInterval = 6 * 3600

    private let store: StateStore
    private let unsaved: UnsavedFiles
    private var entries: [FileHistoryEntry]?

    public init(store: StateStore = StateStore(), unsaved: UnsavedFiles = UnsavedFiles()) {
        self.store = store
        self.unsaved = unsaved
    }

    public func all() async -> [FileHistoryEntry] {
        await loaded()
    }

    /// Called by the shell on tab switch, save, window blur and every 30 s while the editor has focus.
    public func record(_ document: Document, now: Date = Date()) async throws {
        guard let snapshot = await document.historySnapshot(now: now) else { return }
        if snapshot.entry.hasUnsavedEdits {
            try unsaved.store(snapshot.text, for: snapshot.entry.path)
        } else {
            unsaved.remove(for: snapshot.entry.path)
        }
        try await record(snapshot.entry)
    }

    public func record(_ entry: FileHistoryEntry) async throws {
        var list = await loaded()
        list.removeAll { $0.path == entry.path }
        list.append(entry)
        list.sort { $0.lastUsed > $1.lastUsed }
        while list.count > Self.limit, let oldest = list.lastIndex(where: { !$0.hasUnsavedEdits }) {
            list.remove(at: oldest)
        }
        entries = list
        try await store.save(StateName.fileHistory, list)
    }

    /// The remembered scroll and selection, or nil when there is none or it is older than six hours.
    public func restorableState(for path: String, now: Date = Date()) async -> FileHistoryEntry? {
        guard let entry = await loaded().first(where: { $0.path == path }),
              now.timeIntervalSince(entry.lastUsed) < Self.restoreWindow else { return nil }
        return entry
    }

    /// Unsaved text comes back whatever its age.
    public func unsavedText(for path: String) async -> String? {
        guard await loaded().contains(where: { $0.path == path && $0.hasUnsavedEdits }) else { return nil }
        return unsaved.text(for: path)
    }

    /// "Don't save" on close.
    public func discard(path: String) async throws {
        var list = await loaded()
        list.removeAll { $0.path == path }
        entries = list
        unsaved.remove(for: path)
        try await store.save(StateName.fileHistory, list)
    }

    private func loaded() async -> [FileHistoryEntry] {
        if let entries { return entries }
        let stored = await store.load(StateName.fileHistory, as: [FileHistoryEntry].self) ?? []
        entries = stored
        return stored
    }
}
