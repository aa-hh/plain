import AppKit
import PlainCore
import SwiftUI

extension Color {
    static let material = Color(nsColor: Tokens.material)
    static let materialTransparent = Color(nsColor: Tokens.materialTransparent)
    static let materialLine = Color(nsColor: Tokens.materialLine)
    static let textColor = Color(nsColor: Tokens.color)
    static let secondaryText = Color(nsColor: Tokens.colorSecondary)
    static let tertiaryText = Color(nsColor: Tokens.colorTertiary)
    static let blueText = Color(nsColor: Tokens.colorBlue)
    static let redText = Color(nsColor: Tokens.colorRed)
    static let selectionBlue = Color(nsColor: Tokens.selectionBlue)
    static let selectionNeutral = Color(nsColor: Tokens.selectionNeutral)
}

/// Popup and sidebar rows: 13 pt UI text on a 24 pt line.
let uiFont = Font.system(size: Tokens.uiFontSize)

/// `text` with the characters at `indexes` (Character offsets) underlined, as popups mark typed letters.
func underlined(_ text: String, indexes: [Int], offset: Int = 0) -> AttributedString {
    var result = AttributedString()
    for (i, character) in text.enumerated() {
        var piece = AttributedString(String(character))
        if indexes.contains(i + offset) { piece.underlineStyle = .single }
        result += piece
    }
    return result
}

/// A shortcut as the Commands popup shows it, one symbol per space-separated part: `⇧ ⌘ S`.
func spacedSymbols(_ shortcut: Shortcut) -> String {
    shortcut.symbols.map(String.init).joined(separator: " ")
}

/// Two spread-only rings behind a card, as `Tokens` describes the popup shadow.
struct RingShadow: ViewModifier {
    var small = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let palette = Tokens.palette(dark: scheme == .dark)
        let rings = small ? palette.shadowSmall : palette.shadow
        return content.background {
            ZStack {
                ForEach(Array(rings.enumerated().reversed()), id: \.offset) { _, ring in
                    RoundedRectangle(cornerRadius: Tokens.cornerRadius + ring.width)
                        .fill(Color(nsColor: ring.color))
                        .padding(-ring.width)
                }
            }
        }
    }
}

/// The shared popup: 360 pt card, 72 pt filter header, up to 16 rows of 24 pt, 12 pt under the last row.
/// Rows are addressed by index; the caller draws each row and decides what a pick does.
public struct PopupCard<Row: View>: View {
    let placeholder: String
    /// Nil shows the placeholder as a fixed title instead of a field (the Tabs switcher).
    let filter: Binding<String>?
    @Binding var selection: Int
    let rowCount: Int
    /// Index of the row followed by a divider line.
    let dividerAfter: Int?
    /// Shown as a disabled row when there are no rows and the filter is not empty (or there is no filter).
    let emptyText: String
    let onPick: (Int) -> Void
    let onCancel: () -> Void
    let row: (Int) -> Row

    @FocusState private var fieldFocused: Bool
    @Environment(\.controlActiveState) private var activeState

    public init(
        placeholder: String, filter: Binding<String>?, selection: Binding<Int>, rowCount: Int,
        dividerAfter: Int? = nil, emptyText: String = "not found",
        onPick: @escaping (Int) -> Void, onCancel: @escaping () -> Void, @ViewBuilder row: @escaping (Int) -> Row
    ) {
        self.placeholder = placeholder
        self.filter = filter
        self._selection = selection
        self.rowCount = rowCount
        self.dividerAfter = dividerAfter
        self.emptyText = emptyText
        self.onPick = onPick
        self.onCancel = onCancel
        self.row = row
    }

    private var showsEmptyRow: Bool {
        rowCount == 0 && (filter.map { !$0.wrappedValue.isEmpty } ?? true)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if rowCount > 0 {
                list
            } else if showsEmptyRow {
                Text(emptyText)
                    .font(uiFont)
                    .foregroundStyle(Color.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: Tokens.line, maxHeight: Tokens.line, alignment: .leading)
                    .padding(.horizontal, Tokens.rowPadding)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: Tokens.popupWidth)
        .background(Color.material, in: RoundedRectangle(cornerRadius: Tokens.cornerRadius))
        .modifier(RingShadow())
        .onAppear { fieldFocused = true }
        .onChange(of: fieldFocused) { _, focused in if !focused && filter != nil { onCancel() } }
        .onChange(of: activeState) { _, state in if state == .inactive { onCancel() } }
    }

    @ViewBuilder private var header: some View {
        Group {
            if let filter {
                TextField(
                    "", text: filter,
                    prompt: Text(placeholder).foregroundStyle(Color.tertiaryText)
                )
                .textFieldStyle(.plain)
                .foregroundStyle(Color.textColor)
                .focused($fieldFocused)
                .onKeyPress(phases: .down) { handle($0) }
                .onChange(of: filter.wrappedValue) { selection = 0 }
            } else {
                Text(placeholder).foregroundStyle(Color.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: Tokens.popupFilterFontSize, weight: .light))
        .padding(.horizontal, Tokens.rowPadding)
        .frame(height: Tokens.popupFilterLineHeight)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<rowCount, id: \.self) { index in
                        row(index)
                            .font(uiFont)
                            .foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: Tokens.line, maxHeight: Tokens.line, alignment: .leading)
                            .padding(.horizontal, Tokens.rowPadding)
                            .background(index == selection ? selectedColor : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = index; onPick(index) }
                            .id(index)
                        if index == dividerAfter {
                            Rectangle().fill(Color.materialLine).frame(height: 1)
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(rowCount), 16) * Tokens.line + (dividerAfter == nil ? 0 : 1))
            .padding(.bottom, 12)
            .onChange(of: selection) { _, index in proxy.scrollTo(index) }
        }
    }

    private var selectedColor: Color {
        activeState == .inactive ? .selectionNeutral : .selectionBlue
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let ctrl = press.modifiers.contains(.control)
        switch press.key {
        case .downArrow: move(1)
        case .upArrow: move(-1)
        case KeyEquivalent("n") where ctrl: move(1)
        case KeyEquivalent("p") where ctrl: move(-1)
        case .return, .rightArrow:
            guard rowCount > 0 else { return .handled }
            onPick(selection)
        case .escape: onCancel()
        default: return .ignored
        }
        return .handled
    }

    private func move(_ step: Int) {
        guard rowCount > 0 else { return }
        selection = min(max(selection + step, 0), rowCount - 1)
    }
}

/// The match an empty query gives: no indexes, score 0.
let emptyMatch = fuzzyMatch(query: "", in: "")!
