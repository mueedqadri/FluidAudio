import XCTest

@testable import FluidAudio

final class Supertonic3TextChunkerTests: XCTestCase {

    /// Fragment texts only — most cases care about where the splits land, not
    /// how each piece is closed.
    private func texts(_ text: String, maxLen: Int) -> [String] {
        Supertonic3TextChunker.chunk(text: text, maxLen: maxLen).map(\.text)
    }

    // MARK: - Trivial inputs

    func testEmptyInputReturnsNoChunks() {
        XCTAssertEqual(Supertonic3TextChunker.chunk(text: "", maxLen: 110), [])
        XCTAssertEqual(Supertonic3TextChunker.chunk(text: "   \n   ", maxLen: 110), [])
    }

    func testShortInputReturnsSingleChunkUnchanged() {
        XCTAssertEqual(texts("Hello there.", maxLen: 110), ["Hello there."])
    }

    func testInputAtMaxLenBoundaryFitsInOneChunk() {
        let text = String(repeating: "a", count: 110)
        let chunks = texts(text, maxLen: 110)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.count, 110)
    }

    // MARK: - Sentence packing

    func testSentencesAreCombinedUpToMaxLen() {
        XCTAssertEqual(texts("One. Two. Three. Four.", maxLen: 110).count, 1)
    }

    func testLongSentenceTriggersBoundarySplit() {
        // Two sentences of ~60 chars each — together exceed maxLen=80, so the
        // packer should emit two chunks, one per sentence.
        let sentenceA = String(repeating: "a", count: 60) + "."
        let sentenceB = String(repeating: "b", count: 60) + "."
        let chunks = texts("\(sentenceA) \(sentenceB)", maxLen: 80)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 80 })
    }

    // MARK: - Abbreviation awareness

    func testAbbreviationDoesNotSplitMidSentence() {
        // "Dr." should not be treated as a sentence terminator. The packer
        // should keep "Dr. Smith arrived early." as one sentence.
        let chunks = texts("Dr. Smith arrived early. Then he left.", maxLen: 110)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("Dr. Smith"))
        XCTAssertTrue(chunks[0].contains("Then he left."))
    }

    // MARK: - Comma fallback

    func testLongSentenceFallsBackToCommaBoundaries() {
        let parts = (0..<6).map { _ in String(repeating: "x", count: 18) }
        let sentence = parts.joined(separator: ", ") + "."
        let chunks = texts(sentence, maxLen: 50)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 50 })
    }

    // MARK: - Word fallback

    func testVeryLongCommaFreeRunFallsBackToWordBoundaries() {
        let words = Array(repeating: "word", count: 40)
        let sentence = words.joined(separator: " ") + "."
        let chunks = texts(sentence, maxLen: 30)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 30 })
    }

    // MARK: - Paragraph split (blank-line boundary)

    func testParagraphsAreSplitOnBlankLines() {
        let chunks = texts("First paragraph.\n\nSecond paragraph.", maxLen: 110)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0], "First paragraph.")
        XCTAssertEqual(chunks[1], "Second paragraph.")
    }

    // MARK: - Terminal classification

    func testWordSplitFragmentsAreNotTerminal() {
        // A comma-free run split at word boundaries: only the final piece
        // carries the sentence's period, so only it may be closed with one.
        let sentence = Array(repeating: "word", count: 40).joined(separator: " ") + "."
        let chunks = Supertonic3TextChunker.chunk(text: sentence, maxLen: 30)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(
            chunks.dropLast().allSatisfy { !$0.isTerminal },
            "mid-sentence word splits must not be marked terminal")
        XCTAssertTrue(chunks.last!.isTerminal)
    }

    func testCommaSplitFragmentsAreNotTerminal() {
        let parts = (0..<6).map { _ in String(repeating: "x", count: 18) }
        let chunks = Supertonic3TextChunker.chunk(
            text: parts.joined(separator: ", ") + ".", maxLen: 50)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.dropLast().allSatisfy { !$0.isTerminal })
        XCTAssertTrue(chunks.last!.isTerminal)
    }

    func testFragmentsCarryingSourcePunctuationAreTerminal() {
        // Each sentence keeps its own terminator, so every piece is terminal
        // even though only the last one ends the input.
        let sentenceA = String(repeating: "a", count: 60) + "."
        let sentenceB = String(repeating: "b", count: 60) + "!"
        let chunks = Supertonic3TextChunker.chunk(
            text: "\(sentenceA) \(sentenceB)", maxLen: 80)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy(\.isTerminal))
    }

    func testFinalFragmentIsTerminalEvenWithoutPunctuation() {
        // A caller handing over a bare phrase still gets a closed utterance.
        let chunks = Supertonic3TextChunker.chunk(text: "no full stop here", maxLen: 110)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].isTerminal)
    }

    func testEveryParagraphEndIsTerminal() {
        let chunks = Supertonic3TextChunker.chunk(
            text: "First paragraph.\n\nSecond paragraph.", maxLen: 110)
        XCTAssertTrue(chunks.allSatisfy(\.isTerminal))
    }
}
