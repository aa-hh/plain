import PlainCore
import PlainDocument
import SwiftUI

/// A backup tab's content: the merged diff, read-only, added lines on hsl(150,100%,75%) and removed lines on
/// hsl(0,100%,75%), both at 20%.
public struct BackupDiffView: View {
    let lines: [DiffLine]
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let columnWidth: CGFloat

    static let added = Color(red: 128 / 255, green: 1, blue: 191 / 255).opacity(0.2)
    static let removed = Color(red: 1, green: 128 / 255, blue: 128 / 255).opacity(0.2)

    public init(lines: [DiffLine], fontSize: CGFloat = 15, lineHeight: CGFloat = 24, columnWidth: CGFloat = 562) {
        self.lines = lines
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.columnWidth = columnWidth
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: fontSize))
                        .foregroundStyle(Color.textColor)
                        .frame(maxWidth: .infinity, minHeight: lineHeight, alignment: .leading)
                        .background(background(line.kind))
                }
            }
            .textSelection(.enabled)
            .frame(width: columnWidth)
            .padding(.top, Tokens.editorTopPadding)
            .padding(.bottom, Tokens.editorBottomPadding)
            .frame(maxWidth: .infinity)
        }
        .background(Color.material)
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .same: .clear
        case .added: Self.added
        case .removed: Self.removed
        }
    }
}
