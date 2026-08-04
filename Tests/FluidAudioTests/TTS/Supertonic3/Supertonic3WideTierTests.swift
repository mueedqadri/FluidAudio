@preconcurrency import CoreML
import XCTest

@testable import FluidAudio

/// Covers the long-sentence tier's sizing math, asset naming, encoder
/// parameterization, and — the part that matters most — that an absent tier
/// reports itself as absent instead of failing.
final class Supertonic3WideTierTests: XCTestCase {

    // MARK: - Bucket selection

    func testWideBucketPicksSmallestThatHolds() {
        let bucket = Supertonic3Constants.wideTextBucket(forTokenLength:)
        XCTAssertEqual(bucket(129), 192)
        XCTAssertEqual(bucket(192), 192)
        XCTAssertEqual(bucket(193), 256)
        XCTAssertEqual(bucket(256), 256)
        XCTAssertEqual(bucket(257), 320)
        XCTAssertEqual(bucket(320), 320)
    }

    func testWideBucketIsNilPastTheCeiling() {
        XCTAssertNil(Supertonic3Constants.wideTextBucket(forTokenLength: 321))
        XCTAssertNil(Supertonic3Constants.wideTextBucket(forTokenLength: 1_000))
    }

    /// Sizing is not routing: a tier-1 length still reports a wide bucket, and
    /// the caller is the one that checks `> textTFixed` first.
    func testWideBucketAnswersForTierOneLengthsToo() {
        XCTAssertEqual(Supertonic3Constants.wideTextBucket(forTokenLength: 1), 192)
        XCTAssertEqual(
            Supertonic3Constants.wideTextBucket(
                forTokenLength: Supertonic3Constants.textTFixed), 192)
    }

    func testCeilingIsTheLargestPublishedBucket() {
        XCTAssertEqual(Supertonic3Constants.wideTextBuckets.last, Supertonic3Constants.tierCeiling)
        XCTAssertEqual(
            Supertonic3Constants.wideTextBuckets, Supertonic3Constants.wideTextBuckets.sorted())
        XCTAssertTrue(
            Supertonic3Constants.wideTextBuckets.allSatisfy {
                $0 > Supertonic3Constants.textTFixed
            })
    }

    // MARK: - Asset naming

    func testWideStageFileNames() {
        XCTAssertEqual(ModelNames.Supertonic3.textEncoderWideFile, "TextEncoderWide.mlmodelc")
        XCTAssertEqual(
            ModelNames.Supertonic3.durationPredictorWideFile, "DurationPredictorWide.mlmodelc")
    }

    func testWideFunctionNamesPerBucket() {
        XCTAssertEqual(ModelNames.Supertonic3.textEncoderFunction(bucket: 192), "text_t192")
        XCTAssertEqual(ModelNames.Supertonic3.textEncoderFunction(bucket: 256), "text_t256")
        XCTAssertEqual(ModelNames.Supertonic3.textEncoderFunction(bucket: 320), "text_t320")
        XCTAssertEqual(
            ModelNames.Supertonic3.durationPredictorFunction(bucket: 192), "duration_t192")
        XCTAssertEqual(
            ModelNames.Supertonic3.durationPredictorFunction(bucket: 320), "duration_t320")
    }

    /// The tier is optional, so its assets must never enter the required set —
    /// otherwise a repo without them would re-download on every launch.
    func testWideStagesAreNotRequiredForAnyDownloadVariant() {
        for variant in [nil, "dyn-int8", "ane-int8", "ane-int4"] {
            let required = ModelNames.Supertonic3.requiredFiles(veVariant: variant)
            for file in ModelNames.Supertonic3.wideTextStageFiles {
                XCTAssertFalse(
                    required.contains(file),
                    "\(file) must stay optional (variant \(variant ?? "fp16"))")
            }
        }
    }

    /// Tier 2's VectorEstimator is the dynamic int8 build already published in
    /// our upstream repo — not a bucketed one.
    func testDynamicInt8VectorEstimatorPath() {
        XCTAssertEqual(
            ModelNames.Supertonic3.vectorEstimatorFile(precisionSuffix: "int8", bucket: nil),
            "VectorEstimatorVariants/VectorEstimator_int8.mlmodelc")
    }

    // MARK: - Encoder parameterization

    func testEncodeDefaultsToThePinnedWindow() throws {
        let processor = try Self.makeProcessor()
        let (ids, mask) = try processor.encode(texts: ["Hello there."], languages: ["en"])
        XCTAssertEqual(ids[0].count, Supertonic3Constants.textTFixed)
        XCTAssertEqual(mask[0][0].count, Supertonic3Constants.textTFixed)
    }

