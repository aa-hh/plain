import AppKit
import PlainCore
import PlainShell
import SwiftUI

/// The table grid: the selected cell's outline and the two `+` bars shown while the pointer is over a table.
@MainActor
final class TableGridController {
    var outline: NSView?
    /// The bar along the right edge; it adds a column.
    var columnBar: NSView?
    /// The bar along the bottom edge; it adds a row.
    var rowBar: NSView?
    /// The first line of the table the bars belong to.
    var tableStart: Int?
    /// The grid and both bars: the bars stay while the pointer is inside it.
    var zone: NSRect?
    /// Whether the edit and snapshot observers that keep the bars on their table are registered.
    var observing = false
}

/// The 2 pt `page-accent` outline round the cell holding the caret. It never takes clicks.
private final class TableGridOutline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let width = Tokens.page.cellOutline
        let path = NSBezierPath(rect: bounds.insetBy(dx: width / 2, dy: width / 2))
        path.lineWidth = width
        Tokens.page.accent.setStroke()
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A 12 pt `page-hover` bar with a centred Lucide `plus`.
private struct TableGridBar: View {
    let onAdd: () -> Void

    var body: some View {
        let page = Tokens.page
        ZStack {
            Rectangle().fill(Color(nsColor: page.hover))
            LucideIcon(name: "plus", size: page.addBar, colour: Color(nsColor: page.textTertiary))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onAdd)
    }
}

