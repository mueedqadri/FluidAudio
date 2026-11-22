import XCTest

@testable import FluidAudio

/// Where narration may end a sentence after an abbreviation.
final class SentenceBoundaryPolicyTests: XCTestCase {
    private func continues(_ text: String, _ next: String) -> Bool {
        SentenceBoundaryPolicy.continuesAcrossBoundary(text, into: next)
    }

    func testTitlesLatinAndReferenceWordsContinue() {
        XCTAssertTrue(continues("It was Mr.", "Gatsby who called."))
        XCTAssertTrue(continues("As shown, cf.", "Table 2."))
        XCTAssertTrue(continues("See Fig.", "3 for it."))
        XCTAssertFalse(continues("See the Fig.", "It grew."))
        XCTAssertTrue(continues("Under Art.", "231 of the Treaty."))
        XCTAssertTrue(continues("The saint was on St.", "James Street."))
        XCTAssertFalse(continues("He lived on Elm St.", "Then he moved."))
    }

    func testInitialsContinueExceptBeforeASentenceOpener() {
        XCTAssertTrue(continues("It was written by J.", "Smith in 1902."))
        XCTAssertTrue(continues("It was written by A.", "A. Milne."))
        XCTAssertFalse(continues("I am sure he would exclude me from P.", "I shall never see it."))
        XCTAssertFalse(continues("She wrote for C.", "Well, I think so."))
        XCTAssertFalse(continues("Söding, J.", "Protein homology detection."))
        XCTAssertFalse(continues("Chapter I.", "The beginning."))
        XCTAssertFalse(continues("I said to him for P.", "I’m sure of it."))
        XCTAssertTrue(continues("By T. J.", "I’a Bromwich, M.A."))
        XCTAssertTrue(continues("↑ Zemskov V.", "N. On repatriation of Soviet citizens."))
        XCTAssertFalse(continues("↑ Zemskov V. N.", "On repatriation of Soviet citizens."))
    }

    func testOtherLanguagesTitlesAndReferenceWordsContinue() {
        XCTAssertTrue(continues("La Chèvre de M.", "Seguin, d'Alphonse Daudet."))
        XCTAssertTrue(continues("Kinder- und Hausmärchen Nr.", "27, aus den Kinder- und Hausmärchen."))
        XCTAssertTrue(continues("Steht auf S.", "145 im ersten Band."))
        XCTAssertTrue(continues("Das gilt z. B.", "für Esel."))
        XCTAssertTrue(continues("Llegó el Sr.", "García a las tres."))
        XCTAssertTrue(continues("Lo dice en la pág.", "12 del libro."))
        XCTAssertTrue(continues("Arrivò il Sig.", "Rossi con la moglie."))
        XCTAssertTrue(continues("Frutas, p. ej.", "manzanas."))
    }

    func testAnotherLanguagesReferenceWordStaysAnInitial() {
        XCTAssertTrue(continues("Composed by J. S.", "Bach in Leipzig."))
        XCTAssertFalse(continues("Er wohnt in Nr.", "Dann zog er um."))
    }

    func testReferenceWordsComeFromTheTable() {
        XCTAssertTrue(SentenceBoundaryPolicy.referenceWords.isSuperset(of: ["Fig", "pp", "secs", "Art", "Para", "Pt", "Op"]))
    }

    func testTheFingerprintIsStable() {
        XCTAssertEqual(SentenceBoundaryPolicy.fingerprint, SentenceBoundaryPolicy.fingerprint)
        XCTAssertTrue(SentenceBoundaryPolicy.fingerprint.hasPrefix("1-"))
    }
}
