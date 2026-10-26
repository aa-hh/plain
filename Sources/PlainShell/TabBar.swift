import AppKit
import PlainCore
import PlainDocument
import SwiftUI

/// What the tab bar asks the shell to do.
public struct TabBarActions {
    public var select: (TabItem.ID) -> Void
    public var close: (TabItem.ID) -> Void
    public var closeOthers: (TabItem.ID) -> Void
    public var closeAll: () -> Void
    /// Drag to reorder: move the tab to this index.
    public var move: (TabItem.ID, Int) -> Void
    public var showInFinder: (TabItem.ID) -> Void
    public var revertToBackup: (TabItem.ID) -> Void
    /// Double-click on the empty bar.
    public var toggleZoom: () -> Void
    /// The arrows and their menus: go this many entries back or forward in the current tab.
    public var goBack: (Int) -> Void
    public var goForward: (Int) -> Void
    /// Pin in Sidebar.
    public var pin: (TabItem.ID) -> Void

    public init(
        select: @escaping (TabItem.ID) -> Void, close: @escaping (TabItem.ID) -> Void,
        closeOthers: @escaping (TabItem.ID) -> Void, closeAll: @escaping () -> Void,
        move: @escaping (TabItem.ID, Int) -> Void, showInFinder: @escaping (TabItem.ID) -> Void,
        revertToBackup: @escaping (TabItem.ID) -> Void, toggleZoom: @escaping () -> Void,
        goBack: @escaping (Int) -> Void = { _ in }, goForward: @escaping (Int) -> Void = { _ in },
        pin: @escaping (TabItem.ID) -> Void = { _ in }
    ) {
        self.select = select
        self.close = close
        self.closeOthers = closeOthers
        self.closeAll = closeAll
        self.move = move
        self.showInFinder = showInFinder
        self.revertToBackup = revertToBackup
        self.toggleZoom = toggleZoom
        self.goBack = goBack
        self.goForward = goForward
        self.pin = pin
    }
}

/// The 48 pt tab strip: one centred row with 80 pt side padding, tabs up to 200 pt wide. The window drags by
/// the empty strip (the shell sets `isMovableByWindowBackground` and the strip's span).
public struct TabBar: View {
    let tabs: [TabItem]
    let currentID: TabItem.ID?
    let actions: TabBarActions
    /// Whether a tab shows the edited dot; the shell hides it while autosave covers the file.
    let showsEditedMark: (TabItem) -> Bool

    public init(tabs: [TabItem], currentID: TabItem.ID?, actions: TabBarActions,
                showsEditedMark: @escaping (TabItem) -> Bool = { $0.document.isEdited }) {
        self.tabs = tabs
        self.currentID = currentID
        self.actions = actions
        self.showsEditedMark = showsEditedMark
    }

    /// A file name of the form `2026-03-12` shown as a medium date; other names unchanged.
    public static func friendlyName(_ name: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard name.count == 10, let date = parser.date(from: name) else { return name }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// How many entries an arrow's menu lists, newest first.
    public static let arrowMenuLimit = 15

    public var body: some View {
        let history = tabs.first(where: { $0.id == currentID })?.history
        HStack(spacing: 0) {
            // The arrows sit at the strip's left; the same width kept on the right keeps the tabs centred.
            if let history {
                arrow("arrow-left", name: "Back", shortcut: "⌘[", entries: history.back, go: actions.goBack)
                arrow("arrow-right", name: "Forward", shortcut: "⌘]", entries: history.forward, go: actions.goForward)
                    .padding(.trailing, 10)
            }
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    tabView(tab)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
                            actions.move(id, index)
                            return true
                        }
                }
            }
            .frame(maxWidth: .infinity)
            if history != nil { Color.clear.frame(width: 58, height: 1) }
        }
        .padding(.top, 9)
        .padding(.horizontal, Tokens.editorSidePadding)
        .frame(maxWidth: .infinity, minHeight: Tokens.tabStripHeight, maxHeight: Tokens.tabStripHeight, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.toggleZoom() }
    }

    private func tabView(_ tab: TabItem) -> some View {
        let isCurrent = tab.id == currentID
        let document = tab.document
        let colour = isCurrent ? Color.secondaryText : Color.tertiaryText
        let ext = document.fileExtension.isEmpty || document.isBackupTab || tab.title != nil ? "" : "." + document.fileExtension
        return HStack(spacing: 5) {
            if tab.mark == .outsideFolder { Text("⇾") }
            HStack(spacing: 0) {
                Text(tab.title ?? Self.friendlyName(document.displayName))
                Text(ext).foregroundStyle(Color.tertiaryText)
            }
            if showsEditedMark(tab) { Text("•") }
        }
        .font(uiFont)
        .foregroundStyle(colour)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.vertical, 3)
        .padding(.horizontal, 10)
        .frame(maxWidth: 200)
        .frame(height: 30)
        .help(tab.mark == .outsideFolder ? document.url?.path ?? "" : "")
        .contentShape(Rectangle())
        .onTapGesture { actions.select(tab.id) }
        .overlay(MiddleClickCatcher { actions.close(tab.id) })
        .draggable(tab.id.uuidString)
        .contextMenu {
            Button("Close Tab") { actions.close(tab.id) }
            Button("Close Other Tabs") { actions.closeOthers(tab.id) }
            Button("Close All Tabs") { actions.closeAll() }
            Divider()
            Button("Move to the Left") { moveBy(tab, -1) }
            Button("Move to the Right") { moveBy(tab, 1) }
            Divider()
            Button("Show in Finder") { actions.showInFinder(tab.id) }
            if !document.isBackupTab, document.url != nil, tab.mark != .outsideFolder {
                Button("Pin in Sidebar") { actions.pin(tab.id) }
            }
            if document.isBackupTab { Button("Revert to This") { actions.revertToBackup(tab.id) } }
        }
    }

    /// A back or forward arrow: drawn only when its list has entries, but its 24 pt always kept so tabs never shift.
    private func arrow(_ icon: String, name: String, shortcut: String, entries: [String], go: @escaping (Int) -> Void) -> some View {
        let next = entries.last.map { URL(fileURLWithPath: $0).lastPathComponent }
        let menu = Array(entries.reversed().prefix(Self.arrowMenuLimit))
        return LucideIcon(name: icon)
            .frame(width: 24, height: 30)
            .opacity(next == nil ? 0 : 1)
            .contentShape(Rectangle())
            .allowsHitTesting(next != nil)
            .onTapGesture { go(1) }
            .help(next.map { "\(name) to \($0) (\(shortcut))" } ?? "")
            .contextMenu {
                ForEach(Array(menu.enumerated()), id: \.offset) { index, path in
                    Button(URL(fileURLWithPath: path).lastPathComponent) { go(index + 1) }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityValue(next ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { go(1) }
            .accessibilityHidden(next == nil)
    }

    private func moveBy(_ tab: TabItem, _ step: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let target = index + step
        if tabs.indices.contains(target) { actions.move(tab.id, target) }
    }
}

/// Receives middle clicks only; every other event passes through to the views below.
struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    final class CatcherView: NSView {
        var action: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .otherMouseDown || NSApp.currentEvent?.type == .otherMouseUp
                ? super.hitTest(point) : nil
        }
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { action() }
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }
}
