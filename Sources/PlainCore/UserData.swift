import Foundation

/// Plain's folder in `~/Library/Application Support` and its subfolders.
public enum UserData {
    public static let folder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Plain", isDirectory: true)

    public static let config = folder.appendingPathComponent("config", isDirectory: true)
    public static let state = folder.appendingPathComponent("state", isDirectory: true)
    public static let themes = folder.appendingPathComponent("Themes", isDirectory: true)
    public static let fileRevisions = folder.appendingPathComponent("file-revisions", isDirectory: true)
    public static let untitledFiles = folder.appendingPathComponent("untitled-files", isDirectory: true)
    public static let unsavedFiles = folder.appendingPathComponent("unsaved-files", isDirectory: true)
    public static let introduction = folder.appendingPathComponent("Introduction", isDirectory: true)
}

/// Names of the JSON files under `state/`.
public enum StateName {
    public static let fileHistory = "file-history"
    public static let preferences = "preferences"
    public static let silentPreferences = "silent-preferences"
    public static let keyboardShortcuts = "keyboard-shortcuts"
    public static func windowBounds(_ windowID: Int) -> String { "window-bounds-w\(windowID)" }
    public static func tabs(_ windowID: Int) -> String { "tabs-w\(windowID)" }
}

/// Reads and writes `state/<name>.json` files.
public actor StateStore {
    public let folder: URL

    public init() {
        folder = UserData.state
    }

    /// Test-only: keeps state files under the given folder.
    public init(folder: URL) {
        self.folder = folder
    }

    public func url(for name: String) -> URL {
        folder.appendingPathComponent("\(name).json")
    }

    /// The stored value, or nil when the file is missing or does not decode.
    public func load<T: Decodable>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Writes the value atomically, creating the folder when needed.
    public func save<T: Encodable>(_ name: String, _ value: T) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url(for: name), options: .atomic)
    }
}
