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

    /// `text` with its numbers, symbols and abbreviations in spoken form.
    ///
    /// NeMo reads the whole sentence and every rewrite it makes is kept, so a
    /// number keeps its context (`26 kg`, `Oct 10`, `$4.50`) and titles,
    /// emails and web addresses read as words. Our own rules
    /// (``EnglishReferenceAbbreviations/spell(_:)``, then
    /// ``spellRangesAndSymbols(_:)``) run first and hold the forms NeMo
    /// misreads or leaves silent (`cf.`, `hrs`, `2019b`, ranges, `±`, `×`);
    /// digits NeMo leaves alone go through ``normalize(_:)``.
    static func spokenText(_ text: String) -> EnglishSpokenText {
        let text = EnglishOldMoney.joiningSpacedCurrency(text)
        var pieces = text.split(whereSeparator: \.isWhitespace).map { Piece(text: String($0), source: nil) }
        pieces = rewrite(pieces, keepingOnlyDigitRewrites: false, leavingOpen: true, with: editWrittenForms)
        pieces = rewrite(pieces, keepingOnlyDigitRewrites: false) {
            spellRangesAndSymbols(
                EnglishGreekLetters.spell(
                    EnglishReferenceAbbreviations.spell(
                        EnglishGluedNumbers.spell(
                            EnglishFormulas.spell(
                                EnglishRomanNumerals.spell(
                                    EnglishAbbreviationTable.spellWords(EnglishOldMoney.spell($0))))))))
        }
        pieces = rewrite(pieces, keepingOnlyDigitRewrites: false, when: nemoMayRead, holding: nemoMisreads) {
            // NeMo reads `=` as "equal sign" when a percent sits on its left, and
            // after a title it expands splits a possessive before punctuation
            // (`St. James’s.` → `Saint James’ s.`).
            NemoTextNormalizer.normalize($0, language: .english)
                .replacingOccurrences(of: "equal sign", with: "equals")
                .replacingOccurrences(of: #"(?<=[A-Za-z][’'])\ss\b"#, with: "s", options: .regularExpression)
        }
        pieces = rewrite(pieces, with: normalize)
        // NeMo drops the full stop an abbreviation shares with the sentence (`5 p.m.` → `five PM`).
        if let last = pieces.last, let source = last.source, source.hasSuffix("."),
            let end = last.text.last, !".!?".contains(end)
        {
            pieces[pieces.count - 1] = Piece(text: last.text + ".", source: source)
        }
        return assemble(pieces)
    }

    /// Written words NeMo may read differently: a digit, a symbol, a dotted
    /// form (`U.S.`, `jane.doe`) or a capitalized run (`NASA`, `VIII`).
    /// Abbreviations are the table's (``EnglishAbbreviationTable/spellWords(_:)``),
    /// so a stretch with none of these skips NeMo, which costs tens of
    /// milliseconds a sentence.
    private static func nemoMayRead(_ word: String) -> Bool {
        word.contains(where: { $0.isASCIIDigit || "@#&$%€£¥+=/<>×±°§~^".contains($0) })
            || word.range(of: #"[A-Za-z]\.[A-Za-z]|[A-Z]{2,}"#, options: .regularExpression) != nil
    }

    /// Written words NeMo reads wrongly: `AT&T` → `ATANDT`, initials it joins
    /// into a word (`A. M. Turing` → `AM`), `etc.` as one word the lexicon lacks, a
    /// slash between words (`and/or` → `and slash or`), a word it joins to the
    /// one before (`to ’Frisco` → `to’Frisco`), and markup it names aloud
    /// (`_War_`, `*`, `|`, `M^{rs}`, `mother.--Yours` and `Jan.-Mar.` → `dot
    /// dash`). The phonemizer reads each of them as it did before NeMo.
    private static func nemoMisreads(_ word: String) -> Bool {
        word.contains(where: { "*|{}".contains($0) }) || word.contains("--") || word.contains(".-")
            || word.range(of: #"^[‘’'][A-Za-z]"#, options: .regularExpression) != nil
            || word.range(of: #"(?:^|[^A-Za-z0-9])_|_(?:$|[^A-Za-z0-9])"#, options: .regularExpression) != nil
            || word.range(
                of: #"^\W*(?:[A-Z]+&[A-Z]+|[A-Z]\.|[Ee]tc\.|[-+=~]{2,}|[A-Za-z]+(?:/[A-Za-z]+)+)\W*$"#,
                options: .regularExpression) != nil
    }

    /// A whitespace-separated piece of the output; `source` is set when it is
    /// spoken words that replace written ones. An open piece is a written form
    /// a rule edited for the stages after it to read (`50–175` → `50 to 175`).
    private struct Piece {
        let text: String
        let source: String?
        var isOpen = false
    }

    /// Run `rewriter` over each stretch of pieces still to be read: untouched
    /// ones and open ones. With `keepingOnlyDigitRewrites`, only stretches
    /// holding a digit are read and only rewrites of written words with a
    /// digit are kept, which is how the ``normalize(_:)`` fallback runs. A
    /// stretch is read only when a word in it passes `when`; pieces `holding`
    /// accepts pass through unread. `leavingOpen` keeps the rewrites open. A
    /// rewrite that touches an open piece covers all of it, so its page words
    /// stay one span.
    private static func rewrite(
        _ pieces: [Piece],
        keepingOnlyDigitRewrites: Bool = true,
        leavingOpen: Bool = false,
        when needsReading: (String) -> Bool = { _ in true },
        holding: (String) -> Bool = { _ in false },
        with rewriter: (String) -> String
    ) -> [Piece] {
        var result: [Piece] = []
        var stretch: [Piece] = []

        func flush() {
            defer { stretch.removeAll() }
            var tokens: [String] = []
            var owners: [Int] = []
            for (index, piece) in stretch.enumerated() {
                let words = piece.text.split(whereSeparator: \.isWhitespace).map(String.init)
                tokens += words
                owners += Array(repeating: index, count: words.count)
            }
            guard tokens.contains(where: needsReading),
                !keepingOnlyDigitRewrites || tokens.contains(where: { $0.contains(where: \.isASCIIDigit) })
            else {
                result += stretch
                return
            }
            let rewritten = rewriter(tokens.joined(separator: " "))
                .split(whereSeparator: \.isWhitespace).map(String.init)

            // Hunks joined so none ends inside a piece.
            var groups: [(written: Range<Int>, spoken: [String])] = []
            var position = 0
            for hunk in hunks(from: tokens, to: rewritten) {
                let range = position..<(position + hunk.written.count)
                position = range.upperBound
                if let last = groups.last, last.written.upperBound > 0, last.written.upperBound < tokens.count,
                    owners[last.written.upperBound - 1] == owners[last.written.upperBound]
                {
                    groups[groups.count - 1] = (last.written.lowerBound..<range.upperBound, last.spoken + hunk.spoken)
                } else {
                    groups.append((range, hunk.spoken))
                }
            }

            for group in groups {
                let written = Array(tokens[group.written])
                let covered = group.written.isEmpty ? [] : Array(Set(owners[group.written])).sorted()
                guard written != group.spoken, !group.spoken.isEmpty,
                    !keepingOnlyDigitRewrites || written.contains(where: { $0.contains(where: \.isASCIIDigit) })
                else {
                    result += covered.map { stretch[$0] }
                    continue
                }
                // An edge word that reads the same alone is its own piece, so word
                // timings keep one written word per span (`1915, Mr.`); the digit-only
                // fallback leaves it as written. An open piece's words stay together.
                let trimmed = trimmingStandaloneRewrites(
                    (written, group.spoken), trimmable: group.written.map { !stretch[owners[$0]].isOpen },
                    with: rewriter)
                func edge(_ word: (written: String, spoken: [String])) -> Piece {
                    keepingOnlyDigitRewrites
                        ? Piece(text: word.written, source: nil)
                        : Piece(text: word.spoken.joined(separator: " "), source: word.written)
                }
                let kept = covered.dropFirst(trimmed.before.count).dropLast(trimmed.after.count)
                result += trimmed.before.map(edge)
                result.append(
                    Piece(
                        text: americanNumberStyle(trimmed.spoken),
                        source: kept.map { stretch[$0].source ?? stretch[$0].text }.joined(separator: " "),
                        isOpen: leavingOpen))
                result += trimmed.after.map(edge)
            }
        }

        for piece in pieces {
            let words = piece.text.split(whereSeparator: \.isWhitespace).map(String.init)
            if piece.source == nil || piece.isOpen, !words.contains(where: holding) {
                stretch.append(piece)
            } else {
                flush()
                result.append(piece)
            }
        }
        flush()
        return result
    }

    /// Hands back, with their spoken words, a changed region's edge words that
    /// `rewriter` changes the same way on their own, with no number beside
    /// them: `Mr.` → `mister` next to `1915,` is a title, while `kg` next to
    /// `26` only changes with its number.
    private static func trimmingStandaloneRewrites(
        _ hunk: (written: [String], spoken: [String]),
        trimmable: [Bool],
        with rewriter: (String) -> String
    ) -> (
        before: [(written: String, spoken: [String])], written: [String], spoken: [String],
        after: [(written: String, spoken: [String])]
    ) {
        var written = hunk.written
        var spoken = hunk.spoken
        var before: [(written: String, spoken: [String])] = []
        var after: [(written: String, spoken: [String])] = []

        func standaloneRewrite(_ word: String) -> [String]? {
            guard !word.contains(where: \.isASCIIDigit), word.contains(where: \.isLetter) else { return nil }
            let alone = rewriter(word).split(whereSeparator: \.isWhitespace).map(String.init)
            return alone == [word] ? nil : alone
        }

        var trimmable = trimmable[...]
        while written.count > 1, trimmable.first == true, let first = written.first,
            let alone = standaloneRewrite(first), spoken.starts(with: alone), spoken.count > alone.count
        {
            before.append((first, alone))
            written.removeFirst()
            trimmable.removeFirst()
            spoken.removeFirst(alone.count)
        }
        while written.count > 1, trimmable.last == true, let last = written.last,
            let alone = standaloneRewrite(last), spoken.reversed().starts(with: alone.reversed()),
            spoken.count > alone.count
        {
            after.insert((last, alone), at: 0)
            written.removeLast()
            trimmable.removeLast()
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
