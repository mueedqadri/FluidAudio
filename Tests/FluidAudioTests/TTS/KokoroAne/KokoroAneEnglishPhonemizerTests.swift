import Foundation
import XCTest

@testable import FluidAudio

/// Tests for the English KokoroAne text frontend (issue #691): Misaki
/// lexicon weak forms beat the BART G2P citation forms, punctuation is
/// preserved as prosody tokens, and custom-lexicon overrides win.
final class KokoroAneEnglishPhonemizerTests: XCTestCase {

    /// Misaki-style lexicon stand-in. `to` is the issue #691 word: the
    /// lexicon carries the unstressed weak form while BART G2P returns
    /// the stressed citation form `tˈO`.
    private let lexicon: [String: [String]] = [
        "'em": ["ə", "m"],
        "'til": ["t", "ˈ", "I", "l"],
        "'twas": ["t", "w", "ˈ", "ɑ", "z"],
        "to": ["t", "u"],
        "i": ["ˈ", "I"],
        "they": ["ð", "ˈ", "A"],
        "want": ["w", "ˈ", "ɑ", "n", "t"],
        "go": ["ɡ", "ˈ", "O"],
        "hello": ["h", "ə", "l", "ˈ", "O"],
        "there's": ["ð", "ɛ", "ɹ", "z"],
        "world": ["w", "ˈ", "ɜ", "ɹ", "l", "d"],
        // Lowercase pronoun must stay the weak `ʌs` shape (issue #710).
        "us": ["ˌ", "ʌ", "s"],
        // Compound-split parts and spelled digit runs.
        "mac": ["m", "æ", "k"],
        "reader": ["ɹ", "ˈ", "i", "d", "ə", "ɹ"],
        "fourteen": ["f", "ɔ", "ɹ", "t", "ˈ", "i", "n"],
        "three": ["θ", "ɹ", "ˈ", "i"],
        // Stems for the Misaki stem_s pass — the cache carries the base
        // word but not its possessive/plural.
        "country": ["k", "ˈ", "ʌ", "n", "t", "ɹ", "i"],
        "cat": ["k", "ˈ", "æ", "t"],
        "box": ["b", "ˈ", "ɑ", "k", "s"],
        // Stems for Misaki's stem_ed/stem_ing passes.
        "walk": ["w", "ˈ", "ɔ", "k"],
        "price": ["p", "ɹ", "ˈ", "I", "s"],
        "gaze": ["ɡ", "ˈ", "A", "z"],
        "need": ["n", "ˈ", "i", "d"],
        "heat": ["h", "ˈ", "i", "t"],
        "make": ["m", "ˈ", "A", "k"],
        "run": ["ɹ", "ˈ", "ʌ", "n"],
        "free": ["f", "ɹ", "ˈ", "i"],
        "short": ["ʃ", "ˈ", "ɔ", "ɹ", "t"],
        "grid": ["ɡ", "ɹ", "ˈ", "ɪ", "d"],
        "bre": ["b", "ɹ", "ˈ", "ɛ"],
        "short-lived": ["ʃ", "ˈ", "ɔ", "ɹ", "t", "l", "ˈ", "I", "v", "d"],
        // Context / stress / contraction fixtures.
        "apple": ["ˈ", "æ", "p", "ᵊ", "l"],
        "this": ["ð", "ɪ", "s"],
        "that": ["ð", "æ", "t"],
        "where": ["w", "ɛ", "ɹ"],
        "bin": ["b", "ɪ", "n"],
        "six": ["s", "ˈ", "ɪ", "k", "s"],
        // Title-abbreviation expansions (Mr. → mister).
        "mister": ["m", "ˈ", "ɪ", "s", "t", "ə", "ɹ"],
    ]

    /// Mirrors the real `us_lexicon_cache.json`: the blended `AI`/`US`
    /// shapes the #710 overrides bypass, the per-letter names the spell-out
    /// reads, and known acronyms that must stay lexicon-backed.
    private let caseSensitive: [String: [String]] = [
        "AI": ["ˈ", "A", "ˌ", "I"],
        "US": ["ˌ", "ʌ", "s"],
        "A": ["ˈ", "A"],
        "I": ["ˈ", "I"],
        "U": ["j", "ˈ", "u"],
        "S": ["ˈ", "ɛ", "s"],
        "F": ["ˈ", "ɛ", "f"],
        "B": ["b", "ˈ", "i"],
        "T": ["t", "ˈ", "i"],
        "P": ["p", "ˈ", "i"],
        "C": ["s", "ˈ", "i"],
        "M": ["ˈ", "ɛ", "m"],
        "NASA": ["n", "ˈ", "æ", "s", "ə"],
        "OK": ["ˌ", "O", "k", "ˈ", "A"],
        "iPhone": ["ˈ", "I", "f", "ˌ", "O", "n"],
    ]

