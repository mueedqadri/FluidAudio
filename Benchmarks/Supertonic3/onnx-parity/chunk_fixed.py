"""The proposed chunker, next to `chunk_sim` which mirrors what ships.

Two changes, both bug fixes rather than tuning:

1. **Measure in the unit the window counts.** The shipping chunker compares
   against Swift `String.count` (grapheme clusters) while the 128-token budget
   counts unicode scalars after NFKD. Measuring in post-NFKD scalars makes ONE
   cap correct for every language: 118 = 128 window - 9 `<xx></xx>` wrapper
   - 1 appended period. Each script then gets its own effective character
   count for free, and `maxChunkLengthCJK` stops being needed.

2. **Recognise how other languages end a sentence.** The shipping splitter is
   `([.!?])\\s+`, so Hindi, Japanese, Chinese, Arabic and Urdu have no sentence
   boundaries at all and fall straight through to the word fallback. CJK also
   does not put a space after its full stop, so the trailing `\\s+` has to be
   optional for those.

3. **Break at semicolons and colons too.** The reference splits on the comma
   alone, so a sentence joined by either has no candidate above the individual
   word and its seams land wherever the budget ran out.

`mx` is measured in window tokens (the preprocessed string, wrapper and all),
not bare characters -- the estimate this module used to carry charged an
appended period unconditionally, and so refused clauses that already ended in
punctuation and fit exactly.
"""
import re

import supertonic_ref as S

WINDOW = 128
CAP = WINDOW

ABBR = ["Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "Sr.", "Jr.", "St.", "Ave.",
        "Rd.", "Blvd.", "Dept.", "Inc.", "Ltd.", "Co.", "Corp.", "etc.",
        "vs.", "i.e.", "e.g.", "Ph.D."]

# Space-separated scripts: the terminator is followed by whitespace.
SPACED_TERMINATORS = ".!?।॥۔؟։。！？"
# CJK and fullwidth marks also end a sentence with no space after them.
UNSPACED_TERMINATORS = "。！？…"

_SENT_RE = re.compile(
    rf"([{re.escape(SPACED_TERMINATORS)}])\s+"
    rf"|([{re.escape(UNSPACED_TERMINATORS)}])\s*")


def slen(s, lang="en"):
    """Tokens `s` occupies once encoded -- what the window actually counts."""
    return len(S.preprocess(s, lang))


def split_sentences(t):
    out, last = [], 0
    for m in _SENT_RE.finditer(t):
        punc = m.group(1) or m.group(2)
        if punc in ".!?" and any(
                (t[last:m.start()].strip() + punc).endswith(a) for a in ABBR):
            continue
        out.append(t[last:m.end()])
        last = m.end()
    if last < len(t):
        out.append(t[last:])
    return [s for s in (x.strip() for x in out) if s] or [t]


def _pack_words(phrase, mx, into, lang):
    cur = ""
    for w in phrase.split():
        if cur and slen(f"{cur} {w}", lang) > mx:
            into.append(cur)
            cur = ""
        cur = w if not cur else f"{cur} {w}"
    if cur.strip():
        into.append(cur.strip())


# Clause separators, one step weaker than a sentence end. The reference splits
# on the comma alone, so a semicolon- or colon-joined sentence has no candidate
# above the individual word. Measured pause at each: comma 290 ms, semicolon
# 366 ms, colon 441 ms -- all three are breaks a listener already expects.
CLAUSE_SEPARATORS = ",;:،؛、，；："


def split_clauses(sentence):
    """Split at clause separators, keeping each one on the part it ends."""
    parts, buf = [], ""
    for ch in sentence:
        buf += ch
        if ch in CLAUSE_SEPARATORS:
            parts.append(buf)
            buf = ""
    if buf:
        parts.append(buf)
    return parts


def _pack_clauses(sentence, mx, into, lang):
    cur = ""
    for raw in split_clauses(sentence):
        part = raw.strip()
        if not part:
            continue
        if slen(part, lang) > mx:
            if cur.strip():
                into.append(cur.strip())
            cur = ""
            _pack_words(part, mx, into, lang)
            continue
        if cur and slen(f"{cur} {part}", lang) > mx:
            into.append(cur)
            cur = ""
        cur = part if not cur else f"{cur} {part}"
    if cur.strip():
        into.append(cur.strip())


def chunk(text, mx=CAP, lang="en"):
    out, cur = [], ""
    for para in re.split(r"\n\s*\n", text.strip()):
        para = para.strip()
        if not para:
            continue
        if slen(para, lang) <= mx:
            out.append(para)
            continue
        for s in split_sentences(para):
            if slen(s, lang) > mx:
                if cur.strip():
                    out.append(cur.strip())
                cur = ""
                _pack_clauses(s, mx, out, lang)
                continue
            if cur and slen(f"{cur} {s}", lang) > mx:
                out.append(cur)
                cur = ""
            cur = s if not cur else f"{cur} {s}"
        if cur.strip():
            out.append(cur.strip())
            cur = ""
    return out
