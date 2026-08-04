@preconcurrency import CoreML
import Foundation

/// Drives the four Supertonic-3 CoreML stages end-to-end.
///
/// Inference flow (per chunk, batch size 1):
///   1. `text_encoder(text_ids, text_mask, style_ttl) → text_emb`
///   2. `duration_predictor(text_ids, text_mask, style_dp) → duration`
///   3. Sample `[1, latentDim * chunkCompress, latentLen]` noisy latent.
///   4. Repeat `totalStep` times:
///        `vector_estimator(noisy_latent, text_emb, style_ttl,
///                          latent_mask, text_mask,
///                          current_step, total_step) → denoised_latent`
///      and feed `denoised_latent` back as `noisy_latent` for the next step.
///   5. `vocoder(latent) → wav` (44.1 kHz Float32 PCM).
///
/// Input / output tensor names match the upstream ONNX graph; the conversion
/// script (`Scripts/convert_supertonic3_to_coreml.py`) preserves them.
struct Supertonic3Synthesizer {

    private let logger = AppLogger(category: "Supertonic3Synthesizer")
    private let store: Supertonic3ModelStore
    private let processor: Supertonic3UnicodeProcessor

    init(store: Supertonic3ModelStore, processor: Supertonic3UnicodeProcessor) {
        self.store = store
        self.processor = processor
    }

    // MARK: - Public synthesis

    /// Synthesize a long utterance by chunking, calling `_infer` per chunk,
    /// and concatenating with `silenceDuration` of silence between chunks.
    func synthesize(
        text: String,
        language: String,
        style: Supertonic3VoiceStyle,
        totalSteps: Int,
        speed: Float,
        silenceDuration: Float
    ) async throws -> (samples: [Float], duration: Float) {
        // The chunker sizes itself against the models' token window directly,
        // so there is no per-language cap to pick here. How long a single
        // sentence may run does depend on what is installed: without the wide
        // stages the ceiling collapses onto the packing cap and chunking is
        // exactly what it was before the tier existed.
        let wideTierAvailable = await store.isWideTierAvailable()
        let chunks = Supertonic3TextChunker.chunk(
            text: text, lang: language,
            wholeSentenceTokens: wideTierAvailable
                ? Supertonic3Constants.tierCeiling : Supertonic3Constants.textTFixed)
        guard !chunks.isEmpty else { throw Supertonic3Error.emptyText }

        let sampleRate = await store.config.ae.sampleRate
        let silenceSamples = max(0, Int(silenceDuration * Float(sampleRate)))
        let silence = [Float](repeating: 0, count: silenceSamples)

        var samples: [Float] = []
        var durationCat: Float = 0
        var isFirst = true

        for chunk in chunks {
            // One piece per chunk normally; more only when a chunk sized for
            // tier 2 has to be re-split because the tier turned out to be
            // unloadable. Either way the seam treatment is identical.
            for (pieceSamples, pieceDuration) in try await inferChunk(
                text: chunk, language: language, style: style,
                totalSteps: totalSteps, speed: speed)
            {
                if isFirst {
                    samples = pieceSamples
                    durationCat = pieceDuration
                    isFirst = false
                } else {
                    samples.append(contentsOf: silence)
                    samples.append(contentsOf: pieceSamples)
                    durationCat += silenceDuration + pieceDuration
                }
            }
        }

        return (samples, durationCat)
    }

    // MARK: - Tier routing

    /// Which VectorEstimator a chunk runs on, and how its latent is sized.
    private enum VectorEstimatorPlan {
        /// Tier 1: the store picks a fixed-length ANE bucket and the latent is
        /// padded up to it.
        case bucketed
        /// Tier 2: one dynamic-shape model, fed the exact latent length. This
        /// is the mode the quality ceiling was measured in.
        case dynamic(MLModel)
    }