    func testEncodePadsToAWideBucket() throws {
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
        XCTAssertEqual(Array(mask[0][0].suffix(from: scalars)), [Float](repeating: 0, count: 256 - scalars))
        // Padding is zero ids, and the leading ids are unchanged from tier 1.
        let (tier1Ids, _) = try processor.encode(texts: [text], languages: ["en"])
        XCTAssertEqual(Array(ids[0].prefix(scalars)), Array(tier1Ids[0].prefix(scalars)))
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

    // MARK: - Graceful absence

    func testMissingWideStageReportsTierUnavailable() throws {
        let empty = try Self.makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertFalse(Supertonic3ModelStore.hasWideTextStages(in: empty))

        for (file, function) in [
            (ModelNames.Supertonic3.textEncoderWideFile, "text_t192"),
            (ModelNames.Supertonic3.durationPredictorWideFile, "duration_t192"),
        ] {
            do {
                _ = try Supertonic3ModelStore.loadTier2Model(
                    repoDir: empty, fileName: file, functionName: function)
                XCTFail("\(file) should not load out of an empty directory")
            } catch Supertonic3Error.tierUnavailable(let reason) {
                XCTAssertTrue(reason.contains(file), "reason should name the asset: \(reason)")
            }
        }
    }

    func testMissingDynamicVectorEstimatorReportsTierUnavailable() throws {
        let empty = try Self.makeEmptyDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }

        do {
            _ = try Supertonic3ModelStore.loadTier2Model(
                repoDir: empty,
                fileName: ModelNames.Supertonic3.vectorEstimatorFile(
                    precisionSuffix: "int8", bucket: nil),
                functionName: nil)
            XCTFail("the dynamic VectorEstimator should not load out of an empty directory")
        } catch Supertonic3Error.tierUnavailable {
            // Expected.
        }
    }

    func testTokenLengthPastCeilingReportsTierUnavailable() async throws {
        let store = Supertonic3ModelStore(directory: try Self.makeEmptyDirectory())
        do {
            _ = try await store.wideTextStages(forTokenLength: 321)
            XCTFail("321 tokens is past the ceiling and has no bucket")
        } catch Supertonic3Error.tierUnavailable(let reason) {
            XCTAssertTrue(reason.contains("321"), reason)
        }
    }

    /// Before `loadIfNeeded()` there is no repo directory to look in, and that
    /// is a different failure from an absent tier.
    func testTierAccessorsRequireInitializationFirst() async throws {
        let store = Supertonic3ModelStore(directory: try Self.makeEmptyDirectory())
        do {
            _ = try await store.wideTextStages(forTokenLength: 200)
            XCTFail("expected .notInitialized")
        } catch Supertonic3Error.notInitialized {
            // Expected.
        }
        do {
            _ = try await store.dynamicVectorEstimator()
            XCTFail("expected .notInitialized")
        } catch Supertonic3Error.notInitialized {
            // Expected.
        }
    }

    // MARK: - Real assets (skipped when not installed locally)

