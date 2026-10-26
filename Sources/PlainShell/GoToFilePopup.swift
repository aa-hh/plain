import FolderIndex
import GitStatus
import PlainCore
import SwiftUI

/// The rows of Go to File.
public enum GoToFileList {
    /// Empty query: up to 8 recent files, without untitled, preferences and backup files.
    /// With a query: recent files then every other indexed file, fuzzy-filtered by name and sorted by match;
    /// equal scores keep recent files first.
    public static func rows(recents: [URL], allFiles: [URL], query: String) -> [(url: URL, match: FuzzyMatch)] {
        let recents = recents.filter { !isHiddenFromList($0) }
        if query.isEmpty {
            return recents.prefix(8).map { ($0, emptyMatch) }
        }
        var seen = Set<URL>()
        let candidates = (recents + allFiles).filter { seen.insert($0.standardizedFileURL).inserted }
        return filter(items: candidates, query: query) { $0.lastPathComponent }.map { ($0.item, $0.match) }
    }

    static func isHiddenFromList(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return [UserData.untitledFiles, UserData.config, UserData.fileRevisions].contains {
            path.hasPrefix($0.standardizedFileURL.path + "/")
        }
    }

    /// A folder for the ` in <folder>` part: home as `~/…`, the user data folder as `Plain/…`.
    public static func displayPath(of folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        let userData = UserData.folder.standardizedFileURL.path
        if path == userData || path.hasPrefix(userData + "/") { return "Plain" + path.dropFirst(userData.count) }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home || path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// Go > To File…: popup "Files" listing recent and indexed files.
public struct GoToFilePopup: View {
    let recents: [URL]
    let allFiles: [URL]
    let gitMarks: [URL: GitMark]
    @Binding var query: String
    @Binding var selection: Int
    /// The picked file and whether it opens in a new tab (Cmd+Return, Option+click).
    let onOpen: (URL, _ newTab: Bool) -> Void
    let onCancel: () -> Void

    public init(
        recents: [URL], allFiles: [URL], gitMarks: [URL: GitMark], query: Binding<String>, selection: Binding<Int>,
        onOpen: @escaping (URL, _ newTab: Bool) -> Void, onCancel: @escaping () -> Void
    ) {
        self.recents = recents
        self.allFiles = allFiles
        self.gitMarks = gitMarks
        self._query = query
        self._selection = selection
        self.onOpen = onOpen
        self.onCancel = onCancel
    }

    public var body: some View {
        let rows = GoToFileList.rows(recents: recents, allFiles: allFiles, query: query)
        PopupCard(
            placeholder: "Files", filter: $query, selection: $selection, rowCount: rows.count,
            onPick: { onOpen(rows[$0].url, false) }, onPickInNewTab: { onOpen(rows[$0].url, true) }, onCancel: onCancel
        ) { index in
            let url = rows[index].url
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
            let indexes = rows[index].match.indexes
            HStack(spacing: 0) {
                FileIcon(kind: OpenableFiles.fileKind(for: url)).padding(.trailing, 6)
                Text(underlined(name, indexes: indexes))
                Text(underlined(ext, indexes: indexes, offset: name.count)).foregroundStyle(Color.tertiaryText)
                Text(" in \(GoToFileList.displayPath(of: url.deletingLastPathComponent()))")
                    .foregroundStyle(Color.tertiaryText)
                    .truncationMode(.head)
                Spacer(minLength: 10)
                GitMarkLabel(mark: gitMarks[url])
            }
        }
    }
}
