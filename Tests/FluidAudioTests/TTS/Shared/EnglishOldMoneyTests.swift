import Foundation
import XCTest

@testable import FluidAudio

/// Pounds, shillings and pence as old books write them.
final class EnglishOldMoneyTests: XCTestCase {

    private func spoken(_ text: String) -> String { EnglishTextNormalizer.spokenText(text).text }

    func testSpacedPoundSignJoinsItsAmount() {
        XCTAssertEqual(spoken("A salary of £ 4 a week."), "A salary of four pounds a week.")
        XCTAssertEqual(spoken("Some £ 14,000 in the bank."), "Some fourteen thousand pounds in the bank.")
    }

    func testShillingsAndPence() {
        XCTAssertEqual(spoken("It grew to £259. 7s. 6d. by then."),
                       "It grew to two hundred fifty nine pounds, seven shillings and six pence by then.")
        XCTAssertEqual(spoken("It cost 3s. 6d. new."), "It cost three shillings and six pence new.")
        XCTAssertEqual(spoken("All except £3, 10s. each."), "All except three pounds, ten shillings each.")
        XCTAssertEqual(spoken("It came to £ 88 10_s_., while"), "It came to eighty eight pounds, ten shillings, while")
    }

    func testColonForm() {
        XCTAssertEqual(spoken("The sum borrowed upon it was £983,254:11:9¼."),
                       "The sum borrowed upon it was nine hundred eighty three thousand two hundred fifty four pounds, eleven shillings and nine and a quarter pence.")
    }

    func testDecadesStay() {
        XCTAssertEqual(EnglishOldMoney.spell("It boomed in the 1990s. Then it fell."), "It boomed in the 1990s. Then it fell.")
    }
}
