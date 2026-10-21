import AppKit

/// The last 10 edit locations, across files (spec 292). A window shares one between its editors.
@MainActor
public final class EditLocations {
    public struct Entry: Equatable {
        public var url: URL?
        public var offset: Int
    }
    public private(set) var entries: [Entry] = []
    /// Where To Last Edit / To Next Edit stands; nil after a new edit.
    var index: Int?

    public init() {}

    /// Records an edit; an edit on the same line as the newest entry replaces it.
    func record(url: URL?, offset: Int, sameLine: Bool) {
        if let last = entries.last, last.url == url, sameLine {
            entries[entries.count - 1].offset = offset
        } else {
            entries.append(Entry(url: url, offset: offset))
            if entries.count > 10 { entries.removeFirst() }
        }
        index = nil
    }

    func step(back: Bool, from current: Entry) -> Entry? {
        guard !entries.isEmpty else { return nil }
        var i: Int
        if let index {
            i = back ? index - 1 : index + 1
        } else {
            guard back else { return nil }
            i = entries.count - 1
            if entries[i] == current { i -= 1 }
        }
        guard entries.indices.contains(i) else { return nil }
        index = i
        return entries[i]
    }
}

/// Line commands and other edit commands (spec 281–296).
extension EditorTextView {
    func performLineCommand(_ id: String) -> Bool {
        switch id {
        case "editor:move-line-up": moveLines(up: true)
        case "editor:move-line-down": moveLines(up: false)
        case "editor:duplicate-line": duplicateLines()
        case "editor:delete-line": deleteLines()
        case "editor:toggle-case": toggleCase()
        case "editor:last-edit": goToEdit(back: true)
        case "editor:next-edit": goToEdit(back: false)
        default: return false
        }
        return true
    }

    /// Groups of whole lines touched by the selections: (first line start, last line contents end).
    private func lineBlocks() -> [NSRange] {
        var blocks: [NSRange] = []
        for selection in allSelections {
            let lines = linesTouched(by: selection)
            guard let first = lines.first, let last = lines.last else { continue }
            let block = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
            if let previous = blocks.last, block.location <= NSMaxRange(previous) + 1 {
                blocks[blocks.count - 1] = NSUnionRange(previous, block)
            } else {
                blocks.append(block)
            }
        }
        return blocks
    }

    /// Moves every line touched by a selection up or down one line; ordered lists renumber (spec 284).
    func moveLines(up: Bool) {
        var edits: [(range: NSRange, text: String)] = []
        var shifts: [(block: NSRange, delta: Int)] = []
        for block in lineBlocks() {
            let text = nsText.substring(with: block)
            if up {
                guard block.location > 0 else { continue }
                let above = lineContents(at: block.location - 1)
                let aboveText = nsText.substring(with: above)
                edits.append((NSRange(location: above.location, length: NSMaxRange(block) - above.location), text + "\n" + aboveText))
                shifts.append((block, -(above.length + 1)))
            } else {
                guard NSMaxRange(block) < nsText.length else { continue }
                let below = lineContents(at: NSMaxRange(block) + 1)
                let belowText = nsText.substring(with: below)
                edits.append((NSRange(location: block.location, length: NSMaxRange(below) - block.location), belowText + "\n" + text))
                shifts.append((block, below.length + 1))
            }
        }
        guard !edits.isEmpty else { return }
        let selections = allSelections.map { range -> NSRange in
            guard let shift = shifts.first(where: { NSLocationInRange(range.location, NSRange(location: $0.block.location, length: $0.block.length + 1)) }) else { return range }
            return NSRange(location: range.location + shift.delta, length: range.length)
        }
        perform(edits, select: selections)
        listRenumberAround(selections.first?.location ?? 0)
    }

