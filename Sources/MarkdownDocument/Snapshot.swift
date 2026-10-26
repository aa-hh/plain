import Foundation

/// Counts applied edits: version 0 is the text given to `init`, each `apply` adds one.
public struct TextVersion: Comparable, Hashable, Sendable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static func < (lhs: TextVersion, rhs: TextVersion) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Names a block; stays the same while the block's kind and text are unchanged.
public struct BlockID: Hashable, Sendable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
}

public enum BlockKind: Hashable, Sendable {
    case paragraph
    case atxHeading(level: Int)
    case setextHeading(level: Int)
    case blockQuote
    case bulletList
    case orderedList(start: Int)
    /// `task` is nil for an ordinary item and true for a `[ ]` or `[x]` item; `checked` is the box state.
    case listItem(task: Bool?, checked: Bool)
    case table
    case fencedCode(language: String?)
    case indentedCode
    /// Markers are the two fence lines, then per key line in text order its colon with the spaces after it and, when
    /// the value is a `[...]` list, its `[` and `]`.
    case frontMatter
    case mathBlock
    case htmlBlock
    case htmlComment
    case referenceDefinition
    case footnoteDefinition(label: String)
    case toc
    case thematicBreak
    case pageBreak
}

public enum InlineKind: Hashable, Sendable {
    case text
    case emphasis
    case strong
    case strike
    case highlight
    case code
    case math
    case link(destination: String)
    /// The label is lower-cased with runs of white space collapsed, the same form as `Snapshot.referenceDefinitions` keys.
    case referenceLink(label: String)
    case image(destination: String, alt: String)
    case referenceImage(label: String)
    case footnoteReference(label: String)
    /// `[text]` that matches no reference definition.
    case shortcutReference
    case autolink(destination: String)
    case bareURL(destination: String)
    case emoji(name: String, character: String)
    case htmlTag
    case liquidTag
    case lineBreak
    case escape
}

/// One inline element. All ranges are UTF-16 offsets into `Snapshot.text`.
public struct Inline: Hashable, Sendable {
    public var kind: InlineKind
    public var range: NSRange
    /// Syntax characters drawn faded: `*`, brackets and URL, backticks, colons and so on.
    public var markerRanges: [NSRange]
    public var contentRange: NSRange
    public var children: [Inline]

    public init(kind: InlineKind, range: NSRange, markerRanges: [NSRange] = [], contentRange: NSRange? = nil, children: [Inline] = []) {
        self.kind = kind
        self.range = range
        self.markerRanges = markerRanges
        self.contentRange = contentRange ?? range
        self.children = children
    }

    func shifted(by delta: Int) -> Inline {
        guard delta != 0 else { return self }
        var copy = self
        copy.range.location += delta
        copy.contentRange.location += delta
        copy.markerRanges = markerRanges.map { NSRange(location: $0.location + delta, length: $0.length) }
        copy.children = children.map { $0.shifted(by: delta) }
        return copy
    }
}

/// A Prism token: `type` is Prism's token name, such as `keyword` or `string`.
public struct CodeToken: Hashable, Sendable {
    public var range: NSRange
    public var type: String
    public init(range: NSRange, type: String) {
        self.range = range
        self.type = type
    }
}

public struct Heading: Hashable, Sendable {
    public var blockID: BlockID
    public var level: Int
    public var text: String
    /// Unique within the document: repeats get `-1`, `-2` and so on.
    public var slug: String
    public var range: NSRange
}

/// One block. Ranges are UTF-16 offsets into `Snapshot.text`; line numbers start at 0.
///
/// The parsed values live in a shared storage object and a block that moves only stores the distance it moved,
/// so an edit costs one addition per later top-level block instead of rewriting every nested range.
public struct Block: Sendable {
    public let id: BlockID
    public let kind: BlockKind
    let storage: BlockStorage
    var delta = 0
    var lineDelta = 0

    init(id: BlockID, kind: BlockKind, storage: BlockStorage) {
        self.id = id
        self.kind = kind
        self.storage = storage
    }

    public var range: NSRange {
        NSRange(location: storage.range.location + delta, length: storage.range.length)
    }

    public var lineRange: Range<Int> {
        (storage.lineRange.lowerBound + lineDelta)..<(storage.lineRange.upperBound + lineDelta)
    }

