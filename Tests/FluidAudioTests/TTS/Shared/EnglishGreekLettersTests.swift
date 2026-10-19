import Foundation
import XCTest

@testable import FluidAudio

/// Greek letters used as symbols are read by name; Greek words are left alone.
final class EnglishGreekLettersTests: XCTestCase {

    private func spoken(_ text: String) -> String { EnglishTextNormalizer.spokenText(text).text }

    func testSymbolsAreNamed() {
        XCTAssertEqual(spoken("The free energy ΔG is negative."), "The free energy delta G is negative.")
        XCTAssertEqual(spoken("The Cα atoms move."), "The C alpha atoms move.")
        XCTAssertEqual(spoken("A 2σ deviation."), "A two sigma deviation.")
        XCTAssertEqual(spoken("A significance of 5.1σ was seen."), "A significance of five point one sigma was seen.")
        XCTAssertEqual(spoken("The channel H→ γγ is clean."), "The channel H→ gamma gamma is clean.")
        XCTAssertEqual(spoken("We used α = 0.3 here."), "We used alpha equals zero point three here.")
        XCTAssertEqual(spoken("The update ∆Φ is small."), "The update delta phi is small.")
    }

    func testPowersAndSubscriptsOfGreekLetters() {
        XCTAssertEqual(spoken("If χ² is large."), "If chi squared is large.")
        XCTAssertEqual(spoken("Set β₂ to one."), "Set beta two to one.")
    }

    func testGreekWordsStay() {
        XCTAssertEqual(EnglishGreekLetters.spell("the word λόγος here"), "the word λόγος here")
    }
}
