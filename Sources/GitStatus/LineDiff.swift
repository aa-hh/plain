/// A mark for one line of the new text.
public struct LineMark: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case added, changed, deleted
    }

    /// Zero-based line in the new text. A deletion marks the line that now sits where the removed lines were.
    public var line: Int
    public var kind: Kind

    public init(line: Int, kind: Kind) {
        self.line = line
        self.kind = kind
    }
}

/// Marks for `text` compared with the committed version.
public func marks(for text: String, committed: String) -> [LineMark] {
    lineDiff(
        old: committed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
        new: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
}

/// Line marks from a histogram diff: split on the rarest shared line, extend the match, recurse, and fall back
/// to Myers where every shared line repeats too often to anchor on.
public func lineDiff(old: [String], new: [String]) -> [LineMark] {
    var ids: [String: Int] = [:]
    let a = old.map { line in ids[line] ?? { ids[line] = ids.count; return ids.count - 1 }() }
    let b = new.map { line in ids[line] ?? { ids[line] = ids.count; return ids.count - 1 }() }
    var ops: [DiffOp] = []
    ops.reserveCapacity(a.count + b.count)
    histogram(a, 0..<a.count, b, 0..<b.count, &ops)
    return markLines(ops, newCount: b.count)
}

enum DiffOp { case equal, delete, insert }

/// Anchor lines that repeat more often than this go to Myers instead.
private let maxAnchorCount = 64

private func histogram(_ a: [Int], _ ra: Range<Int>, _ b: [Int], _ rb: Range<Int>, _ ops: inout [DiffOp]) {
    var lowA = ra.lowerBound, highA = ra.upperBound, lowB = rb.lowerBound, highB = rb.upperBound
    while lowA < highA, lowB < highB, a[lowA] == b[lowB] {
        lowA += 1
        lowB += 1
    }
    let prefix = lowA - ra.lowerBound
    var suffix = 0
    while lowA < highA, lowB < highB, a[highA - 1] == b[highB - 1] {
        highA -= 1
        highB -= 1
        suffix += 1
    }
    ops.append(contentsOf: repeatElement(.equal, count: prefix))
    defer { ops.append(contentsOf: repeatElement(.equal, count: suffix)) }
    if lowA == highA || lowB == highB {
        ops.append(contentsOf: repeatElement(.delete, count: highA - lowA))
        ops.append(contentsOf: repeatElement(.insert, count: highB - lowB))
        return
    }

    var countA: [Int: Int] = [:]
    for i in lowA..<highA { countA[a[i], default: 0] += 1 }
    var countB: [Int: (count: Int, first: Int)] = [:]
    for j in lowB..<highB {
        if let entry = countB[b[j]] { countB[b[j]] = (entry.count + 1, entry.first) } else { countB[b[j]] = (1, j) }
    }
    var anchor: (i: Int, j: Int, score: Int)?
    for i in lowA..<highA {
        guard let inB = countB[a[i]] else { continue }
        let score = countA[a[i]]! + inB.count
        if anchor == nil || score < anchor!.score { anchor = (i, inB.first, score) }
        if score == 2 { break }
    }
    guard let anchor else {
        ops.append(contentsOf: repeatElement(.delete, count: highA - lowA))
        ops.append(contentsOf: repeatElement(.insert, count: highB - lowB))
        return
    }
    if anchor.score > maxAnchorCount {
        myers(a, lowA..<highA, b, lowB..<highB, &ops)
        return
    }
    // Grow the match around the anchor in both directions.
    var startA = anchor.i, startB = anchor.j, endA = anchor.i + 1, endB = anchor.j + 1
    while startA > lowA, startB > lowB, a[startA - 1] == b[startB - 1] {
        startA -= 1
        startB -= 1
    }
    while endA < highA, endB < highB, a[endA] == b[endB] {
        endA += 1
        endB += 1
    }
    histogram(a, lowA..<startA, b, lowB..<startB, &ops)
    ops.append(contentsOf: repeatElement(.equal, count: endA - startA))
    histogram(a, endA..<highA, b, endB..<highB, &ops)
}

/// Myers' O(ND) diff over one region, appending its edit script.
private func myers(_ a: [Int], _ ra: Range<Int>, _ b: [Int], _ rb: Range<Int>, _ ops: inout [DiffOp]) {
    let n = ra.count, m = rb.count, limit = n + m, offset = limit + 1
    var v = [Int](repeating: 0, count: 2 * limit + 3)
    var trace: [[Int]] = []
    func firstMoveIsDown(_ v: [Int], _ k: Int, _ d: Int) -> Bool {
        k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
    }
    search: for d in 0...limit {
        trace.append(v)
        for k in stride(from: -d, through: d, by: 2) {
            var x = firstMoveIsDown(v, k, d) ? v[offset + k + 1] : v[offset + k - 1] + 1
            var y = x - k
            while x < n, y < m, a[ra.lowerBound + x] == b[rb.lowerBound + y] {
                x += 1
                y += 1
            }
            v[offset + k] = x
            if x >= n, y >= m { break search }
        }
    }
    // Walk the saved states backwards to recover the script.
    var script: [DiffOp] = []
    var x = n, y = m
    for d in stride(from: trace.count - 1, through: 0, by: -1) {
        let v = trace[d]
        let k = x - y
        let prevK = firstMoveIsDown(v, k, d) ? k + 1 : k - 1
        let prevX = v[offset + prevK]
        let prevY = prevX - prevK
        while x > prevX, y > prevY {
            script.append(.equal)
            x -= 1
            y -= 1
        }
        if d > 0 { script.append(x == prevX ? .insert : .delete) }
        x = prevX
        y = prevY
    }
    ops.append(contentsOf: script.reversed())
}

/// Turns an edit script into marks: inserted lines next to deletions are `changed`, others `added`;
/// a pure deletion marks one row.
private func markLines(_ ops: [DiffOp], newCount: Int) -> [LineMark] {
    var marks: [LineMark] = []
    var newLine = 0
    var deleted = 0
    var inserted: [Int] = []
    func flush() {
        if !inserted.isEmpty {
            let kind: LineMark.Kind = deleted > 0 ? .changed : .added
            marks += inserted.map { LineMark(line: $0, kind: kind) }
        } else if deleted > 0 {
            marks.append(LineMark(line: max(0, min(newLine, newCount - 1)), kind: .deleted))
        }
        deleted = 0
        inserted = []
    }
    for op in ops {
        switch op {
        case .equal:
            flush()
            newLine += 1
        case .delete:
            deleted += 1
        case .insert:
            inserted.append(newLine)
            newLine += 1
        }
    }
    flush()
    return marks
}
