#!/usr/bin/env python3
"""Diff Swift phonemizer output against canonical Misaki output.

Inputs are the JSONL files from `fluidaudiocli phonemize-parity` (Swift) and
`misaki_dump.py` (reference). Words are aligned per line with SequenceMatcher;
tokenization differences (e.g. Misaki keeps "1999" as one token, the Swift
normalizer pre-expands it) are compared as joined regions. Mismatches are
clustered into heuristic classes and ranked. Where the Misaki dump carries the
whole line's phonemes, each punctuation mark's spacing (a space before it, a
space after it) is compared too; the Swift line is its words joined by spaces,
which is exactly the string the model receives.

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


def punctuation_spacing(line_phonemes):
    """Each punctuation mark with whether a space sits before and after it."""
    p = unicodedata.normalize("NFC", line_phonemes)
    marks = []
    for k, ch in enumerate(p):
        if ch in PUNCT_PHONEMES:
            before = k == 0 or p[k - 1] == " "
            after = k == len(p) - 1 or p[k + 1] == " "
            marks.append((ch, before, after, k))
    return marks


def spacing_label(before, after):
    return ("␣" if before else "") + "x" + ("␣" if after else "")


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

    spacing_units = 0
    spacing = []  # (mark, swift label, misaki label, swift line, misaki line, line_i)
    for i in shared:
        misaki_line = misaki_lines[i].get("phonemes")
        if misaki_line is None:
            continue
        swift_line = " ".join(w["phonemes"] for w in swift_lines[i]["words"])
        smarks = punctuation_spacing(swift_line)
        mmarks = punctuation_spacing(misaki_line)
        matcher = SequenceMatcher(None, [m[0] for m in smarks], [m[0] for m in mmarks], autojunk=False)
        for op, s1, s2, m1, m2 in matcher.get_opcodes():
            if op != "equal":
                continue
            for sm, mm in zip(smarks[s1:s2], mmarks[m1:m2]):
                spacing_units += 1
                if sm[1:3] != mm[1:3]:
                    spacing.append((sm[0], spacing_label(*sm[1:3]), spacing_label(*mm[1:3]), swift_line, misaki_line, i))

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

    if spacing_units:
        print(f"punctuation marks compared: {spacing_units}")
        print(f"spacing mismatches:         {len(spacing)} ({100.0 * len(spacing) / spacing_units:.2f}%)")
        kinds = Counter((mark, sl, ml) for mark, sl, ml, _, _, _ in spacing)
        for (mark, sl, ml), c in kinds.most_common():
            example = next(e for e in spacing if e[:3] == (mark, sl, ml))
            print(f"  {c:4d}x {mark!r} swift {sl} misaki {ml}: swift={example[3][:80]!r} misaki={example[4][:80]!r}")
        print()

    if args.tsv:
        with open(args.tsv, "w", encoding="utf-8") as out:
            out.write("class\tline\tword\tswift\tmisaki\n")
            for cls, sw, sp, mp, i in mismatches:
                out.write(f"{cls}\t{i}\t{sw}\t{sp}\t{mp}\n")
        print(f"wrote {len(mismatches)} rows to {args.tsv}")


if __name__ == "__main__":
    main()
