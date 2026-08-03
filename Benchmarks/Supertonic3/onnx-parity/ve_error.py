"""How far does each quantized VectorEstimator drift from fp32 ONNX?

Same text stages, same shapes, same starting noise — only the denoiser weights
differ. Reports relative L2 error of the denoised latent after the first step
(raw quantization error) and after all 8 (what the vocoder actually sees).
"""
import json
import math

import numpy as np

import ref_synth as R
from hybrid_ve import ve_model

SRC = json.load(open("paragraphs.json"))
WORDS = SRC["p1"].split()


def build(text):
    ids, mask, tl = R.enc.encode(text, pad_to=128)
    dur = max(0.05, float(np.ravel(R.dp_sess.run(
        None, {"text_ids": ids, "text_mask": mask, "style_dp": R.dp_style})[0])[0]) / R.SPEED)
    emb = R.te_sess.run(None, {"text_ids": ids, "text_mask": mask, "style_ttl": R.ttl})[0]
    ll = max(1, math.ceil(dur * R.SR / R.CHUNK_SIZE))
    bucket = next((b for b in R.BUCKETS if b >= ll), R.BUCKETS[-1])
    rng = np.random.default_rng(7)
    noisy = R.pad_axis(rng.standard_normal((1, R.CHANNELS, ll)).astype(np.float32), bucket)
    lmask = R.pad_axis(np.ones((1, 1, ll), dtype=np.float32), bucket)
    return ids, mask, emb, noisy, lmask, ll, bucket, dur


def run_onnx(mask, emb, noisy, lmask, steps):
    x, first = noisy, None
    for s in range(steps):
        x = R.ve_sess.run(None, {
            "noisy_latent": x, "text_emb": emb, "style_ttl": R.ttl,
            "latent_mask": lmask, "text_mask": mask,
            "current_step": np.array([s], dtype=np.float32),
            "total_step": np.array([R.STEPS], dtype=np.float32)})[0].astype(np.float32)
        if s == 0:
            first = x.copy()
    return first, x


def run_ml(mask, emb, noisy, lmask, bucket, quant, steps):
    m = ve_model(bucket, quant, "cpu")
    x, first = noisy, None
    for s in range(steps):
        x = np.array(m.predict({
            "noisy_latent": x, "text_emb": emb, "style_ttl": R.ttl,
            "latent_mask": lmask, "text_mask": mask,
            "current_step": np.array([s], dtype=np.float32),
            "total_step": np.array([R.STEPS], dtype=np.float32)})["denoised_latent"],
            dtype=np.float32)
        if s == 0:
            first = x.copy()
    return first, x


def rel(a, b, ll):
    a, b = a[:, :, :ll], b[:, :, :ll]
    return float(np.linalg.norm(a - b) / max(np.linalg.norm(b), 1e-9)) * 100


print(f"{'chunk':>6} {'chars':>5} {'latent':>6} | "
      + " | ".join(f"{q:^17}" for q in ("int4", "int6", "int8")))
print(f"{'':>6} {'':>5} {'':>6} | " + " | ".join(f"{'step1':>8} {'final':>8}" for _ in range(3)))
print("-" * 82)

for nw, label in ((7, "short"), (12, "cap70"), (19, "cap110")):
    text = " ".join(WORDS[:nw])
    ids, mask, emb, noisy, lmask, ll, bucket, dur = build(text)
    _, ref_final = run_onnx(mask, emb, noisy, lmask, R.STEPS)
    ref_first, _ = run_onnx(mask, emb, noisy, lmask, 1)
    cells = []
    for q in ("int4", "int6", "int8"):
        f1, fn = run_ml(mask, emb, noisy, lmask, bucket, q, R.STEPS)
        cells.append(f"{rel(f1, ref_first, ll):7.2f}% {rel(fn, ref_final, ll):7.2f}%")
    print(f"{label:>6} {len(text):>5} {ll:>6} | " + " | ".join(cells))
