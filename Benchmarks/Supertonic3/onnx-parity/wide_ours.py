"""Cap 300 using FluidAudio's own weights everywhere except the two text stages.

The point of this script is to size the re-export. Our shipped *dynamic*
VectorEstimator declares `text_emb` as `[1, 256, ?]` and its latent axis as
`?`; probing it directly shows it accepts T=320 and L=512 without complaint.
Our Vocoder is likewise latent-length agnostic. So of the four stages, only
`TextEncoder` and `DurationPredictor` are actually pinned at 128 -- and those
are the two small ones (23 MB and 4 MB) that ship in fp16, with no
quantisation decisions attached.

This runs a 300-character cap with a wide-axis TextEncoder/DurationPredictor
standing in, and our own VectorEstimator and Vocoder doing the rest. If it
sounds right, the re-export is two small fp16 graphs rather than a whole
pipeline.

Everything is CoreML: mixing onnxruntime into the same process as several
CoreML models segfaults, which is why this does not reuse ref_synth.
"""
import argparse
import json
import math
import os
import wave

import numpy as np
import coremltools as ct

import chunk_fixed
from supertonic_ref import Encoder, ROOT, preprocess

SR = 44100
CHUNK = 512 * 6
CHANNELS = 24 * 6
STEPS = 8
SPEED = 1.05
TEXT_BUCKETS = (16, 32, 64, 128, 192, 256, 320)
CPU = ct.ComputeUnit.CPU_ONLY

enc = Encoder()
_cache = {}


def load(path, fn=None):
    key = (path, fn)
    if key not in _cache:
        kw = {"function_name": fn} if fn else {}
        _cache[key] = ct.models.CompiledMLModel(path, compute_units=CPU, **kw)
    return _cache[key]


def style():
    with open(f"{ROOT}/voice_styles/M1.json") as f:
        d = json.load(f)
    ttl = np.array(d["style_ttl"]["data"], np.float32).reshape(d["style_ttl"]["dims"])
    dp = np.array(d["style_dp"]["data"], np.float32).reshape(d["style_dp"]["dims"])
    return ttl, dp


TTL, DP = style()


def encode(text, lang, pad_to):
    raw = enc.ids_for(preprocess(text, lang))
    keep = min(len(raw), pad_to)
    ids = raw[:keep] + [0] * (pad_to - keep)
    mask = [1.0] * keep + [0.0] * (pad_to - keep)
    return (np.array([ids], np.int32),
            np.array([[mask]], np.float32), len(raw))


def infer(text, lang, wide, rng):
    n = len(enc.ids_for(preprocess(text, lang)))
    t = next((b for b in TEXT_BUCKETS if b >= n), TEXT_BUCKETS[-1])
    ids, mask, true_len = encode(text, lang, t)

    dp = load(f"{wide}/DurationPredictor.mlmodelc", f"duration_t{t}").predict(
        {"text_ids": ids, "text_mask": mask.astype(np.float16),
         "style_dp": DP.astype(np.float16)})
    duration = max(0.05, float(np.ravel(list(dp.values())[0])[0]) / SPEED)

    te = load(f"{wide}/TextEncoder.mlmodelc", f"text_t{t}").predict(
        {"text_ids": ids, "text_mask": mask.astype(np.float16),
         "style_ttl": TTL.astype(np.float16)})
    emb = np.array(te["text_emb"], np.float32)

    L = max(1, math.ceil(duration * SR / CHUNK))
    noisy = rng.standard_normal((1, CHANNELS, L)).astype(np.float32)
    lmask = np.ones((1, 1, L), np.float32)

    ve = load(f"{ROOT}/VectorEstimator.mlmodelc")
    for step in range(STEPS):
        noisy = np.array(ve.predict({
            "noisy_latent": noisy, "text_emb": emb, "style_ttl": TTL,
            "latent_mask": lmask, "text_mask": mask,
            "current_step": np.array([step], np.float32),
            "total_step": np.array([STEPS], np.float32),
        })["denoised_latent"], np.float32)

    vo = load(f"{ROOT}/Vocoder.mlmodelc")
    wav = np.ravel(list(vo.predict({"latent": noisy}).values())[0])
    trim = min(len(wav), int(SR * duration))
    return (wav[:trim] if trim > 0 else wav), duration, true_len, t, L


def write_wav(path, s):
    peak = float(np.abs(s).max()) or 1.0
    pcm = (np.clip(s / max(peak, 1.0), -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--wide", required=True, help="dir with a wide-axis TextEncoder/DurationPredictor")
    ap.add_argument("--keys", default="p1,p2")
    ap.add_argument("--lang", default="en")
    ap.add_argument("--cap", type=int, default=300)
    ap.add_argument("--seed", type=int, default=1234)
    args = ap.parse_args()

    src = json.load(open("paragraphs.json"))
    gap = np.zeros(int(0.05 * SR), np.float32)
    for key in args.keys.split(","):
        name = f"ourve-{key}-cap{args.cap}"
        print(f"\n[{name}]", flush=True)
        rng = np.random.default_rng(args.seed)
        parts = []
        for i, c in enumerate(chunk_fixed.chunk(src[key], mx=args.cap)):
            s, d, n, t, L = infer(c, args.lang, args.wide, rng)
            if i:
                parts.append(gap)
            parts.append(s)
            print(f"    chunk {i+1} chars={len(c):3d} tok={n:3d}->T{t} "
                  f"dur={d:5.2f}s latent={L:3d}", flush=True)
        out = np.concatenate(parts)
        write_wav(f"out/{name}.wav", out)
        print(f"    -> out/{name}.wav  {len(out)/SR:.2f}s", flush=True)
