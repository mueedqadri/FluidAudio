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
    }

    func testReferenceWordsComeFromTheTable() {
        XCTAssertTrue(SentenceBoundaryPolicy.referenceWords.isSuperset(of: ["Fig", "pp", "secs", "Art", "Para", "Pt", "Op"]))
    }
}
