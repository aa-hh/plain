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
        let fileActions = FileListActions(open: { _, _ in }, pin: { _ in }, unpin: { _ in }, movePin: { _, _ in }, revealInFinder: { _ in })
        let sidebarActions = SidebarActions(
            toggleFold: { _ in }, setHidden: { _, _ in }, move: { _, _ in }, resize: { _ in }, resizeEnded: {}, resetWidth: {})

        let views: [AnyView] = [
            AnyView(GoToFilePopup(recents: [file], allFiles: [file], gitMarks: [file: .changed], query: .constant(""), selection: .constant(0), onOpen: { _, _ in }, onCancel: {})),
            AnyView(GoToHeadingPopup(headings: list, query: .constant("Two"), selection: .constant(0), onPick: { _ in }, onCancel: {})),
            AnyView(CommandsPopup(recent: ["file:save"], isChecked: { _ in true }, query: .constant(""), selection: .constant(0), onRun: { _ in }, onCancel: {})),
            AnyView(RecentFoldersPopup(folders: [folder, FileManager.default.homeDirectoryForCurrentUser], currentFolder: folder, query: .constant(""), selection: .constant(0), onOpen: { _ in }, onCancel: {})),
            AnyView(BackupsPopup(backups: [], query: .constant(""), selection: .constant(0), onPick: { _ in }, onCancel: {})),
            AnyView(TabSwitcherPopup(tabs: tabs, selection: .constant(1), modifierFlags: flags, onPick: { _ in }, onCancel: {})),
            AnyView(FindInFolderPopup(folder: folder, hits: hits, query: .constant("One"), selection: .constant(0), onPick: { _, _ in }, onCancel: {})),
            AnyView(FilesSidebar(root: tree, currentFile: file, gitMarks: [file: .added], expanded: .constant([]), actions: actions)),
            AnyView(FileListSection(files: [file], currentFile: file, gitMarks: [file: .changed], isPinned: true, actions: fileActions)),
            AnyView(Sidebar(
                sections: SidebarSections().items, titles: [.pinned: "Pinned", .files: "folder", .outline: "Outline"],
                pinnedCount: 1, recentCount: 0, width: 200, compact: true, actions: sidebarActions
            ) { _ in Text("rows") }),
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
    }

    // MARK: Sidebar

    func testSidebarLayoutHeights() {
        // Turns red if Pinned and Recent stop taking their rows' height (10 and 6 at most), or Files and Outline stop
        // sharing what is left (docs/navigation-spec.md, Heights).
        let all: Set<SidebarSectionKind> = Set(SidebarSectionKind.allCases)
        let sections = SidebarSectionKind.allCases.map { SidebarSection(kind: $0) }
        // 4 headers (96) + 3 gaps (36) + 10 pins (240) + 2 recents (48) leaves 180.
        let open = SidebarLayout.place(sections, present: all, pinned: 14, recent: 2, height: 600)
        XCTAssertEqual(open.map(\.body), [240, 48, 90, 90])

        var filesFolded = sections
        filesFolded[2].folded = true
        XCTAssertEqual(SidebarLayout.place(filesFolded, present: all, pinned: 14, recent: 2, height: 600).map(\.body), [240, 48, 0, 180])

        var outlineHidden = sections
        outlineHidden[3].hidden = true
        let three = SidebarLayout.place(outlineHidden, present: all, pinned: 14, recent: 2, height: 600)
        XCTAssertEqual(three.map(\.kind), [.pinned, .recent, .files])
        XCTAssertEqual(three.last?.body, 216)

        let noFolder = SidebarLayout.place(sections, present: [.recent, .outline], pinned: 0, recent: 8, height: 100)
        XCTAssertEqual(noFolder.map(\.kind), [.recent, .outline])
        XCTAssertEqual(noFolder.map(\.body), [144, 0])
    }

    func testSidebarWidthAndOldState() {
        // Turns red if dragging the edge stops clamping to 160–400 or closing below 120, or an old sidebar-w<N> mode
        // string stops loading.
        XCTAssertNil(SidebarState.draggedWidth(119))
        XCTAssertEqual(SidebarState.draggedWidth(120), 160)
        XCTAssertEqual(SidebarState.draggedWidth(250), 250)
        XCTAssertEqual(SidebarState.draggedWidth(900), 400)

        let state = SidebarState()
        state.apply(oldMode: "none")
        XCTAssertFalse(state.visible)
        state.apply(oldMode: "outline")
        XCTAssertTrue(state.visible)
        state.apply(SidebarState.Saved(visible: true, width: 1000))
        XCTAssertEqual(state.width, 400)
    }

    func testSidebarSectionsOrderHideAndLoad() async throws {
        // Turns red if dragging a header stops moving its section, Show Files stops un-hiding and unfolding, or a
        // saved list missing a section stops loading with that section added at the end.
        let sections = SidebarSections()
        sections.move(.outline, before: .pinned)
        XCTAssertEqual(sections.items.map(\.kind), [.outline, .pinned, .recent, .files])
        sections.setHidden(.files, true)
        sections.toggleFold(.files)
        XCTAssertTrue(sections[.files].hidden)
        XCTAssertTrue(sections[.files].folded)
        sections.reveal(.files)
        XCTAssertFalse(sections[.files].hidden)
        XCTAssertFalse(sections[.files].folded)

        let store = StateStore(folder: folder.appendingPathComponent("state"))
        try await store.save(SidebarSections.stateName, [SidebarSection(kind: .files, folded: true), SidebarSection(kind: .pinned)])
        let loaded = SidebarSections()
        await loaded.load(from: store)
        XCTAssertEqual(loaded.items.map(\.kind), [.files, .pinned, .recent, .outline])
        XCTAssertTrue(loaded[.files].folded)
    }

    func testPinsFollowRenameAndTrash() async throws {
        // Turns red if pins stop following a renamed folder, stop being dropped with a trashed file, or stop
        // surviving a save and load.
        let root = URL(fileURLWithPath: "/f")
        let pins = Pins()
        pins.pin(URL(fileURLWithPath: "/f/notes/a.md"), in: root)
        pins.pin(URL(fileURLWithPath: "/f/b.md"), in: root)
        pins.pin(URL(fileURLWithPath: "/f/b.md"), in: root)
        pins.move(URL(fileURLWithPath: "/f/b.md"), to: 0, in: root)
        XCTAssertEqual(pins.files(in: root).map(\.path), ["/f/b.md", "/f/notes/a.md"])
        pins.rename(from: "/f/notes", to: "/f/old")
        XCTAssertEqual(pins.files(in: root).map(\.path), ["/f/b.md", "/f/old/a.md"])
        pins.remove(under: ["/f/b.md"])
        XCTAssertEqual(pins.files(in: root).map(\.path), ["/f/old/a.md"])

        let store = StateStore(folder: folder.appendingPathComponent("state"))
        try await pins.save(to: store)
        let loaded = Pins()
        await loaded.load(from: store)
        XCTAssertEqual(loaded.files(in: root).map(\.path), ["/f/old/a.md"])
    }

    // MARK: Tab history

    func testTabHistorySteps() {
        // Turns red if TabHistory loses its 50-entry cap, keeps the forward list after a push, or steps several
        // entries in the wrong order.
        var history = TabHistory()
        for n in 0..<60 { history.push("/f/\(n).md") }
        XCTAssertEqual(history.back.count, 50)
        XCTAssertEqual(history.back.first, "/f/10.md")

        history = TabHistory(back: ["/a", "/b", "/c"])
        XCTAssertEqual(history.goBack(3, from: "/d"), "/a")
        XCTAssertEqual(history.back, [])
        XCTAssertEqual(history.forward, ["/d", "/c", "/b"])
        XCTAssertEqual(history.goForward(from: "/a"), "/b")
        XCTAssertEqual(history.back, ["/a"])
        XCTAssertEqual(history.forward, ["/d", "/c"])
        XCTAssertNil(history.goBack(2, from: "/b"))
        history.push("/b")
        XCTAssertEqual(history.back, ["/a", "/b"])
        XCTAssertEqual(history.forward, [])
    }

    func testTabHistoryRenameRemoveAndJSON() throws {
        // Turns red if renaming a folder stops moving the entries under it, catches a sibling that only shares the
        // prefix, or the lists stop surviving a JSON round trip.
        var history = TabHistory(back: ["/f/notes/a.md", "/f/notes2.md", "/f/b.md"], forward: ["/f/notes"])
        history.rename(from: "/f/notes", to: "/f/old")
        XCTAssertEqual(history.back, ["/f/old/a.md", "/f/notes2.md", "/f/b.md"])
        XCTAssertEqual(history.forward, ["/f/old"])
        history.remove(under: ["/f/old"])
        XCTAssertEqual(history.back, ["/f/notes2.md", "/f/b.md"])
        XCTAssertEqual(history.forward, [])
        let data = try JSONEncoder().encode(history)
        XCTAssertEqual(try JSONDecoder().decode(TabHistory.self, from: data), history)
    }
}
