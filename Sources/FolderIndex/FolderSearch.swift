import Foundation
import PlainCore

public struct SearchHit: Sendable, Hashable {
    public var url: URL
    /// Zero-based line number in the file.
    public var line: Int
    /// The line, trimmed from the left to a word boundary about 12 characters before the hit.
    public var lineText: String
    /// The hit in the whole file, in UTF-16 units, for selecting it in the editor.
    public var range: NSRange
    /// The hit inside `lineText`, in UTF-16 units, for highlighting it in the results.
    public var rangeInLineText: NSRange
}

/// Searches the index's openable files for `query` (case-insensitive, a hit must start a space-separated chunk).
/// Sends hits in index order, batched every 50 ms or 200 hits. Ending the stream cancels the search.
public func search(_ query: String, in index: FolderIndex) -> AsyncStream<[SearchHit]> {
    let (stream, continuation) = AsyncStream.makeStream(of: [SearchHit].self)
    let task = Task {
        defer { continuation.finish() }
        guard !query.isEmpty else { return }
        let loweredQuery = Array(query.lowercased().utf8)
        var batch: [SearchHit] = []
        var lastSent = ContinuousClock.now
        for url in await index.allFiles() where OpenableFiles.isOpenable(url) {
            if Task.isCancelled { return }
            guard let file = await index.searchText(of: url), contains(file.lowercased, loweredQuery) else { continue }
            batch += hits(of: query, in: file.text, url: url)
            if batch.count >= 200 || ContinuousClock.now - lastSent >= .milliseconds(50) {
                if !batch.isEmpty { continuation.yield(batch) }
                batch = []
                lastSent = ContinuousClock.now
            }
        }
        if !batch.isEmpty, !Task.isCancelled { continuation.yield(batch) }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
}

/// Byte search of the lowercased text, far cheaper than a case-insensitive `range(of:)` over every file.
private func contains(_ lowercased: String, _ needle: [UInt8]) -> Bool {
    var haystack = lowercased
    return haystack.withUTF8 { bytes in
        needle.withUnsafeBytes { memmem(bytes.baseAddress, bytes.count, $0.baseAddress, $0.count) != nil }
    }
}

func hits(of query: String, in text: String, url: URL) -> [SearchHit] {
    var result: [SearchHit] = []
    var lineStart = 0
    for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        defer { lineStart += line.utf16.count + 1 }
        let lineString = String(line)
        var searchFrom = lineString.startIndex
        while searchFrom < lineString.endIndex {
            let rest = String(lineString[searchFrom...])
            guard let found = chunkStartMatch(query: query, in: rest) else { break }
            let lower = lineString.index(searchFrom, offsetBy: rest.distance(from: rest.startIndex, to: found.lowerBound))
            let upper = lineString.index(lower, offsetBy: rest.distance(from: found.lowerBound, to: found.upperBound))
            result.append(hit(line: lineString, number: number, lineStart: lineStart, match: lower..<upper, url: url))
            // The next hit must start a later chunk, so continue after the next space.
            guard let space = lineString[lineString.index(after: lower)...].firstIndex(of: " ") else { break }
            searchFrom = lineString.index(after: space)
        }
    }
    return result
}

private func hit(line: String, number: Int, lineStart: Int, match: Range<String.Index>, url: URL) -> SearchHit {
    var start = line.firstIndex { !$0.isWhitespace } ?? line.startIndex
    if start > match.lowerBound { start = match.lowerBound }
    if line.distance(from: start, to: match.lowerBound) > 12 {
        let cut = line.index(match.lowerBound, offsetBy: -12)
        // Move forward to the start of the next word so the shown text does not begin mid-word.
        if cut > line.startIndex, !line[line.index(before: cut)].isWhitespace,
            let space = line[cut..<match.lowerBound].firstIndex(where: \.isWhitespace)
        {
            start = line.index(after: space)
        } else {
            start = cut
        }
    }
    let nsLine = line as NSString
    let matchRange = NSRange(match, in: line)
    let startOffset = NSRange(start..<start, in: line).location
    return SearchHit(
        url: url, line: number, lineText: nsLine.substring(from: startOffset),
        range: NSRange(location: lineStart + matchRange.location, length: matchRange.length),
        rangeInLineText: NSRange(location: matchRange.location - startOffset, length: matchRange.length))
}
