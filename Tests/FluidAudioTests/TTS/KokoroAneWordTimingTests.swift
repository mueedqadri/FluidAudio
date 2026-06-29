import XCTest

@testable import FluidAudio

/// Unit tests for the offline frame→word attribution math added for word-level
/// timing (`KokoroAneManager.wordTimings` / `groupSegmentsIntoChunks`). These
/// exercise the token-index walk without loading any CoreML models.
final class KokoroAneWordTimingTests: XCTestCase {

    private typealias Segment = KokoroAneEnglishPhonemizer.PhonemeSegment

    /// Vocab over the characters used below; ids are arbitrary but non-zero
    /// (0 is BOS/EOS). Includes a space token by default.
    private func vocab(includeSpace: Bool = true) -> KokoroAneVocab {
        var map: [Character: Int32] = [:]
        var next: Int32 = 1
        for ch in "hɛlowɜɹd,!" {
            if map[ch] == nil {
                map[ch] = next
                next += 1
            }
        }
        if includeSpace { map[" "] = next }
        return KokoroAneVocab(map: map)
    }

    /// Two words, a space token between them, BOS/EOS framing. Frames are
    /// uniform per phoneme so the expected seconds are easy to hand-compute.
    func testTwoWordsWithSpaceToken() {
        // Tokens: BOS h ɛ l o ␣ w ɜ ɹ l d EOS
        //         1   10×4      2   10×5     1   → total 94
        let frames: [Int32] = [1, 10, 10, 10, 10, 2, 10, 10, 10, 10, 10, 1]
        let segments = [
            Segment(word: "hello", phonemes: "hɛlo"),
            Segment(word: "world", phonemes: "wɜɹld"),
        ]
        // durationSeconds chosen so secPerFrame == 0.01 (94 frames → 0.94 s).
        let timings = KokoroAneManager.wordTimings(
            segments: segments,
            perTokenFrames: frames,
            durationSeconds: 0.94,
            offsetSeconds: 0,
            vocab: vocab())

        XCTAssertEqual(timings.count, 2)
        XCTAssertEqual(timings[0].word, "hello")
        XCTAssertEqual(timings[0].startSec, 0.01, accuracy: 1e-9)  // after BOS frame
        XCTAssertEqual(timings[0].endSec, 0.41, accuracy: 1e-9)
        XCTAssertEqual(timings[1].word, "world")
        XCTAssertEqual(timings[1].startSec, 0.43, accuracy: 1e-9)  // after the space frame
        XCTAssertEqual(timings[1].endSec, 0.93, accuracy: 1e-9)
    }

    /// `offsetSeconds` (the audio already produced by earlier chunks) shifts
    /// every interval forward.
    func testChunkOffsetShiftsIntervals() {
        let frames: [Int32] = [1, 10, 10, 10, 10, 2, 10, 10, 10, 10, 10, 1]
        let segments = [
            Segment(word: "hello", phonemes: "hɛlo"),
            Segment(word: "world", phonemes: "wɜɹld"),
        ]
        let timings = KokoroAneManager.wordTimings(
            segments: segments,
            perTokenFrames: frames,
            durationSeconds: 0.94,
            offsetSeconds: 5.0,
            vocab: vocab())

        XCTAssertEqual(timings[0].startSec, 5.01, accuracy: 1e-9)
        XCTAssertEqual(timings[1].endSec, 5.93, accuracy: 1e-9)
    }

    /// When the vocab has no space token, `encode` emits no separator token, so
    /// the walk must not skip one — words stay contiguous.
    func testNoSpaceTokenKeepsWordsContiguous() {
        // Tokens: BOS h ɛ l o w ɜ ɹ l d EOS  (no space token)
        let frames: [Int32] = [1, 10, 10, 10, 10, 10, 10, 10, 10, 10, 1]
        let segments = [
            Segment(word: "hello", phonemes: "hɛlo"),
            Segment(word: "world", phonemes: "wɜɹld"),
        ]
        let timings = KokoroAneManager.wordTimings(
            segments: segments,
            perTokenFrames: frames,
            durationSeconds: 0.92,
            offsetSeconds: 0,
            vocab: vocab(includeSpace: false))

        XCTAssertEqual(timings.count, 2)
        XCTAssertEqual(timings[0].endSec, 0.41, accuracy: 1e-9)
        // No gap: world starts exactly where hello ended.
        XCTAssertEqual(timings[1].startSec, 0.41, accuracy: 1e-9)
    }

