import AppKit
import MarkdownDocument

/// Copy as Rich Text, Copy as HTML (spec 602–607) and the HTML to Markdown conversion behind Paste Formatted
/// (spec 619–630).
public enum RichText {
    /// Renders Markdown the way export does: no path rewriting, no theme or KaTeX stylesheet.
    public static func html(for markdown: String, math: any MathRenderer) async -> String {
        let snapshot = await MarkdownDocument(text: markdown).currentSnapshot()
        return HTMLRenderer(math: math).html(for: snapshot)
    }

    /// Puts the rendered HTML on the pasteboard as HTML and the Markdown as plain text.
    @MainActor
    public static func copyAsRichText(markdown: String, math: any MathRenderer, pasteboard: NSPasteboard = .general) async {
        let rendered = await html(for: markdown, math: math)
        pasteboard.clearContents()
        pasteboard.setString(rendered, forType: .html)
        pasteboard.setString(markdown, forType: .string)
    }

    /// Puts the rendered HTML source on the pasteboard as plain text only.
    @MainActor
    public static func copyAsHTML(markdown: String, math: any MathRenderer, pasteboard: NSPasteboard = .general) async {
        let rendered = await html(for: markdown, math: math)
        pasteboard.clearContents()
        pasteboard.setString(rendered, forType: .string)
    }

    /// The pasteboard's HTML, or its plain text when it has none, converted to Markdown.
    @MainActor
    public static func markdownFromPasteboard(_ pasteboard: NSPasteboard = .general) -> String? {
        guard let source = pasteboard.string(forType: .html) ?? pasteboard.string(forType: .string) else { return nil }
        return htmlToMarkdown(source)
    }

    // MARK: HTML to Markdown

    final class Node {
        let tag: String?
        let text: String
        var attributes: [String: String]
        var children: [Node] = []
        weak var parent: Node?

        init(tag: String?, text: String = "", attributes: [String: String] = [:]) {
            self.tag = tag
            self.text = text
            self.attributes = attributes
        }
    }

