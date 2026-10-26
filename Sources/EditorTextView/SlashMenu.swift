import AppKit
import MarkdownDocument
import PlainCore
import PlainShell
import SwiftUI

/// The `/` menu and the code language list.
@MainActor
final class SlashMenuController {
    /// Where the menu's text starts: the `/`, or the line start when the block handle's `+` opened it.
    var anchor = 0
    /// True when a typed `/` opened the menu, so the query starts one character after `anchor`.
    var slashTyped = false
    var rows: [PageBlockKind] = []
    var highlighted = 0
    var host: NSView?
    /// The language list and the start of the fence line it rewrites.
    var languageHost: NSView?
    var fenceLineStart = 0
}

extension EditorTextView {
    // MARK: The `/` menu

    /// Keys while the `/` menu is open: Up and Down move the highlight, Return inserts, Esc closes keeping the text.
    func slashMenuHandles(_ selector: Selector) -> Bool {
        if slashMenu.languageHost != nil, selector == #selector(NSResponder.cancelOperation(_:)) {
            closeLanguageList()
            return true
        }
        guard slashMenu.host != nil else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            slashMenu.highlighted = max(slashMenu.highlighted - 1, 0)
            showSlashMenu()
        case #selector(NSResponder.moveDown(_:)):
            slashMenu.highlighted = max(min(slashMenu.highlighted + 1, slashMenu.rows.count - 1), 0)
            showSlashMenu()
        case #selector(NSResponder.insertNewline(_:)):
            guard slashMenu.rows.indices.contains(slashMenu.highlighted) else {
                closeMenu()
                return false
            }
            insertSlashKind(slashMenu.rows[slashMenu.highlighted])
        case #selector(NSResponder.cancelOperation(_:)):
            closeMenu()
        default:
            return false
        }
        return true
    }

    /// Opens the menu when a `/` is typed alone on its line; while open, filters the rows by the text after the anchor.
    func slashMenuTextChanged() {
        guard isPage else { return }
        guard slashMenu.host != nil else {
            guard lastTypedCharacter == "/", let caret, caret > 0 else { return }
            let line = lineContents(at: caret)
            guard nsText.substring(with: line) == "/", caret == NSMaxRange(line) else { return }
            closeAutocomplete()
            openMenu(anchor: caret - 1, slashTyped: true)
            return
        }
        let start = slashMenu.anchor + (slashMenu.slashTyped ? 1 : 0)
        // The `/` that opened the menu was deleted: there is no query left to read.
        guard let caret, caret >= start, !slashMenu.slashTyped || character(at: slashMenu.anchor) == 47 else { return closeMenu() }
        let query = nsText.substring(with: NSRange(location: start, length: caret - start))
        slashMenu.rows = filter(items: PageBlockKind.slashKinds, query: query) { $0.title }.map(\.item)
        slashMenu.highlighted = 0
        showSlashMenu()
    }

    /// Closes the menu when the caret leaves the anchor's line after the anchor, or the selection is not one caret.
    func slashMenuSelectionMoved() {
        guard slashMenu.host != nil else { return }
        guard let caret, caret >= slashMenu.anchor, caret <= NSMaxRange(lineContents(at: slashMenu.anchor)) else { return closeMenu() }
    }

    /// Opens the menu on an empty line with no `/` typed (the block handle's `+`).
    func openSlashMenu(atEmptyLine lineStart: Int) {
        openMenu(anchor: lineStart, slashTyped: false)
    }

    /// Closes the `/` menu and the language list.
    func closeSlashMenu() {
        closeMenu()
        closeLanguageList()
    }

    private func openMenu(anchor: Int, slashTyped: Bool) {
        slashMenu.anchor = anchor
        slashMenu.slashTyped = slashTyped
        slashMenu.rows = PageBlockKind.slashKinds
        slashMenu.highlighted = 0
        showSlashMenu()
    }

    private func closeMenu() {
        slashMenu.host?.removeFromSuperview()
        slashMenu.host = nil
        slashMenu.rows = []
    }

    /// Places the menu below the anchor's line when it fits in the visible rect, else above, else on the roomier side
    /// with as many rows as fit.
    private func showSlashMenu() {
        slashMenu.host?.removeFromSuperview()
        let page = Tokens.page
        let line = rect(forCharacterRange: NSRange(location: slashMenu.anchor, length: 0))
        let visible = visibleRect
        let chrome = SlashMenuView.chrome
        var rowCount = min(slashMenu.rows.count, page.slashMaxRows)
        let wanted = slashMenu.rows.isEmpty ? chrome + page.menuRow : chrome + CGFloat(rowCount) * page.slashRow
        let roomBelow = visible.maxY - line.maxY, roomAbove = line.minY - visible.minY
        if !slashMenu.rows.isEmpty, wanted > roomBelow, wanted > roomAbove {
            rowCount = min(rowCount, max(Int((max(roomBelow, roomAbove) - chrome) / page.slashRow), 0))
        }
        let height = slashMenu.rows.isEmpty ? wanted : chrome + CGFloat(rowCount) * page.slashRow
        let view = SlashMenuView(rows: slashMenu.rows, highlighted: slashMenu.highlighted, visibleRows: rowCount) { [weak self] kind in
            self?.insertSlashKind(kind)
        }
        slashMenu.host = showPageTool(view, size: NSSize(width: page.slashWidth, height: height), below: line, above: line)
    }

    /// Writes `kind`'s Markdown in place of the text from the anchor to the caret, as one undo step.
    func insertSlashKind(_ kind: PageBlockKind) {
        guard let caret, caret >= slashMenu.anchor else { return closeMenu() }
        let range = NSRange(location: slashMenu.anchor, length: caret - slashMenu.anchor)
        closeMenu()
        var image: (alt: String, path: String)?
        if kind == .image {
            guard let url = actions.chooseImage() else { return }
            image = (url.deletingPathExtension().lastPathComponent, relativePath(to: url))
        }
        let change = PageBlocks.insert(kind, replacing: range, text: nsText, image: image)
        apply(change.edits, caret: change.caret)
    }

    // MARK: The language list

    /// Opens the list of code languages under the label of the fence line starting at `fenceLineStart`.
    func openLanguageList(fenceLineStart: Int) {
        closeLanguageList()
        let page = Tokens.page
        slashMenu.fenceLineStart = fenceLineStart
        let first = rect(forCharacterRange: NSRange(location: fenceLineStart, length: 0))
        let label = NSRect(x: columnLeft + page.codePadSides, y: first.minY + page.codePadTop, width: 1, height: 18)
        let count = min(LanguageListView.items.count, page.slashMaxRows)
        let size = NSSize(width: page.languageListWidth, height: LanguageListView.chrome + CGFloat(count) * page.menuRow)
        let view = LanguageListView(current: fenceLanguage().id, onPick: { [weak self] id in self?.pickLanguage(id) },
                                    onCancel: { [weak self] in self?.closeLanguageList() })
        slashMenu.languageHost = showPageTool(view, size: size, below: label, above: label)
    }

    /// The fence line's text after its backtick or tilde run, and the language id at its start.
    private func fenceLanguage() -> (range: NSRange, id: String) {
        let line = lineContents(at: slashMenu.fenceLineStart)
        let string = nsText.substring(with: line) as NSString
        var start = 0
        while start < string.length, string.character(at: start) == 32 { start += 1 }
        if start < string.length {
            let fence = string.character(at: start)
            while start < string.length, string.character(at: start) == fence { start += 1 }
        }
        let rest = NSRange(location: line.location + start, length: line.length - start)
        let id = nsText.substring(with: rest).trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? ""
        return (rest, id)
    }

    /// Replaces the fence line's text after the backtick run with `id` (`""` for Plain text), as one undo step.
    func pickLanguage(_ id: String) {
        guard slashMenu.languageHost != nil else { return }
        let range = fenceLanguage().range
        closeLanguageList()
        apply([TextEdit(range: range, replacement: id)], caret: slashMenu.fenceLineStart)
    }

    private func closeLanguageList() {
        guard let host = slashMenu.languageHost else { return }
        slashMenu.languageHost = nil
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: host) ?? false
        host.removeFromSuperview()
        if hadFocus { window?.makeFirstResponder(self) }
    }
}

