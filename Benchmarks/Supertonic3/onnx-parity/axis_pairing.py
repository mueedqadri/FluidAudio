"""Do the text and latent axes have to bucket independently?

The bucketed VectorEstimator pins `text_emb` at [1, 256, 128], so widening the
text axis means new VE buckets. If T and L are independent that is a cross
product -- 9 files for three buckets each. If a given T implies a bounded L,
they can be paired and it is 3.

Longer text is more audio, so they should be correlated; this measures how
tightly, using the reference duration predictor at its true symbolic length
(ours truncates past 128 tokens and freezes the duration, so it cannot answer).

    python3 axis_pairing.py [--sample N]
"""
import argparse
import html
import math
import re
import unicodedata
import zipfile

import numpy as np

import supertonic_ref as S

SR = 44100
CHUNK_SIZE = 512 * 6
SPEED = 1.05
L_BUCKETS = (128, 256, 512)
T_BUCKETS = (128, 320, 512)

EPUB = (
    "/Users/mueedqadri/Documents/Code/MacReader/MacReader/Resources"
    "/SampleLibrary/the-great-gatsby.epub"
)


def sentences():
    parts = []
    with zipfile.ZipFile(EPUB) as z:
        for name in z.namelist():
            if not name.lower().endswith((".xhtml", ".html", ".htm")):
                continue
            raw = z.read(name).decode("utf-8", "ignore")
            raw = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", raw, flags=re.S | re.I)
            parts.append(html.unescape(re.sub(r"<[^>]+>", " ", raw)))
    text = re.sub(r"\s+", " ", " ".join(parts))
    return [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if len(s.strip()) > 2]


def tokens(s):
    return len(unicodedata.normalize("NFKD", f"<en>{s}</en>"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", type=int, default=240)
    args = ap.parse_args()

    enc = S.Encoder()
    ttl, dp_style = S.load_style()
    _, dp = S.onnx_sessions()

    pool = sentences()
    # Spread the sample across the length range rather than over-weighting the
    # short sentences that dominate any natural corpus.
    pool.sort(key=tokens)
    step = max(1, len(pool) // args.sample)
    picked = pool[::step]

    rows = []
    for s in picked:
        ids, mask, true_len = enc.encode(s, lang="en", pad_to=None)
        dur = float(np.ravel(dp.run(
            None, {"text_ids": ids, "text_mask": mask, "style_dp": dp_style})[0])[0])
        dur = max(0.05, dur / SPEED)
        rows.append((true_len, dur, max(1, math.ceil(dur * SR / CHUNK_SIZE))))

    print(f"{len(rows)} sentences, {rows[0][0]}-{rows[-1][0]} tokens\n")
    print(f"{'text bucket':>12}  {'n':>4}  {'max latent':>10}  {'fits':>6}  paired L")
    lo = 0
    for t in T_BUCKETS:
        band = [r for r in rows if lo < r[0] <= t]
        lo = t
        if not band:
            continue
        worst = max(r[2] for r in band)
        paired = next((b for b in L_BUCKETS if b >= worst), None)
        print(f"{t:>12}  {len(band):>4}  {worst:>10}  "
              f"{str(paired is not None):>6}  L{paired}")

    over = [r for r in rows if r[0] > T_BUCKETS[-1]]
    print(f"\nsentences past the widest text bucket: {len(over)}")

    tok = np.array([r[0] for r in rows], dtype=float)
    lat = np.array([r[2] for r in rows], dtype=float)
    slope = float(np.polyfit(tok, lat, 1)[0])
    print(f"latent frames per text token: {slope:.3f} "
          f"(corr {np.corrcoef(tok, lat)[0,1]:.3f})")
    print(f"L512 covers text up to ~{512/slope:.0f} tokens")


if __name__ == "__main__":
    main()
