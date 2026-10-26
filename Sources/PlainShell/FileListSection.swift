import AppKit
import GitStatus
import PlainCore
import SwiftUI

/// What the Pinned and Recent sections ask the shell to do.
public struct FileListActions {
    public var open: (URL, _ newTab: Bool) -> Void
    public var pin: (URL) -> Void
    public var unpin: (URL) -> Void
    /// Dragging a pinned row: the file moves to this index.
    public var movePin: (URL, Int) -> Void
    public var revealInFinder: ([URL]) -> Void

    public init(
        open: @escaping (URL, Bool) -> Void, pin: @escaping (URL) -> Void, unpin: @escaping (URL) -> Void,
        movePin: @escaping (URL, Int) -> Void, revealInFinder: @escaping ([URL]) -> Void
    ) {
        self.open = open
        self.pin = pin
        self.unpin = unpin
        self.movePin = movePin
        self.revealInFinder = revealInFinder
    }
}

/// The Pinned or Recent section: one row per file, drawn like a file in the Files tree but without indent.
/// Click opens in place; Option+click or middle-click opens a new tab.
public struct FileListSection: View {
    let files: [URL]
    let currentFile: URL?
    let gitMarks: [URL: GitMark]
    /// Pinned rows offer Unpin and reorder by dragging; Recent rows offer Pin.
    let isPinned: Bool
    let actions: FileListActions

    static var dragPrefix: String { "plain-sidebar-pin:" }

    public init(files: [URL], currentFile: URL?, gitMarks: [URL: GitMark], isPinned: Bool, actions: FileListActions) {
        self.files = files
        self.currentFile = currentFile
        self.gitMarks = gitMarks
        self.isPinned = isPinned
        self.actions = actions
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.element) { index, url in
                    row(url, index: index)
                }
            }
        }
    }

    @ViewBuilder private func row(_ url: URL, index: Int) -> some View {
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let base = HStack(spacing: 0) {
            FileIcon(kind: OpenableFiles.fileKind(for: url)).padding(.trailing, 6)
            Text(url.deletingPathExtension().lastPathComponent).foregroundStyle(Color.secondaryText)
            Text(ext).foregroundStyle(Color.tertiaryText)
            Spacer(minLength: 4)
            GitMarkLabel(mark: gitMarks[url])
        }
        .font(uiFont)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, Tokens.rowPadding)
        .frame(height: Tokens.line)
        .background(url.standardizedFileURL == currentFile?.standardizedFileURL ? Color.selectionNeutral : .clear)
        .contentShape(Rectangle())
        .onTapGesture { actions.open(url, NSEvent.modifierFlags.contains(.option)) }
        .overlay(MiddleClickCatcher { actions.open(url, true) })
        .help(url.path)
        .contextMenu {
            if isPinned { Button("Unpin") { actions.unpin(url) } } else { Button("Pin") { actions.pin(url) } }
            Button("Show in Finder") { actions.revealInFinder([url]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions.open(url, false) }
        if isPinned {
            base
                .draggable(Self.dragPrefix + url.path)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, raw.hasPrefix(Self.dragPrefix) else { return false }
                    actions.movePin(URL(fileURLWithPath: String(raw.dropFirst(Self.dragPrefix.count))), index)
                    return true
                }
        } else {
            base
        }
    }
}
