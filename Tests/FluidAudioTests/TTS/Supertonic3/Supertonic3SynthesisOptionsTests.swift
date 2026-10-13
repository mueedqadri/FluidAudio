@preconcurrency import CoreML
import XCTest

@testable import FluidAudio

/// The synthesis switches: windowed vocoding must equal one whole call for a
/// causal vocoder, and the latent check must count a stuck start.
final class Supertonic3SynthesisOptionsTests: XCTestCase {

    /// A causal stand-in: each slot's samples mix that slot and the 19 before it,
    /// with the first slot replicated at the left edge, like the real vocoder.
    private func causalVocode(_ latent: [Float], channels: Int, length: Int, samplesPerSlot: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length * samplesPerSlot)
        for t in 0..<length {
            var acc: Float = 0
            for back in 0..<20 {
                let source = max(0, t - back)
                for c in 0..<channels { acc += latent[c * length + source] * Float(back + 1 + c) }
            }
            for k in 0..<samplesPerSlot { out[t * samplesPerSlot + k] = acc + Float(k) * 0.001 }
        }
        return out
    }

    private func latent(channels: Int, length: Int) -> [Float] {
        (0..<(channels * length)).map { Float(($0 * 7919) % 101) / 50 - 1 }
    }

    func testWindowedVocodeMatchesWholeForACausalVocoder() async throws {
        let channels = 3, length = 300, samplesPerSlot = 4
        let input = latent(channels: channels, length: length)
        let whole = causalVocode(input, channels: channels, length: length, samplesPerSlot: samplesPerSlot)
        let windowed = await Supertonic3LatentTools.windowedVocode(
            latent: input, channels: channels, length: length, windowSlots: 116,
            samplesPerSlot: samplesPerSlot
        ) { piece, pieceLength in
            self.causalVocode(piece, channels: channels, length: pieceLength, samplesPerSlot: samplesPerSlot)
        }
        XCTAssertEqual(windowed, whole)
    }

    func testWindowedVocodeWithoutEnoughContextDiffers() async throws {
        let channels = 3, length = 300, samplesPerSlot = 4
        let input = latent(channels: channels, length: length)
        let whole = causalVocode(input, channels: channels, length: length, samplesPerSlot: samplesPerSlot)
        let windowed = await Supertonic3LatentTools.windowedVocode(
            latent: input, channels: channels, length: length, windowSlots: 116,
            contextSlots: 4, samplesPerSlot: samplesPerSlot
        ) { piece, pieceLength in
            self.causalVocode(piece, channels: channels, length: pieceLength, samplesPerSlot: samplesPerSlot)
        }
        XCTAssertEqual(windowed.count, whole.count)
        XCTAssertNotEqual(windowed, whole)
    }

    func testLeadingRunCountsAStuckStart() {
        let channels = 2, length = 10
        var stuck = latent(channels: channels, length: length)
        for c in 0..<channels { for t in 0..<4 { stuck[c * length + t] = 0.5 } }
        XCTAssertEqual(
            Supertonic3LatentTools.leadingRun(in: stuck, channels: channels, length: length, zero: false), 4)
        XCTAssertEqual(
            Supertonic3LatentTools.leadingRun(in: stuck, channels: channels, length: length, zero: true), 0)

        var zeros = latent(channels: channels, length: length)
        for c in 0..<channels { for t in 0..<3 { zeros[c * length + t] = 0 } }
        XCTAssertEqual(
            Supertonic3LatentTools.leadingRun(in: zeros, channels: channels, length: length, zero: true), 3)

        let healthy = latent(channels: channels, length: length)
        XCTAssertEqual(
            Supertonic3LatentTools.leadingRun(in: healthy, channels: channels, length: length, zero: false), 0)
    }

    func testSlackArrayHoldsTheValuesAndReadsAsContiguous() throws {
        let values: [Float] = (0..<24).map(Float.init)
        let array = try Supertonic3MultiArray.makeWithSlack(
            values, shape: [1, 4, 6], dataType: .float32, tailSlackBytes: 16_384)
        XCTAssertEqual(array.shape, [1, 4, 6])
        XCTAssertEqual(Supertonic3MultiArray.extractFloats(array), values)
    }

    func testFp32ComputeVariantNamesItsOwnFile() {
        XCTAssertEqual(Supertonic3VectorEstimator.fp32Compute.precisionSuffix, "fp32")
        XCTAssertEqual(Supertonic3VectorEstimator.fp32Compute.downloadVariant, "dyn-fp32")
        XCTAssertTrue(
            ModelNames.Supertonic3.requiredFiles(veVariant: "dyn-fp32")
                .contains("VectorEstimatorVariants/VectorEstimator_fp32.mlmodelc"))
    }
}
