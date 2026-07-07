import Foundation
import XCTest

@testable import FluidAudio

/// Unit tests for the shared compound-token helpers: seam splitting for
/// camelCase / letter+digit tokens and the spoken form of digit runs.
final class EnglishCompoundWordsTests: XCTestCase {

    // MARK: - splitParts seams

    func testLetterDigitBoundaries() {
        XCTAssertEqual(EnglishCompoundWords.splitParts("CASP14"), ["CASP", "14"])
        XCTAssertEqual(EnglishCompoundWords.splitParts("14CASP"), ["14", "CASP"])
        XCTAssertEqual(EnglishCompoundWords.splitParts("B2B"), ["B", "2", "B"])
    }

    func testCamelCaseBoundaries() {
        XCTAssertEqual(EnglishCompoundWords.splitParts("MacReader"), ["Mac", "Reader"])
        XCTAssertEqual(EnglishCompoundWords.splitParts("camelCase"), ["camel", "Case"])
        XCTAssertEqual(EnglishCompoundWords.splitParts("iPhone15"), ["i", "Phone", "15"])
    }

    func testAcronymThenTitlecaseKeepsLastCapitalWithWord() {
        XCTAssertEqual(EnglishCompoundWords.splitParts("HTMLParser"), ["HTML", "Parser"])
        XCTAssertEqual(EnglishCompoundWords.splitParts("XMLHttpRequest"), ["XML", "Http", "Request"])
    }

    func testSeparatorsAreDropped() {
        XCTAssertEqual(EnglishCompoundWords.splitParts("COVID-19"), ["COVID", "19"])
        XCTAssertEqual(EnglishCompoundWords.splitParts("-5"), ["5"])
    }

    func testSeamlessWordsComeBackWhole() {
        XCTAssertEqual(EnglishCompoundWords.splitParts("hello"), ["hello"])
        XCTAssertEqual(EnglishCompoundWords.splitParts("NASA"), ["NASA"])
        XCTAssertEqual(EnglishCompoundWords.splitParts("Reader"), ["Reader"])
        XCTAssertEqual(EnglishCompoundWords.splitParts("42"), ["42"])
    }

    // MARK: - spokenWords for digit runs

    func testPlainRunsReadAsCardinals() {
        XCTAssertEqual(EnglishCompoundWords.spokenWords(forDigits: "14"), ["fourteen"])
        XCTAssertEqual(EnglishCompoundWords.spokenWords(forDigits: "26"), ["twenty", "six"])
        XCTAssertEqual(
            EnglishCompoundWords.spokenWords(forDigits: "1990"),
            ["one", "thousand", "nine", "hundred", "ninety"])
    }

    func testLeadingZeroRunsReadDigitByDigit() {
        XCTAssertEqual(EnglishCompoundWords.spokenWords(forDigits: "007"), ["zero", "zero", "seven"])
    }

    func testOverflowRunsReadDigitByDigit() {
        // 20 digits — past Int.max, so the cardinal spelling can't apply.
        let spoken = EnglishCompoundWords.spokenWords(forDigits: "12345678901234567890")
        XCTAssertEqual(spoken.count, 20)
        XCTAssertEqual(spoken.first, "one")
        XCTAssertEqual(spoken.last, "zero")
    }
}
