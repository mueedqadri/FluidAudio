"""What unit should the chunk cap be measured in?

`Supertonic3TextChunker` compares against Swift `String.count` -- extended
grapheme clusters -- while the 128-token window counts unicode scalars after
NFKD. For Latin those agree exactly and the mismatch is invisible. Elsewhere
they do not, and the encoder silently discards whatever does not fit.

The reference implementations do not agree with each other either. All four
name the same function and the same constant 300, and all four mean something
different by it on non-Latin text:

    py/helper.py      len(str)          code points
    web/helper.js     .length           UTF-16 code units
    swift/Helper.swift .count           grapheme clusters   <- what we mirror
    rust/src/helper.rs .len()           UTF-8 BYTES

Upstream never feels this because their ONNX text axis is symbolic: the unit
changes chunk size, never correctness. Freezing T at 128, as every CoreML port
does, turns the Swift choice into a truncation bug.

Both upstream *encoders* get it right -- `unicodeScalars.count` in Swift (with
a comment saying why), `.chars().count()` in Rust. The insight just never
reached the chunker.

Run this to reproduce the three findings:
  1. per-language expansion, cluster vs scalar
  2. the largest safe cap in Characters, per language, and where it ships
  3. that ONE cap in post-NFKD scalars serves every language, so the
     per-language table is not needed at all
"""
import unicodedata as ud

from supertonic_ref import Encoder, preprocess

WINDOW = 128
WRAPPER = len("<xx></xx>")   # 9; every Supertonic language code is 2 letters
APPENDED_PERIOD = 1
UNIVERSAL_CAP = WINDOW - WRAPPER - APPENDED_PERIOD   # 118

VIRAMA = "्"
SHIPS = {"ko": 57, "ja": 57}       # maxChunkLengthCJK; everything else:
SHIPS_DEFAULT = 70                 # maxChunkLengthLatin

SAMPLES = {
    "en": "The morning air was cool and the light came in from the side. ",
    "de": "Die Morgenluft war kuehl und das Licht fiel von der Seite ein. ",
    "ru": "Утренний воздух "
          "был прохладным, "
          "и свет падал "
          "сбоку в окно. ",
    "hi": "सुबह की हवा में "
          "हल्की ठंडक थी और "
          "रोशनी बगल से आ "
          "रही थी। ",
    "vi": "Không khí buổi sáng mát mẻ và ánh sáng "
          "chiếu xiên vào phòng. ",
    "ar": "كان هواء الصباح "
          "باردا وكان الضوء "
          "يدخل من الجانب. ",
    "ko": "아침 공기는 서늘했고 빛이 "
          "비스듬히 들어왔다. ",
    "ja": "朝の空気は涼しく、光が斜めに"
          "差し込んでいた。",
}

enc = Encoder()


def extends(c, prev):
    return ud.category(c) in ("Mn", "Mc", "Me") or prev == VIRAMA


def clusters(s):
    """Swift String.count."""
    n = i = 0
    while i < len(s):
        i += 1
        while i < len(s) and extends(s[i], s[i - 1]):
            i += 1
        n += 1
    return n


def cluster_prefix(s, n):
    i = k = 0
    while i < len(s) and k < n:
        i += 1
        while i < len(s) and extends(s[i], s[i - 1]):
            i += 1
        k += 1
    return i


def scalar_prefix(s, n):
    """Largest prefix whose NFKD form is <= n scalars."""
    lo, hi = 0, len(s)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if len(ud.normalize("NFKD", s[:mid])) <= n:
            lo = mid
        else:
            hi = mid - 1
    return lo


def tokens(text, lang):
    return len(enc.ids_for(preprocess(text, lang)))


def main():
    print("1. Expansion: one Swift Character costs how many tokens?\n")
    print(f"   {'lang':5}{'scalars/Char':>14}{'tokens/Char':>13}")
    for lang, s in SAMPLES.items():
        t = s * 10
        c = clusters(t)
        print(f"   {lang:5}{len(t)/c:>14.2f}{len(ud.normalize('NFKD', t))/c:>13.2f}")

    print("\n2. Largest cap in Characters that still fits the window,"
          " against what ships:\n")
    print(f"   {'lang':5}{'safe':>6}{'ships':>7}   verdict")
    for lang, s in SAMPLES.items():
        t = s * 10
        safe = 0
        for cap in range(1, 250):
            end = cluster_prefix(t, cap)
            if end >= len(t):
                break
            if tokens(t[:end], lang) <= WINDOW:
                safe = cap
            else:
                break
        ships = SHIPS.get(lang, SHIPS_DEFAULT)
        if ships > safe:
            v = "SHIPPING CAP ALREADY OVERFLOWS"
        elif 110 > safe:
            v = "a 110 cap would truncate"
        else:
            v = "ok, and ok at 110"
        print(f"   {lang:5}{safe:>6}{ships:>7}   {v}")

    print(f"\n3. One cap of {UNIVERSAL_CAP} post-NFKD scalars, every language:\n")
    print(f"   {'lang':5}{'chars':>7}{'tokens':>8}")
    ok = True
    for lang, s in SAMPLES.items():
        t = s * 10
        n = scalar_prefix(t, UNIVERSAL_CAP)
        tok = tokens(t[:n], lang)
        ok &= tok <= WINDOW
        print(f"   {lang:5}{n:>7}{tok:>8}{'' if tok <= WINDOW else '  OVER'}")
    print(f"\n   verdict: {'HOLDS' if ok else 'FAILS'} -- "
          f"{'maxChunkLengthCJK is unnecessary' if ok else 'a per-language table is needed'}")


if __name__ == "__main__":
    main()
