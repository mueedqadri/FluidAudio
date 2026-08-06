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
/// One path per chunk, whatever its length: the text stages are padded up to
/// the smallest published bucket that holds it, and the VectorEstimator takes
/// the exact latent length. Everything but the vocoder runs `.cpuOnly` — see
/// `Supertonic3ModelStore` for why.
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
        // The chunker sizes itself against the models' token windows directly,
        // so there is no per-language cap to pick here.
        let chunks = Supertonic3TextChunker.chunk(
            text: text, lang: language,
            wholeSentenceTokens: Supertonic3Constants.tierCeiling)
        guard !chunks.isEmpty else { throw Supertonic3Error.emptyText }

        let sampleRate = await store.config.ae.sampleRate
        let silenceSamples = max(0, Int(silenceDuration * Float(sampleRate)))
        let silence = [Float](repeating: 0, count: silenceSamples)

        var samples: [Float] = []
        var durationCat: Float = 0
        var isFirst = true

        for chunk in chunks {
            // One piece per chunk normally; more only when a chunk overruns a
            // model window and has to be re-split. Either way the seam
            // treatment is identical.
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

    // MARK: - Per-chunk dispatch

    /// Synthesize one chunk on the text bucket its encoded length calls for.
    ///
    /// Returns a list because a chunk can overrun the latent window — a long
    /// sentence at a slow playback rate predicts past 512 slots. The recovery
    /// is to re-split at `textTFixed` and synthesize the pieces through the
    /// same stages, which is heard as a seam rather than as failed playback.
    private func inferChunk(
        text: String, language: String,
        style: Supertonic3VoiceStyle,
        totalSteps: Int, speed: Float
    ) async throws -> [(samples: [Float], duration: Float)] {
        let tokens = Supertonic3TextChunker.encodedLength(of: text, lang: language)
        do {
            return [
                try await infer(
                    text: text, language: language, style: style,
                    totalSteps: totalSteps, speed: speed, tokenLength: tokens)
            ]
        } catch Supertonic3Error.tierUnavailable(let reason) {
            logger.warning(
                "A \(tokens)-token chunk exceeds a model window (\(reason)); "
                    + "splitting at \(Supertonic3Constants.textTFixed)")
            var pieces: [(samples: [Float], duration: Float)] = []
            for piece in Supertonic3TextChunker.chunk(
                text: text, lang: language,
                wholeSentenceTokens: Supertonic3Constants.textTFixed)
            {
                // Deliberately not recursive: a piece that still overruns has
                // nowhere left to go, and the error is the honest answer.
                pieces.append(
                    try await infer(
                        text: piece, language: language, style: style,
                        totalSteps: totalSteps, speed: speed,
                        tokenLength: Supertonic3TextChunker.encodedLength(
                            of: piece, lang: language)))
            }
            return pieces
        }
    }

    // MARK: - Single-chunk inference (batch size 1)

    /// Run the four stages for one chunk of `tokenLength` encoded tokens.
    private func infer(
        text: String, language: String,
        style: Supertonic3VoiceStyle,
        totalSteps: Int, speed: Float,
        tokenLength: Int
    ) async throws -> (samples: [Float], duration: Float) {
        let stages = try await store.textStages(forTokenLength: tokenLength)
        let (textEncoder, durationPredictor, maxLen) = stages
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
        let dpOut = try await predict(
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
        let textEncOut = try await predict(
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

        // RangeDim is not unbounded: the VectorEstimator and the vocoder both
        // publish a 512-slot latent ceiling, and a near-`tierCeiling` sentence
        // at a slow speed predicts a duration past it. Report the window
        // overrun — the caller re-splits at the 128-token window and the pieces
        // fit — rather than letting CoreML reject the bind, which nothing
        // upstream can recover from.
        guard trueLen <= Supertonic3Constants.dynamicLatentSlotCeiling else {
            throw Supertonic3Error.tierUnavailable(
                reason: "a \(trueLen)-slot latent exceeds the "
                    + "\(Supertonic3Constants.dynamicLatentSlotCeiling)-slot window the "
                    + "VectorEstimator and vocoder publish (≈35.7 s of audio)")
        }
        let vectorEstimator = try await store.vectorEstimator()

        // The same axis has a floor, and short utterances fall under it — a
        // one-word paragraph at 2x speed predicts 10 slots against a bound of
        // 17. Pad up to `minimumLatentSlots`, which clears that bound and the
        // int8 kernel's 32-wide tile in one step (below the tile a short chunk
        // costs up to 47x more per step than a padded one). The mask keeps the
        // tail out of the computation; the trim below takes it back off.
        let veLen = max(trueLen, Supertonic3Constants.minimumLatentSlots)
        let veLatentShape = [latentDims.bsz, channels, veLen]

        let noisyFlat =
            veLen == trueLen
            ? initialLatent
            : Self.padRows(initialLatent, channels: channels, fromLen: trueLen, toLen: veLen)
        let veMaskFlat =
            veLen == trueLen ? latentMaskFlat : Self.padTail(latentMaskFlat, toLen: veLen)

        var noisyLatent = try makeFloat(values: noisyFlat, shape: veLatentShape)
        let latentMask = try makeFloat(values: veMaskFlat, shape: [latentDims.bsz, 1, veLen])

        for step in 0..<totalSteps {
            let currentStep = try makeFloat(values: [Float(step)], shape: [1])
            let totalStep = try makeFloat(values: [Float(totalSteps)], shape: [1])

            let denoisedOut = try await predict(
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

        // Drop the floor padding before the vocoder, which takes a RangeDim
        // latent length of its own.
        let vocoderLatent: MLMultiArray
        if veLen == trueLen {
            vocoderLatent = noisyLatent
        } else {
            let denoisedFlat = Supertonic3MultiArray.extractFloats(noisyLatent)
            let trimmed = Self.trimRows(
                denoisedFlat, channels: channels, fromLen: veLen, toLen: trueLen)
            vocoderLatent = try makeFloat(values: trimmed, shape: latentShape)
        }

        // --- Stage 4: vocoder --- //
        let vocoderOut = try await predict(
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
    ) async throws -> MLFeatureProvider {
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        } catch {
            throw Supertonic3Error.inferenceFailed(
                stage: stage, underlying: "feature provider: \(error)")
        }
        ComputePlanLogger.notePredictionQoS(stage: "supertonic.\(stage)")
        do {
            // The async API, matching KokoroAneSynthesizer. Not a style choice:
            // ~30 s after backgrounding, iOS demotes the app's threads, and a
            // synchronous prediction submitted from a demoted thread has its
            // ANE request refused at the kernel (kIOReturnNotPermitted →
            // "Unable to compute the prediction"). Kokoro, on this API, keeps
            // synthesizing in the background on the same device.
            return try await model.prediction(from: provider)
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

    // MARK: - Latent floor padding (channel-major [1, C, L] flattened)

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