    /// A leading-punctuation segment (empty `word`) consumes its token but is
    /// not emitted as a highlightable word; the following real word's timing
    /// still accounts for those frames.
    func testLeadingPunctuationSegmentSkipped() {
        // Tokens: BOS , ␣ h ɛ l o EOS
        let frames: [Int32] = [1, 5, 2, 10, 10, 10, 10, 1]
        let segments = [
            Segment(word: "", phonemes: ","),
            Segment(word: "hello", phonemes: "hɛlo"),
        ]
        let timings = KokoroAneManager.wordTimings(
            segments: segments,
            perTokenFrames: frames,
            durationSeconds: 0.49,
            offsetSeconds: 0,
            vocab: vocab())

        XCTAssertEqual(timings.count, 1)
        XCTAssertEqual(timings[0].word, "hello")
        // BOS(1) + ','(5) + space(2) = 8 frames before "hello".
        XCTAssertEqual(timings[0].startSec, 0.08, accuracy: 1e-9)
        XCTAssertEqual(timings[0].endSec, 0.48, accuracy: 1e-9)
    }

    /// Trailing punctuation attached to a word's phonemes counts toward that
    /// word's span (its pause time is attributed to the word it follows).
    func testTrailingPunctuationCountsTowardWord() {
        // "hello!" → phonemes "hɛlo!"; tokens: BOS h ɛ l o ! EOS
        // Frames sum to 47, so durationSeconds 0.47 ⇒ secPerFrame 0.01.
        let frames: [Int32] = [1, 10, 10, 10, 10, 5, 1]
        let segments = [Segment(word: "hello", phonemes: "hɛlo!")]
        let timings = KokoroAneManager.wordTimings(
            segments: segments,
            perTokenFrames: frames,
            durationSeconds: 0.47,
            offsetSeconds: 0,
            vocab: vocab())

        XCTAssertEqual(timings.count, 1)
        XCTAssertEqual(timings[0].startSec, 0.01, accuracy: 1e-9)
        // Includes the '!' frames (40 + 5 = 45 frames after BOS).
        XCTAssertEqual(timings[0].endSec, 0.46, accuracy: 1e-9)
    }

    // MARK: - groupSegmentsIntoChunks

    func testGroupSegmentsSplitsAtWordBoundaryUnderCap() {
        let segments = [
            Segment(word: "a", phonemes: "aaaa"),   // 4
            Segment(word: "b", phonemes: "bbbb"),   // 4 (+1 space = 9)
            Segment(word: "c", phonemes: "cccc"),   // would push to 14
        ]
        // Cap 10: "aaaa bbbb" = 9 fits; adding " cccc" = 14 > 10 → new chunk.
        let chunks = KokoroAneManager.groupSegmentsIntoChunks(segments, maxLength: 10)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].map(\.word), ["a", "b"])
        XCTAssertEqual(chunks[1].map(\.word), ["c"])
    }

    func testGroupSegmentsSingleChunkWhenUnderCap() {
        let segments = [
            Segment(word: "a", phonemes: "aa"),
            Segment(word: "b", phonemes: "bb"),
        ]
        let chunks = KokoroAneManager.groupSegmentsIntoChunks(segments, maxLength: 510)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 2)
    }

    func testGroupSegmentsOversizeWordIsOwnChunk() {
        let segments = [
            Segment(word: "tiny", phonemes: "aa"),
            Segment(word: "huge", phonemes: String(repeating: "x", count: 20)),
        ]
        let chunks = KokoroAneManager.groupSegmentsIntoChunks(segments, maxLength: 10)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].map(\.word), ["tiny"])
        XCTAssertEqual(chunks[1].map(\.word), ["huge"])
    }
}
