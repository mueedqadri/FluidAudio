import XCTest

@testable import FluidAudio

final class Supertonic3TextChunkerTests: XCTestCase {

    private let window = Supertonic3Constants.textTFixed

    /// The invariant the whole chunker exists to hold: nothing it emits may
    /// exceed the token window, in any script. Past it, `encode` truncates and
    /// the tail is lost without any error surfacing.
    private func assertFits(
        _ chunks: [String], lang: String, _ maxTokens: Int? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let cap = maxTokens ?? window
        for chunk in chunks {
            let n = Supertonic3TextChunker.encodedLength(of: chunk, lang: lang)
            XCTAssertLessThanOrEqual(
                n, cap, "chunk encodes to \(n) tokens: '\(chunk)'", file: file, line: line)
        }
    }

    /// Chunk with one cap governing both packing and atomicity — the behavior
    /// before the wide tier existed, and still exactly what happens when its
    /// assets are absent. The tests below that pin a small window are testing
    /// the clause/word fallback ladder, which now activates at the atomicity
    /// ceiling rather than at the packing cap, so they have to say so.
    private func chunkSingleCap(_ text: String, lang: String, cap: Int) -> [String] {
        Supertonic3TextChunker.chunk(
            text: text, lang: lang, maxTokens: cap, wholeSentenceTokens: cap)
    }

    // MARK: - Trivial inputs

    func testEmptyInputReturnsNoChunks() {
        XCTAssertEqual(Supertonic3TextChunker.chunk(text: "", lang: "en"), [])
        XCTAssertEqual(Supertonic3TextChunker.chunk(text: "   \n   ", lang: "en"), [])
    }

    func testShortInputReturnsSingleChunkUnchanged() {
        XCTAssertEqual(
            Supertonic3TextChunker.chunk(text: "Hello there.", lang: "en"),
            ["Hello there."])
    }

    // MARK: - Sentence packing

    func testSentencesAreCombinedUpToTheWindow() {
        let chunks = Supertonic3TextChunker.chunk(text: "One. Two. Three. Four.", lang: "en")
        XCTAssertEqual(chunks, ["One. Two. Three. Four."])
    }

    func testLongSentencesSplitAtSentenceBoundaries() {
        let a = String(repeating: "a", count: 60) + "."
        let b = String(repeating: "b", count: 60) + "."
        let chunks = Supertonic3TextChunker.chunk(
            text: "\(a) \(b)", lang: "en", maxTokens: 80)
        XCTAssertEqual(chunks, [a, b])
        assertFits(chunks, lang: "en", 80)
    }

    // MARK: - Abbreviation awareness

