import Foundation
import XCTest

@testable import FluidAudio

/// Unit symbols after a number read as units; alone they stay letters.
final class EnglishUnitSymbolsTests: XCTestCase {

    private func spoken(_ text: String) -> String { EnglishTextNormalizer.spokenText(text).text }

    func testSymbolsAfterANumberReadAsUnits() {
        XCTAssertEqual(spoken("They were now 100 feet (30 m) from the surface."),
                       "They were now one hundred feet (thirty meters) from the surface.")
        XCTAssertEqual(spoken("It ran at 10 W and 20 V for an hour."), "It ran at ten watts and twenty volts for an hour.")
        XCTAssertEqual(spoken("A rod 1 m long."), "A rod one meter long.")
        XCTAssertEqual(spoken("Wait 5 s then 2 ms."), "Wait five seconds then two milliseconds.")
        XCTAssertEqual(spoken("It is 5 mm thick."), "It is five millimeters thick.")
    }

    func testMicroAndElectronVoltUnits() {
        XCTAssertEqual(spoken("Add 20 µl and 10 μM of it."), "Add twenty microliters and ten micromolar of it.")
        XCTAssertEqual(spoken("For the 8 TeV data at 126 GeV."), "For the eight T E V data at one hundred twenty six G E V.")
    }

    func testInchesAndAPercentAfterARange() {
        XCTAssertEqual(spoken("When r = 5.5 in. and h = 20 in."), "When r equals five point five inches and h equals twenty inches.")
        XCTAssertEqual(spoken("Dark chocolate, 70–85% cocoa."), "Dark chocolate, seventy to eighty five percent cocoa.")
    }

    func testLettersAloneStay() {
        XCTAssertEqual(spoken("See Fig. 2 A and the letter m."), "See figure two A and the letter m.")
        XCTAssertEqual(spoken("Come in and sit."), "Come in and sit.")
    }
}
