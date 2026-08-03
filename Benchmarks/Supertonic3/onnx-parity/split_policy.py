"""Where should an over-long run be split?

Three word-packing policies compared on the real corpus at a 110-character cap:

  greedy   -- fill to the cap, dump the remainder (what ships today)
  balanced -- n = ceil(len/cap) pieces of roughly even length
  phrase   -- latest split point that lands before a phrase-opening word,
              falling back to greedy when none is available

Only runs that already exceed the cap reach these; sentence and comma
boundaries are handled upstream exactly as production does.
"""
import json
import math

import chunk_sim as C

# Words that open a phrase, so a break immediately before one reads as a
# breath rather than a cut through the middle of a noun phrase.
#
# Deliberately excludes words that are only sometimes phrase-initial --
# "since", "as", "that", "so", "if", "than". "he had long | since forgotten"
# is the cautionary case: "since" there is part of the idiom "long since",
# and breaking before it is exactly the seam that reads as a false stop.
OPENERS = {
    "and", "but", "or", "nor", "yet", "for", "with", "without", "from",
    "into", "onto", "upon", "which", "who", "whom", "whose", "when",
    "where", "while", "because", "although", "though", "after",
    "before", "until", "unless", "whether",
}
FLOOR = 0.55  # never take a phrase break shorter than this fraction of the cap


def _window(words, i, mx):
    """Widest j such that words[i:j] still fits the cap."""
    j, ln = i, 0
    while j < len(words):
        add = len(words[j]) + (1 if j > i else 0)
        if ln + add > mx:
            break
        ln += add
        j += 1
    return max(j, i + 1)


def pack_greedy(run, mx):
    words, out, i = run.split(), [], 0
    while i < len(words):
        j = _window(words, i, mx)
        out.append(" ".join(words[i:j]))
        i = j
    return out


def pack_balanced(run, mx):
    n = max(1, math.ceil(len(run) / mx))
    target = len(run) / n
    out, cur = [], ""
    for w in run.split():
        cand = w if not cur else cur + " " + w
        if cur and (len(cand) > mx or (len(out) < n - 1 and len(cur) >= target)):
            out.append(cur)
            cur = w
        else:
            cur = cand
    if cur.strip():
        out.append(cur.strip())
    return out


def pack_phrase(run, mx):
    words, out, i = run.split(), [], 0
    floor = mx * FLOOR
    while i < len(words):
        j = _window(words, i, mx)
        if j < len(words):
            best = None
            for k in range(i + 1, j + 1):
                if k < len(words) and words[k].lower().strip(",;:").lstrip("(") in OPENERS:
                    if len(" ".join(words[i:k])) >= floor:
                        best = k
            j = best or j
        out.append(" ".join(words[i:j]))
        i = j
    return out


def pack_both(run, mx):
    """Balanced target, but snapped to a phrase opening when one is near it.

    Balance alone only relocates a bad seam; phrase alone takes the latest
    opener, which is often the worst one in the window. Aiming at the balanced
    target and picking the opener nearest to it gets both.
    """
    words = run.split()
    n = max(1, math.ceil(len(run) / mx))
    out, i, left = [], 0, n
    while i < len(words):
        j = _window(words, i, mx)
        if j < len(words) and left > 1:
            remaining = len(" ".join(words[i:]))
            target = remaining / left
            cands = [k for k in range(i + 1, j + 1)
                     if k < len(words)
                     and words[k].lower().strip(",;:").lstrip("(") in OPENERS
                     and len(" ".join(words[i:k])) >= mx * FLOOR]
            if cands:
                j = min(cands, key=lambda k: abs(len(" ".join(words[i:k])) - target))
            else:  # no opener -- fall back to an even split at a word boundary
                j = min(range(i + 1, j + 1),
                        key=lambda k: abs(len(" ".join(words[i:k])) - target))
        out.append(" ".join(words[i:j]))
        i, left = j, left - 1
    return out


PACK = {"greedy": pack_greedy, "balanced": pack_balanced,
        "phrase": pack_phrase, "both": pack_both}


def chunk(text, mx, policy):
    """Production chunker with only the word-packing step swapped out."""
    pack = PACK[policy]
    ch, cur = [], ""
    for s in C.split_sentences(text.strip()):
        s = s.strip()
        if not s:
            continue
        if len(s) > mx:
            if cur.strip():
                ch.append(cur.strip())
            cur = ""
            buf = ""
            for part in (x.strip() for x in s.split(",")):
                if not part:
                    continue
                if len(part) > mx:
                    if buf.strip():
                        ch.append(buf.strip())
                    buf = ""
                    ch.extend(pack(part, mx))
                    continue
                if len(buf) + len(part) + 2 > mx and buf:
                    ch.append(buf)
                    buf = ""
                buf = part if not buf else buf + ", " + part
            if buf.strip():
                ch.append(buf.strip())
            continue
        if len(cur) + len(s) + 1 > mx and cur:
            ch.append(cur)
            cur = ""
        cur = s if not cur else cur + " " + s
    if cur.strip():
        ch.append(cur.strip())
    return ch


if __name__ == "__main__":
    CAP = 110
    paras = [l.strip() for l in open("../paragraphs.txt")
             if l.strip() and not l.lstrip().startswith("#")]

    print(f"{'policy':10s}{'chunks':>8}{'mid-clause':>12}{'orphans <=30':>14}{'shortest':>10}")
    print("-" * 54)
    cuts = {}
    for pol in PACK:
        tot = mid = orph = 0
        shortest = 999
        seen = []
        for p in paras:
            cs = chunk(p, CAP, pol)
            tot += len(cs)
            for a, b in zip(cs, cs[1:]):
                if a.rstrip()[-1] not in ".!?":
                    seen.append((a.split()[-1], b.split()[0]))
            for c in cs:
                mid += c.rstrip()[-1] not in ".!?"
                orph += len(c) <= 30
                shortest = min(shortest, len(c))
        cuts[pol] = seen
        print(f"{pol:10s}{tot:>8}{mid:>12}{orph:>14}{shortest:>10}")

    print("\nwhere the mid-clause cuts land   (...last word | first word...)")
    for pol in ("greedy", "phrase"):
        print(f"\n  {pol}:")
        for a, b in cuts[pol]:
            print(f"    ...{a} | {b}...")

    p1 = json.load(open("paragraphs.json"))["p1"]
    print("\nparagraph one, phrase policy:")
    for i, c in enumerate(chunk(p1, CAP, "phrase")):
        t = "TERM" if c.rstrip()[-1] in ".!?" else "MID "
        print(f"  {i + 1}: [{len(c):3}] {t} {c!r}")