    /// Synthesize one chunk, on the tier its encoded length calls for.
    ///
    /// Returns a list because the tier-2 attempt can fail on an installed but
    /// unloadable bundle; the recovery is to re-split the chunk at the tier-1
    /// window and synthesize the pieces, which sounds like it did before the
    /// tier existed rather than failing playback.
    private func inferChunk(
        text: String, language: String,
        style: Supertonic3VoiceStyle,
        totalSteps: Int, speed: Float
    ) async throws -> [(samples: [Float], duration: Float)] {
        let tokens = Supertonic3TextChunker.encodedLength(of: text, lang: language)
        guard tokens > Supertonic3Constants.textTFixed else {
            return [
                try await infer(
                    text: text, language: language, style: style,
                    totalSteps: totalSteps, speed: speed,
                    maxLen: Supertonic3Constants.textTFixed,
                    textEncoder: await store.textEncoder(),
                    durationPredictor: await store.durationPredictor(),
                    vectorEstimatorPlan: .bucketed)
            ]
        }

        do {
            let stages = try await store.wideTextStages(forTokenLength: tokens)
            return [
                try await infer(
                    text: text, language: language, style: style,
                    totalSteps: totalSteps, speed: speed,
                    maxLen: stages.paddedT,
                    textEncoder: stages.textEncoder,
                    durationPredictor: stages.durationPredictor,
                    vectorEstimatorPlan: .dynamic(try await store.dynamicVectorEstimator()))
            ]
        } catch Supertonic3Error.tierUnavailable(let reason) {
            logger.warning(
                "Long-sentence tier unavailable for a \(tokens)-token chunk "
                    + "(\(reason)); splitting at \(Supertonic3Constants.textTFixed)")
            var pieces: [(samples: [Float], duration: Float)] = []
            for piece in Supertonic3TextChunker.chunk(
                text: text, lang: language,
                wholeSentenceTokens: Supertonic3Constants.textTFixed)
            {
                pieces.append(
                    try await infer(
                        text: piece, language: language, style: style,
                        totalSteps: totalSteps, speed: speed,
                        maxLen: Supertonic3Constants.textTFixed,
                        textEncoder: await store.textEncoder(),
                        durationPredictor: await store.durationPredictor(),
                        vectorEstimatorPlan: .bucketed))
            }
            return pieces
        }
    }

    // MARK: - Single-chunk inference (batch size 1)

