import Foundation
import XCTest

@testable import FluidAudio

/// The generated NeMo entries still say what the linked grammars say; rerun
/// `Scripts/verbalization/abbreviation_map.py --write` when this fails.
final class EnglishAbbreviationTableNeMoTests: XCTestCase {

    func testEveryNeMoEntryRoundTripsThroughTheEngine() throws {
        try XCTSkipUnless(NemoTextNormalizer.normalize("5", language: .english) != "5", "NeMo engine not linked")
        for entry in EnglishAbbreviationTable.nemoEntries {
            let sentence: String
            switch entry.context {
            case .anywhere: sentence = "It was \(entry.written) today."
            case .streetSuffix: sentence = "It is at 12 Elm \(entry.written). today."
            case .title: sentence = "We met \(entry.written). Smith today."
            case .beforeNumber, .afterNumber: continue
            }
            let read = NemoTextNormalizer.normalize(sentence, language: .english)
            XCTAssertTrue(read.contains(entry.spoken), "\(entry.written): \"\(read)\"")
        }
    }
}
