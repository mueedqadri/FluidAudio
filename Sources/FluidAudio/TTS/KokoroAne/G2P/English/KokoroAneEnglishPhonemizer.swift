import Foundation
import NaturalLanguage

/// English text frontend for the KokoroAne 7-stage chain.
///
/// Word resolution order (mirrors `StyleTTS2Phonemizer` and Kokoro's
/// Misaki frontend):
///   1. caller-supplied custom lexicon (case-sensitive, then lower-cased)
///   2. letter-name overrides for bundled entries that don't read as
///      letter names (`AI`, `US`) — spelled out from per-letter entries
///      (issue #710)
///   3. case-sensitive Misaki lexicon hit on the original spelling
///      (proper nouns, abbreviations like `NATO`)
///   4. POS-aware heteronyms (`live`, `wind`, `record`, …): the bundled
///      lexicon cache is flattened to one pronunciation per word, so the
///      Misaki gold dict's POS-keyed entries are restored here, selected
///      by an `NLTagger` lexical-class pass over the input
///   5. case-sensitive hit on the normalized lower-case form
///   6. lower-cased Misaki lexicon hit — this is what gives function
///      words their weak forms (`to` → `tu`), instead of the BART G2P
///      citation form (`tˈO`) that over-stresses them (issue #691)
///   7. strict ASCII all-caps initialisms (`FBI`, `ATP`) spelled as
///      letter names after a full lexicon miss (issue #710)
///   8. possessive/plural stemming à la Misaki `stem_s` (`country's` /
///      `countries` → `country` + voicing-matched sibilant) — the flattened
///      cache doesn't carry most `-s` forms
///   9. compound split for mixed-shape tokens (`MacReader` → `Mac Reader`,
///      `CASP14` → `C A S P fourteen`) when every part re-resolves through
///      steps 1–8
///   10. BART G2P CoreML fallback for OOV words (injected by the caller)
///
/// Punctuation supported by the chain's `vocab.json` (`, . ! ? ; …` etc.)
/// is preserved and attached to the preceding word — Kokoro treats those
/// tokens as prosody/pause cues, matching upstream `KPipeline.g2p` output.
/// Unlike the StyleTTS2 frontend, Misaki diphthong shorthand (`A O I Y W`)
/// is NOT expanded: the laishere vocab carries those tokens directly.
struct KokoroAneEnglishPhonemizer: Sendable {

    private static let logger = AppLogger(category: "KokoroAneEnglishPhonemizer")

    /// Lower-cased word → ordered Misaki phoneme tokens (pre-filtered
    /// against the chain vocab at load time by `LexiconAssetCache`).
    let wordToPhonemes: [String: [String]]

    /// Original-case word → phoneme tokens (`"AI"`, `"iPhone"`, …).
    let caseSensitiveWordToPhonemes: [String: [String]]

    /// Caller-supplied overrides (word → IPA string), checked before the
    /// Misaki lexicon. Exact spelling wins over the lower-cased form.
    let customLexicon: [String: String]

    /// Punctuation characters the loaded `vocab.json` can encode.
    /// Characters outside this set are dropped (they would be silently
    /// skipped at `KokoroAneVocab.encode` anyway).
    let allowedPunctuation: Set<Character>

    init(
        wordToPhonemes: [String: [String]] = [:],
        caseSensitiveWordToPhonemes: [String: [String]] = [:],
        customLexicon: [String: String] = [:],
        allowedPunctuation: Set<Character> = []
    ) {
        self.wordToPhonemes = wordToPhonemes
        self.caseSensitiveWordToPhonemes = caseSensitiveWordToPhonemes
        self.customLexicon = customLexicon
        self.allowedPunctuation = allowedPunctuation
    }

    /// One resolved word and the IPA it produced. Kept punctuation is appended
    /// to the preceding word's `phonemes` (matching the flat-string shape), so
    /// a segment's `phonemes` may carry a trailing prosody/pause token. A
    /// leading punctuation run with no preceding word yields a segment with an
    /// empty `word`.
    struct PhonemeSegment: Sendable, Equatable {
        let word: String
        var phonemes: String
    }

