# Supertonic-3 (v1.7.3) Swift Inference

Multilingual flow-matching diffusion TTS. 31 languages, 44.1 kHz mono
Float32 output, voice styling via per-speaker JSON tensors. 4-stage
CoreML pipeline at ~398 MB total.

## Overview

Supertonic-3 is a 4-stage CoreML port of
[supertone-inc/supertonic](https://github.com/supertone-inc/supertonic)
v1.7.3. Each utterance runs:

```
text → text_encoder       → text_emb       [1, 256, 128]
text → duration_predictor → duration       [1]
       vector_estimator   ×8 denoising steps (flow-matching diffusion w/ CFG)
       vocoder            → 44.1 kHz mono Float32 wav
```

The `vector_estimator` stage is the cost center: 8 denoising steps with
classifier-free guidance built into the graph (W_COND = 4.0,
W_UNCOND = 3.0). Voice identity rides on two style tensors
(`style_ttl`, `style_dp`) loaded from per-speaker JSON presets — the
upstream repo ships `M1`/`F1`/`M2`/`F2`/… and the FluidInference mirror
re-publishes them under `assets/voice_styles/`.

## Quick Start

### CLI

```bash
swift run fluidaudiocli tts "Hello from Supertonic three." \
    --backend supertonic3 \
    --lang en \
    --voice-style path/to/M1.json \
    --output ~/Desktop/sup3-demo.wav
```

`--voice-style` is required and must point at a Supertonic voice preset
JSON. On first invocation the CLI downloads the four `.mlmodelc`
bundles plus `tts.json` and `unicode_indexer.json`; subsequent calls
reuse the disk cache.

Optional flags:

| Flag | Default | Notes |
|---|---|---|
| `--lang <code>` | `en` | One of the 31 supported ISO codes — see [Languages](#languages) |
| `--total-steps <n>` | `8` | Denoising step count; lower trades quality for latency |
| `--speed <f>` | `1.05` | Speech-rate multiplier; divides predicted duration |
| `--ve-variant <v>` | `int8` | VectorEstimator weight precision — `int8`, `int6`, `int4`, or `fp16`. See [VectorEstimator variants](#vectorestimator-variants) |

### Swift

```swift
import FluidAudio

let manager = try await Supertonic3Manager.downloadAndCreate(
    computeUnits: .cpuAndNeuralEngine,
    vectorEstimator: .dynamic(.int8)       // optional; this is the default
)

// `computeUnits` reaches the vocoder only. The text stages and the
// VectorEstimator are pinned `.cpuOnly` — see "Compute placement" below.

let style = try Supertonic3VoiceStyle.load(
    from: URL(fileURLWithPath: "/path/to/M1.json"))

let (samples, _) = try await manager.synthesize(
    text: "Hello from Supertonic three.",
    language: "en",
    style: style)
// `samples`: Float32 PCM, 44.1 kHz mono.
```

## Pipeline

```
text                       voice style JSON (M1.json …)
  |                                |
  v                                v
Supertonic3TextChunker       Supertonic3VoiceStyle.load
  |  (paragraph → sentence       |  (style_ttl  [1, 50, 256]
  |   → comma → word, 110         |   style_dp  [1,  8,  16])
  |   chars Latin / 90 CJK)       |
  v                                |
Supertonic3UnicodeProcessor        |
  |  (NFKD → strip emoji →         |
  |   <lang>…</lang> tags →        |
  |   65536-entry codepoint        |
  |   indexer → text_ids, mask)    |
  | text_ids   [1, 128]            |
  | text_mask  [1, 1, 128]         |
  v                                v
Supertonic3Synthesizer  (4 CoreML stages, batch = 1)
  ├─ text_encoder       text_ids + style_ttl  → text_emb     [1, 256, 128]
  ├─ duration_predictor text_ids + style_dp   → duration     [1]
  ├─ vector_estimator   ×8 denoising steps    → denoised_latent
  │     (flow-matching diffusion w/ CFG; current_step/total_step
  │      drive σ schedule; style_ttl + text_mask + latent_mask
  │      condition each step)
  └─ vocoder            denoised_latent       → wav (44.1 kHz mono Float32)
```

The flow-matching loop iterates `vector_estimator` `totalSteps` (= 8)
times, feeding each `denoised_latent` back in as the next step's
`noisy_latent`. CFG is fused into the model — Swift only supplies the
`current_step` / `total_step` scalars.

## Files

| File | Role |
|---|---|
| `Supertonic3Manager.swift` | Public actor — `initialize()`, `downloadAndCreate()`, `synthesize(text:language:style:totalSteps:speed:silenceDuration:)`, `cleanup()` |
| `Supertonic3Constants.swift` | Compile-time constants (44.1 kHz, text buckets, latent floors/ceiling, 8 default steps, 31-language whitelist) |
| `Supertonic3Error.swift` | Per-module `Error, LocalizedError` enum |
| `Supertonic3Types.swift` | `Supertonic3Config` (`tts.json` schema) + `Supertonic3VoiceStyle` (decoded style tensors) |
| `Assets/Supertonic3ModelStore.swift` | Actor — loads the vocoder eagerly and the text stages / VectorEstimator lazily, plus `tts.json` + `unicode_indexer.json`. Owns compute placement |
| `Assets/Supertonic3ResourceDownloader.swift` | HuggingFace pull for `FluidInference/supertonic-3-coreml` |
| `Pipeline/Preprocess/Supertonic3UnicodeProcessor.swift` | NFKD normalize + emoji strip + symbol replace + `<lang>` wrap + 65536-entry codepoint → token-id lookup, pads to the caller's text bucket |
| `Pipeline/Preprocess/Supertonic3TextChunker.swift` | Sentence-aware chunker measured in *encoded tokens*, not characters — packs to 128, keeps a sentence whole to 320, clause-splits beyond |
| `Pipeline/Synthesize/Supertonic3Synthesizer.swift` | 4-stage CoreML driver — text_encoder + duration_predictor → 8-step vector_estimator → vocoder |
| `Pipeline/Synthesize/Supertonic3LatentSampler.swift` | Noisy-latent + latent-mask sampling for the flow-matching loop |
| `Pipeline/Synthesize/Supertonic3MultiArray.swift` | `MLMultiArray` ergonomics shared by the synthesizer stages |

## Text preprocessing

Mirrors the upstream `UnicodeProcessor` from
[Helper.swift](https://github.com/supertone-inc/supertonic/blob/main/swift/Sources/Helper.swift):

1. NFKD decompose (`decomposedStringWithCompatibilityMapping`).
2. Strip emoji codepoints in the wide Unicode planes.
3. Replace dashes / quotes / brackets / arrows with ASCII equivalents.
4. Drop decorative symbols (`♥`, `☆`, `\\`, …).
5. Expand a small set of abbreviations (`@` → " at ", `e.g.,` →
   "for example,", `i.e.,` → "that is,").
6. Tighten spacing around punctuation; collapse repeated quotes.
7. Append `.` if no terminal punctuation.
8. Wrap with `<lang>…</lang>` tags.
9. Map each Unicode scalar through `unicode_indexer.json` (a flat
   `[Int64]` array keyed by codepoint) — unknown scalars receive `-1`
   so the model can mask them.

The `text_encoder` + `duration_predictor` models pin the T axis at
**128**; longer inputs are truncated and shorter ones zero-padded. The
chunker keeps each pass under 110 (Latin) / 90 (CJK) characters so the
NFKD-expanded codepoint sequence plus `<lang>` overhead fits inside
the 128-token window.

## Voice styles

`Supertonic3VoiceStyle` loads two style tensors from a per-speaker JSON:

| Field | Shape | Consumed by |
|---|---|---|
| `style_ttl` | `[1, 50, 256]` | `text_encoder` + every `vector_estimator` step |
| `style_dp` | `[1, 8, 16]` | `duration_predictor` |

The upstream repo ships `M1` / `M2` / `F1` / `F2` etc. as static JSON
files under
[`FluidInference/supertonic-3-coreml/assets/voice_styles/`](https://huggingface.co/FluidInference/supertonic-3-coreml/tree/main/assets/voice_styles).
Pass any of those to `Supertonic3VoiceStyle.load(from:)`; the decoded
struct is `Sendable` and can be reused across many synthesize calls.

## Languages

31 ISO codes plus `"na"` (language-agnostic / numeric):

```
en  ko  ja  ar  bg  cs  da  de  el  es  et  fi
fr  hi  hr  hu  id  it  lt  lv  nl  pl  pt  ro
ru  sk  sl  sv  tr  uk  vi  na
```

No Chinese (`zh`) — Supertonic-3 was not trained on Mandarin. Use
[`KokoroAne`](KokoroAne.md) with `--variant mandarin` for Mandarin
TTS in FluidAudio.

There is no per-language chunk cap. `Supertonic3TextChunker` measures each
candidate by the number of tokens it *encodes to* and compares that against
the 128-token window directly, so the window is the cap. A cap expressed in
characters means something different in every script — Devanagari averages
~1.4 scalars per grapheme cluster, and NFKD splits a Hangul syllable into
three jamo — so one number per script silently truncates whenever the guess
is wrong. The character counts that fall out are measured, not configured:
en/de/ar 118, ru 116, ja 108, vi 94, ko 56.

Sentence boundaries are recognised in every supported script: Latin `.!?`,
the Devanagari danda `।`/`॥`, the Arabic question mark `؟`, and the CJK
`。！？`, the last group without requiring trailing whitespace.

## Models

All CoreML packages live under
[`FluidInference/supertonic-3-coreml`](https://huggingface.co/FluidInference/supertonic-3-coreml).

| Stage | mlmodelc | Notes |
|---|---|---|
| Text encoder | `TextEncoderWide.mlmodelc` | Multi-function: `text_t{32,64,128,192,256,320}`, selected with `MLModelConfiguration.functionName`. Outputs `text_emb [1, 256, T]` |
| Duration predictor | `DurationPredictorWide.mlmodelc` | Multi-function: `duration_t{...}`, same buckets. Outputs scalar `duration` |
| Vector estimator | `VectorEstimatorVariants/VectorEstimator_int8.mlmodelc` | RangeDim `[17, 512]` on both the latent and text axes. 8 denoising steps with fused CFG (W_COND = 4.0, W_UNCOND = 3.0). See [variants](#vectorestimator-variants) |
| Vocoder | `Vocoder.mlmodelc` | Latent RangeDim `[4, 512]`. Outputs `wav` at 44.1 kHz mono Float32 |

The published `text_t16` function exists but is unusable: it emits a 16-wide
`text_emb`, and the VectorEstimator's text axis will not bind under 17.

### Compute placement

Not a tuning knob. The text stages and the VectorEstimator are pinned
`.cpuOnly` on both platforms; only the vocoder takes the caller's
`computeUnits`. Two independent findings put them there:

- **Fixed shapes froze the text axis.** An ANE export must pin every axis,
  which capped a sentence at 128 tokens and split 34.9% of them mid-clause.
- **iOS refuses the ANE to a backgrounded app, per program.** Multi-island
  BNNS↔ANE programs get `kIOReturnNotPermitted` at foreground QoS; only
  single-block programs (the vocoder) keep running.

The all-CPU chain measures 11.6–42× realtime on M-series and 10–37× on an
A15, against a 1× playback requirement.

### Latent bounds

Three separate limits on the latent axis, all enforced by the synthesizer:

| Bound | Value | What happens |
|---|---|---|
| VectorEstimator floor | 17 slots | Latent is padded to 32 (see below), mask zeroes the tail |
| int8 kernel tile | 32 slots | Below it the CPU kernel falls off its fast path — 12 ms/step at 32, 577 ms at 31 |
| Vocoder floor | 4 slots | Trim back from 32 stops here; the waveform trim to predicted duration discards the rest |
| Ceiling (both) | 512 slots ≈ 35.7 s | Chunk is re-split at 128 tokens and the pieces run through the same stages |

Companion assets:

| File | Role |
|---|---|
| `tts.json` | Sample rate, chunk-compress factor, base chunk size — overrides the compile-time defaults in `Supertonic3Constants` |
| `unicode_indexer.json` | Flat `[Int64]` array, indexed by codepoint, mapping every Unicode scalar to a model token id |
| `assets/voice_styles/*.json` | Per-speaker `style_ttl` / `style_dp` tensors |

## VectorEstimator variants

`VectorEstimator` is the cost center (run once per denoising step × 8), so it
ships in several weight-compressed builds under
[`FluidInference/supertonic-3-coreml/VectorEstimatorVariants/`](https://huggingface.co/FluidInference/supertonic-3-coreml/tree/main/VectorEstimatorVariants).
Select one via `Supertonic3Manager(vectorEstimator:)` or the `--ve-variant`
CLI flag. Two independent axes:

Every build is a RangeDim model fed the exact latent length and run
`.cpuOnly`; they differ only in weight precision, i.e. download size.

| `Supertonic3VectorEstimator` | `--ve-variant` | bundle |
|---|---|---|
| `.dynamic(q)` (default `.int8`) | `int8` / `int6` / `int4` | `VectorEstimatorVariants/VectorEstimator_int{8,6,4}.mlmodelc` |
| `.fp16Dynamic` | `fp16` | `VectorEstimator.mlmodelc` (repo root) |

The fixed-length ANE-bucketed builds are retired. They were ~2.7× faster and
it did not matter: 4-bit palettization comes apart as chunks grow, the fixed
shapes froze the text axis, and iOS refuses those programs to a backgrounded
app.

**Quantization → size only** (placement is unchanged). All are post-training,
weight-only:

| suffix | method | size vs FP16 | quality |
|---|---|---|---|
| `int8` | linear, per-channel symmetric int8 | ~2.0× smaller (64.5 MB) | transparent (closest to FP16) |
| `int6` | 6-bit k-means palettization | ~2.5× smaller (48.4 MB) | very good |
| `int4` | 4-bit k-means palettization | ~3.9× smaller (32.5 MB) | perceptually clean in A/B listening |

Only the selected build downloads (via the variant filter), so non-default
choices add no cost to other configurations. **Callers should stay on int8**:
4-bit palettization degrades past a ~110-character chunk and 6-bit past ~300,
while int8 stays clean at every chunk length measured. Max audio per chunk is
the 512-slot ceiling, ≈ 35.7 s.

> Quality note: waveform/spectral SNR of the quantized builds vs FP16 looks low,
> but that is **diffusion trajectory divergence, not degradation** — an 8-step
> flow-matching ODE under a slightly-perturbed vector field lands on a
> different-but-valid sample, and sample-aligned SNR is phase-sensitive. Judge by
> listening (or ASR), not waveform SNR.

## Known issues

- **No Chinese.** Supertonic-3's training set does not include Mandarin.
  Use KokoroAne `--variant mandarin` for `zh`.
- **Voice styles are not auto-downloaded.** The four model files +
  `unicode_indexer.json` + `tts.json` come down on first init, but
  voice style JSONs must be supplied by the caller (path on disk or
  fetched separately from the HF repo).
- **320-token whole-sentence ceiling.** A sentence is synthesized whole up
  to 320 encoded tokens (~1% of real sentences exceed it); past that the
  chunker splits at clause separators. Per-chunk audio is concatenated with
  `silenceDuration` (default 0.05 s) in between, so prosody continuity across
  a seam is not preserved.
- **WER on whitespace-free scripts.** Korean / Japanese have no word
  boundaries; `WERCalculator` splits on whitespace and reports
  near-100% WER. Trust CER on those rows.

## License

- **Supertonic-3 model weights:** Apache 2.0, inherited from
  [supertone-inc/supertonic](https://github.com/supertone-inc/supertonic)
  upstream.
- **FluidAudio SDK:** Apache 2.0.
