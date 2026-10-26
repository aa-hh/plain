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

/// One window's sidebar: whether it shows, its width, the Files tree's expanded folders and focus requests.
/// The sections are app-wide, in `SidebarSections` (docs/navigation-spec.md, The sidebar).
@MainActor @Observable
public final class SidebarState {
    public var visible: Bool
    public var width: CGFloat
    public var expandedFolders: Set<URL> = []
    /// Set by Show Files; the Files section takes keyboard focus and clears it (spec 897).
    public var filesFocusRequested = false
    /// Set by Show Outline; the Outline section's filter takes keyboard focus and clears it (spec 921).
    public var outlineFocusRequested = false

    public static let expansionStateName = "sidebar-expansion"

    /// What `state/sidebar-w<N>.json` holds.
    public struct Saved: Codable, Equatable, Sendable {
        public var visible: Bool
        public var width: Double

        public init(visible: Bool, width: Double) {
            self.visible = visible
            self.width = width
        }
    }

    public init(visible: Bool = true, width: CGFloat = Tokens.sidebarWidth) {
        self.visible = visible
        self.width = width
    }

    public var saved: Saved { Saved(visible: visible, width: Double(width)) }

    public func apply(_ saved: Saved) {
        visible = saved.visible
        width = min(max(CGFloat(saved.width), Tokens.sidebarMinWidth), Tokens.sidebarMaxWidth)
    }

    /// A `sidebar-w<N>` file written before the sidebar had sections holds the mode string `files`, `outline` or
    /// `none`.
    public func apply(oldMode: String) {
        visible = oldMode != "none"
        width = Tokens.sidebarWidth
    }

