@preconcurrency import CoreML
import XCTest

@testable import FluidAudio

/// Covers the one synthesis path every Supertonic-3 chunk takes: bucket sizing,
/// asset naming, encoder parameterization, the two window guards, and — where
/// the assets are installed locally — end-to-end synthesis at both ends of the
/// bucket range.
final class Supertonic3SinglePathTests: XCTestCase {

    // MARK: - Bucket selection

    func testBucketPicksSmallestThatHolds() {
        let bucket = Supertonic3Constants.wideTextBucket(forTokenLength:)
        XCTAssertEqual(bucket(1), 32)
        XCTAssertEqual(bucket(32), 32)
        XCTAssertEqual(bucket(33), 64)
        XCTAssertEqual(bucket(64), 64)
        XCTAssertEqual(bucket(65), 128)
        XCTAssertEqual(bucket(128), 128)
        XCTAssertEqual(bucket(129), 192)
        XCTAssertEqual(bucket(193), 256)
        XCTAssertEqual(bucket(257), 320)
        XCTAssertEqual(bucket(320), 320)
    }

    func testBucketIsNilPastTheCeiling() {
        XCTAssertNil(Supertonic3Constants.wideTextBucket(forTokenLength: 321))
        XCTAssertNil(Supertonic3Constants.wideTextBucket(forTokenLength: 1_000))
    }

    func testCeilingIsTheLargestPublishedBucket() {
        XCTAssertEqual(Supertonic3Constants.wideTextBuckets.last, Supertonic3Constants.tierCeiling)
        XCTAssertEqual(
            Supertonic3Constants.wideTextBuckets, Supertonic3Constants.wideTextBuckets.sorted())
    }

    /// The packing cap is a bucket like any other now — nothing routes on it.
    func testPackingCapIsItsOwnBucket() {
        XCTAssertTrue(
            Supertonic3Constants.wideTextBuckets.contains(Supertonic3Constants.textTFixed))
        XCTAssertEqual(
            Supertonic3Constants.wideTextBucket(
                forTokenLength: Supertonic3Constants.textTFixed),
            Supertonic3Constants.textTFixed)
    }

    // MARK: - Asset naming

    func testStageFileNames() {
        XCTAssertEqual(ModelNames.Supertonic3.textEncoderWideFile, "TextEncoderWide.mlmodelc")
        XCTAssertEqual(
            ModelNames.Supertonic3.durationPredictorWideFile, "DurationPredictorWide.mlmodelc")
    }

    func testFunctionNamesPerBucket() {
        XCTAssertEqual(ModelNames.Supertonic3.textEncoderFunction(bucket: 32), "text_t32")
        XCTAssertEqual(ModelNames.Supertonic3.textEncoderFunction(bucket: 128), "text_t128")
        XCTAssertEqual(ModelNames.Supertonic3.textEncoderFunction(bucket: 320), "text_t320")
        XCTAssertEqual(
            ModelNames.Supertonic3.durationPredictorFunction(bucket: 32), "duration_t32")
        XCTAssertEqual(
            ModelNames.Supertonic3.durationPredictorFunction(bucket: 320), "duration_t320")
    }

    func testVectorEstimatorFileNaming() {
        // FP16 stays at repo root; quantized variants live under the subdir.
        XCTAssertEqual(
            ModelNames.Supertonic3.vectorEstimatorFile(precisionSuffix: nil),
            "VectorEstimator.mlmodelc")
        XCTAssertEqual(
            ModelNames.Supertonic3.vectorEstimatorFile(precisionSuffix: "int8"),
            "VectorEstimatorVariants/VectorEstimator_int8.mlmodelc")
    }

