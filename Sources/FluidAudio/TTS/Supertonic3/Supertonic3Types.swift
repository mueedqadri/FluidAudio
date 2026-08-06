import Foundation

/// On-disk schema of the upstream `tts.json` config.
///
/// The reference Swift CLI only consumes two scalars from each section
/// (`sample_rate`, `base_chunk_size`, `chunk_compress_factor`, `latent_dim`).
/// The Swift port duplicates those fields here so a downloaded `tts.json`
/// can override the compile-time defaults in `Supertonic3Constants` when
/// FluidInference republishes a tuned variant.
public struct Supertonic3Config: Codable, Sendable {

    public struct AEConfig: Codable, Sendable {
        public let sampleRate: Int
        public let baseChunkSize: Int

        public init(sampleRate: Int, baseChunkSize: Int) {
            self.sampleRate = sampleRate
            self.baseChunkSize = baseChunkSize
        }

        private enum CodingKeys: String, CodingKey {
            case sampleRate = "sample_rate"
            case baseChunkSize = "base_chunk_size"
        }
    }

    public struct TTLConfig: Codable, Sendable {
        public let chunkCompressFactor: Int
        public let latentDim: Int

        public init(chunkCompressFactor: Int, latentDim: Int) {
            self.chunkCompressFactor = chunkCompressFactor
            self.latentDim = latentDim
        }

        private enum CodingKeys: String, CodingKey {
            case chunkCompressFactor = "chunk_compress_factor"
            case latentDim = "latent_dim"
        }
    }

    public let ae: AEConfig
    public let ttl: TTLConfig

    public init(ae: AEConfig, ttl: TTLConfig) {
        self.ae = ae
        self.ttl = ttl
    }

    /// Fallback config that matches `Supertonic3Constants` — used when the
    /// caller cannot supply a `tts.json` (e.g. embedded resource scenarios).
    public static let defaults = Supertonic3Config(
        ae: .init(
            sampleRate: Supertonic3Constants.sampleRate,
            baseChunkSize: Supertonic3Constants.baseChunkSize),
        ttl: .init(
            chunkCompressFactor: Supertonic3Constants.chunkCompressFactor,
            latentDim: Supertonic3Constants.latentDim))
}

/// Weight-quantization level for the VectorEstimator stage. All three are
/// post-training, weight-only compressions that leave placement and speed
/// unchanged — they only shrink the on-disk / in-memory model:
///   - `.int8` — linear per-channel symmetric int8 (≈64 MB, transparent).
///   - `.int6` — 6-bit k-means palettization (≈48 MB, very good).
///   - `.int4` — 4-bit k-means palettization (≈32 MB, perceptually clean).
public enum Supertonic3Quantization: String, Sendable, Equatable, CaseIterable {
    case int8
    case int6
    case int4
}

/// Selects which VectorEstimator build the pipeline downloads and runs.
///
/// VectorEstimator is the heaviest stage (run `totalSteps`× per utterance).
/// Every build here is a RangeDim model fed the exact latent length, run
/// `.cpuOnly`; the cases differ only in weight precision, i.e. download size:
///
/// - `.dynamic(q)` — weight-quantized RangeDim model, 64 MB at int8.
/// - `.fp16Dynamic` — the original FP16 model, 128 MB. Reach for it to check
///   whether quantization is implicated in a defect, not to ship.
///
/// Fixed-length ANE-bucketed builds are gone. They were ~2.7× faster and it
/// did not matter: 4-bit palettization comes apart as chunks grow (macro WER
/// 0.88% → 7.63% between a 70- and a 110-character cap, where int8 holds
/// 0.24% at both), the fixed shapes froze the text axis at 128 tokens, and
/// iOS refuses those programs to a backgrounded app. The exact-latent CPU
/// chain measures 10–37× realtime against the 1× playback needs.
public enum Supertonic3VectorEstimator: Sendable, Equatable {
    case fp16Dynamic
    case dynamic(Supertonic3Quantization)

    /// Default: dynamic int8 — the precision the fp32 quality ceiling was
    /// measured against, at half the FP16 download.
    public static let `default`: Supertonic3VectorEstimator = .dynamic(.int8)

    /// `nil` for FP16; the rawValue (`"int8"`/`"int6"`/`"int4"`) otherwise.
    var precisionSuffix: String? {
        switch self {
        case .fp16Dynamic: return nil
        case .dynamic(let q): return q.rawValue
        }
    }

    /// Variant token passed to `DownloadUtils.downloadRepo` / `getRequiredModelNames`
    /// so only the selected VectorEstimator file is fetched.
    var downloadVariant: String? {
        switch self {
        case .fp16Dynamic: return nil
        case .dynamic(let q): return "dyn-\(q.rawValue)"
        }
    }
}

