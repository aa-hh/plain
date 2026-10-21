import AppKit
import Observation
import PlainCore

public enum DocumentError: Error, Equatable, Sendable {
    case readProtected(URL)
    case writeProtected(URL)
    case folderProtected(URL)
    /// Saving needs a file location and an untitled document has none until Save As.
    case untitled
}

extension Notification.Name {
    /// Posted with the `Document` as object when another process changes its file.
    public static let documentDiskChanged = Notification.Name("PlainDocument.diskChanged")
}

/// Disk reads and writes. Runs off the main thread, so nothing here touches a `Document`.
enum DiskIO {
    static func read(_ url: URL) throws -> (text: String, modified: Date?) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), !fm.isReadableFile(atPath: url.path) {
            throw DocumentError.readProtected(url)
        }
        let data = try Data(contentsOf: url)
        // Latin-1 accepts every byte, so the fallback cannot fail.
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return (text, modificationDate(url))
    }

    static func write(_ text: String, to url: URL) throws -> Date? {
        let fm = FileManager.default
        // An atomic write replaces the file, so a read-only file must be refused here.
        if fm.fileExists(atPath: url.path), !fm.isWritableFile(atPath: url.path) {
            throw DocumentError.writeProtected(url)
        }
        guard fm.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            throw DocumentError.folderProtected(url)
        }
        try Data(text.utf8).write(to: url, options: .atomic)
        return modificationDate(url)
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Keeps an older write from landing after a newer one when an async save and a synchronous save overlap.
final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var newest = 0

    func write(_ text: String, to url: URL, generation: Int) throws -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard generation > newest else { return DiskIO.modificationDate(url) }
        let date = try DiskIO.write(text, to: url)
        newest = generation
        return date
    }
}

final class FilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = url
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        self.onChange = onChange
    }

    func presentedItemDidChange() { onChange() }
}

/// One open file. Owns the text storage and undo manager the editor uses.
@MainActor @Observable
public final class Document {
    public private(set) var url: URL?
    /// The empty file under `untitled-files/` that backs an untitled document; nil once saved.
    public private(set) var untitledURL: URL?
    public let textStorage = NSTextStorage()
    public let undoManager = UndoManager()
    public var isPreferencesFile = false
    public var isBackupTab = false
    public private(set) var lastDiskModificationDate: Date?
    /// A disk version the user chose to keep their text over (Cancel in the reload prompt).
    public var ignoredModificationDate: Date?
    public var scrollOffset: CGFloat = 0
    public var selectedRanges: [NSRange] = []

    private var editCount = 0
    private var savedEditCount = 0
    @ObservationIgnored private let gate = WriteGate()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var presenter: FilePresenter?
    @ObservationIgnored private var editObserver: NSObjectProtocol?

    public init(text: String = "", url: URL? = nil, untitledURL: URL? = nil) {
        self.url = url
        self.untitledURL = untitledURL
        textStorage.mutableString.setString(text)
        // Counts edits to characters only; style changes do not make a file edited. Edits happen on the main thread.
        editObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: textStorage, queue: nil
        ) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { self?.editCount += 1 }
        }
    }

    isolated deinit {
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
    }

    public var isEdited: Bool { editCount != savedEditCount }
    public var isUntitled: Bool { url == nil }
    public var displayName: String { url?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    public var fileExtension: String { url?.pathExtension ?? "" }
    public var text: String { textStorage.string }

    // MARK: Opening

    /// Reads off the main thread. Line endings become `\n`; text is UTF-8 with a Latin-1 fallback.
    public static func open(url: URL) async throws -> Document {
        let result = try await Task.detached { try DiskIO.read(url) }.value
        let document = Document(text: result.text, url: url)
        document.lastDiskModificationDate = result.modified
        return document
    }

    /// Creates an empty `<10 random characters>.md` in `folder` and returns a document backed by it.
    public static func untitled(in folder: URL = UserData.untitledFiles) throws -> Document {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let name = String((0..<10).map { _ in letters.randomElement()! })
        let file = folder.appendingPathComponent("\(name).md")
        try Data().write(to: file)
        return Document(untitledURL: file)
    }

    // MARK: Saving

    public func save() async throws {
        guard let url else { throw DocumentError.untitled }
        let (text, count, gen) = beginWrite()
        let gate = gate
        let date = try await Task.detached { try gate.write(text, to: url, generation: gen) }.value
        finishWrite(count: count, date: date)
    }

    /// Blocks the caller. Used before a tab switch or close, where an async save could be lost.
    public func saveSync() throws {
        guard let url else { throw DocumentError.untitled }
        let (text, count, gen) = beginWrite()
        finishWrite(count: count, date: try gate.write(text, to: url, generation: gen))
    }

    public func saveAs(url newURL: URL) async throws {
        let old = url
        url = newURL
        do { try await save() } catch { url = old; throw error }
        if let untitledURL { try? FileManager.default.removeItem(at: untitledURL) }
        untitledURL = nil
        startWatching()
    }

    /// Puts `text` in the document (a backup, for "Revert to This") and saves it.
    public func revert(to text: String) async throws {
        replaceText(text)
        try await save()
    }

    /// Re-reads the file, keeping the selection where it still fits.
    public func reload() async throws {
        guard let url else { throw DocumentError.untitled }
        let result = try await Task.detached { try DiskIO.read(url) }.value
        replaceText(result.text)
        savedEditCount = editCount
        lastDiskModificationDate = result.modified
        selectedRanges = selectedRanges.compactMap { range in
            range.location <= textStorage.length
                ? NSRange(location: range.location, length: min(range.length, textStorage.length - range.location)) : nil
        }
        undoManager.removeAllActions()
    }

    /// Adds owner write permission to the file and its folder (the Overwrite answer in the protection prompt).
    public func makeWritable() throws {
        guard let url else { throw DocumentError.untitled }
        let fm = FileManager.default
        for target in [url, url.deletingLastPathComponent()] where fm.fileExists(atPath: target.path) {
            let mode = (try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int) ?? 0o644
            try fm.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: target.path)
        }
    }

    private func replaceText(_ text: String) {
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
    }

    private func beginWrite() -> (String, Int, Int) {
        generation += 1
        return (textStorage.string, editCount, generation)
    }

    private func finishWrite(count: Int, date: Date?) {
        savedEditCount = count
        lastDiskModificationDate = date
    }

    // MARK: Watching

    /// Starts telling the app when another process changes the file.
    public func startWatching() {
        stopWatching()
        guard let url else { return }
        let presenter = FilePresenter(url: url) { [weak self] in
            Task { @MainActor in self?.diskMayHaveChanged() }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
    }

    public func stopWatching() {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
    }

    private func diskMayHaveChanged() {
        guard let url, let date = DiskIO.modificationDate(url),
              date != lastDiskModificationDate, date != ignoredModificationDate else { return }
        NotificationCenter.default.post(name: .documentDiskChanged, object: self, userInfo: ["modificationDate": date])
    }
}
