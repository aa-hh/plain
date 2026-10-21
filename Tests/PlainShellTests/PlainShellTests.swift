import AppKit
import Combine
import FolderIndex
import MarkdownDocument
import PlainCore
import PlainDocument
import SwiftUI
import XCTest

@testable import PlainShell

@MainActor
final class PlainShellTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PlainShellTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func headings(_ text: String) async -> [Heading] {
        await MarkdownDocument(text: text).currentSnapshot().headings
    }

    private func searchHits(_ files: [String: String], query: String) async throws -> [SearchHit] {
        for (name, text) in files {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let index = FolderIndex(root: folder)
        await index.start()
        var hits: [SearchHit] = []
        for await batch in search(query, in: index) { hits += batch }
        return hits
    }

    func testGoToFileListsRecentsFirst() {
        // Turns red if GoToFileList.rows stops putting recent files ahead of other indexed files or keeps untitled files.
        let a = folder.appendingPathComponent("a.md"), b = folder.appendingPathComponent("b.md")
        let c = folder.appendingPathComponent("c.md"), z = folder.appendingPathComponent("z.md")
        let untitled = UserData.untitledFiles.appendingPathComponent("x1y2z3.md")
        let recents = [b, untitled, a]

        XCTAssertEqual(GoToFileList.rows(recents: recents, allFiles: [a, c, z, b], query: "").map(\.url), [b, a])
        XCTAssertEqual(GoToFileList.rows(recents: recents, allFiles: [a, c, z, b], query: "md").map(\.url), [b, a, c, z])
        XCTAssertEqual(GoToFileList.rows(recents: recents, allFiles: [a, c, z, b], query: "zm").map(\.url), [z])
    }

    func testGoToHeadingKeepsParents() async {
        // Turns red if HeadingList.rows drops the parent headings of a match.
        let list = await headings("# Intro\n\n## Setup\n\n### Install tools\n\n## Other\n")
        let rows = HeadingList.rows(headings: list, query: "tools")
        XCTAssertEqual(rows.map(\.index), [0, 1, 2])
        XCTAssertNil(rows[0].match)
        XCTAssertNil(rows[1].match)
        XCTAssertNotNil(rows[2].match)
    }

    func testCommandsPutRecentFirstWithDivider() {
        // Turns red if CommandList.rows stops listing the recent commands first with a divider after them.
        let list = CommandList.rows(commands: Command.all, recent: ["file:save", "editor:bold"], query: "")
        XCTAssertEqual(list.rows.prefix(2).map(\.command.id), ["file:save", "editor:bold"])
        XCTAssertEqual(list.dividerAfter, 1)
        XCTAssertEqual(list.rows.filter { $0.command.id == "file:save" }.count, 1)
        XCTAssertFalse(list.rows.contains { $0.command.id == "editor:next-edit" }, "hidden from menu")
        XCTAssertFalse(list.rows.contains { $0.command.id == "window:move-tab-left" }, "tab context only")
        XCTAssertEqual(CommandList.label(list.rows[0].command), "File › Save")
        XCTAssertNil(CommandList.rows(commands: Command.all, recent: [], query: "").dividerAfter)
    }

    func testTabSwitcherPreselectsSecondEntry() {
        // Turns red if TabSwitcherPopup.initialSelection stops skipping the current tab.
        let tabs = (0..<3).map { _ in TabItem(document: Document(text: "x")) }
        XCTAssertEqual(TabSwitcherPopup.initialSelection(tabs: tabs, currentID: tabs[0].id), 1)
        XCTAssertEqual(TabSwitcherPopup.initialSelection(tabs: tabs, currentID: tabs[2].id), 0)
        XCTAssertEqual(TabSwitcherPopup.initialSelection(tabs: Array(tabs.prefix(1)), currentID: tabs[0].id), 0)
    }

    func testFindInFolderGroupsCollapseAtFifteenHits() async throws {
        // Turns red if FindInFolderList changes the 15-hit threshold for a group starting expanded.
        let fifteen = Array(repeating: "a foo b", count: 15).joined(separator: "\n")
        let fourteen = Array(repeating: "a foo b", count: 14).joined(separator: "\n")
        let hits = try await searchHits(["many.md": fifteen, "few.md": fourteen], query: "foo")
        let groups = FindInFolderList.groups(hits)
        let many = try XCTUnwrap(groups.first { $0.url.lastPathComponent == "many.md" })
        let few = try XCTUnwrap(groups.first { $0.url.lastPathComponent == "few.md" })
        XCTAssertFalse(many.startsExpanded)
        XCTAssertTrue(few.startsExpanded)
        XCTAssertEqual(FindInFolderList.rows(groups, toggled: []).count, 2 + 14)
        XCTAssertEqual(FindInFolderList.rows(groups, toggled: [many.url]).count, 2 + 14 + 15)
        XCTAssertEqual(FindInFolderList.relativePath(many.url, in: folder), "many.md")
    }

    func testOutlineIndentsByRank() {
        // Turns red if HeadingList.ranks indents by heading level instead of rank among the levels in use.
        XCTAssertEqual(HeadingList.ranks(levels: [1, 3, 5]), [0, 1, 2])
        XCTAssertEqual(HeadingList.ranks(levels: [2, 4, 2, 3]), [0, 2, 0, 1])
    }

    func testStatsLabelStrings() {
        // Turns red if TextStatsMode labels or preference values change.
        XCTAssertEqual(TextStatsMode.wordCount.label(for: "Hi, there - you?"), "3 W")
        XCTAssertEqual(TextStatsMode.characterCount.label(for: "abc"), "3 C")
        XCTAssertEqual(TextStatsMode.readingTime.label(for: Array(repeating: "word", count: 400).joined(separator: " ")), "02:00 RT")
        XCTAssertEqual(TextStatsMode(rawValue: "word-count"), .wordCount)
        XCTAssertEqual(TextStatsMode.allCases.map(\.rawValue), ["word-count", "character-count", "reading-time"])
    }

    func testEachViewRendersInHostingView() async throws {
        // Turns red if any PlainShell view crashes while laying out in an NSHostingView.
        try "# One\n\n## Two\n".write(to: folder.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let index = FolderIndex(root: folder)
        await index.start()
        let tree = await index.tree
        let list = await headings("# One\n\n## Two\n")
        let hits = try await searchHits([:], query: "One")
        let tabs = [TabItem(document: Document(text: "x")), TabItem(document: Document(text: ""), mark: .outsideFolder)]
        let flags = Just(NSEvent.ModifierFlags.control).eraseToAnyPublisher()
        let actions = FilesSidebarActions(
            open: { _, _ in }, createFile: { _, _ in }, createFolder: { _, _ in }, rename: { _, _ in },
            trash: { _ in }, copy: { _ in }, cut: { _ in }, paste: { _ in }, revealInFinder: { _ in }, focusEditor: {})
        let tabActions = TabBarActions(
            select: { _ in }, close: { _ in }, closeOthers: { _ in }, closeAll: {}, move: { _, _ in },
            showInFinder: { _ in }, revertToBackup: { _ in }, toggleZoom: {})
        let file = folder.appendingPathComponent("a.md")

        let views: [AnyView] = [
            AnyView(GoToFilePopup(recents: [file], allFiles: [file], gitMarks: [file: .changed], query: .constant(""), selection: .constant(0), onOpen: { _ in }, onCancel: {})),
            AnyView(GoToHeadingPopup(headings: list, query: .constant("Two"), selection: .constant(0), onPick: { _ in }, onCancel: {})),
            AnyView(CommandsPopup(recent: ["file:save"], isChecked: { _ in true }, query: .constant(""), selection: .constant(0), onRun: { _ in }, onCancel: {})),
            AnyView(RecentFoldersPopup(folders: [folder, FileManager.default.homeDirectoryForCurrentUser], currentFolder: folder, query: .constant(""), selection: .constant(0), onOpen: { _ in }, onCancel: {})),
            AnyView(BackupsPopup(backups: [], query: .constant(""), selection: .constant(0), onPick: { _ in }, onCancel: {})),
            AnyView(TabSwitcherPopup(tabs: tabs, selection: .constant(1), modifierFlags: flags, onPick: { _ in }, onCancel: {})),
            AnyView(FindInFolderPopup(folder: folder, hits: hits, query: .constant("One"), selection: .constant(0), onPick: { _ in }, onCancel: {})),
            AnyView(FilesSidebar(root: tree, currentFile: file, gitMarks: [file: .added], expanded: .constant([]), compact: true, actions: actions)),
            AnyView(OutlineSidebar(headings: list, caretOffset: 10, changedHeadings: [], onJump: { _, _ in })),
            AnyView(TextStatsLabel(text: "two words", isSelection: true, mode: .wordCount, onPick: { _ in })),
            AnyView(NotificationBar(notification: ShellNotification(message: "Saved", isError: true, buttons: [.init(label: "Restart", action: {})]), onClose: {})),
            AnyView(EmptyWindowView()),
            AnyView(TabBar(tabs: tabs, currentID: tabs[0].id, actions: tabActions)),
            AnyView(BackupDiffView(lines: BackupDiff.lines(old: "a\nb\nc", new: "a\nB\nc"))),
            AnyView(ImageZoomOverlay(image: NSImage(size: NSSize(width: 2000, height: 100)), onClose: {})),
        ]
        for view in views {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0)
        }
        XCTAssertEqual(ImageZoomOverlay.fittedSize(natural: CGSize(width: 2000, height: 100), container: CGSize(width: 800, height: 600)).width, 680)
    }

    func testPopupStateOpenRules() {
        // Turns red if PopupState.open stops clearing the filter or stops moving to the next row on a repeat.
        let state = PopupState()
        state.filter = "old"
        state.open(.files)
        XCTAssertEqual(state.filter, "")
        XCTAssertEqual(state.selection, 0)
        state.open(.files)
        XCTAssertEqual(state.selection, 1)
        let sidebar = SidebarState(mode: .outline)
        sidebar.toggle()
        XCTAssertEqual(sidebar.mode, .none)
        sidebar.toggle()
        XCTAssertEqual(sidebar.mode, .outline)
    }
}
