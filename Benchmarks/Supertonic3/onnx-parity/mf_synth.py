"""Synthesize through a *multi-function* CoreML export whose text axis is
bucketed rather than frozen at 128 (`smdesai/supertonic-3-coreml`: text
T in {16,32,64,128,192,256,320}, latent L in {16,32,64,128,256,384,512}).

Answers the question our own export cannot: does a chunk longer than 128
tokens synthesize correctly, or was the frozen axis hiding a deeper limit?

Stages are swappable so the text axis can be isolated from the 6-bit
VectorEstimator that ships alongside it:

  --ve onnx    reference fp32 VectorEstimator (isolates the text stages)
  --ve coreml  the export's own palettized VectorEstimator

The vocoder stays reference fp32 in both, so any difference is upstream of it.
"""
import argparse
import json
import math
import os

import numpy as np

import chunk_sim
import ref_synth as R

import coremltools as ct

TEXT_BUCKETS = (16, 32, 64, 128, 192, 256, 320)
LATENT_BUCKETS = (16, 32, 64, 128, 256, 384, 512)
_UNIT = {"cpu": ct.ComputeUnit.CPU_ONLY, "ane": ct.ComputeUnit.CPU_AND_NE}
_cache = {}


def model(root, name, fn, unit):
    key = (root, name, fn, unit)
    if key not in _cache:
        path = os.path.join(root, f"{name}.mlmodelc")
        kw = {"function_name": fn} if fn else {}
        _cache[key] = ct.models.CompiledMLModel(
            path, compute_units=_UNIT[unit], **kw)
    return _cache[key]


def bucket_for(n, buckets, what):
    b = next((b for b in buckets if b >= n), None)
    if b is None:
        raise SystemExit(f"{what} {n} exceeds largest bucket {buckets[-1]}")
    return b


def infer_chunk(text, rng, root, ve_backend, unit):
    """One chunk end to end. Returns (samples, duration, tokens, T, latent, L)."""
    _, _, true_len = R.enc.encode(text)          # unpadded, to size the bucket
    t = bucket_for(true_len, TEXT_BUCKETS, "text length")
    ids, mask, _ = R.enc.encode(text, pad_to=t)

    ids16 = ids.astype(np.int32)
    mask16 = mask.astype(np.float16)
    ttl16 = R.ttl.astype(np.float16)

    dp = model(root, "DurationPredictor", f"duration_t{t}", unit).predict(
        {"text_ids": ids16, "text_mask": mask16, "style_dp": R.dp_style.astype(np.float16)})
    duration = max(0.05, float(np.ravel(list(dp.values())[0])[0]) / R.SPEED)

    te = model(root, "TextEncoder", f"text_t{t}", unit).predict(
        {"text_ids": ids16, "text_mask": mask16, "style_ttl": ttl16})
    text_emb = np.array(te["text_emb"], dtype=np.float32)

    latent_len = max(1, math.ceil(duration * R.SR / R.CHUNK_SIZE))
    noisy = rng.standard_normal((1, R.CHANNELS, latent_len)).astype(np.float32)
    latent_mask = np.ones((1, 1, latent_len), dtype=np.float32)
    ell = latent_len

    if ve_backend == "ours":
        # Our shipped dynamic build: variable text axis, variable latent, no padding.
        from supertonic_ref import ROOT
        m = model(ROOT, "VectorEstimator", None, unit)
        for step in range(R.STEPS):
            noisy = np.array(m.predict({
                "noisy_latent": noisy, "text_emb": text_emb, "style_ttl": R.ttl,
                "latent_mask": latent_mask, "text_mask": mask,
                "current_step": np.array([step], dtype=np.float32),
                "total_step": np.array([R.STEPS], dtype=np.float32),
            })["denoised_latent"], dtype=np.float32)
    elif ve_backend == "onnx":
        for step in range(R.STEPS):
            noisy = R.ve_sess.run(None, {
                "noisy_latent": noisy, "text_emb": text_emb, "style_ttl": R.ttl,
                "latent_mask": latent_mask, "text_mask": mask,
                "current_step": np.array([step], dtype=np.float32),
                "total_step": np.array([R.STEPS], dtype=np.float32),
            })[0].astype(np.float32)
    else:
        ell = bucket_for(latent_len, LATENT_BUCKETS, "latent length")
        noisy = R.pad_axis(noisy, ell)
        latent_mask = R.pad_axis(latent_mask, ell)
        m = model(root, f"VectorEstimator_l{ell}", f"vector_t{t}_l{ell}", unit)
        args = {"noisy_latent": noisy.astype(np.float16),
                "text_emb": text_emb.astype(np.float16),
                "style_ttl": ttl16,
                "latent_mask": latent_mask.astype(np.float16),
                "text_mask": mask16}
        for step in range(R.STEPS):
            out = m.predict({**args,
                             "noisy_latent": args["noisy_latent"],
                             "current_step": np.array([step], dtype=np.float16),
                             "total_step": np.array([R.STEPS], dtype=np.float16)})
            args["noisy_latent"] = np.array(list(out.values())[0], dtype=np.float16)
        noisy = np.array(args["noisy_latent"], dtype=np.float32)[:, :, :latent_len]

    wav = np.ravel(R.vo_sess.run(None, {"latent": noisy})[0])
    trim = min(len(wav), int(R.SR * duration))
    return (wav[:trim] if trim > 0 else wav), duration, true_len, t, latent_len, ell


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="dir holding the .mlmodelc bundles")
    ap.add_argument("--keys", default="p1,p2")
    ap.add_argument("--caps", default="300")
    ap.add_argument("--ve", default="onnx", choices=("onnx", "coreml", "ours"),
                    help="ours = FluidAudio's shipped DYNAMIC VectorEstimator, which already "
                         "declares text_emb as [1,256,?] and so accepts a 320-token text axis "
                         "without any re-export")
    ap.add_argument("--unit", default="cpu", choices=("cpu", "ane"))
    ap.add_argument("--tag", default="mf")
    ap.add_argument("--seed", type=int, default=1234,
                    help="latent noise seed; sweep it to separate weight damage "
                         "from Supertonic's own seed-dependent word skipping")
    args = ap.parse_args()

    src = json.load(open("paragraphs.json"))
    for key in args.keys.split(","):
        for cap in (int(c) for c in args.caps.split(",")):
            sfx = "" if args.seed == 1234 else f"-s{args.seed}"
            name = f"{args.tag}-{key}-cap{cap}-ve{args.ve}{sfx}"
            print(f"\n[{name}]")
            rng = np.random.default_rng(args.seed)
            gap = np.zeros(int(0.05 * R.SR), dtype=np.float32)
            parts = []
            for i, c in enumerate(chunk_sim.chunk(src[key], mx=cap)):
                s, d, tok, t, ll, ell = infer_chunk(c, rng, args.root, args.ve, args.unit)
                if i:
                    parts.append(gap)
                parts.append(s)
                print(f"    chunk {i+1} chars={len(c):3d} tok={tok:3d}->T{t} "
                      f"dur={d:5.2f}s latent={ll:3d}->L{ell}")
            out = np.concatenate(parts)
            R.write_wav(f"out/{name}.wav", out)
            print(f"    -> out/{name}.wav  {len(out)/R.SR:.2f}s")
