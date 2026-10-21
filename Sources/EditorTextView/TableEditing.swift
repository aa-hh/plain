import AppKit

/// A table read from the text: its lines and cells.
struct TextTable {
    struct Row {
        var line: NSRange
        /// Cell content ranges without the padding spaces.
        var cells: [NSRange]
        /// Ranges between pipes, padding included.
        var slots: [NSRange]
    }
    var rows: [Row]
    var dividerIndex: Int
    var leadingPipe: Bool
    var trailingPipe: Bool
    var alignments: [String]
}

/// Table helpers (spec 142–155).
extension EditorTextView {
    static let dividerRegex = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)

    private func isDivider(_ line: NSRange) -> Bool {
        let text = nsText.substring(with: line)
        guard text.contains("-") else { return false }
        return Self.dividerRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private func hasPipe(_ line: NSRange) -> Bool { nsText.substring(with: line).contains("|") }

    /// Splits a row into its cells at unescaped pipes.
    func row(_ line: NSRange) -> TextTable.Row {
        var slots: [NSRange] = []
        var start = line.location
        var index = line.location
        let end = NSMaxRange(line)
        while index < end {
            let c = nsText.character(at: index)
            if c == 92 { index += 2; continue }
            if c == 124 {
                slots.append(NSRange(location: start, length: index - start))
                start = index + 1
            }
            index += 1
        }
        slots.append(NSRange(location: start, length: end - start))
        let text = nsText.substring(with: line).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|"), !slots.isEmpty { slots.removeFirst() }
        if text.hasSuffix("|"), text.count > 1, !slots.isEmpty { slots.removeLast() }
        let cells = slots.map { slot -> NSRange in
            var s = slot.location, e = NSMaxRange(slot)
            while s < e, nsText.character(at: s) == 32 { s += 1 }
            while e > s, nsText.character(at: e - 1) == 32 { e -= 1 }
            return NSRange(location: s, length: e - s)
        }
        return TextTable.Row(line: line, cells: cells, slots: slots)
    }

    /// The complete table (header, divider, rows) holding `offset`.
    func table(at offset: Int) -> TextTable? {
        let current = lineContents(at: offset)
        guard hasPipe(current) || isDivider(current) else { return nil }
        var first = current
        while first.location > 0 {
            let above = lineContents(at: first.location - 1)
            guard hasPipe(above) else { break }
            first = above
        }
        var lines = [first]
        while NSMaxRange(lines.last!) < nsText.length {
            let below = lineContents(at: NSMaxRange(lines.last!) + 1)
            guard hasPipe(below) else { break }
            lines.append(below)
        }
        guard lines.count >= 2, isDivider(lines[1]) else { return nil }
        let headerText = nsText.substring(with: lines[0]).trimmingCharacters(in: .whitespaces)
        let rows = lines.map(row)
        let alignments = rows[1].cells.map { nsText.substring(with: $0) }.map { cell -> String in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return "center"
            case (true, false): return "left"
            case (false, true): return "right"
            default: return ""
            }
        }
        return TextTable(rows: rows, dividerIndex: 1, leadingPipe: headerText.hasPrefix("|"), trailingPipe: headerText.hasSuffix("|"),
                         alignments: alignments)
    }

    /// An empty row with cells as wide as the divider's.
    private func emptyRow(like table: TextTable) -> String {
        let divider = table.rows[table.dividerIndex]
        var parts = divider.slots.map { String(repeating: " ", count: max($0.length, 3)) }
        if parts.isEmpty { parts = ["   "] }
        return (table.leadingPipe ? "|" : "") + parts.joined(separator: "|") + (table.trailingPipe ? "|" : "")
    }

    // MARK: Enter (spec 146–148)

    func tableNewline(at offset: Int) -> Bool {
        guard isMarkdownFile else { return false }
        let line = lineContents(at: offset)
        let text = nsText.substring(with: line).trimmingCharacters(in: .whitespaces)
        if let table = table(at: offset) {
            guard let index = table.rows.firstIndex(where: { $0.line.location == line.location }), index > table.dividerIndex else { return false }
            let row = table.rows[index]
            if index == table.rows.count - 1, row.cells.allSatisfy({ $0.length == 0 }) {
                perform(line, "", caret: line.location)
                return true
            }
            let empty = emptyRow(like: table)
            let caretInCell = (table.leadingPipe ? 2 : 1)
            perform(NSRange(location: NSMaxRange(line), length: 0), "\n" + empty, caret: NSMaxRange(line) + 1 + caretInCell)
            return true
        }
        // A header row: a line that starts and ends with `|`, with no divider yet.
        guard offset == NSMaxRange(line), text.count > 1, text.hasPrefix("|"), text.hasSuffix("|") else { return false }
        if NSMaxRange(line) < nsText.length, isDivider(lineContents(at: NSMaxRange(line) + 1)) { return false }
        let header = row(line)
        let divider = "|" + header.slots.map { String(repeating: "-", count: max($0.length, 3)) }.joined(separator: "|") + "|"
        let empty = "|" + header.slots.map { String(repeating: " ", count: max($0.length, 3)) }.joined(separator: "|") + "|"
        let insertion = "\n" + divider + "\n" + empty
        let rowStart = NSMaxRange(line) + 1 + (divider as NSString).length + 1
        perform(NSRange(location: NSMaxRange(line), length: 0), insertion, caret: rowStart + 2)
        return true
    }

    // MARK: `|` after a table (spec 149)

    func tableTyped(_ c: String, at offset: Int) -> Bool {
        guard c == "|", isMarkdownFile, offset > 0 else { return false }
        let line = lineContents(at: offset)
        guard line.length == 0, line.location > 0, let table = table(at: line.location - 1) else { return false }
        let empty = emptyRow(like: table)
        perform(NSRange(location: offset, length: 0), empty, caret: offset + (table.leadingPipe ? 2 : 1))
        return true
    }

    // MARK: Tab between cells (spec 150)

    func tableTab(forward: Bool, selection: NSRange) -> Bool {
        guard isMarkdownFile, allSelections.count == 1, let table = table(at: selection.location) else { return false }
        if let snapshot, snapshot.block(at: selection.location)?.kind != .table { return false }
        var cells: [NSRange] = []
        var current: Int?
        for (index, row) in table.rows.enumerated() where index != table.dividerIndex {
            for slot in row.slots.indices {
                let cell = row.cells[slot]
                let slotRange = row.slots[slot]
                if selection.location >= slotRange.location, NSMaxRange(selection) <= NSMaxRange(slotRange) { current = cells.count }
                cells.append(cell)
            }
        }
        guard let current, !cells.isEmpty else { return false }
        let next = (current + (forward ? 1 : -1) + cells.count) % cells.count
        setSelectedRange(cells[next])
        return true
    }

    // MARK: Re-padding (spec 151)

    func tableAfterTyping() {
        guard isMarkdownFile, let offset = caret, let table = table(at: offset) else { return }
        guard let rowIndex = table.rows.firstIndex(where: { NSLocationInRange(offset, NSRange(location: $0.line.location, length: $0.line.length + 1)) }),
              rowIndex != table.dividerIndex else { return }
        let row = table.rows[rowIndex]
        guard let column = row.slots.firstIndex(where: { offset >= $0.location && offset <= NSMaxRange($0) }) else { return }
        let within = max(0, offset - row.cells[column].location)
        let count = table.rows.map(\.cells.count).max() ?? 0
        var widths = Array(repeating: 1, count: count)
        for (index, row) in table.rows.enumerated() where index != table.dividerIndex {
            for (c, cell) in row.cells.enumerated() { widths[c] = max(widths[c], nsText.substring(with: cell).count) }
        }
        var lines: [String] = []
        var caretInRow = 0
        for (index, row) in table.rows.enumerated() {
            var parts: [String] = []
            for c in 0..<count {
                if index == table.dividerIndex {
                    let alignment = c < table.alignments.count ? table.alignments[c] : ""
                    let dashes = widths[c] + 2 - (alignment == "center" ? 2 : alignment.isEmpty ? 0 : 1)
                    let body = String(repeating: "-", count: max(dashes, 1))
                    switch alignment {
                    case "center": parts.append(":" + body + ":")
                    case "left": parts.append(":" + body)
                    case "right": parts.append(body + ":")
                    default: parts.append(body)
                    }
                } else {
                    let text = c < row.cells.count ? nsText.substring(with: row.cells[c]) : ""
                    if index == rowIndex && c == column {
                        let before = (table.leadingPipe ? 1 : 0) + parts.reduce(0) { $0 + ($1 as NSString).length + 1 } + 1
                        caretInRow = before + min(within, (text as NSString).length)
                    }
                    parts.append(" " + text + String(repeating: " ", count: widths[c] - text.count) + " ")
                }
            }
            lines.append((table.leadingPipe ? "|" : "") + parts.joined(separator: "|") + (table.trailingPipe ? "|" : ""))
        }
        let whole = NSRange(location: table.rows[0].line.location, length: NSMaxRange(table.rows.last!.line) - table.rows[0].line.location)
        let replacement = lines.joined(separator: "\n")
        guard replacement != nsText.substring(with: whole) else { return }
        let rowStart = whole.location + lines[..<rowIndex].reduce(0) { $0 + ($1 as NSString).length + 1 }
        perform(whole, replacement, caret: rowStart + caretInRow)
    }
}
