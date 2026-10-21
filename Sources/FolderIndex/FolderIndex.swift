import CoreServices
import Foundation
import PlainCore

/// One file or folder in the index. Folder children are sorted folders first, then natural case-insensitive name order.
public struct FolderNode: Sendable, Hashable {
    public var name: String
    public var url: URL
    public var kind: FileKind
    public var children: [FolderNode]
    /// The macOS hidden flag. Names starting with `.` never reach the index.
    public var isHidden: Bool
}

/// The window folder's file tree, kept current by an `FSEventStream` on the root.
public actor FolderIndex {
    /// Levels below the root that the index reads.
    static let maxDepth = 6

    /// The root with symbolic links resolved, matching the paths FSEvents reports.
    public nonisolated let root: URL
    /// Paths reported by FSEvents after each update, minus skipped names.
    public nonisolated let changes: AsyncStream<Set<URL>>

    private let changesContinuation: AsyncStream<Set<URL>>.Continuation
    /// Folder path to its direct children (each child's `children` left empty).
    private var entries: [String: [FolderNode]] = [:]
    private var textCache: [String: (date: Date, text: String, lowercased: String)] = [:]
    private var watcher: FileWatcher?

    public init(root: URL) {
        self.root = URL(fileURLWithPath: resolvedPath(root), isDirectory: true)
        (changes, changesContinuation) = AsyncStream.makeStream(of: Set<URL>.self)
    }

    deinit {
        changesContinuation.finish()
    }

    /// Reads the tree breadth-first, then watches the root for changes.
    public func start() {
        entries = [:]
        scan(from: root.path)
        guard watcher == nil else { return }
        watcher = FileWatcher(path: root.path, latency: 0.3, fileEvents: true) { [weak self] paths in
            Task { await self?.handle(paths) }
        }
    }

    public var tree: FolderNode {
        node(path: root.path, name: root.lastPathComponent, isHidden: false)
    }

    /// Every file in the index, in tree order.
    public func allFiles() -> [URL] {
        var files: [URL] = []
        func walk(_ path: String) {
            for child in entries[path] ?? [] {
                if child.kind == .folder { walk(child.url.path) } else { files.append(child.url) }
            }
        }
        walk(root.path)
        return files
    }

    /// The text of an openable file, re-read only when its modification date changes.
    public func text(of url: URL) -> String? {
        searchText(of: url)?.text
    }

    /// The cached text and its lowercased copy, which find in folder scans first to skip files without a hit.
    func searchText(of url: URL) -> (text: String, lowercased: String)? {
        guard OpenableFiles.isOpenable(url) else { return nil }
        let path = url.path
        // `stat` rather than `URL.resourceValues`, which caches the date on the URL value, or
        // `FileManager.attributesOfItem`, which builds a dictionary per file and is too slow for find in folder.
        var info = stat()
        guard stat(path, &info) == 0 else {
            textCache[path] = nil
            return nil
        }
        let date = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        if let cached = textCache[path], cached.date == date { return (cached.text, cached.lowercased) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let lowercased = text.lowercased()
        textCache[path] = (date, text, lowercased)
        return (text, lowercased)
    }

    // MARK: - Reading folders

    private func node(path: String, name: String, isHidden: Bool) -> FolderNode {
        let children = (entries[path] ?? []).map { child in
            child.kind == .folder ? node(path: child.url.path, name: child.name, isHidden: child.isHidden) : child
        }
        return FolderNode(
            name: name, url: URL(fileURLWithPath: path, isDirectory: true), kind: .folder,
            children: children, isHidden: isHidden)
    }

    /// Lists `start` and its subfolders breadth-first down to `maxDepth`.
    private func scan(from start: String) {
        var queue = [start]
        var index = 0
        while index < queue.count {
            let path = queue[index]
            index += 1
            let children = list(path)
            entries[path] = children
            for child in children where child.kind == .folder && depth(of: child.url.path) < Self.maxDepth {
                queue.append(child.url.path)
            }
        }
    }

    private func list(_ path: String) -> [FolderNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: keys)) ?? []
        let nodes: [FolderNode] = urls.compactMap { url in
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory ?? false
            guard !Self.isSkipped(name: name, isFolder: isFolder) else { return nil }
            let childPath = (path as NSString).appendingPathComponent(name)
            return FolderNode(
                name: name, url: URL(fileURLWithPath: childPath, isDirectory: isFolder),
                kind: isFolder ? .folder : OpenableFiles.fileKind(for: url),
                children: [], isHidden: values?.isHidden ?? false)
        }
        return nodes.sorted { a, b in
            if (a.kind == .folder) != (b.kind == .folder) { return a.kind == .folder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func isSkipped(name: String, isFolder: Bool) -> Bool {
        name.hasPrefix(".") || OpenableFiles.junkNames.contains(name)
            || (isFolder && OpenableFiles.skippedFolders.contains(name))
    }

    private func depth(of path: String) -> Int {
        path.dropFirst(root.path.count).split(separator: "/").count
    }

    // MARK: - File events

    private func handle(_ paths: [String]) {
        var changed = Set<URL>()
        let rootPrefix = root.path + "/"
        for path in Set(paths) where path.hasPrefix(rootPrefix) {
            let components = path.dropFirst(rootPrefix.count).split(separator: "/")
            // Paths inside skipped names (dot files, junk, node_modules) are not part of the index.
            guard !components.contains(where: { $0.hasPrefix(".") || OpenableFiles.junkNames.contains(String($0))
                || OpenableFiles.skippedFolders.contains(String($0)) })
            else { continue }
            textCache[path] = nil
            var isFolder: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
            if !exists || !isFolder.boolValue {
                for key in entries.keys where key == path || key.hasPrefix(path + "/") { entries[key] = nil }
            }
            let parent = (path as NSString).deletingLastPathComponent
            if entries[parent] != nil { entries[parent] = list(parent) }
            if exists, isFolder.boolValue, depth(of: path) < Self.maxDepth, entries[parent] != nil {
                scan(from: path)
            }
            changed.insert(URL(fileURLWithPath: path, isDirectory: exists && isFolder.boolValue))
        }
        if !changed.isEmpty { changesContinuation.yield(changed) }
    }
}

/// `realpath` of a file URL, so paths match the ones FSEvents reports (`/private/var/…` rather than `/var/…`).
func resolvedPath(_ url: URL) -> String {
    guard let pointer = realpath(url.path, nil) else { return url.standardizedFileURL.path }
    defer { free(pointer) }
    return String(cString: pointer)
}

/// An `FSEventStream` on one folder that hands each batch of changed paths to `handler` on a private queue.
final class FileWatcher: @unchecked Sendable {
    private let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "Plain.FolderIndex.FileWatcher")
    private var stream: FSEventStreamRef?

    init?(path: String, latency: TimeInterval, fileEvents: Bool, handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handler(list)
        }
        var flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        if fileEvents { flags |= kFSEventStreamCreateFlagFileEvents }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, FSEventStreamCreateFlags(flags))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