/// The `/` menu card: a "Blocks" label, then 48 pt rows with a 40 pt icon tile, the block name and a description.
struct SlashMenuView: View {
    /// The card's padding and the "Blocks" label row.
    static let chrome: CGFloat = 8 + 28

    let rows: [PageBlockKind]
    let highlighted: Int
    let visibleRows: Int
    let onPick: (PageBlockKind) -> Void

    var body: some View {
        let page = Tokens.page
        PageMenuCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Blocks")
                    .font(.system(size: page.menuSmall))
                    .foregroundStyle(Color(nsColor: page.textSecondary))
                    .padding(.horizontal, 8)
                    .frame(height: 28, alignment: .leading)
                if rows.isEmpty {
                    Text("No blocks found")
                        .font(.system(size: page.menuLabel))
                        .foregroundStyle(Color(nsColor: page.textSecondary))
                        .padding(.horizontal, 8)
                        .frame(height: page.menuRow, alignment: .leading)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.offset) { index, kind in
                                    row(kind, highlighted: index == highlighted).id(index)
                                }
                            }
                        }
                        .frame(height: CGFloat(visibleRows) * page.slashRow)
                        .onAppear { proxy.scrollTo(highlighted) }
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: page.slashWidth)
    }

    private func row(_ kind: PageBlockKind, highlighted: Bool) -> some View {
        let page = Tokens.page
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: page.handleBoxRadius).fill(Color(nsColor: page.background))
                RoundedRectangle(cornerRadius: page.handleBoxRadius).strokeBorder(Color(nsColor: page.border), lineWidth: 1)
                LucideIcon(name: kind.icon, size: page.handleIcon, colour: Color(nsColor: page.textSecondary))
            }
            .frame(width: page.slashTile, height: page.slashTile)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: page.menuLabel))
                    .foregroundStyle(Color(nsColor: page.text))
                Text(kind.slashDescription)
                    .font(.system(size: page.menuSmall))
                    .foregroundStyle(Color(nsColor: page.textSecondary))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: page.slashRow)
        .background(highlighted ? Color(nsColor: page.hover) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: page.handleBoxRadius))
        .contentShape(Rectangle())
        .onTapGesture { onPick(kind) }
    }
}

