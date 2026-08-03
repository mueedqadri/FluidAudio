"""Python port of FluidAudio's Supertonic3UnicodeProcessor + model loaders.

Mirrors Supertonic3UnicodeProcessor.swift step for step so the token IDs fed to
the reference ONNX graphs are byte-identical to what the CoreML path receives.
"""
import json
import os
import re
import unicodedata

import numpy as np

ROOT = os.path.expanduser("~/.cache/fluidaudio/Models/supertonic-3")
HERE = os.path.dirname(os.path.abspath(__file__))
TEXT_T_FIXED = 128

_SYMBOL_REPLACEMENTS = [
    ("–", "-"), ("‑", "-"), ("—", "-"), ("_", " "),
    ("“", '"'), ("”", '"'), ("‘", "'"), ("’", "'"),
    ("´", "'"), ("`", "'"), ("[", " "), ("]", " "), ("|", " "),
    ("/", " "), ("#", " "), ("→", " "), ("←", " "),
]
_DECORATIVE = ["♥", "☆", "♡", "©", "\\"]
_EXPRESSIONS = [("@", " at "), ("e.g.,", "for example, "), ("i.e.,", "that is, ")]
_EMOJI_RANGES = [
    (0x1F600, 0x1F64F), (0x1F300, 0x1F5FF), (0x1F680, 0x1F6FF),
    (0x1F700, 0x1F77F), (0x1F780, 0x1F7FF), (0x1F800, 0x1F8FF),
    (0x1F900, 0x1F9FF), (0x1FA00, 0x1FA6F), (0x1FA70, 0x1FAFF),
    (0x2600, 0x26FF), (0x2700, 0x27BF), (0x1F1E6, 0x1F1FF),
]
_TERMINAL_RE = re.compile("[.!?;:,'\"“”‘’)\\]}…。」』】〉》›»]$")


def _is_emoji(cp):
    return any(lo <= cp <= hi for lo, hi in _EMOJI_RANGES)


def preprocess(text, lang="en"):
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not _is_emoji(ord(c)))
    for old, new in _SYMBOL_REPLACEMENTS:
        text = text.replace(old, new)
    for sym in _DECORATIVE:
        text = text.replace(sym, "")
    for old, new in _EXPRESSIONS:
        text = text.replace(old, new)
    for old in [" ,", " .", " !", " ?", " ;", " :", " '"]:
        text = text.replace(old, old[1:])
    for a, b in [('""', '"'), ("''", "'"), ("``", "`")]:
        while a in text:
            text = text.replace(a, b)
    text = re.sub(r"\s+", " ", text).strip()
    if text and not _TERMINAL_RE.search(text):
        text += "."
    return f"<{lang}>{text}</{lang}>"


class Encoder:
    def __init__(self):
        with open(f"{ROOT}/unicode_indexer.json") as f:
            self.indexer = json.load(f)

    def ids_for(self, processed):
        """Unpadded ID list, one entry per unicode scalar."""
        out = []
        for ch in processed:
            v = ord(ch)
            out.append(self.indexer[v] if v < len(self.indexer) else -1)
        return out

    def encode(self, text, lang="en", pad_to=None):
        """Return (ids[1,T], mask[1,1,T], true_len). pad_to=None → exact length."""
        processed = preprocess(text, lang)
        raw = self.ids_for(processed)
        true_len = len(raw)
        if pad_to is None:
            ids, mask = raw, [1.0] * true_len
        else:
            keep = min(true_len, pad_to)
            ids = raw[:keep] + [0] * (pad_to - keep)
            mask = [1.0] * keep + [0.0] * (pad_to - keep)
        return (
            np.array([ids], dtype=np.int64),
            np.array([[mask]], dtype=np.float32),
            true_len,
        )


def load_style():
    with open(f"{ROOT}/voice_styles/M1.json") as f:
        d = json.load(f)
    ttl = np.array(d["style_ttl"]["data"], dtype=np.float32).reshape(d["style_ttl"]["dims"])
    dp = np.array(d["style_dp"]["data"], dtype=np.float32).reshape(d["style_dp"]["dims"])
    return ttl, dp


def onnx_sessions():
    import onnxruntime as ort
    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    te = ort.InferenceSession(f"{HERE}/te.onnx", opts, providers=["CPUExecutionProvider"])
    dp = ort.InferenceSession(f"{HERE}/dp.onnx", opts, providers=["CPUExecutionProvider"])
    return te, dp


def coreml_models(compute="cpu"):
    import coremltools as ct
    unit = {"cpu": ct.ComputeUnit.CPU_ONLY, "all": ct.ComputeUnit.ALL,
            "ane": ct.ComputeUnit.CPU_AND_NE}[compute]
    te = ct.models.CompiledMLModel(f"{ROOT}/TextEncoder.mlmodelc", compute_units=unit)
    dp = ct.models.CompiledMLModel(f"{ROOT}/DurationPredictor.mlmodelc", compute_units=unit)
    return te, dp
