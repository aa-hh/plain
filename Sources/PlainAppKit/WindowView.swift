import AppKit
import EditorTextView
import MarkdownDocument
import PlainCore
import PlainShell
import PreviewRenderer
import SwiftUI
import UniformTypeIdentifiers

/// Where the window's parts go (spec 1205–1216, 1373–1440). All values in points from the window's left edge.
public struct WindowLayout: Equatable, Sendable {
    public var compact: Bool
    /// The editor area under the tab strip.
    public var editorX: CGFloat
    public var editorWidth: CGFloat
    /// The text column inside the editor area.
    public var columnX: CGFloat
    public var columnWidth: CGFloat
    public var previewX: CGFloat
    public var previewWidth: CGFloat
    /// The tab strip spans the editor side only.
    public var stripWidth: CGFloat

    /// `columnWidth` is the full column (`lineWidth` × width of "a"); it shrinks to the area minus 160 when needed.
    public static func compute(windowWidth: CGFloat, screenWidth: CGFloat, sidebar: Bool, preview: PreviewMode,
                               columnWidth: CGFloat, sidebarWidth: CGFloat = Tokens.sidebarWidth) -> WindowLayout {
        let previewWidth: CGFloat = preview == .split ? (windowWidth / 2 - (sidebar ? sidebarWidth / 2 : 0)) : 0
        let needed = 722 + sidebarWidth + previewWidth
        let free = screenWidth - needed
        let compact = sidebar && (windowWidth < needed || free < sidebarWidth)
        var shift: CGFloat = 0
        if sidebar {
            shift = compact ? sidebarWidth : min(max((screenWidth - windowWidth) * sidebarWidth / free, 0), sidebarWidth)
        }
        let editorWidth = max(windowWidth - previewWidth - shift, 0)
        let column = max(min(columnWidth, editorWidth - 2 * Tokens.editorSidePadding), 40)
        return WindowLayout(
            compact: compact, editorX: shift, editorWidth: editorWidth,
            columnX: shift + ((editorWidth - column) / 2).rounded(.down), columnWidth: column,
            previewX: windowWidth - previewWidth, previewWidth: previewWidth, stripWidth: windowWidth - previewWidth)
    }
}

/// One window's content: tab strip, sidebar, editor, preview, popups and overlays, stacked per spec 1440.
public struct WindowView: View {
    @Bindable var model: WindowModel

    public init(model: WindowModel) {
        self.model = model
    }