/// The code language list: a "Search languages" field, then "Plain text" and every fence language, the current one
/// ticked.
struct LanguageListView: View {
    /// The card's padding and the search field row.
    static let chrome: CGFloat = 8 + 32

    /// "Plain text", then each fence language's display name once, with the first id that has it (`javascript` and
    /// `js` both read "JavaScript"; `javascript` is kept).
    static var items: [(id: String, name: String)] {
        var seen = Set<String>()
        return ([(id: "", name: "Plain text")] + EditorTextView.fenceLanguages.map { (id: $0, name: PageBlocks.languageName($0)) })
            .filter { seen.insert($0.name).inserted }
    }

    let current: String
    let onPick: (String) -> Void
    let onCancel: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let page = Tokens.page
        let currentName = PageBlocks.languageName(current)
        let shown = filter(items: Self.items, query: query) { $0.name }.map(\.item)
        PageMenuCard {
            VStack(spacing: 0) {
                TextField("", text: $query, prompt: Text("Search languages").foregroundStyle(Color(nsColor: page.textTertiary)))
                    .textFieldStyle(.plain)
                    .font(.system(size: page.menuLabel))
                    .foregroundStyle(Color(nsColor: page.text))
                    .focused($focused)
                    .onSubmit { if let first = shown.first { onPick(first.id) } }
                    .onExitCommand { onCancel() }
                    .padding(.horizontal, 8)
                    .frame(height: page.menuRow)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                            PageMenuRow(icon: item.id.isEmpty ? "type" : "code", title: item.name, trailing: item.name == currentName ? .tick : .none)
                                .onTapGesture { onPick(item.id) }
                        }
                    }
                }
            }
            .padding(4)
        }
        .frame(width: page.languageListWidth)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: focused) { _, now in if !now { onCancel() } }
    }
}
