import Foundation

/// Per-call switches for `Supertonic3Manager.synthesize`. The defaults are the
/// production path; each switch exists to test a way around a device fault.
public struct Supertonic3SynthesisOptions: Sendable {
    /// Longest latent the VectorEstimator is asked for. A chunk predicted
    /// longer is re-split at clause breaks into pieces that fit.
    public var maximumLatentSlots: Int?

    /// Run the vocoder over windows of at most this many latent slots, left
    /// context included. The vocoder is causal, so the result is the same as
    /// one whole call.
    public var vocoderWindowSlots: Int?

    /// Zeroed bytes allocated past the end of every input array.
    public var inputTailSlackBytes: Int

    /// Called once per synthesized piece with what the VectorEstimator made.
    public var latentReport: (@Sendable (Supertonic3LatentReport) -> Void)?

    public init(
        maximumLatentSlots: Int? = nil,
        vocoderWindowSlots: Int? = nil,
        inputTailSlackBytes: Int = 0,
        latentReport: (@Sendable (Supertonic3LatentReport) -> Void)? = nil
    ) {
        self.maximumLatentSlots = maximumLatentSlots
        self.vocoderWindowSlots = vocoderWindowSlots
        self.inputTailSlackBytes = inputTailSlackBytes
        self.latentReport = latentReport
    }

    public static let standard = Supertonic3SynthesisOptions()
}

/// What the VectorEstimator produced for one piece: whether its latent starts
/// with a run of identical or all-zero slots, after each denoising step.
public struct Supertonic3LatentReport: Sendable, Equatable {
    public let latentSlots: Int
    public let textTokens: Int
    public let textBucket: Int
    /// Leading run of slots identical to slot 0, after the last step.
    public let leadingConstantSlots: Int
    /// Leading run of slots whose every value is (near) zero, after the last step.
    public let leadingZeroSlots: Int
    /// `leadingConstantSlots` after each denoising step.
    public let leadingConstantSlotsPerStep: [Int]
}

/// Pure helpers behind the synthesis switches, kept free of CoreML so they can
/// be tested with a stand-in model.
public enum Supertonic3LatentTools {
    /// Left context a vocoder window needs: the vocoder sees 116 frames back,
    /// 19.3 slots at 6 frames per slot.
    public static let vocoderContextSlots = 24

    /// Leading run of slots that match slot 0 (`zero == false`) or are all
    /// near zero (`zero == true`), in a channel-major `[channels, length]` latent.
    public static func leadingRun(
        in latent: [Float], channels: Int, length: Int, zero: Bool, tolerance: Float = 1e-4
    ) -> Int {
        guard length > 0, latent.count >= channels * length else { return 0 }
        var run = 0
        for t in 0..<length {
            var matches = true
            for c in 0..<channels {
                let value = latent[c * length + t]
                let reference: Float = zero ? 0 : latent[c * length]
                if abs(value - reference) > tolerance {
                    matches = false
                    break
                }
            }
            guard matches else { break }
            run += 1
        }
        return zero || run > 1 ? run : 0
    }

    /// Vocode a channel-major `[channels, length]` latent in windows of at most
    /// `windowSlots` slots, each carrying `contextSlots` of left context whose
    /// output is dropped. Exact for a causal vocoder whose receptive field fits
    /// in the context.
    public static func windowedVocode(
        latent: [Float],
        channels: Int,
        length: Int,
        windowSlots: Int,
        contextSlots: Int = vocoderContextSlots,
        samplesPerSlot: Int,
        vocode: (_ window: [Float], _ windowLength: Int) async throws -> [Float]
    ) async rethrows -> [Float] {
        let step = max(1, windowSlots - contextSlots)
        var output: [Float] = []
        output.reserveCapacity(length * samplesPerSlot)
        var start = 0
        while start < length {
            let end = min(length, start + step)
            let from = max(0, start - contextSlots)
            let windowLength = end - from
            var window = [Float](repeating: 0, count: channels * windowLength)
            for c in 0..<channels {
                let src = c * length + from
                let dst = c * windowLength
                for t in 0..<windowLength { window[dst + t] = latent[src + t] }
            }
            let samples = try await vocode(window, windowLength)
            let drop = (start - from) * samplesPerSlot
            if samples.count > drop {
                output.append(contentsOf: samples[drop..<min(samples.count, windowLength * samplesPerSlot)])
            }
            start = end
        }
        return output
    }
}