    public var markerRanges: [NSRange] {
        guard delta != 0 else { return storage.markerRanges }
        return storage.markerRanges.map { NSRange(location: $0.location + delta, length: $0.length) }
    }

    public var inlines: [Inline] {
        guard delta != 0 else { return storage.inlines }
        return storage.inlines.map { $0.shifted(by: delta) }
    }

    public var children: [Block] {
        guard delta != 0 || lineDelta != 0 else { return storage.children }
        return storage.children.map { $0.shifted(by: delta, lines: lineDelta) }
    }

    /// Prism tokens for a fenced block whose language Prism knows; nil otherwise.
    public var codeTokens: [CodeToken]? {
        guard delta != 0, let tokens = storage.codeTokens else { return storage.codeTokens }
        return tokens.map { CodeToken(range: NSRange(location: $0.range.location + delta, length: $0.range.length), type: $0.type) }
    }

    /// From a trailing `{.class #id key=value}`: keys `class` (space separated), `id`, and each `key`.
    public var attributes: [String: String] { storage.attributes }

    func shifted(by delta: Int, lines: Int) -> Block {
        var copy = self
        copy.delta += delta
        copy.lineDelta += lines
        return copy
    }
}

/// The block the caret is in while its kind is still ambiguous, with what the preview needs to draw it.
public struct ProvisionalBlock: Sendable {
    public let id: BlockID
    /// The kind to show for the block while its own kind is still ambiguous; always `.table`.
    public let kind: BlockKind
    /// Offsets of the `|` in the block's lines that no `\` escapes, in text order.
    public let pipeOffsets: [Int]
}

final class BlockStorage: Sendable {
    let range: NSRange
    let lineRange: Range<Int>
    let markerRanges: [NSRange]
    let inlines: [Inline]
    let children: [Block]
    let codeTokens: [CodeToken]?
    let attributes: [String: String]
    /// Plain text of a heading, used for its slug.
    let headingText: String?
    let containsHeading: Bool
    let containsFootnoteReference: Bool
    /// Label (normalised) and destination of a reference definition.
    let definition: (label: String, destination: String)?

    init(range: NSRange, lineRange: Range<Int>, markerRanges: [NSRange] = [], inlines: [Inline] = [], children: [Block] = [],
         codeTokens: [CodeToken]? = nil, attributes: [String: String] = [:], headingText: String? = nil,
         definition: (label: String, destination: String)? = nil) {
        self.range = range
        self.lineRange = lineRange
        self.markerRanges = markerRanges
        self.inlines = inlines
        self.children = children
        self.codeTokens = codeTokens
        self.attributes = attributes
        self.headingText = headingText
        self.containsHeading = headingText != nil || children.contains { $0.storage.containsHeading }
        func hasReference(_ inlines: [Inline]) -> Bool {
            inlines.contains { if case .footnoteReference = $0.kind { true } else { hasReference($0.children) } }
        }
        self.containsFootnoteReference = hasReference(inlines) || children.contains { $0.storage.containsFootnoteReference }
        self.definition = definition
    }
}

/// One footnote reference: its label's number and how many references to that label came before it.
public struct FootnoteReference: Hashable, Sendable {
    public var number: Int
    public var occurrence: Int
    public init(number: Int, occurrence: Int) {
        self.number = number
        self.occurrence = occurrence
    }
}

/// Footnote numbers for the whole document. Only references to a defined label count; labels are numbered in the
/// order their first reference appears, references inside footnote definitions included.
public struct Footnotes: Sendable {
    /// Labels in the order their first reference appears; a label's number is its index plus one.
    public var order: [String] = []
    /// Reference offset to its number and occurrence.
    public var references: [Int: FootnoteReference] = [:]
    /// How many references each label has.
    public var counts: [String: Int] = [:]
    /// The first definition of each label.
    public var definitions: [String: Block] = [:]

    init() {}

