import AppKit
import FolderIndex
import GitStatus
import PlainCore
import SwiftUI

/// A 9 × 7 pixel drawing at the bottom-left of a 16 × 16 box, filled in the tertiary colour.
struct PixelIcon: View {
    let rows: [String]

    var body: some View {
        Canvas { context, size in
            let top = size.height - CGFloat(rows.count)
            for (y, row) in rows.enumerated() {
                for (x, pixel) in row.enumerated() where pixel == "1" {
                    context.fill(Path(CGRect(x: CGFloat(x), y: top + CGFloat(y), width: 1, height: 1)), with: .color(.tertiaryText))
                }
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// The five file icons: folder closed or open, text file, image, any other file.
struct FileIcon: View {
    let kind: FileKind
    var expanded = false

    static let folderClosed = ["111000000", "100111111", "100000001", "101010101", "101010101", "100000001", "111111111"]
    static let folderOpen = ["111000000", "111111111", "111111111", "111111111", "111111111", "111111111", "111111111"]
    static let text = ["111111111", "000000000", "111111000", "000000000", "111111111", "000000000", "111110000"]
    static let image = ["101010101", "010101010", "101010101", "010101010", "101010101", "010101010", "101010101"]
    static let other = ["101010101", "000000000", "101010101", "000000000", "101010101", "000000000", "101010101"]

    var body: some View {
        switch kind {
        case .folder: PixelIcon(rows: expanded ? Self.folderOpen : Self.folderClosed)
        case .text: PixelIcon(rows: Self.text)
        case .image: PixelIcon(rows: Self.image)
        case .other: PixelIcon(rows: Self.other)
        }
    }
}

/// A 9 × 7 box with `H1`…`H6` drawn in 3 × 5 pixel letters.
struct HeadingIcon: View {
    let level: Int

    static let glyphs: [Character: [String]] = [
        "H": ["101", "101", "111", "101", "101"],
        "1": ["010", "110", "010", "010", "111"],
        "2": ["111", "001", "111", "100", "111"],
        "3": ["111", "001", "011", "001", "111"],
        "4": ["101", "101", "111", "001", "001"],
        "5": ["111", "100", "111", "001", "111"],
        "6": ["111", "100", "111", "101", "111"],
    ]

    var body: some View {
        let h = Self.glyphs["H"]!
        let digit = Self.glyphs[Character(String(min(max(level, 1), 6)))]!
        let inner = (0..<5).map { h[$0] + "0" + digit[$0] }
        PixelIcon(rows: ["111111111"] + inner.map { "1" + $0 + "1" } + ["111111111"])
    }
}

/// A git mark after a row: `+` added, `~` changed, `D` deleted, `R` renamed.
struct GitMarkLabel: View {
    let mark: GitMark?

    var body: some View {
        switch mark {
        case .added: Text("+").foregroundStyle(Color.tertiaryText)
        case .changed: Text("~").foregroundStyle(Color.tertiaryText)
        case .deleted: Text("D").foregroundStyle(Color.tertiaryText)
        case .renamed: Text("R").foregroundStyle(Color.tertiaryText)
        case nil: EmptyView()
        }
    }
}

/// What the files sidebar asks the shell to do. Throwing closures report `FileOperationError`.
public struct FilesSidebarActions {
    public var open: (URL, _ newTab: Bool) -> Void
    public var createFile: (_ folder: URL, _ name: String) throws -> Void
    public var createFolder: (_ folder: URL, _ name: String) throws -> Void
    public var rename: (URL, _ name: String) throws -> Void
    /// Moves to the Trash after the sidebar's confirmation; the shell closes their tabs.
    public var trash: ([URL]) -> Void
    public var copy: ([URL]) -> Void
    public var cut: ([URL]) -> Void
    public var paste: (_ folder: URL) -> Void
    public var revealInFinder: ([URL]) -> Void
    public var focusEditor: () -> Void
    /// Pin in the sidebar's Pinned section.
    public var pin: (URL) -> Void

    public init(
        open: @escaping (URL, Bool) -> Void, createFile: @escaping (URL, String) throws -> Void,
        createFolder: @escaping (URL, String) throws -> Void, rename: @escaping (URL, String) throws -> Void,
        trash: @escaping ([URL]) -> Void, copy: @escaping ([URL]) -> Void, cut: @escaping ([URL]) -> Void,
        paste: @escaping (URL) -> Void, revealInFinder: @escaping ([URL]) -> Void, focusEditor: @escaping () -> Void,
        pin: @escaping (URL) -> Void = { _ in }
    ) {
        self.open = open
        self.createFile = createFile
        self.createFolder = createFolder
        self.rename = rename
        self.trash = trash
        self.copy = copy
        self.cut = cut
        self.paste = paste
        self.revealInFinder = revealInFinder
        self.focusEditor = focusEditor
        self.pin = pin
    }
}

/// The sidebar's Files section: a filter row with the folder name as placeholder, then the folder tree.
/// Folders show their children only while expanded; `expanded` is kept by `SidebarState`.
public struct FilesSidebar: View {
    let root: FolderNode
    let currentFile: URL?
    let gitMarks: [URL: GitMark]
    @Binding var expanded: Set<URL>
    let actions: FilesSidebarActions

    private enum InlineEdit: Equatable {
        case newFile(parent: URL, depth: Int)
        case newFolder(parent: URL, depth: Int)
        case rename(URL)
    }

    struct VisibleRow: Equatable {
        var node: FolderNode
        var depth: Int
    }

    @State private var query = ""
    @State private var filterSelection: TextSelection?
    @State private var selected = Set<URL>()
    @State private var cursor: URL?
    @State private var anchor: URL?
    @State private var edit: InlineEdit?
    @State private var editText = ""
    @State private var editSelection: TextSelection?
    @State private var pendingTrash: [URL] = []
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case filter, list, edit }

    /// Set by the shell to move keyboard focus into the list; cleared once taken.
    @Binding var focusRequested: Bool

    public init(
        root: FolderNode, currentFile: URL?, gitMarks: [URL: GitMark], expanded: Binding<Set<URL>>,
        actions: FilesSidebarActions, focusRequested: Binding<Bool> = .constant(false)
    ) {
        self.root = root
        self.currentFile = currentFile
        self.gitMarks = gitMarks
        self._expanded = expanded
        self.actions = actions
        self._focusRequested = focusRequested
    }

    /// Rows in display order: the expanded tree, or with a query every matching item at depth 0.
    static func visibleRows(root: FolderNode, expanded: Set<URL>, query: String) -> [VisibleRow] {
        var rows: [VisibleRow] = []
        func walk(_ nodes: [FolderNode], depth: Int) {
            for node in nodes {
                if query.isEmpty {
                    rows.append(VisibleRow(node: node, depth: depth))
                    if node.kind == .folder && expanded.contains(node.url) { walk(node.children, depth: depth + 1) }
                } else {
                    if fuzzyMatch(query: query, in: node.name) != nil { rows.append(VisibleRow(node: node, depth: 0)) }
                    walk(node.children, depth: 0)
                }
            }
        }
        walk(root.children, depth: 0)
        return rows
    }

    public var body: some View {
        let rows = Self.visibleRows(root: root, expanded: expanded, query: query)
        VStack(spacing: 0) {
            // The filter row shows only while it is in use; typing in the list starts it.
            if focus == .filter || !query.isEmpty {
                TextField("", text: $query, selection: $filterSelection, prompt: Text(root.name).foregroundStyle(Color.tertiaryText))
                    .textFieldStyle(.plain)
                    .font(uiFont)
                    .foregroundStyle(Color.textColor)
                    .help(root.url.path)
                    .focused($focus, equals: .filter)
                    .onKeyPress(phases: .down) { handleFilterKey($0, rows: rows) }
                    .padding(.horizontal, Tokens.rowPadding)
                    .frame(height: Tokens.line)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        if case .newFile(root.url, _) = edit { editRow(depth: 0, kind: .text) }
                        if case .newFolder(root.url, _) = edit { editRow(depth: 0, kind: .folder) }
                        ForEach(rows, id: \.node.url) { row in
                            rowView(row, rows: rows).id(row.node.url)
                            if case .newFile(row.node.url, let depth) = edit { editRow(depth: depth, kind: .text) }
                            if case .newFolder(row.node.url, let depth) = edit { editRow(depth: depth, kind: .folder) }
                        }
                    }
                    .padding(.bottom, Tokens.editorBottomPadding)
                }
                .onAppear { if let currentFile { proxy.scrollTo(currentFile) } }
                .onChange(of: cursor) { _, url in if let url { proxy.scrollTo(url) } }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .list)
            .onKeyPress(phases: .down) { handleListKey($0, rows: rows) }
            .contextMenu { emptyAreaMenu }
        }
        .task(id: focusRequested) {
            guard focusRequested else { return }
            focus = .list
            focusRequested = false
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } })) {
            Button("Move to Trash", role: .destructive) { actions.trash(pendingTrash); pendingTrash = [] }
            Button("Cancel", role: .cancel) { pendingTrash = [] }
        }
        .alert("Error renaming file", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Rows

    private func rowView(_ row: VisibleRow, rows: [VisibleRow]) -> some View {
        let node = row.node
        let isFolder = node.kind == .folder
        let ext = isFolder || node.url.pathExtension.isEmpty ? "" : "." + node.url.pathExtension
        let name = ext.isEmpty ? node.name : String(node.name.dropLast(ext.count))
        return HStack(spacing: 0) {
            FileIcon(kind: node.kind, expanded: expanded.contains(node.url))
            if edit == .rename(node.url) {
                editField
            } else {
                Text(name).foregroundStyle(Color.secondaryText)
                Text(ext).foregroundStyle(Color.tertiaryText)
            }
            Spacer(minLength: 4)
            GitMarkLabel(mark: gitMarks[node.url])
        }
        .font(uiFont)
        .lineLimit(1)
        .padding(.leading, Tokens.rowPadding + CGFloat(row.depth) * Tokens.levelIndent)
        .padding(.trailing, Tokens.rowPadding)
        .frame(height: Tokens.line)
        .background(rowBackground(node.url))
        .contentShape(Rectangle())
        .onTapGesture { click(node, rows: rows) }
        .overlay { if !isFolder { MiddleClickCatcher { actions.open(node.url, true) } } }
        .onDrag { NSItemProvider(object: node.url as NSURL) }
        .contextMenu { itemMenu(for: node) }
    }

    private func rowBackground(_ url: URL) -> Color {
        if focus == .list && selected.contains(url) { return .selectionBlue }
        if url == currentFile { return .selectionNeutral }
        return .clear
    }

    private func editRow(depth: Int, kind: FileKind) -> some View {
        HStack(spacing: 0) {
            FileIcon(kind: kind)
            editField
        }
        .font(uiFont)
        .padding(.leading, Tokens.rowPadding + CGFloat(depth) * Tokens.levelIndent)
        .padding(.trailing, Tokens.rowPadding)
        .frame(height: Tokens.line)
    }

    private var editField: some View {
        TextField("", text: $editText, selection: $editSelection)
            .textFieldStyle(.plain)
            .foregroundStyle(Color.textColor)
            .focused($focus, equals: .edit)
            .onSubmit(commitEdit)
            .onKeyPress(.escape) { cancelEdit(); return .handled }
            .onChange(of: focus) { old, new in if old == .edit && new != .edit { cancelEdit() } }
    }

    // MARK: Menus

    @ViewBuilder private func itemMenu(for node: FolderNode) -> some View {
        let targets = selected.contains(node.url) ? Array(selected) : [node.url]
        let folder = node.kind == .folder ? node.url : node.url.deletingLastPathComponent()
        Button("New File") { startNew(file: true, in: folder) }
        Button("New Folder") { startNew(file: false, in: folder) }
        Divider()
        Button("Cut") { actions.cut(targets) }
        Button("Copy") { actions.copy(targets) }
        Button("Paste") { actions.paste(folder) }
        Divider()
        if targets.count == 1 { Button("Rename") { startRename(node.url) } }
        Button("Delete") { pendingTrash = targets }
        Divider()
        if node.kind != .folder { Button("Pin") { actions.pin(node.url) } }
        Button("Show in Finder") { actions.revealInFinder(targets) }
    }

    @ViewBuilder private var emptyAreaMenu: some View {
        Button("New File") { startNew(file: true, in: root.url) }
        Button("New Folder") { startNew(file: false, in: root.url) }
        Button("Paste") { actions.paste(root.url) }
        Button("Show in Finder") { actions.revealInFinder([root.url]) }
    }

    private var trashTitle: String {
        pendingTrash.count == 1
            ? "Are you sure you want to delete \(pendingTrash[0].lastPathComponent)?"
            : "Are you sure you want to delete the selected items?"
    }

    // MARK: Actions

    private func click(_ node: FolderNode, rows: [VisibleRow]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor {
            select(range: anchor, to: node.url, rows: rows)
        } else if flags.contains(.command) {
            if !selected.insert(node.url).inserted { selected.remove(node.url) }
            anchor = node.url
        } else {
            selected = [node.url]
            anchor = node.url
            if node.kind == .folder {
                toggle(node.url)
            } else {
                actions.open(node.url, flags.contains(.option))
            }
        }
        cursor = node.url
        focus = .list
    }

    private func select(range from: URL, to: URL, rows: [VisibleRow]) {
        let urls = rows.map(\.node.url)
        guard let a = urls.firstIndex(of: from), let b = urls.firstIndex(of: to) else { return }
        selected = Set(urls[min(a, b)...max(a, b)])
    }

    private func toggle(_ url: URL) {
        if !expanded.insert(url).inserted { expanded.remove(url) }
    }

    /// The folder new items go into: the cursor folder, the cursor file's folder, or the root.
    private var targetFolder: URL {
        guard let cursor else { return root.url }
        return find(cursor, in: root)?.kind == .folder ? cursor : cursor.deletingLastPathComponent()
    }

    private func find(_ url: URL, in node: FolderNode) -> FolderNode? {
        if node.url == url { return node }
        for child in node.children { if let hit = find(url, in: child) { return hit } }
        return nil
    }

    private func depth(of folder: URL) -> Int {
        let rootCount = root.url.standardizedFileURL.pathComponents.count
        return folder.standardizedFileURL.pathComponents.count - rootCount
    }

    private func startNew(file: Bool, in folder: URL) {
        if folder != root.url { expanded.insert(folder) }
        let d = depth(of: folder)
        edit = file ? .newFile(parent: folder, depth: d) : .newFolder(parent: folder, depth: d)
        editText = ""
        editSelection = nil
        focus = .edit
    }

    private func startRename(_ url: URL) {
        let name = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        edit = .rename(url)
        editText = name
        editSelection = TextSelection(range: name.startIndex..<name.index(name.startIndex, offsetBy: stem.count))
        focus = .edit
    }

    private func cancelEdit() {
        guard edit != nil else { return }
        edit = nil
        focus = .list
    }

    private func commitEdit() {
        let name = editText
        let current = edit
        edit = nil
        focus = .list
        guard !name.isEmpty, let current else { return }
        do {
            switch current {
            case .newFile(let parent, _): try actions.createFile(parent, name)
            case .newFolder(let parent, _): try actions.createFolder(parent, name)
            case .rename(let url): if name != url.lastPathComponent { try actions.rename(url, name) }
            }
        } catch FileOperationError.renameClash {
            errorMessage = "File with the provided name already exists"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Keys

    private func handleFilterKey(_ press: KeyPress, rows: [VisibleRow]) -> KeyPress.Result {
        switch press.key {
        case .escape, .tab:
            if query.isEmpty { actions.focusEditor() } else { query = "" }
        case .downArrow:
            focus = .list
            moveCursor(1, extend: false, rows: rows)
        case .return:
            focus = .list
            if cursor == nil { cursor = rows.first?.node.url }
            openCursor(newTab: press.modifiers.contains(.command))
        case .delete where press.modifiers.contains(.command) && query.isEmpty:
            pendingTrash = Array(selected)
        default:
            return .ignored
        }
        return .handled
    }

    private func handleListKey(_ press: KeyPress, rows: [VisibleRow]) -> KeyPress.Result {
        let cmd = press.modifiers.contains(.command)
        let ctrl = press.modifiers.contains(.control)
        let shift = press.modifiers.contains(.shift)
        let f2 = KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))
        switch press.key {
        case .downArrow where cmd: openCursor(newTab: false)
        case .upArrow where cmd: collapseOrParent()
        case .downArrow: moveCursor(1, extend: shift, rows: rows)
        case .upArrow: moveCursor(-1, extend: shift, rows: rows)
        case KeyEquivalent("n") where ctrl: moveCursor(1, extend: false, rows: rows)
        case KeyEquivalent("p") where ctrl: moveCursor(-1, extend: false, rows: rows)
        case .home: setCursor(rows.first?.node.url)
        case .end: setCursor(rows.last?.node.url)
        case .rightArrow:
            guard let node = cursorNode else { return .handled }
            if node.kind == .folder { expanded.insert(node.url) } else { actions.open(node.url, false) }
        case .leftArrow: collapseOrParent()
        case .return: openCursor(newTab: cmd)
        case KeyEquivalent("n") where cmd: startNew(file: true, in: targetFolder)
        case .deleteForward: pendingTrash = Array(selected)
        case .delete where cmd && shift: pendingTrash = Array(selected)
        case .delete where cmd && query.isEmpty: pendingTrash = Array(selected)
        case KeyEquivalent("c") where cmd: actions.copy(Array(selected))
        case KeyEquivalent("x") where cmd: actions.cut(Array(selected))
        case KeyEquivalent("v") where cmd: actions.paste(targetFolder)
        case KeyEquivalent("r") where cmd: if let cursor { startRename(cursor) }
        case f2: if let cursor { startRename(cursor) }
        case .escape, .tab:
            if query.isEmpty { actions.focusEditor() } else { query = "" }
        default:
            guard !cmd, !ctrl, press.characters.count == 1, let character = press.characters.first,
                  character.isLetter || character.isNumber || character.isPunctuation || character.isSymbol else { return .ignored }
            query.append(character)
            filterSelection = TextSelection(insertionPoint: query.endIndex)
            // The filter row appears with this update; focus moves once it exists.
            DispatchQueue.main.async { focus = .filter }
        }
        return .handled
    }

    private var cursorNode: FolderNode? { cursor.flatMap { find($0, in: root) } }

    private func setCursor(_ url: URL?) {
        guard let url else { return }
        cursor = url
        anchor = url
        selected = [url]
    }

    private func moveCursor(_ step: Int, extend: Bool, rows: [VisibleRow]) {
        let urls = rows.map(\.node.url)
        guard !urls.isEmpty else { return }
        let index = cursor.flatMap { urls.firstIndex(of: $0) }.map { min(max($0 + step, 0), urls.count - 1) } ?? 0
        if extend, let anchor {
            cursor = urls[index]
            select(range: anchor, to: urls[index], rows: rows)
        } else {
            setCursor(urls[index])
        }
    }

    private func collapseOrParent() {
        guard let node = cursorNode else { return }
        if node.kind == .folder && expanded.contains(node.url) {
            expanded.remove(node.url)
        } else if node.url.deletingLastPathComponent() != root.url {
            setCursor(node.url.deletingLastPathComponent())
        }
    }

    private func openCursor(newTab: Bool) {
        let targets = newTab ? Array(selected) : (cursor.map { [$0] } ?? [])
        for url in targets {
            if find(url, in: root)?.kind == .folder { toggle(url) } else { actions.open(url, newTab) }
        }
    }
}
