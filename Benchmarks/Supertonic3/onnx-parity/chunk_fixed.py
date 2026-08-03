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

Everything else -- paragraph split, abbreviation guard, comma then word
fallbacks, the packing order -- is deliberately unchanged, so an A/B isolates
these two.
"""
import re
import unicodedata as ud

WINDOW = 128
WRAPPER = len("<xx></xx>")
APPENDED_PERIOD = 1
CAP = WINDOW - WRAPPER - APPENDED_PERIOD          # 118

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


def slen(s):
    """Length in the unit the 128-token window actually counts."""
    return len(ud.normalize("NFKD", s))


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


def _pack_words(phrase, mx, into):
    cur = ""
    for w in phrase.split():
        if cur and slen(cur) + slen(w) + 1 > mx:
            into.append(cur)
            cur = ""
        cur = w if not cur else f"{cur} {w}"
    if cur.strip():
        into.append(cur.strip())


def _pack_commas(sentence, mx, into):
    cur = ""
    for raw in sentence.split(","):
        part = raw.strip()
        if not part:
            continue
        if slen(part) > mx:
            if cur.strip():
                into.append(cur.strip())
            cur = ""
            _pack_words(part, mx, into)
            continue
        if cur and slen(cur) + slen(part) + 2 > mx:
            into.append(cur)
            cur = ""
        cur = part if not cur else f"{cur}, {part}"
    if cur.strip():
        into.append(cur.strip())


def chunk(text, mx=CAP):
    out, cur = [], ""
    for para in re.split(r"\n\s*\n", text.strip()):
        para = para.strip()
        if not para:
            continue
        if slen(para) <= mx:
            out.append(para)
            continue
        for s in split_sentences(para):
            if slen(s) > mx:
                if cur.strip():
                    out.append(cur.strip())
                cur = ""
                _pack_commas(s, mx, out)
                continue
            if cur and slen(cur) + slen(s) + 1 > mx:
                out.append(cur)
                cur = ""
            cur = s if not cur else f"{cur} {s}"
        if cur.strip():
            out.append(cur.strip())
            cur = ""
    return out