    /// Walks only the blocks holding a reference, reading their stored inlines plus the distance they moved, so an
    /// edit near the top does not copy every later block's inlines.
    init(blocks: [Block]) {
        for block in blocks {
            if case .footnoteDefinition(let label) = block.kind, definitions[label] == nil { definitions[label] = block }
        }
        guard !definitions.isEmpty else { return }
        var numbers: [String: Int] = [:]
        func visit(_ inlines: [Inline], delta: Int) {
            for inline in inlines {
                if case .footnoteReference(let label) = inline.kind, definitions[label] != nil {
                    let number: Int
                    if let existing = numbers[label] {
                        number = existing
                    } else {
                        order.append(label)
                        number = order.count
                        numbers[label] = number
                    }
                    let occurrence = counts[label, default: 0]
                    counts[label] = occurrence + 1
                    references[inline.range.location + delta] = FootnoteReference(number: number, occurrence: occurrence)
                }
                visit(inline.children, delta: delta)
            }
        }
        func visit(_ blocks: [Block], delta: Int) {
            for block in blocks where block.storage.containsFootnoteReference {
                visit(block.storage.inlines, delta: delta + block.delta)
                visit(block.storage.children, delta: delta + block.delta)
            }
        }
        visit(blocks, delta: 0)
    }
}

/// The parsed document at one text version.
public struct Snapshot: Sendable {
    public let version: TextVersion
    public let text: String
    /// Top-level blocks in text order.
    public let blocks: [Block]
    public let headings: [Heading]
    /// Normalised label (lower case, white space collapsed) to destination; the first definition of a label wins.
    public let referenceDefinitions: [String: String]
    public let footnotes: Footnotes
    /// Top-level blocks that are new or changed since the previous snapshot.
    public let changedBlockIDs: Set<BlockID>
    /// Top-level blocks of the previous snapshot that no longer exist.
    public let removedBlockIDs: Set<BlockID>
    /// The text range, in this snapshot's text, covering every edit and changed block since the previous snapshot.
    public let changedRange: NSRange
    /// The block the caret is in while its kind is still ambiguous: the kind to show for it and the pipe offsets
    /// to draw that kind with. Nil once the block settles or the caret leaves it. The preview reads this; export,
    /// copy and every other consumer read `Block.kind`, so they see the settled kind.
    public let provisional: ProvisionalBlock?

    /// The top-level block whose range holds the offset; an offset at a block's end counts as inside it.
    public func block(at offset: Int) -> Block? {
        Self.find(offset, in: blocks)
    }

    /// The innermost block whose range holds the offset.
    public func deepestBlock(at offset: Int) -> Block? {
        guard var block = block(at: offset) else { return nil }
        while let child = Self.find(offset, in: block.children) { block = child }
        return block
    }

    /// Every block, nested ones included, in text order, that satisfies the predicate.
    public func blocks(where predicate: (Block) -> Bool) -> [Block] {
        var result: [Block] = []
        func visit(_ list: [Block]) {
            for block in list {
                if predicate(block) { result.append(block) }
                visit(block.children)
            }
        }
        visit(blocks)
        return result
    }

    /// Ranges holding code rather than prose: fenced, indented and math blocks, front matter, HTML blocks and comments,
    /// and inline code, math and HTML tags.
    public func codeRanges() -> [NSRange] {
        var result: [NSRange] = []
        func visit(_ inlines: [Inline]) {
            for inline in inlines {
                switch inline.kind {
                case .code, .math, .htmlTag: result.append(inline.range)
                default: visit(inline.children)
                }
            }
        }
        func visit(_ list: [Block]) {
            for block in list {
                switch block.kind {
                case .fencedCode, .indentedCode, .mathBlock, .frontMatter, .htmlBlock, .htmlComment:
                    result.append(block.range)
                default:
                    visit(block.inlines)
                    visit(block.children)
                }
            }
        }
        visit(blocks)
        return result
    }

    /// The inlines holding the offset, outermost first. An offset where two inlines meet picks the later one.
    public func inline(at offset: Int) -> [Inline] {
        guard let block = deepestBlock(at: offset) else { return [] }
        var result: [Inline] = []
        var level = block.inlines
        while let next = level.last(where: { $0.range.location <= offset && offset <= NSMaxRange($0.range) }) {
            result.append(next)
            level = next.children
        }
        return result
    }

    static func find(_ offset: Int, in list: [Block]) -> Block? {
        var low = 0
        var high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].range.location <= offset { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let candidate = list[low - 1]
        return offset <= NSMaxRange(candidate.range) ? candidate : nil
    }
}
