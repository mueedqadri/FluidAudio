"""Hybrid pipeline: reference fp32 ONNX everywhere EXCEPT the denoising loop,
which runs our shipped CoreML VectorEstimator (ANE-bucketed, int4 palettized).

Shapes are identical to ref_synth's `bucket` mode, which transcribed
word-perfect in fp32 — so any damage here is the quantized weights, not shape.
"""
import argparse
import json
import math

import numpy as np

import chunk_sim
import ref_synth as R
from supertonic_ref import ROOT

import coremltools as ct

_UNIT = {"cpu": ct.ComputeUnit.CPU_ONLY, "ane": ct.ComputeUnit.CPU_AND_NE}
_cache = {}


def ve_model(bucket, quant, unit):
    key = (bucket, quant, unit)
    if key not in _cache:
        p = f"{ROOT}/VectorEstimatorVariants/VectorEstimator_L{bucket}_{quant}.mlmodelc"
        _cache[key] = ct.models.CompiledMLModel(p, compute_units=_UNIT[unit])
    return _cache[key]


def infer_chunk(text, rng, quant, unit):
    ids, mask, true_len = R.enc.encode(text, pad_to=128)
    duration = float(np.ravel(R.dp_sess.run(
        None, {"text_ids": ids, "text_mask": mask, "style_dp": R.dp_style})[0])[0])
    duration = max(0.05, duration / R.SPEED)
    text_emb = R.te_sess.run(
        None, {"text_ids": ids, "text_mask": mask, "style_ttl": R.ttl})[0]

    latent_len = max(1, math.ceil(duration * R.SR / R.CHUNK_SIZE))
    bucket = next((b for b in R.BUCKETS if b >= latent_len), R.BUCKETS[-1])
    noisy = R.pad_axis(rng.standard_normal((1, R.CHANNELS, latent_len)).astype(np.float32), bucket)
    latent_mask = R.pad_axis(np.ones((1, 1, latent_len), dtype=np.float32), bucket)

    m = ve_model(bucket, quant, unit)
    for step in range(R.STEPS):
        noisy = np.array(m.predict({
            "noisy_latent": noisy, "text_emb": text_emb, "style_ttl": R.ttl,
            "latent_mask": latent_mask, "text_mask": mask,
            "current_step": np.array([step], dtype=np.float32),
            "total_step": np.array([R.STEPS], dtype=np.float32),
        })["denoised_latent"], dtype=np.float32)

    noisy = noisy[:, :, :latent_len]
    wav = np.ravel(R.vo_sess.run(None, {"latent": noisy})[0])
    trim = min(len(wav), int(R.SR * duration))
    return (wav[:trim] if trim > 0 else wav), duration, latent_len, bucket


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--keys", default="p1,p2")
    ap.add_argument("--caps", default="110")
    ap.add_argument("--quant", default="int4")
    ap.add_argument("--unit", default="cpu")
    args = ap.parse_args()

    src = json.load(open("paragraphs.json"))
    for key in args.keys.split(","):
        for cap in (int(c) for c in args.caps.split(",")):
            name = f"ref-{key}-cap{cap}-mlve{args.quant}-{args.unit}"
            print(f"\n[{name}]")
            rng = np.random.default_rng(1234)
            gap = np.zeros(int(0.05 * R.SR), dtype=np.float32)
            parts = []
            for i, c in enumerate(chunk_sim.chunk(src[key], mx=cap)):
                s, d, ll, b = infer_chunk(c, rng, args.quant, args.unit)
                if i:
                    parts.append(gap)
                parts.append(s)
                print(f"    chunk {i+1} chars={len(c):3d} dur={d:5.2f}s latent={ll:3d}->L{b}")
            out = np.concatenate(parts)
            R.write_wav(f"out/{name}.wav", out)
            print(f"    -> out/{name}.wav  {len(out)/R.SR:.2f}s")