    static let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr", "param"]
    static let rawTextTags: Set<String> = ["script", "style"]
    static let skippedTags: Set<String> = ["head", "style", "script", "title"]
    static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "nav", "aside", "main", "figure", "figcaption", "dl", "dt", "dd",
        "address", "form", "fieldset", "details", "summary", "ul", "ol", "table", "center",
    ]

    /// Converts HTML to Markdown with the rules of spec 620–630.
    public static func htmlToMarkdown(_ html: String) -> String {
        render(parse(html).children, inPre: false).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A forgiving tree: unknown end tags are ignored, an end tag closes every element opened inside its match.
    static func parse(_ html: String) -> Node {
        let root = Node(tag: "#root")
        var current = root
        let scalars = Array(html.unicodeScalars)
        var index = 0
        var text = ""

        func flushText() {
            guard !text.isEmpty else { return }
            let node = Node(tag: nil, text: Sanitizer.decodeEntities(text))
            node.parent = current
            current.children.append(node)
            text = ""
        }
        func isNameStart(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isAlphabetic && scalar.isASCII }
        func find(_ needle: String, from start: Int) -> Int? {
            let target = Array(needle.lowercased().unicodeScalars)
            var cursor = start
            while cursor + target.count <= scalars.count {
                if (0..<target.count).allSatisfy({ String(scalars[cursor + $0]).lowercased().unicodeScalars.first == target[$0] }) { return cursor }
                cursor += 1
            }
            return nil
        }

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "<" else {
                text.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            if index + 3 < scalars.count && scalars[index + 1] == "!" && scalars[index + 2] == "-" && scalars[index + 3] == "-" {
                flushText()
                index = find("-->", from: index + 4).map { $0 + 3 } ?? scalars.count
                continue
            }
            if index + 1 < scalars.count && (scalars[index + 1] == "!" || scalars[index + 1] == "?") {
                flushText()
                index = find(">", from: index).map { $0 + 1 } ?? scalars.count
                continue
            }
            let closing = index + 1 < scalars.count && scalars[index + 1] == "/"
            let nameStart = index + (closing ? 2 : 1)
            guard nameStart < scalars.count, isNameStart(scalars[nameStart]), let end = tagEnd(scalars, from: nameStart) else {
                text.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            flushText()
            let inside = String(String.UnicodeScalarView(scalars[nameStart..<end]))
            index = end + 1
            var nameEnd = inside.startIndex
            while nameEnd < inside.endIndex && !inside[nameEnd].isWhitespace && inside[nameEnd] != "/" { nameEnd = inside.index(after: nameEnd) }
            let name = inside[..<nameEnd].lowercased()
            if closing {
                var node: Node? = current
                while let candidate = node, candidate.tag != name { node = candidate.parent }
                if let match = node, let parent = match.parent { current = parent }
                continue
            }
            let element = Node(tag: name, attributes: attributes(String(inside[nameEnd...])))
            element.parent = current
            current.children.append(element)
            if rawTextTags.contains(name) {
                let close = find("</\(name)", from: index) ?? scalars.count
                let body = Node(tag: nil, text: String(String.UnicodeScalarView(scalars[index..<close])))
                element.children.append(body)
                index = close < scalars.count ? (find(">", from: close).map { $0 + 1 } ?? scalars.count) : close
                continue
            }
            if !voidTags.contains(name) && !inside.hasSuffix("/") { current = element }
        }
        flushText()
        return root
    }

    /// Index of the `>` ending a tag, skipping quoted attribute values.
    private static func tagEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var quote: Unicode.Scalar?
        var index = start
        while index < scalars.count {
            let scalar = scalars[index]
            if let open = quote {
                if scalar == open { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == ">" {
                return index
            } else if scalar == "<" {
                return nil
            }
            index += 1
        }
        return nil
    }

    private static let attributePattern = try! NSRegularExpression(pattern: "([^\\s=/]+)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+)))?")

    private static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let source = text as NSString
        for match in attributePattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1)).lowercased()
            var value = ""
            for group in 2...4 where match.range(at: group).location != NSNotFound { value = source.substring(with: match.range(at: group)) }
            if result[name] == nil { result[name] = Sanitizer.decodeEntities(value) }
        }
        return result
    }

    /// Joins pieces, putting a space between two that would otherwise touch without white space.
    private static func join(_ result: inout String, _ piece: String) {
        guard !piece.isEmpty else { return }
        if let last = result.last, let first = piece.first, !last.isWhitespace, !first.isWhitespace { result += " " }
        result += piece
    }

    static func render(_ nodes: [Node], inPre: Bool) -> String {
        var result = ""
        for node in nodes { join(&result, render(node, inPre: inPre)) }
        return result
    }

    private static func isHidden(_ node: Node) -> Bool {
        if let style = node.attributes["style"]?.lowercased().replacingOccurrences(of: " ", with: ""),
           style.contains("display:none") || style.range(of: "opacity:0(?![.0-9]*[1-9])", options: .regularExpression) != nil {
            return true
        }
        return node.attributes["class"]?.split(separator: " ").contains { $0.hasPrefix("Apple-") } == true
    }

    private static func plainText(_ node: Node) -> String {
        node.tag == nil ? node.text : node.children.map(plainText).joined()
    }

    static func render(_ node: Node, inPre: Bool) -> String {
        guard let tag = node.tag else {
            return inPre ? node.text : node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if skippedTags.contains(tag) || isHidden(node) { return "" }
        let content = { render(node.children, inPre: inPre) }
        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            return "\n\n" + String(repeating: "#", count: Int(String(tag.last!))!) + " " + content() + "\n\n"
        case "li":
            return "- " + content() + "\n"
        case "blockquote":
            return "> " + content() + "\n"
        case "pre":
            return "```\n" + node.children.map(plainText).joined() + "\n```\n"
        case "code":
            return inPre ? node.children.map(plainText).joined() : "`" + content() + "`"
        case "em": return "*" + content() + "*"
        case "strong": return "**" + content() + "**"
        case "strike": return "~~" + content() + "~~"
        case "a":
            let text = content()
            guard !text.isEmpty else { return "" }
            guard let href = node.attributes["href"], !href.isEmpty else { return text }
            func trimmed(_ value: String) -> String { value.hasSuffix("/") ? String(value.dropLast()) : value }
            return trimmed(text) == trimmed(href) ? href : "[\(text)](\(href))"
        case "img":
            return "![\(node.attributes["alt"] ?? "")](\(node.attributes["src"] ?? ""))"
        case "br": return "\n"
        case "hr": return "***\n"
        case "table": return table(node) + "\n"
        default:
            return blockTags.contains(tag) ? content() + "\n" : content()
        }
    }

    /// A pipe table with every column padded to its widest cell (at least 3). A table whose first row has no `th`
    /// gets an empty header row.
    private static func table(_ node: Node) -> String {
        var rows: [Node] = []
        func collect(_ node: Node) {
            for child in node.children {
                if child.tag == "tr" { rows.append(child) } else if child.tag != nil { collect(child) }
            }
        }
        collect(node)
        var cells: [[String]] = rows.map { row in
            row.children.filter { $0.tag == "td" || $0.tag == "th" }.map {
                render($0.children, inPre: false).replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|")
            }
        }
        guard !cells.isEmpty else { return "" }
        let columns = cells.map(\.count).max() ?? 0
        let firstIsHeader = rows[0].children.contains { $0.tag == "th" }
        if !firstIsHeader { cells.insert(Array(repeating: "", count: columns), at: 0) }
        cells = cells.map { $0 + Array(repeating: "", count: columns - $0.count) }
        let widths = (0..<columns).map { column in max(3, cells.map { $0[column].count }.max() ?? 0) }
        func line(_ row: [String]) -> String {
            "| " + row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: " | ") + " |"
        }
        var lines = [line(cells[0]), line(widths.map { String(repeating: "-", count: $0) })]
        lines += cells.dropFirst().map(line)
        return lines.joined(separator: "\n")
    }
}
