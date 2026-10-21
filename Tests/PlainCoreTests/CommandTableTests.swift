import XCTest
@testable import PlainCore

final class CommandTableTests: XCTestCase {
    // Turns red if a command id is repeated within a menu, or a menu other than the tab menu reuses another menu's id.
    func testIDsAreUnique() {
        for group in MenuGroup.allCases {
            let ids = Command.all.filter { $0.menu == group }.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "duplicate id in \(group)")
        }
        let outsideTabMenu = Command.all.filter { $0.menu != .tabContext }.map(\.id)
        XCTAssertEqual(outsideTabMenu.count, Set(outsideTabMenu).count)
    }

    // Turns red if `Shortcut.init(_:)` or `Shortcut.fileText` stops reading back what it writes.
    func testShortcutsRoundTrip() {
        for shortcut in Command.all.flatMap(\.shortcuts) {
            XCTAssertEqual(Shortcut(shortcut.fileText), shortcut, shortcut.fileText)
        }
        XCTAssertEqual(Shortcut("Cmd Shift S")?.fileText, "Cmd Shift S")
        XCTAssertEqual(Shortcut("shift cmd =")?.fileText, "Cmd Shift Plus")
        XCTAssertNil(Shortcut("Cmd Banana"))
    }

    // Turns red if the macOS symbol printer changes modifier order or key symbols.
    func testSymbols() {
        XCTAssertEqual(Shortcut("Cmd Alt Backspace")?.symbols, "⌥⌘⌫")
        XCTAssertEqual(Shortcut("Ctrl Shift Up")?.symbols, "⌃⇧↑")
    }

    // Turns red if `SettingsFiles.keyboardShortcutsMarkdown` drops or reformats the Bold entry.
    func testDefaultShortcutsFileHasBold() {
        let text = SettingsFiles.keyboardShortcutsMarkdown()
        XCTAssertTrue(text.contains("bold: Cmd B"))
        XCTAssertTrue(text.contains("## Format"))
    }

    // Turns red if two commands in the Keyboard Shortcuts file share a key, which would make the file ambiguous.
    func testShortcutFileKeysAreUnique() {
        let keys = SettingsFiles.shortcutSections.flatMap { group, _ in
            Command.all.filter { $0.menu == group && $0.configurable && !$0.hiddenFromMenu }.map(\.shortcutKey)
        }
        XCTAssertEqual(keys.count, Set(keys).count)
    }
}
