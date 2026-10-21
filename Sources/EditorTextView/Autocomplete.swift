import AppKit
import MarkdownDocument
import PlainCore

/// A file or folder offered while typing a path.
public struct PathCompletion: Equatable, Sendable {
    public var name: String
    public var isFolder: Bool
    public init(name: String, isFolder: Bool) {
        self.name = name
        self.isFolder = isFolder
    }
}

extension EditorActions {
    /// Lists the folder a typed path points into (spec 187): `./`, `../` and plain names are relative to the
    /// document's folder, `/` to `root`, `~/` to the home folder. Hidden files only when the typed part starts with `.`;
    /// case-insensitive unless it has a capital; junk files skipped.
    public static func listPath(_ typed: String, documentURL: URL?, root: URL?) -> [PathCompletion] {
        let decoded = typed.removingPercentEncoding ?? typed
        let partial = decoded.hasSuffix("/") ? "" : (decoded as NSString).lastPathComponent
        let folderPart = decoded.hasSuffix("/") ? decoded : (decoded as NSString).deletingLastPathComponent
        let base: URL?
        var relative = folderPart
        if decoded.hasPrefix("~/") {
            base = FileManager.default.homeDirectoryForCurrentUser
            relative = String(folderPart.dropFirst(2))
        } else if decoded.hasPrefix("/") {
            base = root
            relative = String(folderPart.dropFirst())
        } else {
            base = documentURL?.deletingLastPathComponent()
        }
        guard let base else { return [] }
        let folder = relative.isEmpty ? base : base.appendingPathComponent(relative, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let caseSensitive = partial.contains { $0.isUppercase }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            if OpenableFiles.junkNames.contains(name) { return nil }
            if name.hasPrefix("."), !partial.hasPrefix(".") { return nil }
            let matches = caseSensitive ? name.hasPrefix(partial) : name.lowercased().hasPrefix(partial.lowercased())
            guard matches else { return nil }
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isFolder)
            return PathCompletion(name: name, isFolder: isFolder.boolValue)
        }
    }
}

struct Suggestion {
    var title: String
    var icon: String?
    /// Text that replaces the typed fragment.
    var insert: String
    /// Character offsets in `title` to underline.
    var matched: [Int]
    /// Caret position after accepting, counted from the start of `insert`; nil puts it at the end.
    var caretOffset: Int?
    /// Ask for suggestions again after accepting (folders, CSS property names).
    var reask = false
    /// An emoji to record as recently used.
    var emoji: String?
    /// Character offsets in `title` drawn in `--color-red` (spelling corrections, spec 1598).
    var red: [Int] = []
    /// For context menu rows: runs instead of inserting text.
    var action: (() -> Void)?
}

struct AutocompleteSession {
    /// The typed fragment the suggestions replace, at the primary caret.
    var fragment: NSRange
    var suggestions: [Suggestion]
    var selected = 0
}

/// Autocomplete (spec 178–195, 1593–1597).
extension EditorTextView {
    static let fenceLanguages = ["aspnet", "bash", "batch", "basic", "c", "cpp", "csharp", "css", "coffeescript", "dart", "docker", "elixir",
                                 "erlang", "fortran", "fsharp", "git", "go", "groovy", "handlebars", "haskell", "html", "http", "java",
                                 "javascript", "js", "json", "latex", "less", "lua", "makefile", "markdown", "matlab", "mathml", "mermaid",
                                 "nginx", "objectivec", "ocaml", "oz", "pascal", "perl", "php", "powershell", "prolog", "python", "ruby",
                                 "rust", "scala", "scss", "smalltalk", "sql", "svg", "swift", "typescript", "xml", "yaml"]