    func testDynamicVectorEstimatorLoadsCPUOnlyWhenInstalled() throws {
        let repoDir = Self.localRepoDirectory
        let file = ModelNames.Supertonic3.vectorEstimatorFile(precisionSuffix: "int8", bucket: nil)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: repoDir.appendingPathComponent(file).path),
            "\(file) not installed in the local cache")

        let model = try Supertonic3ModelStore.loadTier2Model(
            repoDir: repoDir, fileName: file, functionName: nil)
        XCTAssertNotNil(model.modelDescription.inputDescriptionsByName["noisy_latent"])
        XCTAssertNotNil(model.modelDescription.inputDescriptionsByName["current_step"])
    }

    func testWideStagesLoadPerBucketWhenInstalled() throws {
        let repoDir = Self.localRepoDirectory
        try XCTSkipUnless(
            Supertonic3ModelStore.hasWideTextStages(in: repoDir),
            "wide text stages not installed in the local cache")

        for bucket in Supertonic3Constants.wideTextBuckets {
            let encoder = try Supertonic3ModelStore.loadTier2Model(
                repoDir: repoDir,
                fileName: ModelNames.Supertonic3.textEncoderWideFile,
                functionName: ModelNames.Supertonic3.textEncoderFunction(bucket: bucket))
            let ids = encoder.modelDescription.inputDescriptionsByName["text_ids"]
            XCTAssertEqual(
                ids?.multiArrayConstraint?.shape.map(\.intValue), [1, bucket],
                "text_t\(bucket) should declare a [1, \(bucket)] text axis")
            XCTAssertEqual(
                ids?.multiArrayConstraint?.dataType, .int32,
                "text_ids is Int32 — the synthesizer binds Int32 for both tiers")

            let predictor = try Supertonic3ModelStore.loadTier2Model(
                repoDir: repoDir,
                fileName: ModelNames.Supertonic3.durationPredictorWideFile,
                functionName: ModelNames.Supertonic3.durationPredictorFunction(bucket: bucket))
            XCTAssertNotNil(predictor.modelDescription.outputDescriptionsByName["duration"])
        }
    }

    /// The wide stages declare `style_ttl` and `text_mask` as **fp16**, where
    /// our own stages declare fp32 — and the synthesizer binds Float32 for both.
    /// The Python harness casts to fp16 by hand, so whether CoreML's Swift API
    /// converts on our behalf is the one binding question tier 2 raises. It
    /// does; this test is what says so.
    func testWideEncoderAcceptsOurFloat32Bindings() throws {
        let repoDir = Self.localRepoDirectory
        try XCTSkipUnless(
            Supertonic3ModelStore.hasWideTextStages(in: repoDir),
            "wide text stages not installed in the local cache")

        let bucket = Supertonic3Constants.tierCeiling
        let encoder = try Supertonic3ModelStore.loadTier2Model(
            repoDir: repoDir,
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

    /// End-to-end proof that the tier-2 branch runs: the report's 215-token
    /// sentence synthesized as ONE utterance through the wide stages and the
    /// dynamic VectorEstimator, all `.cpuOnly`.
    ///
    /// No throughput assertion — that is [MAC-409]'s job on real hardware, and
    /// a threshold here would just be flaky. The measurement is logged instead.
    func testLongSentenceSynthesizesThroughTierTwo() async throws {
        let modelsRoot = try XCTUnwrap(Self.localModelsRoot)
        try XCTSkipUnless(
            Self.hasEverythingForTierTwoSynthesis, "tier-2 synthesis assets not installed locally")

        let store = Supertonic3ModelStore(
            directory: modelsRoot, computeUnits: .cpuAndNeuralEngine,
            vectorEstimator: .aneBucketed(.int8))
        try await store.loadIfNeeded()
        let tierAvailable = await store.isWideTierAvailable()
        XCTAssertTrue(tierAvailable)

        let processor = try Supertonic3UnicodeProcessor(
            unicodeIndexerURL: try await store.unicodeIndexerURL())
        let synthesizer = Supertonic3Synthesizer(store: store, processor: processor)
        let style = try Supertonic3VoiceStyle.load(
            from: Self.localRepoDirectory.appendingPathComponent(
                Supertonic3Voice.m1.fileName))

        let sentence =
            "Most of the confidences were unsought - frequently I have feigned sleep, "
            + "preoccupation, or a hostile levity when I realized by some unmistakable "
            + "sign that an intimate revelation was quivering on the horizon."
        let tokens = Supertonic3TextChunker.encodedLength(of: sentence, lang: "en")
        XCTAssertEqual(
            Supertonic3TextChunker.chunk(text: sentence, lang: "en").count, 1,
            "the sentence must reach the synthesizer as one chunk")

        let started = ProcessInfo.processInfo.systemUptime
        let (samples, duration) = try await synthesizer.synthesize(
            text: sentence, language: "en", style: style,
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

        // Wide text stages + dynamic VE are .cpuOnly; the vocoder is the shared
        // tier-1 instance on whatever this store was configured with, which is
        // the shipping arrangement. Not a pure-CPU figure, deliberately.
        print(
            String(
                format: "[MAC-409 datapoint] tier 2, %d tokens, %.2fs audio in %.2fs "
                    + "= %.2fx realtime (text stages + VE .cpuOnly, shared vocoder as configured)",
                tokens, duration, elapsed, Double(duration) / max(elapsed, 0.001)))
    }

    // MARK: - Helpers

    private static var localModelsRoot: URL? {
        try? TtsCacheDirectory.ensure().appendingPathComponent("Models")
    }

    /// Everything `loadIfNeeded()` + tier 2 + a voice needs, so the test skips
    /// instead of reaching for the network.
    private static var hasEverythingForTierTwoSynthesis: Bool {
        let repoDir = localRepoDirectory
        let dynamicVE = ModelNames.Supertonic3.vectorEstimatorFile(
            precisionSuffix: "int8", bucket: nil)
        let needed =
            ModelNames.Supertonic3.requiredFiles(veVariant: "ane-int8")
            .union(ModelNames.Supertonic3.wideTextStageFiles)
            .union([dynamicVE, Supertonic3Voice.m1.fileName])
        return needed.allSatisfy { file in
            FileManager.default.fileExists(atPath: repoDir.appendingPathComponent(file).path)
        }
    }

    private static var localRepoDirectory: URL {
        (try? TtsCacheDirectory.ensure().appendingPathComponent("Models/supertonic-3"))
            ?? URL(fileURLWithPath: "/nonexistent")
    }

    private static func makeEmptyDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supertonic3-wide-tier-\(UUID().uuidString)")
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
