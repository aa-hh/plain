import AppKit
import Foundation

public enum FileOperationError: Error, Equatable {
    /// "File with the provided name already exists" when renaming.
    case renameClash
    /// A new file or folder would replace an existing item.
    case alreadyExists
}

public enum FileOperations {
    /// Creates an empty file. A name without an extension gets `.md`; a name ending in `/` or `\` makes a folder.
    @discardableResult
    public static func createFile(in folder: URL, name: String) throws -> URL {
        if name.hasSuffix("/") || name.hasSuffix("\\") {
            return try createFolder(in: folder, name: String(name.dropLast()))
        }
        let fileName = (name as NSString).pathExtension.isEmpty ? name + ".md" : name
        let url = folder.appendingPathComponent(fileName, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw FileOperationError.alreadyExists }
        try Data().write(to: url, options: .withoutOverwriting)
        return url
    }

    @discardableResult
    public static func createFolder(in folder: URL, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw FileOperationError.alreadyExists }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Renames in place. Throws `renameClash` when the new name is taken.
    @discardableResult
    public static func rename(_ url: URL, to name: String) throws -> URL {
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw FileOperationError.renameClash }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    public static func trash(_ urls: [URL]) throws {
        for url in urls { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    /// Copies into `folder`; clashing names get `-1`, `-2`… after the first dot-separated part.
    @discardableResult
    public static func copy(_ urls: [URL], to folder: URL) throws -> [URL] {
        try urls.map { url in
            let target = freeName(for: url.lastPathComponent, in: folder)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        }
    }

    /// Moves into `folder`; clashing names get `-1`, `-2`… after the first dot-separated part.
    @discardableResult
    public static func move(_ urls: [URL], to folder: URL) throws -> [URL] {
        try urls.map { url in
            let target = freeName(for: url.lastPathComponent, in: folder)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    public static func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// `notes.tar.gz` becomes `notes-1.tar.gz`, then `notes-2.tar.gz`, until the name is free.
    static func freeName(for name: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent(name)
        let dot = name.firstIndex(of: ".") ?? name.endIndex
        var number = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name[..<dot])-\(number)\(name[dot...])")
            number += 1
        }
        return url
    }
}
