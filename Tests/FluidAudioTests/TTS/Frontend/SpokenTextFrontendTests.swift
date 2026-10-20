import XCTest

@testable import FluidAudio

final class SpokenTextFrontendTests: XCTestCase {
    func testRuleFrontendReadsEnglishWithTheEnglishPass() {
        let text = "In 1915, Mr. Gatsby paid $4.50."
        let spoken = RuleFrontend().spokenText(text, language: "en-US")
        XCTAssertEqual(spoken, EnglishTextNormalizer.spokenText(text))
        XCTAssertEqual(spoken.language, "en")
        XCTAssertEqual(spoken.expansions.map(\.source), ["1915,", "Mr.", "$4.50."])
    }

    func testRuleFrontendLeavesOtherLanguagesAsWritten() {
        let spoken = RuleFrontend().spokenText("Il a payé 4,50 €.", language: "fr-FR")
        XCTAssertEqual(spoken, SpokenText(text: "Il a payé 4,50 €.", language: "fr"))
    }

    func testPassthroughKeepsTheText() {
        let spoken = PassthroughFrontend().spokenText("E = mc², 26 kg.", language: "en_US")
        XCTAssertEqual(spoken, SpokenText(text: "E = mc², 26 kg.", language: "en"))
        XCTAssertTrue(spoken.expansions.isEmpty)
    }
}
