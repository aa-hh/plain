import AppKit
import PlainCore

/// One `.css` file in the Themes folder.
public struct ThemeFile: Hashable, Sendable {
    /// The file name without extension; the menu item's title.
    public var name: String
    public var url: URL
    /// `windows:<name>-preview-theme`, the name lower-cased with every non-letter removed (spec 549).
    public var commandID: String
}

/// The preview themes in `<user data>/Themes` (spec 546–552). The three built-in files are written fresh on every
/// launch, so edits to them do not survive; other `.css` files there are the user's own themes.
public struct Themes: Sendable {
    public let folder: URL
    public let store: StateStore

    /// The state file holding the chosen theme's path under the key `themePath`.
    public static let stateName = "preview"

    struct SavedTheme: Codable {
        var themePath: String?
    }

    public init(folder: URL = UserData.themes, store: StateStore = StateStore()) {
        self.folder = folder
        self.store = store
    }

    /// File names (without `.css`) and tokens of the built-in themes.
    public static let builtIn: [(name: String, tokens: PreviewThemeTokens)] = [
        ("Default", Tokens.previewDefault), ("GitHub", Tokens.previewGitHub), ("Dark", Tokens.previewDark),
    ]

    /// Writes `Default.css`, `GitHub.css` and `Dark.css`, replacing files of those names.
    public func writeBuiltIns() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for theme in Self.builtIn {
            try Self.css(for: theme.tokens).write(to: folder.appendingPathComponent(theme.name + ".css"), atomically: true, encoding: .utf8)
        }
    }

    /// Every `.css` file in the folder, by name.
    public func list() -> [ThemeFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "css" }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                return ThemeFile(name: name, url: url, commandID: Self.commandID(forName: name))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func commandID(forName name: String) -> String {
        "windows:" + String(name.lowercased().filter(\.isLetter)) + "-preview-theme"
    }

    /// Saves the chosen theme's path app-wide.
    public func select(_ url: URL) async throws {
        try await store.save(Self.stateName, SavedTheme(themePath: url.path))
    }

    public func savedThemePath() async -> String? {
        await store.load(Self.stateName, as: SavedTheme.self)?.themePath
    }

    /// The saved theme if its file exists, else `Themes/Default.css`, else the built-in Default written to a
    /// temporary file (spec 551).
    public func startupTheme() async -> URL {
        let manager = FileManager.default
        if let path = await savedThemePath(), manager.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        let defaultURL = folder.appendingPathComponent("Default.css")
        if manager.fileExists(atPath: defaultURL.path) { return defaultURL }
        let fallback = manager.temporaryDirectory.appendingPathComponent("Plain-Default.css")
        try? Self.css(for: Tokens.previewDefault).write(to: fallback, atomically: true, encoding: .utf8)
        return fallback
    }

    /// Add Theme…: opens the Themes folder in Finder and posts a notification with a Restart button (spec 552).
    @MainActor
    public func addTheme(post: (_ message: String, _ buttonTitle: String, _ action: @escaping @MainActor () -> Void) -> Void) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
        post("Restart Plain so the new theme shows in the menu", "Restart") { Self.restart() }
    }

    /// Opens a new copy of the app, then quits this one.
    @MainActor
    public static func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    // MARK: Stylesheet

    /// A theme stylesheet for the preview's shadow root: colours as custom properties on `:host`, layout on
    /// `.content`, then elements, KaTeX, Prism tokens and print size.
    public static func css(for theme: PreviewThemeTokens) -> String {
        let isGitHub = theme.name == "GitHub"
        var css = """
        /* \(theme.name) preview theme for Plain. Plain rewrites this file on every launch; copy it under another name to make your own. */
        :host {
          --background: \(theme.background);
          --color: \(theme.bodyColor);
          --link: \(theme.linkColor);
          --code-color: \(theme.codeBlockColor);
          --code-background: \(theme.codeBlockBackground);
          --inline-code-color: \(theme.inlineCodeColor);
          --inline-code-background: \(theme.inlineCodeBackground);
          --quote-color: \(theme.quoteColor);
          --rule-color: \(theme.tableRuleColor);
          display: block;
          background: var(--background);
          color: var(--color);
          font-family: \(theme.bodyFont);
          font-size: \(theme.bodySize);
          line-height: \(theme.bodyLineHeight);
          -webkit-font-smoothing: antialiased;
        }
        .content {
          max-width: \(theme.contentMaxWidth);
          margin: 0 auto;
          padding: \(theme.paddingVertical) \(theme.paddingSides);
          overflow-wrap: break-word;
        }
        p, ul, ol, table, pre, blockquote, details, .table-of-contents, .math-block { margin: \(theme.paragraphMargin); }
        h1, h2, h3, h4, h5, h6 { font-family: \(theme.headingFont); font-weight: \(theme.headingWeight); color: inherit; margin: \(theme.paragraphMargin);\(theme.name == "Dark" ? " line-height: normal;" : "") }

        """
        for level in 1...6 {
            var rule = "h\(level) { font-size: \(theme.headingSizes[level - 1]);"
            let margin = theme.headingMargins[level - 1]
            if !margin.isEmpty { rule += " margin: \(margin);" }
            if theme.name == "Default" && level == 1 { rule += " line-height: 28.8px;" }
            if isGitHub && level == 1 { rule += " line-height: 43.2px; padding-bottom: 10.8px; border-bottom: 1px solid #EEEEEE;" }
            if isGitHub && level == 2 { rule += " line-height: 34.3px; padding-bottom: 8.4px; border-bottom: 1px solid #EEEEEE;" }
            if isGitHub && level == 6 { rule += " color: #777777;" }
            css += rule + " }\n"
        }
        css += """
        a { color: var(--link); text-decoration: none; }
        \(isGitHub ? "a:hover, a:active { text-decoration: underline; }\n" : "")strong { font-weight: bold; }
        em { font-style: italic; }
        s { text-decoration: line-through; }
        code {
          font-family: \(theme.inlineCodeFont);
          font-size: \(theme.inlineCodeSize);
          color: var(--inline-code-color);
          background: var(--inline-code-background);
          border-radius: \(theme.inlineCodeRadius);
          padding: \(theme.inlineCodePadding);
          margin: \(theme.inlineCodeMargin);
        }
        pre {
          background: var(--code-background);
          border-radius: \(theme.codeBlockRadius);
          padding: \(theme.codeBlockPadding);
          margin: \(theme.codeBlockMargin);
          overflow-x: auto;
        }
        pre code {
          font-family: \(theme.codeBlockFont);
          font-size: \(theme.codeBlockSize);
          line-height: \(theme.codeBlockLineHeight);
          color: var(--code-color);
          background: none;
          border-radius: 0;
          padding: 0;
          margin: 0;
          white-space: pre;
        }
        blockquote {
          border-left: \(theme.quoteBorder);
          padding: \(theme.quotePadding);
          color: var(--quote-color);
          margin: \(theme.quoteMargin);
        }
        ul, ol { padding-left: \(theme.listPadding); }
        ul { list-style: disc; }
        ol { list-style: decimal; }
        li > ul, li > ol { margin-bottom: 0; }
        \(isGitHub ? "ul ul { list-style: circle; }\nol ol, ul ol { list-style: lower-roman; }\nol ol ol, ol ul ol, ul ol ol, ul ul ol { list-style: lower-alpha; }" : "ol ol, ul ol { list-style: lower-roman; }")
        .task-list-item { list-style: none; }
        \(isGitHub ? ".task-list-item + .task-list-item { margin-top: 3px; }\n.task-list-item-checkbox { margin: 0 0.2em 0.25em -1.6em; vertical-align: middle; }" : ".task-list-item-checkbox { margin-left: -20.8px; width: 16.9px; }")
        img { max-width: 100%; border: 0;\(isGitHub ? " background: #FFFFFF;" : "") }

        """
        if isGitHub {
            css += """
            table { display: block; width: max-content; max-width: 100%; overflow: auto; border-collapse: collapse; }
            th, td { border: 1px solid var(--rule-color); padding: \(theme.tableCellPadding); }
            th { font-weight: bold; }
            tr { border-top: 1px solid #CCCCCC; }
            tbody tr:nth-child(2n) { background: #F8F8F8; }
            hr { height: 4px; padding: 0; margin: \(theme.ruleMargin); background: #E7E7E7; border: 0; border-bottom: 1px solid #EEEEEE; }

            """
        } else {
            css += """
            table { width: 100%; border-collapse: collapse; border-top: 3.9px solid var(--rule-color); border-bottom: 3.9px solid var(--rule-color); }
            th, td { padding: \(theme.tableCellPadding); text-align: left; vertical-align: top; }
            th { font-weight: normal; }
            th:first-child, td:first-child { padding-left: 0; }
            th:last-child, td:last-child { padding-right: 0; }
            tbody tr:first-child td { border-top: 2.6px solid var(--rule-color); }
            hr { border: 0; border-top: \(theme.rule); margin: \(theme.ruleMargin); height: 0; }

            """
        }
        css += """
        .math-block { font-size: \(theme.mathBlockSize); text-align: \(theme.mathBlockAlign); padding: \(theme.mathBlockPadding); margin: \(theme.mathBlockMargin); border-radius: 4px; overflow-x: auto; overflow-y: hidden; }
        .math-block .katex-display { margin: 0; text-align: inherit; }
        .math-block .katex-display > .katex { text-align: inherit; }
        .katex--error, .katex-error { font-family: \(theme.inlineCodeFont); white-space: pre-wrap; }
        .footnote-ref { font-size: 0.83em; }
        .footnote-ref a, .footnote-backref { color: var(--link); }
        .footnotes-sep { margin-top: 2em; }
        .footnotes-list { font-size: 0.95em; }
        .emoji { font-size: inherit; }
        .page-break { height: 0; }

        """
        for (token, colour) in theme.codeTokens.sorted(by: { $0.key < $1.key }) {
            css += ".token.\(token) { color: \(colour); }\n"
        }
        if let selection = theme.selection { css += "::selection { background: \(selection); }\n" }
        css += """
        @media print {
          :host { font-size: \(theme.printFontSize); }
        }

        """
        return css
    }
}