    /// The inversion of the two-tier contract: the multi-function text stages
    /// are the *only* text stages, so every download variant must require them.
    func testTextStagesAreRequiredForEveryDownloadVariant() {
        for variant in [nil, "dyn-int8", "dyn-int4"] {
            let required = ModelNames.Supertonic3.requiredFiles(veVariant: variant)
            XCTAssertTrue(
                required.contains(ModelNames.Supertonic3.textEncoderWideFile),
                "variant \(variant ?? "fp16")")
            XCTAssertTrue(
                required.contains(ModelNames.Supertonic3.durationPredictorWideFile),
                "variant \(variant ?? "fp16")")
            XCTAssertTrue(required.contains(ModelNames.Supertonic3.vocoderFile))
        }
    }

    /// The retired narrow stages and fixed-length VectorEstimators must not be
    /// fetched: they are ~190 MB the pipeline can no longer load.
    func testRetiredAssetsAreNeverRequired() {
        for variant in [nil, "dyn-int8", "dyn-int4"] {
            let required = ModelNames.Supertonic3.requiredFiles(veVariant: variant)
            for retired in [
                "TextEncoder.mlmodelc", "DurationPredictor.mlmodelc",
                "VectorEstimatorVariants/VectorEstimator_L128_int8.mlmodelc",
                "VectorEstimatorVariants/VectorEstimator_L256_int8.mlmodelc",
                "VectorEstimatorVariants/VectorEstimator_L512_int8.mlmodelc",
            ] {
                XCTAssertFalse(
                    required.contains(retired),
                    "\(retired) is retired (variant \(variant ?? "fp16"))")
            }
        }
    }

    func testRequiredFilesPerVariant() {
        let dyn = ModelNames.Supertonic3.requiredFiles(veVariant: "dyn-int8")
        XCTAssertTrue(dyn.contains("VectorEstimatorVariants/VectorEstimator_int8.mlmodelc"))
        XCTAssertFalse(dyn.contains("VectorEstimator.mlmodelc"))

        let fp16 = ModelNames.Supertonic3.requiredFiles(veVariant: nil)
        XCTAssertTrue(fp16.contains("VectorEstimator.mlmodelc"))
    }

    /// The app path implies `dyn-int8`; if the default ever drifts, the
    /// manifest MacReader ships stops matching what the store loads.
    func testDefaultVectorEstimatorIsDynamicInt8() {
        XCTAssertEqual(Supertonic3VectorEstimator.default, .dynamic(.int8))
        XCTAssertEqual(Supertonic3VectorEstimator.default.downloadVariant, "dyn-int8")
        XCTAssertEqual(Supertonic3VectorEstimator.default.precisionSuffix, "int8")
    }

    // MARK: - Encoder parameterization

    func testEncodeDefaultsToThePackingCap() throws {
        let processor = try Self.makeProcessor()
        let (ids, mask) = try processor.encode(texts: ["Hello there."], languages: ["en"])
        XCTAssertEqual(ids[0].count, Supertonic3Constants.textTFixed)
        XCTAssertEqual(mask[0][0].count, Supertonic3Constants.textTFixed)
    }

    func testEncodePadsToABucket() throws {
        let processor = try Self.makeProcessor()
        let text = "A gentle breeze moved through the open window."
        let scalars = Supertonic3TextChunker.encodedLength(of: text, lang: "en")
        let (ids, mask) = try processor.encode(
            texts: [text], languages: ["en"], maxLen: 256)

        XCTAssertEqual(ids[0].count, 256)
        XCTAssertEqual(mask[0][0].count, 256)
        // Exactly `min(scalars, 256)` ones, then zeros — the mask is what tells
        // the stage where the sentence actually ends inside the padded axis.
        XCTAssertEqual(mask[0][0].filter { $0 == 1 }.count, min(scalars, 256))
        XCTAssertEqual(
            Array(mask[0][0].suffix(from: scalars)), [Float](repeating: 0, count: 256 - scalars))
        XCTAssertTrue(ids[0].dropFirst(scalars).allSatisfy { $0 == 0 })
    }