    /// Plain's table of 30 non-void HTML tags with their own attributes.
    static let htmlTags: [String: [String]] = [
        "a": ["href", "target", "rel", "download"], "b": [], "blockquote": ["cite"], "code": [], "del": ["cite", "datetime"],
        "details": ["open"], "div": [], "em": [], "h1": [], "h2": [], "i": [], "kbd": [], "li": ["value"], "mark": [],
        "ol": ["start", "reversed", "type"], "p": [], "pre": [], "s": [], "small": [], "span": [], "strong": [], "sub": [],
        "summary": [], "sup": [], "table": [], "td": ["colspan", "rowspan", "headers"], "th": ["colspan", "rowspan", "headers", "scope"],
        "tr": [], "u": [], "ul": [],
    ]
    static let globalAttributes = ["class", "id", "style", "title", "lang", "dir", "hidden"]

    static let cssProperties = [
        "align-items", "animation", "background", "background-color", "background-image", "background-position", "background-repeat",
        "background-size", "border", "border-bottom", "border-color", "border-left", "border-radius", "border-right", "border-style",
        "border-top", "border-width", "bottom", "box-shadow", "box-sizing", "clear", "color", "content", "cursor", "display", "flex",
        "flex-direction", "flex-wrap", "float", "font", "font-family", "font-size", "font-style", "font-weight", "gap", "grid",
        "grid-template-columns", "height", "justify-content", "left", "letter-spacing", "line-height", "list-style", "margin",
        "margin-bottom", "margin-left", "margin-right", "margin-top", "max-width", "min-height", "opacity", "outline", "overflow",
        "padding", "position", "right", "text-align", "text-decoration", "top", "transition",
    ]
    static let cssValues = ["auto", "block", "bold", "center", "flex", "grid", "hidden", "inherit", "initial", "inline", "inline-block",
                            "none", "normal", "relative", "absolute", "fixed", "solid", "transparent"]
    static let javaScriptKeywords = ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
                                     "delete", "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import",
                                     "in", "instanceof", "let", "new", "null", "return", "static", "super", "switch", "this", "throw",
                                     "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield"]

    // MARK: Asking

    func autocompleteAfterTyping() {
        guard helperDepth == 0, let offset = caret else { return closeAutocomplete() }
        if lastTypedCharacter == ">", closeHTMLTag(at: offset) { return closeAutocomplete() }
        if let character = lastTypedCharacter, String(character).unicodeScalars.first?.properties.isEmojiPresentation == true {
            recordEmoji(String(character))
        }
        showSuggestions(suggestions(at: offset))
    }

    /// Ctrl+Space or Alt+Enter: ask for suggestions; open the context menu when there are none (spec 181).
    func askForSuggestions() {
        guard let offset = caret ?? allSelections.first?.location else { return }
        if let found = suggestions(at: offset), !found.suggestions.isEmpty {
            showSuggestions(found)
        } else {
            showContextMenuAtCaret()
        }
    }

    func suggestions(at offset: Int) -> AutocompleteSession? {
        let line = lineContents(at: offset)
        let before = nsText.substring(with: NSRange(location: line.location, length: offset - line.location))
        if isMarkdownFile {
            if let session = emojiSuggestions(before: before, offset: offset) { return session }
            if let session = linkSuggestions(before: before, offset: offset) { return session }
            if let session = fenceSuggestions(before: before, offset: offset) { return session }
            if let session = attributeSuggestions(before: before, offset: offset) { return session }
            return nil
        }
        switch document.fileExtension.lowercased() {
        case "css", "scss", "less": return cssSuggestions(before: before, offset: offset)
        case "js", "jsx", "es6", "javascript": return javaScriptSuggestions(before: before, offset: offset)
        default: return nil
        }
    }

    private func session(_ fragmentLength: Int, at offset: Int, _ suggestions: [Suggestion]) -> AutocompleteSession? {
        let typed = nsText.substring(with: NSRange(location: offset - fragmentLength, length: fragmentLength))
        let list = Array(suggestions.prefix(6))
        guard !list.isEmpty, !(list.count == 1 && list[0].insert == typed) else { return nil }
        return AutocompleteSession(fragment: NSRange(location: offset - fragmentLength, length: fragmentLength), suggestions: list)
    }

    // MARK: Emoji (spec 186)

    private func emojiSuggestions(before: String, offset: Int) -> AutocompleteSession? {
        guard let colon = before.lastIndex(of: ":") else { return nil }
        let query = String(before[before.index(after: colon)...])
        guard !query.isEmpty, query.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" }) else { return nil }
        if colon > before.startIndex {
            let previous = before[before.index(before: colon)]
            if previous.isLetter || previous.isNumber { return nil }
        }
        if isInCodeOrMath(offset) { return nil }
        let table = EmojiTable.shared
        var seen = Set<String>()
        var results: [(suggestion: Suggestion, rank: Int, score: Int)] = []
        func add(_ entry: EmojiEntry, rank: Int) {
            guard !seen.contains(entry.emoji), let name = entry.aliases.first else { return }
            let match = entry.aliases.compactMap { alias in fuzzyMatch(query: query, in: alias).map { (alias, $0) } }.max { $0.1.score < $1.1.score }
            seen.insert(entry.emoji)
            results.append((Suggestion(title: match?.0 ?? name, icon: entry.emoji, insert: entry.emoji, matched: match?.1.indexes ?? [],
                                       emoji: entry.emoji), rank, match?.1.score ?? 0))
        }
        for emoji in recentEmoji {
            if let entry = table.entries.first(where: { $0.emoji == emoji }), entry.aliases.contains(where: { fuzzyMatch(query: query, in: $0) != nil }) {
                add(entry, rank: 0)
            }
        }
        for entry in table.entries where entry.aliases.contains(query.lowercased()) { add(entry, rank: 1) }
        for entry in table.entries where entry.aliases.contains(where: { fuzzyMatch(query: query, in: $0) != nil }) { add(entry, rank: 2) }
        for entry in table.search(prefix: query) { add(entry, rank: 3) }
        let sorted = results.enumerated().sorted {
            let a = $0.element, b = $1.element
            if a.rank != b.rank { return a.rank < b.rank }
            if a.score != b.score { return a.score > b.score }
            return $0.offset < $1.offset
        }.map(\.element.suggestion)
        let fragment = (String(before[colon...]) as NSString).length
        let spaceFollows = character(at: offset) == 32
        let list = sorted.map { suggestion -> Suggestion in
            var copy = suggestion
            if !spaceFollows { copy.insert += " " }
            return copy
        }
        return session(fragment, at: offset, list)
    }

    func recordEmoji(_ emoji: String) {
        recentEmoji.removeAll { $0 == emoji }
        recentEmoji.insert(emoji, at: 0)
        actions.recordEmoji(emoji)
    }

    // MARK: Paths and anchors (spec 187–188)

    private func linkSuggestions(before: String, offset: Int) -> AutocompleteSession? {
        let typed: String
        if let match = before.range(of: #"\]\([^)\s]*$"#, options: .regularExpression) {
            typed = String(before[match].dropFirst(2))
        } else if let match = before.range(of: #"(src|href)="[^"]*$"#, options: .regularExpression) {
            let text = String(before[match])
            typed = String(text[text.index(after: text.firstIndex(of: "\"")!)...])
        } else {
            return nil
        }
        let fragmentLength = (typed as NSString).length
        if typed.hasPrefix("#") {
            let query = String(typed.dropFirst())
            let list = filter(items: snapshot?.headings ?? [], query: query) { $0.slug }.map {
                Suggestion(title: $0.item.slug, icon: nil, insert: "#" + $0.item.slug, matched: $0.match.indexes)
            }
            return session(fragmentLength, at: offset, list)
        }
        guard typed.hasPrefix("./") || typed.hasPrefix("../") || typed.hasPrefix("/") || typed.hasPrefix("~/") else { return nil }
        let folderPart = typed.hasSuffix("/") ? typed : (typed as NSString).deletingLastPathComponent + "/"
        let partial = typed.hasSuffix("/") ? "" : (typed as NSString).lastPathComponent
        let list = actions.completePath(typed, document.url).map { entry -> Suggestion in
            let encoded = entry.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.name
            return Suggestion(title: entry.name + (entry.isFolder ? "/" : ""), icon: nil, insert: folderPart + encoded + (entry.isFolder ? "/" : ""),
                              matched: Array(0..<min(partial.count, entry.name.count)), reask: entry.isFolder)
        }
        return session(fragmentLength, at: offset, list)
    }

    // MARK: Fence languages (spec 189)

    private func fenceSuggestions(before: String, offset: Int) -> AutocompleteSession? {
        guard let match = before.range(of: #"^\s{0,3}(`{3,}|~{3,})[A-Za-z0-9+#-]*$"#, options: .regularExpression) else { return nil }
        let query = String(String(before[match]).drop { $0 == " " || $0 == "`" || $0 == "~" })
        guard !query.isEmpty else { return nil }
        let list = filter(items: Self.fenceLanguages, query: query) { $0 }.map {
            Suggestion(title: $0.item, icon: nil, insert: $0.item, matched: $0.match.indexes)
        }
        return session((query as NSString).length, at: offset, list)
    }

    // MARK: HTML (spec 190)

    /// Typing `>` after an opening tag of a known non-void tag inserts its closing tag after the caret.
    private func closeHTMLTag(at offset: Int) -> Bool {
        guard isMarkdownFile else { return false }
        let line = lineContents(at: offset)
        let before = nsText.substring(with: NSRange(location: line.location, length: offset - line.location))
        guard let match = before.range(of: #"<[a-zA-Z][a-zA-Z0-9]*(\s[^<>]*)?>$"#, options: .regularExpression),
              !before[match].hasSuffix("/>") else { return false }
        let tag = String(before[match].dropFirst().prefix { $0.isLetter || $0.isNumber }).lowercased()
        guard Self.htmlTags[tag] != nil else { return false }
        let closing = "</" + tag + ">"
        if nsText.substring(from: offset).hasPrefix(closing) { return false }
        perform(NSRange(location: offset, length: 0), closing, caret: offset)
        return true
    }

    private func attributeSuggestions(before: String, offset: Int) -> AutocompleteSession? {
        guard let match = before.range(of: #"<[a-zA-Z][a-zA-Z0-9]*(\s+[a-zA-Z-]+(="[^"]*")?)*\s+[a-zA-Z-]*$"#, options: .regularExpression) else { return nil }
        let text = String(before[match])
        let tag = String(text.dropFirst().prefix { $0.isLetter || $0.isNumber }).lowercased()
        guard let own = Self.htmlTags[tag] else { return nil }
        let query = String(text.reversed().prefix { $0.isLetter || $0 == "-" }.reversed())
        let list = filter(items: own + Self.globalAttributes, query: query) { $0 }.map {
            Suggestion(title: $0.item, icon: nil, insert: $0.item + "=\"\"", matched: $0.match.indexes, caretOffset: ($0.item as NSString).length + 2)
        }
        return session((query as NSString).length, at: offset, list)
    }

    // MARK: CSS and JavaScript files (spec 191)

    private func cssSuggestions(before: String, offset: Int) -> AutocompleteSession? {
        if before.range(of: #"^\s+[a-z-]+:\s*[a-z-]*$"#, options: .regularExpression) != nil {
            let query = String(before.reversed().prefix { $0.isLetter || $0 == "-" }.reversed())
            let list = Self.cssValues.filter { $0.hasPrefix(query) }.map {
                Suggestion(title: $0, icon: nil, insert: $0 + ";", matched: Array(0..<query.count))
            }
            return session((query as NSString).length, at: offset, list)
        }
        guard before.range(of: #"^\s+[a-z-]+$"#, options: .regularExpression) != nil else { return nil }
        let query = before.trimmingCharacters(in: .whitespaces)
        let list = filter(items: Self.cssProperties, query: query) { $0 }.map {
            Suggestion(title: $0.item, icon: nil, insert: $0.item + ": ", matched: $0.match.indexes, reask: true)
        }
        return session((query as NSString).length, at: offset, list)
    }

    private func javaScriptSuggestions(before: String, offset: Int) -> AutocompleteSession? {
        let query = String(before.reversed().prefix { $0.isLetter }.reversed())
        guard !query.isEmpty else { return nil }
        let list = Self.javaScriptKeywords.filter {
            $0.count > 4 && $0.hasPrefix(query) && Self.jaroWinkler(query, $0) >= 0.85
        }.map { Suggestion(title: $0, icon: nil, insert: $0, matched: Array(0..<query.count)) }
        return session((query as NSString).length, at: offset, list)
    }

    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let s = Array(a), t = Array(b)
        guard !s.isEmpty, !t.isEmpty else { return 0 }
        let window = max(max(s.count, t.count) / 2 - 1, 0)
        var sMatched = Array(repeating: false, count: s.count), tMatched = Array(repeating: false, count: t.count)
        var matches = 0
        for i in s.indices {
            for j in max(0, i - window)..<min(t.count, i + window + 1) where !tMatched[j] && s[i] == t[j] {
                sMatched[i] = true
                tMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0, k = 0
        for i in s.indices where sMatched[i] {
            while !tMatched[k] { k += 1 }
            if s[i] != t[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        let jaro = (m / Double(s.count) + m / Double(t.count) + (m - Double(transpositions) / 2) / m) / 3
        let prefix = Double(min(4, zip(s, t).prefix { $0 == $1 }.count))
        return jaro + prefix * 0.1 * (1 - jaro)
    }

    // MARK: Popup

    func showSuggestions(_ found: AutocompleteSession?) {
        guard let found, !found.suggestions.isEmpty else { return closeAutocomplete() }
        autocomplete = found
        let popup = autocompletePopup ?? AutocompletePopup()
        if popup.superview == nil { addSubview(popup) }
        autocompletePopup = popup
        popup.suggestions = found.suggestions
        popup.selected = found.selected
        let caretRect = rect(forCharacterRange: NSRange(location: found.fragment.location, length: 0))
        let size = popup.fittingSize
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        var y = caretRect.maxY - AutocompletePopup.ringWidth
        popup.reversed = false
        if y + size.height > visible.maxY, caretRect.minY - size.height >= visible.minY {
            y = caretRect.minY - size.height + AutocompletePopup.ringWidth
            popup.reversed = true
        }
        popup.frame = NSRect(x: caretRect.minX - 15 - AutocompletePopup.ringWidth, y: y, width: size.width, height: size.height)
        popup.needsDisplay = true
    }

    func closeAutocomplete() {
        autocomplete = nil
        autocompletePopup?.removeFromSuperview()
    }

    func moveAutocompleteSelection(by step: Int) {
        guard var session = autocomplete else { return }
        let count = session.suggestions.count
        session.selected = (session.selected + step + count) % count
        autocomplete = session
        autocompletePopup?.selected = session.selected
        autocompletePopup?.needsDisplay = true
    }

    /// Enter or Tab while the list is open accepts the selected suggestion at every caret (spec 183–184).
    func autocompleteAccept() -> Bool {
        guard let session = autocomplete, session.suggestions.indices.contains(session.selected) else { return false }
        let suggestion = session.suggestions[session.selected]
        closeAutocomplete()
        if let action = suggestion.action {
            action()
            return true
        }
        let length = session.fragment.length
        var edits: [(range: NSRange, text: String)] = []
        var carets: [NSRange] = []
        var shift = 0
        let insertLength = (suggestion.insert as NSString).length
        for range in allSelections.sorted(by: { $0.location < $1.location }) {
            let start = max(range.location - length, 0)
            edits.append((NSRange(location: start, length: range.location - start), suggestion.insert))
            carets.append(NSRange(location: start + shift + (suggestion.caretOffset ?? insertLength), length: 0))
            shift += insertLength - (range.location - start)
        }
        perform(edits, select: carets)
        if let emoji = suggestion.emoji { recordEmoji(emoji) }
        if suggestion.reask, let offset = caret { showSuggestions(suggestions(at: offset)) }
        return true
    }

    /// Keys while the list is open (spec 183). Returns true when the key was used.
    func autocompleteCommand(_ selector: Selector) -> Bool {
        guard autocomplete != nil else { return false }
        switch selector {
        case #selector(moveDown(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            moveAutocompleteSelection(by: autocompletePopup?.reversed == true ? -1 : 1)
        case #selector(moveUp(_:)):
            moveAutocompleteSelection(by: autocompletePopup?.reversed == true ? 1 : -1)
        case #selector(cancelOperation(_:)), #selector(complete(_:)):
            closeAutocomplete()
        default:
            return false
        }
        return true
    }
}

/// The autocomplete card: up to 6 rows of 26 pt, 14 pt text, the typed part underlined (spec 182, 1593–1597).
final class AutocompletePopup: NSView {
    /// Room for the 1 + 5 pt rings around the card.
    static let ringWidth: CGFloat = 6
    var suggestions: [Suggestion] = []
    var selected = 0
    var reversed = false

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let font = Tokens.menuRowFont
        let width = suggestions.map { suggestion -> CGFloat in
            let icon = suggestion.icon.map { 14 + NSAttributedString(string: $0, attributes: [.font: font]).size().width } ?? 0
            return icon + NSAttributedString(string: suggestion.title, attributes: [.font: font]).size().width
        }.max() ?? 0
        return NSSize(width: ceil(width) + 40 + Self.ringWidth * 2,
                      height: CGFloat(suggestions.count) * Tokens.menuRowLineHeight + 24 + Self.ringWidth * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Tokens.palette(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let card = bounds.insetBy(dx: Self.ringWidth, dy: Self.ringWidth)
        drawCard(card, palette: palette)
        let font = Tokens.menuRowFont
        let rows = reversed ? Array(suggestions.enumerated().reversed()) : Array(suggestions.enumerated())
        for (row, item) in rows.enumerated() {
            let rowRect = NSRect(x: card.minX, y: card.minY + 12 + CGFloat(row) * Tokens.menuRowLineHeight,
                                 width: card.width, height: Tokens.menuRowLineHeight)
            if item.offset == selected {
                palette.selectionBlue.setFill()
                rowRect.fill(using: .sourceOver)
            }
            var x = rowRect.minX + 20
            if let icon = item.element.icon {
                let string = NSAttributedString(string: icon, attributes: [.font: font])
                string.draw(at: NSPoint(x: x, y: rowRect.minY + (rowRect.height - string.size().height) / 2))
                x += string.size().width + 14
            }
            let title = NSMutableAttributedString(string: item.element.title, attributes: [.font: font, .foregroundColor: palette.color])
            let characters = Array(item.element.title)
            var offsets: [Int] = []
            var utf16 = 0
            for c in characters {
                offsets.append(utf16)
                utf16 += String(c).utf16.count
            }
            for index in item.element.red where index < characters.count {
                title.addAttribute(.foregroundColor, value: palette.colorRed,
                                   range: NSRange(location: offsets[index], length: String(characters[index]).utf16.count))
            }
            for index in item.element.matched where index < characters.count {
                title.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                   range: NSRange(location: offsets[index], length: String(characters[index]).utf16.count))
            }
            title.draw(at: NSPoint(x: x, y: rowRect.minY + (rowRect.height - title.size().height) / 2))
        }
    }
}

extension NSView {
    /// A popup card: `--material` background, radius 6, and spread-only rings around it (spec 1311–1313).
    func drawCard(_ card: NSRect, palette: Palette, small: Bool = true) {
        var inner = card
        for ring in (small ? palette.shadowSmall : palette.shadow) {
            let outer = inner.insetBy(dx: -ring.width, dy: -ring.width)
            let grow = (outer.width - card.width) / 2
            let path = NSBezierPath(roundedRect: outer, xRadius: Tokens.cornerRadius + grow, yRadius: Tokens.cornerRadius + grow)
            let innerGrow = (inner.width - card.width) / 2
            path.append(NSBezierPath(roundedRect: inner, xRadius: Tokens.cornerRadius + innerGrow, yRadius: Tokens.cornerRadius + innerGrow))
            path.windingRule = .evenOdd
            ring.color.setFill()
            path.fill()
            inner = outer
        }
        palette.material.setFill()
        NSBezierPath(roundedRect: card, xRadius: Tokens.cornerRadius, yRadius: Tokens.cornerRadius).fill()
    }
}
