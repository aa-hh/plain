import Foundation
import Observation

/// A replacement the editor applies as its own undo step.
public struct Correction: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
}

/// Keeps the list of misspelled ranges for one document and decides when to recheck.
@MainActor @Observable
public final class SpellcheckController {
    public private(set) var misspellings: [NSRange] = []
    public var enabled = true {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { schedule(NSRange(location: 0, length: (text as NSString).length), after: .zero) } else { cancelAndClear() }
        }
    }
    public var autocorrect = false

    @ObservationIgnored private let engine: SpellingEngine
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private var text = ""
    @ObservationIgnored private var excluded: [NSRange] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: NSRange?
    /// The word being typed one character at a time, if any.
    @ObservationIgnored private var typedWord: NSRange?
    @ObservationIgnored private var corrected: Set<String> = []

    public init(engine: SpellingEngine, delay: Duration = .seconds(1)) {
        self.engine = engine
        self.delay = delay
    }

    /// `changedRange` is the edited range in the new `text`. `typedCharacter` is the character typed,
    /// or the character deleted; a space in either case rechecks immediately (spec 320).
    public func textChanged(text newText: String, changedRange: NSRange, excludedRanges: [NSRange], typedCharacter: Character?) {
        let delta = (newText as NSString).length - (text as NSString).length
        text = newText
        excluded = excludedRanges
        generation += 1
        trackTypedWord(changedRange: changedRange, typedCharacter: typedCharacter)
        guard enabled else { return }
        let oldEnd = changedRange.location + changedRange.length - delta
        misspellings = misspellings.map { $0.location >= oldEnd ? NSRange(location: $0.location + delta, length: $0.length) : $0 }
        let union = pending.map { NSUnionRange($0, changedRange) } ?? changedRange
        schedule(union, after: typedCharacter == " " ? .zero : delay)
    }

    /// Up to 4 guesses for the misspelling at `range` (spec 202).
    public func corrections(for range: NSRange) async -> [String] {
        guard NSMaxRange(range) <= (text as NSString).length else { return [] }
        return Array(await engine.guesses(for: (text as NSString).substring(with: range)).prefix(4))
    }

    public func learn(word: String) async {
        engine.learn(word: word)
        schedule(NSRange(location: 0, length: (text as NSString).length), after: .zero)
        await task?.value
    }

    /// Call after the editor inserts a space at `offset`. Returns the correction to apply, if any (spec 323).
    public func didTypeSpace(at offset: Int, in text: String) async -> Correction? {
        let word = typedWord
        typedWord = nil
        guard autocorrect, enabled, let word, NSMaxRange(word) == offset, NSMaxRange(word) <= (text as NSString).length else { return nil }
        let string = (text as NSString).substring(with: word)
        let key = "\(word.location):\(string)"
        guard !corrected.contains(key), Self.isCheckable(string) else { return nil }
        let wholeWord = NSRange(location: 0, length: (string as NSString).length)
        guard await engine.check(paragraph: string) == [wholeWord], let best = await engine.guesses(for: string).first else { return nil }
        corrected.insert(key)
        return Correction(range: word, replacement: best)
    }

    private func trackTypedWord(changedRange: NSRange, typedCharacter: Character?) {
        guard let c = typedCharacter else { typedWord = nil; return }
        if c == " " { return }
        guard changedRange.length == 1, Self.isWordCharacter(c) else { typedWord = nil; return }
        if let w = typedWord, NSMaxRange(w) == changedRange.location {
            typedWord = NSRange(location: w.location, length: w.length + 1)
        } else {
            typedWord = changedRange
        }
    }

    private func schedule(_ range: NSRange, after wait: Duration) {
        pending = range
        task?.cancel()
        let gen = generation
        task = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, let self else { return }
            await self.recheck(gen)
        }
    }

    private func recheck(_ gen: Int) async {
        guard let range = pending else { return }
        pending = nil
        let ns = text as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: ns.paragraphRange(for: clamped), options: .byParagraphs) { _, r, _, _ in paragraphs.append(r) }
        for paragraph in paragraphs where paragraph.length > 0 {
            let found = await engine.check(paragraph: ns.substring(with: paragraph))
            guard gen == generation else { return }
            let fresh = found.compactMap { r -> NSRange? in
                let abs = NSRange(location: r.location + paragraph.location, length: r.length)
                let word = ns.substring(with: abs)
                guard Self.isCheckable(word), !excluded.contains(where: { NSIntersectionRange($0, abs).length > 0 }) else { return nil }
                return abs
            }
            misspellings = misspellings.filter { NSIntersectionRange($0, paragraph).length == 0 } + fresh
        }
        misspellings.sort { $0.location < $1.location }
    }

    private func cancelAndClear() {
        task?.cancel()
        pending = nil
        misspellings = []
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c == "'" || c == "’" || c == "-" }

    /// Spec 321: more than one character, only letters, apostrophes and hyphens.
    private static func isCheckable(_ word: String) -> Bool { word.count > 1 && word.allSatisfy(isWordCharacter) }
}
