import Foundation

/// Replaces `range` (UTF-16 offsets) with `replacement`.
public struct TextEdit: Sendable {
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}
