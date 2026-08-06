#if os(macOS)
import FluidAudio
import Foundation

/// Batch TTS→ASR roundtrip verification.
///
/// Reads a list of phrases from a file, synthesizes each one with the requested
/// TTS backend, transcribes the resulting WAV with Parakeet, computes per-phrase
/// and aggregate WER, and writes a JSON report.
///
/// Usage:
///   fluidaudio tts-asr-verify --backend kokoro-ane \
///       --texts-file phrases.txt \
///       --voice af_heart \
///       --output-json verify-results.json \
///       [--audio-dir /tmp/lai-wavs]
public enum TTSAsrVerifyCommand {

    private static let logger = AppLogger(category: "TTSAsrVerifyCommand")

    /// One synthesized phrase, normalized across backends so the verify loop
    /// stays backend-agnostic. `kokoro` carries the per-stage detail only the
    /// Kokoro chain reports; Supertonic leaves it `nil` rather than emitting
    /// zeroed fields that would read as real measurements.
    private struct Utterance: Sendable {
        let samples: [Float]
        let sampleRate: Int
        let kokoro: KokoroDetail?
    }

    private struct KokoroDetail: Sendable {
        let encoderTokens: Int
        let acousticFrames: Int
        let timings: KokoroAneStageTimings
    }

    public static func run(arguments: [String]) async {
        var backendName = "kokoro-ane"
        var textsFile: String?
        var voice: String = TtsConstants.recommendedVoice
        var outputJson: String?
        var audioDir: String?
        // Supertonic-3 knobs. Defaults mirror `Supertonic3Constants` so a bare
        // `--backend supertonic3` run matches what the app ships.
        var language = "en"
        var voiceStylePath: String?
        var totalSteps = Supertonic3Constants.defaultTotalSteps
        var speed = Supertonic3Constants.defaultSpeed
        var silence = Supertonic3Constants.defaultSilenceDuration
        var veVariant = Supertonic3VectorEstimator.default
        var veLabel = "default"

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--backend":
                if i + 1 < arguments.count {
                    backendName = arguments[i + 1]
                    i += 1
                }
            case "--texts-file":
                if i + 1 < arguments.count {
                    textsFile = arguments[i + 1]
                    i += 1
                }
            case "--voice":
                if i + 1 < arguments.count {
                    voice = arguments[i + 1]
                    i += 1
                }
            case "--output-json":
                if i + 1 < arguments.count {
                    outputJson = arguments[i + 1]
                    i += 1
                }
            case "--audio-dir":
                if i + 1 < arguments.count {
                    audioDir = arguments[i + 1]
                    i += 1
                }
            case "--language":
                if i + 1 < arguments.count {
                    language = arguments[i + 1].lowercased()
                    i += 1
                }
            case "--voice-style":
                if i + 1 < arguments.count {
                    voiceStylePath = arguments[i + 1]
                    i += 1
                }
            case "--total-steps":
                if i + 1 < arguments.count, let v = Int(arguments[i + 1]), v > 0 {
                    totalSteps = v
                    i += 1
                }
            case "--speed":
                if i + 1 < arguments.count, let v = Float(arguments[i + 1]), v > 0 {
                    speed = v
                    i += 1
                }
            case "--silence":
                if i + 1 < arguments.count, let v = Float(arguments[i + 1]), v >= 0 {
                    silence = v
                    i += 1
                }
            case "--ve-variant", "--vector-estimator":
                if i + 1 < arguments.count {
                    let raw = arguments[i + 1].lowercased()
                    if let v = Self.parseVectorEstimator(raw) {
                        veVariant = v
                        veLabel = raw
                    } else {
                        logger.warning(
                            "Unknown --ve-variant '\(raw)'; keeping the default (int8). "
                                + "Valid: fp16, int8, int6, int4.")
                    }
                    i += 1
                }
            case "--help", "-h":
                printUsage()
                return
            default:
                logger.warning("Unknown argument: \(arg)")
            }
            i += 1
        }

        guard let textsFile else {
            logger.error("--texts-file is required")
            printUsage()
            exit(1)
        }

        let phrases: [String]
        do {
            phrases = try readPhrases(from: textsFile)
        } catch {
            logger.error("Failed to read texts file: \(error.localizedDescription)")
            exit(1)
        }
        guard !phrases.isEmpty else {
            logger.error("No phrases found in \(textsFile)")
            exit(1)
        }
        logger.info("Loaded \(phrases.count) phrase(s) from \(textsFile)")

        let backend = parseBackend(backendName)
        guard backend == .kokoroAne || backend == .supertonic3 else {
            logger.error(
                "tts-asr-verify supports --backend kokoro-ane or supertonic3 "
                    + "(got '\(backendName)')")
            exit(1)
        }

        do {
            // Set up TTS once. Both branches resolve a voice and hand back a
            // synthesizer closure; everything downstream is backend-agnostic.
            let resolvedVoice: String
            let synthesize: @Sendable (String) async throws -> Utterance

            switch backend {
            case .supertonic3:
                // Immutable copies so the synthesizer closure can be @Sendable.
                let stLanguage = language
                let stTotalSteps = totalSteps
                let stSpeed = speed
                let stSilence = silence

                let manager = Supertonic3Manager(vectorEstimator: veVariant)
                try await manager.initialize()

                // An explicit --voice-style <path> wins; otherwise --voice
                // names a built-in preset (F1-F5, M1-M5), defaulting to M1.
                let style: Supertonic3VoiceStyle
                if let voiceStylePath {
                    style = try Supertonic3VoiceStyle.load(
                        from: resolveURL(voiceStylePath, isDirectory: false))
                    resolvedVoice = voiceStylePath
                } else {
                    let selected = Supertonic3Voice(name: voice) ?? .default
                    if Supertonic3Voice(name: voice) == nil,
                        voice != TtsConstants.recommendedVoice
                    {
                        logger.warning(
                            "Unknown Supertonic-3 voice '\(voice)'; using "
                                + "\(Supertonic3Voice.default.rawValue).")
                    }
                    style = try await Supertonic3ResourceDownloader.loadVoiceStyle(selected)
                    resolvedVoice = selected.rawValue
                }

                guard Supertonic3Constants.availableLanguages.contains(stLanguage) else {
                    logger.error("Supertonic-3 does not support language '\(stLanguage)'")
                    exit(1)
                }

                logger.info(
                    "Supertonic-3 initialized (voice=\(resolvedVoice) lang=\(stLanguage) "
                        + "steps=\(stTotalSteps) speed=\(String(format: "%.2f", stSpeed)) "
                        + "silence=\(String(format: "%.2f", stSilence))s "
                        + "ve=\(veLabel) "
                        + "window=\(Supertonic3Constants.textTFixed) tokens)")

                synthesize = { phrase in
                    let result = try await manager.synthesize(
                        text: phrase, language: stLanguage, style: style,
                        totalSteps: stTotalSteps, speed: stSpeed,
                        silenceDuration: stSilence)
                    return Utterance(
                        samples: result.samples,
                        sampleRate: Supertonic3Constants.sampleRate,
                        kokoro: nil)
                }

            default:
                let kokoroVoice =
                    voice == TtsConstants.recommendedVoice
                    ? KokoroAneConstants.defaultVoice : voice
                let manager = KokoroAneManager(defaultVoice: kokoroVoice)
                try await manager.initialize()
                resolvedVoice = kokoroVoice
                logger.info("KokoroAne initialized (voice=\(kokoroVoice))")

                synthesize = { phrase in
                    let detailed = try await manager.synthesizeDetailed(
                        text: phrase, voice: kokoroVoice, speed: 1.0)
                    return Utterance(
                        samples: detailed.samples,
                        sampleRate: detailed.sampleRate,
                        kokoro: KokoroDetail(
                            encoderTokens: detailed.encoderTokens,
                            acousticFrames: detailed.acousticFrames,
                            timings: detailed.timings))
                }
            }

            // Set up ASR once.
            let asrModels = try await AsrModels.downloadAndLoad()
            let asr = AsrManager()
            try await asr.loadModels(asrModels)
            let decoderLayers = await asr.decoderLayerCount

            // Optional audio output directory.
            var audioDirURL: URL? = nil
            if let audioDir {
                let url = resolveURL(audioDir, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true)
                audioDirURL = url
            }

            // Iterate phrases.
            var perPhrase: [[String: Any]] = []
            var totalAudioS = 0.0
            var totalSynthS = 0.0
            var totalAsrS = 0.0
            var werValues: [Double] = []
            var totalRefWords = 0
            var totalEditDistance = 0
            var totalRefSentenceEnds = 0
            var totalHypSentenceEnds = 0

            for (idx, phrase) in phrases.enumerated() {
                let label = String(format: "[%02d/%02d]", idx + 1, phrases.count)
                logger.info("\(label) Synthesizing: \(phrase)")

                let synth0 = Date()
                let utterance = try await synthesize(phrase)
                let wav = try AudioWAV.data(
                    from: utterance.samples, sampleRate: Double(utterance.sampleRate))
                let synthS = Date().timeIntervalSince(synth0)

                // Persist WAV (audioDir if set, else temp file).
                let wavURL: URL
                if let audioDirURL {
                    wavURL = audioDirURL.appendingPathComponent(
                        String(format: "phrase_%03d.wav", idx + 1))
                } else {
                    wavURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("tts-asr-verify-\(UUID().uuidString).wav")
                }
                try wav.write(to: wavURL)

                let audioS = Double(utterance.samples.count) / Double(utterance.sampleRate)

                // Transcribe.
                let asr0 = Date()
                var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
                let transcription = try await asr.transcribe(
                    wavURL, decoderState: &decoderState)
                let asrS = Date().timeIntervalSince(asr0)

                // WER.
                let m = WERCalculator.calculateWERMetrics(
                    hypothesis: transcription.text, reference: phrase)
                werValues.append(m.wer)
                totalRefWords += m.totalWords
                totalEditDistance += m.insertions + m.deletions + m.substitutions
                totalAudioS += audioS
                totalSynthS += synthS
                totalAsrS += asrS

                // Seam signal. A chunker that ends a fragment mid-clause makes
                // the model perform a full stop there, and the transcriber
                // duly writes one — so the hypothesis carries more sentence
                // endings than the reference. WER cannot see this (the words
                // survive), which is why it is tracked separately.
                let refEnds = sentenceEndCount(phrase)
                let hypEnds = sentenceEndCount(transcription.text)
                totalRefSentenceEnds += refEnds
                totalHypSentenceEnds += hypEnds

                logger.info("  ref: \(phrase)")
                logger.info("  hyp: \(transcription.text)")
                logger.info(
                    String(
                        format: "  wer=%.1f%%  ends=%d/%d (%+d)  audio=%.2fs  synth=%.2fs  asr=%.2fs",
                        m.wer * 100, hypEnds, refEnds, hypEnds - refEnds, audioS, synthS, asrS))

                if audioDirURL == nil {
                    try? FileManager.default.removeItem(at: wavURL)
                }

                var entry: [String: Any] = [
                    "index": idx + 1,
                    "reference": phrase,
                    "hypothesis": transcription.text,
                    "wer": m.wer,
                    "insertions": m.insertions,
                    "deletions": m.deletions,
                    "substitutions": m.substitutions,
                    "ref_word_count": m.totalWords,
                    "ref_char_count": phrase.count,
                    "ref_sentence_ends": refEnds,
                    "hyp_sentence_ends": hypEnds,
                    "excess_sentence_ends": hypEnds - refEnds,
                    "audio_s": audioS,
                    "synth_s": synthS,
                    "asr_s": asrS,
                    "wav_path": audioDirURL == nil ? "" : wavURL.path,
                ]
                if let k = utterance.kokoro {
                    entry["encoder_tokens"] = k.encoderTokens
                    entry["acoustic_frames"] = k.acousticFrames
                    entry["stage_timings_ms"] = [
                        "albert": k.timings.albert,
                        "post_albert": k.timings.postAlbert,
                        "alignment": k.timings.alignment,
                        "prosody": k.timings.prosody,
                        "noise": k.timings.noise,
                        "vocoder": k.timings.vocoder,
                        "tail": k.timings.tail,
                        "total": k.timings.totalMs,
                    ]
                }
                perPhrase.append(entry)
            }

            await asr.cleanup()

            // Aggregate.
            let macroWer =
                werValues.isEmpty
                ? 0.0 : werValues.reduce(0, +) / Double(werValues.count)
            let microWer =
                totalRefWords == 0
                ? 0.0 : Double(totalEditDistance) / Double(totalRefWords)
            let rtfx = totalSynthS > 0 ? totalAudioS / totalSynthS : 0
            let excessEnds = totalHypSentenceEnds - totalRefSentenceEnds
            let spuriousRate =
                totalRefSentenceEnds == 0
                ? 0.0 : Double(excessEnds) / Double(totalRefSentenceEnds)

            logger.info("--- Summary ---")
            logger.info("  phrases: \(phrases.count)")
            logger.info(String(format: "  macro WER: %.2f%%", macroWer * 100))
            logger.info(String(format: "  micro WER: %.2f%%", microWer * 100))
            logger.info(
                String(
                    format: "  sentence ends: %d heard vs %d written (%+d, %+.0f%%)",
                    totalHypSentenceEnds, totalRefSentenceEnds, excessEnds,
                    spuriousRate * 100))
            logger.info(String(format: "  total audio: %.2fs", totalAudioS))
            logger.info(String(format: "  total synth: %.2fs (RTFx %.2fx)", totalSynthS, rtfx))
            logger.info(String(format: "  total asr:   %.2fs", totalAsrS))

            // Write JSON.
            if let outputJson {
                var summary: [String: Any] = [
                    "backend": backendName,
                    "voice": resolvedVoice,
                    "phrase_count": phrases.count,
                    "macro_wer": macroWer,
                    "micro_wer": microWer,
                    "total_audio_s": totalAudioS,
                    "total_synth_s": totalSynthS,
                    "total_asr_s": totalAsrS,
                    "realtime_speed": rtfx,
                    "ref_sentence_ends": totalRefSentenceEnds,
                    "hyp_sentence_ends": totalHypSentenceEnds,
                    "excess_sentence_ends": excessEnds,
                    "spurious_boundary_rate": spuriousRate,
                ]
                if backend == .supertonic3 {
                    // Chunking is what this backend is usually being measured
                    // for, so record the knobs that change where seams land.
                    summary["language"] = language
                    summary["total_steps"] = totalSteps
                    summary["speed"] = speed
                    summary["silence_s"] = silence
                    summary["max_chunk_tokens"] = Supertonic3Constants.textTFixed
                }
                let report: [String: Any] = [
                    "summary": summary,
                    "phrases": perPhrase,
                ]
                let url = resolveURL(outputJson, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let data = try JSONSerialization.data(
                    withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url)
                logger.info("Report written: \(url.path)")
            }
        } catch {
            logger.error("tts-asr-verify failed: \(error)")
            exit(1)
        }
    }

    // MARK: - Helpers

    private static func parseBackend(_ name: String) -> TtsBackend {
        switch name.lowercased() {
        case "pocket", "pockettts", "pocket-tts": return .pocketTts
        case "supertonic3", "supertonic-3", "sup3", "supertonic": return .supertonic3
        case "kokoro-ane", "kokoroane", "kokoro", "lai": return .kokoroAne
        default: return .kokoroAne
        }
    }

    /// Map a `--ve-variant` token to a `Supertonic3VectorEstimator`. Mirrors
    /// `TTSCommand.parseSupertonicVE` so both commands accept the same spelling.
    private static func parseVectorEstimator(_ raw: String) -> Supertonic3VectorEstimator? {
        switch raw {
        case "fp16", "fp16dynamic": return .fp16Dynamic
        case "default", "": return .default
        case "int8", "int6", "int4", "dyn-int8", "dyn-int6", "dyn-int4":
            return Supertonic3Quantization(rawValue: String(raw.split(separator: "-").last!))
                .map { .dynamic($0) }
        default: return nil
        }
    }

    /// Count sentence-terminal punctuation. Approximate by design — it does
    /// not special-case abbreviations or decimals, so corpora meant for this
    /// metric should avoid them (see `Benchmarks/Supertonic3`). Comparing the
    /// same corpus before and after a change keeps that bias constant.
    private static func sentenceEndCount(_ text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if character == "." || character == "!" || character == "?" || character == "…" {
                count += 1
            }
        }
    }

    private static func readPhrases(from path: String) throws -> [String] {
        let url = resolveURL(path, isDirectory: false)
        let raw = try String(contentsOf: url, encoding: .utf8)
        return raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func resolveURL(_ path: String, isDirectory: Bool) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: isDirectory)
        }
        let cwd = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return cwd.appendingPathComponent(expanded, isDirectory: isDirectory)
    }

    private static func printUsage() {
        print(
            """
            Usage: fluidaudio tts-asr-verify --texts-file phrases.txt [options]

            Reads phrases (one per line, '#' comments ignored), synthesizes each
            with the chosen TTS backend, transcribes with Parakeet, computes
            per-phrase + aggregate WER, and writes a JSON report.

            Options:
              --backend <name>      TTS backend: kokoro-ane (default) | supertonic3
              --texts-file <path>   Phrases file (required)
              --voice <name>        Voice name (kokoro: af_heart; supertonic: M1)
              --output-json <path>  Output JSON report path
              --audio-dir <path>    Optional dir to keep generated WAVs
              --help, -h            Show this help

            Supertonic-3 only:
              --language <code>     ISO language code (default: en)
              --voice-style <path>  Voice style JSON; overrides --voice
              --total-steps <n>     Denoising steps (default: 8)
              --speed <x>           Speed multiplier (default: 1.05)
              --silence <s>         Inter-chunk silence seconds (default: 0.05)
              --ve-variant <name>   VectorEstimator precision: fp16 | int8
                                    (default) | int6 | int4

            Example:
              fluidaudio tts-asr-verify \\
                  --backend supertonic3 \\
                  --texts-file paragraphs.txt \\
                  --voice M1 \\
                  --output-json verify-results.json

            Note: Supertonic-3 caps chunks at 70 characters (57 for CJK), so a
            corpus of long paragraphs measures the multi-chunk seam path while
            short phrases measure the single-chunk path. Run both.
            """
        )
    }
}
#endif
