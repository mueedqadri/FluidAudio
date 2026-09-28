import Foundation

/// Long-text chunker, sized against the window the models actually have.
///
/// The chunker splits by paragraphs first, then packs whole sentences up to
/// the cap (abbreviation-aware). A sentence that on its own exceeds the cap is
/// split further at word boundaries, preferring clause separators, into pieces
/// of near-equal size (`BalancedSplit`).
///
/// That fallback is a **deviation from the reference**, which only
/// ever breaks at sentence boundaries and hands an over-long sentence to the
/// model whole. We cannot in general: a text axis is frozen into every CoreML
/// export, and anything past it is silently truncated by
/// `Supertonic3UnicodeProcessor.encode`. Dropping words is worse than a seam.
///
/// ## Two caps, not one
///
/// Packing and atomicity are separate questions, and this chunker answers them
/// with separate numbers:
///
/// - `maxTokens` (128) is how much **may be packed together**. Short sentences
///   combine up to it, and every seam so produced is a real sentence boundary
///   the model already knows how to pronounce.
/// - `wholeSentenceTokens` (320) is how long a **single sentence** may be and
///   still be emitted intact, on the wide `.cpuOnly` stages.
///
/// The gap between them is the whole point. A 215-token sentence used to
/// become three chunks with two invented sentence endings inside it; now it is
/// one chunk. It is deliberately *not* packed with its neighbours — a seam
/// between two complete sentences costs nothing, while widening a chunk drags
/// short sentences onto the slower CPU tier for no prosody gain.
///
/// Only a sentence past `wholeSentenceTokens` still splits, and its pieces are
/// then free to land back on the fast tier if they fit.
///
/// ## Why the cap is measured in encoded tokens
///
/// A token is one Unicode *scalar* of the preprocessed string — after NFKD,
/// after the `<lang>…</lang>` wrapper, after the period `preprocess` appends.
/// Measuring candidates any other way silently mis-sizes them:
///
/// - Swift `String.count` counts extended grapheme clusters. Devanagari
///   averages ~1.4 scalars per cluster, so a cap that looks safe in
///   `Character`s overflows the window and loses the tail of the chunk.
/// - NFKD decomposes a Hangul syllable into three jamo and a stacked
///   Vietnamese vowel into up to three scalars, so even a scalar count taken
///   *before* preprocessing understates the cost.
///
/// For Latin text every measure agrees, which is why this stayed invisible.
/// The upstream reference ports disagree with each other on exactly this
/// point — Python counts code points, JavaScript UTF-16 units, Swift grapheme
/// clusters, Rust UTF-8 bytes — and none of them feels it, because their ONNX
/// text axis is symbolic and no window exists to overflow.
///
/// Measuring the encoded form removes the guesswork: one cap serves all 31
/// languages, each script gets the character count it can afford, and there is
/// no per-script table to keep in sync.
enum Supertonic3TextChunker {

    private static let abbreviations: [String] = [
        "Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "Sr.", "Jr.",
        "St.", "Ave.", "Rd.", "Blvd.", "Dept.", "Inc.", "Ltd.",
        "Co.", "Corp.", "etc.", "vs.", "i.e.", "e.g.", "Ph.D.",
    ]

    /// Terminators followed by whitespace: Latin, plus the Devanagari danda
    /// and double danda (`hi`) and the Arabic question mark (`ar`).
    private static let spacedTerminators = ".!?\u{0964}\u{0965}\u{061F}"

    /// Terminators that need no following whitespace. CJK does not space after
    /// its full stop, so requiring one would find no boundaries at all in `ja`.
    private static let unspacedTerminators = "\u{3002}\u{FF01}\u{FF1F}"

    /// Number of tokens `text` occupies once encoded for `lang` — the only
    /// measure the 128-token window responds to.
    static func encodedLength(of text: String, lang: String) -> Int {
        Supertonic3UnicodeProcessor.preprocess(text: text, lang: lang)
            .unicodeScalars.count
    }

    /// Split `text` into chunks the models can synthesize.
    ///
    /// - Parameters:
    ///   - lang: language tag; both the wrapper cost and the terminator set
    ///     depend on it, so it cannot be inferred later.
    ///   - maxTokens: how much may be packed into one chunk. Defaults to the
    ///     tier-1 text axis. Lower it only to leave deliberate headroom.
    ///   - wholeSentenceTokens: how long a single sentence may be and still be
    ///     emitted whole, on the wide tier. Pass `maxTokens` to get the old
    ///     single-cap behavior — which is what callers do when the wide assets
    ///     are not installed.
    static func chunk(
        text rawText: String,
        lang: String,
        maxTokens: Int = Supertonic3Constants.textTFixed,
        wholeSentenceTokens: Int = Supertonic3Constants.tierCeiling
    ) -> [String] {
        // A ceiling below the packing cap would be incoherent; clamp rather
        // than trust the caller, so `wholeSentenceTokens: 0` degrades to
        // single-cap behavior instead of splitting every sentence to nothing.
        let ceiling = max(maxTokens, wholeSentenceTokens)
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return []
        }

