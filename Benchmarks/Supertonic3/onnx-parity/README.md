# Supertonic-3 ONNX parity harness

Answers one question: when our CoreML port reads a long chunk worse than the
upstream demo does, **which** of our departures from the reference is to blame?

The port differs from `Supertone/supertonic-3`'s ONNX graphs in three ways, and
these scripts reintroduce them one at a time against the same fp32 weights:

| Departure | Isolated by |
| --- | --- |
| text axis frozen at `textTFixed = 128` | `ref_synth.py --modes exact,pad128` |
| latent padded up to an `L128/256/512` bucket | `ref_synth.py --modes bucket` |
| VectorEstimator palettized to int4/int6/int8 | `hybrid_ve.py --quant` |

## Result (2026-08-02, v1.7.3 weights, M1, 8 steps)

Shapes are innocent. fp32 stays word-perfect at a 110-character cap **and at
the demo's 300** with the text padded to 128 and the latent padded to its
bucket. Swap in the shipped int4 VectorEstimator, changing nothing else, and
the words break up:

> A joke **the ton** a pun, a must become joke turns on something else […]
> The translator who preserves every word **is the effit's** produced accurate
> document and a failed. **Peace** of writing.

int6 and int8 transcribe clean at 110. Per-step error vs fp32 is small
(int4 ~3.4%, int8 ~0.3%) but compounds across the 8-step denoising loop and
grows with latent length — after 8 steps, int4 is 89% off at a 110-character
chunk where int8 is 24%.

Corpus confirmation on `../paragraphs.txt` via
`fluidaudio tts-asr-verify --ve-variant`:

| VectorEstimator | cap 70 | cap 110 |
| --- | --- | --- |
| `int4` | 0.88% WER, 27 excess sentence ends | **7.63% WER**, 17 |
| `int8` | 0.24% WER, 35 excess sentence ends | **0.24% WER, 21** |

## Setup

```sh
uv venv --python 3.12 .venv
VIRTUAL_ENV=.venv uv pip install onnx onnxruntime numpy coremltools

for f in text_encoder duration_predictor vector_estimator vocoder; do
  curl -sLO "https://huggingface.co/Supertone/supertonic-3/resolve/main/onnx/$f.onnx"
done
mv text_encoder.onnx te.onnx && mv duration_predictor.onnx dp.onnx
```

CoreML models and `unicode_indexer.json` are read from
`~/.cache/fluidaudio/Models/supertonic-3`, so run the Swift CLI once first to
populate it. `hybrid_ve.py --quant int6|int8` additionally needs those
VectorEstimator variants fetched into `VectorEstimatorVariants/`.

## Scripts

- `supertonic_ref.py` — Python port of `Supertonic3UnicodeProcessor`, so token
  IDs are byte-identical to the Swift path. Everything else imports it.
- `probe.py` — text stages only. Three-way duration/embedding diff:
  ONNX-exact vs ONNX-padded-to-128 vs CoreML. Shows the conversion is faithful
  (≤0.4% on duration) and that past 128 tokens input is silently discarded —
  predicted duration freezes at 9.23 s for every length from 151 to 388.
- `ref_synth.py` — full fp32 reference pipeline. `--modes exact,pad128,bucket`.
- `hybrid_ve.py` — fp32 ONNX everywhere except the denoising loop, which runs
  our CoreML VectorEstimator. The test that isolated the cause.
- `ve_error.py` — per-step vs compounded quantisation error by chunk length.
- `chunk_sim.py` — Python mirror of `Supertonic3TextChunker`.

Outputs land in `out/`; transcribe with `fluidaudio transcribe out/<file>.wav`.