    func testAbbreviationDoesNotSplitMidSentence() {
        let chunks = Supertonic3TextChunker.chunk(
            text: "Dr. Smith arrived early. Then he left.", lang: "en")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("Dr. Smith"))
        XCTAssertTrue(chunks[0].contains("Then he left."))
    }

    // MARK: - Fallbacks

    func testLongSentenceFallsBackToCommaBoundaries() {
        let sentence =
            (0..<6).map { _ in String(repeating: "x", count: 18) }
            .joined(separator: ", ") + "."
        let chunks = chunkSingleCap(sentence, lang: "en", cap: 50)
        XCTAssertGreaterThan(chunks.count, 1)
        assertFits(chunks, lang: "en", 50)
    }

    func testVeryLongCommaFreeRunFallsBackToWordBoundaries() {
        let sentence = Array(repeating: "word", count: 40).joined(separator: " ") + "."
        let chunks = chunkSingleCap(sentence, lang: "en", cap: 30)
        XCTAssertGreaterThan(chunks.count, 1)
        assertFits(chunks, lang: "en", 30)
    }

    // MARK: - Paragraph split (blank-line boundary)

    func testParagraphsAreSplitOnBlankLines() {
        let chunks = Supertonic3TextChunker.chunk(
            text: "First paragraph.\n\nSecond paragraph.", lang: "en")
        XCTAssertEqual(chunks, ["First paragraph.", "Second paragraph."])
    }

    // MARK: - The window is measured in encoded tokens, not Characters

    /// Devanagari averages ~1.4 scalars per grapheme cluster. A cap compared
    /// against `String.count` lets these chunks past the window, and the
    /// encoder then drops their tails silently.
    func testDevanagariChunksStayInsideTheWindow() {
        let hindi = String(
            repeating: "\u{0938}\u{0941}\u{092C}\u{0939} \u{0915}\u{0940} "
                + "\u{0939}\u{0935}\u{093E} \u{092E}\u{0947}\u{0902} "
                + "\u{0939}\u{0932}\u{094D}\u{0915}\u{0940} "
                + "\u{0920}\u{0902}\u{0921}\u{0915} \u{0925}\u{0940}\u{0964} ",
            count: 6)
        let chunks = Supertonic3TextChunker.chunk(text: hindi, lang: "hi")
        XCTAssertGreaterThan(chunks.count, 1)
        assertFits(chunks, lang: "hi")
    }

    /// NFKD decomposes each Hangul syllable into three jamo, so Korean costs
    /// far more tokens per Character than its source text suggests.
    func testKoreanChunksStayInsideTheWindow() {
        let korean = String(
            repeating: "\u{C544}\u{CE68} \u{ACF5}\u{AE30}\u{B294} "
                + "\u{C11C}\u{B298}\u{D588}\u{ACE0} \u{BE5B}\u{C774} "
                + "\u{B4E4}\u{C5B4}\u{C654}\u{B2E4}. ",
            count: 8)
        let chunks = Supertonic3TextChunker.chunk(text: korean, lang: "ko")
        XCTAssertGreaterThan(chunks.count, 1)
        assertFits(chunks, lang: "ko")
    }

    func testEncodedLengthExceedsCharacterCountForDevanagari() {
        let word = "\u{0939}\u{0932}\u{094D}\u{0915}\u{0940}"  // हल्की
        XCTAssertGreaterThan(
            Supertonic3TextChunker.encodedLength(of: word, lang: "hi"), word.count)
    }

    // MARK: - Sentence terminators outside Latin

    /// With only `.!?` recognised, Hindi has no sentence boundaries at all and
    /// every seam lands wherever the budget ran out.
    func testDandaEndsAHindiSentence() {
        let one = "\u{0935}\u{0939} \u{0906}\u{092F}\u{093E}\u{0964}"  // वह आया।
        let two = "\u{092F}\u{0939} \u{0917}\u{092F}\u{093E}\u{0964}"  // यह गया।
        let chunks = Supertonic3TextChunker.chunk(
            text: "\(one) \(two)", lang: "hi",
            maxTokens: Supertonic3TextChunker.encodedLength(of: one, lang: "hi"))
        XCTAssertEqual(chunks, [one, two])
    }

    /// Japanese does not put a space after `。`, so a splitter that requires
    /// trailing whitespace finds nothing.
    func testCJKFullStopEndsASentenceWithoutTrailingSpace() {
        let one = "\u{6771}\u{4EAC}\u{3078}\u{884C}\u{304F}\u{3002}"  // 東京へ行く。
        let two = "\u{96E8}\u{304C}\u{964D}\u{308B}\u{3002}"  // 雨が降る。
        let chunks = Supertonic3TextChunker.chunk(
            text: one + two, lang: "ja",
            maxTokens: Supertonic3TextChunker.encodedLength(of: one, lang: "ja"))
        XCTAssertEqual(chunks, [one, two])
    }

    func testArabicQuestionMarkEndsASentence() {
        let one = "\u{0643}\u{064A}\u{0641} \u{062D}\u{0627}\u{0644}\u{0643}\u{061F}"  // كيف حالك؟
        let two = "\u{0623}\u{0646}\u{0627} \u{0628}\u{062E}\u{064A}\u{0631}."  // أنا بخير.
        let chunks = Supertonic3TextChunker.chunk(
            text: "\(one) \(two)", lang: "ar",
            maxTokens: Supertonic3TextChunker.encodedLength(of: one, lang: "ar"))
        XCTAssertEqual(chunks, [one, two])
    }

    // MARK: - Clause boundaries

    func testSemicolonIsABreakCandidate() {
        let text = "The first clause runs on a while; the second one does too."
        let chunks = chunkSingleCap(text, lang: "en", cap: 50)
        XCTAssertEqual(chunks, ["The first clause runs on a while;", "the second one does too."])
        assertFits(chunks, lang: "en", 50)
    }

    func testColonIsABreakCandidate() {
        let text = "Here is the point: everything after it is the explanation."
        let chunks = chunkSingleCap(text, lang: "en", cap: 50)
        XCTAssertEqual(chunks, ["Here is the point:", "everything after it is the explanation."])
    }

    // MARK: - Two caps: packing at 128, atomicity at the tier ceiling

    /// The sentence from the original report. At 215 encoded tokens it used to
    /// come out as three chunks — two invented sentence endings inside one
    /// sentence — and is now emitted whole.
    func testTheGatsbySentenceIsOneChunk() {
        let sentence =
            "Most of the confidences were unsought - frequently I have feigned sleep, "
            + "preoccupation, or a hostile levity when I realized by some unmistakable "
            + "sign that an intimate revelation was quivering on the horizon."
        let tokens = Supertonic3TextChunker.encodedLength(of: sentence, lang: "en")
        XCTAssertGreaterThan(tokens, Supertonic3Constants.textTFixed, "\(tokens) tokens")
        XCTAssertLessThanOrEqual(tokens, Supertonic3Constants.tierCeiling, "\(tokens) tokens")

        XCTAssertEqual(Supertonic3TextChunker.chunk(text: sentence, lang: "en"), [sentence])
        // Without the wide assets the same sentence still splits, as before.
        XCTAssertGreaterThan(chunkSingleCap(sentence, lang: "en", cap: window).count, 1)
    }

    func testSentenceOverThePackingCapIsEmittedWholeAndAlone() {
        let long = Array(repeating: "word", count: 40).joined(separator: " ") + "."
        let short = "A short one."
        XCTAssertGreaterThan(
            Supertonic3TextChunker.encodedLength(of: long, lang: "en"), window)

        let chunks = Supertonic3TextChunker.chunk(text: "\(short) \(long) \(short)", lang: "en")
        // The long sentence is its own chunk; the short ones are not dragged
        // into it, since a seam between whole sentences costs no prosody.
        XCTAssertEqual(chunks, [short, long, short])
    }

    func testShortSentencesStillPackAtThePackingCapNotTheCeiling() {
        // Six ~30-token sentences: packing must still stop at 128, not run on
        // to the 320 ceiling.
        let sentence = "The quick brown fox jumped over the lazy dog again."
        let chunks = Supertonic3TextChunker.chunk(
            text: Array(repeating: sentence, count: 6).joined(separator: " "), lang: "en")
        XCTAssertGreaterThan(chunks.count, 1)
        assertFits(chunks, lang: "en")
    }

    func testSentencePastTheCeilingClauseSplitsIntoPiecesThatFit() {
        let sentence =
            (0..<12).map { _ in String(repeating: "x", count: 30) }
            .joined(separator: ", ") + "."
        XCTAssertGreaterThan(
            Supertonic3TextChunker.encodedLength(of: sentence, lang: "en"),
            Supertonic3Constants.tierCeiling)

        let chunks = Supertonic3TextChunker.chunk(text: sentence, lang: "en")
        XCTAssertGreaterThan(chunks.count, 1)
        assertFits(chunks, lang: "en", Supertonic3Constants.tierCeiling)
    }

    /// Routing is by *encoded* length, so the tier a sentence lands on depends
    /// on its script, not its character count.
    func testKoreanRoutesByEncodedLengthNotCharacterCount() {
        // NFKD triples each Hangul syllable, so this is tier 2 on 60-odd
        // Characters where the same count of Latin ones would be tier 1.
        let korean =
            String(
                repeating: "\u{C544}\u{CE68} \u{ACF5}\u{AE30}\u{B294} "
                    + "\u{C11C}\u{B298}\u{D588}\u{ACE0} \u{BE5B}\u{C774} "
                    + "\u{B4E4}\u{C5B4}\u{C654}\u{B2E4}",
                count: 3) + "."
        let tokens = Supertonic3TextChunker.encodedLength(of: korean, lang: "ko")
        XCTAssertGreaterThan(tokens, window)
        XCTAssertLessThan(korean.count, window, "fewer Characters than the window")

        XCTAssertEqual(Supertonic3TextChunker.chunk(text: korean, lang: "ko"), [korean])
    }

    func testDevanagariSentenceOverTheWindowIsEmittedWhole() {
        let hindi =
            String(
                repeating: "\u{0938}\u{0941}\u{092C}\u{0939} \u{0915}\u{0940} "
                    + "\u{0939}\u{0935}\u{093E} \u{092E}\u{0947}\u{0902} "
                    + "\u{0939}\u{0932}\u{094D}\u{0915}\u{0940} "
                    + "\u{0920}\u{0902}\u{0921}\u{0915} \u{0925}\u{0940} ",
                count: 5
            ).trimmingCharacters(in: .whitespaces) + "\u{0964}"
        let tokens = Supertonic3TextChunker.encodedLength(of: hindi, lang: "hi")
        XCTAssertGreaterThan(tokens, window)
        XCTAssertLessThanOrEqual(tokens, Supertonic3Constants.tierCeiling)

        XCTAssertEqual(Supertonic3TextChunker.chunk(text: hindi, lang: "hi"), [hindi])
    }

    /// Text that already fits one tier-1 chunk must be untouched by any of
    /// this — same chunk, whether or not the wide tier is in play.
    func testShortTextIsUnaffectedByTheCeiling() {
        for text in ["Hello there.", "One. Two. Three. Four.", "Dr. Smith arrived early."] {
            XCTAssertEqual(
                Supertonic3TextChunker.chunk(text: text, lang: "en"),
                chunkSingleCap(text, lang: "en", cap: window),
                "'\(text)' should chunk identically with and without the tier")
        }
    }

    /// A ceiling below the packing cap is incoherent; it degrades to single-cap
    /// behavior rather than splitting every sentence to nothing.
    func testCeilingBelowPackingCapIsClamped() {
        let text = "One part here, a second part there, and a third part at the end."
        XCTAssertEqual(
            Supertonic3TextChunker.chunk(
                text: text, lang: "en", maxTokens: 40, wholeSentenceTokens: 0),
            chunkSingleCap(text, lang: "en", cap: 40))
    }

    /// The separator belongs to the clause it ends. Dropping it would leave the
    /// fragment unterminated, and `preprocess` would fabricate a full stop —
    /// turning a comma into a sentence ending mid-sentence.
    func testClauseSeparatorsSurviveTheSplit() {
        let text = "One part here, a second part there, and a third part at the end."
        let chunks = chunkSingleCap(text, lang: "en", cap: 40)
        XCTAssertEqual(chunks, ["One part here,", "a second part there,", "and a third part at the end."])
    }
}
