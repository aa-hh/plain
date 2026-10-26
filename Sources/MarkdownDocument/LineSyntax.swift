import Foundation

/// Line shapes that callers outside the parser need to recognise on a single line of text.
public enum LineSyntax {
    /// The marker's range when the whole line is spaces or tabs, then `-`, `*`, `+` or 1 to 9 digits followed by `.` or `)`, and nothing else.
    public static func bareListMarker(in line: String) -> NSRange? {
        let units = Array(line.utf16)
        var start = 0
        while start < units.count, units[start] == 32 || units[start] == 9 { start += 1 }
        let rest = units[start...]
        guard let last = rest.last else { return nil }
        if rest.count == 1, [45, 42, 43].contains(last) { return NSRange(location: start, length: 1) }
        guard last == 46 || last == 41 else { return nil }
        let digits = rest.dropLast()
        guard (1...9).contains(digits.count), digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return NSRange(location: start, length: rest.count)
    }
}
