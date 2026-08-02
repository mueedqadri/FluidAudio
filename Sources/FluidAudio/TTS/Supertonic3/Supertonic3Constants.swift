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

    /// Max characters per chunk when synthesizing long English/Latin text.
    ///
    /// Sized to the `textTFixed = 128` window less the `<lang>…</lang>`
    /// wrapper and NFKD expansion. **This is a limit of our CoreML export, not
    /// of the model.** The reference ONNX graphs declare `text_length` as a
    /// symbolic dimension and the upstream demo chunks at 300 characters
    /// (120 for CJK); freezing T at 128 during conversion is what forces a
    /// cap here at all.
    ///
    /// Held at 70 because of #669, and **confirmed by measurement**: raising
    /// it to 110 on `Benchmarks/Supertonic3/paragraphs.txt` cut mid-clause
    /// seams (54 → 30) but took macro WER from ~1.5% to **12.2%**, with whole
    /// clauses dropped from the audio and words mangled ("Distances" →
    /// "Distas"). The seam win is not worth losing the words.
    ///
    /// So the export degrades well before its own 128-token window is full,
    /// while the reference runs the same weights at 300 characters. Both
    /// facts point at the conversion rather than the weights. Raising this
    /// safely requires a re-export, not a constant change — see MAC-395.
    public static let maxChunkLengthLatin: Int = 70

    /// Chunk cap for Korean / Japanese. CJK expands to more codepoints per
    /// visible character after NFKD, so the same token window holds fewer of
    /// them; kept proportionally below `maxChunkLengthLatin`.
    public static let maxChunkLengthCJK: Int = 57

    // MARK: - Language whitelist (matches AVAILABLE_LANGS in the reference)

    /// 31 supported languages plus "na" (language-agnostic / numeric).
    public static let availableLanguages: [String] = [
        "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi",
        "fr", "hi", "hr", "hu", "id", "it", "lt", "lv", "nl", "pl", "pt", "ro",
        "ru", "sk", "sl", "sv", "tr", "uk", "vi", "na",
    ]

    /// Languages that should use the tighter `maxChunkLengthCJK` (57-char) chunker.
    public static let cjkLanguages: Set<String> = ["ko", "ja"]
}
