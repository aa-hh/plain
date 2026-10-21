import Foundation
import PlainCore
import Yams

public enum ShortcutsError: Error, Equatable {
    case noYAMLBlock
    case unreadable
    case badShortcut(String)
}

/// The Keyboard Shortcuts file (spec 1076–1083): one YAML block per menu section, keys are command ids without
/// their prefix, values one shortcut or a list. Saving it rebinds the menu, the key monitor and the editor.
public enum Shortcuts {
    /// The file Plain writes for the given commands (their current shortcuts).
    public static func markdown(commands: [Command]) -> String {
        SettingsFiles.keyboardShortcutsMarkdown(commands: commands)
    }

    /// Every `key: shortcuts` pair in the file's YAML blocks. Throws when a block does not parse or a shortcut is unknown.
    public static func parse(_ markdown: String) throws -> [String: [Shortcut]] {
        let blocks = yamlBlocks(in: markdown)
        guard !blocks.isEmpty else { throw ShortcutsError.noYAMLBlock }
        var result: [String: [Shortcut]] = [:]
        for block in blocks {
            let loaded: Any?
            do { loaded = try Yams.load(yaml: block) } catch { throw ShortcutsError.unreadable }
            guard let loaded else { continue }
            guard let map = loaded as? [String: Any] else { throw ShortcutsError.unreadable }
            for (key, value) in map {
                let texts: [String]
                if let text = value as? String {
                    texts = text.isEmpty ? [] : [text]
                } else if let list = value as? [Any] {
                    texts = try list.map { item in
                        guard let text = item as? String else { throw ShortcutsError.unreadable }
                        return text
                    }.filter { !$0.isEmpty }
                } else {
                    throw ShortcutsError.unreadable
                }
                result[key] = try texts.map { text in
                    guard let shortcut = Shortcut(text) else { throw ShortcutsError.badShortcut(text) }
                    return shortcut
                }
            }
        }
        return result
    }

    /// The commands with the file's shortcuts on the configurable ones it names. Others keep theirs.
    public static func apply(_ parsed: [String: [Shortcut]], to commands: [Command]) -> [Command] {
        let sectionGroups = Set(SettingsFiles.shortcutSections.map(\.0))
        var byID: [String: [Shortcut]] = [:]
        for command in commands where sectionGroups.contains(command.menu) && command.configurable && !command.hiddenFromMenu {
            if let shortcuts = parsed[command.shortcutKey] { byID[command.id] = shortcuts }
        }
        return overriding(byID, in: commands)
    }

    /// Replaces the shortcuts of commands by id, leaving non-configurable commands as they are.
    public static func overriding(_ shortcutsByID: [String: [Shortcut]], in commands: [Command]) -> [Command] {
        commands.map { command in
            var command = command
            if command.configurable, command.menu != .tabContext, let shortcuts = shortcutsByID[command.id] {
                command.shortcuts = shortcuts
            }
            return command
        }
    }

    /// The configurable commands whose shortcuts differ from the defaults, by id, in file form.
    public static func overrides(_ commands: [Command], defaults: [Command] = Command.all) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (command, original) in zip(commands, defaults) where command.shortcuts != original.shortcuts {
            result[command.id] = command.shortcuts.map(\.fileText)
        }
        return result
    }

    /// Turns stored overrides back into shortcuts, skipping any that no longer parse.
    public static func decode(_ stored: [String: [String]]) -> [String: [Shortcut]] {
        stored.mapValues { $0.compactMap(Shortcut.init) }
    }

    /// The contents of every fenced `yaml` block.
    static func yamlBlocks(in markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring]?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if current == nil {
                if trimmed.hasPrefix("```"), trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == "yaml" {
                    current = []
                }
            } else if trimmed == "```" {
                blocks.append(current!.joined(separator: "\n"))
                current = nil
            } else {
                current!.append(line)
            }
        }
        return blocks
    }
}
