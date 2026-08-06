import Foundation

/// Compile-time constants for the Supertonic-3 multilingual TTS pipeline.
///
/// Mirrors the hyperparameters published in the upstream `tts.json` and the
/// reference inference flow in
/// `https://github.com/supertone-inc/supertonic/blob/main/swift/Sources/Helper.swift`.
///
/// Supertonic-3 ships four ONNX models (text_encoder, duration_predictor,
/// vector_estimator, vocoder) totalling ~398 MB. FluidAudio re-publishes those
/// models as `.mlmodelc` bundles under
/// `FluidInference/supertonic-3-coreml`; see
/// `Scripts/convert_supertonic3_to_coreml.py` for the conversion recipe.
public enum Supertonic3Constants {

    // MARK: - Audio

    /// Vocoder output sample rate. 44.1 kHz mono Float32.
    public static let sampleRate: Int = 44_100

    // MARK: - Latent / chunking

    /// Base chunk size (samples) of the acoustic autoencoder. Drives the
    /// `latent_len = ceil(wav_len / (base_chunk_size * chunk_compress_factor))`
    /// calculation for the denoising loop. Matches `ae.base_chunk_size` in
    /// the published `tts.json` (Supertonic-3 v1.7.3).
    public static let baseChunkSize: Int = 512

    /// Chunk-compress factor used by the text-to-latent module. The flattened
    /// latent dimension passed to `vector_estimator` is
    /// `latent_dim * chunk_compress_factor`. Matches `ttl.chunk_compress_factor`.
    public static let chunkCompressFactor: Int = 6

    /// Per-chunk latent dimensionality before applying `chunk_compress_factor`.
    /// Matches `ttl.latent_dim` (== `ae.ldim`) in the published config.
    public static let latentDim: Int = 24

    /// Style token count expected by the text-to-latent style encoder
    /// (`style_ttl` shape is `[bsz, ttlStyleTokens, ttlStyleDim]`).
    public static let ttlStyleTokens: Int = 50

    /// Style embedding dim for `style_ttl` (matches `style_value_dim`).
    public static let ttlStyleDim: Int = 256

    /// Style token count expected by the duration-predictor style encoder
    /// (`style_dp` shape is `[bsz, dpStyleTokens, dpStyleDim]`).
    public static let dpStyleTokens: Int = 8

    /// Style embedding dim for `style_dp` (matches `dp.style_token_layer.style_value_dim`).
    public static let dpStyleDim: Int = 16

    /// Text-encoder output channel count fed into `vector_estimator.text_emb`.
    public static let textEmbDim: Int = 256

    /// Packing cap, in encoded tokens, for a chunk that holds more than one
    /// sentence — and the width the synthesizer re-splits at when a chunk
    /// overruns `dynamicLatentSlotCeiling`.
    ///
    /// Not a routing boundary: every chunk takes the same path regardless of
    /// length. 128 is kept because it is the granularity narration wants —
    /// highlighting, cache keys and seek all key off a chunk — not because any
    /// model requires it. (It was `TEXT_T_FIXED = 128` in the reference Python
    /// driver, whose text axis really was frozen there.)
    public static let textTFixed: Int = 128

    /// Text-axis lengths published by `TextEncoderWide` / `DurationPredictorWide`
    /// — one multi-function bundle per stage, one CoreML function per bucket.
    /// A chunk is padded up to the smallest bucket that holds it, and the mask
    /// tells the stage where the text actually ends.
    ///
    /// These bundles are the *only* text stages the pipeline loads. The narrow
    /// T128 export they replaced was frozen at 128 tokens, and **34.9%** of
    /// sentences do not fit that (measured over all 2,601 sentences of Gatsby);
    /// every one of those was split mid-sentence, which is heard as an invented
    /// sentence ending. Split rate by window on the same corpus: 128 → 34.9%,
    /// 192 → 12.3%, 256 → 4.0%, 320 → ~1%.
    ///
    /// Everything here runs `.cpuOnly` on both platforms. The ANE is not an
    /// option and not a loss: its fixed shapes are what froze the text axis in
    /// the first place, iOS refuses these programs outright once the app is
    /// backgrounded (see `Supertonic3ModelStore`), and the all-CPU chain still
    /// measures 10–37× realtime on an A15 against the 1× playback needs. The
    /// vocoder alone stays on the ANE — its single-block program is the one
    /// iOS keeps granting in the background.
    ///
    /// `text_t16` is published but deliberately **not** listed: the
    /// VectorEstimator's `text_emb` / `text_mask` axes are RangeDims starting
    /// at `dynamicAxisFloor`, so a 16-wide embedding fails the bind. 32 is the
    /// smallest bucket the chain as a whole can run.
    public static let wideTextBuckets: [Int] = [32, 64, 128, 192, 256, 320]

