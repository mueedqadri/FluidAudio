"""Overlap-and-discard: give each chunk the neighbouring text as context,
then crop the context's audio back off.

The seam defect is that Supertonic ends every utterance with a sentence-final
fall, so a chunk boundary inside a sentence is performed as a full stop. The
literature's fix for this in long-form TTS is to carry context across the
boundary (MagpieTTS-LF, arXiv 2606.18485) -- but that method threads
autoregressive attention state, which a non-autoregressive flow-matching model
has none of. The part that does port is its first two components: prepend the
previous chunk's tail and append the next chunk's head as *text*, so the model
never sees the target as a complete utterance, then discard the extra audio.

The catch is the discard. Supertonic emits one scalar duration per chunk and no
per-token alignment, so the crop point has to be estimated. This uses the same
character-weighted estimate the app already uses for word highlighting
(`SpeechWordAligner.charWeighted`), then snaps to the quietest 10 ms frame
within a search window so the join lands in a trough rather than mid-vowel.

Costs paid up front: context eats the 128-token window, so the *emitted* span
per call shrinks and the call count rises. Whether that trade is worth it is
the thing this script measures.
"""
import argparse
import json
import math

import numpy as np

import chunk_sim
import ref_synth as R

SR = R.SR
FRAME = SR // 100  # 10 ms


def energy_floor_index(samples, lo, hi):
    """Quietest 10 ms frame in [lo, hi) -- the least-audible place to cut."""
    lo = max(0, min(lo, len(samples)))
    hi = max(lo + FRAME, min(hi, len(samples)))
    best, best_rms = lo, float("inf")
    for start in range(lo, hi - FRAME, FRAME):
        rms = float(np.sqrt(np.mean(samples[start:start + FRAME] ** 2)))
        if rms < best_rms:
            best, best_rms = start, rms
    return best


def speech_extent(samples, floor_db=-42.0):
    """Index one past the last frame above the floor.

    The proportional crop has to be measured against the spoken region, not the
    clip: Supertonic appends its own sentence-final silence, so mapping
    character position onto raw clip length lands late and leaks the next word.
    """
    if len(samples) < FRAME:
        return len(samples)
    n = len(samples) // FRAME
    frames = samples[:n * FRAME].reshape(n, FRAME)
    rms = np.sqrt((frames ** 2).mean(axis=1))
    thresh = (10 ** (floor_db / 20)) * max(float(rms.max()), 1e-9)
    voiced = np.flatnonzero(rms > thresh)
    return int((voiced[-1] + 1) * FRAME) if len(voiced) else len(samples)


def plan(text, target, left, right):
    """Split into target spans, each with its neighbouring text as context."""
    spans = chunk_sim.chunk(text, mx=target)
    out = []
    for i, span in enumerate(spans):
        pre = " ".join(spans[:i])[-left:] if left and i else ""
        post = " ".join(spans[i + 1:])[:right] if right and i < len(spans) - 1 else ""
        # Do not cut a context word in half; the model would voice the fragment.
        if pre and " " in pre:
            pre = pre[pre.index(" ") + 1:]
        if post and " " in post:
            post = post[:post.rindex(" ")]
        out.append((pre, span, post))
    return out


def synth_span(pre, span, post, rng):
    """Synthesize pre+span+post, return only span's audio."""
    full = " ".join(p for p in (pre, span, post) if p)
    samples, duration, _ = R.infer_chunk(full, "exact", rng)
    if not pre and not post:
        return samples

    # Character-weighted estimate of where span sits inside the *spoken* region.
    n = len(full)
    spoken = speech_extent(samples)
    start_frac = (len(pre) + 1) / n if pre else 0.0
    end_frac = (n - len(post) - 1) / n if post else 1.0
    lo_est, hi_est = int(start_frac * spoken), int(end_frac * spoken)

    # Snap each cut to a nearby trough. +-8% of the spoken region, bounded.
    win = max(FRAME * 3, int(0.08 * spoken))
    lo = energy_floor_index(samples, lo_est - win, lo_est + win) if pre else 0
    hi = (energy_floor_index(samples, hi_est - win, hi_est + win) + FRAME
          if post else len(samples))
    return samples[lo:max(hi, lo + FRAME)]


def synth(text, target, left, right, silence, seed):
    rng = np.random.default_rng(seed)
    gap = np.zeros(int(silence * SR), dtype=np.float32)
    parts, spans = [], plan(text, target, left, right)
    for i, (pre, span, post) in enumerate(spans):
        s = synth_span(pre, span, post, rng)
        if i:
            parts.append(gap)
        parts.append(s)
        print(f"    span {i+1}/{len(spans)} target={len(span):3d} "
              f"ctx=-{len(pre)}/+{len(post)} window={len(pre)+len(span)+len(post):3d} "
              f"-> {len(s)/SR:5.2f}s")
    return np.concatenate(parts), spans


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--keys", default="p1,p2")
    ap.add_argument("--target", type=int, default=70)
    ap.add_argument("--left", type=int, default=0)
    ap.add_argument("--right", type=int, default=45)
    ap.add_argument("--silence", type=float, default=0.05)
    ap.add_argument("--seed", type=int, default=1234)
    args = ap.parse_args()

    src = json.load(open("paragraphs.json"))
    for key in args.keys.split(","):
        name = f"ctx-{key}-t{args.target}-l{args.left}-r{args.right}"
        print(f"\n[{name}]")
        out, spans = synth(src[key], args.target, args.left, args.right,
                           args.silence, args.seed)
        R.write_wav(f"out/{name}.wav", out)
        print(f"    -> out/{name}.wav  {len(out)/SR:.2f}s  ({len(spans)} spans)")
