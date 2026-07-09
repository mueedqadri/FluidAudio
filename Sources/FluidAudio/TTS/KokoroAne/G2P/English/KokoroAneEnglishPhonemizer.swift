import Foundation
import NaturalLanguage

/// English text frontend for the KokoroAne chain.
///
/// Word resolution order (mirrors `StyleTTS2Phonemizer` and Kokoro's
/// Misaki frontend):
///   1. caller-supplied custom lexicon (case-sensitive, then lower-cased)
///   2. letter-name overrides for bundled entries that don't read as
///      letter names (`AI`, `US`) — spelled out from per-letter entries
///      (issue #710)
///   3. context-sensitive function words à la Misaki `get_special_case`
///      (`the` → `ði`/`ðə` by the following sound, `to` → `tu`/`tə`/`tʊ`,
///      `a` → `ɐ`, `I` → `ˌI`, `used` past vs "used to", …)
///   4. case-sensitive Misaki lexicon hit on the original spelling
///      (proper nouns, abbreviations like `NATO`)
///   5. phrase-final strong forms for weak function words (Misaki's
///      `None`-keyed gold entries: `this` → `ðˈɪs` before punctuation)
///   6. POS-aware heteronyms (`live`, `wind`, `record`, …): the bundled
///      lexicon cache is flattened to one pronunciation per word, so the
///      Misaki gold dict's POS-keyed entries are restored here, selected
///      by an `NLTagger` lexical-class pass over the input
///   7. case-sensitive hit on the normalized lower-case form, then the
///      lower-cased Misaki lexicon hit — this is what gives function
///      words their weak forms (`to` → `tu`), instead of the BART G2P
///      citation form (`tˈO`) that over-stresses them (issue #691)
///   8. strict ASCII all-caps initialisms (`FBI`, `ATP`) spelled as
///      letter names after a full lexicon miss (issue #710)
///   9. possessive/plural stemming à la Misaki `stem_s` (`country's` /
///      `countries` → `country` + voicing-matched sibilant) — the flattened
///      cache doesn't carry most `-s` forms
///   10. past-tense stemming à la Misaki `stem_ed` (`lived` → `live` + `d`)
///   11. progressive stemming à la Misaki `stem_ing` (`making` → `make` +
///       `ɪŋ`)
///   12. compound split for mixed-shape tokens (`MacReader`, `CASP14`,
///      `living-room`) when every part re-resolves through steps 1–11;
///      all-letter compounds join tightly with Misaki's stress demotion
///   13. BART G2P CoreML fallback for OOV words (injected by the caller)
///
/// Resolution runs right-to-left so each word can see its following
/// context (Misaki `TokenContext`: `future_vowel` drives `the`/`to`,
/// `future_to` drives `used`). Capitalized words gain Misaki's
/// capitalization stress (`0.5`; ALL-CAPS `2`) via ``MisakiStress``.
/// After resolution the final output applies Misaki's symbol remap
/// (`ɾ` → `T`, `ʔ` → `t`) — Kokoro was trained on that alphabet.
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

    /// Keep the runtime trace focused on pronunciation-sensitive tokens rather
    /// than recording a whole document's text. Capitalized words catch names;
    /// suffixes cover the dynamic Misaki stem passes at issue here.
    private static func shouldLogResolution(for word: String) -> Bool {
        let lowered = word.lowercased()
        return word != lowered
            || word.contains(where: { phoneticApostropheCharacters.contains($0) })
            || lowered.hasSuffix("ed")
            || lowered.hasSuffix("ing")
            || (lowered.count > 2 && lowered.hasSuffix("s"))
    }

    private static func logResolution(
        token: String,
        normalized: String,
        posTag: String?,
        route: String,
        phonemes: String
    ) {
        guard shouldLogResolution(for: token) else { return }
        logger.notice(
            "pronunciation.resolve token='\(token)' normalized='\(normalized)' "
                + "pos='\(posTag ?? "none")' route='\(route)' ipa='\(phonemes)'")
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

        let tokens = Self.splitWordTokens(trimmed)
        let heteronymTags = Self.heteronymTags(for: tokens, in: trimmed)

        // Resolve right-to-left so context-sensitive function words can see
        // the following token (Misaki iterates `reversed(tokens)` threading
        // a `TokenContext` the same way).
        var resolved = [String?](repeating: nil, count: tokens.count)
        var context = TokenContext()
        for index in tokens.indices.reversed() {
            let token = tokens[index].token
            if token.isEmpty { continue }

            if token.count == 1, let ch = token.first, !ch.isLetter, !ch.isNumber {
                guard allowedPunctuation.contains(ch) else { continue }
                resolved[index] = String(ch)
                context = Self.tokenContext(context, phonemes: String(ch), token: token)
                continue
            }

            let ipa = try await resolveWord(
                token, posTag: heteronymTags[index], context: context, fallback: fallback)
            resolved[index] = ipa
            context = Self.tokenContext(context, phonemes: ipa, token: token)
        }

        var segments: [PhonemeSegment] = []
        for (index, entry) in tokens.enumerated() {
            guard let ipa = resolved[index] else { continue }
            let token = entry.token

            // Punctuation token (single non-word char from the splitter).
            // Attach to the preceding word — Kokoro's vocab encodes
            // punctuation as its own prosody token, but Misaki output
            // never puts a space before it.
            if token.count == 1, let ch = token.first, !ch.isLetter, !ch.isNumber {
                if segments.isEmpty {
                    segments.append(PhonemeSegment(word: "", phonemes: ipa))
                } else {
                    segments[segments.count - 1].phonemes.append(ipa)
                }
                continue
            }

            segments.append(PhonemeSegment(word: token, phonemes: ipa))
        }

        // Kokoro was trained on Misaki's final output alphabet: the tap and
        // glottal-stop symbols are remapped after resolution (misaki/en.py
        // does `.replace('ɾ', 'T').replace('ʔ', 't')` for Kokoro v1.0).
        for index in segments.indices {
            segments[index].phonemes = segments[index].phonemes
                .replacingOccurrences(of: "ɾ", with: "T")
                .replacingOccurrences(of: "ʔ", with: "t")
        }

        return segments
    }

    // MARK: - Token context (Misaki TokenContext)

    /// Right-to-left resolution context: `futureVowel` is whether the next
    /// pronounced sound is a vowel (`nil` at utterance end or across
    /// non-quote punctuation), `futureTo` is whether the next token is `to`.
    struct TokenContext: Sendable {
        var futureVowel: Bool? = nil
        var futureTo: Bool = false
    }

    private static let nonQuotePuncts = Set(";:,.!?—…()")

    /// Port of Misaki `G2P.token_context`: derive the context the *previous*
    /// word will see from this token's resolved phonemes. The first phoneme
    /// character that is a vowel, consonant, or non-quote punctuation decides
    /// `futureVowel`; quote-only phonemes leave it unchanged, as does an
    /// unresolved token (`phonemes == nil`).
    private static func tokenContext(
        _ context: TokenContext, phonemes: String?, token: String
    ) -> TokenContext {
        var futureVowel = context.futureVowel
        if let phonemes {
            for ch in phonemes {
                if MisakiStress.vowels.contains(ch) {
                    futureVowel = true
                } else if MisakiStress.consonants.contains(ch) {
                    futureVowel = false
                } else if nonQuotePuncts.contains(ch) {
                    futureVowel = nil
                } else {
                    continue
                }
                break
            }
        }
        let futureTo = token == "to" || token == "To" || token == "TO"
        return TokenContext(futureVowel: futureVowel, futureTo: futureTo)
    }

    // MARK: - Heteronym POS tagging

    /// Coarse POS tags (`VERB`/`NOUN`/`ADJ`/`ADV`) for the tokens that are
    /// heteronyms, keyed by token index. The tagger is only constructed when
    /// the input actually contains one, so the common path pays a single
    /// table lookup per word or a small number of candidate-stem lookups.
    /// Tags are resolved up front (no awaits), keeping the non-Sendable
    /// `NLTagger` out of the async resolution loop.
    private static func heteronymTags(
        for tokens: [(token: String, range: Range<String.Index>)],
        in text: String
    ) -> [Int: String] {
        var tags: [Int: String] = [:]
        var tagger: NLTagger?
        for (index, entry) in tokens.enumerated() {
            guard mightNeedHeteronymTag(entry.token) else { continue }
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

    /// Inflected heteronyms need a POS tag even though the full token is not
    /// itself in the heteronym table (`lived` must re-resolve `live` as a
    /// verb). Probe the same bounded candidate set used by the inflection
    /// resolvers, keeping the `NLTagger` lazy on the ordinary path.
    /// Context-sensitive function words whose `specialCase` branch consults
    /// the POS tag (`a` DT, `I` PRP, `by` ADV, `in` IN, `used` VERB/ADJ,
    /// `that` DT, `am`/`an` NOUN guards).
    private static let taggedSpecialWords: Set<String> = [
        "a", "am", "an", "i", "by", "in", "used", "that",
    ]

    private static func mightNeedHeteronymTag(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if taggedSpecialWords.contains(lowered) { return true }
        if EnglishHeteronyms.table[normalizeKey(lowered)] != nil { return true }

        var stems: [String] = []
        if lowered.count >= 3, lowered.hasSuffix("s") {
            if lowered.hasSuffix("'s") {
                stems.append(String(lowered.dropLast(2)))
            } else if !lowered.hasSuffix("ss") {
                stems.append(String(lowered.dropLast()))
                if lowered.count > 4 {
                    if lowered.hasSuffix("ies") {
                        stems.append(String(lowered.dropLast(3)) + "y")
                    } else if lowered.hasSuffix("es") {
                        stems.append(String(lowered.dropLast(2)))
                    }
                }
            }
        } else if lowered.count >= 4, lowered.hasSuffix("d") {
            if !lowered.hasSuffix("dd") {
                stems.append(String(lowered.dropLast()))
            }
            if lowered.count > 4, lowered.hasSuffix("ed"), !lowered.hasSuffix("eed") {
                stems.append(String(lowered.dropLast(2)))
            }
        } else if lowered.count >= 5, lowered.hasSuffix("ing") {
            if lowered.count > 5 {
                stems.append(String(lowered.dropLast(3)))
            }
            stems.append(String(lowered.dropLast(3)) + "e")
            if lowered.count > 5 {
                stems.append(String(lowered.dropLast(4)))
            }
        }

        return stems.contains { EnglishHeteronyms.table[normalizeKey($0)] != nil }
    }

    /// Maps an `NLTagger` lexical class onto the Misaki gold-dict POS buckets
    /// plus the finer tags the special-case words consult (`DT`/`PRP`/`IN`);
    /// nil (→ DEFAULT pronunciation) for everything else. The heteronym
    /// table only keys the four coarse buckets, so the finer tags fall to
    /// DEFAULT there. Tense distinctions (`read`, `reread`, and `wound` past
    /// vs present) are not resolvable at this granularity and stay on
    /// DEFAULT; `used` is recovered via the future-`to` context instead.
    private static func coarsePOSTag(_ tag: NLTag) -> String? {
        switch tag {
        case .verb: return "VERB"
        case .noun: return "NOUN"
        case .adjective: return "ADJ"
        case .adverb: return "ADV"
        case .determiner: return "DT"
        case .pronoun: return "PRP"
        case .preposition: return "IN"
        default: return nil
        }
    }

    // MARK: - Word resolution

    private func resolveWord(
        _ word: String,
        posTag: String? = nil,
        context: TokenContext = TokenContext(),
        fallback: @Sendable (String) async throws -> [String]?
    ) async throws -> String? {
        let normalized = Self.normalizeKey(word)

        // Context-sensitive function words resolve before any lexicon probe
        // (Misaki `get_special_case` runs first in `get_word`) — but after
        // the caller's custom lexicon, which must stay authoritative.
        if customLexicon[word] == nil, customLexicon[normalized] == nil,
            let special = specialCase(word, posTag: posTag, context: context)
        {
            Self.logResolution(
                token: word,
                normalized: normalized,
                posTag: posTag,
                route: "special-case",
                phonemes: special)
            return special
        }

        if let ipa = resolveFromLexicon(word, posTag: posTag, context: context) {
            Self.logResolution(
                token: word,
                normalized: normalized,
                posTag: posTag,
                route: "lexicon-or-stem",
                phonemes: ipa)
            return ipa
        }

        // Contractions the lexicon doesn't carry whole ("Where'd",
        // "that'll") — Misaki's spaCy tokenizer splits them and resolves
        // the pieces from the gold suffix entries, joined tightly.
        if let contraction = resolveContraction(word, posTag: posTag, context: context) {
            Self.logResolution(
                token: word,
                normalized: normalized,
                posTag: posTag,
                route: "contraction",
                phonemes: contraction)
            return contraction
        }

        // Mixed-shape tokens (camelCase compounds like `MacReader`,
        // letter+digit forms like `CASP14`) miss every lexicon as a whole
        // but split cleanly at their case/digit seams. When every part
        // resolves from the lexicon/initialism chain, read the parts;
        // otherwise keep the whole-token BART path so lexicon-shaped names
        // (`McGregor`) aren't chopped into worse fragments.
        if let compound = resolveCompound(word) {
            Self.logResolution(
                token: word,
                normalized: normalized,
                posTag: posTag,
                route: "compound",
                phonemes: compound)
            return compound
        }

        // Residual digit runs (a bare `6` from `6:15`, footnote markers)
        // read as numbers rather than reaching BART, mirroring Misaki's
        // phoneme-level `get_number`.
        if !word.isEmpty, word.allSatisfy(\.isNumber) {
            let spoken = EnglishCompoundWords.spokenWords(forDigits: word)
            let rendered = spoken.compactMap { resolveFromLexicon($0) }
            if !rendered.isEmpty, rendered.count == spoken.count {
                let ipa = rendered.joined(separator: " ")
                Self.logResolution(
                    token: word,
                    normalized: normalized,
                    posTag: posTag,
                    route: "digits",
                    phonemes: ipa)
                return ipa
            }
        }

        guard !normalized.isEmpty else { return nil }
        // Misaki's BART fallback receives the original-cased spelling (with
        // typographic apostrophes normalized) — the grapheme vocabulary is
        // case-sensitive and names phonemize better with their casing.
        let fallbackSpelling = String(
            word.map { phoneticApostropheCharacters.contains($0) ? "'" : $0 })
        do {
            if let phonemes = try await fallback(fallbackSpelling), !phonemes.isEmpty {
                let ipa = phonemes.joined()
                Self.logResolution(
                    token: word,
                    normalized: normalized,
                    posTag: posTag,
                    route: "bart-g2p",
                    phonemes: ipa)
                return ipa
            }
            Self.logger.warning(
                "pronunciation.resolve token='\(word)' normalized='\(normalized)' "
                    + "route='bart-g2p' result='nil' — skipping")
            return nil
        } catch {
            Self.logger.warning(
                "pronunciation.resolve token='\(word)' normalized='\(normalized)' "
                    + "route='bart-g2p' failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Context-sensitive function words (Misaki get_special_case)

    /// Port of the raw-text subset of Misaki `Lexicon.get_special_case`:
    /// determiners and weak function words whose reading depends on the
    /// following sound, the POS tag, or both. Gold-dict values are inlined
    /// (the flattened cache carries only the DEFAULT forms).
    private func specialCase(
        _ rawWord: String, posTag: String?, context: TokenContext
    ) -> String? {
        let word = String(
            rawWord.map { phoneticApostropheCharacters.contains($0) ? "'" : $0 })
        switch word {
        case "that's", "That's", "THAT'S":
            // spaCy splits the contraction and tags `that` DT, so Misaki
            // reads the strong form here regardless of context.
            return "ðˈæts"
        case "a":
            // spaCy tags standalone `a` as DT essentially always; NLTagger
            // sometimes returns no tag, so default the lowercase article to
            // the reduced form rather than the citation `ˈA`.
            return posTag == nil || posTag == "DT" ? "ɐ" : "ˈA"
        case "A":
            return posTag == "DT" ? "ɐ" : "ˈA"
        case "am", "Am", "AM":
            if posTag == "NOUN" { return nil }
            if context.futureVowel == nil || word != "am" { return "æm" }
            return "ɐm"
        case "an", "An", "AN":
            if word == "AN", posTag == "NOUN" { return nil }
            return "ɐn"
        case "I":
            return posTag == "PRP" ? "ˌI" : nil
        case "by", "By", "BY":
            return posTag == "ADV" ? "bˈI" : nil
        case "to", "To", "TO":
            switch context.futureVowel {
            case nil: return "tu"  // golds["to"]
            case false: return "tə"
            case true: return "tʊ"
            }
        case "in", "In", "IN":
            // Misaki: primary stress unless it's a plain preposition with
            // known following context. Treat a missing tag as IN — NLTagger
            // skips common prepositions more often than spaCy does.
            let isPreposition = posTag == nil || posTag == "IN"
            return context.futureVowel == nil || !isPreposition ? "ˈɪn" : "ɪn"
        case "the", "The", "THE":
            return context.futureVowel == true ? "ði" : "ðə"
        case "vs", "vs.", "Vs", "VS":
            return resolveFromLexicon("versus", context: context)
        case "used", "Used", "USED":
            // golds["used"]: VBD `jˈust` before an infinitive ("used to"),
            // DEFAULT `jˈuzd` otherwise. NLTagger has no tense, so accept
            // verb/adjective plus the future-to context like Misaki does.
            if (posTag == "VERB" || posTag == "ADJ"), context.futureTo {
                return "jˈust"
            }
            return "jˈuzd"
        case "that", "That", "THAT":
            // The only gold entry keyed by DT; the flattened cache carries
            // just the weak DEFAULT `ðæt`.
            return posTag == "DT" ? "ðˈæt" : nil
        default:
            return nil
        }
    }

    /// Misaki gold entries keyed by `None`: weak function words that take a
    /// strong (stressed) form phrase-finally — when `futureVowel` is `nil`
    /// (utterance end or before non-quote punctuation). The flattened cache
    /// carries only their weak DEFAULT forms.
    private static let phraseFinalStrongForms: [String: String] = [
        "be": "bˈi", "been": "bˌɪn", "by": "bˈI", "can": "kˈæn",
        "could": "kˈʊd", "could've": "kˈʊdəv", "couldn't": "kˈʊdᵊnt",
        "doth": "dˈʌθ", "get": "ɡˈɛt", "gone": "ɡˈɔn", "got": "ɡˈɑt",
        "had": "hˌæd", "has": "hˈæz", "have": "hˈæv", "her": "hˌɜɹ",
        "hers": "hˈɜɹz", "his": "hˌɪz", "my": "mˈI", "thee": "ðˈi",
        "there": "ðˈɛɹ", "there's": "ðˈɛɹz", "these": "ðˈiz",
        "thine": "ðˈIn", "this": "ðˈɪs", "those": "ðˈOz",
        "through": "θɹˈu", "will": "wˈɪl", "won't": "wˈOnt",
        "would": "wˈʊd", "wouldst": "wˈʊdst", "ye": "jˈi", "yer": "jˈɜɹ",
    ]

    /// The full no-model resolution chain: custom lexicon, letter-name
    /// overrides, case-sensitive/lower-cased Misaki entries, phrase-final
    /// strong forms, heteronyms, and all-caps initialism spell-out. `nil`
    /// means a genuine miss — the caller decides whether to try a compound
    /// split or BART G2P. Lexicon hits gain Misaki's capitalization stress.
    private func resolveFromLexicon(
        _ word: String, posTag: String? = nil, context: TokenContext = TokenContext()
    ) -> String? {
        let normalized = Self.normalizeKey(word)
        let rawLowercased = word.lowercased()

        // Misaki `Lexicon.lookup` applies capitalization stress to every
        // dictionary hit: capitalized words gain a secondary stress when
        // unstressed (0.5), ALL-CAPS gain a primary (2).
        let capStress: Double? =
            word == rawLowercased ? nil : (word == word.uppercased() ? 2 : 0.5)

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
            return MisakiStress.apply(phonemes.joined(), capStress)
        }

        // `normalizeKey` deliberately removes punctuation, but the Misaki
        // cache also contains canonical hyphenated entries such as
        // `short-lived`. Probe the raw lower-cased form before stripping it.
        if rawLowercased != normalized,
            let phonemes = caseSensitiveWordToPhonemes[rawLowercased]
                ?? wordToPhonemes[rawLowercased],
            !phonemes.isEmpty
        {
            return MisakiStress.apply(phonemes.joined(), capStress)
        }

        // Weak function words strengthen phrase-finally (Misaki's
        // `None`-keyed gold entries), ahead of the flattened weak forms.
        if context.futureVowel == nil,
            let strong = Self.phraseFinalStrongForms[normalized]
        {
            return MisakiStress.apply(strong, capStress)
        }

        // The bundled lexicon cache is flattened to each word's DEFAULT
        // reading; heteronyms restore the POS-keyed gold-dict entries and
        // must resolve before it.
        if let entry = EnglishHeteronyms.table[normalized],
            let ipa = posTag.flatMap({ entry[$0] }) ?? entry["DEFAULT"]
        {
            return MisakiStress.apply(ipa, capStress)
        }

        if let phonemes = caseSensitiveWordToPhonemes[normalized]
            ?? wordToPhonemes[normalized],
            !phonemes.isEmpty
        {
            return MisakiStress.apply(phonemes.joined(), capStress)
        }

        // After a full lexicon miss, read strict ASCII all-caps tokens of a
        // small length range as letter-name initialisms (`FBI`, `ATP`)
        // instead of letting BART G2P sound them out as a word (issue #710).
        // Known acronyms (`NASA`, `FIFA`, `OK`, `COVID`) keep their bundled
        // pronunciations because they're resolved above as lexicon hits.
        if EnglishInitialisms.isCandidate(word), let spelled = spellAsLetterNames(word) {
            return spelled
        }

        if let stemmed = resolveStemS(word, posTag: posTag, context: context) {
            return stemmed
        }

        if let stemmed = resolveStemEd(word, posTag: posTag, context: context) {
            return stemmed
        }

        if let stemmed = resolveStemIng(word, posTag: posTag, context: context) {
            return stemmed
        }

        return nil
    }

    // MARK: - Possessives, plurals, and inflections (Misaki stem_s/stem_ed/stem_ing)

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
    private func resolveStemS(
        _ word: String, posTag: String?, context: TokenContext = TokenContext()
    ) -> String? {
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
            if let ipa = resolveFromLexicon(stem, posTag: posTag, context: context) {
                let resolved = Self.appendSibilant(to: ipa)
                Self.logResolution(
                    token: word,
                    normalized: Self.normalizeKey(word),
                    posTag: posTag,
                    route: "stem_s stem='\(stem)' base='\(ipa)'",
                    phonemes: resolved)
                return resolved
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

    private static let usTapContexts: Set<Character> = Set("AIOWYiuæɑəɛɪɹʊʌ")

    /// Append Misaki's US past-tense allomorph. The voiceless set is
    /// intentionally distinct from the plural resolver's set.
    private static func appendPastTense(to ipa: String) -> String {
        guard let last = ipa.last else { return ipa }
        if "pkfθʃsʧ".contains(last) { return ipa + "t" }
        if last == "d" { return ipa + "ᵻd" }
        if last != "t" { return ipa + "d" }

        let characters = Array(ipa)
        guard characters.count >= 2 else { return ipa + "ɪd" }
        if usTapContexts.contains(characters[characters.count - 2]) {
            return String(characters.dropLast()) + "ɾᵻd"
        }
        return ipa + "ᵻd"
    }

    /// Append Misaki's US progressive allomorph, including tapping after the
    /// same vowel/rhotic contexts as the past-tense resolver.
    private static func appendProgressive(to ipa: String) -> String {
        let characters = Array(ipa)
        guard characters.count >= 2,
            characters.last == "t",
            usTapContexts.contains(characters[characters.count - 2])
        else {
            return ipa + "ɪŋ"
        }
        return String(characters.dropLast()) + "ɾɪŋ"
    }

    /// Resolve regular past tense forms by re-resolving a known base through
    /// the full chain, preserving its token-level POS tag for heteronyms.
    private func resolveStemEd(
        _ word: String, posTag: String?, context: TokenContext = TokenContext()
    ) -> String? {
        let lowered = word.lowercased()
        guard lowered.count >= 4, lowered.hasSuffix("d") else { return nil }

        var stems: [String] = []
        if !lowered.hasSuffix("dd") {
            stems.append(String(word.dropLast()))
        }
        if lowered.count > 4, lowered.hasSuffix("ed"), !lowered.hasSuffix("eed") {
            stems.append(String(word.dropLast(2)))
        }

        for stem in stems {
            if let ipa = resolveFromLexicon(stem, posTag: posTag, context: context) {
                let resolved = Self.appendPastTense(to: ipa)
                Self.logResolution(
                    token: word,
                    normalized: Self.normalizeKey(word),
                    posTag: posTag,
                    route: "stem_ed stem='\(stem)' base='\(ipa)'",
                    phonemes: resolved)
                return resolved
            }
        }
        return nil
    }

    /// Resolve regular progressive forms by re-resolving Misaki's ordered
    /// base candidates: direct, silent-e restoration, then doubled consonant.
    private func resolveStemIng(
        _ word: String, posTag: String?, context: TokenContext = TokenContext()
    ) -> String? {
        let lowered = word.lowercased()
        guard lowered.count >= 5, lowered.hasSuffix("ing") else { return nil }

        var stems: [String] = []
        if lowered.count > 5 {
            stems.append(String(word.dropLast(3)))
        }
        stems.append(String(word.dropLast(3)) + "e")

        let characters = Array(lowered)
        let isDoubledConsonant = characters.count > 5
            && characters[characters.count - 4] == characters[characters.count - 5]
            && "bcdgklmnprstvxz".contains(characters[characters.count - 4])
        if lowered.count > 5, (isDoubledConsonant || lowered.hasSuffix("cking")) {
            stems.append(String(word.dropLast(4)))
        }

        for stem in stems {
            if let ipa = resolveFromLexicon(stem, posTag: posTag, context: context) {
                // Misaki passes stress 0.5 into the `-ing` stem lookup: a
                // stem with no stress marks gains a secondary before `ɪŋ`.
                let stressed = word == lowered ? MisakiStress.apply(ipa, 0.5) : ipa
                let resolved = Self.appendProgressive(to: stressed)
                Self.logResolution(
                    token: word,
                    normalized: Self.normalizeKey(word),
                    posTag: posTag,
                    route: "stem_ing stem='\(stem)' base='\(ipa)'",
                    phonemes: resolved)
                return resolved
            }
        }
        return nil
    }

    // MARK: - Contractions

    /// Suffix phonemes from the Misaki gold dict (`'ll` → `əl`, `'d` → `d`,
    /// `'m` → `m`); `'s` is covered by `resolveStemS`. `'re`/`'ve`/`n't`
    /// have no gold entries — words carrying them either exist whole in the
    /// lexicon or fall through to BART, matching Misaki.
    private static let contractionSuffixes: [(suffix: String, ipa: String)] = [
        ("'ll", "əl"), ("'d", "d"), ("'m", "m"),
    ]

    /// Resolve a contraction the lexicon doesn't carry whole by stripping
    /// the suffix and re-resolving the stem (with its special-case and
    /// heteronym handling intact), then appending the suffix phonemes with
    /// Misaki's tight join.
    private func resolveContraction(
        _ word: String, posTag: String?, context: TokenContext
    ) -> String? {
        let canonical = String(
            word.map { phoneticApostropheCharacters.contains($0) ? "'" : $0 })
        let lowered = canonical.lowercased()
        for entry in Self.contractionSuffixes where lowered.hasSuffix(entry.suffix) {
            let stem = String(canonical.dropLast(entry.suffix.count))
            guard stem.count >= 2 else { continue }
            if let ipa = specialCase(stem, posTag: posTag, context: context)
                ?? resolveFromLexicon(stem, posTag: posTag, context: context)
            {
                return ipa + entry.ipa
            }
        }
        return nil
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

        var rendered: [(text: String, ipa: String)] = []
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
                rendered.append((text: spoken, ipa: ipa))
            }
        }
        guard !rendered.isEmpty else { return nil }

        // Misaki's `prespace` rule: compounds whose source text mixes letter
        // and digit classes keep spaces between part phonemes; all-letter
        // compounds (`living-room`, `MacReader`) join tightly with surplus
        // primary stresses demoted (`G2P.resolve_tokens`).
        let isAllLetters = word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "_" }
        guard isAllLetters else {
            return rendered.map(\.ipa).joined(separator: " ")
        }
        return Self.joinTightCompound(rendered)
    }

    /// Port of the no-prespace branch of Misaki `G2P.resolve_tokens`: when a
    /// tight compound carries more primary stresses than half its parts, the
    /// weakest half (unstressed first, then lightest by ``MisakiStress/weight``)
    /// is demoted to secondary. A two-part compound led by a single letter
    /// (`T-shirt`) demotes the second part instead.
    private static func joinTightCompound(_ parts: [(text: String, ipa: String)]) -> String {
        var phonemes = parts.map(\.ipa)
        let indices = phonemes.indices.filter { !phonemes[$0].isEmpty }
        if indices.count == 2, parts[indices[0]].text.count == 1 {
            phonemes[indices[1]] = MisakiStress.apply(phonemes[indices[1]], -0.5)
            return phonemes.joined()
        }
        let stressed = indices.map { index in
            (
                hasPrimary: phonemes[index].contains(MisakiStress.primary),
                weight: MisakiStress.weight(phonemes[index]),
                index: index
            )
        }
        let primaryCount = stressed.count(where: \.hasPrimary)
        if stressed.count >= 2, primaryCount > (stressed.count + 1) / 2 {
            let demoted = stressed.sorted {
                if $0.hasPrimary != $1.hasPrimary { return !$0.hasPrimary }
                if $0.weight != $1.weight { return $0.weight < $1.weight }
                return $0.index < $1.index
            }.prefix(stressed.count / 2)
            for entry in demoted {
                phonemes[entry.index] = MisakiStress.apply(phonemes[entry.index], -0.5)
            }
        }
        return phonemes.joined()
    }

    // MARK: - Letter-name initialisms (issue #710)

    /// Spell a token as a sequence of letter names using the per-letter
    /// entries in the case-sensitive lexicon, shaped like Misaki `get_NNP`:
    /// letters join tightly, every stress demotes to secondary, and the
    /// last one promotes back to primary (`FBI` → `ˌɛfbˌiˈI`, `II` → `ˌIˈI`).
    /// Returns `nil` if any letter is missing so the caller falls through
    /// to its normal fallback rather than emitting a partial word.
    private func spellAsLetterNames(_ word: String) -> String? {
        guard
            let joined = EnglishInitialisms.spell(
                word, letterTokens: { caseSensitiveWordToPhonemes[$0] }, separator: "")
        else { return nil }
        let demoted = MisakiStress.apply(joined, 0)
        guard let lastSecondary = demoted.lastIndex(of: MisakiStress.secondary) else {
            return demoted
        }
        return demoted.replacingCharacters(
            in: lastSecondary...lastSecondary, with: String(MisakiStress.primary))
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