    /// Punctuation present in the real `ANE/vocab.json`.
    private let punctuation: Set<Character> = [",", ".", "!", "?", ";", ":", "…"]

    private func makePhonemizer(
        custom: [String: String] = [:]
    ) -> KokoroAneEnglishPhonemizer {
        KokoroAneEnglishPhonemizer(
            wordToPhonemes: lexicon,
            caseSensitiveWordToPhonemes: caseSensitive,
            customLexicon: custom,
            allowedPunctuation: punctuation
        )
    }

    /// G2P stand-in that returns the stressed citation form for "to" the
    /// way the BART model does, and records which words reached it.
    private actor FallbackRecorder {
        var words: [String] = []
        func g2p(_ word: String) -> [String]? {
            words.append(word)
            if word == "to" { return ["t", "ˈ", "O"] }
            return ["<g2p:\(word)>"]
        }
    }

    // MARK: - Context-sensitive function words (Misaki get_special_case)

    func testTheReducesByFollowingSound() async throws {
        let phonemizer = makePhonemizer()
        let beforeVowel = try await phonemizer.phonemize("the apple") { _ in nil }
        XCTAssertEqual(beforeVowel, "ði ˈæpᵊl")
        let beforeConsonant = try await phonemizer.phonemize("the world") { _ in nil }
        XCTAssertEqual(beforeConsonant, "ðə wˈɜɹld")
    }

    func testToReducesByFollowingSound() async throws {
        let phonemizer = makePhonemizer()
        let beforeVowel = try await phonemizer.phonemize("to apple") { _ in nil }
        XCTAssertEqual(beforeVowel, "tʊ ˈæpᵊl")
        let beforeConsonant = try await phonemizer.phonemize("to go") { _ in nil }
        XCTAssertEqual(beforeConsonant, "tə ɡˈO")
        let phraseFinal = try await phonemizer.phonemize("go to") { _ in nil }
        XCTAssertEqual(phraseFinal, "ɡˈO tu")
    }

    func testArticleAReduces() async throws {
        let result = try await makePhonemizer().phonemize("a world") { _ in nil }
        XCTAssertEqual(result, "ɐ wˈɜɹld")
    }

    func testThatsAlwaysStrong() async throws {
        let result = try await makePhonemizer().phonemize("that's go") { _ in nil }
        XCTAssertEqual(result, "ðˈæts ɡˈO")
    }

    // MARK: - Phrase-final strong forms (Misaki None-keyed gold entries)

    func testWeakWordStrengthensPhraseFinally() async throws {
        let phonemizer = makePhonemizer()
        let midPhrase = try await phonemizer.phonemize("this apple") { _ in nil }
        XCTAssertEqual(midPhrase, "ðɪs ˈæpᵊl")
        let phraseFinal = try await phonemizer.phonemize("this.") { _ in nil }
        XCTAssertEqual(phraseFinal, "ðˈɪs.")
    }

    // MARK: - Capitalization stress (Misaki cap_stresses)

    func testCapitalizedWordGainsSecondaryStress() async throws {
        let phonemizer = makePhonemizer()
        let capitalized = try await phonemizer.phonemize("Bin") { _ in nil }
        XCTAssertEqual(capitalized, "bˌɪn")
        let allCaps = try await phonemizer.phonemize("BIN") { _ in nil }
        XCTAssertEqual(allCaps, "bˈɪn")
        let lowercase = try await phonemizer.phonemize("bin") { _ in nil }
        XCTAssertEqual(lowercase, "bɪn")
    }

    // MARK: - Title abbreviations (spaCy tokenizer exceptions)

