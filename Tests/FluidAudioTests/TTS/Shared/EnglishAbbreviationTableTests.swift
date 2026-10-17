import Foundation
import XCTest

@testable import FluidAudio

/// One table drives the title, reference-word and anywhere abbreviations.
final class EnglishAbbreviationTableTests: XCTestCase {

    func testEachWrittenFormHasOneEntryPerContext() {
        let keys = EnglishAbbreviationTable.entries.map { "\($0.context)|\($0.written)" }
        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testListsAreViewsOverTheTable() {
        XCTAssertEqual(EnglishTitleAbbreviations.expansions["Mr"], "mister")
        XCTAssertEqual(EnglishTitleAbbreviations.expansions.count, 23)
        XCTAssertEqual(EnglishReferenceAbbreviations.beforeNumber["pp"], "pages")
        XCTAssertNil(EnglishTitleAbbreviations.expansions["Mr."])
    }

    func testUnitsReadSingularAfterOne() {
        XCTAssertEqual(EnglishReferenceAbbreviations.spell("It took 1 hr and 20 mins today."), "It took 1 hour and 20 minutes today.")
        XCTAssertEqual(EnglishReferenceAbbreviations.spell("Wait 3.5 secs."), "Wait 3.5 seconds")
    }

    func testEveryAnywhereEntryReadsInASentence() {
        let frames: [String: String] = [
            "et al.": "Smith et al. showed it", "(Ed.)": "Smith (Ed.) wrote it",
            "(Eds.)": "Smith (Eds.) wrote it", "ed.": "the 2nd ed. of it",
        ]
        for entry in EnglishAbbreviationTable.entries {
            guard case .anywhere = entry.context else { continue }
            let sentence = frames[entry.written] ?? "a, \(entry.written) b"
            XCTAssertTrue(
                EnglishReferenceAbbreviations.spell(sentence).contains(entry.spoken),
                "\(entry.written) in \"\(sentence)\"")
        }
    }
}
