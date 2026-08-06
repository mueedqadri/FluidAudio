@preconcurrency import CoreML
import Foundation

/// Actor-based store for the Supertonic-3 CoreML models plus the two companion
/// config files (`tts.json`, `unicode_indexer.json`).
///
/// The four stages are:
///   1. `text_encoder`        — text IDs + style → text embedding
///   2. `duration_predictor`  — text IDs + style → per-utterance duration
///   3. `vector_estimator`    — denoising loop input (called N times)
///   4. `vocoder`             — final latent → 44.1 kHz waveform
///
/// **Placement is not a tuning knob here.** The text stages and the
/// VectorEstimator are pinned `.cpuOnly` on both platforms; only the vocoder
/// takes the caller's `computeUnits` (`.cpuAndNeuralEngine` by default). Two
/// independent findings put them there:
///
/// - *Fixed shapes froze the text axis.* An ANE export has to pin every axis,
///   which capped a sentence at 128 tokens and split 34.9% of them mid-clause.
///   The text stages that hold a sentence whole are multi-function CPU
///   bundles, and the VectorEstimator that takes an exact latent is a RangeDim
///   model CoreML will not put on the ANE at all.
/// - *iOS refuses the ANE to a backgrounded app, per program.* Field-verified
///   on device (iPhone 13 Pro, A15): the kernel returns kIOReturnNotPermitted
///   for the text stages' many-island BNNS↔ANE programs and for the bucketed
///   VectorEstimator — at foreground QoS, with an ios17-retargeted
///   bit-identical model, minutes or seconds after backgrounding alike — while
///   single-block ANE programs (the vocoder, Kokoro's stages) keep running in
///   the same process.
///
/// So CPU placement is the one configuration that cannot be refused, and it
/// costs nothing that matters: the all-CPU chain measured 10–37× realtime on
/// an A15 and 43× on M-series, against the 1× playback needs.
public actor Supertonic3ModelStore {

    private let logger = AppLogger(category: "Supertonic3ModelStore")

    private let directory: URL?
    private let computeUnits: MLComputeUnits
    private let veOption: Supertonic3VectorEstimator

    private var repoDirectory: URL?
    private var vocoderModel: MLModel?

    /// Text stages cached per text bucket — one CoreML function of one
    /// multi-function bundle each — and the single RangeDim VectorEstimator.
    /// All `.cpuOnly`, all loaded on first use.
    private var textEncoders: [Int: MLModel] = [:]
    private var durationPredictors: [Int: MLModel] = [:]
    private var vectorEstimatorModel: MLModel?

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

    // MARK: - Public API

    /// Download (if missing) the CoreML bundles + `tts.json` +
    /// `unicode_indexer.json`, then load the vocoder.
    ///
    /// Only the vocoder loads eagerly: it is shared by every chunk and is the
    /// one stage whose placement depends on the caller. The text stages are
    /// per-bucket and the VectorEstimator is 64 MB, so both wait for a chunk
    /// that actually needs them.
    public func loadIfNeeded() async throws {
        if vocoderModel != nil { return }

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
        vocoderModel = try loadModel(
            repoDir: repoDir,
            fileName: ModelNames.Supertonic3.vocoderFile, config: cfg)

        let elapsed = Date().timeIntervalSince(loadStart)
        logger.info(
            "Supertonic-3 vocoder loaded in \(String(format: "%.2f", elapsed))s")
    }

    // MARK: - Accessors

    public func vocoder() throws -> MLModel {
        guard let vocoderModel else { throw Supertonic3Error.notInitialized }
        return vocoderModel
    }

    /// The text stages that hold `tokenLength` tokens whole, loaded on first
    /// use, plus the text length the caller must pad `text_ids` and `text_mask`
    /// to.
    ///
    /// Throws `.tierUnavailable` when `tokenLength` is past
    /// `Supertonic3Constants.tierCeiling` — the chunker splits before that, so
    /// it is the caller's cue to re-split rather than a failure.
    public func textStages(
        forTokenLength tokenLength: Int
    ) throws -> (textEncoder: MLModel, durationPredictor: MLModel, paddedT: Int) {
        guard let bucket = Supertonic3Constants.wideTextBucket(forTokenLength: tokenLength) else {
            throw Supertonic3Error.tierUnavailable(
                reason: "\(tokenLength) tokens exceeds the ceiling of "
                    + "\(Supertonic3Constants.tierCeiling); clause-split first")
        }
        if let encoder = textEncoders[bucket], let predictor = durationPredictors[bucket] {
            return (encoder, predictor, bucket)
        }
        guard let repoDir = repoDirectory else { throw Supertonic3Error.notInitialized }

        let encoder = try Self.loadCPUStage(
            repoDir: repoDir,
            fileName: ModelNames.Supertonic3.textEncoderWideFile,
            functionName: ModelNames.Supertonic3.textEncoderFunction(bucket: bucket))
        let predictor = try Self.loadCPUStage(
            repoDir: repoDir,
            fileName: ModelNames.Supertonic3.durationPredictorWideFile,
            functionName: ModelNames.Supertonic3.durationPredictorFunction(bucket: bucket))

        textEncoders[bucket] = encoder
        durationPredictors[bucket] = predictor
        logger.info("Loaded text stages at T\(bucket) (.cpuOnly)")
        return (encoder, predictor, bucket)
    }

    /// The RangeDim VectorEstimator, `.cpuOnly`, loaded on first use.
    ///
    /// Precision follows the caller's `Supertonic3VectorEstimator`; int8 is the
    /// default and not a tuning choice, because the palettization ladder comes
    /// apart as chunks grow — int4 breaks at a 110-character cap, 6-bit at 300
    /// — while int8 stays clean at every cap measured.
    public func vectorEstimator() throws -> MLModel {
        if let cached = vectorEstimatorModel { return cached }
        guard let repoDir = repoDirectory else { throw Supertonic3Error.notInitialized }

        let model = try Self.loadCPUStage(
            repoDir: repoDir,
            fileName: ModelNames.Supertonic3.vectorEstimatorFile(
                precisionSuffix: veOption.precisionSuffix),
            functionName: nil)
        vectorEstimatorModel = model
        logger.info("Loaded VectorEstimator (.cpuOnly)")
        return model
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
        vocoderModel = nil
        textEncoders.removeAll()
        durationPredictors.removeAll()
        vectorEstimatorModel = nil
    }

    // MARK: - Helpers

    /// Load one CPU-pinned bundle from `repoDir`.
    ///
    /// `static` and repo-directory-parameterized so failures are testable
    /// without a populated cache.
    static func loadCPUStage(
        repoDir: URL, fileName: String, functionName: String?
    ) throws -> MLModel {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly

        if let functionName {
            // The text stages are multi-function bundles, which need the
            // macOS 15 / iOS 18 CoreML runtime. The package still targets
            // macOS 14, so this is a runtime gate; MacReader's own deployment
            // targets are 26 and never see it.
            guard #available(macOS 15.0, iOS 18.0, *) else {
                throw Supertonic3Error.unsupportedRuntime(
                    reason: "multi-function CoreML models require macOS 15+/iOS 18+")
            }
            cfg.functionName = functionName
        }

        let modelURL = repoDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw Supertonic3Error.modelFileNotFound(fileName)
        }
        do {
            let model = try MLModel(contentsOf: modelURL, configuration: cfg)
            ComputePlanLogger.logPlacement(
                modelURL: modelURL, configuration: cfg,
                label: fileName + (functionName.map { " [\($0)]" } ?? ""))
            return model
        } catch {
            let function = functionName.map { " [\($0)]" } ?? ""
            throw Supertonic3Error.corruptedModel(
                fileName + function, underlying: "\(error)")
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