    /// The width after dragging the sidebar's edge to `proposed`; nil when the drag closes it.
    public static func draggedWidth(_ proposed: CGFloat) -> CGFloat? {
        proposed < Tokens.sidebarCloseWidth ? nil : min(max(proposed, Tokens.sidebarMinWidth), Tokens.sidebarMaxWidth)
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

public enum SidebarSectionKind: String, Codable, Sendable, CaseIterable {
    case pinned, recent, files, outline

    /// The name in the headers' menu; the Files header itself shows the folder's name.
    public var title: String {
        switch self {
        case .pinned: "Pinned"
        case .recent: "Recent"
        case .files: "Files"
        case .outline: "Outline"
        }
    }
}

public struct SidebarSection: Codable, Equatable, Sendable {
    public var kind: SidebarSectionKind
    public var folded: Bool
    public var hidden: Bool

    public init(kind: SidebarSectionKind, folded: Bool = false, hidden: Bool = false) {
        self.kind = kind
        self.folded = folded
        self.hidden = hidden
    }
}

/// The sidebar's sections in order, with their fold and hidden state: one setting for the whole app, kept in
/// `state/sidebar-sections.json`.
@MainActor @Observable
public final class SidebarSections {
    public private(set) var items: [SidebarSection]

    public static let stateName = "sidebar-sections"

    public init(_ items: [SidebarSection] = SidebarSectionKind.allCases.map { SidebarSection(kind: $0) }) {
        self.items = Self.complete(items)
    }

    public subscript(kind: SidebarSectionKind) -> SidebarSection {
        items.first { $0.kind == kind } ?? SidebarSection(kind: kind)
    }

    public func toggleFold(_ kind: SidebarSectionKind) { change(kind) { $0.folded.toggle() } }
    public func setHidden(_ kind: SidebarSectionKind, _ hidden: Bool) { change(kind) { $0.hidden = hidden } }

    /// Show Files and Show Outline: the section shows and unfolds.
    public func reveal(_ kind: SidebarSectionKind) {
        change(kind) {
            $0.hidden = false
            $0.folded = false
        }
    }

    /// Dragging a header onto another: the dragged section takes the target's place.
    public func move(_ kind: SidebarSectionKind, before target: SidebarSectionKind) {
        guard kind != target, let from = items.firstIndex(where: { $0.kind == kind }) else { return }
        let section = items.remove(at: from)
        let to = items.firstIndex { $0.kind == target } ?? items.count
        items.insert(section, at: to)
    }

    private func change(_ kind: SidebarSectionKind, _ update: (inout SidebarSection) -> Void) {
        guard let index = items.firstIndex(where: { $0.kind == kind }) else { return }
        update(&items[index])
    }

    /// Keeps the first entry for each kind in its order and adds any kind the list lacks at the end.
    static func complete(_ items: [SidebarSection]) -> [SidebarSection] {
        var seen = Set<SidebarSectionKind>()
        let known = items.filter { seen.insert($0.kind).inserted }
        return known + SidebarSectionKind.allCases.filter { !seen.contains($0) }.map { SidebarSection(kind: $0) }
    }

    public func load(from store: StateStore) async {
        if let saved: [SidebarSection] = await store.load(Self.stateName) { items = Self.complete(saved) }
    }

    public func save(to store: StateStore) async throws {
        try await store.save(Self.stateName, items)
    }
}

/// Files pinned in the sidebar, per folder, shared by every window: `state/pins.json` holds
/// `{ "<folder path>": ["<file path>", …] }`.
@MainActor @Observable
public final class Pins {
    public private(set) var byFolder: [String: [String]]

    public static let stateName = "pins"

    public init(_ byFolder: [String: [String]] = [:]) {
        self.byFolder = byFolder
    }

    public func files(in folder: URL?) -> [URL] {
        guard let folder else { return [] }
        return (byFolder[folder.standardizedFileURL.path] ?? []).map { URL(fileURLWithPath: $0) }
    }

    public func contains(_ file: URL, in folder: URL?) -> Bool {
        guard let folder else { return false }
        return byFolder[folder.standardizedFileURL.path]?.contains(file.standardizedFileURL.path) ?? false
    }

    public func pin(_ file: URL, in folder: URL) {
        let key = folder.standardizedFileURL.path, path = file.standardizedFileURL.path
        if byFolder[key]?.contains(path) != true { byFolder[key, default: []].append(path) }
    }

    public func unpin(_ file: URL, in folder: URL) {
        byFolder[folder.standardizedFileURL.path]?.removeAll { $0 == file.standardizedFileURL.path }
    }

    /// Dragging a pinned row: the file moves to `index` in its folder's list.
    public func move(_ file: URL, to index: Int, in folder: URL) {
        let key = folder.standardizedFileURL.path, path = file.standardizedFileURL.path
        guard var list = byFolder[key], let from = list.firstIndex(of: path) else { return }
        list.remove(at: from)
        list.insert(path, at: min(max(index, 0), list.count))
        byFolder[key] = list
    }

    /// A file or folder renamed from `old` to `new`: pins at or under it follow, in every folder.
    public func rename(from old: String, to new: String) {
        for key in byFolder.keys {
            byFolder[key] = byFolder[key]?.map { $0 == old ? new : ($0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0) }
        }
    }

    /// Trashed files lose their pins.
    public func remove(under paths: [String]) {
        for key in byFolder.keys {
            byFolder[key]?.removeAll { pin in paths.contains { pin == $0 || pin.hasPrefix($0 + "/") } }
        }
    }

    public func load(from store: StateStore) async {
        if let saved: [String: [String]] = await store.load(Self.stateName) { byFolder = saved }
    }

    public func save(to store: StateStore) async throws {
        try await store.save(Self.stateName, byFolder)
    }
}

/// The Files and Outline sections draw their filter row only while it has focus or text; otherwise their rows sit
/// right under the header (docs/navigation-spec.md, The sidebar).
enum SectionFilter {
    static func isShown(focused: Bool, query: String) -> Bool { focused || !query.isEmpty }
}

/// A tab's mark before its name. The edited dot comes from `Document.isEdited`.
public enum TabMark: Sendable {
    case none
    /// The file is outside the window folder: `⇾` and a path tooltip.
    case outsideFolder
}

/// The files a tab showed before and after its current one, as paths, the nearest last in each list
/// (docs/navigation-spec.md, Back and forward).
public struct TabHistory: Codable, Equatable, Sendable {
    public static let limit = 50

    public var back: [String]
    public var forward: [String]

    public init(back: [String] = [], forward: [String] = []) {
        self.back = back
        self.forward = forward
    }

    /// Leaving `path` for another file in place: it goes on the back list and the forward list empties.
    public mutating func push(_ path: String) {
        back.append(path)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward = []
    }

    /// Moves `steps` entries back from `current`; returns the file to show, or nil when the list is shorter.
    public mutating func goBack(_ steps: Int = 1, from current: String) -> String? {
        Self.step(steps, from: current, taking: &back, giving: &forward)
    }

    public mutating func goForward(_ steps: Int = 1, from current: String) -> String? {
        Self.step(steps, from: current, taking: &forward, giving: &back)
    }

    private static func step(_ steps: Int, from current: String, taking source: inout [String], giving other: inout [String]) -> String? {
        guard steps >= 1, source.count >= steps else { return nil }
        let target = source[source.count - steps]
        other.append(current)
        other.append(contentsOf: source.suffix(steps - 1).reversed())
        source.removeLast(steps)
        if other.count > limit { other.removeFirst(other.count - limit) }
        return target
    }

    /// A file or folder renamed from `old` to `new`: entries at or under it follow.
    public mutating func rename(from old: String, to new: String) {
        func moved(_ path: String) -> String {
            if path == old { return new }
            return path.hasPrefix(old + "/") ? new + path.dropFirst(old.count) : path
        }
        back = back.map(moved)
        forward = forward.map(moved)
    }

    /// Drops every entry at or under one of `paths`.
    public mutating func remove(under paths: [String]) {
        func kept(_ path: String) -> Bool { !paths.contains { path == $0 || path.hasPrefix($0 + "/") } }
        back = back.filter(kept)
        forward = forward.filter(kept)
    }
}

public struct TabItem: Identifiable {
    public let id: UUID
    /// Replaced when a file opens in place (docs/navigation-spec.md).
    public var document: Document
    public var mark: TabMark
    /// Shown instead of the file name (a backup tab's `<file> | <backup>`, spec 886).
    public var title: String?
    public var history: TabHistory

    public init(id: UUID = UUID(), document: Document, mark: TabMark = .none, title: String? = nil, history: TabHistory = TabHistory()) {
        self.id = id
        self.document = document
        self.mark = mark
        self.title = title
        self.history = history
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
