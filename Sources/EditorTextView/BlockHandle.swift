import AppKit
import MarkdownDocument
import PlainCore
import PlainShell
import SwiftUI

/// The block handle (`+` and grip) beside the hovered block, the block menu, and block dragging.
@MainActor
final class BlockHandleController {
    /// The block under the pointer; nil while the handle is hidden.
    var hovered: PageBlock?
    var handle: NSView?
    var menu: NSView?
    var turnInto: NSView?
    /// The `page-hover` fill over the hovered block while the pointer is over the handle.
    var overlay: NSView?
    var dropLine: NSView?
    /// The "Copy" button at a code block's top right.
    var copyButton: NSView?
    /// Where a grip press started, in editor coordinates.
    var dragStart: NSPoint?
    var dragging = false
}

/// A filled rect over the text that lets clicks through to it.
private final class PageFillView: NSBox {
    convenience init(colour: NSColor) {
        self.init(frame: .zero)
        boxType = .custom
        borderWidth = 0
        titlePosition = .noTitle
        fillColor = colour
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A 24 × 24 handle box with an 18 pt icon that fills `page-hover` under the pointer.
private struct HandleBox: View {
    let icon: String
    @State private var hovered = false

    var body: some View {
        let page = Tokens.page
        LucideIcon(name: icon, size: page.handleIcon, colour: Color(nsColor: page.textTertiary))
            .frame(width: page.handleBox, height: page.handleBox)
            .background(RoundedRectangle(cornerRadius: page.handleBoxRadius).fill(hovered ? Color(nsColor: page.hover) : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

/// `+` then the grip.
private struct BlockHandleView: View {
    let onPlus: () -> Void
    let onGripChanged: () -> Void
    let onGripEnded: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HandleBox(icon: "plus").onTapGesture(perform: onPlus)
            HandleBox(icon: "grip-vertical")
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in onGripChanged() }.onEnded { _ in onGripEnded() })
        }
    }
}

/// The block menu: Turn into (only for blocks that hold text), Duplicate, Copy as Markdown, Delete.
private struct BlockMenuView: View {
    let showsTurnInto: Bool
    let onTurnInto: () -> Void
    let onDuplicate: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hovered: Int?

    var body: some View {
        let turnInto: [(icon: String, title: String, trailing: PageMenuRow.Trailing, action: () -> Void)] =
            showsTurnInto ? [("repeat-2", "Turn into", .chevron, onTurnInto)] : []
        let rows = turnInto + [
            ("copy", "Duplicate", .none, onDuplicate), ("clipboard-copy", "Copy as Markdown", .none, onCopy),
            ("trash-2", "Delete", .none, onDelete),
        ]
        PageMenuCard {
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    PageMenuRow(icon: rows[index].icon, title: rows[index].title, trailing: rows[index].trailing, highlighted: hovered == index)
                        .onHover { inside in
                            if inside { hovered = index } else if hovered == index { hovered = nil }
                        }
                        .onTapGesture(perform: rows[index].action)
                }
            }
            .padding(4)
        }
        .frame(width: Tokens.page.menuWidth)
    }

    static func height(showsTurnInto: Bool) -> CGFloat { (showsTurnInto ? 4 : 3) * Tokens.page.menuRow + 8 }
}

/// "Copy" in 12 pt `page-text-secondary`.
private struct CodeCopyButton: View {
    let onCopy: () -> Void

    var body: some View {
        Text("Copy")
            .font(.system(size: Tokens.page.codeHeaderSize))
            .foregroundStyle(Color(nsColor: Tokens.page.textSecondary))
            .padding(.horizontal, 4)
            .frame(height: 18)
            .contentShape(Rectangle())
            .onTapGesture(perform: onCopy)
    }
}

extension EditorTextView {
    // MARK: Hover

    func blockHandleMouseMoved(_ event: NSEvent) {
        let tools = blockHandle
        guard tools.menu == nil, !tools.dragging else { return }
        guard isPage, allSelections.count <= 1 else { return hideBlockHandle() }
        let point = convert(event.locationInWindow, from: nil)
        let left = columnLeft - 4 - 2 * Tokens.page.handleBox
        guard point.x >= left, point.x <= columnRight, bounds.contains(point) else { return hideBlockHandle() }
        // A parse is pending: keep what is shown until the snapshot arrives.
        guard let snapshot else { return }
        guard let block = hoveredBlock(at: point, snapshot: snapshot) else { return hideBlockHandle() }
        if block != tools.hovered || tools.handle?.isHidden != false { showBlockHandle(for: block) }
        tools.overlay?.isHidden = !(tools.handle?.frame.contains(point) ?? false)
    }

