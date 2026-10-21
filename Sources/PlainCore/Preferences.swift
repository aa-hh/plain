import Foundation
import Observation

public enum PreferenceValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    /// The value as written in the Preferences YAML block.
    public var yamlText: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case .string(let value):
            let plain = value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            return plain && !value.isEmpty ? value : "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
    }
}

public struct PreferenceKey: Sendable {
    public var name: String
    public var defaultValue: PreferenceValue
    public var min: Double?
    public var max: Double?
    /// Sort position in the YAML block; ties sort by name.
    public var order: Int
    /// Silent keys are menu toggles kept out of the Preferences file.
    public var silent: Bool

    public init(_ name: String, _ defaultValue: PreferenceValue, min: Double? = nil, max: Double? = nil, order: Int, silent: Bool = false) {
        self.name = name
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
        self.order = order
        self.silent = silent
    }

    public static let all: [PreferenceKey] = [
        PreferenceKey("font", .string("system-ui"), order: 1),
        PreferenceKey("fontSize", .number(15), min: 10, max: 30, order: 2),
        PreferenceKey("codeFont", .string("Roboto Mono"), order: 3),
        PreferenceKey("codeFontSize", .number(13), min: 10, max: 30, order: 4),
        PreferenceKey("lineHeight", .number(1.6), min: 1.5, max: 2, order: 5),
        PreferenceKey("lineWidth", .number(72), min: 20, order: 6),
        PreferenceKey("tabSize", .number(2), order: 7),
        PreferenceKey("useLargeFontInHeadings", .bool(true), order: 8),
        PreferenceKey("nightMode", .bool(false), order: 100, silent: true),
        PreferenceKey("typewriter", .bool(false), order: 100, silent: true),
        PreferenceKey("spellcheck", .bool(true), order: 100, silent: true),
        PreferenceKey("autoCorrectSpelling", .bool(false), order: 100, silent: true),
        PreferenceKey("file.autosave", .bool(true), order: 100, silent: true),
        PreferenceKey("text-stats.visible", .bool(false), order: 100, silent: true),
        PreferenceKey("text-stats.type", .string("word-count"), order: 100, silent: true),
    ]

    public static let byName: [String: PreferenceKey] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    func clamped(_ value: PreferenceValue) -> PreferenceValue {
        guard case .number(var number) = value else { return value }
        if let min { number = Swift.max(min, number) }
        if let max { number = Swift.min(max, number) }
        return .number(number)
    }
}

@Observable @MainActor
public final class Preferences {
    public private(set) var values: [String: PreferenceValue]

    public init(values: [String: PreferenceValue] = [:]) {
        var all = Dictionary(uniqueKeysWithValues: PreferenceKey.all.map { ($0.name, $0.defaultValue) })
        for (name, value) in values {
            if let key = PreferenceKey.byName[name] { all[name] = key.clamped(value) }
        }
        self.values = all
    }

    public subscript(name: String) -> PreferenceValue? { values[name] }

    /// Sets a known key, clamping numbers to the key's range. Unknown keys are ignored.
    public func set(_ name: String, _ value: PreferenceValue) {
        guard let key = PreferenceKey.byName[name] else { return }
        values[name] = key.clamped(value)
    }

    public func reset(_ name: String) {
        guard let key = PreferenceKey.byName[name] else { return }
        values[name] = key.defaultValue
    }

    public func number(_ name: String) -> Double {
        if case .number(let value) = values[name] { return value }
        return 0
    }

    public func bool(_ name: String) -> Bool {
        if case .bool(let value) = values[name] { return value }
        return false
    }

    public func string(_ name: String) -> String {
        if case .string(let value) = values[name] { return value }
        return ""
    }

    /// The YAML lines for the visible (non-silent) keys, ordered by `order` then name.
    public func yamlBody() -> String {
        PreferenceKey.all
            .filter { !$0.silent }
            .sorted { ($0.order, $0.name) < ($1.order, $1.name) }
            .map { "\($0.name): \((values[$0.name] ?? $0.defaultValue).yamlText)" }
            .joined(separator: "\n")
    }
}

/// Templates for `config/Preferences.md` and `config/Keyboard Shortcuts.md`.
public enum SettingsFiles {
    public static func preferencesMarkdown(yamlBody: String) -> String {
        """
        # Preferences

        Edit and save to update preferences:

        ```yaml
        \(yamlBody)
        ```

        This file lives in ~/Library/Application Support/Plain/config/. Plain rewrites the block above whenever a value changes.

        """
    }

    /// Menu groups that get a block in the Keyboard Shortcuts file, with their headings.
    public static let shortcutSections: [(MenuGroup, String)] = [
        (.file, "File"), (.edit, "Edit"), (.selection, "Selection"), (.format, "Format"), (.go, "Go"), (.view, "View"),
    ]

    /// YAML lines for one menu group: `key: Cmd S`, `key: ["Cmd P", "Cmd T"]`, or `key: ""` when unbound.
    /// Hidden and non-configurable commands are left out.
    public static func shortcutsYAML(for group: MenuGroup, commands: [Command] = Command.all) -> String {
        commands
            .filter { $0.menu == group && $0.configurable && !$0.hiddenFromMenu }
            .map { command -> String in
                let texts = command.shortcuts.map(\.fileText)
                let value: String
                switch texts.count {
                case 0: value = "\"\""
                case 1: value = texts[0]
                default: value = "[" + texts.map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\"))\"" }.joined(separator: ", ") + "]"
                }
                return "\(command.shortcutKey): \(value)"
            }
            .joined(separator: "\n")
    }

    public static func keyboardShortcutsMarkdown(commands: [Command] = Command.all) -> String {
        var text = "# Keyboard Shortcuts\n\nEdit and save to change shortcuts. Write keys with spaces, for example `Cmd Shift S`, or a list such as `[\"Cmd P\", \"Cmd T\"]`.\n"
        for (group, title) in shortcutSections {
            text += "\n## \(title)\n\n```yaml\n\(shortcutsYAML(for: group, commands: commands))\n```\n"
        }
        text += "\nThis file lives in ~/Library/Application Support/Plain/config/.\n"
        return text
    }
}
