#!/usr/bin/env python3
"""Score how the English frontend reads numbers, symbols and abbreviations.

Each item pairs a written sentence with how a person reads it aloud. Both are
phonemized by `fluidaudiocli phonemize-parity` (EnglishTextNormalizer plus the
KokoroAne phonemizer chain, no Core ML), and an item passes when the written
form's phonemes match one accepted spoken form after stress marks and
punctuation are removed. Accepted forms are the item's own alternatives plus
the style variants in `spoken_variants` ("hundred and five", "the fourth of
June", "twenty fourteen", "oh" for zero), so style is not scored as error.

A word the chain cannot resolve (`<OOV:...>`, which the app hands to the BART
fallback) fails the item unless the spoken form has the same word; names stay
neutral that way. A spoken form may give a reading as IPA in `⟨...⟩` when no
lexicon word spells it (`⟨ɛt ˈɑl⟩`).

Usage:
  swift build --product fluidaudiocli
  python3 Scripts/verbalization/fetch_corpus.py
  python3 Scripts/verbalization/score.py \
      --kokoro-dir <dir with us_lexicon_cache.json> --vocab <ANE/vocab.json>
  python3 Scripts/verbalization/score.py ... --failures Date
  python3 Scripts/verbalization/score.py ... --json results.json
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
CACHE = Path(os.environ.get("VERBALIZATION_CACHE", Path.home() / ".cache" / "fluidaudio" / "verbalization"))

CORPORA = {
    "dograh": CACHE / "dograh-en-US.jsonl",
    "papers": HERE / "papers.jsonl",
}

UNITS = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
TEENS = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
         "seventeen", "eighteen", "nineteen"]
TENS = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
NUMBER_WORD = "|".join(UNITS + TEENS + TENS)
MONTHS = "January|February|March|April|May|June|July|August|September|October|November|December"
ORDINAL_UNITS = "first|second|third|fourth|fifth|sixth|seventh|eighth|ninth"
ORDINAL_WORD = (rf"(?:(?:twenty|thirty) (?:{ORDINAL_UNITS})|{ORDINAL_UNITS}|tenth|eleventh|twelfth|"
                rf"thirteenth|fourteenth|fifteenth|sixteenth|seventeenth|eighteenth|nineteenth|"
                rf"twentieth|thirtieth)")
IPA = re.compile(r"⟨([^⟩]*)⟩")


def spoken_variants(text: str) -> set[str]:
    """Readings of `text` that differ only in accepted style."""
    out = {text}

    def expand(rule):
        for s in list(out):
            for v in rule(s):
                out.add(v)

    # "five hundred sixty five" <-> "five hundred and sixty five".
    expand(lambda s: [re.sub(rf"\b(hundred|thousand|million|billion) (?=(?:{NUMBER_WORD})\b)", r"\1 and ", s)])
    expand(lambda s: [re.sub(rf"\b(hundred|thousand|million|billion) and (?=(?:{NUMBER_WORD})\b)", r"\1 ", s)])
    # "dollars and forty one cents" <-> "dollars forty one cents".
    expand(lambda s: [re.sub(r"\b(dollars?|pounds?|euros?) and\b", r"\1", s)])
    # "June fourth" <-> "the fourth of June".
    expand(lambda s: [re.sub(rf"\b({MONTHS}) ({ORDINAL_WORD})\b", r"the \2 of \1", s)])
    # "twenty fourteen" <-> "two thousand fourteen"; "twenty oh nine" <-> "two thousand nine".
    expand(lambda s: [re.sub(rf"\btwenty ((?:{'|'.join(TEENS + TENS)})(?: (?:{'|'.join(UNITS)}))?)\b", r"two thousand \1", s)])
    expand(lambda s: [re.sub(rf"\btwo thousand ((?:{'|'.join(TEENS + TENS)})(?: (?:{'|'.join(UNITS)}))?)\b", r"twenty \1", s)])
    expand(lambda s: [re.sub(rf"\btwo thousand ({'|'.join(UNITS)})\b", r"twenty oh \1", s)])
    # "seven oh four" <-> "seven zero four".
    expand(lambda s: [re.sub(rf"\b({NUMBER_WORD}) oh\b", r"\1 zero", s)])
    expand(lambda s: [re.sub(rf"\b({NUMBER_WORD}) zero\b", r"\1 oh", s)])
    return out


def spelled_letters(text: str) -> str:
    """Give letters in a spelled run a period so "F D A in" reads "A" as a letter, not the article."""
    return re.sub(r"\b[A-Z](?: [A-Z]\b)+", lambda m: " ".join(c + "." for c in m.group(0).split()), text)


def normalize(words: list[dict], ipa: list[str]) -> tuple[str, set[str]]:
    """Joined phonemes without stress or punctuation, and the unresolved words."""
    oov = set()
    parts = []
    for w in words:
        p = w["phonemes"]
        for m in re.finditer(r"<OOV:([^>]*)>", p):
            token = m.group(1)
            slot = re.fullmatch(r"zzipa(\d+)", token)
            if slot:
                continue
            oov.add(token.lower())
        p = re.sub(r"<OOV:zzipa(\d+)>", lambda m: ipa[int(m.group(1))], p)
        p = re.sub(r"<OOV:([^>]*)>", lambda m: "<" + m.group(1).lower() + ">", p)
        parts.append(p)
    s = "".join(parts)
    s = s.replace("ɾ", "t").replace("T", "t").replace("ʔ", "t")
    s = re.sub(r"[ˈˌː\s.,;:!?\"'“”‘’()\[\]\-—–…/]", "", s)
    return s, oov


def load_items(names: list[str]) -> list[dict]:
    items = []
    for name in names:
        path = CORPORA[name]
        if not path.exists():
            sys.exit(f"missing {path}; run Scripts/verbalization/fetch_corpus.py")
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                item = json.loads(line)
                item["corpus"] = name
                items.append(item)
    return items


def phonemize(lines: list[str], cli: Path, kokoro_dir: str, vocab: str) -> list[list[dict]]:
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = Path(tmp) / "in.corpus", Path(tmp) / "out.jsonl"
        src.write_text("\n".join(lines) + "\n", encoding="utf-8")
        subprocess.run(
            [str(cli), "phonemize-parity", "--input", str(src), "--output", str(dst),
             "--kokoro-dir", kokoro_dir, "--vocab", vocab],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        by_line = {}
        for row in dst.read_text(encoding="utf-8").splitlines():
            j = json.loads(row)
            by_line[j["i"]] = j["words"]
    return [by_line.get(i + 1, []) for i in range(len(lines))]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus", action="append", choices=sorted(CORPORA), help="default: all")
    parser.add_argument("--kokoro-dir", default=os.environ.get(
        "FLUIDAUDIO_KOKORO_DIR", str(Path.home() / ".cache/fluidaudio/Models/kokoro")))
    parser.add_argument("--vocab", default=os.environ.get(
        "FLUIDAUDIO_KOKORO_VOCAB", str(Path.home() / ".cache/fluidaudio/Models/kokoro-82m-coreml/ANE/vocab.json")))
    parser.add_argument("--cli", default=str(REPO / ".build" / "debug" / "fluidaudiocli"))
    parser.add_argument("--failures", metavar="TYPE", help="list the failing items of one type ('all' for every type)")
    parser.add_argument("--json", metavar="PATH", help="write per-item results")
    args = parser.parse_args()

    cli = Path(args.cli)
    if not cli.exists():
        sys.exit(f"missing {cli}; run `swift build --product fluidaudiocli`")
    items = load_items(args.corpus or sorted(CORPORA))

    # One phonemizer run: each item's written line, then each of its accepted spoken lines.
    lines, plan = [], []
    for item in items:
        ipa: list[str] = []

        def slot(m):
            ipa.append(m.group(1))
            return f"zzipa{len(ipa) - 1}"

        forms = set()
        for spoken in [item["spoken"], *item.get("alternatives", [])]:
            forms |= spoken_variants(spoken)
        primary = spelled_letters(IPA.sub(slot, item["spoken"]))
        rest = sorted({spelled_letters(IPA.sub(slot, f)) for f in forms} - {primary})
        spoken_lines = [primary, *rest]
        plan.append((len(lines), len(spoken_lines), ipa))
        lines.append(item["written"])
        lines.extend(spoken_lines)
    words = phonemize(lines, cli, args.kokoro_dir, args.vocab)

    results = []
    for item, (start, count, ipa) in zip(items, plan):
        written, written_oov = normalize(words[start], [])
        matched = strict = False
        for k in range(count):
            spoken, spoken_oov = normalize(words[start + 1 + k], ipa)
            if written == spoken and not written_oov - spoken_oov:
                matched = True
                strict = strict or k == 0
        results.append({
            "id": item.get("id"), "corpus": item["corpus"], "type": item["category"],
            "written": item["written"], "spoken": item["spoken"],
            "pass": matched, "strict": strict,
            "unresolved": sorted(written_oov - normalize(words[start + 1], ipa)[1]) if count else [],
            "ours": " ".join(w["word"] + ("?" if "<OOV:" in w["phonemes"] else "") for w in words[start]),
        })

    by_type = collections.OrderedDict()
    for r in results:
        t = by_type.setdefault((r["corpus"], r["type"]), [0, 0, 0])
        t[0] += 1
        t[1] += r["pass"]
        t[2] += bool(r["unresolved"]) and not r["pass"]
    for corpus in sorted({c for c, _ in by_type}):
        rows = [(t, v) for (c, t), v in by_type.items() if c == corpus]
        total = sum(v[0] for _, v in rows)
        passed = sum(v[1] for _, v in rows)
        strict = sum(r["strict"] for r in results if r["corpus"] == corpus)
        print(f"\n{corpus}: {passed} of {total} ({strict} matching the listed reading exactly)")
        for t, (n, p, u) in sorted(rows, key=lambda r: (r[1][1] / r[1][0], r[0])):
            note = f"   {u} with unresolved words" if u else ""
            print(f"  {t:34s} {p:3d}/{n:<3d}{note}")

    if args.failures:
        for r in results:
            if not r["pass"] and args.failures in ("all", r["type"]):
                print(f"\n[{r['type']}] {r['written']}\n  want: {r['spoken']}\n  ours: {r['ours']}")
    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=1, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