    func testSplitWordsMergesTitlePeriodOnlyBeforeCapitalizedWord() {
        XCTAssertEqual(
            KokoroAneEnglishPhonemizer.splitWords("Mr. Bin"),
            ["Mr.", "Bin"])
        // Sentence-final title: the period stays a prosody token.
        XCTAssertEqual(
            KokoroAneEnglishPhonemizer.splitWords("the Dr."),
            ["the", "Dr", "."])
        // Lowercase nouns that spell like titles keep their period.
        XCTAssertEqual(
            KokoroAneEnglishPhonemizer.splitWords("a good rep. Everyone"),
            ["a", "good", "rep", ".", "Everyone"])
    }

    func testTitleBeforeNameReadsSpokenExpansionWithoutPause() async throws {
        let phonemizer = makePhonemizer()
        let mister = try await phonemizer.phonemize("Mr. Bin") { _ in nil }
        XCTAssertEqual(mister, "mˈɪstəɹ bˌɪn")

        // `miz` is missing from the Misaki lexicon; the inline IPA covers it.
        let miz = try await phonemizer.phonemize("Ms. Bin") { _ in nil }
        XCTAssertEqual(miz, "mˈɪz bˌɪn")

        let segments = try await phonemizer.phonemizeSegments("Mr. Bin") { _ in nil }
        XCTAssertEqual(
            segments,
            [
                .init(word: "Mr.", phonemes: "mˈɪstəɹ"),
                .init(word: "Bin", phonemes: "bˌɪn"),
            ])
    }

    // MARK: - Contractions

    func testContractionResolvesStemPlusSuffix() async throws {
        let phonemizer = makePhonemizer()
        let whered = try await phonemizer.phonemize("Where'd") { _ in nil }
        XCTAssertEqual(whered, "wˌɛɹd")
        let thatll = try await phonemizer.phonemize("that'll") { _ in nil }
        XCTAssertEqual(thatll, "ðætəl")
    }

    // MARK: - Residual digit runs

