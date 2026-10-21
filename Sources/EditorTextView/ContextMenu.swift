import AppKit
import MarkdownDocument
import PlainCore

/// One context menu row: its title, the letters drawn red (spelling corrections) and what it does.
struct ContextItem {
    var title: String
    var red: [Int] = []
    var action: () -> Void
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func fire() { run() }
}

/// The context menu: right-click (native menu) or Ctrl+Space / Alt+Enter (the in-editor card) (spec 197–212).
extension EditorTextView {
    public override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: point)
        let inside = allSelections.contains { $0.length > 0 && NSLocationInRange(offset, $0) }
        if !inside { setSelectedRange(wordRange(at: offset)) }
        Task { [weak self] in
            guard let self else { return }
            let items = await self.contextItems(at: offset)
            let menu = NSMenu()
            for item in items {
                let menuItem = ClosureMenuItem(title: item.title, run: item.action)
                if !item.red.isEmpty { menuItem.attributedTitle = Self.redTitle(item) }
                menu.addItem(menuItem)
            }
            if !items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    private static func redTitle(_ item: ContextItem) -> NSAttributedString {
        let title = NSMutableAttributedString(string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        let characters = Array(item.title)
        var offset = 0
        for (index, c) in characters.enumerated() {
            let length = String(c).utf16.count
            if item.red.contains(index) { title.addAttribute(.foregroundColor, value: Tokens.colorRed, range: NSRange(location: offset, length: length)) }
            offset += length
        }
        return title
    }

    /// Ctrl+Space or Alt+Enter with no suggestions: the same items in the autocomplete card at the caret.
    func showContextMenuAtCaret() {
        guard let offset = allSelections.first?.location else { return }
        Task { [weak self] in
            guard let self else { return }
            let items = await self.contextItems(at: offset)
            guard !items.isEmpty else { return }
            let suggestions = items.map { Suggestion(title: $0.title, icon: nil, insert: "", matched: [], red: $0.red, action: $0.action) }
            self.showSuggestions(AutocompleteSession(fragment: NSRange(location: self.selectedRange().location, length: 0), suggestions: suggestions))
        }
    }

    // MARK: Items

    func contextItems(at offset: Int) async -> [ContextItem] {
        var items: [ContextItem] = []
        items += await spellingItems(at: offset)
        items += linkItems(at: offset)
        items += listItems(at: offset)
        items += tocItems(at: offset)
        items += emojiItems(at: offset)
        items += searchItems()
        return items
    }

    /// Up to 4 corrections with the differing letters red, then "Add to Dictionary" (spec 202, 322).
    private func spellingItems(at offset: Int) async -> [ContextItem] {
        guard let spellcheck, let range = spellcheck.misspellings.first(where: { NSLocationInRange(offset, $0) || NSMaxRange($0) == offset }) else { return [] }
        let word = nsText.substring(with: range)
        let corrections = await spellcheck.corrections(for: range)
        var items = corrections.map { correction -> ContextItem in
            let wordCharacters = Array(word.lowercased())
            let red = Array(correction.lowercased()).enumerated().filter { $0.offset >= wordCharacters.count || wordCharacters[$0.offset] != $0.element }.map(\.offset)
            return ContextItem(title: correction, red: red) { [weak self] in
                guard let self, self.nsText.length >= NSMaxRange(range), self.nsText.substring(with: range) == word else { return }
                self.perform(range, correction, caret: range.location + (correction as NSString).length)
            }
        }
        items.append(ContextItem(title: "Add to Dictionary") { Task { await spellcheck.learn(word: word) } })
        return items
    }

    private func linkItems(at offset: Int) -> [ContextItem] {
        guard let link = linkTarget(at: offset) else { return [] }
        var items: [ContextItem] = []
        switch link.target {
        case .anchor(let slug):
            items.append(ContextItem(title: "Go to Heading") { [weak self] in self?.goToAnchor(slug) })
        case .web(let url):
            let text = url.absoluteString
            let title = link.isReference ? "Visit " + (text.count > 40 ? String(text.prefix(40)) + "..." : text) : "Visit Link"
            items.append(ContextItem(title: title) { [weak self] in self?.actions.visitURL(url) })
        case .file(let url):
            if FileManager.default.fileExists(atPath: url.path) {
                if OpenableFiles.isOpenable(url) {
                    let title = link.isReference ? "Open " + url.lastPathComponent : "Open File"
                    items.append(ContextItem(title: title) { [weak self] in self?.actions.openPath(url) })
                }
                items.append(ContextItem(title: "Show in Finder") { [weak self] in self?.actions.revealInFinder(url) })
                if let folder = actions.folderURL(), url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") {
                    items.append(ContextItem(title: "Show in Sidebar") { [weak self] in self?.actions.showInSidebar(url) })
                }
            } else {
                items.append(ContextItem(title: "Create File") { [weak self] in self?.actions.createFile(url) })
            }
        }
        if let definition = link.definition {
            items.append(ContextItem(title: "Go to Definition") { [weak self] in self?.setSelectedRange(definition); self?.scrollRangeToVisible(definition) })
        }
        switch link.inline.kind {
        case .referenceLink, .referenceImage:
            items.append(ContextItem(title: "Convert to Inline") { [weak self] in self?.convertToInline(link) })
        default:
            break
        }
        return items
    }

    private func listItems(at offset: Int) -> [ContextItem] {
        guard let block = snapshot?.deepestBlock(at: offset) else { return [] }
        let item: Block?
        if case .listItem = block.kind { item = block } else {
            item = snapshot?.blocks(where: {
                if case .listItem = $0.kind { return NSLocationInRange(offset, $0.range) || NSMaxRange($0.range) == offset }
                return false
            }).last
        }
        guard let item, case .listItem(let task, let checked) = item.kind else { return [] }
        var items: [ContextItem] = []
        if task == true {
            items.append(ContextItem(title: checked ? "Uncheck Item" : "Check Item") { [weak self] in self?.toggleTask(at: item.range.location) })
        }
        items.append(ContextItem(title: "Convert to OL") { [weak self] in self?.convertList(at: offset, to: .ordered) })
        items.append(ContextItem(title: "Convert to UL") { [weak self] in self?.convertList(at: offset, to: .bullet) })
        items.append(ContextItem(title: "Convert to Task List") { [weak self] in self?.convertList(at: offset, to: .task) })
        return items
    }

    /// `[[toc]]` → "Convert to List": nested links to every heading, two spaces per level used (spec 206).
    private func tocItems(at offset: Int) -> [ContextItem] {
        guard let snapshot, let block = snapshot.block(at: offset), block.kind == .toc else { return [] }
        return [ContextItem(title: "Convert to List") { [weak self] in
            guard let self, let snapshot = self.snapshot else { return }
            let levels = Array(Set(snapshot.headings.map(\.level))).sorted()
            let lines = snapshot.headings.map { heading -> String in
                let depth = levels.firstIndex(of: heading.level) ?? 0
                return String(repeating: "  ", count: depth) + "- [" + heading.text + "](#" + heading.slug + ")"
            }
            let list = lines.joined(separator: "\n")
            self.perform(block.range, list, caret: block.range.location + (list as NSString).length)
        }]
    }

    /// "Convert to Text" for an emoji character next to the caret; "Convert to Unicode" for a shortcode (spec 207).
    private func emojiItems(at offset: Int) -> [ContextItem] {
        if let inline = inlines(at: offset).last, case .emoji(_, let character) = inline.kind {
            return [ContextItem(title: "Convert to Unicode") { [weak self] in
                self?.perform(inline.range, character, caret: inline.range.location + (character as NSString).length)
            }]
        }
        for range in [composedRange(endingAt: offset), composedRange(startingAt: offset)].compactMap({ $0 }) {
            let text = nsText.substring(with: range)
            if let name = EmojiTable.shared.shortcode(for: text) {
                return [ContextItem(title: "Convert to Text") { [weak self] in
                    self?.perform(range, ":" + name + ":", caret: range.location + name.utf16.count + 2)
                }]
            }
        }
        return []
    }

    private func composedRange(endingAt offset: Int) -> NSRange? {
        guard offset > 0 else { return nil }
        return nsText.rangeOfComposedCharacterSequence(at: offset - 1)
    }

    private func composedRange(startingAt offset: Int) -> NSRange? {
        guard offset < nsText.length else { return nil }
        return nsText.rangeOfComposedCharacterSequence(at: offset)
    }

    /// `Search for "…"` for a single-line selection that is not a URL, cut to about 47 characters (spec 208).
    private func searchItems() -> [ContextItem] {
        guard let range = singleSelection, range.length > 0 else { return [] }
        let text = nsText.substring(with: range).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains("\n"), !Self.isURL(text) else { return [] }
        var shown = text
        if shown.count > 47 {
            shown = String(shown.prefix(47))
            if let space = shown.lastIndex(of: " ") { shown = String(shown[..<space]) }
            shown += "…"
        }
        return [ContextItem(title: "Search for \u{201C}" + shown + "\u{201D}") { [weak self] in self?.actions.searchWeb(text) }]
    }

    private func convertToInline(_ link: LinkAtCaret) {
        guard let destination = link.destination else { return }
        let content = nsText.substring(with: link.inline.contentRange)
        var opener = "["
        if case .referenceImage = link.inline.kind { opener = "![" }
        let result = opener + content + "](" + destination + ")"
        perform(link.inline.range, result, caret: link.inline.range.location + (result as NSString).length)
    }
}
