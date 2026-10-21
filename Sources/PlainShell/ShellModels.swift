import Foundation
import Observation
import PlainCore
import PlainDocument

public enum PopupKind: Sendable {
    case files, headings, commands, recentFolders, backups, tabSwitcher, findInFolder
}

/// The open popup, its filter text and selected row.
@MainActor @Observable
public final class PopupState {
    public var active: PopupKind?
    public var filter = ""
    public var selection = 0

    public init() {}

    /// Opening clears the filter and selects the first row; opening the popup that is already open
    /// (its own shortcut again) moves to the next row.
    public func open(_ kind: PopupKind, filter: String = "") {
        if active == kind {
            selection += 1
            return
        }
        active = kind
        self.filter = filter
        selection = 0
    }

    public func close() {
        active = nil
        filter = ""
        selection = 0
    }
}

public enum SidebarMode: String, Codable, Sendable {
    case files, outline, none
}

/// Which sidebar shows, the one Show None brings back, and the expanded folders of the Files sidebar.
@MainActor @Observable
public final class SidebarState {
    public var mode: SidebarMode
    /// The sidebar `window:toggle-sidebar` re-shows.
    public var lastVisible: SidebarMode
    public var expandedFolders: Set<URL> = []

    public static let expansionStateName = "sidebar-expansion"

    public init(mode: SidebarMode = .files) {
        self.mode = mode
        self.lastVisible = mode == .none ? .files : mode
    }

    public func show(_ mode: SidebarMode) {
        self.mode = mode
        if mode != .none { lastVisible = mode }
    }

    /// Show None: hides the visible sidebar, or re-shows the last one.
    public func toggle() {
        mode = mode == .none ? lastVisible : .none
    }

    /// Reads the expanded folders from `state/sidebar-expansion.json`.
    public func loadExpansion(from store: StateStore) async {
        let paths: [String] = await store.load(Self.expansionStateName) ?? []
        expandedFolders = Set(paths.map { URL(fileURLWithPath: $0) })
    }

    public func saveExpansion(to store: StateStore) async throws {
        try await store.save(Self.expansionStateName, expandedFolders.map(\.path).sorted())
    }
}

/// A tab's mark before its name. The edited dot comes from `Document.isEdited`.
public enum TabMark: Sendable {
    case none
    /// The file is outside the window folder: `⇾` and a path tooltip.
    case outsideFolder
}

public struct TabItem: Identifiable {
    public let id: UUID
    public let document: Document
    public var mark: TabMark

    public init(id: UUID = UUID(), document: Document, mark: TabMark = .none) {
        self.id = id
        self.document = document
        self.mark = mark
    }
}

/// The window's open tabs and the current one.
@MainActor @Observable
public final class TabsState {
    public var items: [TabItem] = []
    public var currentID: TabItem.ID?

    public init() {}

    public var current: TabItem? { items.first { $0.id == currentID } }
}