    func testBareDigitTokenReadsAsNumber() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("6") { await recorder.g2p($0) }
        XCTAssertEqual(result, "sˈɪks")
        let recordedEmpty = await recorder.words.isEmpty
        XCTAssertTrue(recordedEmpty, "digits must not reach BART G2P")
    }

    // MARK: - Weak forms (the issue #691 symptom)

    func testFunctionWordToUsesLexiconWeakFormNotG2P() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("I want to go") { await recorder.g2p($0) }

        XCTAssertEqual(result, "ˌI wˈɑnt tə ɡˈO")
        XCTAssertFalse(result.contains("tˈO"), "'to' must not get the stressed citation form")
        let recordedEmpty = await recorder.words.isEmpty
        XCTAssertTrue(recordedEmpty, "all words should resolve from the lexicon")
    }

    func testUppercaseToStillResolvesWeakForm() async throws {
        // "TO" has no case-sensitive entry; it must hit the lower-cased
        // lexicon, not fall through to G2P.
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("TO") { await recorder.g2p($0) }
        XCTAssertEqual(result, "tu")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty)
    }

    // MARK: - Resolution order

    func testCaseSensitiveLexiconWinsForProperNouns() async throws {
        // `NASA` is a lexicon-backed acronym, not spelled out.
        let result = try await makePhonemizer().phonemize("NASA") { _ in nil }
        XCTAssertEqual(result, "nˈæsə")
    }

    // MARK: - Letter-name initialisms (issue #710)

    func testAIOverrideSpellsLetterNamesNotBlendedShape() async throws {
        // `AI` bypasses the blended `ˈAˌI` lexicon entry and reads `A I`.
        let result = try await makePhonemizer().phonemize("AI") { _ in nil }
        XCTAssertEqual(result, "ˌAˈI")
    }

    func testUSOverrideSpellsLetterNamesNotPronoun() async throws {
        // Uppercase `US` reads `U S`, not the lowercase pronoun `ʌs`.
        let result = try await makePhonemizer().phonemize("US") { _ in nil }
        XCTAssertEqual(result, "jˌuˈɛs")
    }

    func testLowercaseUsStaysPronoun() async throws {
        // The override only matches the exact uppercase spelling.
        let result = try await makePhonemizer().phonemize("us") { _ in nil }
        XCTAssertEqual(result, "ˌʌs")
    }

    func testUnknownAllCapsInitialismSpelledAsLetterNames() async throws {
        // `FBI`/`ATP` miss the lexicon and spell out instead of reaching G2P.
        let recorder = FallbackRecorder()
        let fbi = try await makePhonemizer().phonemize("FBI") { await recorder.g2p($0) }
        XCTAssertEqual(fbi, "ˌɛfbˌiˈI")
        let atp = try await makePhonemizer().phonemize("ATP") { await recorder.g2p($0) }
        XCTAssertEqual(atp, "ˌAtˌipˈi")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty, "initialisms must not reach BART G2P")
    }

    func testKnownAcronymStaysLexiconBackedNotSpelled() async throws {
        // `OK` is a lexicon hit (2-5 all-caps) — it keeps its bundled shape
        // rather than spelling `O K`.
        let result = try await makePhonemizer().phonemize("OK") { _ in nil }
        XCTAssertEqual(result, "ˌOkˈA")
    }

    func testInitialismSpellOutFallsThroughToG2PWithoutLetterEntries() async throws {
        // G2P-only degraded path: no per-letter lexicon entries, so the
        // all-caps token must reach the fallback rather than emit a partial.
        let phonemizer = KokoroAneEnglishPhonemizer(allowedPunctuation: punctuation)
        let recorder = FallbackRecorder()
        let result = try await phonemizer.phonemize("FBI") { await recorder.g2p($0) }
        XCTAssertEqual(result, "<g2p:FBI>")
        let recorded = await recorder.words
        XCTAssertEqual(recorded, ["FBI"])
    }

    func testOverrideFallsBackToLexiconWhenLettersMissing() async throws {
        // Degraded lexicon: `US` is present but the per-letter entries are
        // not, so the override can't spell it and falls through to the
        // bundled shape (logged, never silently dropped or sent to G2P).
        let phonemizer = KokoroAneEnglishPhonemizer(
            caseSensitiveWordToPhonemes: ["US": ["ˌ", "ʌ", "s"]],
            allowedPunctuation: punctuation
        )
        let recorder = FallbackRecorder()
        let result = try await phonemizer.phonemize("US") { await recorder.g2p($0) }
        XCTAssertEqual(result, "ˈʌs")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty, "override fall-through must use the lexicon, not G2P")
    }

    func testLongAllCapsWordIsNotSpelledButReachesG2P() async throws {
        // Outside the 2-5 length range → not an initialism; reaches G2P
        // instead of being spelled letter by letter. (Candidate boundaries
        // are unit-tested in EnglishInitialismsTests.)
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("ABCDEF") { await recorder.g2p($0) }
        XCTAssertEqual(result, "<g2p:ABCDEF>")
        let recorded = await recorder.words
        XCTAssertEqual(recorded, ["ABCDEF"])
    }

    // MARK: - Possessives and regular plurals (Misaki stem_s)

    func testPossessiveResolvesStemPlusVoicedSibilant() async throws {
        // `country's` misses the cache; the stem resolves and takes `z`
        // after the voiced final vowel.
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("country's") { await recorder.g2p($0) }
        XCTAssertEqual(result, "kˈʌntɹiz")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty, "stemmed possessives must not reach BART G2P")
    }

    func testIesPluralResolvesYStem() async throws {
        let result = try await makePhonemizer().phonemize("countries") { _ in nil }
        XCTAssertEqual(result, "kˈʌntɹiz")
    }

    func testPossessiveAfterVoicelessStopTakesS() async throws {
        let result = try await makePhonemizer().phonemize("cat's") { _ in nil }
        XCTAssertEqual(result, "kˈæts")
    }

    func testEsPluralAfterSibilantTakesReducedVowel() async throws {
        let result = try await makePhonemizer().phonemize("boxes") { _ in nil }
        XCTAssertEqual(result, "bˈɑksᵻz")
    }

    func testInitialismPossessive() async throws {
        // `AI's` stems to the letter-name override and takes `z`.
        let result = try await makePhonemizer().phonemize("AI's") { _ in nil }
        XCTAssertEqual(result, "ˌAˈIz")
    }

    func testDoubleSEndingIsNotStemmed() async throws {
        // `-ss` words are never plural-stripped; the whole token goes to G2P.
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("guess") { await recorder.g2p($0) }
        XCTAssertEqual(result, "<g2p:guess>")
        let recorded = await recorder.words
        XCTAssertEqual(recorded, ["guess"])
    }

    func testSEndingWithUnknownStemKeepsWholeTokenG2P() async throws {
        // `Jonas` isn't a plural of anything known — no fabricated stem.
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("Jonas") { await recorder.g2p($0) }
        XCTAssertEqual(result, "<g2p:Jonas>")
        let recorded = await recorder.words
        XCTAssertEqual(recorded, ["Jonas"])
    }

    // MARK: - Past tense and progressive inflections (Misaki stem_ed/stem_ing)

    func testPastTenseUsesHeteronymStemPOSTag() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("They lived") { await recorder.g2p($0) }
        XCTAssertTrue(result.contains("lˈɪvd"), "verb 'lived' must use the short vowel, got: \(result)")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty)
    }

    func testHyphenatedGoldEntryUsesRawLowercaseProbe() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("short-lived") { await recorder.g2p($0) }
        XCTAssertEqual(result, "ʃˈɔɹtlˈIvd")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty)
    }

    func testPastTenseVoicingAndTapRules() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("walked priced gazed wanted needed heated freed") {
            await recorder.g2p($0)
        }
        XCTAssertEqual(result, "wˈɔkt pɹˈIst ɡˈAzd wˈɑntᵻd nˈidᵻd hˈiTᵻd fɹˈid")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty)
    }

    func testPastTenseGuardsKeepWholeTokenFallback() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("gridd breed") { await recorder.g2p($0) }
        XCTAssertEqual(result, "<g2p:gridd> <g2p:breed>")
        let recorded = await recorder.words
        XCTAssertEqual(recorded, ["breed", "gridd"])
    }

    func testProgressiveStemCandidatesAndTapRule() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("walking making running heating") { await recorder.g2p($0) }
        XCTAssertEqual(result, "wˈɔkɪŋ mˈAkɪŋ ɹˈʌnɪŋ hˈiTɪŋ")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty)
    }

    func testShortIngWordKeepsWholeTokenFallback() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("king") { await recorder.g2p($0) }
        XCTAssertEqual(result, "<g2p:king>")
        let recorded = await recorder.words
        XCTAssertEqual(recorded, ["king"])
    }

    func testCompoundPossessive() async throws {
        // Trailing `'s` on a resolvable compound reads the compound + `z`.
        let result = try await makePhonemizer().phonemize("MacReader's") { _ in nil }
        XCTAssertEqual(result, "mˌækɹˈidəɹz")
    }

    // MARK: - Compound tokens (camelCase / letter+digit)

    func testCamelCaseCompoundReadsAsItsParts() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("MacReader") { await recorder.g2p($0) }
        XCTAssertEqual(result, "mˌækɹˈidəɹ")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty, "resolved compounds must not reach BART G2P")
    }

    func testLetterDigitCompoundSpellsAcronymAndNumber() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("CASP14") { await recorder.g2p($0) }
        XCTAssertEqual(result, "sˌiˌAˌɛspˈi fɔɹtˈin")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty)
    }

    func testShortLetterDigitCompound() async throws {
        let result = try await makePhonemizer().phonemize("MP3") { _ in nil }
        XCTAssertEqual(result, "ˌɛmpˈi θɹˈi")
    }

    func testCaseSensitiveLexiconEntryBeatsCompoundSplit() async throws {
        // `iPhone` has an exact-spelling entry; it must not split to `i Phone`.
        let result = try await makePhonemizer().phonemize("iPhone") { _ in nil }
        XCTAssertEqual(result, "ˈIfˌOn")
    }

    func testCompoundWithUnresolvablePartKeepsWholeTokenG2P() async throws {
        // `Gregor` misses the lexicon → the whole token goes to BART as
        // before, not a mix of split parts and per-part G2P.
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("McGregor") { await recorder.g2p($0) }
        XCTAssertEqual(result, "<g2p:McGregor>")
        let recorded = await recorder.words
        XCTAssertEqual(recorded, ["McGregor"])
    }

    func testApostropheWordSkipsCompoundSplit() async throws {
        // A possessive must not read its trailing `s` as a letter name.
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("Zorblax's") { await recorder.g2p($0) }
        XCTAssertEqual(result, "<g2p:Zorblax's>")
        let recorded = await recorder.words
        XCTAssertEqual(recorded, ["Zorblax's"])
    }

    func testCompoundSegmentKeepsTheOriginalWord() async throws {
        // Word timing pairs segment words against reader words — the
        // compound stays one segment carrying the original spelling.
        let segments = try await makePhonemizer().phonemizeSegments("CASP14") { _ in nil }
        XCTAssertEqual(segments.map(\.word), ["CASP14"])
    }

    func testOOVWordFallsBackToG2PWithNormalizedSpelling() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("I want Zorblax") { await recorder.g2p($0) }
        XCTAssertEqual(result, "ˌI wˈɑnt <g2p:Zorblax>")
        let recordedWords = await recorder.words
        XCTAssertEqual(recordedWords, ["Zorblax"])
    }

    func testCustomLexiconOverridesEverything() async throws {
        let phonemizer = makePhonemizer(custom: ["to": "tə"])
        let result = try await phonemizer.phonemize("I want to go") { _ in nil }
        XCTAssertEqual(result, "ˌI wˈɑnt tə ɡˈO")
    }

    func testCustomLexiconExactSpellingBeatsLowercased() async throws {
        let phonemizer = makePhonemizer(custom: ["to": "tə", "TO": "tˈu"])
        let emphatic = try await phonemizer.phonemize("TO") { _ in nil }
        XCTAssertEqual(emphatic, "tˈu")
        let weak = try await phonemizer.phonemize("to") { _ in nil }
        XCTAssertEqual(weak, "tə")
    }

    // MARK: - Punctuation and quote delimiters

    func testSupportedPunctuationAttachesToPrecedingWord() async throws {
        let result = try await makePhonemizer().phonemize("Hello, world!") { _ in nil }
        XCTAssertEqual(result, "həlˈO, wˈɜɹld!")
    }

    func testUnsupportedPunctuationIsDropped() async throws {
        // '#' is not in the chain vocab → dropped, no stray space.
        let result = try await makePhonemizer().phonemize("hello # world") { _ in nil }
        XCTAssertEqual(result, "həlˈO wˈɜɹld")
    }

    func testApostropheWordsStayIntactForLexiconLookup() async throws {
        let phonemizer = KokoroAneEnglishPhonemizer(
            wordToPhonemes: ["don't": ["d", "ˈ", "O", "n", "t"]],
            allowedPunctuation: punctuation
        )
        let result = try await phonemizer.phonemize("don't") { _ in nil }
        XCTAssertEqual(result, "dˈOnt")
    }

    func testTypographicApostropheWordsUseAsciiLexiconEntry() async throws {
        let phonemizer = KokoroAneEnglishPhonemizer(
            wordToPhonemes: ["don't": ["d", "ˈ", "O", "n", "t"]],
            allowedPunctuation: punctuation
        )
        let result = try await phonemizer.phonemize("don’t") { _ in nil }
        XCTAssertEqual(result, "dˈOnt")
    }

    func testTypographicPossessiveStaysOneWord() async throws {
        let phonemizer = KokoroAneEnglishPhonemizer(
            wordToPhonemes: ["reader's": ["ɹ", "ˈ", "i", "d", "ɚ", "z"]],
            allowedPunctuation: punctuation
        )
        let segments = try await phonemizer.phonemizeSegments("reader’s voice") { word in
            word == "voice" ? ["v", "ˈ", "ɔ", "ɪ", "s"] : nil
        }
        XCTAssertEqual(segments.map(\.word), ["reader's", "voice"])
        XCTAssertEqual(segments.map(\.phonemes), ["ɹˈidɚz", "vˈɔɪs"])
    }

    func testSingleQuotesAreDelimitersNotPartOfLexiconKey() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("'to'") { await recorder.g2p($0) }
        XCTAssertEqual(result, "tu")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty)
    }

    func testQuotedSentenceKeepsContractionsIntact() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("'there's to'") {
            await recorder.g2p($0)
        }
        XCTAssertEqual(result, "ðɛɹz tu")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty)
    }

    func testKnownLeadingApostropheWordsStayIntactForLexiconLookup() async throws {
        let recorder = FallbackRecorder()
        let result = try await makePhonemizer().phonemize("'twas 'em 'til 'to'") {
            await recorder.g2p($0)
        }

        XCTAssertEqual(result, "twˈɑz əm tˈIl tu")
        let recorded = await recorder.words
        XCTAssertTrue(recorded.isEmpty)
    }

    // MARK: - Degraded paths

    func testG2PNilSkipsWordButKeepsRest() async throws {
        let result = try await makePhonemizer().phonemize("want zzz go") { word in
            word == "zzz" ? nil : ["x"]
        }
        XCTAssertEqual(result, "wˈɑnt ɡˈO")
    }

    func testG2PErrorPropagates() async {
        struct Boom: Error {}
        do {
            _ = try await makePhonemizer().phonemize("Zorblax") { _ in throw Boom() }
            XCTFail("expected error to propagate")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testEmptyInputThrows() async {
        do {
            _ = try await makePhonemizer().phonemize("   ") { _ in nil }
            XCTFail("expected inputProcessingFailed")
        } catch let error as KokoroAneError {
            guard case .inputProcessingFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNothingResolvedThrows() async {
        do {
            _ = try await makePhonemizer().phonemize("zzz") { _ in nil }
            XCTFail("expected inputProcessingFailed")
        } catch let error as KokoroAneError {
            guard case .inputProcessingFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Without lexicon (pre-#691 behavior preserved)

    func testEmptyLexiconFallsBackToG2PForEveryWord() async throws {
        let phonemizer = KokoroAneEnglishPhonemizer(allowedPunctuation: punctuation)
        let recorder = FallbackRecorder()
        let result = try await phonemizer.phonemize("I want to go") { await recorder.g2p($0) }
        let recordedAll = await recorder.words
        // `I` and `to` resolve via the Misaki special cases without any
        // lexicon; resolution runs right-to-left, so `go` records first.
        XCTAssertEqual(recordedAll, ["go", "want"])
        XCTAssertTrue(result.hasPrefix("ˌI"), "the pronoun special case needs no lexicon")
    }

    // MARK: - POS-aware heteronyms

    /// The bundled lexicon cache flattens every heteronym to its DEFAULT
    /// reading; the restored gold-dict entries must pick the verb form when
    /// the word is used as a verb, and DEFAULT otherwise.
    func testHeteronymLiveResolvesByPartOfSpeech() async throws {
        let phonemizer = makePhonemizer()
        let verb = try await phonemizer.phonemize("I want to live") { _ in ["x"] }
        XCTAssertTrue(verb.contains("lˈɪv"), "verb 'live' must use the short vowel, got: \(verb)")

        let adjective = try await phonemizer.phonemize("a live concert") { _ in ["x"] }
        XCTAssertTrue(adjective.contains("lˈIv"), "adjective 'live' must use the diphthong, got: \(adjective)")
    }

    /// Heteronyms beat the flattened lexicon entry (which carries only the
    /// DEFAULT reading) but stay behind a caller's custom-lexicon override.
    func testCustomLexiconStillOverridesHeteronym() async throws {
        let phonemizer = makePhonemizer(custom: ["live": "custom"])
        let result = try await phonemizer.phonemize("I want to live") { _ in ["x"] }
        XCTAssertTrue(result.contains("custom"))
        XCTAssertFalse(result.contains("lˈɪv"))
    }

    /// A flattened-lexicon entry for a heteronym must lose to the POS pick:
    /// this is the exact shape of the shipped `us_lexicon_cache.json`, which
    /// carries `live` → the DEFAULT diphthong only.
    func testHeteronymBeatsFlattenedLexiconEntry() async throws {
        let phonemizer = KokoroAneEnglishPhonemizer(
            wordToPhonemes: ["live": ["l", "ˈ", "I", "v"], "i": ["ˈ", "I"], "here": ["h", "ˈ", "ɪ", "ɹ"]],
            allowedPunctuation: punctuation
        )
        let result = try await phonemizer.phonemize("I live here") { _ in ["x"] }
        XCTAssertTrue(result.contains("lˈɪv"), "POS pick must beat the flattened DEFAULT, got: \(result)")
    }

    /// Token ranges from the splitter reconstruct the source substrings —
    /// the invariant the POS tagger relies on.
    func testSplitWordTokensRangesMatchSource() {
        let text = "Don't stop, it's twenty-one!"
        for token in KokoroAneEnglishPhonemizer.splitWordTokens(text) {
            let source = String(text[token.range])
            XCTAssertEqual(
                KokoroAneEnglishPhonemizer.normalizeKey(source),
                KokoroAneEnglishPhonemizer.normalizeKey(token.token)
            )
        }
    }
}
