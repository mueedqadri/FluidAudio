"""Reference Supertonic-3 synthesis in pure fp32 ONNX, with a switchable
isolation ladder that reintroduces our export's constraints one at a time:

  exact    — reference: exact text length, exact latent length, fp32 VE
  pad128   — text zero-padded to 128 (our TextEncoder/DurationPredictor shape)
  bucket   — pad128 + latent padded up to the 128/256/512 bucket (our VE shape)

Everything else (chunker, preprocessing, speed, seam silence) matches FluidAudio.
"""
import argparse
import json
import math
import wave

import numpy as np

import chunk_sim
from supertonic_ref import Encoder, load_style, onnx_sessions, preprocess

SR = 44100
CHUNK_SIZE = 512 * 6          # baseChunkSize * chunkCompressFactor
CHANNELS = 24 * 6             # latentDim * chunkCompressFactor
STEPS = 8
SPEED = 1.05
BUCKETS = (128, 256, 512)

enc = Encoder()
ttl, dp_style = load_style()
te_sess, dp_sess = onnx_sessions()

import onnxruntime as ort
_o = ort.SessionOptions()
_o.log_severity_level = 3
ve_sess = ort.InferenceSession("vector_estimator.onnx", _o, providers=["CPUExecutionProvider"])
vo_sess = ort.InferenceSession("vocoder.onnx", _o, providers=["CPUExecutionProvider"])


def pad_axis(x, to_len, axis=-1):
    if x.shape[axis] >= to_len:
        return x
    pad = [(0, 0)] * x.ndim
    pad[axis] = (0, to_len - x.shape[axis])
    return np.pad(x, pad)


LANG = "en"  # set by --lang; the encoder wraps text as <LANG>...</LANG>


def infer_chunk(text, mode, rng):
    text_pad = 128 if mode in ("pad128", "bucket") else None
    ids, mask, true_len = enc.encode(text, lang=LANG, pad_to=text_pad)

    duration = float(np.ravel(dp_sess.run(
        None, {"text_ids": ids, "text_mask": mask, "style_dp": dp_style})[0])[0])
    duration = max(0.05, duration / SPEED)

    text_emb = te_sess.run(
        None, {"text_ids": ids, "text_mask": mask, "style_ttl": ttl})[0]

    latent_len = max(1, math.ceil(duration * SR / CHUNK_SIZE))
    noisy = rng.standard_normal((1, CHANNELS, latent_len)).astype(np.float32)
    latent_mask = np.ones((1, 1, latent_len), dtype=np.float32)

    if mode == "bucket":
        pad_len = next((b for b in BUCKETS if b >= latent_len), latent_len)
        noisy = pad_axis(noisy, pad_len)
        latent_mask = pad_axis(latent_mask, pad_len)

    for step in range(STEPS):
        noisy = ve_sess.run(None, {
            "noisy_latent": noisy, "text_emb": text_emb, "style_ttl": ttl,
            "latent_mask": latent_mask, "text_mask": mask,
            "current_step": np.array([step], dtype=np.float32),
            "total_step": np.array([STEPS], dtype=np.float32),
        })[0].astype(np.float32)

    if mode == "bucket":
        noisy = noisy[:, :, :latent_len]

    wav = np.ravel(vo_sess.run(None, {"latent": noisy})[0])
    trim = min(len(wav), int(SR * duration))
    return wav[:trim] if trim > 0 else wav, duration, true_len


CHUNKER = "ships"  # "ships" mirrors Swift today; "fixed" is the proposed policy


def synth(text, cap, mode, silence=0.05, seed=1234):
    rng = np.random.default_rng(seed)
    if CHUNKER == "fixed":
        import chunk_fixed
        chunks = chunk_fixed.chunk(text, mx=cap)
    else:
        chunks = chunk_sim.chunk(text, mx=cap)
    gap = np.zeros(int(silence * SR), dtype=np.float32)
    parts, lens = [], []
    for i, c in enumerate(chunks):
        samples, dur, tl = infer_chunk(c, mode, rng)
        lens.append(tl)
        if i:
            parts.append(gap)
        parts.append(samples)
        print(f"    chunk {i+1}/{len(chunks)}  chars={len(c):3d} tok={tl:3d} "
              f"dur={dur:5.2f}s{'  <-- TRUNCATED' if mode != 'exact' and tl > 128 else ''}")
    return np.concatenate(parts), chunks, lens


def write_wav(path, samples):
    peak = float(np.abs(samples).max()) or 1.0
    pcm = (np.clip(samples / max(peak, 1.0), -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--keys", default="p1,p2")
    ap.add_argument("--caps", default="70,110,300")
    ap.add_argument("--modes", default="exact")
    ap.add_argument("--lang", default="en")
    ap.add_argument("--chunker", default="ships", choices=("ships", "fixed"))
    ap.add_argument("--tag", default="ref")
    args = ap.parse_args()
    LANG = args.lang
    CHUNKER = args.chunker

    src = json.load(open("paragraphs.json"))
    meta = {}
    for key in args.keys.split(","):
        for cap in (int(c) for c in args.caps.split(",")):
            for mode in args.modes.split(","):
                name = f"{args.tag}-{key}-cap{cap}-{mode}"
                print(f"\n[{name}]")
                samples, chunks, lens = synth(src[key], cap, mode)
                write_wav(f"out/{name}.wav", samples)
                meta[name] = dict(cap=cap, mode=mode, chunks=chunks, tok_lens=lens,
                                  seconds=round(len(samples) / SR, 2))
                print(f"    -> out/{name}.wav  {len(samples)/SR:.2f}s")
    prev = {}
    try:
        prev = json.load(open("ref_meta.json"))
    except FileNotFoundError:
        pass
    prev.update(meta)
    json.dump(prev, open("ref_meta.json", "w"), indent=1)
