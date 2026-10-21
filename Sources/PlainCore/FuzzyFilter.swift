import Foundation

public struct FuzzyMatch: Hashable, Sendable {
    /// Character offsets (in `Character`s) of the matched query letters.
    public var indexes: [Int]
    public var score: Int
}

private let wordSeparators: Set<Character> = [" ", "-", "_", "/", "."]

/// Matches the query's characters in order. Case-insensitive unless the query has a capital letter.
/// The score rewards matches at word starts and runs of adjacent matches.
public func fuzzyMatch(query: String, in text: String) -> FuzzyMatch? {
    let caseSensitive = query.contains { $0.isUppercase }
    let needle = Array(caseSensitive ? query : query.lowercased())
    let haystack = Array(text)
    guard !needle.isEmpty else { return FuzzyMatch(indexes: [], score: 0) }

    var indexes: [Int] = []
    var score = 0
    var q = 0
    for (i, character) in haystack.enumerated() where q < needle.count {
        let candidate = caseSensitive ? character : Character(character.lowercased())
        guard candidate == needle[q] else { continue }
        score += 1
        if i == 0 || wordSeparators.contains(haystack[i - 1]) { score += 8 }
        if let last = indexes.last, last == i - 1 { score += 4 }
        indexes.append(i)
        q += 1
    }
    return q == needle.count ? FuzzyMatch(indexes: indexes, score: score) : nil
}

/// Items whose text fuzzy-matches the query, best score first; equal scores keep input order.
/// An empty query returns every item.
public func filter<Item>(items: [Item], query: String, text: (Item) -> String) -> [(item: Item, match: FuzzyMatch)] {
    items.enumerated()
        .compactMap { offset, item in fuzzyMatch(query: query, in: text(item)).map { (offset, item, $0) } }
        .sorted { $0.2.score != $1.2.score ? $0.2.score > $1.2.score : $0.0 < $1.0 }
        .map { (item: $0.1, match: $0.2) }
}

/// The first case-insensitive occurrence of the query.
public func substringMatch(query: String, in text: String) -> Range<String.Index>? {
    guard !query.isEmpty else { return nil }
    return text.range(of: query, options: .caseInsensitive)
}

/// The first case-insensitive occurrence of the query that starts a space-separated chunk.
public func chunkStartMatch(query: String, in text: String) -> Range<String.Index>? {
    guard !query.isEmpty else { return nil }
    var start = text.startIndex
    while let range = text.range(of: query, options: .caseInsensitive, range: start..<text.endIndex) {
        if range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)] == " " {
            return range
        }
        start = text.index(after: range.lowerBound)
    }
    return nil
}
