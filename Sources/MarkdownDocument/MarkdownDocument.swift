import Foundation
import PlainCore
import Synchronization

/// The one Markdown parser. Holds a copy of the editor's text, takes edits as they happen and publishes a `Snapshot`
/// after each parse. Edits queued while a parse runs are applied together and parsed once.
public actor MarkdownDocument {
    private struct Inbox {
        var version = 0
        var pending: [TextEdit] = []
        var draining = false
        var streams: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    }

    private nonisolated let inbox = Mutex(Inbox())
    private var source: Source
    private var current: Snapshot
    private var nextID: Int
    private var slugs: [String: String]
    private var footnoteLabels: Set<String>
    private var waiters: [(version: TextVersion, continuation: CheckedContinuation<Snapshot, Never>)] = []

    public init(text: String) {
        let source = Source(units: Array(text.utf16))
        var nextID = 0
        let kinds = LineScanner(source: source).scan(0..<source.lineCount).kinds
        let blocks = PostPass.parse(source, lines: 0..<source.lineCount, kinds: kinds, extraDefinitions: [],
                                    outsideFootnoteLabels: [], nextID: &nextID)
        var slugs: [String: String] = [:]
        self.source = source
        self.nextID = nextID
        footnoteLabels = Self.footnoteLabels(in: blocks)
        current = Snapshot(version: TextVersion(rawValue: 0), text: Self.string(source.units), blocks: blocks,
                           headings: Self.headings(in: blocks, slugs: &slugs), referenceDefinitions: Self.definitions(in: blocks),
                           changedBlockIDs: Set(blocks.map(\.id)), removedBlockIDs: [],
                           changedRange: NSRange(location: 0, length: source.units.count))
        self.slugs = slugs
    }

    /// Queues the edit and returns at once. Edits apply in call order; each one adds one to the version.
    @discardableResult
    public nonisolated func apply(_ edit: TextEdit) -> TextVersion {
        let (version, start) = inbox.withLock { inbox in
            inbox.version += 1
            inbox.pending.append(edit)
            defer { inbox.draining = true }
            return (inbox.version, !inbox.draining)
        }
        if start { Task { await self.drain() } }
        return TextVersion(rawValue: version)
    }

    /// The version of the last edit queued, published or not.
    public nonisolated var version: TextVersion {
        TextVersion(rawValue: inbox.withLock { $0.version })
    }

    /// A new stream on each access; every stream receives every snapshot published after it was made.
    public nonisolated var snapshots: AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream()
        let id = UUID()
        inbox.withLock { $0.streams[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.inbox.withLock { _ = $0.streams.removeValue(forKey: id) }
        }
        return stream
    }

    /// The latest published snapshot; edits still queued are not in it.
    public func currentSnapshot() -> Snapshot { current }

    /// Waits for the first snapshot whose version is at least `version`.
    public func snapshot(atLeast version: TextVersion) async -> Snapshot {
        if current.version >= version { return current }
        return await withCheckedContinuation { waiters.append((version, $0)) }
    }

    private func drain() {
        while true {
            let batch: ([TextEdit], Int)? = inbox.withLock { inbox in
                guard !inbox.pending.isEmpty else {
                    inbox.draining = false
                    return nil
                }
                defer { inbox.pending.removeAll(keepingCapacity: true) }
                return (inbox.pending, inbox.version)
            }
            guard let (edits, version) = batch else { return }
            publish(process(edits, version: TextVersion(rawValue: version)))
        }
    }

    private func publish(_ snapshot: Snapshot) {
        current = snapshot
        for stream in inbox.withLock({ Array($0.streams.values) }) { stream.yield(snapshot) }
        var remaining: [(version: TextVersion, continuation: CheckedContinuation<Snapshot, Never>)] = []
        for waiter in waiters {
            if waiter.version <= snapshot.version { waiter.continuation.resume(returning: snapshot) } else { remaining.append(waiter) }
        }
        waiters = remaining
    }

    // MARK: Incremental reparse

    private func process(_ edits: [TextEdit], version: TextVersion) -> Snapshot {
        let oldLineCount = source.lineCount
        let oldStarts = source.lineStarts

        // Apply the edits, keeping one range [start, end) in new offsets that covers all of them.
        var start = Int.max
        var end = Int.min
        var delta = 0
        for edit in edits {
            let location = min(max(edit.range.location, 0), source.units.count)
            let length = min(max(edit.range.length, 0), source.units.count - location)
            let replacement = Array(edit.replacement.utf16)
            source.units.replaceSubrange(location..<(location + length), with: replacement)
            let inserted = replacement.count
            if start == Int.max {
                start = location
                end = location + inserted
            } else {
                if end >= location + length { end += inserted - length } else if end > location { end = location + inserted }
                end = max(end, location + inserted)
                start = min(start, location)
            }
            delta += inserted - length
        }
        let oldEnd = end - delta

        // Rebuild the line table for the touched lines and shift the rest.
        let firstLine = source.line(containing: start)
        let lastLine = source.line(containing: oldEnd)
        var scanEnd = end
        while scanEnd < source.units.count && source.units[scanEnd] != 10 { scanEnd += 1 }
        let fresh = Source.lineStarts(in: source.units, from: oldStarts[firstLine], to: scanEnd)
        source.lineStarts.replaceSubrange(firstLine...lastLine, with: fresh)
        for index in (firstLine + fresh.count)..<source.lineStarts.count { source.lineStarts[index] += delta }
        let lineDelta = source.lineCount - oldLineCount

        // Window: from the block before the first touched block to the second block after the last touched one.
        let old = current.blocks
        let firstTouched = Self.lastIndex(in: old, atOrBefore: start)
        let lastTouched = Self.lastIndex(in: old, atOrBefore: oldEnd)
        let windowStart = firstTouched >= 1 ? old[firstTouched - 1].lineRange.lowerBound : 0
        var windowEnd = lastTouched + 2 < old.count ? old[lastTouched + 2].lineRange.upperBound : oldLineCount
        windowEnd = max(windowEnd, lastLine + 1)

        var full = false
        var newBlocks: [Block] = []
        var attempts = 0
        while true {
            windowEnd = min(windowEnd, oldLineCount)
            let lines = windowStart..<(windowEnd + lineDelta)
            let scanner = LineScanner(source: source)
            let (kinds, open) = scanner.scan(lines)
            if let fence = open {
                guard windowEnd < oldLineCount, let close = scanner.closingLine(of: fence, from: lines.upperBound) else {
                    full = true
                    break
                }
                windowEnd = Self.blockBoundary(in: old, atOrAfter: close - lineDelta + 1)
                continue
            }
            var nextID = self.nextID
            newBlocks = PostPass.parse(source, lines: lines, kinds: kinds, extraDefinitions: extraDefinitions(for: lines),
                                       outsideFootnoteLabels: footnoteLabels, nextID: &nextID)
            self.nextID = nextID
            let covered = old.filter { $0.lineRange.lowerBound >= windowStart && $0.lineRange.lowerBound < windowEnd }
            if windowEnd < oldLineCount && !Self.endsStable(newBlocks.last, covered.last, start: start, oldEnd: oldEnd, delta: delta, lineDelta: lineDelta) {
                attempts += 1
                guard attempts <= 8 else {
                    full = true
                    break
                }
                let next = old.firstIndex { $0.lineRange.lowerBound >= windowEnd }
                windowEnd = next.map { old[$0].lineRange.upperBound } ?? oldLineCount
                continue
            }
            if Self.labels(in: covered) != Self.labels(in: newBlocks) { full = true }
            break
        }

        let coveredRange: Range<Int>
        if full {
            var nextID = self.nextID
            let kinds = LineScanner(source: source).scan(0..<source.lineCount).kinds
            newBlocks = PostPass.parse(source, lines: 0..<source.lineCount, kinds: kinds, extraDefinitions: [],
                                       outsideFootnoteLabels: [], nextID: &nextID)
            self.nextID = nextID
            coveredRange = 0..<old.count
        } else {
            let first = old.firstIndex { $0.lineRange.lowerBound >= windowStart } ?? old.count
            let last = old.firstIndex { $0.lineRange.lowerBound >= windowEnd } ?? old.count
            coveredRange = first..<max(first, last)
        }

        // Keep the id (and, for a window parse, the parsed content) of every covered block whose text did not change.
        var intact: [Int: (block: Block, delta: Int, lines: Int)] = [:]
        for block in old[coveredRange] {
            let range = block.range
            if NSMaxRange(range) < start {
                intact[range.location] = (block, 0, 0)
            } else if range.location > oldEnd {
                intact[range.location + delta] = (block, delta, lineDelta)
            }
        }
        var merged = Array(old[..<coveredRange.lowerBound])
        var changed: Set<BlockID> = []
        var kept: Set<BlockID> = []
        var changedRange = NSRange(location: start, length: end - start)
        for block in newBlocks {
            if let match = intact[block.range.location], match.block.kind == block.kind,
               match.block.range.length == block.range.length, match.block.lineRange.count == block.lineRange.count {
                kept.insert(match.block.id)
                merged.append(full ? Block(id: match.block.id, kind: block.kind, storage: block.storage)
                                   : match.block.shifted(by: match.delta, lines: match.lines))
            } else {
                changed.insert(block.id)
                changedRange = NSUnionRange(changedRange, block.range)
                merged.append(block)
            }
        }
        let removed = Set(old[coveredRange].map(\.id)).subtracting(kept)
        for block in old[coveredRange.upperBound...] { merged.append(block.shifted(by: delta, lines: lineDelta)) }

        var definitions = current.referenceDefinitions
        let touchedKinds = old[coveredRange].map(\.kind) + newBlocks.map(\.kind)
        if full || touchedKinds.contains(.referenceDefinition) { definitions = Self.definitions(in: merged) }
        if full || touchedKinds.contains(where: { if case .footnoteDefinition = $0 { true } else { false } }) {
            footnoteLabels = Self.footnoteLabels(in: merged)
        }
        return Snapshot(version: version, text: Self.string(source.units), blocks: merged,
                        headings: Self.headings(in: merged, slugs: &slugs), referenceDefinitions: definitions,
                        changedBlockIDs: changed, removedBlockIDs: removed, changedRange: changedRange)
    }

    /// Definitions from outside the window whose label could be referenced inside it, as `[label]: destination` lines.
    private func extraDefinitions(for lines: Range<Int>) -> [String] {
        let definitions = current.referenceDefinitions
        guard !definitions.isEmpty else { return [] }
        let units = source.units
        var candidates: Set<String> = []
        var index = source.lineStart(lines.lowerBound)
        let end = source.lineEnd(lines.upperBound - 1)
        var open: Int?
        while index < end {
            switch units[index] {
            case 91: open = index + 1
            case 93:
                if let start = open { candidates.insert(normalizedLabel(source.string(start..<index))) }
                open = nil
            default: break
            }
            index += 1
        }
        return candidates.compactMap { label in definitions[label].map { "[\(label)]: \($0)" } }
    }

    // MARK: Helpers

    private static func string(_ units: [UInt16]) -> String {
        guard !units.isEmpty else { return "" }
        return units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) as String }
    }

    /// Index of the last block starting at or before the offset, or -1.
    private static func lastIndex(in blocks: [Block], atOrBefore offset: Int) -> Int {
        var low = 0
        var high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].range.location <= offset { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }

    /// The end line of the old block holding `line - 1`, or `line` when that line is outside every block.
    private static func blockBoundary(in blocks: [Block], atOrAfter line: Int) -> Int {
        var low = 0
        var high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].lineRange.upperBound < line { low = mid + 1 } else { high = mid }
        }
        guard low < blocks.count, blocks[low].lineRange.lowerBound < line else { return line }
        return blocks[low].lineRange.upperBound
    }

    /// Whether the window's last new block is its last old block unchanged, so the parse can stop at the window end.
    private static func endsStable(_ new: Block?, _ old: Block?, start: Int, oldEnd: Int, delta: Int, lineDelta: Int) -> Bool {
        guard let new, let old else { return new == nil && old == nil }
        let range = old.range
        guard range.location > oldEnd || NSMaxRange(range) < start else { return false }
        let shift = range.location > oldEnd ? delta : 0
        let lines = range.location > oldEnd ? lineDelta : 0
        return new.kind == old.kind && new.range.location == range.location + shift && new.range.length == range.length
            && new.lineRange == (old.lineRange.lowerBound + lines)..<(old.lineRange.upperBound + lines)
    }

    /// Reference definition and footnote labels, which decide how text elsewhere parses.
    private static func labels(in blocks: [Block]) -> Set<String> {
        var result: Set<String> = []
        for block in blocks {
            if let definition = block.storage.definition { result.insert("ref:" + definition.label) }
            if case .footnoteDefinition(let label) = block.kind { result.insert("fn:" + label) }
        }
        return result
    }

    private static func definitions(in blocks: [Block]) -> [String: String] {
        var result: [String: String] = [:]
        for block in blocks {
            if let definition = block.storage.definition, result[definition.label] == nil {
                result[definition.label] = definition.destination
            }
        }
        return result
    }

    private static func footnoteLabels(in blocks: [Block]) -> Set<String> {
        var result: Set<String> = []
        for block in blocks {
            if case .footnoteDefinition(let label) = block.kind { result.insert(label) }
        }
        return result
    }

    private static func headings(in blocks: [Block], slugs: inout [String: String]) -> [Heading] {
        var result: [Heading] = []
        var counter = SlugCounter()
        func visit(_ list: [Block]) {
            for block in list where block.storage.containsHeading {
                if let text = block.storage.headingText {
                    let level: Int
                    switch block.kind {
                    case .atxHeading(let value), .setextHeading(let value): level = value
                    default: level = 1
                    }
                    let base: String
                    if let cached = slugs[text] {
                        base = cached
                    } else {
                        base = slugify(text)
                        slugs[text] = base
                    }
                    result.append(Heading(blockID: block.id, level: level, text: text, slug: counter.unique(base), range: block.range))
                }
                visit(block.children)
            }
        }
        visit(blocks)
        return result
    }
}
