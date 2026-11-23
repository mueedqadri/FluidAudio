import XCTest

@testable import FluidAudio

/// Where narration may end a sentence after an abbreviation.
final class SentenceBoundaryPolicyTests: XCTestCase {
    private func continues(_ text: String, _ next: String) -> Bool {
        SentenceBoundaryPolicy.continuesAcrossBoundary(text, into: next)
    }

    func testTitlesLatinAndReferenceWordsContinue() {
        XCTAssertTrue(continues("It was Mr.", "Gatsby who called."))
        XCTAssertTrue(continues("said Elizabeth drily--“Mr.", "Darcy is kind."))
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

    func testGermanOrdinalsContinue() {
        XCTAssertTrue(continues("Berlin wurde im 13.", "Jahrhundert erstmals urkundlich erwähnt."))
        XCTAssertTrue(continues("Die Mauer fiel am 9.", "November 1989."))
        XCTAssertTrue(continues("Abgerufen am 12.", "März 2025."))
        XCTAssertTrue(continues("Große Ausgabe, 7.", "Auflage, Göttingen."))
        XCTAssertTrue(continues("die Straße des 17.", "Juni führt zum Tor."))
        XCTAssertTrue(continues("Hertha BSC und der 1.", "FC Union Berlin."))
    }

    func testANumberAtTheEndOfASentenceStillEndsIt() {
        XCTAssertFalse(continues("im Jahr 2008 319.", "Im Vergleich der Stadtstaaten."))
        XCTAssertFalse(continues("Die A 103 kreuzt die A 111.", "Die Brücke ist alt."))
        XCTAssertFalse(continues("I was then 13.", "The year after, I left."))
        XCTAssertFalse(continues("I am 13.", "The year after, I left."))
        XCTAssertFalse(continues("among the states; 3.", "Maintenance of harmony."))
        XCTAssertFalse(continues("of extinct species, 329.", "of organic beings, 411."))
        XCTAssertFalse(continues("Desjardins, t. 1l, p. 40 et 382.", "Julien Vinson est plus circonspect."))
        XCTAssertFalse(continues("l’aire de développement des 1.", "Mortillet (A. de), p. 82."))
    }

    func testReferenceWordsComeFromTheTable() {
        XCTAssertTrue(SentenceBoundaryPolicy.referenceWords.isSuperset(of: ["Fig", "pp", "secs", "Art", "Para", "Pt", "Op"]))
    }

    func testTheFingerprintIsStable() {
        XCTAssertEqual(SentenceBoundaryPolicy.fingerprint, SentenceBoundaryPolicy.fingerprint)
        XCTAssertTrue(SentenceBoundaryPolicy.fingerprint.hasPrefix("2-"))
    }
}
