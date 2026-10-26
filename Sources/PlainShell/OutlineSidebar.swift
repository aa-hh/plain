import MarkdownDocument
import PlainCore
import SwiftUI

/// The Outline sidebar: every heading, indented 16 pt per rank among the levels in use, with an h1–h6 icon.
/// The current heading (the last one above the caret) is highlighted. Typing filters, keeping parents.
public struct OutlineSidebar: View {
    let headings: [Heading]
    /// Caret offset in the document, for the current heading.
    let caretOffset: Int
    /// Headings whose section holds a git change.
    let changedHeadings: Set<BlockID>
    /// Jumps to a heading; `focusEditor` is true for Enter and a click, false for Space.
    let onJump: (Heading, _ focusEditor: Bool) -> Void

    /// Set by Show Outline; the filter takes keyboard focus and clears it (spec 921).
    @Binding var focusRequested: Bool

    @State private var query = ""
    @State private var cursor: Int?
    @FocusState private var focused: Bool
    @FocusState private var filterFocused: Bool
    /// The filter row shows while it is focused or holds a query.
    @State private var filterShown = false

    public init(
        headings: [Heading], caretOffset: Int, changedHeadings: Set<BlockID>,
        focusRequested: Binding<Bool> = .constant(false), onJump: @escaping (Heading, Bool) -> Void
    ) {
        self.headings = headings
        self.caretOffset = caretOffset
        self.changedHeadings = changedHeadings
        self._focusRequested = focusRequested
        self.onJump = onJump
    }

    /// Index of the last heading starting at or before `offset`.
    public static func currentHeading(_ headings: [Heading], caretOffset offset: Int) -> Int? {
        headings.lastIndex { $0.range.location <= offset }
    }

    public var body: some View {
        let rows = HeadingList.rows(headings: headings, query: query)
        let ranks = HeadingList.ranks(levels: headings.map(\.level))
        let current = Self.currentHeading(headings, caretOffset: caretOffset)
        VStack(spacing: 0) {
            if filterShown || !query.isEmpty {
                TextField("", text: $query, prompt: Text("Outline").foregroundStyle(Color.tertiaryText))
                    .textFieldStyle(.plain)
                    .font(uiFont)
                    .foregroundStyle(Color.textColor)
                    .focused($filterFocused)
                    .padding(.horizontal, Tokens.rowPadding)
                    .frame(height: Tokens.line)
            }
            if headings.isEmpty {
                Text("No headings")
                    .font(uiFont)
                    .foregroundStyle(Color.tertiaryText)
                    .padding(.horizontal, Tokens.rowPadding)
                    .frame(maxWidth: .infinity, minHeight: Tokens.line, maxHeight: Tokens.line, alignment: .leading)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.index) { row in
                            let heading = headings[row.index]
                            HStack(spacing: 0) {
                                HeadingIcon(level: heading.level)
                                Text(heading.text).truncationMode(.tail)
                                Spacer(minLength: 4)
                                if changedHeadings.contains(heading.blockID) { GitMarkLabel(mark: .changed) }
                            }
                            .font(uiFont)
                            .foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
                            .padding(.leading, Tokens.rowPadding + CGFloat(ranks[row.index]) * Tokens.levelIndent)
                            .padding(.trailing, Tokens.rowPadding)
                            .frame(height: Tokens.line)
                            .background(row.index == (cursor ?? current) ? Color.selectionBlue : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { cursor = row.index; onJump(heading, true) }
                            .id(row.index)
                        }
                    }
                    .padding(.bottom, Tokens.editorBottomPadding)
                }
                .onChange(of: current) { _, index in cursor = nil; if let index { proxy.scrollTo(index) } }
            }
        }
        .focused($focused)
        .task(id: focusRequested) {
            guard focusRequested else { return }
            filterShown = true
            focusRequested = false
            // The filter row appears with this update; focus moves once it exists.
            try? await Task.sleep(for: .milliseconds(1))
            filterFocused = true
        }
        .onChange(of: filterFocused) { _, isFocused in if !isFocused { filterShown = false } }
        .onKeyPress(phases: .down) { press in handle(press, rows: rows.map(\.index), current: current) }
    }

    private func handle(_ press: KeyPress, rows: [Int], current: Int?) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let position = (cursor ?? current).flatMap { rows.firstIndex(of: $0) }
        switch press.key {
        case .downArrow: cursor = rows[min((position ?? -1) + 1, rows.count - 1)]
        case .upArrow: cursor = rows[max((position ?? 1) - 1, 0)]
        case .return: if let index = cursor ?? current { onJump(headings[index], true) }
        case .space: if let index = cursor ?? current { onJump(headings[index], false) }
        default: return .ignored
        }
        return .handled
    }
}