    /// Largest sentence, in encoded tokens, that is synthesized whole (the
    /// largest published bucket). The 99th percentile sentence is ≈334 tokens,
    /// so roughly 1% of sentences still clause-split — into pieces that each
    /// fit, rather than into whatever the budget allowed.
    public static let tierCeiling: Int = 320

    /// Smallest published bucket that holds `tokenLength`, or `nil` when no
    /// bucket does (i.e. past `tierCeiling`, which the chunker splits before).
    public static func wideTextBucket(forTokenLength tokenLength: Int) -> Int? {
        wideTextBuckets.first { $0 >= tokenLength }
    }

    /// Upper bound, in latent slots, of the dynamic-shape stages.
    /// The published RangeDims are `[17, 512]` on the dynamic VectorEstimator's
    /// latent axes and `[4, 512]` on the vocoder's. One slot is
    /// `ae.base_chunk_size × ttl.chunk_compress_factor` samples — 512 × 6 =
    /// 3,072 at 44.1 kHz — so 512 slots is ≈35.7 s of audio.
    ///
    /// Reachable, because duration is divided by the speed parameter: a
    /// sentence near `tierCeiling` runs ≈19.5 s at 1× and crosses the window
    /// below ≈0.55×, well inside the 0.5× a playback UI offers. The
    /// synthesizer guards against this bound and throws `.tierUnavailable`,
    /// which re-splits the sentence at `textTFixed` and synthesizes the pieces
    /// through the same path — degrading to a seam instead of failing the
    /// prediction with an opaque CoreML shape error.
    public static let dynamicLatentSlotCeiling: Int = 512

    /// Lower bound of **every** RangeDim axis on the dynamic VectorEstimator —
    /// the `17` of its published `[17, 512]`, on the latent axis
    /// (`noisy_latent`, `latent_mask`) and the text axis (`text_emb`,
    /// `text_mask`) alike. ≈1.18 s of audio on the latent side.
    ///
    /// Both ends are reachable and both were measured, because bucket padding
    /// used to hide them:
    ///
    /// - *Text axis.* `text_t16` exists in the bundles but produces a 16-wide
    ///   embedding the VectorEstimator refuses, which is why
    ///   `wideTextBuckets` starts at 32.
    /// - *Latent axis.* `"Yes."` predicts 16 slots. CoreML rejects the bind
    ///   ("Size (16) of dimension (2) is not in allowed range (17..512)"), so
    ///   the synthesizer pads the latent and its mask up to
    ///   `minimumLatentSlots` (which clears this bound as well) and trims back
    ///   before the vocoder, whose own floor is 4.
    public static let dynamicAxisFloor: Int = 17

    /// Latent length the synthesizer pads up to before running the
    /// VectorEstimator. Both a correctness bound (it clears `dynamicAxisFloor`)
    /// and, far more expensively, a **performance** one.
    ///
    /// The int8 VectorEstimator's CPU kernel is tiled 32 wide on the latent
    /// axis. Below that it drops to a fallback whose cost *grows* as the input
    /// shrinks — measured per denoising step, M-series, text axis held at 64
    /// (which is itself flat from 17 to 128, so the text axis is not involved):
    ///
    /// | latent | 17 | 22 | 27 | 31 | **32** | 40 | 64 | 128 |
    /// | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    /// | ms/step | 76 | 257 | 430 | 577 | **12** | 14 | 15 | 26 |
    ///
    /// A 31-slot latent costs 47× what a 32-slot one does. Left unpadded, a
    /// short paragraph — the common case for dialogue, headings and list items
    /// — synthesized at **0.7× realtime**, i.e. slower than playback, while a
    /// full sentence ran at 18×. The pad is masked out and trimmed off, so it
    /// changes nothing but the speed.
    public static let minimumLatentSlots: Int = 32

