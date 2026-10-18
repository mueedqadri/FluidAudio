import Foundation
import XCTest

@testable import FluidAudio

/// NeMo text normalization over whole sentences, our rules for what it
/// misreads, and the spoken words tied back to the written ones for word timings.
final class EnglishSpokenTextTests: XCTestCase {

    private func spoken(_ text: String) -> String {
        EnglishTextNormalizer.spokenText(text).text
    }

    func testPlainProseIsReturnedAsWritten() {
        let text = "It was a quiet evening, and nobody spoke."
        let result = EnglishTextNormalizer.spokenText(text)
        XCTAssertEqual(result.text, text)
        XCTAssertTrue(result.expansions.isEmpty)
    }

    func testNumbersAreReadInContext() {
        XCTAssertEqual(spoken("It weighs 26 kg today."), "It weighs twenty six kilograms today.")
        XCTAssertEqual(spoken("It rose to 93.4% last year."), "It rose to ninety three point four percent last year.")
        XCTAssertEqual(spoken("It was 1999 then."), "It was nineteen ninety nine then.")
    }

    func testNeMoReadsWordsWithoutADigit() {
        let result = EnglishTextNormalizer.spokenText("In 1915, Mr. Gatsby met Mrs. Wilson.")
        XCTAssertEqual(result.text, "In nineteen fifteen, mister Gatsby met mrs Wilson.")
        XCTAssertEqual(result.expansions.map(\.source), ["1915,", "Mr.", "Mrs."])
        XCTAssertEqual(spoken("She tagged @alice_maya today."), "She tagged at alice underscore maya today.")
        XCTAssertEqual(
            spoken("Email jane.doe@example.com today."), "Email jane dot doe at example dot com today.")
        XCTAssertEqual(spoken("It ended in World War II."), "It ended in World War two.")
    }

    func testTheTableReadsTitlesAndPlacesBeforeNeMo() {
        XCTAssertEqual(spoken("Adm. Nelson met Prof. Lee."), "admiral Nelson met professor Lee.")
        XCTAssertEqual(spoken("Mr. and Mrs. Bennet came."), "mister and mrs Bennet came.")
        XCTAssertEqual(spoken("We went to St. Paul on Elm St. today."), "We went to Saint Paul on Elm Street today.")
        XCTAssertEqual(spoken("Mr. Neville St. Clair lived on Elm St."), "mister Neville Saint Clair lived on Elm Street.")
        XCTAssertEqual(spoken("Dr. Jones lives on Mulholland Dr. now."), "doctor Jones lives on Mulholland Drive now.")
        XCTAssertEqual(spoken("It is at 12 Main Ave. and Fifth Ave."), "It is at twelve Main Avenue and Fifth Avenue.")
        XCTAssertEqual(spoken("John Smith, Esq. climbed Mt. Rainier."), "John Smith, esquire climbed Mount Rainier.")
        XCTAssertEqual(spoken("The dept. head asked the Prof. again."), "The department head asked the Prof. again.")
    }

    func testSentenceKeepsTheFullStopAnAbbreviationShares() {
        XCTAssertEqual(spoken("We met at 5 p.m."), "We met at five PM.")
        XCTAssertEqual(spoken("They live at No. 7 Elm St."), "They live at number seven Elm Street.")
    }

