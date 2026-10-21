import PlainCore
import PlainDocument
import SwiftUI

/// File > Backups…: popup "Backups" listing this file's backups newest first by friendly date.
public struct BackupsPopup: View {
    let backups: [BackupInfo]
    @Binding var query: String
    @Binding var selection: Int
    let onPick: (BackupInfo) -> Void
    let onCancel: () -> Void

    public init(
        backups: [BackupInfo], query: Binding<String>, selection: Binding<Int>,
        onPick: @escaping (BackupInfo) -> Void, onCancel: @escaping () -> Void
    ) {
        self.backups = backups
        self._query = query
        self._selection = selection
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public var body: some View {
        let rows = filter(items: backups, query: query) { $0.friendlyDate }
        PopupCard(
            placeholder: "Backups", filter: $query, selection: $selection, rowCount: rows.count,
            onPick: { onPick(rows[$0].item) }, onCancel: onCancel
        ) { index in
            Text(underlined(rows[index].item.friendlyDate, indexes: rows[index].match.indexes))
        }
    }
}
