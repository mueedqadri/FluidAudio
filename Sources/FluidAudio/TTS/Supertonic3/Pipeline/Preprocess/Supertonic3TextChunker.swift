import Foundation

/// Long-text chunker, sized against the window the models actually have.
///
/// The chunker splits by paragraphs first, then packs whole sentences up to
/// the cap (abbreviation-aware). A sentence that on its own exceeds the cap is
/// split further — first at clause separators, then at whitespace.
///
/// Those last two fallbacks are a **deviation from the reference**, which only
/// ever breaks at sentence boundaries and hands an over-long sentence to the
/// model whole. We cannot: `textTFixed = 128` is frozen into the CoreML
/// export, and anything past it is silently truncated by
/// `Supertonic3UnicodeProcessor.encode`. Dropping words is worse than a seam,
/// so the fallbacks stay until the text stages are re-exported with a larger
/// text axis.
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

    /// Split `text` so that every chunk encodes to at most `maxTokens`.
    ///
    /// - Parameters:
    ///   - lang: language tag; both the wrapper cost and the terminator set
    ///     depend on it, so it cannot be inferred later.
    ///   - maxTokens: defaults to the models' pinned text axis. Lower it only
    ///     to leave deliberate headroom.
    static func chunk(
        text rawText: String,
        lang: String,
        maxTokens: Int = Supertonic3Constants.textTFixed
    ) -> [String] {
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
            packSentences(para, lang: lang, maxTokens: maxTokens, into: &chunks)
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
        _ paragraph: String, lang: String, maxTokens: Int, into chunks: inout [String]
    ) {
        var current = ""

        for sentence in splitSentences(paragraph) {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if encodedLength(of: trimmed, lang: lang) > maxTokens {
                flush(&current, into: &chunks)
                packClauses(trimmed, lang: lang, maxTokens: maxTokens, into: &chunks)
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

    private static func packClauses(
        _ sentence: String, lang: String, maxTokens: Int, into chunks: inout [String]
    ) {
        var current = ""
        for rawPart in splitClauses(sentence) {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty { continue }

            if encodedLength(of: part, lang: lang) > maxTokens {
                flush(&current, into: &chunks)
                packWords(part, lang: lang, maxTokens: maxTokens, into: &chunks)
                continue
            }

            if !current.isEmpty,
                encodedLength(of: "\(current) \(part)", lang: lang) > maxTokens
            {
                chunks.append(current)
                current = ""
            }
            current = current.isEmpty ? part : "\(current) \(part)"
        }
        flush(&current, into: &chunks)
    }

    /// Split at clause separators, keeping each separator on the part it ends.
    ///
    /// Retaining it matters twice over: the packer can rejoin parts without
    /// inventing punctuation that wasn't there, and a chunk that ends at a
    /// separator keeps it, so `preprocess` sees a clause ending rather than a
    /// bare fragment it has to terminate with a fabricated period.
    private static func splitClauses(_ sentence: String) -> [String] {
        var parts: [String] = []
        var buffer = ""
        for character in sentence {
            buffer.append(character)
            if clauseSeparators.contains(character) {
                parts.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            parts.append(buffer)
        }
        return parts
    }

    private static func packWords(
        _ phrase: String, lang: String, maxTokens: Int, into chunks: inout [String]
    ) {
        var current = ""
        for word in phrase.split(whereSeparator: { $0.isWhitespace }) {
            let w = String(word)
            if !current.isEmpty,
                encodedLength(of: "\(current) \(w)", lang: lang) > maxTokens
            {
                chunks.append(current)
                current = ""
            }
            current = current.isEmpty ? w : "\(current) \(w)"
        }
        flush(&current, into: &chunks)
    }

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
