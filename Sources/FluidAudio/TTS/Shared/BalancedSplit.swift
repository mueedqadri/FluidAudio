import Foundation

/// Where to cut a run of words that is too long for one model call.
///
/// Each group is spoken as its own utterance and falls at its end, so where a
/// group ends is heard. A greedy fill makes every group as full as it can and
/// leaves the remainder last: a 392-token sentence became 296 and 104, a
/// 989-token one 320, 319, 319 and 58.
///
/// In order of what matters most:
/// 1. **Fewest cuts away from a clause break.** A group that ends mid-clause is
///    heard as an invented sentence ending (Supertonic even appends a period),
///    and that is worse than one more seam at a comma, which sounds like the
///    comma it is. A near-full 885-token sentence fits three groups only with a
///    mid-clause cut, and four at clause breaks.
/// 2. **Fewest groups.**
/// 3. **Even lengths**, by squared distance from the mean, so equal groups win.
///
/// Frontend-agnostic. Kokoro passes phoneme counts per word segment, Supertonic
/// encoded tokens per word; both join words with a single space.
enum BalancedSplit {

    /// Group `lengths` into consecutive ranges whose joined length (each length
    /// plus `separatorLength` between neighbours) stays within `maxLength`.
    ///
    /// - Parameters:
    ///   - clauseBreakAfter: one flag per gap, `lengths.count - 1` of them;
    ///     `true` where the unit before the gap ends a clause.
    /// - Returns: one range when everything fits. A single unit longer than
    ///   `maxLength` becomes a group of its own; the caller decides what that
    ///   means for its model.
    static func groups(
        lengths: [Int],
        separatorLength: Int = 1,
        clauseBreakAfter: [Bool],
        maxLength: Int
    ) -> [Range<Int>] {
        let count = lengths.count
        guard count > 0 else { return [] }
        precondition(clauseBreakAfter.count == count - 1, "one clause flag per gap")

        var prefix = [0]
        for length in lengths { prefix.append(prefix[prefix.count - 1] + length) }
        func joinedLength(_ start: Int, _ end: Int) -> Int {
            prefix[end] - prefix[start] + (end - start - 1) * separatorLength
        }

        let total = joinedLength(0, count)
        let cap = max(maxLength, 1)
        guard total > cap else { return [0..<count] }
        let target = total / ((total + cap - 1) / cap)
        // Each rank outweighs everything below it summed over every group.
        let groupCost = (count + 1) * (total * total + 1)
        let unclausedCut = (count + 1) * groupCost

        var best = [Int](repeating: .max, count: count + 1)
        var previous = [Int](repeating: 0, count: count + 1)
        best[0] = 0
        for start in 0..<count where best[start] != .max {
            for end in (start + 1)...count {
                let length = joinedLength(start, end)
                if length > cap, end > start + 1 { break }
                let cut = end < count && !clauseBreakAfter[end - 1] ? unclausedCut : 0
                let imbalance = (length - target) * (length - target)
                let cost = best[start] + groupCost + imbalance + cut
                if cost < best[end] {
                    best[end] = cost
                    previous[end] = start
                }
            }
        }

        var ends: [Int] = []
        var cursor = count
        while cursor > 0 {
            ends.append(cursor)
            cursor = previous[cursor]
        }
        var ranges: [Range<Int>] = []
        var start = 0
        for end in ends.reversed() {
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    /// Whether `word` ends a clause: its last character, behind any closing
    /// quote or bracket, is one of `marks`.
    static func endsClause(_ word: some StringProtocol, marks: Set<Character>) -> Bool {
        guard let last = word.last(where: { !closers.contains($0) }) else { return false }
        return marks.contains(last)
    }

    private static let closers: Set<Character> = [
        "\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}", "\u{00BB}", "\u{300D}", "\u{300F}",
    ]
}
