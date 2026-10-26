import Foundation

public enum Modifier: String, Hashable, Sendable, CaseIterable {
    case cmd, ctrl, alt, shift
}

/// A key combination, written in the Keyboard Shortcuts file as `"Cmd Shift S"`.
public struct Shortcut: Hashable, Sendable {
    public var modifiers: Set<Modifier>
    /// Canonical key name: an upper-cased single character, or one of `Shortcut.namedKeys`.
    public var key: String

    public init(modifiers: Set<Modifier>, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    public static let namedKeys: [String] = [
        "Up", "Down", "Left", "Right", "Enter", "Backspace", "Delete", "Esc", "Tab", "Space",
        "Home", "End", "PageUp", "PageDown", "Plus", "Minus",
    ] + (1...12).map { "F\($0)" }

    /// File-form order of modifiers.
    static let modifierOrder: [Modifier] = [.cmd, .ctrl, .alt, .shift]
    static let modifierNames: [String: Modifier] = [
        "cmd": .cmd, "command": .cmd, "ctrl": .ctrl, "control": .ctrl,
        "alt": .alt, "option": .alt, "shift": .shift,
    ]

    /// Parses the file form, for example `"Cmd Shift S"`. Returns nil for an unknown key or a missing key.
    public init?(_ text: String) {
        let parts = text.split(separator: " ").map(String.init)
        guard let last = parts.last else { return nil }
        var modifiers = Set<Modifier>()
        for part in parts.dropLast() {
            guard let modifier = Self.modifierNames[part.lowercased()] else { return nil }
            modifiers.insert(modifier)
        }
        guard let key = Self.canonicalKey(last) else { return nil }
        self.init(modifiers: modifiers, key: key)
    }

    static func canonicalKey(_ name: String) -> String? {
        if name == "=" { return "Plus" }
        if name == "-" { return "Minus" }
        if name.count == 1 { return name.uppercased() }
        return namedKeys.first { $0.lowercased() == name.lowercased() }
    }

    /// The file form, for example `"Cmd Shift S"`.
    public var fileText: String {
        (Self.modifierOrder.filter(modifiers.contains).map { $0.rawValue.capitalized } + [key]).joined(separator: " ")
    }

    /// The macOS form shown in the Commands popup, for example `"⇧⌘S"`.
    public var symbols: String {
        let order: [(Modifier, String)] = [(.ctrl, "⌃"), (.alt, "⌥"), (.shift, "⇧"), (.cmd, "⌘")]
        let keySymbols: [String: String] = [
            "Backspace": "⌫", "Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "Esc": "⎋",
            "Plus": "=", "Minus": "-",
        ]
        return order.filter { modifiers.contains($0.0) }.map(\.1).joined() + (keySymbols[key] ?? key)
    }
}

public enum MenuGroup: String, Sendable, CaseIterable {
    case plain, file, edit, selection, format, go, view, window, help, tabContext, editorContext
}

public enum CommandKind: Hashable, Sendable {
    case action
    case checkbox
    case radio(group: String)
}

public struct Command: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var menu: MenuGroup
    public var shortcuts: [Shortcut]
    public var kind: CommandKind
    public var configurable: Bool
    public var hiddenFromMenu: Bool

    public init(
        id: String, title: String, menu: MenuGroup, shortcuts: [Shortcut] = [], kind: CommandKind = .action,
        configurable: Bool = true, hiddenFromMenu: Bool = false
    ) {
        self.id = id
        self.title = title
        self.menu = menu
        self.shortcuts = shortcuts
        self.kind = kind
        self.configurable = configurable
        self.hiddenFromMenu = hiddenFromMenu
    }

    /// The Keyboard Shortcuts file key: the id without its prefix.
    public var shortcutKey: String {
        id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
    }
}

private func c(
    _ title: String, _ id: String, _ menu: MenuGroup, _ shortcuts: String..., kind: CommandKind = .action,
    configurable: Bool = true, hidden: Bool = false
) -> Command {
    Command(
        id: id, title: title, menu: menu, shortcuts: shortcuts.map { Shortcut($0)! }, kind: kind,
        configurable: configurable, hiddenFromMenu: hidden)
}

