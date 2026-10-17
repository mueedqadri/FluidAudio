import Foundation
import XCTest

@testable import FluidAudio

/// NeMo text normalization limited to written words with a digit, and the
/// spoken words tied back to the written ones for word timings.
final class EnglishSpokenTextTests: XCTestCase {

    private func spoken(_ text: String) -> String {
        EnglishTextNormalizer.spokenText(text).text
    }

    func testTextWithoutDigitsIsReturnedAsWritten() {
        let text = "“Take ’em downstairs,” said Mr. Gatsby to Mrs. Wilson."
        let result = EnglishTextNormalizer.spokenText(text)
        XCTAssertEqual(result.text, text)
        XCTAssertTrue(result.expansions.isEmpty)
    }

    func testNumbersAreReadInContext() {
        XCTAssertEqual(spoken("It weighs 26 kg today."), "It weighs twenty six kilograms today.")
        XCTAssertEqual(spoken("It rose to 93.4% last year."), "It rose to ninety three point four percent last year.")
        XCTAssertEqual(spoken("It was 1999 then."), "It was nineteen ninety nine then.")
    }

    func testRewritesWithoutADigitStayAsWritten() {
        XCTAssertEqual(
            spoken("In 1915, Mr. Gatsby met Mrs. Wilson."),
            "In nineteen fifteen, Mr. Gatsby met Mrs. Wilson.")
        XCTAssertEqual(
            spoken("“Take ’em downstairs,” he said in 1922."),
            "“Take ’em downstairs,” he said in nineteen twenty two.")
    }

    func testNumbersDropTheBritishAnd() {
        XCTAssertEqual(spoken("It cost 270 dollars."), "It cost two hundred seventy dollars.")
        XCTAssertEqual(spoken("Show that 169 + 101 = 270."), "Show that one hundred sixty nine plus one hundred one equals two hundred seventy.")
    }

    func testTimeSignatureIsNotAFraction() {
        XCTAssertEqual(spoken("Play it in 5/4 time."), "Play it in five four time.")
        XCTAssertEqual(spoken("About 2/5 of them came."), "About two fifths of them came.")
    }

    func testExpansionPointsAtItsSpokenWords() {
        let result = EnglishTextNormalizer.spokenText("It was 1999 then.")
        XCTAssertEqual(result.expansions.count, 1)
        let expansion = result.expansions[0]
        XCTAssertEqual(expansion.source, "1999")
        let ns = result.text as NSString
        let range = NSRange(location: expansion.range.lowerBound, length: expansion.range.count)
        XCTAssertEqual(ns.substring(with: range), "nineteen ninety nine")
    }

    // MARK: - Ranges, versions and symbols

    func testRangesReadWithTo() {
        XCTAssertTrue(spoken("See pages 7–9 today.").contains("seven to nine"))
        XCTAssertTrue(spoken("See pp. 45-67 for it.").contains("forty five to sixty seven"))
        XCTAssertTrue(spoken("The match ended 58-7 at home.").contains("fifty eight to seven"))
        XCTAssertTrue(spoken("The war of 1914-1918 ended.").contains("nineteen fourteen to nineteen eighteen"))
        XCTAssertTrue(spoken("Open 6:15-6:30 daily.").contains("six fifteen to six thirty"))
    }

    func testHyphensThatAreNotRangesStay() {
        XCTAssertFalse(spoken("Call 555-0199 now.").contains(" to "))
        XCTAssertFalse(spoken("It was on 2009-02-26 here.").contains(" to "))
        XCTAssertTrue(spoken("It rose from 8-1/2 to 9.").contains("eight and one half"))
    }

    func testVersionsAndSectionNumbers() {
        XCTAssertTrue(spoken("Section 3.1.2 describes it.").contains("three point one point two"))
        XCTAssertTrue(spoken("Upgrade to v2.5.0 now.").contains("version two point five point zero"))
        XCTAssertTrue(spoken("Fixed in version 4.26 today.").contains("version four point twenty six"))
    }

    func testSymbolsBesideNumbers() {
        let stats = spoken("It was significant (p < 0.05, n = 120).")
        XCTAssertTrue(stats.contains("less than zero point zero five"), stats)
        XCTAssertTrue(stats.contains("n equals one hundred twenty"), stats)
        XCTAssertTrue(spoken("It rose 93.4% ± 0.2 overall.").contains("plus or minus zero point two"))
        XCTAssertTrue(spoken("A 2× speedup.").contains("two times speedup"))
        XCTAssertTrue(spoken("Keep x ≥ 5 always.").contains("greater than or equal to five"))
        XCTAssertTrue(spoken("Meet at 5 AM sharp.").contains("five a.m."))
        XCTAssertTrue(spoken("The model has 1.3B parameters.").contains("one point three billion"))
    }

    func testArithmeticStaysWithNeMo() {
        XCTAssertTrue(
            spoken("Show 705 - 30 = 675.").contains("seven hundred five minus thirty equals six hundred seventy five"))
        XCTAssertTrue(spoken("Here 50% of 620 = 310 holds.").contains("equals three hundred ten"))
    }

    func testAccidentalsWithoutDigits() {
        XCTAssertEqual(spoken("Play it in B♭ major."), "Play it in B flat major.")
        XCTAssertEqual(spoken("Then F♯ minor."), "Then F sharp minor.")
    }

    // MARK: - Segment merging

    private typealias Segment = KokoroAneEnglishPhonemizer.PhonemeSegment

    func testExpansionSegmentsMergeUnderTheWrittenWord() {
        let result = EnglishTextNormalizer.spokenText("It was 1999 then.")
        let segments: [Segment] = [
            .init(word: "It", phonemes: "ˌɪt"),
            .init(word: "was", phonemes: "wʌz"),
            .init(word: "nineteen", phonemes: "nˌIntˈin"),
            .init(word: "ninety", phonemes: "nˈIndi"),
            .init(word: "nine", phonemes: "nˈIn"),
            .init(word: "then", phonemes: "ðˈɛn."),
        ]
        let merged = result.mergingExpansions(segments)
        XCTAssertEqual(merged.map(\.word), ["It", "was", "1999", "then"])
        XCTAssertEqual(merged[2].phonemes, "nˌIntˈin nˈIndi nˈIn")
        XCTAssertEqual(
            merged.map(\.phonemes).joined(separator: " "),
            segments.map(\.phonemes).joined(separator: " "),
            "the phoneme string the model receives must not change")
    }

    func testSegmentsThatCannotBeFoundAreLeftAlone() {
        let result = EnglishTextNormalizer.spokenText("It was 1999 then.")
        let segments: [Segment] = [
            .init(word: "It", phonemes: "ˌɪt"),
            .init(word: "unrelated", phonemes: "ʌnɹəlˈATᵻd"),
        ]
        XCTAssertEqual(result.mergingExpansions(segments), segments)
    }
}
