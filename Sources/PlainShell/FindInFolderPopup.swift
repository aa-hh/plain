import FolderIndex
import PlainCore
import SwiftUI

/// Find in Folder results grouped by file.
public enum FindInFolderList {
    public struct Group: Equatable {
        public var url: URL
        public var hits: [SearchHit]
        /// A group starts expanded when it has fewer than 15 hits.
        public var startsExpanded: Bool { hits.count < 15 }
    }

    public enum Row: Equatable {
        case file(Group, expanded: Bool)
        case hit(SearchHit)
    }

    /// Groups in the order their first hit arrived.
    public static func groups(_ hits: [SearchHit]) -> [Group] {
        var groups: [Group] = []
        var position: [URL: Int] = [:]
        for hit in hits {
            if let i = position[hit.url] {
                groups[i].hits.append(hit)
            } else {
                position[hit.url] = groups.count
                groups.append(Group(url: hit.url, hits: [hit]))
            }
        }
        return groups
    }

    /// File rows, each followed by its hits when expanded. `toggled` holds files whose starting state was flipped.
    public static func rows(_ groups: [Group], toggled: Set<URL>) -> [Row] {
        groups.flatMap { group -> [Row] in
            let expanded = group.startsExpanded != toggled.contains(group.url)
            return [.file(group, expanded: expanded)] + (expanded ? group.hits.map(Row.hit) : [])
        }
    }

    /// The path of `url` relative to `folder`.
    public static func relativePath(_ url: URL, in folder: URL) -> String {
        let base = folder.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

/// Edit > Find in Folder…: a search field with results grouped by file. The shell runs the search
/// (`FolderIndex.search`) as `query` changes and passes the hits in.
public struct FindInFolderPopup: View {
    let folder: URL
    let hits: [SearchHit]
    @Binding var query: String
    @Binding var selection: Int
    let onPick: (SearchHit) -> Void
    let onCancel: () -> Void
    @State private var toggled = Set<URL>()

    public init(
        folder: URL, hits: [SearchHit], query: Binding<String>, selection: Binding<Int>,
        onPick: @escaping (SearchHit) -> Void, onCancel: @escaping () -> Void
    ) {
        self.folder = folder
        self.hits = hits
        self._query = query
        self._selection = selection
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public var body: some View {
        let rows = FindInFolderList.rows(FindInFolderList.groups(hits), toggled: toggled)
        PopupCard(
            placeholder: "Find in Folder", filter: $query, selection: $selection, rowCount: rows.count,
            onPick: { pick(rows[$0]) }, onCancel: onCancel
        ) { index in
            switch rows[index] {
            case .file(let group, let expanded):
                HStack(spacing: 7) {
                    Text(FindInFolderList.relativePath(group.url, in: folder)).truncationMode(.head)
                    Text("›").rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Color.tertiaryText)
            case .hit(let hit):
                Text(highlighted(hit))
            }
        }
        .onChange(of: query) { toggled = [] }
    }

    private func pick(_ row: FindInFolderList.Row) {
        switch row {
        case .file(let group, _):
            if !toggled.insert(group.url).inserted { toggled.remove(group.url) }
        case .hit(let hit):
            onPick(hit)
        }
    }

    private func highlighted(_ hit: SearchHit) -> AttributedString {
        var text = AttributedString(hit.lineText)
        if let range = Range(hit.rangeInLineText, in: hit.lineText),
           let lower = AttributedString.Index(range.lowerBound, within: text),
           let upper = AttributedString.Index(range.upperBound, within: text) {
            text[lower..<upper].foregroundColor = .textColor
            text[lower..<upper].underlineStyle = .single
        }
        return text
    }
}
