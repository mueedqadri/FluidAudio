import Foundation

/// English text as the voice reads it, with every rewritten span tied to the
/// written words it replaced, so word timings can be reported against the
/// words a reader sees (`"1999"`, not `"nineteen"` and `"ninety"`).
struct EnglishSpokenText: Sendable, Equatable {
    struct Expansion: Sendable, Equatable {
        /// UTF-16 offsets of the spoken words in `text`.
        let range: Range<Int>
        /// The written words they replace.
        let source: String
    }

    let text: String
    let expansions: [Expansion]
}

extension EnglishTextNormalizer {

    /// `text` with its numbers and symbols in spoken form.
    ///
    /// NeMo reads the whole sentence, so a number keeps its context (`26 kg`,
    /// `Oct 10`, `$4.50`), but only its rewrites of written words that contain
    /// a digit are kept. Everything else NeMo would change (`Mr.` → `mister`,
    /// the space it drops before a quote mark) stays as written, and text
    /// without a digit never reaches it. Our own rules for what NeMo misses
    /// (``spellRangesAndSymbols(_:)``) run first; digits NeMo leaves alone go
    /// through ``normalize(_:)``.
    static func spokenText(_ text: String) -> EnglishSpokenText {
        guard text.contains(where: { $0.isASCIIDigit || spokenSymbols.contains($0) }) else {
            return EnglishSpokenText(text: text, expansions: [])
        }
        var pieces = text.split(whereSeparator: \.isWhitespace).map { Piece(text: String($0), source: nil) }
        pieces = rewrite(pieces, with: spellRangesAndSymbols, keepingOnlyDigitRewrites: false)
        pieces = rewrite(pieces) {
            // NeMo reads `=` as "equal sign" when a percent sits on its left.
            NemoTextNormalizer.normalize($0, language: .english)
                .replacingOccurrences(of: "equal sign", with: "equals")
        }
        pieces = rewrite(pieces, with: normalize)
        return assemble(pieces)
    }

    /// A whitespace-separated piece of the output; `source` is set when it is
    /// spoken words that replace written ones.
    private struct Piece {
        let text: String
        let source: String?
    }

    /// Symbols ``spellRangesAndSymbols(_:)`` may read in text without a digit.
    private static let spokenSymbols: Set<Character> = ["♭", "♯"]

    /// Run `rewriter` over each stretch of untouched pieces. NeMo's rewrites
    /// are kept only where the written side holds a digit; our own rules are
    /// exact and keep every rewrite.
    private static func rewrite(
        _ pieces: [Piece],
        with rewriter: (String) -> String,
        keepingOnlyDigitRewrites: Bool = true
    ) -> [Piece] {
        var result: [Piece] = []
        var stretch: [String] = []

        func flush() {
            defer { stretch.removeAll() }
            guard !keepingOnlyDigitRewrites || stretch.contains(where: { $0.contains(where: \.isASCIIDigit) }) else {
                result += stretch.map { Piece(text: $0, source: nil) }
                return
            }
            let rewritten = rewriter(stretch.joined(separator: " "))
                .split(whereSeparator: \.isWhitespace).map(String.init)
            for hunk in hunks(from: stretch, to: rewritten) {
                guard hunk.spoken != hunk.written, !hunk.spoken.isEmpty,
                    !keepingOnlyDigitRewrites
                        || hunk.written.contains(where: { $0.contains(where: \.isASCIIDigit) })
                else {
                    result += hunk.written.map { Piece(text: $0, source: nil) }
                    continue
                }
                let trimmed = keepingOnlyDigitRewrites
                    ? trimmingStandaloneRewrites(hunk, with: rewriter)
                    : (before: [], written: hunk.written, spoken: hunk.spoken, after: [])
                result += trimmed.before.map { Piece(text: $0, source: nil) }
                result.append(
                    Piece(
                        text: americanNumberStyle(trimmed.spoken),
                        source: trimmed.written.joined(separator: " ")))
                result += trimmed.after.map { Piece(text: $0, source: nil) }
            }
        }

        for piece in pieces {
            if piece.source == nil {
                stretch.append(piece.text)
            } else {
                flush()
                result.append(piece)
            }
        }
        flush()
        return result
    }

    /// Hands back a changed region's edge words that `rewriter` changes on
    /// their own, with no number beside them: `Mr.` → `mister` next to `1915,`
    /// is a title, while `kg` next to `26` only changes with its number.
    private static func trimmingStandaloneRewrites(
        _ hunk: (written: [String], spoken: [String]),
        with rewriter: (String) -> String
    ) -> (before: [String], written: [String], spoken: [String], after: [String]) {
        var written = hunk.written
        var spoken = hunk.spoken
        var before: [String] = []
        var after: [String] = []

        func standaloneRewrite(_ word: String) -> [String]? {
            guard !word.contains(where: \.isASCIIDigit), word.contains(where: \.isLetter) else { return nil }
            let alone = rewriter(word).split(whereSeparator: \.isWhitespace).map(String.init)
            return alone == [word] ? nil : alone
        }

        while written.count > 1, let first = written.first, let alone = standaloneRewrite(first),
            spoken.starts(with: alone), spoken.count > alone.count
        {
            before.append(first)
            written.removeFirst()
            spoken.removeFirst(alone.count)
        }
        while written.count > 1, let last = written.last, let alone = standaloneRewrite(last),
            spoken.reversed().starts(with: alone.reversed()), spoken.count > alone.count
        {
            after.insert(last, at: 0)
            written.removeLast()
            spoken.removeLast(alone.count)
        }
        return (before, written, spoken, after)
    }

    /// Aligned runs of two token lists: unchanged tokens come one per hunk
    /// with equal sides; each changed region comes as one hunk.
    private static func hunks(from old: [String], to new: [String]) -> [(written: [String], spoken: [String])] {
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var hunks: [(written: [String], spoken: [String])] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, !removed.contains(i), !inserted.contains(j) {
                hunks.append(([old[i]], [old[i]]))
                i += 1
                j += 1
                continue
            }
            var written: [String] = []
            var spoken: [String] = []
            while i < old.count, removed.contains(i) {
                written.append(old[i])
                i += 1
            }
            while j < new.count, inserted.contains(j) {
                spoken.append(new[j])
                j += 1
            }
            if written.isEmpty, spoken.isEmpty { break }
            hunks.append((written, spoken))
        }
        return hunks
    }

    /// "one hundred and twenty" → "one hundred twenty", as American readers
    /// and Misaki say it.
    private static func americanNumberStyle(_ words: [String]) -> String {
        var kept: [String] = []
        for (index, word) in words.enumerated() {
            if word == "and", let previous = kept.last, scaleWords.contains(previous),
                index + 1 < words.count,
                numberWords.contains(words[index + 1].trimmingCharacters(in: .punctuationCharacters))
            {
                continue
            }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }

    private static let scaleWords: Set<String> = ["hundred", "thousand", "million", "billion", "trillion"]
    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    ]

    private static func assemble(_ pieces: [Piece]) -> EnglishSpokenText {
        var text = ""
        var expansions: [EnglishSpokenText.Expansion] = []
        for piece in pieces {
            if !text.isEmpty { text += " " }
            let start = text.utf16.count
            text += piece.text
            if let source = piece.source {
                expansions.append(.init(range: start..<text.utf16.count, source: source))
            }
        }
        return EnglishSpokenText(text: text, expansions: expansions)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
