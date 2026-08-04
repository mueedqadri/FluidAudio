"""Where do the seams land, and does the listener expect a break there?

A seam is a chunk boundary. Supertonic ends every chunk as its own utterance,
so a seam the text did not ask for is heard as an invented full stop. This
counts them without synthesizing anything: a chunk that already ends in real
punctuation is a seam the reader was expecting, and one that does not is a
fabricated ending — `preprocess` appends the period itself.

    python3 seam_audit.py
"""
import supertonic_ref as S
import chunk_fixed as F

REAL_ENDINGS = ".!?;:,…।॥؟。！？、，；："

PARAGRAPH = (
    "The abnormal mind is quick to detect and attach itself to this quality "
    "when it appears in a normal person, and so it came about that in college "
    "I was unjustly accused of being a politician, because I was privy to the "
    "secret griefs of wild, unknown men. Most of the confidences were "
    "unsought﻿—frequently I have feigned sleep, preoccupation, or a "
    "hostile levity when I realized by some unmistakable sign that an intimate "
    "revelation was quivering on the horizon; the intimate revelations of "
    "young men, or at least the terms in which they express them, are usually "
    "plagiaristic and marred by obvious suppressions."
)


def audit(text, lang="en"):
    chunks = F.chunk(text)
    invented, orphans = 0, 0
    print(f"{len(chunks)} chunks")
    for i, c in enumerate(chunks):
        processed = S.preprocess(c, lang)
        expected = c.rstrip()[-1:] in REAL_ENDINGS
        words = len(c.split())
        if not expected:
            invented += 1
        if words <= 2:
            orphans += 1
        flag = "" if expected else "   <-- invented ending"
        if words <= 2:
            flag += "   <-- orphan"
        print(f"  {i}  tok={len(processed):3d} words={words:3d}  {c!r}{flag}")
    print(f"\ninvented endings: {invented}/{len(chunks)}   orphans: {orphans}")
    over = [c for c in chunks if len(S.preprocess(c, lang)) > 128]
    print(f"over the 128-token window: {len(over)}")


if __name__ == "__main__":
    audit(PARAGRAPH)
