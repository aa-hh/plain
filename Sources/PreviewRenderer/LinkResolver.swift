import Foundation

/// Turns `img src`, `a href` and `object data` values into paths for the on-screen preview (spec 493). Export and
/// copy do not use it, so their paths stay as written.
public struct LinkResolver: Sendable {
    public var projectRoot: URL?
    /// The open file; relative paths are joined to its folder.
    public var currentFile: URL?
    public var homeFolder: URL

    public init(projectRoot: URL?, currentFile: URL?, homeFolder: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.projectRoot = projectRoot
        self.currentFile = currentFile
        self.homeFolder = homeFolder
    }

    /// In order: a leading `file://` is removed; full URLs and `#anchors` stay as they are; the rest is URL-decoded,
    /// `~/` becomes the home folder, a path starting with `/` is joined to the project root when there is one, and
    /// anything else is joined to the open file's folder (or the project root without an open file), with leading
    /// segments that repeat the end of that folder merged. With neither, the path stays as written.
    public func resolve(_ value: String) -> String {
        var path = value
        if path.lowercased().hasPrefix("file://") { path = String(path.dropFirst(7)) }
        if path.hasPrefix("#") || Self.hasScheme(path) { return path }
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("~/") { return homeFolder.path + "/" + path.dropFirst(2) }
        if path.hasPrefix("/") {
            guard let projectRoot else { return path }
            return Self.join(projectRoot.path, path)
        }
        guard let base = currentFile?.deletingLastPathComponent().path ?? projectRoot?.path else { return path }
        return Self.join(base, path)
    }

    /// `scheme:` at the start, as in `https:`, `mailto:` or `data:`.
    static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else { return false }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }

    /// Joins `path` to `base`, dropping leading segments of `path` that repeat the last segments of `base`
    /// (`/a/docs` + `docs/x.png` gives `/a/docs/x.png`).
    static func join(_ base: String, _ path: String) -> String {
        let baseParts = base.split(separator: "/").map(String.init)
        var parts = path.split(separator: "/").map(String.init)
        if parts.first == "." { parts.removeFirst() }
        var overlap = 0
        for length in stride(from: min(baseParts.count, parts.count), through: 1, by: -1)
        where Array(baseParts.suffix(length)) == Array(parts.prefix(length)) {
            overlap = length
            break
        }
        return "/" + (baseParts + parts.dropFirst(overlap)).joined(separator: "/")
    }
}
