import MarkdownDocument
import PlainCore
import SwiftUI

/// The rows of Go to Heading and the outline filter.
public enum HeadingList {
    /// Headings whose text fuzzy-matches the query, each with its parent headings kept for context, in document order.
    /// Returns the heading index and its match (nil for a parent kept only for context).
    public static func rows(headings: [Heading], query: String) -> [(index: Int, match: FuzzyMatch?)] {
        if query.isEmpty { return headings.indices.map { ($0, emptyMatch) } }
        var matches: [Int: FuzzyMatch] = [:]
        var keep = Set<Int>()
        for (i, heading) in headings.enumerated() {
            guard let match = fuzzyMatch(query: query, in: heading.text) else { continue }
            matches[i] = match
            keep.insert(i)
            var level = heading.level
            for parent in stride(from: i - 1, through: 0, by: -1) where headings[parent].level < level {
                keep.insert(parent)
                level = headings[parent].level
            }
        }
        return keep.sorted().map { ($0, matches[$0]) }
    }

    /// Indent steps by rank among the heading levels in use: levels {1, 3, 5} give 0, 1, 2.
    public static func ranks(levels: [Int]) -> [Int] {
        let used = Array(Set(levels)).sorted()
        return levels.map { used.firstIndex(of: $0) ?? 0 }
    }
}

/// Go > To Heading…: popup "Outline". Picking scrolls to the heading.
public struct GoToHeadingPopup: View {
    let headings: [Heading]
    @Binding var query: String
    @Binding var selection: Int
    let onPick: (Heading) -> Void
    let onCancel: () -> Void

    public init(
        headings: [Heading], query: Binding<String>, selection: Binding<Int>,
        onPick: @escaping (Heading) -> Void, onCancel: @escaping () -> Void
    ) {
        self.headings = headings
        self._query = query
        self._selection = selection
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public var body: some View {
        let rows = HeadingList.rows(headings: headings, query: query)
        PopupCard(
            placeholder: "Outline", filter: $query, selection: $selection, rowCount: rows.count,
            onPick: { onPick(headings[rows[$0].index]) }, onCancel: onCancel
        ) { index in
            let heading = headings[rows[index].index]
            HStack(spacing: 0) {
                HeadingIcon(level: heading.level)
                Text(underlined(heading.text, indexes: rows[index].match?.indexes ?? []))
                    .foregroundStyle(rows[index].match == nil ? Color.tertiaryText : Color.secondaryText)
                    .truncationMode(.tail)
            }
            .padding(.leading, CGFloat(heading.level - 1) * Tokens.levelIndent)
        }
    }
}
