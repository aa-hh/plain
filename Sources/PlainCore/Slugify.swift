import Foundation

/// A heading id: lower case, transliterated to Latin without accents, non-alphanumeric runs turned into one `-`, trimmed.
public func slugify(_ text: String) -> String {
    let latin = (text.applyingTransform(.toLatin, reverse: false) ?? text)
        .applyingTransform(.stripDiacritics, reverse: false) ?? text
    var slug = ""
    var pendingDash = false
    for character in latin.lowercased() {
        if character.isASCII && (character.isLetter || character.isNumber) {
            if pendingDash && !slug.isEmpty { slug.append("-") }
            pendingDash = false
            slug.append(character)
        } else {
            pendingDash = true
        }
    }
    return slug
}

/// Makes repeated slugs unique by appending `-1`, `-2` and so on.
public struct SlugCounter: Sendable {
    private var seen: [String: Int] = [:]

    public init() {}

    public mutating func unique(_ slug: String) -> String {
        guard var count = seen[slug] else {
            seen[slug] = 0
            return slug
        }
        var candidate: String
        repeat {
            count += 1
            candidate = "\(slug)-\(count)"
        } while seen[candidate] != nil
        seen[slug] = count
        seen[candidate] = 0
        return candidate
    }
}
