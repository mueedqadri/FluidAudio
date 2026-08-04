import XCTest

@testable import FluidAudio

final class Supertonic3UnicodeProcessorTests: XCTestCase {

    // MARK: - preprocess()

    func testWrapsTextWithLangTags() {
        let out = Supertonic3UnicodeProcessor.preprocess(text: "hello", lang: "en")
        XCTAssertEqual(out, "<en>hello.</en>")
    }

    func testAppendsPeriodWhenMissingTerminalPunctuation() {
        let out = Supertonic3UnicodeProcessor.preprocess(text: "hello world", lang: "en")
        XCTAssertTrue(out.hasSuffix(".</en>"))
    }

    func testDoesNotAppendPeriodWhenAlreadyTerminated() {
        XCTAssertEqual(
            Supertonic3UnicodeProcessor.preprocess(text: "hello!", lang: "en"),
            "<en>hello!</en>")
        XCTAssertEqual(
            Supertonic3UnicodeProcessor.preprocess(text: "hello?", lang: "en"),
            "<en>hello?</en>")
        XCTAssertEqual(
            Supertonic3UnicodeProcessor.preprocess(text: "hello.", lang: "en"),
            "<en>hello.</en>")
    }

    func testStripsEmojiCodepoints() {
        // U+1F600 GRINNING FACE — should be removed.
        let out = Supertonic3UnicodeProcessor.preprocess(text: "hi \u{1F600} there", lang: "en")
        XCTAssertFalse(out.unicodeScalars.contains { $0.value == 0x1F600 })
        XCTAssertTrue(out.contains("hi"))
        XCTAssertTrue(out.contains("there"))
    }

    func testReplacesSmartQuotesAndDashes() {
        let out = Supertonic3UnicodeProcessor.preprocess(
            text: "she said \u{201C}hi\u{201D} \u{2014} then left", lang: "en")
        XCTAssertFalse(out.contains("\u{201C}"))
        XCTAssertFalse(out.contains("\u{201D}"))
        XCTAssertFalse(out.contains("\u{2014}"))
        XCTAssertTrue(out.contains("\""))
        XCTAssertTrue(out.contains("-"))
    }

    /// An unspaced em dash is the common case in prose, and it is the one that
    /// breaks: without the spaces the model reads the two words as a single
    /// hyphenated compound and puts no pause between them at all.
    func testUnspacedDashBecomesASpacedHyphen() {
        let out = Supertonic3UnicodeProcessor.preprocess(
            text: "unsought\u{2014}frequently", lang: "en")
        XCTAssertEqual(out, "<en>unsought - frequently.</en>")
    }

    /// An already-spaced dash must not gain extra spaces; the whitespace
    /// collapse downstream is what keeps the two cases identical.
    func testSpacedDashCollapsesToOneSpaceEachSide() {
        let out = Supertonic3UnicodeProcessor.preprocess(
            text: "unsought \u{2014} frequently", lang: "en")
        XCTAssertEqual(out, "<en>unsought - frequently.</en>")
    }

    func testHorizontalBarIsADashNotAHyphen() {
        let out = Supertonic3UnicodeProcessor.preprocess(
            text: "unsought\u{2015}frequently", lang: "en")
        XCTAssertEqual(out, "<en>unsought - frequently.</en>")
    }

    /// A hyphen joins a compound rather than separating clauses, so it stays
    /// tight. NFKD folds U+2011 into U+2010 before the table runs, which is why
    /// the table is keyed on the latter.
    func testNonBreakingHyphenStaysUnspaced() {
        for hyphen in ["\u{2010}", "\u{2011}"] {
            let out = Supertonic3UnicodeProcessor.preprocess(
                text: "well\(hyphen)known", lang: "en")
            XCTAssertEqual(out, "<en>well-known.</en>")
        }
    }

    /// Invisible format characters ride along in real EPUB and PDF text. The
    /// indexer has no entry for most of them, so each one lands mid-word as an
    /// unknown token and still costs a slot in the 128-token window.
    func testStripsInvisibleFormatCharacters() {
        let out = Supertonic3UnicodeProcessor.preprocess(
            text: "un\u{00AD}sought\u{FEFF}\u{200B}ly\u{200D}", lang: "en")
        XCTAssertEqual(out, "<en>unsoughtly.</en>")
    }

    func testExpandsAtSymbolAndCommonAbbreviations() {
        let out = Supertonic3UnicodeProcessor.preprocess(
            text: "ping me @ ten, e.g., now", lang: "en")
        XCTAssertTrue(out.contains(" at "))
        XCTAssertTrue(out.contains("for example,"))
    }

    func testDropsDecorativeSymbols() {
        let out = Supertonic3UnicodeProcessor.preprocess(
            text: "love \u{2665} you \u{2606}", lang: "en")
        XCTAssertFalse(out.contains("\u{2665}"))
        XCTAssertFalse(out.contains("\u{2606}"))
    }

    func testCollapsesRepeatedQuotesAndWhitespace() {
        let out = Supertonic3UnicodeProcessor.preprocess(
            text: "hello   ''world''", lang: "en")
        XCTAssertFalse(out.contains("  "))  // no double space
        XCTAssertFalse(out.contains("''"))  // no doubled apostrophes
    }

    // MARK: - mask()

    func testMaskShapeAndOnesPerRowMatchLengths() {
        let m = Supertonic3UnicodeProcessor.mask(from: [3, 5, 0], maxLen: 6)
        XCTAssertEqual(m.count, 3)
        XCTAssertTrue(m.allSatisfy { $0.count == 1 && $0[0].count == 6 })
        XCTAssertEqual(m[0][0], [1, 1, 1, 0, 0, 0])
        XCTAssertEqual(m[1][0], [1, 1, 1, 1, 1, 0])
        XCTAssertEqual(m[2][0], [0, 0, 0, 0, 0, 0])
    }

    func testMaskClampsLengthAtMaxLen() {
        let m = Supertonic3UnicodeProcessor.mask(from: [20], maxLen: 4)
        XCTAssertEqual(m[0][0], [1, 1, 1, 1])
    }
}
