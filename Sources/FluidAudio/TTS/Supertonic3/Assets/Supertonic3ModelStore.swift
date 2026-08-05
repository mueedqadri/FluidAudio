@preconcurrency import CoreML
import Foundation

/// Actor-based store for the four Supertonic-3 CoreML models plus the two
/// companion config files (`tts.json`, `unicode_indexer.json`).
///
/// The four stages are:
///   1. `text_encoder`        — text IDs + style → text embedding
///   2. `duration_predictor`  — text IDs + style → per-utterance duration
///   3. `vector_estimator`    — denoising loop input (called N times)
///   4. `vocoder`             — final latent → 44.1 kHz waveform
///
/// All four are intentionally loaded with `.cpuAndNeuralEngine` by default —
/// the converted graphs are FP16 and small enough to fit in ANE working
/// memory. Callers can override at init time (`.cpuOnly` is recommended for
/// Intel Macs and for the smoke tests).
public actor Supertonic3ModelStore {

    private let logger = AppLogger(category: "Supertonic3ModelStore")

    private let directory: URL?
    private let computeUnits: MLComputeUnits
    private let veOption: Supertonic3VectorEstimator

    private var repoDirectory: URL?
    private var textEncoderModel: MLModel?
    private var durationPredictorModel: MLModel?
    private var vocoderModel: MLModel?

    /// Single VectorEstimator for the non-bucketed (`.fp16Dynamic` / `.dynamic`)
    /// modes. `nil` in bucketed mode, where models are loaded lazily per bucket.
    private var vectorEstimatorModel: MLModel?
    /// Lazily-loaded fixed-length VectorEstimators keyed by latent bucket length
    /// (used only in `.aneBucketed` mode).
    private var bucketModels: [Int: MLModel] = [:]

    /// Tier-2 (long-sentence) stages, all `.cpuOnly`, all loaded on first use.
    /// The wide text stages are cached per text bucket — one CoreML function of
    /// one multi-function bundle each; the dynamic VectorEstimator is a single
    /// model that takes the exact latent length. See
    /// `Supertonic3Constants.wideTextBuckets` for why this tier exists and why
    /// it is CPU-pinned.
    private var wideTextEncoders: [Int: MLModel] = [:]
    private var wideDurationPredictors: [Int: MLModel] = [:]
    private var dynamicVectorEstimatorModel: MLModel?

    private(set) var config: Supertonic3Config = .defaults

    public init(
        directory: URL? = nil,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        vectorEstimator: Supertonic3VectorEstimator = .default
    ) {
        self.directory = directory
        self.computeUnits = computeUnits
        self.veOption = vectorEstimator
    }

    /// Compute units the VectorEstimator stage should use. Dynamic-shape builds
    /// cannot use the ANE (CoreML rejects data-dependent shapes), so they are
    /// pinned to CPU/GPU; bucketed builds target the ANE.
    ///
    /// Tier 2 deliberately does **not** come through here even though it runs a
    /// dynamic VectorEstimator: the `.dynamic → .cpuAndGPU` mapping below would
    /// cost iOS background synthesis. It pins `.cpuOnly` instead — see
    /// `loadTier2Model(repoDir:fileName:functionName:)`.
    private var veComputeUnits: MLComputeUnits {
        // An explicit .cpuOnly request always wins (it already excludes the ANE,
        // so no override is needed). Otherwise dynamic shapes avoid the ANE
        // (Core ML rejects them) and bucketed builds target it.
        if computeUnits == .cpuOnly { return .cpuOnly }
        switch veOption {
        case .fp16Dynamic: return computeUnits  // preserve historical behavior
        case .dynamic: return .cpuAndGPU
        case .aneBucketed: return .cpuAndNeuralEngine
        }
    }

    // MARK: - Public API

    /// Download (if missing) the four `.mlmodelc` bundles + `tts.json` +
    /// `unicode_indexer.json` and load the CoreML stages.
    public func loadIfNeeded() async throws {
        if textEncoderModel != nil { return }

        let repoDir = try await Supertonic3ResourceDownloader.ensureModels(
            directory: directory, veVariant: veOption.downloadVariant)
        self.repoDirectory = repoDir

        // tts.json — optional override of the compile-time defaults. If parsing
        // fails we keep the defaults and warn so callers can debug.
        let configURL = repoDir.appendingPathComponent(ModelNames.Supertonic3.configFile)
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                let data = try Data(contentsOf: configURL)
                self.config = try JSONDecoder().decode(Supertonic3Config.self, from: data)
            } catch {
                logger.warning(
                    "Failed to decode tts.json (\(error)); using compile-time defaults")
            }
        }

        logger.info("Loading Supertonic-3 CoreML models from \(repoDir.path)…")
        let loadStart = Date()

        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits

        // The two text stages are pinned off the ANE, the same treatment
        // Kokoro's PostAlbert gets. Their relative-position attention compiles
        // into many small ANE islands interleaved with BNNS segments (visible
        // in the kernel dump as successive *_bnns → ANE handoffs), and
        // on-device those are exactly the programs whose ANE requests a
        // backgrounded app gets refused (kIOReturnNotPermitted) — while the
        // single-block ANE programs in the same process (both vocoders,
        // Kokoro's stages) keep running. Each runs once per chunk, so the CPU
        // cost is small; the VectorEstimator and vocoder stay on the ANE.
        let textStageCfg = MLModelConfiguration()
        textStageCfg.computeUnits =
            computeUnits == .cpuAndNeuralEngine ? .cpuOnly : computeUnits
        textEncoderModel = try loadModel(
            repoDir: repoDir,
            fileName: ModelNames.Supertonic3.textEncoderFile, config: textStageCfg)
        durationPredictorModel = try loadModel(
            repoDir: repoDir,
            fileName: ModelNames.Supertonic3.durationPredictorFile, config: textStageCfg)
        vocoderModel = try loadModel(
            repoDir: repoDir,
            fileName: ModelNames.Supertonic3.vocoderFile, config: cfg)

        // VectorEstimator: dynamic builds load eagerly; bucketed builds load
        // each fixed-length model lazily on first use (see vectorEstimator(forLatentLength:)).
        if !veOption.isBucketed {
            let veCfg = MLModelConfiguration()
            veCfg.computeUnits = veComputeUnits
            vectorEstimatorModel = try loadModel(
                repoDir: repoDir,
                fileName: ModelNames.Supertonic3.vectorEstimatorFile(
                    precisionSuffix: veOption.precisionSuffix, bucket: nil),
                config: veCfg)
        }

        let elapsed = Date().timeIntervalSince(loadStart)
        logger.info(
            "Supertonic-3 models loaded in \(String(format: "%.2f", elapsed))s")
    }

    // MARK: - Accessors

    public func textEncoder() throws -> MLModel { try unwrap(textEncoderModel, name: "text_encoder") }
    public func durationPredictor() throws -> MLModel {
        try unwrap(durationPredictorModel, name: "duration_predictor")
    }
    /// Resolve the VectorEstimator for a chunk of `latentLength` TTL slots.
    ///
    /// Returns the model plus the latent length the caller must feed it: in
    /// dynamic modes that equals `latentLength` (no padding); in bucketed mode
    /// it is the smallest published bucket ≥ `latentLength`, and the caller pads
    /// the latent/mask up to that length. Bucket models are loaded lazily and
    /// cached.
    public func vectorEstimator(forLatentLength latentLength: Int) throws -> (model: MLModel, paddedLength: Int) {
        guard veOption.isBucketed else {
            return (try unwrap(vectorEstimatorModel, name: "vector_estimator"), latentLength)
        }
        guard let bucket = ModelNames.Supertonic3.aneBuckets.first(where: { $0 >= latentLength })
        else {
            throw Supertonic3Error.inferenceFailed(
                stage: "vector_estimator",
                underlying:
                    "latent length \(latentLength) exceeds largest ANE bucket "
                    + "\(ModelNames.Supertonic3.aneBuckets.last ?? 0); use a dynamic VectorEstimator")
        }
        if let cached = bucketModels[bucket] { return (cached, bucket) }

        guard let repoDir = repoDirectory else { throw Supertonic3Error.notInitialized }
        let veCfg = MLModelConfiguration()
        veCfg.computeUnits = veComputeUnits
        let model = try loadModel(
            repoDir: repoDir,
            fileName: ModelNames.Supertonic3.vectorEstimatorFile(
                precisionSuffix: veOption.precisionSuffix, bucket: bucket),
            config: veCfg)
        bucketModels[bucket] = model
        return (model, bucket)
    }
    public func vocoder() throws -> MLModel { try unwrap(vocoderModel, name: "vocoder") }

    // MARK: - Tier 2 (long sentences, CPU-pinned)

    /// The wide text stages that hold `tokenLength` tokens whole, loaded on
    /// first use, plus the text length the caller must pad `text_ids` and
    /// `text_mask` to.
    ///
    /// Throws `.tierUnavailable` — never a hard failure — whenever the tier
    /// cannot serve the request: assets not installed, bundle unreadable,
    /// `tokenLength` past `Supertonic3Constants.tierCeiling`, or a CoreML
    /// runtime older than macOS 15 / iOS 18. One `catch` at the call site
    /// therefore covers every reason to fall back to tier-1 chunking.
    ///
    /// The vocoder and the voice styles are shared with tier 1 — only the two
    /// text stages and the VectorEstimator differ.
    public func wideTextStages(
        forTokenLength tokenLength: Int
    ) throws -> (textEncoder: MLModel, durationPredictor: MLModel, paddedT: Int) {
        guard let bucket = Supertonic3Constants.wideTextBucket(forTokenLength: tokenLength) else {
            throw Supertonic3Error.tierUnavailable(
                reason: "\(tokenLength) tokens exceeds the tier ceiling of "
                    + "\(Supertonic3Constants.tierCeiling); clause-split first")
        }
        if let encoder = wideTextEncoders[bucket], let predictor = wideDurationPredictors[bucket] {
            return (encoder, predictor, bucket)
        }
        guard let repoDir = repoDirectory else { throw Supertonic3Error.notInitialized }

        let encoder = try Self.loadTier2Model(
            repoDir: repoDir,
            fileName: ModelNames.Supertonic3.textEncoderWideFile,
            functionName: ModelNames.Supertonic3.textEncoderFunction(bucket: bucket))
        let predictor = try Self.loadTier2Model(
            repoDir: repoDir,
            fileName: ModelNames.Supertonic3.durationPredictorWideFile,
            functionName: ModelNames.Supertonic3.durationPredictorFunction(bucket: bucket))

        wideTextEncoders[bucket] = encoder
        wideDurationPredictors[bucket] = predictor
        logger.info("Loaded wide text stages at T\(bucket) (.cpuOnly)")
        return (encoder, predictor, bucket)
    }

    /// The dynamic int8 VectorEstimator, `.cpuOnly`, loaded on first use.
    ///
    /// int8 is not a tuning choice: the palettization ladder comes apart as
    /// chunks grow — int4 breaks at a 110-character cap, 6-bit at 300 — while
    /// int8 stays clean at every cap measured. Tier 2 exists to make chunks
    /// longer, so it takes the one precision that survives them.
    ///
    /// Same `.tierUnavailable` contract as `wideTextStages(forTokenLength:)`.
    public func dynamicVectorEstimator() throws -> MLModel {
        if let cached = dynamicVectorEstimatorModel { return cached }
        guard let repoDir = repoDirectory else { throw Supertonic3Error.notInitialized }

        let model = try Self.loadTier2Model(
            repoDir: repoDir,
            fileName: ModelNames.Supertonic3.vectorEstimatorFile(
                precisionSuffix: Supertonic3Quantization.int8.rawValue, bucket: nil),
            functionName: nil)
        dynamicVectorEstimatorModel = model
        logger.info("Loaded dynamic int8 VectorEstimator (.cpuOnly)")
        return model
    }

    /// Whether both wide text stages are installed under `repoDir`. A cheap
    /// filesystem check, so a caller can learn the tier is absent without
    /// paying a CoreML load to find out.
    public static func hasWideTextStages(in repoDir: URL) -> Bool {
        ModelNames.Supertonic3.wideTextStageFiles.allSatisfy { file in
            FileManager.default.fileExists(atPath: repoDir.appendingPathComponent(file).path)
        }
    }

    /// Whether tier 2 can serve this session at all: both wide text stages
    /// **and** the dynamic VectorEstimator installed, on a runtime new enough
    /// for multi-function models.
    ///
    /// Asked once before chunking, so an installation without the tier chunks
    /// exactly as it did before rather than producing long chunks nothing can
    /// synthesize. The per-chunk `.tierUnavailable` path remains the net for a
    /// bundle that is present but unloadable.
    public func isWideTierAvailable() -> Bool {
        guard #available(macOS 15.0, iOS 18.0, *) else { return false }
        guard let repoDir = repoDirectory else { return false }
        let dynamicVE = ModelNames.Supertonic3.vectorEstimatorFile(
            precisionSuffix: Supertonic3Quantization.int8.rawValue, bucket: nil)
        return Self.hasWideTextStages(in: repoDir)
            && FileManager.default.fileExists(
                atPath: repoDir.appendingPathComponent(dynamicVE).path)
    }

    public func repoDir() throws -> URL {
        guard let dir = repoDirectory else { throw Supertonic3Error.notInitialized }
        return dir
    }

    /// Path to `unicode_indexer.json` after `loadIfNeeded()` has succeeded.
    public func unicodeIndexerURL() throws -> URL {
        try repoDir().appendingPathComponent(ModelNames.Supertonic3.unicodeIndexerFile)
    }

    public func unload() {
        textEncoderModel = nil
        durationPredictorModel = nil
        vectorEstimatorModel = nil
        bucketModels.removeAll()
        vocoderModel = nil
        wideTextEncoders.removeAll()
        wideDurationPredictors.removeAll()
        dynamicVectorEstimatorModel = nil
    }

    // MARK: - Helpers

    private func unwrap(_ model: MLModel?, name: String) throws -> MLModel {
        guard let model else { throw Supertonic3Error.notInitialized }
        return model
    }

    /// Load one optional tier-2 bundle from `repoDir`, pinned `.cpuOnly`.
    ///
    /// Every failure becomes `.tierUnavailable`, including a bundle that is
    /// present but unreadable: an optional tier that degrades to tier-1
    /// behavior is correct, and one that fails synthesis outright is not, so
    /// "installed but broken" is treated the same as "not installed".
    ///
    /// `static` and repo-directory-parameterized so the absence path is
    /// testable without a populated cache.
    static func loadTier2Model(
        repoDir: URL, fileName: String, functionName: String?
    ) throws -> MLModel {
        let cfg = MLModelConfiguration()
        // Explicitly .cpuOnly on both platforms, and deliberately not through
        // `veComputeUnits`: its `.dynamic → .cpuAndGPU` mapping would silently
        // cost iOS background synthesis.
        cfg.computeUnits = .cpuOnly

        if let functionName {
            // The wide stages are multi-function bundles, which need the
            // macOS 15 / iOS 18 CoreML runtime. The package still targets
            // macOS 14, so this is a runtime gate; MacReader's own deployment
            // targets are 26 and never see it.
            guard #available(macOS 15.0, iOS 18.0, *) else {
                throw Supertonic3Error.tierUnavailable(
                    reason: "multi-function CoreML models require macOS 15+/iOS 18+")
            }
            cfg.functionName = functionName
        }

        let modelURL = repoDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw Supertonic3Error.tierUnavailable(reason: "\(fileName) is not installed")
        }
        do {
            let model = try MLModel(contentsOf: modelURL, configuration: cfg)
            ComputePlanLogger.logPlacement(
                modelURL: modelURL, configuration: cfg,
                label: fileName + (functionName.map { " [\($0)]" } ?? ""))
            return model
        } catch {
            let function = functionName.map { " [\($0)]" } ?? ""
            throw Supertonic3Error.tierUnavailable(
                reason: "\(fileName)\(function) failed to load: \(error)")
        }
    }

    private func loadModel(
        repoDir: URL, fileName: String, config: MLModelConfiguration
    ) throws -> MLModel {
        let modelURL = repoDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw Supertonic3Error.modelFileNotFound(fileName)
        }
        do {
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            logger.info("Loaded \(fileName)")
            ComputePlanLogger.logPlacement(
                modelURL: modelURL, configuration: config, label: fileName)
            return model
        } catch {
            throw Supertonic3Error.corruptedModel(fileName, underlying: "\(error)")
        }
    }
}
