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
}
