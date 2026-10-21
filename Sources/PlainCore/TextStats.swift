import Foundation

public enum TextStats {
    static let punctuation: Set<Character> = ["'", "\"", ";", ":", ",", ".", "?", "¿", "-", "!", "¡"]

    /// Words after removing `' " ; : , . ? ¿ - ! ¡`, split on whitespace.
    public static func wordCount(_ text: String) -> Int {
        String(text.filter { !punctuation.contains($0) })
            .split(whereSeparator: \.isWhitespace)
            .count
    }

    public static func characterCount(_ text: String) -> Int { text.count }

    /// Reading time at 200 words per minute as `mm:ss`.
    public static func readingTime(words: Int) -> String {
        let seconds = Int((Double(words) * 60 / 200).rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    public static func wordLabel(_ text: String) -> String { "\(wordCount(text)) W" }
    public static func characterLabel(_ text: String) -> String { "\(characterCount(text)) C" }
    public static func readingTimeLabel(_ text: String) -> String { "\(readingTime(words: wordCount(text))) RT" }
}
