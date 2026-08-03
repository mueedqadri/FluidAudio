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

    /// Pinned text-token sequence length expected by `text_encoder` and
    /// `duration_predictor`. The CoreML conversion fixes the T axis at 128;
    /// the unicode processor pads/truncates inputs to match. Mirrors
    /// `TEXT_T_FIXED = 128` in the reference Python driver.
    public static let textTFixed: Int = 128

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