    /// `ceil(lineWidth × width of "a")` in the prose font, as the editor computes it.
    private var columnWidth: CGFloat {
        let configuration = model.configuration
        let a = NSAttributedString(string: "a", attributes: [.font: NSFont.systemFont(ofSize: configuration.fontSize)]).size().width
        return ceil(configuration.lineWidth * a)
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let layout = WindowLayout.compute(
                windowWidth: size.width, screenWidth: model.screenWidth, sidebar: model.sidebarVisible,
                preview: model.previewMode, columnWidth: columnWidth, sidebarWidth: model.sidebar.width)
            let strip = Tokens.tabStripHeight
            ZStack(alignment: .topLeading) {
                Color(nsColor: Tokens.material)

                editorArea
                    .frame(width: layout.editorWidth, height: max(size.height - strip, 0))
                    .offset(x: layout.editorX, y: strip)

                if let notification = model.notifications.last {
                    NotificationBar(notification: notification) { model.dismissNotification() }
                        .frame(width: layout.editorWidth)
                        .offset(x: layout.editorX, y: size.height - 32)
                }

                if model.statsVisible, model.currentDocument != nil {
                    let stats = model.statsText
                    TextStatsLabel(text: stats.text, isSelection: stats.isSelection, mode: model.statsMode) { mode in
                        model.context.setPreference("text-stats.type", .string(mode.rawValue))
                    }
                    .frame(width: layout.stripWidth - 20, height: size.height - 12, alignment: .bottomTrailing)
                }

                if model.sidebarVisible {
                    sidebarView(compact: layout.compact)
                        .frame(width: model.sidebar.width, height: max(size.height - strip, 0))
                        .offset(y: strip)
                }

                if model.previewMode == .split {
                    PreviewView(controller: model.preview)
                        .frame(width: layout.previewWidth, height: size.height)
                        .offset(x: layout.previewX)
                }

                if model.popup.active != nil {
                    popupView
                        .frame(width: layout.stripWidth)
                        .offset(y: 96)
                }

                if !model.interfaceHidden {
                    tabStrip.frame(width: layout.stripWidth, height: strip)
                }

                if let image = model.zoomImage {
                    ImageZoomOverlay(image: image) { model.zoomImage = nil }
                        .frame(width: size.width, height: size.height)
                }

                if model.previewMode == .full {
                    PreviewView(controller: model.preview)
                        .frame(width: size.width, height: size.height)
                }
            }
            .onChange(of: size.width) { model.updateMinimumWidth() }
        }
        .ignoresSafeArea()
        .preferredColorScheme(model.configuration.darkMode ? .dark : .light)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await model.openDropped(url) }
                }
            }
            return true
        }
        .onChange(of: model.editor.firstVisibleBlockID) { model.editorScrolled() }
        .onChange(of: model.editor.offsetWithinBlock) { model.editorScrolled() }
    }

    @ViewBuilder private var editorArea: some View {
        if let tab = model.tabs.current {
            if let backup = model.backupTab(tab.id) {
                BackupDiffView(lines: backup.lines, fontSize: model.configuration.fontSize,
                               lineHeight: model.configuration.linePoints, columnWidth: columnWidth)
            } else if let markdown = model.markdown {
                EditorView(
                    document: tab.document, markdown: markdown, configuration: model.configuration,
                    spellcheck: model.spellcheck, gitStatus: model.git, actions: model.editorActions,
                    controller: model.editor, splitPreviewShowing: model.previewMode == .split)
            }
        } else {
            EmptyWindowView()
        }
    }

    /// The sidebar's sections (docs/navigation-spec.md, The sidebar).
    private func sidebarView(compact: Bool) -> some View {
        @Bindable var sidebar = model.sidebar
        let pinned = model.pinnedFiles, recent = model.recentFiles
        let current = model.currentDocument?.url
        return Sidebar(
            sections: model.context.sidebarSections.items, titles: model.sidebarTitles(pinned: pinned, recent: recent),
            pinnedCount: pinned.count, recentCount: recent.count, width: sidebar.width, compact: compact,
            actions: model.sidebarSectionActions
        ) { kind in
            switch kind {
            case .pinned:
                FileListSection(files: pinned, currentFile: current, gitMarks: model.gitMarks, isPinned: true, actions: model.fileListActions)
            case .recent:
                FileListSection(files: recent, currentFile: current, gitMarks: model.gitMarks, isPinned: false, actions: model.fileListActions)
            case .files:
                if let tree = model.tree {
                    FilesSidebar(
                        root: tree, currentFile: current, gitMarks: model.gitMarks, expanded: $sidebar.expandedFolders,
                        actions: model.sidebarActions, focusRequested: $sidebar.filesFocusRequested)
                    .onChange(of: model.sidebar.expandedFolders) {
                        let sidebar = model.sidebar, store = model.context.store
                        Task { try? await sidebar.saveExpansion(to: store) }
                    }
                }
            case .outline:
                OutlineSidebar(
                    headings: model.snapshot?.headings ?? [], caretOffset: model.editor.selectedRanges.first?.location ?? 0,
                    changedHeadings: model.changedHeadings, focusRequested: $sidebar.outlineFocusRequested,
                    onJump: { heading, focus in model.jump(to: heading, focus: focus) })
            }
        }
    }

    private var tabStrip: some View {
        TabBar(
            tabs: model.tabs.items, currentID: model.tabs.currentID,
            actions: TabBarActions(
                select: { model.activate($0) },
                close: { model.closeTab($0) },
                closeOthers: { model.closeOtherTabs($0) },
                closeAll: { model.closeAllTabs() },
                move: { model.moveTab($0, to: $1) },
                showInFinder: { id in
                    if let url = model.tabs.items.first(where: { $0.id == id })?.document.url {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                },
                revertToBackup: { model.revertToBackup($0) },
                toggleZoom: { model.window?.zoom(nil) },
                goBack: { model.goBack(steps: $0) },
                goForward: { model.goForward(steps: $0) },
                pin: { id in if let url = model.tabs.items.first(where: { $0.id == id })?.document.url { model.pin(url) } }),
            showsEditedMark: { model.showsEditedMark($0) })
        .background(WindowDragArea())
    }

    @ViewBuilder private var popupView: some View {
        @Bindable var popup = model.popup
        switch popup.active {
        case .files:
            GoToFilePopup(
                recents: model.recentURLs, allFiles: model.allFiles, gitMarks: model.gitMarks,
                query: $popup.filter, selection: $popup.selection,
                onOpen: { url, newTab in model.closePopup(); model.open(url, newTab: newTab) }, onCancel: { model.closePopup() })
        case .headings:
            GoToHeadingPopup(
                headings: model.snapshot?.headings ?? [], query: $popup.filter, selection: $popup.selection,
                onPick: { heading in model.closePopup(); model.jump(to: heading, focus: true) }, onCancel: { model.closePopup() })
        case .commands:
            CommandsPopup(
                commands: model.commands, recent: model.commandHistory, isChecked: { model.isOn($0) },
                query: $popup.filter, selection: $popup.selection,
                onRun: { command in model.runCommand(command.id, true) }, onCancel: { model.closePopup() })
        case .recentFolders:
            RecentFoldersPopup(
                folders: model.recentFolders, currentFolder: model.folder, query: $popup.filter,
                selection: $popup.selection,
                onOpen: { url in model.closePopup(); Task { await model.setFolder(url) } }, onCancel: { model.closePopup() })
        case .backups:
            BackupsPopup(
                backups: model.backupsList, query: $popup.filter, selection: $popup.selection,
                onPick: { model.openBackup($0) }, onCancel: { model.closePopup() })
        case .tabSwitcher:
            TabSwitcherPopup(
                tabs: model.tabsByRecentUse, selection: $popup.selection,
                modifierFlags: model.modifierFlags.eraseToAnyPublisher(),
                onPick: { tab in model.closePopup(); model.activate(tab.id) }, onCancel: { model.closePopup() })
        case .findInFolder:
            if let folder = model.folder {
                FindInFolderPopup(
                    folder: folder, hits: model.searchHits, query: $popup.filter, selection: $popup.selection,
                    onPick: { model.openHit($0, newTab: $1) }, onCancel: { model.closePopup() })
                .onChange(of: model.popup.filter) { _, query in model.runSearch(query) }
            }
        case nil:
            EmptyView()
        }
    }
}

/// The tab strip's empty space moves the window (spec 829); tabs themselves take clicks first.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
