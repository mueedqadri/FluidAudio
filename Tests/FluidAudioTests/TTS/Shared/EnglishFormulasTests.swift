import Foundation
import XCTest

@testable import FluidAudio

/// Chemical formulas and superscript powers read aloud; lookalikes stay words.
final class EnglishFormulasTests: XCTestCase {

    private func spoken(_ text: String) -> String { EnglishTextNormalizer.spokenText(text).text }

    func testFormulasReadLetterByLetterWithCounts() {
        XCTAssertEqual(spoken("Water is H₂O and H2O."), "Water is H two O and H two O.")
        XCTAssertEqual(spoken("Plants take in CO2 and CO₂."), "Plants take in C O two and C O two.")
        XCTAssertEqual(spoken("Add NaCl to Fe2O3 and KMnO4."), "Add N A C L to F E two O three and K M N O four.")
        XCTAssertEqual(spoken("The sample was MgO."), "The sample was M G O.")
        XCTAssertEqual(spoken("Use HCl on GaAs."), "Use H C L on G A A S.")
    }

    func testWordsThatSpellSymbolsStay() {
        let kept = ["Say NO to it.", "He went to the ICU.",
                    "In As We Go.", "It is CO now.", "The SON came home."]
        for text in kept { XCTAssertEqual(spoken(text), text) }
        // Serials with long numbers, and names that end in a metal, are not formulas.
        for code in ["CS581676", "FKF152462", "SN-BC82306", "HeLa", "SARS-CoV-2", "CoCo"] {
            XCTAssertEqual(EnglishFormulas.spell("Look for \(code) here."), "Look for \(code) here.")
        }
    }

    func testPowers() {
        XCTAssertEqual(spoken("The energy is E = mc²."), "The energy is E equals m c squared.")
        XCTAssertEqual(spoken("Take x² and y³ here."), "Take x squared and y cubed here.")
        XCTAssertEqual(spoken("It was 10⁻³ of that."), "It was ten to the minus three of that.")
        XCTAssertEqual(spoken("The plot is 3 m² wide."), "The plot is three square meters wide.")
        XCTAssertEqual(spoken("Let x₁ be small."), "Let x one be small.")
        XCTAssertEqual(spoken("A clamped L¹ loss."), "A clamped L one loss.")
        XCTAssertEqual(spoken("Smoothing in log₁₀ units."), "Smoothing in log ten units.")
        XCTAssertEqual(spoken("Then AB² equals 4AC²."), "Then A B squared equals four A C squared.")
        XCTAssertEqual(spoken("It falls s = 16t² feet."), "It falls s equals sixteen t squared feet.")
        XCTAssertEqual(spoken("Take x²a here."), "Take x squared a here.")
    }
}