    /// Copies the touched lines below; the selection follows the copy (spec 285).
    func duplicateLines() {
        var edits: [(range: NSRange, text: String)] = []
        var shift = 0
        var selections: [NSRange] = []
        let blocks = lineBlocks()
        for block in blocks {
            edits.append((NSRange(location: NSMaxRange(block), length: 0), "\n" + nsText.substring(with: block)))
        }
        for range in allSelections {
            let index = blocks.firstIndex { NSLocationInRange(range.location, NSRange(location: $0.location, length: $0.length + 1)) } ?? 0
            shift = blocks[..<index].reduce(0) { $0 + $1.length + 1 }
            selections.append(NSRange(location: range.location + shift + blocks[index].length + 1, length: range.length))
        }
        perform(edits, select: selections)
    }

    func deleteLines() {
        var edits: [(range: NSRange, text: String)] = []
        var carets: [NSRange] = []
        var removed = 0
        for block in lineBlocks() {
            var range = block
            if NSMaxRange(range) < nsText.length { range.length += 1 } else if range.location > 0 { range.location -= 1; range.length += 1 }
            edits.append((range, ""))
            carets.append(NSRange(location: min(block.location - removed, nsText.length - removed - range.length), length: 0))
            removed += range.length
        }
        perform(edits, select: carets.map { NSRange(location: max($0.location, 0), length: 0) })
    }

    /// Lower case when the text has any capital, else upper case; the word at the caret when nothing is selected.
    func toggleCase() {
        var edits: [(range: NSRange, text: String)] = []
        var selections: [NSRange] = []
        for range in allSelections {
            let target = range.length > 0 ? range : wordRange(at: range.location)
            guard target.length > 0 else { selections.append(range); continue }
            let text = nsText.substring(with: target)
            let changed = text.contains(where: \.isUppercase) ? text.lowercased() : text.uppercased()
            edits.append((target, changed))
            selections.append(range.length > 0 ? NSRange(location: range.location, length: (changed as NSString).length) : range)
        }
        perform(edits, select: selections)
    }

    /// Cmd+Enter adds an empty line below, Cmd+Shift+Enter above, at every caret (spec 288).
    func newLine(above: Bool) {
        var edits: [(range: NSRange, text: String)] = []
        var carets: [NSRange] = []
        var shift = 0
        for range in allSelections {
            let line = lineContents(at: range.location)
            let at = above ? line.location : NSMaxRange(line)
            edits.append((NSRange(location: at, length: 0), "\n"))
            carets.append(NSRange(location: (above ? at : at + 1) + shift, length: 0))
            shift += 1
        }
        perform(edits, select: carets)
    }

    // MARK: Edit locations (spec 292)

    func recordEditLocation(_ edited: NSRange) {
        guard helperDepth == 0 || edited.length > 0 else { return }
        let offset = NSMaxRange(edited)
        let sameLine: Bool
        if let last = editLocations.entries.last, last.url == document.url, last.offset <= nsText.length {
            sameLine = lineContents(at: last.offset).location == lineContents(at: min(offset, nsText.length)).location
        } else {
            sameLine = false
        }
        editLocations.record(url: document.url, offset: offset, sameLine: sameLine)
    }

    func goToEdit(back: Bool) {
        let current = EditLocations.Entry(url: document.url, offset: selectedRange().location)
        guard let entry = editLocations.step(back: back, from: current) else { return }
        if entry.url != document.url, let url = entry.url {
            actions.openFile(url, entry.offset)
            return
        }
        let offset = min(entry.offset, nsText.length)
        setSelectedRange(NSRange(location: offset, length: 0))
        scrollRangeToVisible(NSRange(location: offset, length: 0))
    }

    // MARK: Keys the text view does not bind (spec 407)

    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers ?? ""
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        switch (flags, key) {
        case ([.command], _) where isReturn: return newLine(above: false)
        case ([.command, .shift], _) where isReturn: return newLine(above: true)
        case ([.command], "]"): return shiftLines(by: 1)
        case ([.command], "["): return shiftLines(by: -1)
        case ([.control], " "):
            perform(commandID: "editor:toggle-menu")
        default:
            if handleFindKey(event) { return }
            super.keyDown(with: event)
        }
    }
}
