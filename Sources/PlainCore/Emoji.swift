import Foundation
import PlainVendor

public struct EmojiEntry: Decodable, Hashable, Sendable {
    public var emoji: String
    public var aliases: [String]
    public var tags: [String]
}

/// The emoji list from `emoji.json`, loaded once.
public final class EmojiTable: Sendable {
    public static let shared = EmojiTable(url: VendorFiles.emojiJSON)

    public let entries: [EmojiEntry]
    /// Shortcode (without colons) to emoji character.
    public let byShortcode: [String: String]

    public init(url: URL) {
        let data = (try? Data(contentsOf: url)) ?? Data("[]".utf8)
        entries = (try? JSONDecoder().decode([EmojiEntry].self, from: data)) ?? []
        var map: [String: String] = [:]
        for entry in entries {
            for alias in entry.aliases where map[alias] == nil { map[alias] = entry.emoji }
        }
        byShortcode = map
    }

    /// The first shortcode for an emoji character.
    public func shortcode(for emoji: String) -> String? {
        entries.first { $0.emoji == emoji }?.aliases.first
    }

    /// Entries whose shortcode starts with the prefix, then entries whose tag does.
    public func search(prefix: String) -> [EmojiEntry] {
        let prefix = prefix.lowercased()
        let byName = entries.filter { $0.aliases.contains { $0.hasPrefix(prefix) } }
        let names = Set(byName.map(\.emoji))
        let byTag = entries.filter { !names.contains($0.emoji) && $0.tags.contains { $0.hasPrefix(prefix) } }
        return byName + byTag
    }

    static let recentName = "emoji-recent"

    /// Recently used emoji characters, most recent first.
    public func recent(in store: StateStore) async -> [String] {
        await store.load(Self.recentName, as: [String].self) ?? []
    }

    /// Moves the emoji to the front of the recent list and saves it.
    public func recordRecent(_ emoji: String, in store: StateStore) async throws {
        var list = await recent(in: store)
        list.removeAll { $0 == emoji }
        list.insert(emoji, at: 0)
        try await store.save(Self.recentName, list)
    }
}
