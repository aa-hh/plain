import Foundation

public enum FileKind: Sendable {
    case folder, text, image, other
}

public enum OpenableFiles {
    /// Files that open in a tab.
    public static let openableExtensions: Set<String> = ["md", "markdown", "txt", "text"]
    /// Extensions treated as Markdown.
    public static let markdownExtensions: Set<String> = [
        "md", "markdown", "mmd", "multimarkdown", "mdown", "mkdn", "mkd", "mdwn", "mdtxt", "mdtext", "mdml",
    ]
    /// Files shown with Quick Look.
    public static let imageExtensions: Set<String> = ["png", "gif", "jpg", "jpeg", "bmp", "pdf"]
    /// Operating system files left out of the folder index.
    public static let junkNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini", ".localized"]
    /// Folders the folder index never enters.
    public static let skippedFolders: Set<String> = ["node_modules", "bower_components"]

    /// Sidebar icon extensions.
    static let sidebarTextExtensions: Set<String> = ["md", "mdown", "markdown", "txt"]
    static let sidebarImageExtensions: Set<String> = ["png", "jpg", "gif"]

    public static func isOpenable(_ url: URL) -> Bool {
        openableExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// The sidebar icon kind for a file or folder.
    public static func fileKind(for url: URL) -> FileKind {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
        if isFolder { return .folder }
        let ext = url.pathExtension.lowercased()
        if sidebarTextExtensions.contains(ext) { return .text }
        if sidebarImageExtensions.contains(ext) { return .image }
        return .other
    }
}
