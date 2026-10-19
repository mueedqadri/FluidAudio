import Foundation
import XCTest

@testable import FluidAudio

/// Numbers glued to a letter or a hyphenated word read as numbers; serial codes stay.
final class EnglishGluedNumbersTests: XCTestCase {

    private func spoken(_ text: String) -> String { EnglishTextNormalizer.spokenText(text).text }

    func testModelSizesAndProductNumbers() {
        XCTAssertEqual(spoken("It ran on one A100 node."), "It ran on one A one hundred node.")
        XCTAssertEqual(spoken("Take vitamin B12 daily."), "Take vitamin B twelve daily.")
        XCTAssertEqual(spoken("It leads to a 1202-layer network."), "It leads to a twelve oh two-layer network.")
        XCTAssertEqual(spoken("A 1990-era design."), "A nineteen ninety-era design.")
        XCTAssertEqual(spoken("We use V2 of the model."), "We use version two of the model.")
    }

    func testSerialCodesStay() {
        for text in ["Order part TV-40-E41 now.", "The part CS581676 ships.", "During COVID-19 it closed.",
                     "He lived at 221B, Baker Street.", "See ANSI Z39.48-1984 for it.",
                     "Apply 0001-add-limit-to-log-function.patch first."] {
            XCTAssertEqual(EnglishGluedNumbers.spell(text), text)
        }
    }
}
