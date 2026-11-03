#!/usr/bin/env python3
"""Convert NLTK's averaged_perceptron_tagger_eng into EnglishPOSTagger.bin.

The Kokoro English frontend tags parts of speech with this model instead of
NLTagger, whose lexical classes are all `OtherWord` on iOS 27. Source:
https://raw.githubusercontent.com/nltk/nltk_data/gh-pages/packages/taggers/averaged_perceptron_tagger_eng.zip
(MIT, see ThirdPartyLicenses/averaged-perceptron-tagger-LICENSE.md).

Layout, little-endian:
  "FAPT", UInt32 version
  Float64 weight scale (weight = Int16 * scale)
  UInt32 class count, then per class: UInt8 length + UTF-8 Penn tag
  UInt32 tagdict count, then per entry: UInt8 length + UTF-8 word, UInt8 class
  UInt32 feature count N
  N x UInt64 FNV-1a hash of the UTF-8 feature string, ascending
  N x UInt8 weight count per feature
  per weight, in feature order: UInt8 class, then all Int16 values

Int16 weights move 38 of 2.44M corpus tags against NLTK's float64 model.

Usage: generate_english_pos_tagger.py <averaged_perceptron_tagger_eng dir> <output.bin>
"""

import json
import os
import struct
import sys

VERSION = 1


def fnv1a64(text: str) -> int:
    h = 0xCBF29CE484222325
    for byte in text.encode("utf-8"):
        h ^= byte
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def short_string(text: str) -> bytes:
    data = text.encode("utf-8")
    assert len(data) < 256, text
    return struct.pack("<B", len(data)) + data


def main() -> None:
    source, out_path = sys.argv[1], sys.argv[2]
    prefix = os.path.join(source, "averaged_perceptron_tagger_eng")
    weights = json.load(open(prefix + ".weights.json", encoding="utf-8"))
    tagdict = json.load(open(prefix + ".tagdict.json", encoding="utf-8"))
    classes = sorted(json.load(open(prefix + ".classes.json", encoding="utf-8")))
    class_index = {tag: i for i, tag in enumerate(classes)}

    scale = max(abs(w) for per in weights.values() for w in per.values()) / 32767

    hashed = {}
    for feature, per in weights.items():
        h = fnv1a64(feature)
        assert h not in hashed, f"hash collision on {feature!r}"
        hashed[h] = per

    out = bytearray(b"FAPT")
    out += struct.pack("<I", VERSION)
    out += struct.pack("<d", scale)
    out += struct.pack("<I", len(classes))
    for tag in classes:
        out += short_string(tag)
    out += struct.pack("<I", len(tagdict))
    for word in sorted(tagdict):
        out += short_string(word) + struct.pack("<B", class_index[tagdict[word]])

    order = sorted(hashed)
    out += struct.pack("<I", len(order))
    out += b"".join(struct.pack("<Q", h) for h in order)
    out += bytes(len(hashed[h]) for h in order)
    pairs = [(class_index[tag], round(w / scale)) for h in order for tag, w in sorted(hashed[h].items())]
    out += bytes(c for c, _ in pairs)
    out += b"".join(struct.pack("<h", q) for _, q in pairs)

    with open(out_path, "wb") as f:
        f.write(out)
    print(f"{len(classes)} classes, {len(tagdict)} tagdict words, {len(order)} features, "
          f"{len(pairs)} weights, {len(out)} bytes")


if __name__ == "__main__":
    main()