    /// Convert text to a Misaki-style IPA string. Words are joined with
    /// single spaces; kept punctuation attaches to the preceding word
    /// (`"Hello, world!"` → `"həlˈO, wˈɜɹld!"` shape).
    ///
    /// - Parameter fallback: per-word G2P for words missing from every
    ///   lexicon. Receives the normalized (lower-cased) spelling. `nil`
    ///   return skips the word with a warning; a thrown error aborts.
    /// - Throws: `KokoroAneError.inputProcessingFailed` when the input is
    ///   empty or nothing could be resolved.
    func phonemize(
        _ text: String,
        fallback: @Sendable (String) async throws -> [String]?
    ) async throws -> String {
        let segments = try await phonemizeSegments(text, fallback: fallback)
        let joined = segments.map(\.phonemes).joined(separator: " ")
        if joined.isEmpty {
            throw KokoroAneError.inputProcessingFailed(
                "produced no phonemes for input '\(text.trimmingCharacters(in: .whitespacesAndNewlines))'")
        }
        return joined
    }

    /// Same resolution as `phonemize`, but returns one `PhonemeSegment` per
    /// resolved source word instead of collapsing to a flat string. The flat
    /// string is exactly `segments.map(\.phonemes).joined(separator: " ")`, so
    /// callers can recover the per-word phoneme spans needed for word-level
    /// timing. Throws on empty input.
    func phonemizeSegments(
        _ text: String,
        fallback: @Sendable (String) async throws -> [String]?
    ) async throws -> [PhonemeSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KokoroAneError.inputProcessingFailed("(empty input)")
        }

        var segments: [PhonemeSegment] = []

        let tokens = Self.splitWordTokens(trimmed)
        let heteronymTags = Self.heteronymTags(for: tokens, in: trimmed)

        for (index, entry) in tokens.enumerated() {
            let token = entry.token
            if token.isEmpty { continue }

            // Punctuation token (single non-word char from the splitter).
            if token.count == 1, let ch = token.first, !ch.isLetter, !ch.isNumber {
                guard allowedPunctuation.contains(ch) else { continue }
                // Attach to the preceding word — Kokoro's vocab encodes
                // punctuation as its own prosody token, but Misaki output
                // never puts a space before it.
                if segments.isEmpty {
                    segments.append(PhonemeSegment(word: "", phonemes: String(ch)))
                } else {
                    segments[segments.count - 1].phonemes.append(ch)
                }
                continue
            }

            if let ipa = try await resolveWord(token, posTag: heteronymTags[index], fallback: fallback) {
                segments.append(PhonemeSegment(word: token, phonemes: ipa))
            }
        }

