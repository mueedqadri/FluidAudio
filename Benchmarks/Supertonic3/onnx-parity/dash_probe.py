"""Does Supertonic pause at an em dash?

The clause is short enough to be one chunk in every variant, so anything that
differs between them comes from the punctuation and nothing else. Reports the
silence runs the model puts inside the utterance, which is where a pause would
have to show up.

    python3 dash_probe.py            # measure only
    python3 dash_probe.py --wav      # also write out/dash_*.wav
"""
import argparse
import os

import numpy as np

import ref_synth as R
import supertonic_ref as S

CLAUSE = "Most of the confidences were unsought{}I have feigned sleep."

VARIANTS = [
    ("emdash-ships", "—"),  # what ships: NFKD keeps it, table maps it to "-"
    ("comma", ", "),
    ("spaced-hyphen", " - "),
    ("period", ". "),  # the pause we are trying to approximate
    ("none", " "),  # floor: no punctuation at all
]

# A run of samples under this RMS counts as silence. 30 ms is shorter than any
# deliberate pause and longer than a stop consonant's closure.
SILENCE_RMS = 0.012
MIN_SILENCE_S = 0.030
WIN = 256


def silence_runs(wav, sr=R.SR):
    """(start_s, duration_s) for every internal silent run."""
    n = len(wav) // WIN
    if n == 0:
        return []
    frames = wav[: n * WIN].reshape(n, WIN)
    quiet = np.sqrt((frames.astype(np.float64) ** 2).mean(axis=1)) < SILENCE_RMS

    runs, start = [], None
    for i, q in enumerate(list(quiet) + [False]):
        if q and start is None:
            start = i
        elif not q and start is not None:
            dur = (i - start) * WIN / sr
            if dur >= MIN_SILENCE_S:
                runs.append((start * WIN / sr, dur))
            start = None
    # Leading/trailing silence is padding, not prosody.
    return [r for r in runs if r[0] > 0.05 and r[0] + r[1] < len(wav) / sr - 0.05]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", action="store_true")
    ap.add_argument("--seed", type=int, default=1234)
    args = ap.parse_args()

    if args.wav:
        os.makedirs("out", exist_ok=True)

    print(f"{'variant':16s} {'tok':>4s} {'dur':>6s}  internal silences")
    for name, joiner in VARIANTS:
        text = CLAUSE.format(joiner)
        processed = S.preprocess(text)
        rng = np.random.default_rng(args.seed)
        wav, dur, tok = R.infer_chunk(text, "exact", rng)
        runs = silence_runs(wav)
        shown = ", ".join(f"{t:.2f}s+{d*1000:.0f}ms" for t, d in runs) or "none"
        print(f"{name:16s} {tok:4d} {dur:6.2f}  {shown}")
        print(f"{'':16s} sees: {processed[4:-5]}")
        if args.wav:
            R.write_wav(f"out/dash_{name}.wav", wav)


if __name__ == "__main__":
    main()
