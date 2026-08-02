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

    // MARK: - Terminal vs continuation closing

    func testNonTerminalFragmentGetsContinuationMarkNotPeriod() {
        let out = Supertonic3UnicodeProcessor.preprocess(
            text: "the scheduler falls back to the CPU whenever an operator is",
            lang: "en", isTerminal: false)
        XCTAssertTrue(
            out.hasSuffix("\(Supertonic3UnicodeProcessor.continuationMark)</en>"),
            "a mid-clause fragment must not be closed with a period")
        XCTAssertFalse(out.hasSuffix(".</en>"))
    }

    func testTerminalFragmentStillGetsPeriod() {
        let out = Supertonic3UnicodeProcessor.preprocess(
            text: "the scheduler falls back to the CPU", lang: "en", isTerminal: true)
        XCTAssertTrue(out.hasSuffix(".</en>"))
    }

    func testExistingPunctuationSurvivesRegardlessOfTerminality() {
        // Already-closed text is left alone either way — the flag only decides
        // what to add when nothing is there.
        XCTAssertEqual(
            Supertonic3UnicodeProcessor.preprocess(
                text: "In practice, however,", lang: "en", isTerminal: false),
            "<en>In practice, however,</en>")
        XCTAssertEqual(
            Supertonic3UnicodeProcessor.preprocess(
                text: "That is all.", lang: "en", isTerminal: false),
            "<en>That is all.</en>")
    }

    func testEncodeAppliesPerRowTerminality() throws {
        // Two rows, opposite terminality: only the terminal one may gain a
        // period. Exercised through `preprocess` since `encode` needs a
        // loaded indexer.
        let rows = [("first half of a clause", false), ("a whole sentence", true)]
        let processed = rows.map {
            Supertonic3UnicodeProcessor.preprocess(text: $0.0, lang: "en", isTerminal: $0.1)
        }
        XCTAssertTrue(
            processed[0].hasSuffix("\(Supertonic3UnicodeProcessor.continuationMark)</en>"))
        XCTAssertTrue(processed[1].hasSuffix(".</en>"))
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