        return segments
    }

    // MARK: - Heteronym POS tagging

    /// Coarse POS tags (`VERB`/`NOUN`/`ADJ`/`ADV`) for the tokens that are
    /// heteronyms, keyed by token index. The tagger is only constructed when
    /// the input actually contains one, so the common path pays a single
    /// table lookup per word. Tags are resolved up front (no awaits), keeping
    /// the non-Sendable `NLTagger` out of the async resolution loop.
    private static func heteronymTags(
        for tokens: [(token: String, range: Range<String.Index>)],
        in text: String
    ) -> [Int: String] {
        var tags: [Int: String] = [:]
        var tagger: NLTagger?
        for (index, entry) in tokens.enumerated() {
            guard EnglishHeteronyms.table[normalizeKey(entry.token)] != nil else { continue }
            if tagger == nil {
                let fresh = NLTagger(tagSchemes: [.lexicalClass])
                fresh.string = text
                tagger = fresh
            }
            guard let tag = tagger?.tag(at: entry.range.lowerBound, unit: .word, scheme: .lexicalClass).0,
                let coarse = coarsePOSTag(tag)
            else { continue }
            tags[index] = coarse
        }
        return tags
    }

    /// Maps an `NLTagger` lexical class onto the Misaki gold-dict POS buckets;
    /// nil (→ DEFAULT pronunciation) for everything else. Tense distinctions
    /// (`read` past vs present) are not resolvable at this granularity and
    /// stay on DEFAULT.
    private static func coarsePOSTag(_ tag: NLTag) -> String? {
        switch tag {
        case .verb: return "VERB"
        case .noun: return "NOUN"
        case .adjective: return "ADJ"
        case .adverb: return "ADV"
        default: return nil
        }
    }

    // MARK: - Word resolution

    private func resolveWord(
        _ word: String,
        posTag: String? = nil,
        fallback: @Sendable (String) async throws -> [String]?
    ) async throws -> String? {
        if let ipa = resolveFromLexicon(word, posTag: posTag) {
            return ipa
        }

        // Mixed-shape tokens (camelCase compounds like `MacReader`,
        // letter+digit forms like `CASP14`) miss every lexicon as a whole
        // but split cleanly at their case/digit seams. When every part
        // resolves from the lexicon/initialism chain, read the parts;
        // otherwise keep the whole-token BART path so lexicon-shaped names
        // (`McGregor`) aren't chopped into worse fragments.
        if let compound = resolveCompound(word) {
            return compound
        }

        let normalized = Self.normalizeKey(word)
        guard !normalized.isEmpty else { return nil }
        do {
            if let phonemes = try await fallback(normalized), !phonemes.isEmpty {
                return phonemes.joined()
            }
            Self.logger.warning("G2P returned nil for word '\(normalized)' — skipping")
            return nil
        } catch {
            Self.logger.warning("G2P failed on word '\(normalized)': \(error.localizedDescription)")
            throw error
        }
    }

    /// The full no-model resolution chain: custom lexicon, letter-name
    /// overrides, case-sensitive/lower-cased Misaki entries, heteronyms,
    /// and all-caps initialism spell-out. `nil` means a genuine miss — the
    /// caller decides whether to try a compound split or BART G2P.
    private func resolveFromLexicon(_ word: String, posTag: String? = nil) -> String? {
        let normalized = Self.normalizeKey(word)

        if let custom = customLexicon[word] ?? customLexicon[normalized] {
            return custom
        }

        // A few bundled case-sensitive entries don't read as letter names
        // even though uppercase callers expect them to (`AI` → blended
        // `ˈAˌI`, `US` → the lowercase-pronoun `ʌs` shape). Spell those out
        // before consulting the lexicon so they sound like `A I` / `U S`
        // (issue #710). Lowercase `us`/`ai` are untouched — the override
        // only matches the exact uppercase spelling.
        if EnglishInitialisms.letterNameOverrides.contains(word) {
            if let spelled = spellAsLetterNames(word) {
                return spelled
            }
            // Per-letter entries should always be present when the full
            // lexicon is loaded; if they aren't (e.g. a letter was filtered
            // out of the cache) the override below silently becomes the
            // blended shape it was meant to bypass — log so it isn't silent.
            Self.logger.warning(
                "Letter-name override '\(word)' unspellable (missing per-letter lexicon entries); "
                    + "falling back to the bundled pronunciation")
        }

        // An exact original-spelling hit (proper nouns, `NATO`) still wins
        // over the heteronym table.
        if let phonemes = caseSensitiveWordToPhonemes[word], !phonemes.isEmpty {
            return phonemes.joined()
        }

        // The bundled lexicon cache is flattened to each word's DEFAULT
        // reading; heteronyms restore the POS-keyed gold-dict entries and
        // must resolve before it.
        if let entry = EnglishHeteronyms.table[normalized],
            let ipa = posTag.flatMap({ entry[$0] }) ?? entry["DEFAULT"]
        {
            return ipa
        }

        if let phonemes = caseSensitiveWordToPhonemes[normalized]
            ?? wordToPhonemes[normalized],
            !phonemes.isEmpty
        {
            return phonemes.joined()
        }

        // After a full lexicon miss, read strict ASCII all-caps tokens of a
        // small length range as letter-name initialisms (`FBI`, `ATP`)
        // instead of letting BART G2P sound them out as a word (issue #710).
        // Known acronyms (`NASA`, `FIFA`, `OK`, `COVID`) keep their bundled
        // pronunciations because they're resolved above as lexicon hits.
        if EnglishInitialisms.isCandidate(word), let spelled = spellAsLetterNames(word) {
            return spelled
        }

        if let stemmed = resolveStemS(word, posTag: posTag) {
            return stemmed
        }

        return nil
    }

    // MARK: - Possessives and regular plurals (Misaki stem_s)

    /// Python Misaki resolves `-s` forms at runtime (`Lexicon.stem_s`): the
    /// flattened lexicon cache stores `country` but not `country's` or
    /// `countries`, so those miss every map and would reach BART G2P with
    /// the apostrophe still in the string. Mirror it here: strip the
    /// possessive/plural suffix, re-resolve the stem through this chain,
    /// and append the voicing-matched sibilant.
    ///
    /// Stem candidates follow Misaki's order — plain `-s` (`cats` → `cat`,
    /// blocked for `-ss`), `-'s` (`country's` → `country`), `-ies` →
    /// `y` (`countries` → `country`), `-es` (`boxes` → `box`) — and only a
    /// stem the chain already knows produces a reading; anything else stays
    /// on the whole-token path.
    private func resolveStemS(_ word: String, posTag: String?) -> String? {
        let lowered = word.lowercased()
        guard lowered.count >= 3, lowered.hasSuffix("s") else { return nil }

        var stems: [String] = []
        if lowered.hasSuffix("'s") {
            stems.append(String(word.dropLast(2)))
        } else if !lowered.hasSuffix("ss") {
            stems.append(String(word.dropLast(1)))
            if lowered.count > 4 {
                if lowered.hasSuffix("ies") {
                    stems.append(String(word.dropLast(3)) + "y")
                } else if lowered.hasSuffix("es") {
                    stems.append(String(word.dropLast(2)))
                }
            }
        }

        for stem in stems {
            if let ipa = resolveFromLexicon(stem, posTag: posTag) {
                return Self.appendSibilant(to: ipa)
            }
        }
        return nil
    }

    /// Append the `-s` morpheme the way the lexicon's own plural entries are
    /// written (Misaki `Lexicon._s`): `s` after voiceless stops/fricatives
    /// (`kˈæt` → `kˈæts`), `ᵻz` after sibilants (`bˈɑks` → `bˈɑksᵻz`), `z`
    /// after everything voiced (`kˈʌntɹi` → `kˈʌntɹiz`).
    private static func appendSibilant(to ipa: String) -> String {
        guard let last = ipa.last else { return ipa }
        if "ptkfθ".contains(last) { return ipa + "s" }
        if "szʃʒʧʤ".contains(last) { return ipa + "ᵻz" }
        return ipa + "z"
    }

    // MARK: - Compound tokens (camelCase / letter+digit)

    /// Read a mixed-shape token as its parts: split at case and digit seams
    /// (``EnglishCompoundWords/splitParts(_:)``), spell digit runs as words,
    /// and resolve every piece through ``resolveFromLexicon``. Returns `nil`
    /// — leaving the token on its existing whole-word path — when the token
    /// has no seams, contains an apostrophe (`Alice's` must not read its
    /// possessive as the letter name `S`), or any part misses the lexicon.
    /// The one apostrophe form handled is a trailing `'s`: the possessive of
    /// a resolvable compound reads as the compound plus the voicing-matched
    /// sibilant (`MacReader's` → `mæk ɹˈidəɹz`).
    private func resolveCompound(_ word: String) -> String? {
        if word.count >= 3, let apostrophe = word.dropLast().last,
            phoneticApostropheCharacters.contains(apostrophe),
            word.last == "s" || word.last == "S"
        {
            return resolveCompound(String(word.dropLast(2))).map(Self.appendSibilant(to:))
        }
        guard !word.contains(where: { phoneticApostropheCharacters.contains($0) }) else { return nil }
        let parts = EnglishCompoundWords.splitParts(word)
        guard !parts.isEmpty, parts != [word] else { return nil }

        var rendered: [String] = []
        for part in parts {
            let spokenWords: [String]
            if part.first?.isNumber == true {
                spokenWords = EnglishCompoundWords.spokenWords(forDigits: part)
            } else {
                spokenWords = [part]
            }
            guard !spokenWords.isEmpty else { return nil }
            for spoken in spokenWords {
                guard let ipa = resolveFromLexicon(spoken) else { return nil }
                rendered.append(ipa)
            }
        }
        return rendered.isEmpty ? nil : rendered.joined(separator: " ")
    }

    // MARK: - Letter-name initialisms (issue #710)

    /// Spell a token as a sequence of letter names using the per-letter
    /// entries in the case-sensitive lexicon (`FBI` → `ˈɛf bˈi ˈI`). See
    /// ``EnglishInitialisms/spell(_:letterTokens:render:separator:)`` —
    /// returns `nil` if any letter is missing so the caller falls through
    /// to its normal fallback rather than emitting a partial word.
    private func spellAsLetterNames(_ word: String) -> String? {
        EnglishInitialisms.spell(word) { caseSensitiveWordToPhonemes[$0] }
    }

    /// Lowercase + strip non-letter/digit/apostrophe chars so we hit the
    /// same Misaki cache entries the preprocessor wrote.
    static func normalizeKey(_ word: String) -> String {
        let lowered = String(word.lowercased().map { ch in
            phoneticApostropheCharacters.contains(ch) ? "'" : ch
        })
        let allowedSet = CharacterSet.letters.union(.decimalDigits)
            .union(CharacterSet(charactersIn: "'"))
        let filtered = lowered.unicodeScalars.filter { allowedSet.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }

    // MARK: - Word splitter

    private static let knownLeadingApostropheWords: Set<String> = [
        "'cause", "'em", "'til", "'tis", "'twas", "'twere",
    ]

    /// Emit runs of letters/digits (internal apostrophes and hyphens stay
    /// inside words: `don't`, `twenty-one`), single punctuation chars as
    /// their own tokens, and drop whitespace. Same shape as the StyleTTS2
    /// frontend's imitation of `nltk.word_tokenize`.
    static func splitWords(_ text: String) -> [String] {
        splitWordTokens(text).map(\.token)
    }

    /// `splitWords` with each token's source range in `text`, so the
    /// heteronym pass can ask the POS tagger about a specific occurrence.
    static func splitWordTokens(_ text: String) -> [(token: String, range: Range<String.Index>)] {
        var out: [(token: String, range: Range<String.Index>)] = []
        var current: String = ""
        var currentStart: String.Index?

        @inline(__always) func flushCurrent(endingAt end: String.Index) {
            if !current.isEmpty, let start = currentStart {
                out.append((token: current, range: start..<end))
                current.removeAll(keepingCapacity: true)
            }
            currentStart = nil
        }

        for index in text.indices {
            let ch = text[index]
            if ch.isWhitespace {
                flushCurrent(endingAt: index)
            } else if phoneticApostropheCharacters.contains(ch) {
                let nextIndex = text.index(after: index)
                let nextIsWord =
                    nextIndex < text.endIndex
                    && (text[nextIndex].isLetter || text[nextIndex].isNumber)
                if !current.isEmpty && nextIsWord {
                    current.append("'")
                } else if current.isEmpty && Self.startsKnownLeadingApostropheWord(in: text, at: index) {
                    currentStart = index
                    current.append("'")
                } else {
                    flushCurrent(endingAt: index)
                    out.append((token: String(ch), range: index..<text.index(after: index)))
                }
            } else if ch.isLetter || ch.isNumber || ch == "-" {
                if current.isEmpty { currentStart = index }
                current.append(ch)
            } else {
                flushCurrent(endingAt: index)
                out.append((token: String(ch), range: index..<text.index(after: index)))
            }
        }
        flushCurrent(endingAt: text.endIndex)
        return out
    }

    private static func startsKnownLeadingApostropheWord(
        in text: String,
        at apostropheIndex: String.Index
    ) -> Bool {
        let nextIndex = text.index(after: apostropheIndex)
        guard nextIndex < text.endIndex, text[nextIndex].isLetter else {
            return false
        }

        var endIndex = nextIndex
        while endIndex < text.endIndex, text[endIndex].isLetter {
            endIndex = text.index(after: endIndex)
        }

        let candidate = "'" + text[nextIndex..<endIndex].lowercased()
        return knownLeadingApostropheWords.contains(candidate)
    }
}