extension EditorTextView {
    /// A single click with no modifier in a page table row picks the cell under the pointer and drags a selection
    /// from there; every other click goes on to the usual handling.
    func tableGridMouseDown(_ event: NSEvent) -> Bool {
        guard event.clickCount == 1, event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard let (line, row, _) = tableGridRow(at: point), let first = row.columnEdges.first, let last = row.columnEdges.last else { return false }
        let x = point.x - columnLeft
        guard x >= first, x < last else { return false }
        let cells = HiddenRanges.cells(of: line, in: nsText)
        guard !cells.isEmpty else { return false }
        let column = row.columnEdges.lastIndex { $0 <= x } ?? 0
        let cell = cells[min(column, cells.count - 1)]
        let anchor = min(max(characterIndexForInsertion(at: point), cell.location), NSMaxRange(cell))
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        setSelectedRange(NSRange(location: anchor, length: 0))
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let index = characterIndexForInsertion(at: convert(next.locationInWindow, from: nil))
            setSelectedRange(NSRange(location: min(anchor, index), length: abs(index - anchor)))
            if next.type == .leftMouseUp { break }
        }
        return true
    }

    /// Shows the `+` bars along the right and bottom edges while the pointer is over a page table or its bars.
    func tableGridMouseMoved(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let zone = tableGrid.zone, zone.contains(point) { return }
        hideTableGridBars()
        guard let (line, _, _) = tableGridRow(at: point), let table = table(at: line.location), let firstRow = table.rows.first else { return }
        observeTableEdits()
        tableGrid.tableStart = firstRow.line.location
        placeTableGridBars()
    }

    /// Puts the bars along the right and bottom edges of the table at `tableGrid.tableStart` and sets their hover area
    /// from the table's current layout; hides them when no page grid is there any more.
    private func placeTableGridBars() {
        guard let start = tableGrid.tableStart, start < nsText.length, let table = table(at: start),
              let firstRow = table.rows.first, let lastRow = table.rows.last,
              let row = document.textStorage.attribute(.plainPageTableRow, at: firstRow.line.location, effectiveRange: nil) as? PageTableRow,
              let top = tableGridRowRect(firstRow.line), let bottom = tableGridRowRect(lastRow.line),
              let first = row.columnEdges.first, let last = row.columnEdges.last else { return hideTableGridBars() }
        let bar = Tokens.page.addBar
        let grid = NSRect(x: columnLeft + first, y: top.minY, width: last - first, height: bottom.maxY - top.minY)
        let right = NSRect(x: grid.maxX, y: grid.minY, width: bar, height: grid.height)
        let below = NSRect(x: grid.minX, y: grid.maxY, width: grid.width, height: bar)
        if tableGrid.columnBar == nil {
            let columnBar = NSHostingView(rootView: TableGridBar { [weak self] in self?.tableGridAddColumn() })
            addSubview(columnBar)
            tableGrid.columnBar = columnBar
        }
        if tableGrid.rowBar == nil {
            let rowBar = NSHostingView(rootView: TableGridBar { [weak self] in self?.tableGridAddRow() })
            addSubview(rowBar)
            tableGrid.rowBar = rowBar
        }
        tableGrid.columnBar?.frame = right
        tableGrid.rowBar?.frame = below
        tableGrid.tableStart = firstRow.line.location
        tableGrid.zone = grid.union(right).union(below)
    }

    /// Once per editor: keeps the bars' table start on its line through edits above it, and places the bars and the
    /// cell outline again from each new snapshot, so Tab adding a row, a bar's own edit or typing in a cell moves them
    /// with the table.
    private func observeTableEdits() {
        guard !tableGrid.observing else { return }
        tableGrid.observing = true
        editObservers.append { [weak self] edited, delta in
            guard let self, let start = self.tableGrid.tableStart else { return }
            self.tableGrid.tableStart = Self.map(NSRange(location: start, length: 0), location: edited.location,
                                                 oldLength: edited.length - delta, newLength: edited.length).location
        }
        snapshotObservers.append { [weak self] _ in
            guard let self else { return }
            if self.tableGrid.tableStart != nil { self.placeTableGridBars() }
            if self.tableGrid.outline != nil { self.tableGridSelectionMoved() }
        }
    }

    /// One caret in a page table cell gets the cell outline; anything else hides it.
    func tableGridSelectionMoved() {
        guard allSelections.count == 1, let caret = allSelections.first, caret.length == 0,
              let cell = tableGridCellRect(at: caret.location) else {
            tableGrid.outline?.removeFromSuperview()
            tableGrid.outline = nil
            return
        }
        if let outline = tableGrid.outline {
            outline.frame = cell
        } else {
            observeTableEdits()
            let outline = TableGridOutline(frame: cell)
            addSubview(outline)
            tableGrid.outline = outline
        }
    }

    /// Tab in the last cell of a page table adds a row and puts the caret in its first cell.
    func tableGridTab(forward: Bool) -> Bool {
        guard isPage, forward, allSelections.count == 1, let selection = allSelections.first,
              let table = table(at: selection.location),
              let lastIndex = table.rows.indices.last(where: { $0 != table.dividerIndex }) else { return false }
        let last = table.rows[lastIndex]
        guard last.line.location < nsText.length,
              document.textStorage.attribute(.plainPageTableRow, at: last.line.location, effectiveRange: nil) is PageTableRow,
              let slot = last.slots.last, selection.location >= slot.location, NSMaxRange(selection) <= NSMaxRange(slot) else { return false }
        let row = PageBlocks.addRow(table, text: nsText)
        apply(row.edits, caret: row.caret)
        return true
    }

    func closeTableGrid() {
        hideTableGridBars()
        tableGrid.outline?.removeFromSuperview()
        tableGrid.outline = nil
    }

    /// What the right bar does: a new column on the hovered table, as one undo step. The bars move with the table once
    /// the new snapshot is styled.
    func tableGridAddColumn() {
        guard let start = tableGrid.tableStart, let table = table(at: start) else { return }
        let column = PageBlocks.addColumn(table, text: nsText)
        apply(column.edits, caret: column.caret)
    }

    /// What the bottom bar does: a new row on the hovered table, as one undo step. The bars move with the table once
    /// the new snapshot is styled.
    func tableGridAddRow() {
        guard let start = tableGrid.tableStart, let table = table(at: start) else { return }
        let row = PageBlocks.addRow(table, text: nsText)
        apply(row.edits, caret: row.caret)
    }

    private func hideTableGridBars() {
        tableGrid.columnBar?.removeFromSuperview()
        tableGrid.rowBar?.removeFromSuperview()
        tableGrid.columnBar = nil
        tableGrid.rowBar = nil
        tableGrid.tableStart = nil
        tableGrid.zone = nil
    }

    /// The page table row under `point`: its line, its `PageTableRow` and its rect.
    private func tableGridRow(at point: NSPoint) -> (line: NSRange, row: PageTableRow, rect: NSRect)? {
        guard isPage, nsText.length > 0 else { return nil }
        let line = lineContents(at: characterIndexForInsertion(at: point))
        guard line.location < nsText.length,
              let row = document.textStorage.attribute(.plainPageTableRow, at: line.location, effectiveRange: nil) as? PageTableRow,
              let rect = tableGridRowRect(line), point.y >= rect.minY, point.y < rect.maxY else { return nil }
        return (line, row, rect)
    }

    /// The full-column rect of the line starting `line`, from its layout fragment (the box the grid lines are drawn in).
    private func tableGridRowRect(_ line: NSRange) -> NSRect? {
        guard let layoutManager = textLayoutManager, let storage = layoutManager.textContentManager as? NSTextContentStorage,
              let location = storage.location(storage.documentRange.location, offsetBy: line.location) else { return nil }
        layoutManager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
        let frame = fragment.layoutFragmentFrame
        return NSRect(x: columnLeft, y: textContainerOrigin.y + frame.minY, width: columnRight - columnLeft, height: frame.height)
    }

    /// The rect of the page table cell holding `offset`: its column's edges by its row's height.
    private func tableGridCellRect(at offset: Int) -> NSRect? {
        guard isPage else { return nil }
        let line = lineContents(at: offset)
        guard line.location < nsText.length,
              let row = document.textStorage.attribute(.plainPageTableRow, at: line.location, effectiveRange: nil) as? PageTableRow,
              let column = HiddenRanges.cells(of: line, in: nsText).firstIndex(where: { $0.location <= offset && offset <= NSMaxRange($0) }),
              column + 1 < row.columnEdges.count, let rect = tableGridRowRect(line) else { return nil }
        let edges = row.columnEdges
        return NSRect(x: columnLeft + edges[column], y: rect.minY, width: edges[column + 1] - edges[column], height: rect.height)
    }
}