    /// Run the four stages for one chunk against already-resolved models.
    ///
    /// The stages arrive as parameters rather than being fetched here so that
    /// both tiers share this body verbatim: they differ only in which two text
    /// stages run, what the text axis is padded to, and whether the latent is
    /// bucket-padded or exact.
    private func infer(
        text: String, language: String,
        style: Supertonic3VoiceStyle,
        totalSteps: Int, speed: Float,
        maxLen: Int,
        textEncoder: MLModel,
        durationPredictor: MLModel,
        vectorEstimatorPlan: VectorEstimatorPlan
    ) async throws -> (samples: [Float], duration: Float) {
        let (idsBatch, maskBatch) = try processor.encode(
            texts: [text], languages: [language], maxLen: maxLen)
        guard let ids = idsBatch.first, let mask = maskBatch.first else {
            throw Supertonic3Error.emptyText
        }
        let textLen = ids.count

        let ids32 = ids.map { Int32(clamping: $0) }
        let textIds = try makeInt32(values: ids32, shape: [1, textLen])

        let maskFlat = mask[0]
        let textMask = try makeFloat(values: maskFlat, shape: [1, 1, textLen])

        let styleTTL = try makeFloat(values: style.ttlValues, shape: [1] + Array(style.ttlDims.dropFirst()))
        let styleDP = try makeFloat(values: style.dpValues, shape: [1] + Array(style.dpDims.dropFirst()))

        // --- Stage 1: duration_predictor --- //
        let dpOut = try predict(
            stage: "duration_predictor",
            model: durationPredictor,
            inputs: [
                "text_ids": MLFeatureValue(multiArray: textIds),
                "text_mask": MLFeatureValue(multiArray: textMask),
                "style_dp": MLFeatureValue(multiArray: styleDP),
            ])
        guard let durationArray = dpOut.featureValue(for: "duration")?.multiArrayValue else {
            throw Supertonic3Error.inferenceFailed(
                stage: "duration_predictor", underlying: "missing 'duration' output")
        }
        var durations = Supertonic3MultiArray.extractFloats(durationArray)
        for i in durations.indices {
            durations[i] = max(0.05, durations[i] / max(speed, 0.05))
        }

        // --- Stage 2: text_encoder --- //
        let textEncOut = try predict(
            stage: "text_encoder",
            model: textEncoder,
            inputs: [
                "text_ids": MLFeatureValue(multiArray: textIds),
                "text_mask": MLFeatureValue(multiArray: textMask),
                "style_ttl": MLFeatureValue(multiArray: styleTTL),
            ])
        guard let textEmbValue = textEncOut.featureValue(for: "text_emb")?.multiArrayValue else {
            throw Supertonic3Error.inferenceFailed(
                stage: "text_encoder", underlying: "missing 'text_emb' output")
        }

        // --- Stage 3: noisy latent + denoising loop --- //
        let cfg = await store.config
        let (initialLatent, latentMaskFlat, latentDims) =
            Supertonic3LatentSampler.sampleNoisyLatent(
                durations: durations,
                sampleRate: cfg.ae.sampleRate,
                baseChunkSize: cfg.ae.baseChunkSize,
                chunkCompress: cfg.ttl.chunkCompressFactor,
                latentDim: cfg.ttl.latentDim)

        let trueLen = latentDims.length
        let channels = latentDims.channels
        let latentShape = [latentDims.bsz, channels, trueLen]

        // Resolve the VectorEstimator for this chunk. In bucketed (ANE) mode the
        // store returns a fixed-length model and the bucket length to pad up to;
        // in dynamic mode `padLen == trueLen` and no padding happens.
        let (vectorEstimator, padLen): (MLModel, Int)
        switch vectorEstimatorPlan {
        case .bucketed:
            (vectorEstimator, padLen) = try await store.vectorEstimator(forLatentLength: trueLen)
        case .dynamic(let model):
            (vectorEstimator, padLen) = (model, trueLen)
        }

        let veLatentShape = [latentDims.bsz, channels, padLen]
        let veMaskShape = [latentDims.bsz, 1, padLen]

        let noisyFlat =
            padLen == trueLen
            ? initialLatent
            : Self.padRows(initialLatent, channels: channels, fromLen: trueLen, toLen: padLen)
        let veMaskFlat =
            padLen == trueLen
            ? latentMaskFlat
            : Self.padTail(latentMaskFlat, toLen: padLen)

        var noisyLatent = try makeFloat(values: noisyFlat, shape: veLatentShape)
        let latentMask = try makeFloat(values: veMaskFlat, shape: veMaskShape)

        for step in 0..<totalSteps {
            let currentStep = try makeFloat(values: [Float(step)], shape: [1])
            let totalStep = try makeFloat(values: [Float(totalSteps)], shape: [1])

            let denoisedOut = try predict(
                stage: "vector_estimator",
                model: vectorEstimator,
                inputs: [
                    "noisy_latent": MLFeatureValue(multiArray: noisyLatent),
                    "text_emb": MLFeatureValue(multiArray: textEmbValue),
                    "style_ttl": MLFeatureValue(multiArray: styleTTL),
                    "latent_mask": MLFeatureValue(multiArray: latentMask),
                    "text_mask": MLFeatureValue(multiArray: textMask),
                    "current_step": MLFeatureValue(multiArray: currentStep),
                    "total_step": MLFeatureValue(multiArray: totalStep),
                ])
            guard
                let denoised = denoisedOut.featureValue(for: "denoised_latent")?.multiArrayValue
            else {
                throw Supertonic3Error.inferenceFailed(
                    stage: "vector_estimator", underlying: "missing 'denoised_latent' output")
            }
            // Rebind without recopying when the shape and dtype already match.
            noisyLatent = try reshape(denoised, to: veLatentShape)
        }

        // Trim the padded bucket output back to the true latent length before the
        // vocoder (which accepts a RangeDim latent length).
        let vocoderLatent: MLMultiArray
        if padLen == trueLen {
            vocoderLatent = noisyLatent
        } else {
            let denoisedFlat = Supertonic3MultiArray.extractFloats(noisyLatent)
            let trimmed = Self.trimRows(
                denoisedFlat, channels: channels, fromLen: padLen, toLen: trueLen)
            vocoderLatent = try makeFloat(values: trimmed, shape: latentShape)
        }

        // --- Stage 4: vocoder --- //
        let vocoderOut = try predict(
            stage: "vocoder",
            model: await store.vocoder(),
            inputs: ["latent": MLFeatureValue(multiArray: vocoderLatent)])
        guard let wavArray = vocoderOut.featureValue(for: "wav")?.multiArrayValue else {
            throw Supertonic3Error.inferenceFailed(
                stage: "vocoder", underlying: "missing 'wav' output")
        }

        let wavSamples = Supertonic3MultiArray.extractFloats(wavArray)
        let firstDuration = durations.first ?? 0
        let trimLen = min(wavSamples.count, Int(Float(cfg.ae.sampleRate) * firstDuration))
        let trimmed = trimLen > 0 ? Array(wavSamples.prefix(trimLen)) : wavSamples
        return (trimmed, firstDuration)
    }

