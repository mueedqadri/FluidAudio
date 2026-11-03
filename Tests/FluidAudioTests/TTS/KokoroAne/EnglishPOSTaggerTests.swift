import Foundation
import XCTest

@testable import FluidAudio

/// The bundled perceptron must tag like NLTK's `averaged_perceptron_tagger_eng`.
/// Expected tags are NLTK 3.10's output for the same tokens.
final class EnglishPOSTaggerTests: XCTestCase {

    private func tagger() throws -> EnglishPOSTagger {
        try XCTUnwrap(EnglishPOSTagger.shared, "EnglishPOSTagger.bin must load from the bundle")
    }

    func testTagsMatchNLTK() throws {
        let cases: [(String, String)] = [
            ("I live at West Egg .", "PRP VBP IN NNP NNP ."),
            ("It was a live concert .", "PRP VBD DT JJ NN ."),
            ("Animals live in the forest .", "NNS VBP IN DT NN ."),
            ("Some live , some die .", "DT VBP , DT NN ."),
            ("She has wound the clock .", "PRP VBZ VBN DT NN ."),
            ("The wound healed .", "DT NN VBD ."),
            ("Then read the file .", "RB VB DT NN ."),
            ("In 1922 he bought 37 shares .", "IN CD PRP VBD CD NNS ."),
        ]
        let tagger = try tagger()
        for (sentence, expected) in cases {
            let words = sentence.split(separator: " ").map(String.init)
            XCTAssertEqual(tagger.tag(words).joined(separator: " "), expected, sentence)
        }
    }

    /// Phonemizer tokens are re-cut into Treebank tokens: clitics split off and
    /// quotes turned into opening and closing marks; a token takes its first
    /// piece's tag.
    func testPhonemizerTokensTakeTheirFirstPiecesTag() throws {
        let text = "\u{201C}I don't live there,\u{201D} she said."
        let tokens = KokoroAneEnglishPhonemizer.splitWordTokens(text)
        let tags = try tagger().tags(forWordTokens: tokens, in: text)
        let byToken = Dictionary(zip(tokens.map(\.token), tags), uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byToken["\u{201C}"], "``")
        XCTAssertEqual(byToken["\u{201D}"], "''")
        XCTAssertEqual(byToken["don't"], "VBP")
        XCTAssertEqual(byToken["live"], "VB")
        XCTAssertEqual(byToken["said"], "VBD")
    }
}
