import CoreServices
import Foundation

public enum GitMark: Sendable, Hashable {
    case added, changed, deleted, renamed
}

/// Git marks for one folder from `/usr/bin/git`, refreshed on request and when `.git/HEAD` or `.git/index` changes.
public actor GitStatus {
    public nonisolated let folder: URL
    /// The folder itself or the first of its 5 parents that holds `.git`; nil outside a repository.
    public nonisolated let repositoryRoot: URL?
    /// The latest marks after each refresh.
    public nonisolated let updates: AsyncStream<[URL: GitMark]>
    /// Files and folders with a mark. A folder is `changed` if any file under it is, else it takes any file's mark.
    public private(set) var marks: [URL: GitMark] = [:]

    private let updatesContinuation: AsyncStream<[URL: GitMark]>.Continuation
    private var topLevel: String?
    private var headHash: String?
    /// Committed text per path relative to `topLevel`, valid for `headHash`; nil values mean "not in HEAD".
    private var committed: [String: String?] = [:]
    private var watcher: GitFileWatcher?

    public init(folder: URL) {
        self.folder = folder
        repositoryRoot = Self.findRepository(from: folder)
        (updates, updatesContinuation) = AsyncStream.makeStream(of: [URL: GitMark].self)
    }

    deinit {
        updatesContinuation.finish()
    }

    static func findRepository(from folder: URL) -> URL? {
        var url = folder.standardizedFileURL
        for _ in 0...5 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }

    /// Runs `git status --porcelain --untracked-files` and `git rev-parse --show-toplevel`, then publishes `marks`.
    public func refreshStatus() async {
        guard let repositoryRoot else {
            setMarks([:])
            return
        }
        startWatching(repositoryRoot)
        let top = await Self.git(["rev-parse", "--show-toplevel"], in: folder)
        guard top.status == 0 else {
            setMarks([:])
            return
        }
        let topPath = String(decoding: top.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        topLevel = topPath
        let status = await Self.git(["status", "--porcelain", "--untracked-files"], in: folder)
        guard status.status == 0 else { return }
        setMarks(Self.parseStatus(String(decoding: status.output, as: UTF8.self), topLevel: topPath))
    }

    /// The file's text at `HEAD`, read with `git show HEAD:<path>` once per `HEAD` commit; nil when not committed.
    public func committedText(of url: URL) async -> String? {
        guard repositoryRoot != nil else { return nil }
        if topLevel == nil {
            let top = await Self.git(["rev-parse", "--show-toplevel"], in: folder)
            guard top.status == 0 else { return nil }
            topLevel = String(decoding: top.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let topLevel else { return nil }
        let path = resolvedPath(url)
        guard path.hasPrefix(topLevel + "/") else { return nil }
        let relative = String(path.dropFirst(topLevel.count + 1))
        if headHash == nil {
            let head = await Self.git(["rev-parse", "HEAD"], in: folder)
            guard head.status == 0 else { return nil }
            headHash = String(decoding: head.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            committed = [:]
        }
        if let cached = committed[relative] { return cached }
        let show = await Self.git(["show", "HEAD:\(relative)"], in: URL(fileURLWithPath: topLevel))
        let text = show.status == 0 ? String(decoding: show.output, as: UTF8.self) : nil
        committed[relative] = text
        return text
    }

    private func setMarks(_ newMarks: [URL: GitMark]) {
        marks = newMarks
        updatesContinuation.yield(newMarks)
    }

    private func startWatching(_ repository: URL) {
        guard watcher == nil else { return }
        let gitFolder = resolvedPath(repository.appendingPathComponent(".git"))
        watcher = GitFileWatcher(path: gitFolder) { [weak self] paths in
            let watched = [gitFolder + "/HEAD", gitFolder + "/index"]
            guard paths.contains(where: watched.contains) else { return }
            Task { await self?.repositoryChanged() }
        }
    }

    private func repositoryChanged() async {
        headHash = nil
        committed = [:]
        await refreshStatus()
    }

    // MARK: - Parsing

    static func parseStatus(_ output: String, topLevel: String) -> [URL: GitMark] {
        var result: [String: GitMark] = [:]
        for line in output.split(separator: "\n") where line.count > 3 {
            let code = line.prefix(2)
            var pathPart = line.dropFirst(3)
            if let arrow = pathPart.range(of: " -> ") { pathPart = pathPart[arrow.upperBound...] }
            let mark: GitMark
            if code == "??" || code.contains("A") {
                mark = .added
            } else if code.contains("R") {
                mark = .renamed
            } else if code.contains("D") {
                mark = .deleted
            } else {
                mark = .changed
            }
            let relative = unquote(pathPart)
            result[relative] = mark
            // Folders above the file take its mark, with `changed` winning.
            var folder = (relative as NSString).deletingLastPathComponent
            while !folder.isEmpty {
                if result[folder] != .changed, mark == .changed || result[folder] == nil { result[folder] = mark }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        var marks: [URL: GitMark] = [:]
        for (relative, mark) in result {
            marks[URL(fileURLWithPath: topLevel).appendingPathComponent(relative)] = mark
        }
        return marks
    }

    /// Undoes git's C-style quoting of unusual paths (`"a b\303\251.md"`).
    static func unquote(_ field: Substring) -> String {
        guard field.count >= 2, field.first == "\"", field.last == "\"" else { return String(field) }
        let bytes = Array(field.utf8.dropFirst().dropLast())
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < bytes.count else {
                out.append(byte)
                index += 1
                continue
            }
            let next = bytes[index + 1]
            if (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(next), index + 3 < bytes.count {
                let digits = bytes[(index + 1)...(index + 3)].map { $0 - UInt8(ascii: "0") }
                out.append(digits[0] * 64 + digits[1] * 8 + digits[2])
                index += 4
                continue
            }
            switch next {
            case UInt8(ascii: "n"): out.append(10)
            case UInt8(ascii: "t"): out.append(9)
            default: out.append(next)
            }
            index += 2
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Running git

    static func git(_ arguments: [String], in directory: URL) async -> (status: Int32, output: Data) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                // Stops `git status` rewriting `.git/index`, which would fire the watcher again.
                environment["GIT_OPTIONAL_LOCKS"] = "0"
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, Data()))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, data))
            }
        }
    }
}

/// `realpath` of a file URL, matching the resolved paths git and FSEvents report.
func resolvedPath(_ url: URL) -> String {
    guard let pointer = realpath(url.path, nil) else { return url.standardizedFileURL.path }
    defer { free(pointer) }
    return String(cString: pointer)
}

/// An `FSEventStream` with file-level events on one folder; hands changed paths to `handler` on a private queue.
final class GitFileWatcher: @unchecked Sendable {
    private let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "Plain.GitStatus.FileWatcher")
    private var stream: FSEventStreamRef?

    init?(path: String, handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<GitFileWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handler(unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [])
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagFileEvents
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, FSEventStreamCreateFlags(flags))
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
