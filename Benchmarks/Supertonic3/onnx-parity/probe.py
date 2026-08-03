"""Three-way probe of the Supertonic text stages.

For a ladder of real-prose fragments of increasing length, compare:
  A. ONNX at the fragment's exact token length  (what the reference/demo does)
  B. ONNX zero-padded to 128 with a mask        (what our export's shape forces)
  C. CoreML frozen at 128                       (what we actually ship)

A vs B isolates the padding; B vs C isolates the conversion.
"""
import json
import sys

import numpy as np

from supertonic_ref import Encoder, coreml_models, load_style, onnx_sessions, preprocess

SRC = json.load(open("paragraphs.json"))
enc = Encoder()
ttl, dp_style = load_style()
te_onnx, dp_onnx = onnx_sessions()
te_ml, dp_ml = coreml_models("cpu")


def ladder(text, steps=14):
    """Word-boundary prefixes of `text` spanning short → long."""
    words = text.split()
    out, seen = [], set()
    for n in range(1, len(words) + 1):
        frag = " ".join(words[:n])
        L = len(preprocess(frag))
        if L in seen:
            continue
        seen.add(L)
        out.append((L, frag))
    # sample evenly across the achieved length range
    lo, hi = out[0][0], out[-1][0]
    targets = np.linspace(lo, hi, steps)
    picks, used = [], set()
    for t in targets:
        best = min(out, key=lambda p: abs(p[0] - t))
        if best[0] not in used:
            used.add(best[0])
            picks.append(best)
    return picks


def run_onnx(ids, mask):
    d = dp_onnx.run(None, {"text_ids": ids, "text_mask": mask, "style_dp": dp_style})[0]
    e = te_onnx.run(None, {"text_ids": ids, "text_mask": mask, "style_ttl": ttl})[0]
    return float(np.ravel(d)[0]), e


def run_coreml(ids, mask):
    d = dp_ml.predict({"text_ids": ids.astype(np.int32), "text_mask": mask,
                       "style_dp": dp_style})["duration"]
    e = te_ml.predict({"text_ids": ids.astype(np.int32), "text_mask": mask,
                       "style_ttl": ttl})["text_emb"]
    return float(np.ravel(d)[0]), np.array(e)


def emb_diff(a, b, valid):
    """Max/mean abs difference over the valid (unpadded) text positions."""
    a = np.asarray(a).reshape(a.shape[-2], a.shape[-1])[:, :valid]
    b = np.asarray(b).reshape(b.shape[-2], b.shape[-1])[:, :valid]
    d = np.abs(a - b)
    scale = max(np.abs(a).max(), 1e-9)
    return d.max(), d.mean(), d.max() / scale


rows = []
print(f"{'len':>4} {'chars':>6} | {'ONNX exact':>10} {'ONNX pad128':>11} {'CoreML 128':>10} "
      f"| {'pad/exact':>9} {'ml/pad':>7} | {'emb pad-vs-exact':>16} {'emb ml-vs-pad':>13}")
print("-" * 118)

for key in ("p1", "p2"):
    for L, frag in ladder(SRC[key], steps=12):
        over = L > 128
        ids_e, mask_e, _ = enc.encode(frag, pad_to=None)
        ids_p, mask_p, _ = enc.encode(frag, pad_to=128)
        valid = min(L, 128)

        d_exact, e_exact = run_onnx(ids_e, mask_e)
        d_pad, e_pad = run_onnx(ids_p, mask_p)
        d_ml, e_ml = run_coreml(ids_p, mask_p)

        pe_max, pe_mean, pe_rel = emb_diff(e_pad, e_exact, valid)
        mp_max, mp_mean, mp_rel = emb_diff(e_ml, e_pad, valid)

        flag = " *TRUNC*" if over else ""
        print(f"{L:>4} {len(frag):>6} | {d_exact:>10.3f} {d_pad:>11.3f} {d_ml:>10.3f} "
              f"| {d_pad/d_exact:>9.3f} {d_ml/d_pad:>7.3f} "
              f"| {pe_max:>7.4f} ({pe_rel*100:>5.1f}%) {mp_max:>6.4f} ({mp_rel*100:>4.1f}%){flag}")
        rows.append(dict(key=key, tok_len=L, chars=len(frag), d_exact=d_exact,
                         d_pad=d_pad, d_ml=d_ml, emb_pad_max=float(pe_max),
                         emb_pad_rel=float(pe_rel), emb_ml_max=float(mp_max),
                         emb_ml_rel=float(mp_rel)))
    print()

json.dump(rows, open("probe.json", "w"), indent=1)
print("wrote probe.json")
