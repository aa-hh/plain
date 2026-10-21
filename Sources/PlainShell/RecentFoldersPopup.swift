import PlainCore
import SwiftUI

/// File > Open Recent Folder…: popup "Folders" listing the folder history except the current folder,
/// each with a folder icon, its name and its parent path. Typing filters, best match first.
public struct RecentFoldersPopup: View {
    let folders: [URL]
    let currentFolder: URL?
    @Binding var query: String
    @Binding var selection: Int
    let onOpen: (URL) -> Void
    let onCancel: () -> Void

    public init(
        folders: [URL], currentFolder: URL?, query: Binding<String>, selection: Binding<Int>,
        onOpen: @escaping (URL) -> Void, onCancel: @escaping () -> Void
    ) {
        self.folders = folders
        self.currentFolder = currentFolder
        self._query = query
        self._selection = selection
        self.onOpen = onOpen
        self.onCancel = onCancel
    }

    public static func rows(folders: [URL], currentFolder: URL?, query: String) -> [(url: URL, match: FuzzyMatch)] {
        let others = folders.filter { $0.standardizedFileURL != currentFolder?.standardizedFileURL }
        return filter(items: others, query: query) { $0.lastPathComponent }.map { ($0.item, $0.match) }
    }

    public var body: some View {
        let rows = Self.rows(folders: folders, currentFolder: currentFolder, query: query)
        PopupCard(
            placeholder: "Folders", filter: $query, selection: $selection, rowCount: rows.count,
            onPick: { onOpen(rows[$0].url) }, onCancel: onCancel
        ) { index in
            let url = rows[index].url
            HStack(spacing: 0) {
                FileIcon(kind: .folder)
                Text(underlined(url.lastPathComponent, indexes: rows[index].match.indexes))
                Text(" \(GoToFileList.displayPath(of: url.deletingLastPathComponent()))")
                    .foregroundStyle(Color.tertiaryText)
                    .truncationMode(.head)
            }
        }
    }
}
