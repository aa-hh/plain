import XCTest
@testable import PlainCore
import PreviewRenderer

final class PreviewThemeTests: XCTestCase {
    // Turns red if the Claude pair drops out of `builtIn`, so no menu item or `.css` file is written for it.
    func testBuiltInThemes() {
        let names = Themes.builtIn.map(\.name)
        XCTAssertTrue(names.contains("Claude"))
        XCTAssertTrue(names.contains("Claude Dark"))
        XCTAssertEqual(Themes.commandID(forName: "Claude"), "windows:claude-preview-theme")
        XCTAssertEqual(Themes.commandID(forName: "Claude Dark"), "windows:claudedark-preview-theme")
    }

    // Turns red if `writeBuiltIns` stops writing one file per built-in theme, or names one wrongly.
    func testWriteBuiltIns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Themes(folder: folder).writeBuiltIns()
        for name in Themes.builtIn.map(\.name) {
            let path = folder.appendingPathComponent(name + ".css").path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Claude.css").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Claude Dark.css").path))
    }

    // Turns red if the Claude stylesheet loses a measured rule: the half-pixel code block border, the
    // near-body strong weight, the 4px list gap, or the cell-only table rules.
    func testClaudeCSS() {
        let css = Themes.css(for: Tokens.previewClaude)
        XCTAssertTrue(css.contains("border: 0.5px solid rgba(0,0,0,0.12);"))
        XCTAssertTrue(css.contains("strong, b { font-weight: 500; }"))
        XCTAssertTrue(css.contains("li + li { margin-top: 4px; }"))
        XCTAssertTrue(css.contains("ul ul, ul ol, ol ul, ol ol { padding-bottom: 4px; margin-top: 4px; }"))
        XCTAssertTrue(css.contains("border-bottom: 0.5px solid var(--rule-color);"))
        XCTAssertTrue(css.contains("th { font-weight: 600; border-bottom-color: rgba(0,0,0,0.18); }"))
        XCTAssertFalse(css.contains("border-top: 3.9px"))
        XCTAssertFalse(css.contains("nth-child(2n)"))
        // The surface, radius and border sit on the wrapper so the header shares them, and the code
        // inside loses its own margin so it sits flush under the header.
        XCTAssertTrue(css.contains(".code-block { background: var(--code-background); border: 0.5px solid rgba(0,0,0,0.12); border-radius: 8px; overflow: hidden; }"))
        XCTAssertTrue(css.contains(".code-block > pre { background: none; border: 0; border-radius: 0; padding: 0 14px 14px; }"))
    }

    // Turns red if the Claude Dark stylesheet takes the light values or loses the dark ones.
    func testClaudeDarkCSS() {
        let css = Themes.css(for: Tokens.previewClaudeDark)
        XCTAssertTrue(css.contains("border: 0.5px solid rgba(255,255,255,0.14);"))
        XCTAssertTrue(css.contains("th { font-weight: 600; border-bottom-color: rgba(255,255,255,0.21); }"))
        XCTAssertTrue(css.contains("strong, b { font-weight: 500; }"))
        XCTAssertFalse(css.contains("rgba(0,0,0,0.12)"))
    }

    // Turns red if the existing themes gain the Claude-only rules, or lose the `pre` border line.
    func testExistingThemesUnchanged() {
        let dark = Themes.css(for: Tokens.previewDark)
        XCTAssertTrue(dark.contains("border: none;"))
        XCTAssertFalse(dark.contains("strong, b { font-weight: 500; }"))
        XCTAssertFalse(dark.contains("li + li { margin-top: 4px; }"))
        XCTAssertFalse(dark.contains(".code-header"))
        let defaultCSS = Themes.css(for: Tokens.previewDefault)
        XCTAssertTrue(defaultCSS.contains("border: none;"))
        XCTAssertFalse(defaultCSS.contains("strong, b { font-weight: 500; }"))
        // Guards the GitHub table rules, which the Claude branch had to leave alone.
        XCTAssertTrue(Themes.css(for: Tokens.previewGitHub).contains("border: 1px solid var(--rule-color)"))
        XCTAssertFalse(Themes.css(for: Tokens.previewGitHub).contains("strong, b { font-weight: 500; }"))
    }

    // Turns red if a theme stops handing the fenced block's spacing to the wrapper, which would leave the
    // header floating away from the code or double the block margin.
    func testEveryThemeHandsTheCodeBlockMarginToTheWrapper() {
        for theme in Themes.builtIn.map(\.tokens) {
            let css = Themes.css(for: theme)
            XCTAssertTrue(css.contains(".code-block { margin: \(theme.codeBlockMargin); }"), theme.name)
            XCTAssertTrue(css.contains(".code-block > pre { margin: 0; }"), theme.name)
        }
    }

    // Turns red if the base stylesheet stops laying out the header, or stops hiding it in print. The base
    // rules apply to every theme, so a gap here shows in Default, GitHub and Dark too.
    func testBaseCSSLaysOutTheCodeBlockHeader() {
        XCTAssertTrue(previewBaseCSS.contains(".code-header { display: flex;"))
        XCTAssertTrue(previewBaseCSS.contains(".code-copy"))
        XCTAssertTrue(previewBaseCSS.contains(".code-block:hover .code-copy"))
        XCTAssertTrue(previewBaseCSS.contains("@media (hover: none) { .code-copy { opacity: 0.75; } }"))
        let print = previewBaseCSS.components(separatedBy: "@media print {").last ?? ""
        XCTAssertTrue(print.contains(".code-header { display: none; }"))
    }

    // Turns red if the Claude pair's heading scale drifts from the measured content scale, or the body
    // size moves with it. Both themes carry the same scale.
    func testClaudeHeadingSizes() {
        for tokens in [Tokens.previewClaude, Tokens.previewClaudeDark] {
            let css = Themes.css(for: tokens)
            XCTAssertTrue(css.contains("h1 { font-size: 22px; margin: 12px 0 -4px; font-weight: bold; }"), tokens.name)
            XCTAssertTrue(css.contains("h2 { font-size: 18px; margin: 12px 0 -4px; font-weight: bold; }"), tokens.name)
            XCTAssertTrue(css.contains("h3 { font-size: 16px; margin: 8px 0 -4px; font-weight: bold; }"), tokens.name)
            XCTAssertTrue(css.contains("h4 { font-size: 16px; margin: 8px 0 -4px; font-weight: bold; }"), tokens.name)
            XCTAssertTrue(css.contains("h5 { font-size: 14px; margin: 8px 0 -4px; font-weight: bold; }"), tokens.name)
            XCTAssertTrue(css.contains("h6 { font-size: 14px; margin: 8px 0 -4px; font-weight: 600; }"), tokens.name)
            // Body text is untouched: 15px with a 22.5px line height.
            XCTAssertTrue(css.contains("font-size: 15px;"), tokens.name)
            XCTAssertTrue(css.contains("line-height: 22.5px;"), tokens.name)
            // Default's 32px h1 and GitHub's 36px h1 stay out.
            XCTAssertFalse(css.contains("font-size: 32px;"), tokens.name)
            XCTAssertFalse(css.contains("font-size: 36px;"), tokens.name)
        }
    }

    // Turns red if the heading change reaches Default, GitHub or Dark, whose sizes, weights and margins
    // have to stay as they are.
    func testOlderThemesKeepTheirHeadingScale() {
        let defaultCSS = Themes.css(for: Tokens.previewDefault)
        XCTAssertTrue(defaultCSS.contains("h1 { font-size: 32px; margin: 86.4px 0 57.6px; line-height: 28.8px; }"))
        XCTAssertTrue(defaultCSS.contains("h3 { font-size: 16px; margin: 43.2px 0 28.8px; }"))
        XCTAssertTrue(defaultCSS.contains("font-weight: bold; color: inherit;"))
        XCTAssertFalse(defaultCSS.contains("font-weight: 600;"))

        let githubCSS = Themes.css(for: Tokens.previewGitHub)
        XCTAssertTrue(githubCSS.contains("h1 { font-size: 36px; margin: 36px 0 16px; line-height: 43.2px; padding-bottom: 10.8px; border-bottom: 1px solid #EEEEEE; }"))
        XCTAssertTrue(githubCSS.contains("h5 { font-size: 16px; margin: 16px 0 16px; }"))
        XCTAssertTrue(githubCSS.contains("font-weight: bold; color: inherit;"))
        XCTAssertFalse(githubCSS.contains("font-weight: 600;"))

        let darkCSS = Themes.css(for: Tokens.previewDark)
        XCTAssertTrue(darkCSS.contains("h1 { font-size: 26px; margin: 37.05px 0 24.7px; }"))
        XCTAssertTrue(darkCSS.contains("h2 { font-size: 22.1px; margin: 37.05px 0 24.7px; }"))
        XCTAssertTrue(darkCSS.contains("font-weight: normal; color: inherit;"))
        XCTAssertFalse(darkCSS.contains("font-size: 22px;"))
        XCTAssertFalse(darkCSS.contains("font-weight: 600;"))

        // The Claude heading margins, negative bottom included, belong to the Claude pair only.
        for tokens in [Tokens.previewDefault, Tokens.previewGitHub, Tokens.previewDark] {
            let css = Themes.css(for: tokens)
            XCTAssertFalse(css.contains("margin: 12px 0 -4px;"), tokens.name)
            XCTAssertFalse(css.contains("margin: 8px 0 -4px;"), tokens.name)
        }
    }

    // Turns red if Plain stops opening on the Claude theme when nothing has been chosen: no saved path and
    // no built-in files written yet.
    func testStartupThemeWithNoStateIsClaude() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Plain-Claude.css"))
        }
        let themes = Themes(folder: folder, store: StateStore(folder: folder.appendingPathComponent("state")))
        let url = await themes.startupTheme()
        XCTAssertEqual(url.lastPathComponent, "Plain-Claude.css")
        let css = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(css.contains("h1 { font-size: 22px; margin: 12px 0 -4px; font-weight: bold; }"))
    }

    // Turns red if the written built-ins stop carrying the fallback, so an install whose Themes folder is
    // already populated resolves somewhere else.
    func testStartupThemeUsesTheWrittenClaudeFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let themes = Themes(folder: folder, store: StateStore(folder: folder.appendingPathComponent("state")))
        try themes.writeBuiltIns()
        let url = await themes.startupTheme()
        XCTAssertEqual(url.path, folder.appendingPathComponent("Claude.css").path)
    }

    // Turns red if a chosen theme stops winning over the fallback, including one the user has since
    // rewritten under the same name.
    func testSavedThemeWinsOverTheFallback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let themes = Themes(folder: folder, store: StateStore(folder: folder.appendingPathComponent("state")))
        try themes.writeBuiltIns()
        let mine = folder.appendingPathComponent("Mine.css")
        try "p { color: #123456; }".write(to: mine, atomically: true, encoding: .utf8)
        try await themes.select(mine)
        try "p { color: #654321; }".write(to: mine, atomically: true, encoding: .utf8)
        let url = await themes.startupTheme()
        XCTAssertEqual(url.path, mine.path)
    }

    // Turns red if a saved path to a file the user has deleted stops falling back, or falls back to
    // Default instead of Claude.
    func testSavedThemePathThatIsGoneFallsBackToClaude() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let themes = Themes(folder: folder, store: StateStore(folder: folder.appendingPathComponent("state")))
        try themes.writeBuiltIns()
        let mine = folder.appendingPathComponent("Mine.css")
        try "p { color: #123456; }".write(to: mine, atomically: true, encoding: .utf8)
        try await themes.select(mine)
        try FileManager.default.removeItem(at: mine)
        let url = await themes.startupTheme()
        XCTAssertEqual(url.lastPathComponent, "Claude.css")
    }

    // Turns red if the built-in set stops numbering five, or a theme loses the menu command identifier
    // the menu and the key monitor dispatch on.
    func testBuiltInThemeMenuCommands() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Themes(folder: folder).writeBuiltIns()
        XCTAssertEqual(Themes.builtIn.map(\.name), ["Default", "GitHub", "Dark", "Claude", "Claude Dark"])
        let files = Themes(folder: folder).list()
        XCTAssertEqual(files.count, Themes.builtIn.count)
        let ids = Themes.builtIn.map { Themes.commandID(forName: $0.name) }
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertTrue(files.contains { $0.commandID == id }, id)
        }
    }
}