    /// The block whose own lines span the pointer's height; the deepest item wins.
    private func hoveredBlock(at point: NSPoint, snapshot: Snapshot) -> PageBlock? {
        let offset = characterIndexForInsertion(at: NSPoint(x: columnLeft, y: point.y))
        guard let block = PageBlocks.block(at: offset, snapshot: snapshot, text: nsText) else { return nil }
        let top = firstLineRect(of: block).minY
        let bottom = rect(forCharacterRange: NSRange(location: NSMaxRange(block.range), length: 0)).maxY
        return point.y >= top && point.y <= bottom ? block : nil
    }

    private func showBlockHandle(for block: PageBlock) {
        let tools = blockHandle
        let page = Tokens.page
        tools.hovered = block
        let first = firstLineRect(of: block)
        if tools.handle == nil {
            let host = NSHostingView(rootView: BlockHandleView(
                onPlus: { [weak self] in self?.blockHandlePlus() },
                onGripChanged: { [weak self] in self?.gripChanged() },
                onGripEnded: { [weak self] in self?.gripEnded() }))
            addSubview(host)
            tools.handle = host
            // Any text change makes the hovered block's ranges stale: hide the handle until the pointer moves again.
            editObservers.append { [weak self] _, _ in self?.hideBlockHandle() }
        }
        tools.handle?.frame = NSRect(x: columnLeft - 4 - 2 * page.handleBox, y: first.midY - page.handleBox / 2,
                                     width: 2 * page.handleBox, height: page.handleBox)
        tools.handle?.isHidden = false

        if tools.overlay == nil {
            let overlay = PageFillView(colour: page.hover)
            addSubview(overlay)
            tools.overlay = overlay
        }
        let bottom = rect(forCharacterRange: NSRange(location: NSMaxRange(block.fullRange), length: 0)).maxY
        tools.overlay?.frame = NSRect(x: columnLeft, y: first.minY, width: columnRight - columnLeft, height: max(bottom - first.minY, 0))
        tools.overlay?.isHidden = true

        guard block.kind == .code else {
            tools.copyButton?.isHidden = true
            return
        }
        if tools.copyButton == nil {
            let host = NSHostingView(rootView: CodeCopyButton(onCopy: { [weak self] in self?.copyHoveredCode() }))
            addSubview(host)
            tools.copyButton = host
        }
        if let button = tools.copyButton {
            let size = button.fittingSize
            button.frame = NSRect(x: columnRight - page.codePadSides - size.width, y: first.minY + page.codePadTop, width: size.width, height: size.height)
            button.isHidden = false
        }
    }

    private func hideBlockHandle() {
        let tools = blockHandle
        tools.hovered = nil
        tools.handle?.isHidden = true
        tools.overlay?.isHidden = true
        tools.copyButton?.isHidden = true
        tools.dropLine?.isHidden = true
    }

    func blockHandleSelectionMoved() {
        closeBlockMenu()
        if allSelections.count > 1 { hideBlockHandle() }
    }

    func closeBlockHandle() {
        closeBlockMenu()
        hideBlockHandle()
        blockHandle.dragStart = nil
        blockHandle.dragging = false
    }

    /// The block at the handle's line, found again in the current snapshot so an edit since the hover cannot leave it
    /// stale; nil while a parse is pending or before the handle was ever shown.
    private func handleBlock() -> PageBlock? {
        guard let handle = blockHandle.handle, let snapshot else { return nil }
        let offset = characterIndexForInsertion(at: NSPoint(x: columnLeft, y: handle.frame.midY))
        return PageBlocks.block(at: offset, snapshot: snapshot, text: nsText)
    }