extension Command {
    public static let all: [Command] = [
        // Plain
        c("About Plain", "application:about", .plain, configurable: false),
        c("Preferences…", "application:preferences", .plain, "Cmd ,"),
        c("Keyboard Shortcuts…", "application:keyboard-shortcuts", .plain),

        // File
        c("New", "window:new-file", .file, "Cmd N"),
        c("New Window", "file:new-window", .file, "Cmd Shift N"),
        c("Open…", "window:open", .file, "Cmd O"),
        c("Open Recent Folder…", "window:recent-folders", .file, "Ctrl R"),
        c("Save", "file:save", .file, "Cmd S"),
        c("Save As…", "file:save-as", .file, "Cmd Shift S"),
        c("Autosave", "window:toggle-autosave", .file, kind: .checkbox),
        c("Backups…", "window:backups", .file),
        c("Export to PDF…", "window:export-to-pdf", .file),
        c("Export to HTML…", "window:export-to-html", .file),
        c("Close Tab", "window:close-tab", .file, "Cmd W"),
        c("Close Other Tabs", "window:close-other-tabs", .file, "Cmd Alt W"),
        c("Close All Tabs", "window:close-all-tabs", .file),
        c("Reopen Last Closed Tab", "window:reopen-closed-tab", .file, "Cmd Shift T"),

        // Edit
        c("Undo", "editor:undo", .edit, "Cmd Z"),
        c("Redo", "editor:redo", .edit, "Cmd Shift Z"),
        c("Cut", "editor:cut", .edit, "Cmd X"),
        c("Copy", "editor:copy", .edit, "Cmd C"),
        c("Copy as Rich Text", "editor:copy-as-rich-text", .edit, "Cmd Shift C"),
        c("Copy as HTML", "editor:copy-as-html", .edit, "Cmd Alt C"),
        c("Paste", "editor:paste", .edit, "Cmd V"),
        c("Paste Formatted", "editor:paste-formatted", .edit),
        c("Move Line Up", "editor:move-line-up", .edit, "Cmd Ctrl Up", "Alt Shift Up", "Cmd Alt Up"),
        c("Move Line Down", "editor:move-line-down", .edit, "Cmd Ctrl Down", "Alt Shift Down", "Cmd Alt Down"),
        c("Duplicate Line", "editor:duplicate-line", .edit, "Cmd Shift D"),
        c("Delete Line", "editor:delete-line", .edit, "Cmd Shift K"),
        c("Toggle Case", "editor:toggle-case", .edit, "Cmd Shift U"),
        c("Show Context Menu", "editor:toggle-menu", .edit, "Ctrl Space", "Alt Enter"),
        c("Find…", "editor:find", .edit, "Cmd F"),
        c("Find in Folder…", "window:find-in-files", .edit, "Cmd Shift F"),
        c("Check Spelling", "editor:toggle-spellcheck", .edit, kind: .checkbox),
        c("Autocorrect Spelling", "editor:toggle-autocorrect", .edit, kind: .checkbox),

        // Selection
        c("Select All", "editor:select-all", .selection, "Cmd A"),
        c("Extend Selection", "editor:extend-selection", .selection, "Alt Up", "Cmd Ctrl Shift Right"),
        c("Shrink Selection", "editor:shrink-selection", .selection, "Alt Down", "Cmd Ctrl Shift Left"),
        c("Add Next Occurrence", "editor:add-next-occurrence", .selection, "Cmd D", "Ctrl G"),
        c("Add Each Occurrence", "editor:add-each-occurrence", .selection, "Cmd Ctrl G"),
        c("Remove Last Occurrence", "editor:remove-last-occurrence", .selection, "Cmd U", "Ctrl Shift G"),
        c("Add Selection Above", "editor:add-selection-above", .selection, "Shift Ctrl Up"),
        c("Add Selection Below", "editor:add-selection-below", .selection, "Shift Ctrl Down"),
        c("Split Selection Into Lines", "editor:split-selection-into-lines", .selection, "Cmd Shift L"),

        // Format
        c("Heading 1", "editor:heading1", .format),
        c("Heading 2", "editor:heading2", .format),
        c("Heading 3", "editor:heading3", .format),
        c("Heading 4", "editor:heading4", .format),
        c("Heading 5", "editor:heading5", .format),
        c("Heading 6", "editor:heading6", .format),
        c("Bold", "editor:bold", .format, "Cmd B"),
        c("Italic", "editor:italic", .format, "Cmd I"),
        c("Strikethrough", "editor:strikethrough", .format),
        c("Mark", "editor:mark", .format),
        c("Link", "editor:link", .format, "Cmd K"),
        c("Image", "editor:image", .format),
        c("List", "editor:list", .format),
        c("Ordered List", "editor:ordered-list", .format),
        c("Task List", "editor:task-list", .format),
        c("Quote", "editor:quote", .format),
        c("Comment", "editor:comment", .format, "Cmd /"),
        c("Code", "editor:code", .format),
        c("Code Block", "editor:code-block", .format),
        c("Math", "editor:math", .format),
        c("Math Block", "editor:math-block", .format),
        c("Add Table of Contents", "editor:table-of-contents", .format),
        c("Add Thematic Break", "editor:thematic-break", .format),
        c("Add Page Break", "editor:page-break", .format),
        c("Clear Syntax", "editor:clear-syntax", .format, "Cmd Alt Backspace"),

        // Go
        c("To File…", "window:files", .go, "Cmd P", "Cmd T", "Cmd Shift O"),
        c("To Heading…", "window:titles", .go, "Cmd R"),
        c("To Command…", "window:commands", .go, "Cmd Shift P", "Cmd Shift A"),
        c("To Next Tab", "window:next-tab", .go, "Cmd Alt Right", "Cmd Shift ]"),
        c("To Previous Tab", "window:previous-tab", .go, "Cmd Alt Left", "Cmd Shift ["),
        c("Back", "window:go-back", .go, "Cmd ["),
        c("Forward", "window:go-forward", .go, "Cmd ]"),
        c("To Last Edit", "editor:last-edit", .go, "Cmd Shift Backspace", "Ctrl Q", "Ctrl Minus"),
        c("To Next Edit", "editor:next-edit", .go, "Ctrl Shift Minus", "Ctrl Plus", hidden: true),

        // View
        c("Show Files", "window:sidebar", .view, "Cmd Shift E"),
        c("Show Outline", "window:headings-bar", .view, "Cmd Shift B"),
        c("Show Sidebar", "window:toggle-sidebar", .view, "Cmd \\", kind: .checkbox),
        c("Show Preview", "window:toggle-live-preview", .view, "Cmd Shift I", kind: .checkbox),
        c("Preview", "window:toggle-preview", .view, kind: .checkbox),
        c("Add Theme…", "application:add-custom-theme", .view),
        c("Mode Dark", "window:dark-mode", .view, "Cmd Alt L", "Cmd Ctrl N", kind: .checkbox),
        c("Mode Typewriter", "window:typewriter-mode", .view, "Cmd Alt T", kind: .checkbox),
        c("Show Markdown Source", "window:toggle-markdown-source", .view, "Cmd Shift M", kind: .checkbox),
        c("Show Stats", "window:toggle-text-stats", .view, kind: .checkbox),
        c("Font Size Up", "window:font-size-increase", .view, "Cmd Plus", "Cmd Shift Plus", configurable: false),
        c("Font Size Down", "window:font-size-decrease", .view, "Cmd Minus", configurable: false),
        c("Font Size Default", "window:font-size-default", .view, "Cmd 0", configurable: false),
        c("Hide Interface", "window:hide-interface", .view, "Cmd .", hidden: true),

        // Help
        c("Open Welcome Folder", "application:welcome", .help),
        c("Third-Party Licences", "application:licences", .help),

        // Tab context menu (the close items reuse the File ids; their shortcuts live on the File entries)
        c("Close Tab", "window:close-tab", .tabContext),
        c("Close Other Tabs", "window:close-other-tabs", .tabContext),
        c("Close All Tabs", "window:close-all-tabs", .tabContext),
        c("Move to the Left", "window:move-tab-left", .tabContext, "Ctrl Shift Left"),
        c("Move to the Right", "window:move-tab-right", .tabContext, "Ctrl Shift Right"),
        c("Show in Finder", "window:show-in-finder", .tabContext),
        c("Revert to This", "window:revert-to-backup", .tabContext),
    ]

}
