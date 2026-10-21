import PlainCore
import SwiftUI

/// The rows of Go to Command.
public enum CommandList {
    static let menuNames: [MenuGroup: String] = [
        .plain: "Plain", .file: "File", .edit: "Edit", .selection: "Selection", .format: "Format",
        .go: "Go", .view: "View", .window: "Window", .help: "Help",
    ]

    /// `File › Save`.
    public static func label(_ command: Command) -> String {
        "\(menuNames[command.menu] ?? "") › \(command.title)"
    }

    /// Every application-menu command. Empty query: the up to 3 most recently run first, then a divider
    /// (`dividerAfter`), then the rest in menu order. With a query: fuzzy-filtered by label, best match first.
    public static func rows(
        commands: [Command], recent: [String], query: String
    ) -> (rows: [(command: Command, match: FuzzyMatch)], dividerAfter: Int?) {
        let menu = commands.filter { menuNames[$0.menu] != nil && !$0.hiddenFromMenu }
        guard query.isEmpty else {
            return (filter(items: menu, query: query, text: label).map { ($0.item, $0.match) }, nil)
        }
        let empty = emptyMatch
        let top = recent.prefix(3).compactMap { id in menu.first { $0.id == id } }
        let rest = menu.filter { command in !top.contains { $0.id == command.id } }
        let rows = (top + rest).map { ($0, empty) }
        return (rows, top.isEmpty ? nil : top.count - 1)
    }
}

/// Go > To Command…: popup "Commands" listing `Menu › Item`, a ✓ for checked items and the first shortcut.
public struct CommandsPopup: View {
    let commands: [Command]
    let recent: [String]
    let isChecked: (String) -> Bool
    @Binding var query: String
    @Binding var selection: Int
    let onRun: (Command) -> Void
    let onCancel: () -> Void

    public init(
        commands: [Command] = Command.all, recent: [String], isChecked: @escaping (String) -> Bool,
        query: Binding<String>, selection: Binding<Int>,
        onRun: @escaping (Command) -> Void, onCancel: @escaping () -> Void
    ) {
        self.commands = commands
        self.recent = recent
        self.isChecked = isChecked
        self._query = query
        self._selection = selection
        self.onRun = onRun
        self.onCancel = onCancel
    }

    public var body: some View {
        let list = CommandList.rows(commands: commands, recent: recent, query: query)
        PopupCard(
            placeholder: "Commands", filter: $query, selection: $selection, rowCount: list.rows.count,
            dividerAfter: list.dividerAfter, onPick: { onRun(list.rows[$0].command) }, onCancel: onCancel
        ) { index in
            let command = list.rows[index].command
            let prefix = "\(CommandList.menuNames[command.menu] ?? "") › "
            let indexes = list.rows[index].match.indexes
            HStack(spacing: 0) {
                Text(underlined(prefix, indexes: indexes)).foregroundStyle(Color.tertiaryText)
                Text(underlined(command.title, indexes: indexes, offset: prefix.count))
                if command.kind != .action && isChecked(command.id) { Text(" ✓") }
                Spacer(minLength: 10)
                if let shortcut = command.shortcuts.first {
                    Text(spacedSymbols(shortcut)).foregroundStyle(Color.tertiaryText)
                }
            }
        }
    }
}
