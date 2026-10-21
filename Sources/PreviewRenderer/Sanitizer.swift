import Foundation

/// Cleans HTML the way DOMPurify 1.0.10's defaults do for the cases spec 490 lists: drops `script`, `style`,
/// `iframe`, `object`, `embed` and the other elements that load or run code, every `on*` attribute,
/// `javascript:` and `vbscript:` URLs and `data:` URLs other than images. Keeps `style` attributes and every other
/// element, `details`, `kbd` and `img` included. Comments are dropped. Reads broken markup without failing:
/// a `<` that does not start a tag becomes `&lt;`.
public enum Sanitizer {
    /// Dropped together with everything up to their closing tag.
    static let droppedWithContent: Set<String> = ["script", "style", "iframe", "object", "applet", "frameset", "noembed", "noframes", "template"]
    /// Dropped; their content, if any, stays.
    static let droppedTags: Set<String> = ["embed", "frame", "base", "link", "meta"]
    static let urlAttributes: Set<String> = ["href", "src", "action", "formaction", "xlink:href", "data", "poster", "background", "cite", "lowsrc", "srcset"]

    /// Whether a URL may appear in an attribute: no script schemes, and `data:` only for images when `image` is true.
    public static func isSafeURL(_ value: String, image: Bool) -> Bool {
        let compact = String(decodeEntities(value).unicodeScalars.filter { $0.value > 32 && $0.value != 127 }).lowercased()
        if compact.hasPrefix("javascript:") || compact.hasPrefix("vbscript:") { return false }
        if compact.hasPrefix("data:") { return image && compact.hasPrefix("data:image/") }
        return true
    }

    /// The cleaned HTML. `rewriteURL` (the preview's link resolver) is applied to `href`, `src` and `data` values.
    public static func sanitize(_ html: String, rewriteURL: ((String) -> String)? = nil) -> String {
        let units = Array(html.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        var index = 0
        let count = units.count

        func append(_ text: String) { out.append(contentsOf: text.utf16) }
        func isLetter(_ unit: UInt16) -> Bool { (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) }
        func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 12 }
        func find(_ needle: String, from start: Int) -> Int? {
            let target = Array(needle.utf16)
            var cursor = start
            while cursor + target.count <= count {
                var matched = true
                for (offset, unit) in target.enumerated() {
                    var candidate = units[cursor + offset]
                    if candidate >= 65 && candidate <= 90 { candidate += 32 }
                    if candidate != unit { matched = false; break }
                }
                if matched { return cursor }
                cursor += 1
            }
            return nil
        }
        func name(from start: Int) -> (String, Int) {
            var cursor = start
            while cursor < count && !isSpace(units[cursor]) && units[cursor] != 62 && units[cursor] != 47 { cursor += 1 }
            return (String(decoding: units[start..<cursor], as: UTF16.self).lowercased(), cursor)
        }

        while index < count {
            let unit = units[index]
            guard unit == 60 else {
                out.append(unit)
                index += 1
                continue
            }
            // Comments, doctypes and processing instructions are dropped.
            if index + 3 < count && units[index + 1] == 33 && units[index + 2] == 45 && units[index + 3] == 45 {
                index = (find("-->", from: index + 4).map { $0 + 3 }) ?? count
                continue
            }
            if index + 1 < count && (units[index + 1] == 33 || units[index + 1] == 63) {
                index = (find(">", from: index + 1).map { $0 + 1 }) ?? count
                continue
            }
            // End tag.
            if index + 2 < count && units[index + 1] == 47 && isLetter(units[index + 2]) {
                let (tag, after) = name(from: index + 2)
                guard let close = find(">", from: after) else {
                    append("&lt;")
                    index += 1
                    continue
                }
                if !droppedTags.contains(tag) && !droppedWithContent.contains(tag) { append("</\(tag)>") }
                index = close + 1
                continue
            }
            guard index + 1 < count && isLetter(units[index + 1]) else {
                append("&lt;")
                index += 1
                continue
            }
            // Start tag: read the name and attributes up to `>`, respecting quotes.
            let (tag, afterName) = name(from: index + 1)
            var cursor = afterName
            var attributes: [(String, String?)] = []
            var closed = false
            var selfClosing = false
            while cursor < count {
                while cursor < count && (isSpace(units[cursor]) || units[cursor] == 47) {
                    if units[cursor] == 47 { selfClosing = true }
                    cursor += 1
                }
                guard cursor < count else { break }
                if units[cursor] == 62 {
                    closed = true
                    cursor += 1
                    break
                }
                selfClosing = false
                let nameStart = cursor
                while cursor < count && !isSpace(units[cursor]) && units[cursor] != 61 && units[cursor] != 62 && units[cursor] != 47 { cursor += 1 }
                if cursor == nameStart { cursor += 1; continue }
                let attributeName = String(decoding: units[nameStart..<cursor], as: UTF16.self).lowercased()
                while cursor < count && isSpace(units[cursor]) { cursor += 1 }
                var value: String?
                if cursor < count && units[cursor] == 61 {
                    cursor += 1
                    while cursor < count && isSpace(units[cursor]) { cursor += 1 }
                    if cursor < count && (units[cursor] == 34 || units[cursor] == 39) {
                        let quote = units[cursor]
                        let valueStart = cursor + 1
                        cursor = valueStart
                        while cursor < count && units[cursor] != quote { cursor += 1 }
                        value = String(decoding: units[valueStart..<min(cursor, count)], as: UTF16.self)
                        if cursor < count { cursor += 1 }
                    } else {
                        let valueStart = cursor
                        while cursor < count && !isSpace(units[cursor]) && units[cursor] != 62 { cursor += 1 }
                        value = String(decoding: units[valueStart..<cursor], as: UTF16.self)
                    }
                }
                attributes.append((attributeName, value))
            }
            guard closed else {
                append("&lt;")
                index += 1
                continue
            }
            index = cursor
            if droppedWithContent.contains(tag) {
                if let end = find("</\(tag)", from: index) {
                    index = (find(">", from: end).map { $0 + 1 }) ?? count
                } else {
                    index = count
                }
                continue
            }
            if droppedTags.contains(tag) { continue }
            append("<" + tag)
            for (attributeName, value) in attributes {
                guard isAllowedAttribute(attributeName) else { continue }
                guard var value else {
                    append(" " + attributeName)
                    continue
                }
                if urlAttributes.contains(attributeName) {
                    guard isSafeURL(value, image: tag == "img" && (attributeName == "src" || attributeName == "srcset")) else { continue }
                    if let rewriteURL, ["href", "src", "data"].contains(attributeName) {
                        value = escapeHTML(rewriteURL(decodeEntities(value)))
                        append(" \(attributeName)=\"\(value)\"")
                        continue
                    }
                }
                append(" \(attributeName)=\"\(value.replacingOccurrences(of: "\"", with: "&quot;"))\"")
            }
            append(selfClosing ? " />" : ">")
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// Attribute names made of letters, digits, `-`, `_`, `:` and `.`, except event handlers (`on...`).
    static func isAllowedAttribute(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("on") else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_:.".unicodeScalars.contains($0) }
    }

    /// Decodes numeric entities and `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, `&colon;`, `&tab;`, `&newline;`.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "colon": ":", "tab": "\t", "newline": "\n", "nbsp": "\u{A0}"]
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semicolon = after.prefix(12).firstIndex(of: ";") {
                let body = after[..<semicolon]
                var decoded: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if body.hasPrefix("#") {
                    decoded = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = named[body.lowercased()]
                }
                if let decoded {
                    result += decoded
                    rest = after[after.index(after: semicolon)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }
}