/// The 10 built-in Supertonic-3 voice styles published at
/// `FluidInference/supertonic-3-coreml/voice_styles/`: female `f1`-`f5`,
/// male `m1`-`m5`. Fetch one with
/// `Supertonic3ResourceDownloader.downloadVoiceStyle(_:)` (or download + decode
/// in one call via `loadVoiceStyle(_:)`). Custom styles can still be supplied
/// as any file via `Supertonic3VoiceStyle.load(from:)`.
public enum Supertonic3Voice: String, CaseIterable, Sendable {
    case f1 = "F1"
    case f2 = "F2"
    case f3 = "F3"
    case f4 = "F4"
    case f5 = "F5"
    case m1 = "M1"
    case m2 = "M2"
    case m3 = "M3"
    case m4 = "M4"
    case m5 = "M5"

    /// Default voice (`M1`), the style shipped before the others were added.
    public static let `default`: Supertonic3Voice = .m1

    /// Repo-relative path of this voice's style JSON
    /// (e.g. `voice_styles/F3.json`).
    public var fileName: String { "voice_styles/\(rawValue).json" }

    /// Parse a voice name case-insensitively, e.g. `"f3"` or `"M1"`.
    /// Returns `nil` for unknown names.
    public init?(name: String) {
        self.init(rawValue: name.uppercased())
    }
}

/// On-disk schema of a Supertonic-3 voice style JSON file (the `M1` /
/// `F1` / etc. presets shipped under `assets/voice_styles/` in the
/// reference repo).
///
/// `style_ttl` feeds the text encoder + vector estimator; `style_dp` feeds
/// the duration predictor. Both components encode the same 3-D tensor
/// `[1, D1, D2]` as a nested array; `dims` records the original shape so
/// the loader can validate against the model's expected input shape.
public struct Supertonic3VoiceStyleData: Codable, Sendable {

    public struct Component: Codable, Sendable {
        public let data: [[[Float]]]
        public let dims: [Int]
        public let type: String

        public init(data: [[[Float]]], dims: [Int], type: String) {
            self.data = data
            self.dims = dims
            self.type = type
        }
    }

    public let styleTtl: Component
    public let styleDp: Component

    public init(styleTtl: Component, styleDp: Component) {
        self.styleTtl = styleTtl
        self.styleDp = styleDp
    }

    private enum CodingKeys: String, CodingKey {
        case styleTtl = "style_ttl"
        case styleDp = "style_dp"
    }
}

/// Decoded voice style ready to bind into CoreML feature dictionaries.
///
/// Both tensors are flattened row-major matching the dims `[bsz, D1, D2]`
/// stored on disk. The synthesizer wraps these into `MLMultiArray` instances
/// at call time so the same `Supertonic3VoiceStyle` can be shared across
/// many synthesis calls without re-parsing the JSON.
public struct Supertonic3VoiceStyle: Sendable {
    public let name: String
    public let ttlValues: [Float]
    public let ttlDims: [Int]
    public let dpValues: [Float]
    public let dpDims: [Int]

    public init(
        name: String,
        ttlValues: [Float],
        ttlDims: [Int],
        dpValues: [Float],
        dpDims: [Int]
    ) {
        self.name = name
        self.ttlValues = ttlValues
        self.ttlDims = ttlDims
        self.dpValues = dpValues
        self.dpDims = dpDims
    }

    /// Decode a JSON-encoded voice style file into the flattened
    /// representation expected by the synthesizer.
    public static func load(from url: URL) throws -> Supertonic3VoiceStyle {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Supertonic3Error.voiceStyleLoadFailed(
                path: url.path, underlying: "\(error)")
        }
        let decoded: Supertonic3VoiceStyleData
        do {
            decoded = try JSONDecoder().decode(Supertonic3VoiceStyleData.self, from: data)
        } catch {
            throw Supertonic3Error.voiceStyleLoadFailed(
                path: url.path, underlying: "decode: \(error)")
        }

        let expectedTtl = [1, Supertonic3Constants.ttlStyleTokens, Supertonic3Constants.ttlStyleDim]
        if decoded.styleTtl.dims != expectedTtl {
            throw Supertonic3Error.voiceStyleShapeMismatch(
                component: "style_ttl", expected: expectedTtl, got: decoded.styleTtl.dims)
        }
        let expectedDp = [1, Supertonic3Constants.dpStyleTokens, Supertonic3Constants.dpStyleDim]
        if decoded.styleDp.dims != expectedDp {
            throw Supertonic3Error.voiceStyleShapeMismatch(
                component: "style_dp", expected: expectedDp, got: decoded.styleDp.dims)
        }

        let ttlFlat = flatten(decoded.styleTtl.data, dims: decoded.styleTtl.dims)
        let dpFlat = flatten(decoded.styleDp.data, dims: decoded.styleDp.dims)

        return Supertonic3VoiceStyle(
            name: url.deletingPathExtension().lastPathComponent,
            ttlValues: ttlFlat,
            ttlDims: decoded.styleTtl.dims,
            dpValues: dpFlat,
            dpDims: decoded.styleDp.dims)
    }

    private static func flatten(_ data: [[[Float]]], dims: [Int]) -> [Float] {
        var out: [Float] = []
        let totalCount = dims.reduce(1, *)
        out.reserveCapacity(totalCount)
        for plane in data {
            for row in plane {
                out.append(contentsOf: row)
            }
        }
        return out
    }
}