        var chunks: [String] = []
        for paragraph in splitParagraphs(trimmed) {
            let para = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if para.isEmpty { continue }

            if encodedLength(of: para, lang: lang) <= maxTokens {
                chunks.append(para)
                continue
            }
            packSentences(
                para, lang: lang, maxTokens: maxTokens,
                wholeSentenceTokens: ceiling, into: &chunks)
        }
        return chunks
    }

    // MARK: - Paragraph split (blank line boundary)

    private static func splitParagraphs(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\n\\s*\\n") else {
            return [text]
        }
        let nsrange = NSRange(text.startIndex..., in: text)
        var lastEnd = text.startIndex
        var paragraphs: [String] = []

        regex.enumerateMatches(in: text, range: nsrange) { match, _, _ in
            if let match = match, let r = Range(match.range, in: text) {
                paragraphs.append(String(text[lastEnd..<r.lowerBound]))
                lastEnd = r.upperBound
            }
        }
        if lastEnd < text.endIndex {
            paragraphs.append(String(text[lastEnd...]))
        }
        return paragraphs.isEmpty ? [text] : paragraphs
    }

    // MARK: - Sentence packing (with clause + word fallbacks)

    private static func packSentences(
        _ paragraph: String, lang: String, maxTokens: Int,
        wholeSentenceTokens: Int, into chunks: inout [String]
    ) {
        var current = ""

        for sentence in splitSentences(paragraph) {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let length = encodedLength(of: trimmed, lang: lang)

            if length > wholeSentenceTokens {
                // Past even the wide tier: the only remaining choice is where
                // the seams land, so put them at clause separators the model
                // already pauses at, in pieces of near-equal size.
                flush(&current, into: &chunks)
                splitEvenly(
                    trimmed, lang: lang, maxTokens: wholeSentenceTokens, into: &chunks)
                continue
            }

            if length > maxTokens {
                // Tier 2: emitted whole and alone. Packing a neighbour in would
                // buy no prosody — the seam it removes is a real sentence
                // boundary — and would move that neighbour onto the CPU tier.
                flush(&current, into: &chunks)
                chunks.append(trimmed)
                continue
            }

            if !current.isEmpty,
                encodedLength(of: "\(current) \(trimmed)", lang: lang) > maxTokens
            {
                chunks.append(current)
                current = ""
            }
            current = current.isEmpty ? trimmed : "\(current) \(trimmed)"
        }
        flush(&current, into: &chunks)
    }

    /// Clause-level break candidates, one step weaker than a sentence end.
    ///
    /// The reference splits on the comma alone, so a sentence joined by a
    /// semicolon or a colon has no candidate above the individual word and its
    /// seams land wherever the budget happened to run out. The model pauses at
    /// all three — measured 290 ms at a comma, 366 ms at a semicolon, 441 ms
    /// at a colon — so a seam placed at one is a break the listener was
    /// already expecting.
    ///
    /// The fullwidth forms decompose to their ASCII equivalents under NFKD,
    /// but that happens in `preprocess`, downstream of here: the chunker reads
    /// the raw text and has to recognise them itself.
    private static let clauseSeparators: Set<Character> = [
        ",", ";", ":",
        "\u{060C}",  // Arabic comma
        "\u{061B}",  // Arabic semicolon
        "\u{3001}",  // ideographic comma
        "\u{FF0C}", "\u{FF1B}", "\u{FF1A}",  // fullwidth comma/semicolon/colon
    ]

    /// Split one over-long sentence by `BalancedSplit`: fewest pieces under
    /// `maxTokens`, cuts after clause separators, even sizes.
    ///
    /// A unit ends at whitespace, or right after `、` and the fullwidth
    /// separators, which CJK writes with no space after them. Unit lengths are estimated as NFKD scalars,
    /// against a cap net of the `<lang>…</lang>` wrapper and a possible appended
    /// period. Encoded length is only roughly additive (`preprocess` expands
    /// dashes and tightens spacing), so each piece is measured exactly and one
    /// that still overruns is split again. A single unit has nowhere to go and
    /// is emitted as it is.
    private static func splitEvenly(
        _ sentence: String, lang: String, maxTokens: Int, into chunks: inout [String]
    ) {
        let units = splitUnits(sentence)
        let lengths = units.map { $0.decomposedStringWithCompatibilityMapping.unicodeScalars.count }
        let clauseBreakAfter = units.dropLast().map {
            BalancedSplit.endsClause($0.trimmingCharacters(in: .whitespacesAndNewlines), marks: clauseMarks)
        }
        let overhead = encodedLength(of: "", lang: lang) + 1
        splitEvenly(
            units, lengths: lengths, clauseBreakAfter: clauseBreakAfter,
            lang: lang, maxTokens: maxTokens, estimatedCap: maxTokens - overhead, into: &chunks)
    }

    private static func splitEvenly(
        _ units: [String], lengths: [Int], clauseBreakAfter: [Bool],
        lang: String, maxTokens: Int, estimatedCap: Int, into chunks: inout [String]
    ) {
        // Each unit carries the whitespace that followed it, so the joiner is empty.
        let groups = BalancedSplit.groups(
            lengths: lengths, separatorLength: 0, clauseBreakAfter: clauseBreakAfter,
            maxLength: estimatedCap)
        for group in groups {
            var piece = units[group].joined()
            if group.count > 1, encodedLength(of: piece, lang: lang) > maxTokens {
                // Under the estimate but over the real window: force one more cut.
                let pieceLengths = Array(lengths[group])
                splitEvenly(
                    Array(units[group]), lengths: pieceLengths,
                    clauseBreakAfter: Array(clauseBreakAfter[group.lowerBound..<(group.upperBound - 1)]),
                    lang: lang, maxTokens: maxTokens,
                    estimatedCap: pieceLengths.reduce(0, +) - 1, into: &chunks)
                continue
            }
            flush(&piece, into: &chunks)
        }
    }

    /// The sentence cut after each whitespace run and after each unspaced
    /// separator; joined back, the units are the sentence.
    private static func splitUnits(_ sentence: String) -> [String] {
        var units: [String] = []
        var buffer = ""
        var inWhitespace = false
        for character in sentence {
            if character.isWhitespace {
                inWhitespace = true
            } else if inWhitespace || unspacedSeparators.contains(buffer.last ?? " ") {
                if !buffer.isEmpty { units.append(buffer) }
                buffer = ""
                inWhitespace = false
            }
            buffer.append(character)
        }
        if !buffer.isEmpty { units.append(buffer) }
        return units
    }

    /// Separators CJK writes with no space after them. A Latin comma is not one:
    /// `1,000` must stay one unit.
    private static let unspacedSeparators: Set<Character> = ["\u{3001}", "\u{FF0C}", "\u{FF1B}", "\u{FF1A}"]

    /// Clause separators and terminators, as they end a word.
    private static let clauseMarks: Set<Character> = clauseSeparators.union([".", "!", "?", "\u{2026}", "\u{2014}"])

    @inline(__always)
    private static func flush(_ buffer: inout String, into chunks: inout [String]) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            chunks.append(trimmed)
        }
        buffer = ""
    }

    // MARK: - Sentence boundary detection (abbreviation aware)

    /// Sentence boundaries, in every script Supertonic supports.
    ///
    /// The reference splits on `([.!?])\s+` alone, so Hindi, Japanese and
    /// Arabic have no boundaries at all and fall straight through to the word
    /// fallback — every seam lands wherever the budget ran out. Note the
    /// reference is internally inconsistent here: its "already ends with
    /// punctuation" check *does* list `。`, so it declines to append a period
    /// after one while still refusing to split there.
    private static func splitSentences(_ text: String) -> [String] {
        let pattern =
            "([\(NSRegularExpression.escapedPattern(for: spacedTerminators))])\\s+"
            + "|([\(NSRegularExpression.escapedPattern(for: unspacedTerminators))])\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [text]
        }
        let nsrange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsrange)
        if matches.isEmpty { return [text] }

        var sentences: [String] = []
        var lastEnd = text.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                matchRange.lowerBound >= lastEnd
            else { continue }

            let beforePunc = String(text[lastEnd..<matchRange.lowerBound])
            guard let puncRange = Range(NSRange(location: match.range.location, length: 1), in: text)
            else { continue }
            let punc = String(text[puncRange])

            // Only Latin terminators can be abbreviation-final ("Dr.", "e.g.").
            if ".!?".contains(punc) {
                let combined = beforePunc.trimmingCharacters(in: .whitespaces) + punc
                if abbreviations.contains(where: { combined.hasSuffix($0) }) { continue }
            }

            sentences.append(String(text[lastEnd..<matchRange.upperBound]))
            lastEnd = matchRange.upperBound
        }
        if lastEnd < text.endIndex {
            sentences.append(String(text[lastEnd...]))
        }
        return sentences.isEmpty ? [text] : sentences
    }
}
