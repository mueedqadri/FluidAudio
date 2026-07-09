#!/usr/bin/env python3
"""Diff Swift phonemizer output against canonical Misaki output.

Inputs are the JSONL files from `fluidaudiocli phonemize-parity` (Swift) and
`misaki_dump.py` (reference). Words are aligned per line with SequenceMatcher;
tokenization differences (e.g. Misaki keeps "1999" as one token, the Swift
normalizer pre-expands it) are compared as joined regions. Mismatches are
clustered into heuristic classes and ranked.

Usage:
  python3 diff_report.py --swift swift.jsonl --misaki misaki.jsonl \
    --tsv mismatches.tsv [--examples 8]
"""

import argparse
import json
import re
import unicodedata
from collections import Counter, defaultdict
from difflib import SequenceMatcher

PUNCT_PHONEMES = set(';:,.!?—…"“”()')
STRESS_MARKS = str.maketrans("", "", "ˈˌ")
CURRENCY = set("$£€")


def load(path):
    lines = {}
    with open(path, encoding="utf-8") as f:
        for row in f:
            obj = json.loads(row)
            lines[obj["i"]] = obj
    return lines


def align_key(word):
    w = unicodedata.normalize("NFC", word).replace("’", "'")
    w = "".join(ch for ch in w if ch.isalnum() or ch == "'")
    return w.strip("'").lower()


def clean_phonemes(p):
    p = unicodedata.normalize("NFC", p)
    p = "".join(ch for ch in p if ch not in PUNCT_PHONEMES)
    return re.sub(r"\s+", " ", p).strip()


def stress_free(p):
    return p.translate(STRESS_MARKS)


def classify(source_text, swift_p, misaki_p):
    swift_oov = "<OOV" in swift_p
    misaki_oov = "<OOV" in misaki_p or "❓" in misaki_p
    if swift_oov and misaki_oov:
        return "oov-both"
    if swift_oov:
        return "oov-swift-only"
    if misaki_oov:
        return "oov-misaki-only"
    if any(ch.isdigit() for ch in source_text) or any(ch in CURRENCY for ch in source_text):
        return "digits-normalization"
    if stress_free(swift_p) == stress_free(misaki_p):
        return "stress-only"
    lowered = source_text.lower()
    if lowered.endswith("'s") or lowered.endswith("s'"):
        return "possessive"
    if lowered.endswith("ed"):
        return "suffix-ed"
    if lowered.endswith("ing"):
        return "suffix-ing"
    if lowered.endswith("s"):
        return "suffix-s"
    if "-" in source_text.strip("-"):
        return "hyphenated"
    if "'" in source_text or "’" in source_text:
        return "apostrophe"
    if source_text[:1].isupper():
        return "capitalized"
    return "other"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift", required=True)
    parser.add_argument("--misaki", required=True)
    parser.add_argument("--tsv", default=None)
    parser.add_argument("--examples", type=int, default=8)
    args = parser.parse_args()

    swift_lines = load(args.swift)
    misaki_lines = load(args.misaki)
    shared = sorted(set(swift_lines) & set(misaki_lines))

    total_units = 0
    mismatches = []  # (class, source_text, swift_p, misaki_p, line_i)

    for i in shared:
        stoks = [
            (w["word"], clean_phonemes(w["phonemes"]))
            for w in swift_lines[i]["words"]
            if align_key(w["word"])
        ]
        mtoks = [
            (w["word"], clean_phonemes(w["phonemes"]))
            for w in misaki_lines[i]["words"]
            if align_key(w["word"])
        ]
        skeys = [align_key(w) for w, _ in stoks]
        mkeys = [align_key(w) for w, _ in mtoks]

        for op, s1, s2, m1, m2 in SequenceMatcher(None, skeys, mkeys, autojunk=False).get_opcodes():
            if op == "equal":
                for (sw, sp), (_, mp) in zip(stoks[s1:s2], mtoks[m1:m2]):
                    total_units += 1
                    if sp != mp:
                        mismatches.append((classify(sw, sp, mp), sw, sp, mp, i))
            else:
                total_units += 1
                sw = " ".join(w for w, _ in mtoks[m1:m2]) or " ".join(w for w, _ in stoks[s1:s2])
                sp = " ".join(p for _, p in stoks[s1:s2])
                mp = " ".join(p for _, p in mtoks[m1:m2])
                if clean_phonemes(sp) != clean_phonemes(mp):
                    mismatches.append((classify(sw, sp, mp), sw, sp, mp, i))

    by_class = defaultdict(Counter)
    for cls, sw, sp, mp, _ in mismatches:
        by_class[cls][(sw, sp, mp)] += 1

    print(f"lines compared: {len(shared)}")
    print(f"units compared: {total_units}")
    print(f"mismatches:     {len(mismatches)} ({100.0 * len(mismatches) / max(total_units, 1):.2f}%)")
    print()
    for cls, counter in sorted(by_class.items(), key=lambda kv: -sum(kv[1].values())):
        n = sum(counter.values())
        print(f"== {cls}: {n} mismatches, {len(counter)} distinct ==")
        for (sw, sp, mp), c in counter.most_common(args.examples):
            print(f"  {c:4d}x {sw!r}: swift={sp!r} misaki={mp!r}")
        print()

    if args.tsv:
        with open(args.tsv, "w", encoding="utf-8") as out:
            out.write("class\tline\tword\tswift\tmisaki\n")
            for cls, sw, sp, mp, i in mismatches:
                out.write(f"{cls}\t{i}\t{sw}\t{sp}\t{mp}\n")
        print(f"wrote {len(mismatches)} rows to {args.tsv}")


if __name__ == "__main__":
    main()
