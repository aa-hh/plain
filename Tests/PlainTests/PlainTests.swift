import AppKit
import PlainCore
import PlainDocument
import SwiftUI
import XCTest

@testable import PlainAppKit

@MainActor
final class PlainTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PlainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ text: String = "") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func context() -> AppContext {
        AppContext(userData: folder.appendingPathComponent("userdata", isDirectory: true))
    }

    // MARK: Opening

    func testOpenRules() throws {
        // Turns red if OpenTarget.decide stops following spec 757–762 for anchors, images, other files or URLs.
        let note = try write("note.md", "# Intro\n")
        let picture = try write("picture.png")
        let archive = try write("archive.zip")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)

        func path(_ target: OpenTarget) -> String? {
            switch target {
            case .tab(let url, _), .quickLook(let url), .system(let url), .browser(let url): url.path
            case .nothing: nil
            }
        }
        XCTAssertEqual(path(OpenTarget.decide(note.path)), note.path)
        guard case .tab(_, nil) = OpenTarget.decide(note.path) else { return XCTFail("openable file opens in a tab") }
        guard case .tab(let anchored, "intro") = OpenTarget.decide(note.path + "#intro") else { return XCTFail("anchor") }
        XCTAssertEqual(anchored.path, note.path)
        guard case .tab(_, "x=1") = OpenTarget.decide(note.path + "?x=1") else { return XCTFail("query") }
        guard case .tab(_, nil) = OpenTarget.decide(note.path + "/") else { return XCTFail("trailing slash") }
        guard case .quickLook = OpenTarget.decide(picture.path) else { return XCTFail("image uses Quick Look") }
        guard case .system = OpenTarget.decide(archive.path) else { return XCTFail("other file opens with the system") }
        guard case .browser = OpenTarget.decide("https://example.com/page") else { return XCTFail("URL opens in the browser") }
        XCTAssertEqual(OpenTarget.decide(folder.appendingPathComponent("missing.md").path), .nothing)
        // Spec 763: a folder from the system or the command line is ignored.
        XCTAssertFalse(AppDelegate.isRegularFile(folder.appendingPathComponent("sub")))
        XCTAssertTrue(AppDelegate.isRegularFile(note))
    }

    // MARK: Tabs

    func testTabMemoryRoundTrip() async throws {
        // Turns red if TabMemory stops keeping each folder's tabs separately in state/tabs-w<N>.json.
        let store = StateStore(folder: folder.appendingPathComponent("state"))
        let a = folder.appendingPathComponent("A"), b = folder.appendingPathComponent("B")
        let first = TabMemory(files: ["/x/1.md", "/x/2.md"], current: 1, closed: ["/x/0.md"],
                              recents: [RecentFile(path: "/x/2.md", lastUsed: Date(timeIntervalSince1970: 100))])
        let second = TabMemory(files: ["/y/3.md"], current: 0)
        try await TabMemory.save(first, to: store, window: 2, folder: a)
        try await TabMemory.save(second, to: store, window: 2, folder: b)
        let loadedFirst = await TabMemory.load(from: store, window: 2, folder: a)
        let loadedSecond = await TabMemory.load(from: store, window: 2, folder: b)
        let otherWindow = await TabMemory.load(from: store, window: 3, folder: a)
        XCTAssertEqual(loadedFirst, first)
        XCTAssertEqual(loadedSecond, second)
        XCTAssertNil(otherWindow)
    }

    func testWindowRestoresTabsForItsFolder() async throws {
        // Turns red if WindowModel stops saving its open tabs on hide or stops reopening them for the same folder.
        let a = try write("a.md", "alpha"), b = try write("b.md", "beta")
        let context = context()
        let model = WindowModel(id: 4, context: context)
        await model.setFolder(folder, prompt: false)
        await model.openInTab(a)
        await model.openInTab(b)
        model.windowWillHide()
        try await Task.sleep(for: .milliseconds(300))

        let reopened = WindowModel(id: 4, context: context)
        await reopened.setFolder(folder, prompt: false)
        XCTAssertEqual(reopened.tabs.items.map { $0.document.url?.lastPathComponent }, ["a.md", "b.md"])
        XCTAssertEqual(reopened.currentDocument?.text, "beta")
    }

    func testClosePromptDecisionTable() {
        // Turns red if ClosePrompt asks for autosaved files, skips edited untitled or settings files, or asks for backups.
        func needed(_ edited: Bool, autosave: Bool, untitled: Bool = false, preferences: Bool = false, backup: Bool = false) -> Bool {
            ClosePrompt.isNeeded(isEdited: edited, autosave: autosave, isUntitled: untitled, isPreferences: preferences, isBackup: backup)
        }
        XCTAssertFalse(needed(false, autosave: false))
        XCTAssertFalse(needed(true, autosave: true))
        XCTAssertTrue(needed(true, autosave: false))
        XCTAssertTrue(needed(true, autosave: true, untitled: true))
        XCTAssertTrue(needed(true, autosave: true, preferences: true))
        XCTAssertFalse(needed(true, autosave: false, backup: true))
    }

    // MARK: Layout

    func testCompactLayoutValues() {
        // Turns red if WindowLayout.compute moves the column away from spec 1398 and 1401 or drops the compact rule.
        let wide = WindowLayout.compute(windowWidth: 1680, screenWidth: 1680, sidebar: true, preview: .none, columnWidth: 562)
        XCTAssertFalse(wide.compact)
        XCTAssertEqual(wide.columnX, 559)
        XCTAssertEqual(wide.columnWidth, 562)

        let narrow = WindowLayout.compute(windowWidth: 800, screenWidth: 1680, sidebar: true, preview: .none, columnWidth: 562)
        XCTAssertTrue(narrow.compact)
        XCTAssertEqual(narrow.editorX, 200)
        XCTAssertEqual(narrow.editorX + narrow.editorWidth, 800)
        XCTAssertEqual(narrow.columnWidth, 440)

        // Spec 1420–1422: split preview with the sidebar in the reference window.
        let split = WindowLayout.compute(windowWidth: 1680, screenWidth: 1680, sidebar: true, preview: .split, columnWidth: 562)
        XCTAssertTrue(split.compact)
        XCTAssertEqual(split.previewX, 940)
        XCTAssertEqual(split.previewWidth, 740)
        XCTAssertEqual(split.columnX, 289)
    }

    func testMinimumWidth() {
        // Turns red if the minimum width stops doubling with a preview or adding 260 with a sidebar (spec 725, 1432).
        XCTAssertEqual(WindowModel.minimumWidth(sidebarVisible: false, previewVisible: false), 400)
        XCTAssertEqual(WindowModel.minimumWidth(sidebarVisible: false, previewVisible: true), 800)
        XCTAssertEqual(WindowModel.minimumWidth(sidebarVisible: true, previewVisible: true), 1060)
    }

    // MARK: Settings files

    func testKeyboardShortcutsRoundTripAndRebinding() throws {
        // Turns red if Shortcuts.parse or Shortcuts.apply stop reading back the file Plain writes, or ignore a rebinding.
        let file = Shortcuts.markdown(commands: Command.all)
        let parsed = try Shortcuts.parse(file)
        let applied = Shortcuts.apply(parsed, to: Command.all)
        XCTAssertEqual(applied.map(\.shortcuts), Command.all.map(\.shortcuts))

        let rebound = file.replacingOccurrences(of: "bold: Cmd B", with: "bold: Cmd Shift B")
        let context = context()
        XCTAssertTrue(context.applyShortcutsFile(rebound))
        XCTAssertEqual(context.commands.first { $0.id == "editor:bold" }?.shortcuts, [Shortcut("Cmd Shift B")!])
        XCTAssertEqual(Shortcuts.overrides(context.commands), ["editor:bold": ["Cmd Shift B"]])

        let builder = MenuBuilder(commands: Command.all)
        let menu = builder.build()
        builder.applyShortcuts(context.commands, to: menu)
        let bold = menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.representedObject as? String == "editor:bold" }
        XCTAssertEqual(bold?.keyEquivalent, "b")
        XCTAssertEqual(bold?.keyEquivalentModifierMask, [.command, .shift])

        XCTAssertFalse(context.applyShortcutsFile(file.replacingOccurrences(of: "bold: Cmd B", with: "bold: Cmd Banana")))
        XCTAssertEqual(context.commands.first { $0.id == "editor:bold" }?.shortcuts, [Shortcut("Cmd Shift B")!])
    }

    func testPreferencesParseErrorLeavesValuesUnchanged() {
        // Turns red if PreferencesFile.apply changes any value when the YAML block does not parse.
        let preferences = Preferences()
        let broken = SettingsFiles.preferencesMarkdown(yamlBody: "fontSize: 18\nlineHeight: [1.7")
        XCTAssertFalse(PreferencesFile.apply(broken, to: preferences))
        XCTAssertEqual(preferences.number("fontSize"), 15)
        XCTAssertEqual(preferences.number("lineHeight"), 1.6)

        let wrongType = SettingsFiles.preferencesMarkdown(yamlBody: "fontSize: 18\nuseLargeFontInHeadings: 12")
        XCTAssertFalse(PreferencesFile.apply(wrongType, to: preferences))
        XCTAssertEqual(preferences.number("fontSize"), 15)

        let good = SettingsFiles.preferencesMarkdown(yamlBody: "fontSize: 50\nlineHeight: 1.8")
        XCTAssertTrue(PreferencesFile.apply(good, to: preferences))
        XCTAssertEqual(preferences.number("fontSize"), 30)
        XCTAssertEqual(preferences.number("lineHeight"), 1.8)
    }

    func testFontSizeCommandsClamp() {
        // Turns red if the font size commands stop moving both sizes together or stop at the 10–30 range.
        let context = context()
        let model = WindowModel(id: 5, context: context)
        context.preferences.set("fontSize", .number(30))
        context.preferences.set("codeFontSize", .number(29))
        model.perform("window:font-size-increase")
        XCTAssertEqual(context.preferences.number("fontSize"), 30)
        XCTAssertEqual(context.preferences.number("codeFontSize"), 30)
        model.perform("window:font-size-decrease")
        XCTAssertEqual(context.preferences.number("fontSize"), 29)
        XCTAssertEqual(context.preferences.number("codeFontSize"), 29)
        model.perform("window:font-size-default")
        XCTAssertEqual(context.preferences.number("fontSize"), 15)
        XCTAssertEqual(context.preferences.number("codeFontSize"), 13)
        XCTAssertEqual(model.configuration.fontSize, 15)
    }

    // MARK: Menu

    func testMenuContainsEveryVisibleCommandTitle() {
        // Turns red if MenuBuilder.build leaves out a command the table shows in the menu bar.
        let menu = MenuBuilder(commands: Command.all).build()
        var titles = Set<String>()
        func walk(_ menu: NSMenu) {
            for item in menu.items where !item.isHidden {
                titles.insert(item.title)
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)
        let shown = Command.all.filter { !$0.hiddenFromMenu && $0.menu != .tabContext && $0.menu != .editorContext }
        for command in shown { XCTAssertTrue(titles.contains(command.title), "missing \(command.title)") }
        XCTAssertTrue(titles.contains("Window"))
    }

    // MARK: Recent folders

    func testRecentFoldersOrdering() {
        // Turns red if RecentFolders.adding stops moving a reopened folder to the top without duplicating it.
        let a = URL(fileURLWithPath: "/tmp/a", isDirectory: true)
        let b = URL(fileURLWithPath: "/tmp/b", isDirectory: true)
        let c = URL(fileURLWithPath: "/tmp/c", isDirectory: true)
        var list: [URL] = []
        for url in [a, b, c, a] { list = RecentFolders.adding(url, to: list) }
        XCTAssertEqual(list.map(\.lastPathComponent), ["a", "c", "b"])
    }

    // MARK: Windows

    func testWindowControllerMakesHostingWindow() {
        // Turns red if WindowController stops building the full-size-content window with WindowView in a hosting view.
        let context = context()
        let model = WindowModel(id: 9, context: context)
        let controller = WindowController(id: 9, model: model, context: context, frame: NSRect(x: 0, y: 0, width: 900, height: 600), zoomed: false)
        XCTAssertTrue(controller.window.contentView is NSHostingView<WindowView>)
        XCTAssertTrue(controller.window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(controller.window.titlebarAppearsTransparent)
        XCTAssertEqual(controller.window.minSize, NSSize(width: 400, height: 400))
        XCTAssertTrue(model.window === controller.window)
    }
}
