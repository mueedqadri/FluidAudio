import Foundation

/// Per-stage wall-clock timings (milliseconds) for one synthesis call.
public struct KokoroAneStageTimings: Sendable, Equatable {
    public var albert: Double = 0
    public var postAlbert: Double = 0
    public var alignment: Double = 0
    public var prosody: Double = 0
    public var noise: Double = 0
    public var vocoder: Double = 0
    public var tail: Double = 0

    /// Sum of all stages, in milliseconds.
    public var totalMs: Double {
        albert + postAlbert + alignment + prosody + noise + vocoder + tail
    }

    public init() {}

    /// Accumulate another call's per-stage timings into this one — used when
    /// a long prompt is synthesized in several chunks (issue #712).
    mutating func add(_ other: KokoroAneStageTimings) {
        albert += other.albert
        postAlbert += other.postAlbert
        alignment += other.alignment
        prosody += other.prosody
        noise += other.noise
        vocoder += other.vocoder
        tail += other.tail
    }
}

/// Audio-time interval for one source word, derived from the duration model.
/// Surfaced only by the English text API (`synthesizeDetailed(text:)`), which
/// retains the per-word phoneme segmentation needed to attribute frames to the
/// surface word. `nil` `wordTimings` on a result means no per-word timing was
/// available (phoneme-only input, or a variant without word segmentation).
public struct KokoroAneWordTiming: Sendable, Equatable {
    /// The surface word (post-normalization) these frames were spoken from.
    public let word: String
    public let startSec: Double
    public let endSec: Double

    public init(word: String, startSec: Double, endSec: Double) {
        self.word = word
        self.startSec = startSec
        self.endSec = max(startSec, endSec)
    }
}

/// Detailed result of a `KokoroAneManager.synthesizeDetailed` call.
public struct KokoroAneSynthesisResult: Sendable {
    /// 24 kHz mono fp32 PCM samples (raw, not WAV-wrapped).
    public let samples: [Float]
    /// Sample rate (24,000 Hz for the laishere chain).
    public let sampleRate: Int
    /// `T_enc` — phoneme tokens including BOS/EOS.
    public let encoderTokens: Int
    /// `T_a` — acoustic frames produced by PostAlbert / Alignment.
    public let acousticFrames: Int
    /// Per-stage timings.
    public let timings: KokoroAneStageTimings
    /// Per-encoder-token acoustic frame counts (the duration model's `pred_dur`,
    /// 1:1 with the input ids incl. BOS/EOS). `prefix-sum × durationSeconds /
    /// acousticFrames` converts a token's frame span to audio seconds.
    /// Concatenated in order across chunks. Empty when not surfaced.
    public let perTokenFrames: [Int32]
    /// Per-source-word audio intervals, when the frontend retained word
    /// segmentation (English text API). `nil` otherwise.
    public let wordTimings: [KokoroAneWordTiming]?

    /// Convenience: audio duration in seconds.
    public var durationSeconds: Double {
        Double(samples.count) / Double(sampleRate)
    }

    public init(
        samples: [Float],
        sampleRate: Int,
        encoderTokens: Int,
        acousticFrames: Int,
        timings: KokoroAneStageTimings,
        perTokenFrames: [Int32] = [],
        wordTimings: [KokoroAneWordTiming]? = nil
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.encoderTokens = encoderTokens
        self.acousticFrames = acousticFrames
        self.timings = timings
        self.perTokenFrames = perTokenFrames
        self.wordTimings = wordTimings
    }
}

/// One of the 7 stages in the laishere chain.
public enum KokoroAneStage: String, CaseIterable, Sendable {
    case albert
    case postAlbert
    case alignment
    case prosody
    case noise
    case vocoder
    case tail

    /// `.mlmodelc` filename on disk and on HuggingFace.
    public var bundleName: String {
        switch self {
        case .albert: return "KokoroAlbert.mlmodelc"
        case .postAlbert: return "KokoroPostAlbert.mlmodelc"
        case .alignment: return "KokoroAlignment.mlmodelc"
        case .prosody: return "KokoroProsody.mlmodelc"
        case .noise: return "KokoroNoise_v2.mlmodelc"  // v2: atan2 phase-correction (HF-noise fix)
        case .vocoder: return "KokoroVocoder.mlmodelc"
        case .tail: return "KokoroTail.mlmodelc"
        }
    }
}