    /// Lower bound of the vocoder's own latent RangeDim, `[4, 512]` — a
    /// separate, looser bound than the VectorEstimator's, and the reason the
    /// trim back down from `minimumLatentSlots` has a floor of its own.
    ///
    /// Reachable: duration is clamped to `max(0.05, predicted / speed)`, and
    /// 0.05 s is a single latent slot. A short chunk at a fast rate lands
    /// under 4 — measured, `"7."` at 6× gives exactly 4 and at 8× gives 3,
    /// which CoreML rejects ("Size (3) of dimension (2) is not in allowed
    /// range (4..512)") and the caller sees as a failed vocoder stage. PDF
    /// headings are isolated into their own chunks, so one- and two-token
    /// chunks are ordinary input, not a corner case.
    ///
    /// Padding to it is free: the waveform is trimmed to the predicted
    /// duration afterwards, which discards the extra samples anyway.
    public static let vocoderMinimumLatentSlots: Int = 4

    // MARK: - Inference

    /// Default number of denoising steps for the vector_estimator loop. The
    /// reference CLI ships 8; lower values trade quality for latency.
    public static let defaultTotalSteps: Int = 8

    /// Default global speed factor applied to the predicted duration vector
    /// (`duration /= speed`). The reference CLI ships 1.05.
    public static let defaultSpeed: Float = 1.05

    /// Default silence inserted between text chunks when synthesizing long
    /// utterances. The 70-char chunk cap (#669) splits a paragraph into many
    /// chunks; the reference CLI's 0.3 s pad stacks on top of the model's own
    /// trailing sentence silence, inflating natural ~0.5–1.0 s sentence pauses
    /// to ~1.1–1.2 s (the "unintended pauses" of #736). 0.05 s keeps the seams
    /// from butting tokens together while letting the model's intrinsic
    /// sentence prosody come through. Override via the synthesize parameter
    /// (CLI `--silence`).
    public static let defaultSilenceDuration: Float = 0.05

    /// There is deliberately no per-language chunk cap.
    ///
    /// `Supertonic3TextChunker` measures each candidate chunk by the number of
    /// tokens it *encodes to* (`encodedLength(of:lang:)`) and compares that
    /// against `textTFixed` directly, so the window is the cap. That removes a
    /// class of bug rather than tuning around it: a cap expressed in
    /// characters means something different in every script, and picking one
    /// number per script is guesswork that silently truncates when it is
    /// wrong.
    ///
    /// The character counts that fall out, for reference — measured, not
    /// configured, via `Benchmarks/Supertonic3/onnx-parity/cap_units.py`:
    ///
    /// | | en / de / ar | ru | ja | vi | hi | ko |
    /// | --- | --- | --- | --- | --- | --- | --- |
    /// | chars admitted | 118 | 116 | 108 | 94 | 118 | 56 |
    ///
    /// The two mechanisms behind the spread: Devanagari averages ~1.4 scalars
    /// per grapheme cluster, and NFKD splits a Hangul syllable into three jamo
    /// and a stacked Vietnamese vowel into up to three scalars.
    ///
    /// Chunk *quality* is a separate axis from chunk *size*, and is bounded by
    /// the VectorEstimator's precision rather than by this file. Measured on
    /// `Benchmarks/Supertonic3/paragraphs.txt` with `tts-asr-verify
    /// --ve-variant`, macro WER at a 70- against a 110-character cap:
    /// `int4` 0.88% → 7.63%, `int8` 0.24% → 0.24%. **Callers must select int8**
    /// (MacReader does); 4-bit palettization comes apart as chunks grow, and
    /// 6-bit does the same one cap further out. Neither the frozen text axis
    /// nor latent bucketing is implicated — reference fp32 stays word-perfect
    /// under both constraints at 110 and at 300.

    // MARK: - Language whitelist (matches AVAILABLE_LANGS in the reference)

    /// 31 supported languages plus "na" (language-agnostic / numeric).
    public static let availableLanguages: [String] = [
        "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi",
        "fr", "hi", "hr", "hu", "id", "it", "lt", "lv", "nl", "pl", "pt", "ro",
        "ru", "sk", "sl", "sv", "tr", "uk", "vi", "na",
    ]

    /// Languages written without inter-word spaces. Retained for callers that
    /// need to reason about word segmentation; it no longer selects a chunk
    /// cap, because the chunker measures the encoded window instead.
    public static let cjkLanguages: Set<String> = ["ko", "ja"]
}