    func testFormsNeMoMisreadsAreHeldBack() {
        XCTAssertEqual(spoken("She works for AT&T."), "She works for AT&T.")
        XCTAssertEqual(spoken("A. M. Turing proved it."), "A. M. Turing proved it.")
        XCTAssertEqual(spoken("The AM radio was on."), "The AM radio was on.")
        XCTAssertEqual(spoken("See it, cf. the rest."), "See it, compare the rest.")
        XCTAssertEqual(spoken("It took 3 hrs."), "It took three hours.")
        XCTAssertEqual(spoken("Plates, etc. and cups."), "Plates, etc. and cups.")
        XCTAssertEqual(spoken("Do you dance at St. James’s?"), "Do you dance at Saint James’s?")
        XCTAssertEqual(spoken("Love to her mother.--Yours, Mr. Collins."), "Love to her mother.--Yours, mister Collins.")
        XCTAssertEqual(spoken("They came to ’Frisco with Mr. Wolfsheim."), "They came to ’Frisco with mister Wolfsheim.")
        XCTAssertEqual(spoken("Exports for Jan.-Mar. fell."), "Exports for Jan.-Mar. fell.")
        XCTAssertEqual(spoken("Bring a pen and/or a pencil (he/she)."), "Bring a pen and/or a pencil (he/she).")
        XCTAssertEqual(spoken("About 2/5 of them came."), "About two fifths of them came.")
        XCTAssertEqual(spoken("The _War_ ended. * * *"), "The _War_ ended. * * *")
        XCTAssertEqual(spoken("Stamp (_Journal_, 1920)."), "Stamp (_Journal_, nineteen twenty).")
        XCTAssertEqual(spoken("| 175 | 395 |"), "| one hundred seventy five | three hundred ninety five |")
        XCTAssertEqual(spoken("Up at 6:00 a.m. today."), "Up at six AM today.")
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
        XCTAssertTrue(spoken("Meet at 5 AM sharp.").contains("five AM"))
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

    // MARK: - Reference abbreviations

    func testReferenceWordsBeforeANumber() {
        XCTAssertTrue(spoken("As shown in Fig. 3 and Eq. (2), it holds.").contains("figure three and equation (two)"))
        XCTAssertTrue(spoken("See Sec. 4.2 and Ch. 5 now.").contains("section four point two and chapter five"))
        XCTAssertTrue(spoken("Read pp. 45-67 and p. 9 first.").contains("pages forty five to sixty seven and page nine"))
        XCTAssertTrue(spoken("Published in vol. 21, no. 140 then.").contains("volume twenty one, number one hundred forty"))
    }

    func testReferenceWordsElsewhereStay() {
        XCTAssertEqual(spoken("No. I will not."), "No. I will not.")
        XCTAssertEqual(spoken("The fig. tree grew."), "The fig. tree grew.")
    }

    func testLatinAbbreviations() {
        XCTAssertEqual(
            spoken("The method, i.e. descent, works, e.g. on images."),
            "The method, that is descent, works, for example on images.")
        XCTAssertEqual(spoken("Compare it, cf. Table 2."), "Compare it, compare Table two.")
        XCTAssertEqual(spoken("Shown by Smith et al. last year."), "Shown by Smith et al last year.")
        XCTAssertEqual(spoken("Shown by Smith et al. The end."), "Shown by Smith et al. The end.")
    }

    func testEditorsEditionsAndUnits() {
        XCTAssertTrue(spoken("In: Jones, A. (Ed.), Handbook, 2nd ed. today.").contains("(editor), Handbook, second edition"))
        XCTAssertTrue(spoken("Training took 3.5 hrs total.").contains("three point five hours"))
        XCTAssertTrue(spoken("It took 1 hr here.").contains("one hour"))
        XCTAssertTrue(spoken("(Devlin et al., 2019b) agree.").contains("twenty nineteen B"))
    }

    func testInitialsKeepTheirPeriodButRomanNumeralsDoNot() {
        func merges(_ word: String, in text: String) -> Bool {
            let period = text.firstIndex(of: ".")!
            return EnglishTitleAbbreviations.mergesPeriod(afterWord: word, in: text, periodIndex: period)
        }
        XCTAssertTrue(merges("J", in: "J. Smith"))
        XCTAssertEqual(EnglishTitleAbbreviations.expansion(forTitleToken: "J."), "J")
        XCTAssertFalse(merges("I", in: "I. The war"))
        XCTAssertFalse(merges("X", in: "X. Section"))
        XCTAssertFalse(merges("J", in: "J. and"))
        func mergesLast(_ text: String) -> Bool {
            let period = text.lastIndex(of: ".")!
            let word = String(text[text.index(before: period)])
            return EnglishTitleAbbreviations.mergesPeriod(afterWord: word, in: text, periodIndex: period)
        }
        XCTAssertTrue(mergesLast("Andrew J. Ballard"))
        XCTAssertFalse(mergesLast("Steinegger, M. & Söding, J. Protein"))
        XCTAssertFalse(mergesLast("Eddy, S. R. Accelerated"))
        XCTAssertFalse(mergesLast("approximately 1.4 Å. In addition"))
        XCTAssertTrue(mergesLast("On October 3, 1919, M. Bilinski"))
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
