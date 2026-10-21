import Foundation
import PlainCore

/// Text of files with unsaved edits, kept in `unsaved-files/<encoded path>.md` so it survives a restart.
public struct UnsavedFiles: Sendable {
    public let folder: URL

    public init(folder: URL = UserData.unsavedFiles) {
        self.folder = folder
    }

    func url(for path: String) -> URL {
        folder.appendingPathComponent("\(Backups.encodePath(path, dropExtension: false)).md")
    }

    public func store(_ text: String, for path: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url(for: path), options: .atomic)
    }

    public func text(for path: String) -> String? {
        try? String(contentsOf: url(for: path), encoding: .utf8)
    }

    public func remove(for path: String) {
        try? FileManager.default.removeItem(at: url(for: path))
    }
}
