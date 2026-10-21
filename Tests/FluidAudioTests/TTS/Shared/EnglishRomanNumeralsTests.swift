import Foundation
import XCTest

@testable import FluidAudio

/// Roman numerals read as numbers only where the context says so.
final class EnglishRomanNumeralsTests: XCTestCase {

    private func spoken(_ text: String) -> String { EnglishTextNormalizer.spokenText(text).text }

    func testValues() {
        XCTAssertEqual(EnglishRomanNumerals.value("XIX"), 19)
        XCTAssertEqual(EnglishRomanNumerals.value("CCCXCVI"), 396)
        XCTAssertEqual(EnglishRomanNumerals.value("iii"), 3)
        XCTAssertNil(EnglishRomanNumerals.value("IIII"))
        XCTAssertNil(EnglishRomanNumerals.value("Xi"))
    }

    func testAfterAWordThatNumbersThings() {
        XCTAssertEqual(spoken("Chapter XIX covers it."), "Chapter nineteen covers it.")
        XCTAssertEqual(spoken("Super Bowl CL drew a crowd."), "Super Bowl one hundred fifty drew a crowd.")
        XCTAssertEqual(spoken("Read Act II, Scene iii now."), "Read Act two, Scene three now.")
        XCTAssertEqual(spoken("It ended in World War II."), "It ended in World War two.")
        XCTAssertEqual(spoken("See Appendix C and Class D."), "See Appendix C and Class D.")
    }

    func testAfterANameReadsTheOrdinalOrACardinal() {
        XCTAssertEqual(spoken("Henry VIII married often."), "Henry the eighth married often.")
        XCTAssertEqual(spoken("Louis XIV's court was vast."), "Louis the fourteenth's court was vast.")
        XCTAssertEqual(spoken("Elizabeth I ruled long."), "Elizabeth the first ruled long.")
        XCTAssertEqual(spoken("Henry I was crowned."), "Henry the first was crowned.")
        XCTAssertEqual(spoken("They watched Rocky II twice."), "They watched Rocky two twice.")
    }

    func testNumeralsWithoutContextStay() {
        XCTAssertEqual(spoken("I went home."), "I went home.")
        XCTAssertEqual(spoken("Malcolm X spoke."), "Malcolm X spoke.")
        XCTAssertEqual(spoken("Elizabeth I want something."), "Elizabeth I want something.")
        XCTAssertEqual(spoken("Mary I'm here and Henry I never knew."), "Mary I'm here and Henry I never knew.")
        XCTAssertEqual(spoken("Then I left, and MIX was playing."), "Then I left, and MIX was playing.")
        XCTAssertEqual(spoken("Give the patient an IV now."), "Give the patient an IV now.")
        XCTAssertEqual(spoken("In this chapter I have shown it."), "In this chapter I have shown it.")
        XCTAssertEqual(spoken("See chapter iv for more."), "See chapter four for more.")
    }

    func testListMarkers() {
        XCTAssertEqual(spoken("Steps: (i) open it; (ii) read it."), "Steps: (one) open it; (two) read it.")
        XCTAssertEqual(spoken("He gave an (IV) drip."), "He gave an (IV) drip.")
    }

    func testANumeralAloneIsAHeadingOrAnItem() {
        let headings = [
            "III.": "three.", "XL": "forty", "XXIII.": "twenty three.", "viii.": "eight.", "(iii.)": "(three.)",
            "[xxii.]": "[twenty two.]", "ii": "two",
        ]
        for (written, read) in headings { XCTAssertEqual(spoken(written), read, written) }
        for kept in ["I.", "I", "V.", "(c)", "C.", "MIX", "CD.", "Xi"] { XCTAssertEqual(spoken(kept), kept, kept) }
    }
}