    private func copyHoveredCode() {
        guard let block = blockHandle.hovered, let snapshot else { return }
        let string = VisibleText.plain(text: nsText, snapshot: snapshot, range: block.fullRange, columnWidth: styler.pageColumnWidth)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: Plus

    /// Adds an empty line below the hovered block and opens the `/` menu on it.
    func blockHandlePlus() {
        guard let block = handleBlock() else { return }
        let at = NSMaxRange(block.fullRange)
        closeBlockHandle()
        apply([TextEdit(range: NSRange(location: at, length: 0), replacement: "\n\n")], caret: at + 2)
        openSlashMenu(atEmptyLine: at + 2)
    }

    // MARK: Dragging

    private var pointer: NSPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func gripChanged() {
        guard let point = pointer else { return }
        let tools = blockHandle
        guard let start = tools.dragStart else {
            tools.dragStart = point
            return
        }
        if !tools.dragging, hypot(point.x - start.x, point.y - start.y) >= 3 {
            tools.dragging = true
            closeBlockMenu()
        }
        if tools.dragging { showDropLine(at: dropTarget(at: point).y) }
    }

    private func gripEnded() {
        let tools = blockHandle
        let dragged = tools.dragging
        tools.dragStart = nil
        tools.dragging = false
        tools.dropLine?.isHidden = true
        if !dragged {
            openBlockMenu()
        } else if let point = pointer {
            blockHandleDrop(at: point)
        }
    }

    /// The block whose top is nearest `point`, or nil for after the last block, with the y of that edge.
    private func dropTarget(at point: NSPoint) -> (target: PageBlock?, y: CGFloat) {
        let blocks = pageBlocks()
        // Only blocks on screen can be under the pointer; this keeps layout to the visible text.
        // The top padding is above every line, where `characterIndexForInsertion` answers the text end.
        let low = characterIndexForInsertion(at: NSPoint(x: columnLeft, y: max(visibleRect.minY, textContainerOrigin.y)))
        let high = characterIndexForInsertion(at: NSPoint(x: columnLeft, y: visibleRect.maxY))
        var best: (target: PageBlock?, y: CGFloat)?
        for block in blocks where NSMaxRange(block.fullRange) >= low && block.range.location <= high {
            let y = firstLineRect(of: block).minY
            if best == nil || abs(y - point.y) < abs(best!.y - point.y) { best = (block, y) }
        }
        if let end = blocks.map({ NSMaxRange($0.fullRange) }).max() {
            let y = rect(forCharacterRange: NSRange(location: end, length: 0)).maxY
            if best == nil || abs(y - point.y) < abs(best!.y - point.y) { best = (nil, y) }
        }
        return best ?? (nil, 0)
    }

    private func showDropLine(at y: CGFloat) {
        let tools = blockHandle
        if tools.dropLine == nil {
            let line = PageFillView(colour: Tokens.page.accent)
            addSubview(line)
            tools.dropLine = line
        }
        let height = Tokens.page.dropLine
        tools.dropLine?.frame = NSRect(x: columnLeft, y: y - height / 2, width: columnRight - columnLeft, height: height)
        tools.dropLine?.isHidden = false
    }

    /// Moves the hovered block (with its nested items) to the block edge nearest `point`; a drop onto itself does nothing.
    func blockHandleDrop(at point: NSPoint) {
        guard let block = handleBlock() else { return }
        let change = PageBlocks.move(block, before: dropTarget(at: point).target, text: nsText)
        closeBlockHandle()
        guard !change.edits.isEmpty else { return }
        apply(change.edits, caret: change.caret)
    }

    // MARK: Block menu

    func openBlockMenu() {
        closeBlockMenu()
        guard let handle = blockHandle.handle, let block = handleBlock() else { return }
        let box = Tokens.page.handleBox
        let grip = NSRect(x: handle.frame.maxX - box, y: handle.frame.minY, width: box, height: box)
        let showsTurnInto = block.kind.canTurnInto
        let view = BlockMenuView(showsTurnInto: showsTurnInto,
                                 onTurnInto: { [weak self] in self?.openTurnIntoList() },
                                 onDuplicate: { [weak self] in self?.blockMenuDuplicate() },
                                 onCopy: { [weak self] in self?.blockMenuCopyMarkdown() },
                                 onDelete: { [weak self] in self?.blockMenuDelete() })
        blockHandle.menu = showPageTool(view, size: NSSize(width: Tokens.page.menuWidth, height: BlockMenuView.height(showsTurnInto: showsTurnInto)),
                                        below: grip, above: grip)
    }

    private func closeBlockMenu() {
        blockHandle.menu?.removeFromSuperview()
        blockHandle.menu = nil
        blockHandle.turnInto?.removeFromSuperview()
        blockHandle.turnInto = nil
    }

    private func openTurnIntoList() {
        guard let menu = blockHandle.menu, let block = handleBlock(), block.kind.canTurnInto else { return }
        blockHandle.turnInto?.removeFromSuperview()
        let page = Tokens.page
        let x = menu.frame.maxX + 4
        let list = TurnIntoList(current: block.kind) { [weak self] kind in self?.blockMenuTurnInto(kind) }
        blockHandle.turnInto = showPageTool(list, size: NSSize(width: page.menuWidth, height: CGFloat(PageBlockKind.turnIntoKinds.count) * page.menuRow + 8),
                                            below: NSRect(x: x, y: menu.frame.minY, width: 0, height: 0),
                                            above: NSRect(x: x, y: menu.frame.maxY, width: 0, height: 0))
    }

    func blockMenuDuplicate() { blockMenuEdit { PageBlocks.duplicate($0, text: $1) } }

    func blockMenuDelete() { blockMenuEdit { PageBlocks.delete($0, text: $1) } }

    func blockMenuTurnInto(_ kind: PageBlockKind) { blockMenuEdit { PageBlocks.turnInto($0, to: kind, text: $1) } }

    /// Puts the raw Markdown lines of the hovered block (with nested items) on the pasteboard.
    func blockMenuCopyMarkdown() {
        guard let block = handleBlock() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nsText.substring(with: block.fullRange), forType: .string)
        closeBlockHandle()
    }

    private func blockMenuEdit(_ make: (PageBlock, NSString) -> (edits: [TextEdit], caret: Int?)) {
        guard let block = handleBlock() else { return }
        let change = make(block, nsText)
        closeBlockHandle()
        apply(change.edits, caret: change.caret)
    }
}