    // MARK: - CoreML plumbing

    private func predict(
        stage: String, model: MLModel, inputs: [String: MLFeatureValue]
    ) throws -> MLFeatureProvider {
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        } catch {
            throw Supertonic3Error.inferenceFailed(
                stage: stage, underlying: "feature provider: \(error)")
        }
        do {
            return try model.prediction(from: provider)
        } catch {
            throw Supertonic3Error.inferenceFailed(stage: stage, underlying: "\(error)")
        }
    }

    private func makeFloat(values: [Float], shape: [Int]) throws -> MLMultiArray {
        do {
            return try Supertonic3MultiArray.makeFloat32(values, shape: shape)
        } catch {
            throw Supertonic3Error.invalidTensorShape(
                stage: "tensor", expected: "\(shape)",
                got: "len=\(values.count) (\(error))")
        }
    }

    // MARK: - Bucket padding helpers (channel-major [1, C, L] flattened)

    /// Right-pad each channel row from `fromLen` to `toLen` with zeros.
    /// Input/output are row-major `[1, channels, len]` flattened (`c*len + t`).
    static func padRows(_ flat: [Float], channels: Int, fromLen: Int, toLen: Int) -> [Float] {
        guard toLen > fromLen else { return flat }
        var out = [Float](repeating: 0, count: channels * toLen)
        for c in 0..<channels {
            let src = c * fromLen
            let dst = c * toLen
            for t in 0..<fromLen { out[dst + t] = flat[src + t] }
        }
        return out
    }

    /// Trim each channel row from `fromLen` down to `toLen` (drops the padding).
    static func trimRows(_ flat: [Float], channels: Int, fromLen: Int, toLen: Int) -> [Float] {
        guard fromLen > toLen else { return flat }
        var out = [Float](repeating: 0, count: channels * toLen)
        for c in 0..<channels {
            let src = c * fromLen
            let dst = c * toLen
            for t in 0..<toLen { out[dst + t] = flat[src + t] }
        }
        return out
    }

    /// Right-pad a single `[1, 1, L]` mask row with zeros up to `toLen`.
    static func padTail(_ flat: [Float], toLen: Int) -> [Float] {
        guard toLen > flat.count else { return flat }
        return flat + [Float](repeating: 0, count: toLen - flat.count)
    }

    private func makeInt32(values: [Int32], shape: [Int]) throws -> MLMultiArray {
        do {
            return try Supertonic3MultiArray.makeInt32(values, shape: shape)
        } catch {
            throw Supertonic3Error.invalidTensorShape(
                stage: "tensor", expected: "\(shape)",
                got: "len=\(values.count) (\(error))")
        }
    }

    /// Re-bind a model output back into the expected `[bsz, channels, length]`
    /// latent shape. Most CoreML graphs preserve the trace-time shape so this
    /// is usually identity — the helper exists to gracefully recover when a
    /// converter inserts an extra leading axis.
    private func reshape(_ array: MLMultiArray, to shape: [Int]) throws -> MLMultiArray {
        let totalRequested = shape.reduce(1, *)
        if array.count != totalRequested {
            throw Supertonic3Error.invalidTensorShape(
                stage: "vector_estimator",
                expected: "\(shape)", got: "count=\(array.count)")
        }
        if array.shape.map({ $0.intValue }) == shape, array.dataType == .float32 {
            return array
        }
        let values = Supertonic3MultiArray.extractFloats(array)
        return try Supertonic3MultiArray.makeFloat32(values, shape: shape)
    }
}
