import AppKit
import Foundation

/// Finds misspelled words in one paragraph and offers guesses. Main-actor because `NSSpellChecker` is.
@MainActor
public protocol SpellingEngine: AnyObject {
    /// Ranges of misspelled words, relative to the start of `paragraph`.
    func check(paragraph: String) async -> [NSRange]
    func guesses(for word: String) async -> [String]
    func learn(word: String)
}

/// The operating system's spelling engine. One spell-document tag per instance, so one per document.
@MainActor
public final class SystemSpellingEngine: SpellingEngine {
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()

    public init() {}

    deinit {
        let tag = tag
        Task { @MainActor in NSSpellChecker.shared.closeSpellDocument(withTag: tag) }
    }

    public func check(paragraph: String) async -> [NSRange] {
        let range = NSRange(location: 0, length: (paragraph as NSString).length)
        guard range.length > 0 else { return [] }
        let tag = tag
        return await withCheckedContinuation { continuation in
            NSSpellChecker.shared.requestChecking(
                of: paragraph, range: range,
                types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                options: nil, inSpellDocumentWithTag: tag
            ) { @Sendable _, results, _, _ in
                continuation.resume(returning: results.filter { $0.resultType == .spelling }.map(\.range))
            }
        }
    }

    public func guesses(for word: String) async -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return NSSpellChecker.shared.guesses(forWordRange: range, in: word, language: nil, inSpellDocumentWithTag: tag) ?? []
    }

    public func learn(word: String) {
        NSSpellChecker.shared.learnWord(word)
    }
}

/// Test adapter: a word is correct when it is in `words` (compared lowercased). Words are runs of
/// non-whitespace with surrounding punctuation trimmed, so `C++` arrives whole.
@MainActor
public final class WordListSpellingEngine: SpellingEngine {
    private var words: Set<String>
    private let guessTable: [String: [String]]

    public init(words: Set<String>, guesses: [String: [String]] = [:]) {
        self.words = Set(words.map { $0.lowercased() })
        self.guessTable = guesses
    }

    public func check(paragraph: String) async -> [NSRange] {
        let ns = paragraph as NSString
        var result: [NSRange] = []
        var start: Int?
        func close(at end: Int) {
            guard let s = start else { return }
            start = nil
            var range = NSRange(location: s, length: end - s)
            let trim = CharacterSet(charactersIn: ".,;:!?\"()")
            while range.length > 0, ns.substring(with: NSRange(location: range.location, length: 1)).unicodeScalars.allSatisfy(trim.contains) {
                range = NSRange(location: range.location + 1, length: range.length - 1)
            }
            while range.length > 0, ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1)).unicodeScalars.allSatisfy(trim.contains) {
                range.length -= 1
            }
            if range.length > 0, !words.contains(ns.substring(with: range).lowercased()) { result.append(range) }
        }
        for i in 0..<ns.length {
            let isSpace = ns.substring(with: NSRange(location: i, length: 1)).rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            if isSpace { close(at: i) } else if start == nil { start = i }
        }
        close(at: ns.length)
        return result
    }

    public func guesses(for word: String) async -> [String] { guessTable[word.lowercased()] ?? [] }

    public func learn(word: String) { words.insert(word.lowercased()) }
}