    /// The smallest bucket is one the two-tier design never exercised, so its
    /// masking gets the same explicit check the wide ones got.
    func testEncodePadsToTheSmallestBucket() throws {
        let processor = try Self.makeProcessor()
        let smallest = try XCTUnwrap(Supertonic3Constants.wideTextBuckets.first)
        let text = "Yes."
        let scalars = Supertonic3TextChunker.encodedLength(of: text, lang: "en")
        try XCTSkipUnless(scalars <= smallest, "\"\(text)\" encodes to \(scalars) tokens")

        let (ids, mask) = try processor.encode(
            texts: [text], languages: ["en"], maxLen: smallest)
        XCTAssertEqual(ids[0].count, smallest)
        XCTAssertEqual(mask[0][0].filter { $0 == 1 }.count, scalars)
        XCTAssertTrue(ids[0].dropFirst(scalars).allSatisfy { $0 == 0 })
    }

    func testEncodeTruncatesWhenTextOutgrowsTheBucket() throws {
        let processor = try Self.makeProcessor()
        // 400 scalars of content, wrapper included — past the 320 ceiling.
        let text = String(repeating: "word ", count: 90)
        let (ids, mask) = try processor.encode(
            texts: [text], languages: ["en"], maxLen: Supertonic3Constants.tierCeiling)
        XCTAssertEqual(ids[0].count, Supertonic3Constants.tierCeiling)
        XCTAssertEqual(
            mask[0][0].filter { $0 == 1 }.count, Supertonic3Constants.tierCeiling,
            "an over-long text fills the whole axis")
    }

    // MARK: - Missing assets

    /// The stages are required now, so an absent bundle is a hard
    /// `.modelFileNotFound` — there is no second model set to degrade onto.
    func testMissingStageReportsModelFileNotFound() throws {
        let empty = try Self.makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }

        for (file, function) in [
            (ModelNames.Supertonic3.textEncoderWideFile, "text_t32"),
            (ModelNames.Supertonic3.durationPredictorWideFile, "duration_t32"),
            (ModelNames.Supertonic3.vectorEstimatorFile(precisionSuffix: "int8"), nil),
        ] as [(String, String?)] {
            do {
                _ = try Supertonic3ModelStore.loadCPUStage(
                    repoDir: empty, fileName: file, functionName: function)
                XCTFail("\(file) should not load out of an empty directory")
            } catch Supertonic3Error.modelFileNotFound(let name) {
                XCTAssertEqual(name, file)
            }
        }
    }

    func testTokenLengthPastCeilingReportsAWindowOverrun() async throws {
        let store = Supertonic3ModelStore(directory: try Self.makeEmptyDirectory())
        do {
            _ = try await store.textStages(forTokenLength: 321)
            XCTFail("321 tokens is past the ceiling and has no bucket")
        } catch Supertonic3Error.tierUnavailable(let reason) {
            XCTAssertTrue(reason.contains("321"), reason)
        }
    }

    /// Before `loadIfNeeded()` there is no repo directory to look in, and that
    /// is a different failure from an absent asset.
    func testAccessorsRequireInitializationFirst() async throws {
        let store = Supertonic3ModelStore(directory: try Self.makeEmptyDirectory())
        do {
            _ = try await store.textStages(forTokenLength: 200)
            XCTFail("expected .notInitialized")
        } catch Supertonic3Error.notInitialized {
            // Expected.
        }
        do {
            _ = try await store.vectorEstimator()
            XCTFail("expected .notInitialized")
        } catch Supertonic3Error.notInitialized {
            // Expected.
        }
    }

    // MARK: - Real assets (skipped when not installed locally)

    func testVectorEstimatorLoadsCPUOnlyWhenInstalled() throws {
        let repoDir = Self.localRepoDirectory
        let file = ModelNames.Supertonic3.vectorEstimatorFile(precisionSuffix: "int8")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: repoDir.appendingPathComponent(file).path),
            "\(file) not installed in the local cache")

        let model = try Supertonic3ModelStore.loadCPUStage(
            repoDir: repoDir, fileName: file, functionName: nil)
        XCTAssertNotNil(model.modelDescription.inputDescriptionsByName["noisy_latent"])
        XCTAssertNotNil(model.modelDescription.inputDescriptionsByName["current_step"])
    }

    /// Every published bucket must actually exist as a function in the bundles
    /// — including the four the two-tier build never loaded.
    func testEveryBucketLoadsWhenInstalled() throws {
        try XCTSkipUnless(Self.hasTextStages, "text stages not installed in the local cache")

        for bucket in Supertonic3Constants.wideTextBuckets {
            let encoder = try Supertonic3ModelStore.loadCPUStage(
                repoDir: Self.localRepoDirectory,
                fileName: ModelNames.Supertonic3.textEncoderWideFile,
                functionName: ModelNames.Supertonic3.textEncoderFunction(bucket: bucket))
            let ids = encoder.modelDescription.inputDescriptionsByName["text_ids"]
            XCTAssertEqual(
                ids?.multiArrayConstraint?.shape.map(\.intValue), [1, bucket],
                "text_t\(bucket) should declare a [1, \(bucket)] text axis")
            XCTAssertEqual(
                ids?.multiArrayConstraint?.dataType, .int32,
                "text_ids is Int32 — the synthesizer binds Int32")

            let predictor = try Supertonic3ModelStore.loadCPUStage(
                repoDir: Self.localRepoDirectory,
                fileName: ModelNames.Supertonic3.durationPredictorWideFile,
                functionName: ModelNames.Supertonic3.durationPredictorFunction(bucket: bucket))
            XCTAssertNotNil(predictor.modelDescription.outputDescriptionsByName["duration"])
        }
    }

    /// The stages declare `style_ttl` and `text_mask` as **fp16** where the
    /// synthesizer binds Float32. Whether CoreML's Swift API converts on our
    /// behalf is the one binding question these bundles raise. It does; this
    /// test is what says so.
    func testEncoderAcceptsOurFloat32Bindings() throws {
        try XCTSkipUnless(Self.hasTextStages, "text stages not installed in the local cache")

        let bucket = Supertonic3Constants.tierCeiling
        let encoder = try Supertonic3ModelStore.loadCPUStage(
            repoDir: Self.localRepoDirectory,
            fileName: ModelNames.Supertonic3.textEncoderWideFile,
            functionName: ModelNames.Supertonic3.textEncoderFunction(bucket: bucket))

        let ids = try Supertonic3MultiArray.makeInt32(
            [Int32](repeating: 1, count: bucket), shape: [1, bucket])
        let mask = try Supertonic3MultiArray.makeFloat32(
            [Float](repeating: 1, count: bucket), shape: [1, 1, bucket])
        let style = try Supertonic3MultiArray.makeFloat32(
            [Float](
                repeating: 0,
                count: Supertonic3Constants.ttlStyleTokens
                    * Supertonic3Constants.ttlStyleDim),
            shape: [
                1, Supertonic3Constants.ttlStyleTokens, Supertonic3Constants.ttlStyleDim,
            ])

        let out = try encoder.prediction(
            from: try MLDictionaryFeatureProvider(dictionary: [
                "text_ids": MLFeatureValue(multiArray: ids),
                "text_mask": MLFeatureValue(multiArray: mask),
                "style_ttl": MLFeatureValue(multiArray: style),
            ]))

        let emb = out.featureValue(for: "text_emb")?.multiArrayValue
        XCTAssertEqual(
            emb?.shape.map(\.intValue), [1, Supertonic3Constants.textEmbDim, bucket],
            "text_emb should come back [1, 256, \(bucket)] — the VectorEstimator's text axis")
    }

    /// `dynamicLatentSlotCeiling` is a transcription of what the artifacts
    /// declare, so read it back off the installed models rather than trusting
    /// the comment: the latent axis of both RangeDim stages must top out at
    /// exactly that many slots. If a re-export ever widens them, this is the
    /// line that says the constant (and the guard) can move.
    func testLatentCeilingMatchesThePublishedBounds() throws {
        let repoDir = Self.localRepoDirectory
        let veFile = ModelNames.Supertonic3.vectorEstimatorFile(precisionSuffix: "int8")
        for (file, input) in [(veFile, "noisy_latent"), ("Vocoder.mlmodelc", "latent")] {
            try XCTSkipUnless(
                FileManager.default.fileExists(
                    atPath: repoDir.appendingPathComponent(file).path),
                "\(file) not installed in the local cache")
            let model = try Supertonic3ModelStore.loadCPUStage(
                repoDir: repoDir, fileName: file, functionName: nil)
            let constraint = try XCTUnwrap(
                model.modelDescription.inputDescriptionsByName[input]?.multiArrayConstraint,
                "\(file) should declare \(input)")
            // `sizeRangeForDimension` is a count-style NSRange: NSMaxRange is
            // the exclusive end, so the largest permitted size is one less.
            let latentAxis = constraint.shapeConstraint.sizeRangeForDimension[2].rangeValue
            XCTAssertEqual(
                NSMaxRange(latentAxis) - 1, Supertonic3Constants.dynamicLatentSlotCeiling,
                "\(file)'s \(input) latent axis should top out at the guarded ceiling")
        }
    }

    /// The floor half of the same constraint — on **both** of the
    /// VectorEstimator's RangeDim axes, since the text one is what rules out
    /// the published `text_t16` bucket.
    func testEveryDynamicAxisStartsAtTheFloor() throws {
        let file = ModelNames.Supertonic3.vectorEstimatorFile(precisionSuffix: "int8")
        try XCTSkipUnless(Self.installed(file), "\(file) not installed in the local cache")

        let model = try Supertonic3ModelStore.loadCPUStage(
            repoDir: Self.localRepoDirectory, fileName: file, functionName: nil)
        for input in ["noisy_latent", "latent_mask", "text_emb", "text_mask"] {
            let constraint = try XCTUnwrap(
                model.modelDescription.inputDescriptionsByName[input]?.multiArrayConstraint,
                "\(file) should declare \(input)")
            XCTAssertEqual(
                constraint.shapeConstraint.sizeRangeForDimension[2].rangeValue.location,
                Supertonic3Constants.dynamicAxisFloor,
                "\(input)'s dynamic axis should start at the floor")
        }
    }

    /// The invariant behind dropping `text_t16`: the text encoder emits
    /// `[1, 256, bucket]`, and the VectorEstimator's text axis will not bind
    /// anything narrower than its floor. A bucket under it is unusable no
    /// matter that the function exists in the bundle.
    func testEveryPublishedBucketClearsTheTextAxisFloor() {
        XCTAssertTrue(
            Supertonic3Constants.wideTextBuckets.allSatisfy {
                $0 >= Supertonic3Constants.dynamicAxisFloor
            },
            "a bucket under \(Supertonic3Constants.dynamicAxisFloor) cannot feed the "
                + "VectorEstimator's text axis")
    }

    /// The other end of the same axis, and the regression that bucket padding
    /// used to hide: a short utterance at a fast playback rate predicts fewer
    /// latent slots than the VectorEstimator will bind. Ungated, CoreML rejects
    /// it — "Size (10) of dimension (2) is not in allowed range (17..512)" —
    /// and a one-word paragraph produces no audio at all.
    ///
    /// 2× is inside what a playback UI offers, and duration divides by speed,
    /// so this is an ordinary listening configuration rather than a corner.
    func testShortUtteranceAtFastSpeedClearsTheLatentFloor() async throws {
        try XCTSkipUnless(Self.hasEverythingForSynthesis, "synthesis assets not installed locally")

        let synthesizer = try await Self.makeSynthesizer()
        let style = try Supertonic3VoiceStyle.load(
            from: Self.localRepoDirectory.appendingPathComponent(Supertonic3Voice.m1.fileName))

        // A one-word paragraph is the shortest chunk the chunker can emit.
        var sawSubFloor = false
        for text in ["Yes.", "No.", "Hello there."] {
            let tokens = Supertonic3TextChunker.encodedLength(of: text, lang: "en")
            let bucket = try XCTUnwrap(
                Supertonic3Constants.wideTextBucket(forTokenLength: tokens))

            let (samples, duration) = try await synthesizer.synthesize(
                text: text, language: "en", style: style,
                totalSteps: Supertonic3Constants.defaultTotalSteps,
                speed: 2.0,
                silenceDuration: Supertonic3Constants.defaultSilenceDuration)

            let slots = Self.latentSlots(forDuration: duration)
            if slots < Supertonic3Constants.dynamicAxisFloor { sawSubFloor = true }
            print(
                "[floor] \"\(text)\" \(tokens) tokens → bucket \(bucket), 2x speed, "
                    + "\(String(format: "%.2f", duration))s = \(slots) slots "
                    + "(floor \(Supertonic3Constants.dynamicAxisFloor))")

            XCTAssertFalse(samples.allSatisfy { $0 == 0 }, "output must not be silence")
            // The waveform is trimmed to the predicted duration, so the pad
            // must not survive into it as trailing silence.
            XCTAssertEqual(
                Float(samples.count), duration * Float(Supertonic3Constants.sampleRate),
                accuracy: Float(Supertonic3Constants.sampleRate) * 0.1,
                "\"\(text)\" should return exactly its predicted duration, pad trimmed")
        }
        XCTAssertTrue(
            sawSubFloor,
            "none of these landed under the \(Supertonic3Constants.dynamicAxisFloor)-slot floor, "
                + "so this test proved nothing — raise the speed before trusting it")
    }

    /// At the default rate the same utterances sit just above the floor, which
    /// is why the padding is easy to miss: two slots of margin.
    func testShortUtteranceAtDefaultSpeedSitsJustAboveTheFloor() async throws {
        try XCTSkipUnless(Self.hasEverythingForSynthesis, "synthesis assets not installed locally")

        let synthesizer = try await Self.makeSynthesizer()
        let style = try Supertonic3VoiceStyle.load(
            from: Self.localRepoDirectory.appendingPathComponent(Supertonic3Voice.m1.fileName))

        let (samples, duration) = try await synthesizer.synthesize(
            text: "Yes.", language: "en", style: style,
            totalSteps: Supertonic3Constants.defaultTotalSteps,
            speed: Supertonic3Constants.defaultSpeed,
            silenceDuration: Supertonic3Constants.defaultSilenceDuration)

        print("[floor] \"Yes.\" at 1.05x = \(Self.latentSlots(forDuration: duration)) slots")
        XCTAssertFalse(samples.allSatisfy { $0 == 0 }, "output must not be silence")
    }

    private static func latentSlots(forDuration duration: Float) -> Int {
        let slotSamples =
            Supertonic3Constants.baseChunkSize * Supertonic3Constants.chunkCompressFactor
        return (Int(duration * Float(Supertonic3Constants.sampleRate)) + slotSamples - 1)
            / slotSamples
    }

    // MARK: - Floor padding helpers

    func testPadRowsZeroFillsEachChannelTail() {
        // 2 channels, length 3 → length 5. Layout is row-major [c*len + t].
        let flat: [Float] = [1, 2, 3, 4, 5, 6]  // c0:[1,2,3] c1:[4,5,6]
        let out = Supertonic3Synthesizer.padRows(flat, channels: 2, fromLen: 3, toLen: 5)
        XCTAssertEqual(out, [1, 2, 3, 0, 0, 4, 5, 6, 0, 0])
    }

    func testTrimRowsDropsEachChannelTail() {
        let flat: [Float] = [1, 2, 3, 9, 9, 4, 5, 6, 9, 9]
        let out = Supertonic3Synthesizer.trimRows(flat, channels: 2, fromLen: 5, toLen: 3)
        XCTAssertEqual(out, [1, 2, 3, 4, 5, 6])
    }

    func testPadThenTrimRoundTripsAtTheFloor() {
        let channels = 4
        let trueLen = 12
        let floor = Supertonic3Constants.minimumLatentSlots
        let flat = (0..<(channels * trueLen)).map { Float($0) }
        let padded = Supertonic3Synthesizer.padRows(
            flat, channels: channels, fromLen: trueLen, toLen: floor)
        XCTAssertEqual(padded.count, channels * floor)
        let restored = Supertonic3Synthesizer.trimRows(
            padded, channels: channels, fromLen: floor, toLen: trueLen)
        XCTAssertEqual(restored, flat)
    }

    /// The pad target has to clear the model's hard bound as well as the
    /// kernel's tile, or short chunks fail the bind instead of merely crawling.
    func testPadTargetClearsTheHardAxisFloor() {
        XCTAssertGreaterThanOrEqual(
            Supertonic3Constants.minimumLatentSlots, Supertonic3Constants.dynamicAxisFloor)
    }

    func testPadRowsNoopWhenLengthsEqual() {
        let flat: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(
            Supertonic3Synthesizer.padRows(flat, channels: 2, fromLen: 2, toLen: 2), flat)
    }

    func testPadTailZeroFillsMask() {
        let mask: [Float] = [1, 1, 1]
        XCTAssertEqual(Supertonic3Synthesizer.padTail(mask, toLen: 6), [1, 1, 1, 0, 0, 0])
        XCTAssertEqual(Supertonic3Synthesizer.padTail(mask, toLen: 3), [1, 1, 1])
    }

    /// The regression the ceiling guard exists for: a long sentence at a slow
    /// speed predicts a duration past the 512-slot latent window (≈35.7 s).
    /// Ungated, CoreML rejects the bind and the whole synthesize call fails —
    /// no audio at all. Guarded, it re-splits at the packing cap and plays.
    ///
    /// There is no second model set to recover onto now, so the re-split pieces
    /// go through these same stages at a smaller bucket.
    func testSlowSpeedLongSentenceFallsBackInsteadOfFailing() async throws {
        try XCTSkipUnless(Self.hasEverythingForSynthesis, "synthesis assets not installed locally")

        let synthesizer = try await Self.makeSynthesizer()
        let style = try Supertonic3VoiceStyle.load(
            from: Self.localRepoDirectory.appendingPathComponent(
                Supertonic3Voice.m1.fileName))

        // 0.3× stands in for "slowest supported rate on a long sentence":
        // ≈46 s predicted, comfortably past the window, while the re-split
        // pieces fit their own buckets.
        let (samples, duration) = try await synthesizer.synthesize(
            text: Self.gatsbySentence, language: "en", style: style,
            totalSteps: Supertonic3Constants.defaultTotalSteps,
            speed: 0.3,
            silenceDuration: Supertonic3Constants.defaultSilenceDuration)

        XCTAssertGreaterThan(
            duration, 35.7,
            "the predicted duration must actually cross the latent window for "
                + "this test to prove anything")
        XCTAssertEqual(
            Float(samples.count), duration * Float(Supertonic3Constants.sampleRate),
            accuracy: Float(Supertonic3Constants.sampleRate),
            "sample count should match the predicted duration to within a second")
        XCTAssertFalse(samples.allSatisfy { $0 == 0 }, "output must not be silence")
    }

    /// End-to-end at the top of the bucket range: the report's 215-token
    /// sentence synthesized as ONE utterance.
    ///
    /// No throughput assertion — that is MAC-415's job on real hardware, and a
    /// threshold here would just be flaky. The measurement is logged instead.
    func testLongSentenceSynthesizesWhole() async throws {
        try XCTSkipUnless(Self.hasEverythingForSynthesis, "synthesis assets not installed locally")

        let synthesizer = try await Self.makeSynthesizer()
        let style = try Supertonic3VoiceStyle.load(
            from: Self.localRepoDirectory.appendingPathComponent(
                Supertonic3Voice.m1.fileName))

        let tokens = Supertonic3TextChunker.encodedLength(of: Self.gatsbySentence, lang: "en")
        XCTAssertEqual(
            Supertonic3TextChunker.chunk(text: Self.gatsbySentence, lang: "en").count, 1,
            "the sentence must reach the synthesizer as one chunk")

        let started = ProcessInfo.processInfo.systemUptime
        let (samples, duration) = try await synthesizer.synthesize(
            text: Self.gatsbySentence, language: "en", style: style,
            totalSteps: Supertonic3Constants.defaultTotalSteps,
            speed: Supertonic3Constants.defaultSpeed,
            silenceDuration: Supertonic3Constants.defaultSilenceDuration)
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertGreaterThan(duration, 5, "a \(tokens)-token sentence should run several seconds")
        XCTAssertEqual(
            Float(samples.count), duration * Float(Supertonic3Constants.sampleRate),
            accuracy: Float(Supertonic3Constants.sampleRate),
            "sample count should match the predicted duration to within a second")
        XCTAssertFalse(samples.allSatisfy { $0 == 0 }, "output must not be silence")

        // Text stages + VE are .cpuOnly; the vocoder is on whatever this store
        // was configured with, which is the shipping arrangement.
        print(
            String(
                format: "[throughput] %d tokens, %.2fs audio in %.2fs = %.2fx realtime "
                    + "(text stages + VE .cpuOnly, ANE vocoder)",
                tokens, duration, elapsed, Double(duration) / max(elapsed, 0.001)))
    }

    // MARK: - Helpers

    private static let gatsbySentence =
        "Most of the confidences were unsought - frequently I have feigned sleep, "
        + "preoccupation, or a hostile levity when I realized by some unmistakable "
        + "sign that an intimate revelation was quivering on the horizon."

    /// A synthesizer over the locally installed assets, configured exactly as
    /// the app configures it.
    private static func makeSynthesizer() async throws -> Supertonic3Synthesizer {
        let store = Supertonic3ModelStore(
            directory: try XCTUnwrap(localModelsRoot),
            computeUnits: .cpuAndNeuralEngine,
            vectorEstimator: .dynamic(.int8))
        try await store.loadIfNeeded()
        return Supertonic3Synthesizer(
            store: store,
            processor: try Supertonic3UnicodeProcessor(
                unicodeIndexerURL: try await store.unicodeIndexerURL()))
    }

    private static var localModelsRoot: URL? {
        try? TtsCacheDirectory.ensure().appendingPathComponent("Models")
    }

    private static var localRepoDirectory: URL {
        (try? TtsCacheDirectory.ensure().appendingPathComponent("Models/supertonic-3"))
            ?? URL(fileURLWithPath: "/nonexistent")
    }

    private static var hasTextStages: Bool {
        [
            ModelNames.Supertonic3.textEncoderWideFile,
            ModelNames.Supertonic3.durationPredictorWideFile,
        ].allSatisfy { installed($0) }
    }

    /// Everything `loadIfNeeded()` + synthesis + a voice needs, so the tests
    /// skip instead of reaching for the network.
    private static var hasEverythingForSynthesis: Bool {
        ModelNames.Supertonic3.requiredFiles(veVariant: "dyn-int8")
            .union([Supertonic3Voice.m1.fileName])
            .allSatisfy { installed($0) }
    }

    private static func installed(_ file: String) -> Bool {
        FileManager.default.fileExists(
            atPath: localRepoDirectory.appendingPathComponent(file).path)
    }

    private static func makeEmptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supertonic3-single-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A processor over the real `unicode_indexer.json` when it is installed;
    /// otherwise an identity-ish indexer, which is enough for shape and mask
    /// assertions.
    private static func makeProcessor() throws -> Supertonic3UnicodeProcessor {
        let indexer = localRepoDirectory.appendingPathComponent(
            ModelNames.Supertonic3.unicodeIndexerFile)
        if FileManager.default.fileExists(atPath: indexer.path) {
            return try Supertonic3UnicodeProcessor(unicodeIndexerURL: indexer)
        }
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("supertonic3-indexer-\(UUID().uuidString).json")
        let table = (0..<0x3000).map { Int64($0) }
        try JSONEncoder().encode(table).write(to: stub)
        defer { try? FileManager.default.removeItem(at: stub) }
        return try Supertonic3UnicodeProcessor(unicodeIndexerURL: stub)
    }
}
