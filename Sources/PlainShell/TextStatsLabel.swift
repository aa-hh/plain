import PlainCore
import SwiftUI

/// The `text-stats.type` values.
public enum TextStatsMode: String, CaseIterable, Sendable {
    case wordCount = "word-count"
    case characterCount = "character-count"
    case readingTime = "reading-time"

    /// `N W`, `N C` or `mm:ss RT`.
    public func label(for text: String) -> String {
        switch self {
        case .wordCount: TextStats.wordLabel(text)
        case .characterCount: TextStats.characterLabel(text)
        case .readingTime: TextStats.readingTimeLabel(text)
        }
    }
}

/// The counter at the bottom right: the selection's count if there is one (on a blue background), else the
/// document's. Hidden when the text is empty. Clicking opens a menu of all three values.
public struct TextStatsLabel: View {
    /// The selected text, or the whole document when nothing is selected.
    let text: String
    let isSelection: Bool
    let mode: TextStatsMode
    let onPick: (TextStatsMode) -> Void

    public init(text: String, isSelection: Bool, mode: TextStatsMode, onPick: @escaping (TextStatsMode) -> Void) {
        self.text = text
        self.isSelection = isSelection
        self.mode = mode
        self.onPick = onPick
    }

    public var body: some View {
        if !text.isEmpty {
            Menu {
                ForEach(TextStatsMode.allCases, id: \.self) { mode in
                    Button(mode.label(for: text)) { onPick(mode) }
                }
            } label: {
                Text(mode.label(for: text))
                    .font(uiFont)
                    .foregroundStyle(Color.tertiaryText)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(height: Tokens.line)
            .background(isSelection ? Color.selectionBlue : Color.material)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
    }
}
