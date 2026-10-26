import AppKit
import GitStatus
import MarkdownDocument
import PlainCore
import PlainDocument
import PlainShell
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
                              recents: [RecentFile(path: "/x/2.md", lastUsed: Date(timeIntervalSince1970: 100))],
                              history: [TabHistory(back: ["/x/0.md"]), TabHistory()])
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

    func testTabMemoryWithoutHistoryLoads() throws {
        // Turns red if a tabs-w<N> file written before tabs had back and forward lists stops loading.
        let json = #"{"files":["/x/1.md"],"current":0,"closed":[],"recents":[]}"#
        let memory = try JSONDecoder().decode(TabMemory.self, from: Data(json.utf8))
        XCTAssertEqual(memory.files, ["/x/1.md"])
        XCTAssertEqual(memory.history, [])
    }

    func testPlacementRules() {
        // Turns red if an in-place open stops following docs/navigation-spec.md's four rules, or asks whether the tab
        // can be left before rules 1 and 2 have been tried.
        let a = UUID(), b = UUID()
        let tabs = [(id: a, path: "/f/a.md"), (id: b, path: "/f/b.md")]
        var asked = false
        XCTAssertEqual(Placement.decide(target: "/f/a.md", currentID: a, tabs: tabs) { asked = true; return true }, .stay)
        XCTAssertEqual(Placement.decide(target: "/f/b.md", currentID: a, tabs: tabs) { asked = true; return true }, .switchTo(b))
        XCTAssertFalse(asked)
        XCTAssertEqual(Placement.decide(target: "/f/c.md", currentID: a, tabs: tabs) { false }, .newTab)
        XCTAssertEqual(Placement.decide(target: "/f/c.md", currentID: nil, tabs: []) { true }, .newTab)
        XCTAssertEqual(Placement.decide(target: "/f/c.md", currentID: a, tabs: tabs) { true }, .replace)

        XCTAssertTrue(Placement.canLeave(isUntitled: false, isPreferences: false, isBackup: false, isEdited: false))
        XCTAssertFalse(Placement.canLeave(isUntitled: true, isPreferences: false, isBackup: false, isEdited: false))
        XCTAssertFalse(Placement.canLeave(isUntitled: false, isPreferences: true, isBackup: false, isEdited: false))
        XCTAssertFalse(Placement.canLeave(isUntitled: false, isPreferences: false, isBackup: true, isEdited: false))
        XCTAssertFalse(Placement.canLeave(isUntitled: false, isPreferences: false, isBackup: false, isEdited: true))
    }

    private func names(_ paths: [String]?) -> [String] {
        (paths ?? []).map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    func testOpenInPlaceReplacesTheTabAndBackReturns() async throws {
        // Turns red if opening in place adds a tab, drops the file it left from the back list, or Back and Forward
        // stop moving between them in the same tab.
        let a = try write("a.md", "alpha"), b = try write("b.md", "beta")
        let model = WindowModel(id: 20, context: context())
        await model.setFolder(folder, prompt: false)
        await model.openInTab(a)
        let tabID = try XCTUnwrap(model.tabs.currentID)
        await model.openInPlace(b)
        XCTAssertEqual(model.tabs.items.count, 1)
        XCTAssertEqual(model.tabs.currentID, tabID)
        XCTAssertEqual(model.currentDocument?.text, "beta")
        XCTAssertEqual(names(model.tabs.current?.history.back), ["a.md"])

        await model.step(back: true, steps: 1)
        XCTAssertEqual(model.currentDocument?.text, "alpha")
        XCTAssertEqual(names(model.tabs.current?.history.forward), ["b.md"])
        await model.step(back: false, steps: 1)
        XCTAssertEqual(model.currentDocument?.text, "beta")
        XCTAssertEqual(model.tabs.currentID, tabID)
    }

    func testOpenInPlaceKeepsUnsavedTextAndOpenTabs() async throws {
        // Turns red if opening in place replaces a file whose changes autosave could not write, or opens a second
        // tab for a file that is already open.
        let a = try write("a.md", "alpha"), b = try write("b.md", "beta")
        let context = context()
        context.preferences.set("file.autosave", .bool(false))
        let model = WindowModel(id: 21, context: context)
        await model.setFolder(folder, prompt: false)
        await model.openInTab(a)
        let edited = try XCTUnwrap(model.currentDocument)
        edited.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " edited")
        await model.openInPlace(b)
        XCTAssertEqual(model.tabs.items.count, 2)
        XCTAssertEqual(model.currentDocument?.text, "beta")
        XCTAssertTrue(model.tabs.items[0].document === edited)

        model.activate(model.tabs.items[0].id)
        await model.openInPlace(b)
        XCTAssertEqual(model.tabs.items.count, 2)
        XCTAssertEqual(model.tabs.currentID, model.tabs.items[1].id)
    }

    func testBackSkipsAMissingFileAndHistorySurvivesQuit() async throws {
        // Turns red if Back stops dropping an entry whose file is gone, or tabs lose their lists across a relaunch.
        let a = try write("a.md", "alpha"), b = try write("b.md", "beta"), c = try write("c.md", "gamma")
        let context = context()
        let model = WindowModel(id: 22, context: context)
        await model.setFolder(folder, prompt: false)
        await model.openInTab(a)
        await model.openInPlace(b)
        await model.openInPlace(c)
        XCTAssertEqual(names(model.tabs.current?.history.back), ["a.md", "b.md"])
        await model.saveForQuit()

        let restored = WindowModel(id: 22, context: context)
        await restored.setFolder(folder, prompt: false)
        XCTAssertEqual(names(restored.tabs.current?.history.back), ["a.md", "b.md"])

        try FileManager.default.removeItem(at: b)
        await restored.step(back: true, steps: 1)
        XCTAssertEqual(restored.currentDocument?.text, "alpha")
        XCTAssertEqual(names(restored.tabs.current?.history.back), [])
        XCTAssertEqual(names(restored.tabs.current?.history.forward), ["c.md"])
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

    func testQuitWritesHistoryUnsavedTextAndTabsBeforeReplying() async throws {
        // Turns red if the quit path goes back to returning before the history, unsaved-text and tab writes finish.
        let a = try write("a.md", "alpha")
        let context = context()
        context.preferences.set("file.autosave", .bool(false))
        let model = WindowModel(id: 6, context: context)
        await model.setFolder(folder, prompt: false)
        await model.openInTab(a)
        let named = try XCTUnwrap(model.currentDocument)
        named.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " edited")
        model.newFile()
        let untitled = try XCTUnwrap(model.currentDocument)
        untitled.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "draft")

        await AppDelegate.saveBeforeQuit([model])

        let relaunched = self.context()
        let namedText = await relaunched.fileHistory.unsavedText(for: a.path)
        let untitledText = await relaunched.fileHistory.unsavedText(for: try XCTUnwrap(untitled.untitledURL).path)
        let memory = await TabMemory.load(from: relaunched.store, window: 6, folder: folder)
        XCTAssertEqual(namedText, "alpha edited")
        XCTAssertEqual(untitledText, "draft")
        XCTAssertEqual(memory?.files.count, 2)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "alpha")
    }

    func testAutosaveRecordsHistoryAsSaved() async throws {
        // Turns red if AutosaveController.onSaved stops re-recording history, leaving an "unsaved" entry for saved text.
        let a = try write("a.md", "alpha")
        let context = context()
        let model = WindowModel(id: 7, context: context)
        await model.setFolder(folder, prompt: false)
        await model.openInTab(a)
        let document = try XCTUnwrap(model.currentDocument)
        document.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " edited")
        try await context.fileHistory.record(document)
        let before = await context.fileHistory.all().first { $0.path == a.path }?.hasUnsavedEdits
        XCTAssertEqual(before, true)

        var after: Bool?
        for _ in 0..<150 {
            after = await context.fileHistory.all().first { $0.path == a.path }?.hasUnsavedEdits
            if after == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(after, false)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "alpha edited")
    }

    func testRenameKeepsUnsavedEdits() async throws {
        // Turns red if a sidebar rename goes back to closing the tab and reloading the file from disk.
        for autosave in [false, true] {
            let old = try write("old-\(autosave).md", "alpha")
            let context = context()
            context.preferences.set("file.autosave", .bool(autosave))
            let model = WindowModel(id: 8, context: context)
            await model.setFolder(folder, prompt: false)
            await model.openInTab(old)
            let document = try XCTUnwrap(model.currentDocument)
            document.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " edited")

            try model.sidebarActions.rename(old, "new-\(autosave).md")

            let new = folder.appendingPathComponent("new-\(autosave).md")
            XCTAssertTrue(model.currentDocument === document)
            XCTAssertEqual(document.url?.lastPathComponent, new.lastPathComponent)
            XCTAssertEqual(document.text, "alpha edited")
            XCTAssertTrue(document.isEdited)
            try await Task.sleep(for: .milliseconds(900))
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
            XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), autosave ? "alpha edited" : "alpha")
            XCTAssertEqual(document.isEdited, !autosave)
            // Turns red if fileMoved stops recording the document under its new path and discarding the old path's entry.
            let paths = await context.fileHistory.all().map(\.path)
            XCTAssertFalse(paths.contains(old.path))
            XCTAssertTrue(paths.contains(try XCTUnwrap(document.url).path))
            if !autosave {
                let unsaved = await context.fileHistory.unsavedText(for: try XCTUnwrap(document.url).path)
                XCTAssertEqual(unsaved, "alpha edited")
            }
        }
    }

    func testSwitchingBackKeepsTheTabsParser() async throws {
        // Turns red if activating a tab goes back to making a fresh MarkdownDocument, which reparses the whole file.
        let a = try write("a.md", "# A\n"), b = try write("b.md", "# B\n")
        let model = WindowModel(id: 10, context: context())
        await model.setFolder(folder, prompt: false)
        await model.openInTab(a)
        let parser = try XCTUnwrap(model.markdown)
        await model.openInTab(b)
        XCTAssertFalse(model.markdown === parser)
        await model.openInTab(a)
        XCTAssertTrue(model.markdown === parser)
    }

    func testRestoringTabsParsesOnlyTheCurrentOne() async throws {
        // Turns red if parsers go back to being made when a tab is restored instead of on its first activation.
        let files = try ["a.md", "b.md", "c.md"].map { try write($0, "# \($0)\n") }
        let context = context()
        let model = WindowModel(id: 17, context: context)
        await model.setFolder(folder, prompt: false)
        for file in files { await model.openInTab(file) }
        await model.saveForQuit()

        let restored = WindowModel(id: 17, context: context)
        await restored.setFolder(folder, prompt: false)
        XCTAssertEqual(restored.tabs.items.count, 3)
        XCTAssertEqual(restored.parsers.count, 1)
        let current = try XCTUnwrap(restored.currentDocument)
        XCTAssertTrue(restored.parsers[ObjectIdentifier(current)] === restored.markdown)
    }

    func testRestoredPreferencesTabIsStillAPreferencesFile() async throws {
        // Turns red if the Preferences check moves back out of loadDocument, so a tab restored at launch is autosaved
        // and its Save no longer applies the settings.
        let context = context()
        let prefs = context.preferencesFile
        try FileManager.default.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try context.preferencesMarkdown().write(to: prefs, atomically: true, encoding: .utf8)
        let model = WindowModel(id: 11, context: context)
        await model.setFolder(folder, prompt: false)
        await model.openInTab(prefs)
        await model.saveForQuit()

        let restored = WindowModel(id: 11, context: context)
        await restored.setFolder(folder, prompt: false)
        let document = try XCTUnwrap(restored.currentDocument)
        XCTAssertEqual(document.url?.standardizedFileURL, prefs.standardizedFileURL)
        XCTAssertTrue(document.isPreferencesFile)
        let edited = SettingsFiles.preferencesMarkdown(yamlBody: "fontSize: 20\n")
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: document.textStorage.length), with: edited)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNotEqual(try String(contentsOf: prefs, encoding: .utf8), edited)
        let saved = await restored.save(document)
        XCTAssertTrue(saved)
        XCTAssertEqual(context.preferences.number("fontSize"), 20)
    }

    func testEditedMarkFollowsAutosave() async throws {
        // Turns red if the tab bar's edited dot goes back to reading document.isEdited, which flashes while autosave is on.
        let a = try write("a.md", "alpha")
        let context = context()
        let model = WindowModel(id: 12, context: context)
        await model.setFolder(folder, prompt: false)
        await model.openInTab(a)
        let tab = try XCTUnwrap(model.tabs.current)
        tab.document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        XCTAssertTrue(tab.document.isEdited)
        XCTAssertFalse(model.showsEditedMark(tab))
        context.setPreference("file.autosave", .bool(false))
        model.preferencesChanged()
        XCTAssertTrue(model.showsEditedMark(tab))

        model.newFile()
        let untitled = try XCTUnwrap(model.tabs.current)
        untitled.document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "draft")
        context.setPreference("file.autosave", .bool(true))
        model.preferencesChanged()
        XCTAssertTrue(model.showsEditedMark(untitled))
    }

    /// A window model shown in an off-screen window, so SwiftUI installs its editor.
    private func hostedModel(id: Int) async -> (WindowModel, WindowController) {
        let context = context()
        let model = WindowModel(id: id, context: context)
        let controller = WindowController(id: id, model: model, context: context,
                                          frame: NSRect(x: 0, y: 0, width: 1000, height: 700), zoomed: false)
        await model.setFolder(folder, prompt: false)
        return (model, controller)
    }

    /// Lays the window out and lets the main actor run until `condition` holds or 3 s pass.
    private func waitUntil(_ controller: WindowController, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            controller.window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testLinkWithHeadingAnchorSelectsHeading() async throws {
        // Turns red if openLink goes back to reading the window's snapshot before the new tab's parse and editor exist,
        // which leaves the file open at the top.
        let filler = String(repeating: "Some text.\n\n", count: 40)
        let notes = try write("notes.md", "# Notes\n\n" + filler + "## Section\n\nbody\n")
        let start = ("# Notes\n\n" + filler as NSString).length
        let (model, controller) = await hostedModel(id: 13)
        model.openLink(notes.path + "#section")
        let selected = await waitUntil(controller) { model.editor.selectedRanges == [NSRange(location: start, length: 0)] }
        XCTAssertTrue(selected, "selection is \(model.editor.selectedRanges)")
        XCTAssertEqual(model.currentDocument?.url?.lastPathComponent, "notes.md")
    }

    func testInstalledEditorRecordsEditsInTheWindowsList() async throws {
        // Turns red if EditorView.install stops handing the controller's EditLocations to a new editor, so the first
        // edit in a fresh tab is recorded in a list To Last Edit across files never reads.
        let a = try write("a.md", "alpha\n")
        let (model, controller) = await hostedModel(id: 14)
        await model.openInTab(a)
        let edited = await waitUntil(controller) { model.editor.replace(range: NSRange(location: 0, length: 0), with: "x") }
        XCTAssertTrue(edited)
        XCTAssertEqual(model.editor.editLocations.entries.map { $0.url?.lastPathComponent }, ["a.md"])
    }

    func testEditsAfterSwitchingBackReachTheParserOnce() async throws {
        // Turns red if an editor left over from an earlier visit to the tab keeps forwarding edits to the tab's parser,
        // which then holds each edit twice.
        let a = try write("a.md", "alpha\n"), b = try write("b.md", "beta\n")
        let (model, controller) = await hostedModel(id: 15)
        let caret = NSRange(location: 1, length: 0)
        await model.openInTab(a)
        let document = try XCTUnwrap(model.currentDocument)
        model.editor.show(range: caret, in: document, position: nil)
        let firstShown = await waitUntil(controller) { model.editor.selectedRanges == [caret] }
        await model.openInTab(b)
        let other = try XCTUnwrap(model.currentDocument)
        model.editor.show(range: NSRange(location: 2, length: 0), in: other, position: nil)
        let otherShown = await waitUntil(controller) { model.editor.selectedRanges == [NSRange(location: 2, length: 0)] }
        await model.openInTab(a)
        let parser = try XCTUnwrap(model.markdown)
        model.editor.show(range: caret, in: document, position: nil)
        let backShown = await waitUntil(controller) { model.editor.selectedRanges == [caret] }
        XCTAssertTrue(firstShown && otherShown && backShown)
        XCTAssertTrue(model.editor.replace(range: NSRange(location: 0, length: 0), with: "x"))
        let parsed = await parser.snapshot(atLeast: parser.version)
        XCTAssertEqual(document.text, "xalpha\n")
        XCTAssertEqual(parsed.text, document.text)
    }

    func testChangedHeadingsCoverTheirSections() async {
        // Turns red if WindowModel.changedHeadings stops marking a heading whose section (up to the next heading) holds
        // a git line mark, or marks one whose section has none.
        let text = "intro\n# One\nbody\n# Two\nbody\n# Three\nlast\n"
        let snapshot = await MarkdownDocument(text: text).currentSnapshot()
        let ids = snapshot.headings.map(\.blockID)
        XCTAssertEqual(ids.count, 3)
        let marks = [LineMark(line: 0, kind: .changed), LineMark(line: 4, kind: .added), LineMark(line: 6, kind: .deleted)]
        XCTAssertEqual(WindowModel.changedHeadings(snapshot.headings, text: text, marks: marks), [ids[1], ids[2]])
        XCTAssertEqual(WindowModel.changedHeadings(snapshot.headings, text: text, marks: [LineMark(line: 0, kind: .added)]), [])
    }

    func testBackupTabTitleAndShowFilesFocus() async throws {
        // Turns red if a backup tab loses its `<file> | <backup>` title (spec 886) or Show Files stops asking the Files
        // sidebar to take focus (spec 897).
        let a = try write("a.md", "alpha\n")
        let context = context()
        let model = WindowModel(id: 16, context: context)
        await model.setFolder(folder, prompt: false)
        await model.openInTab(a)
        try await context.backups.requestBackup(path: a.path, text: "alpha\n")
        try await context.backups.recordLineBreakInserted(path: a.path, text: "alpha\n")
        let backups = try await context.backups.list(for: a.path)
        let backup = try XCTUnwrap(backups.first)
        model.openBackup(backup)
        XCTAssertEqual(model.tabs.current?.title, "a.md | \(backup.friendlyDate)")

        model.sidebar.visible = false
        context.sidebarSections.toggleFold(.files)
        model.perform("window:sidebar")
        XCTAssertTrue(model.sidebar.visible)
        XCTAssertFalse(context.sidebarSections[.files].folded)
        XCTAssertTrue(model.sidebar.filesFocusRequested)
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

        // A sidebar dragged to 300 pt moves the editor by that much (docs/navigation-spec.md, Width).
        let wider = WindowLayout.compute(windowWidth: 800, screenWidth: 1680, sidebar: true, preview: .none, columnWidth: 562, sidebarWidth: 300)
        XCTAssertTrue(wider.compact)
        XCTAssertEqual(wider.editorX, 300)
        XCTAssertEqual(wider.columnWidth, 340)
    }

    func testMinimumWidth() {
        // Turns red if the minimum width stops doubling with a preview or adding the sidebar's width plus 60
        // (260 at the default width, spec 725, 1432).
        XCTAssertEqual(WindowModel.minimumWidth(sidebarWidth: nil, previewVisible: false), 400)
        XCTAssertEqual(WindowModel.minimumWidth(sidebarWidth: nil, previewVisible: true), 800)
        XCTAssertEqual(WindowModel.minimumWidth(sidebarWidth: 200, previewVisible: true), 1060)
        XCTAssertEqual(WindowModel.minimumWidth(sidebarWidth: 300, previewVisible: false), 760)
    }

    func testOldSidebarStateAndPinsInTheWindow() async throws {
        // Turns red if a sidebar-w<N> file from before sections stops loading, or the Recent and Pinned sections stop
        // listing the right files.
        let a = try write("a.md", "alpha"), b = try write("b.md", "beta")
        let context = context()
        try await context.store.save(WindowModel.sidebarName(23), "none")
        let model = WindowModel(id: 23, context: context)
        await model.restore()
        XCTAssertFalse(model.sidebar.visible)

        await model.setFolder(folder, prompt: false)
        await model.openInTab(a)
        await model.openInTab(b)
        XCTAssertEqual(model.recentFiles.map(\.lastPathComponent), ["a.md"])
        model.pin(a)
        XCTAssertEqual(model.pinnedFiles.map(\.lastPathComponent), ["a.md"])
        try model.sidebarActions.rename(a, "c.md")
        XCTAssertEqual(model.pinnedFiles.map(\.lastPathComponent), ["c.md"])
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

    func testShowMarkdownSourceTogglesAndIsSavedPerWindow() async throws {
        // Turns red if View > Show Markdown Source stops flipping the editor configuration and its check mark, or
        // stops being saved in `markdown-source-wN` and read back by `restore()`.
        let context = context()
        let model = WindowModel(id: 31, context: context)
        XCTAssertFalse(model.isOn("window:toggle-markdown-source"))
        XCTAssertFalse(model.configuration.showMarkdownSource)
        model.perform("window:toggle-markdown-source")
        XCTAssertTrue(model.isOn("window:toggle-markdown-source"))
        XCTAssertTrue(model.configuration.showMarkdownSource)
        var saved = false
        for _ in 0..<100 where !saved {
            saved = await context.store.load(WindowModel.markdownSourceName(31), as: Bool.self) == true
            if !saved { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(saved)
        let restored = WindowModel(id: 31, context: context)
        await restored.restore()
        XCTAssertTrue(restored.isOn("window:toggle-markdown-source"))
        XCTAssertTrue(restored.configuration.showMarkdownSource)
    }
}
