#!/usr/bin/env python3
"""Check that a frontend change leaves plain prose alone.

`dump` phonemizes two Project Gutenberg books paragraph by paragraph with the
current build; `diff` compares two dumps and lists every word whose phonemes
changed. Run `dump` on the base commit, again on the change, then `diff`.
A normalization change should only touch digits, symbols and the forms it
targets; anything else in the list is a regression to explain.

Usage:
  python3 Scripts/verbalization/prose_check.py dump --out base.jsonl --kokoro-dir ... --vocab ...
  python3 Scripts/verbalization/prose_check.py dump --out change.jsonl --kokoro-dir ... --vocab ...
  python3 Scripts/verbalization/prose_check.py diff base.jsonl change.jsonl
"""

from __future__ import annotations

import argparse
import collections
import difflib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
CACHE = Path(os.environ.get("VERBALIZATION_CACHE", Path.home() / ".cache" / "fluidaudio" / "verbalization"))

# The two books the Misaki parity report uses (Scripts/parity/REPORT.md).
BOOKS = {"gatsby": 64317, "keynes": 15776}


def book_paragraphs(name: str, number: int) -> list[str]:
    path = CACHE / f"pg{number}.txt"
    if not path.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        url = f"https://www.gutenberg.org/cache/epub/{number}/pg{number}.txt"
        path.write_bytes(urllib.request.urlopen(url, timeout=60).read())
    text = path.read_text(encoding="utf-8-sig")
    start = re.search(r"\*\*\* START OF.*?\*\*\*", text)
    end = re.search(r"\*\*\* END OF", text)
    body = text[start.end() if start else 0:end.start() if end else len(text)]
    return [re.sub(r"\s+", " ", p).strip() for p in re.split(r"\n\s*\n", body) if p.strip()]


def dump(args) -> None:
    cli = Path(args.cli)
    if not cli.exists():
        sys.exit(f"missing {cli}; run `swift build --product fluidaudiocli`")
    lines, keys = [], []
    for name, number in BOOKS.items():
        for k, p in enumerate(book_paragraphs(name, number)):
            lines.append(p)
            keys.append(f"{name}:{k}")
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = Path(tmp) / "in.corpus", Path(tmp) / "out.jsonl"
        src.write_text("\n".join(lines) + "\n", encoding="utf-8")
        subprocess.run(
            [str(cli), "phonemize-parity", "--input", str(src), "--output", str(dst),
             "--kokoro-dir", args.kokoro_dir, "--vocab", args.vocab],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        rows = {json.loads(r)["i"]: json.loads(r) for r in dst.read_text(encoding="utf-8").splitlines()}
    with open(args.out, "w", encoding="utf-8") as f:
        for i, key in enumerate(keys):
            row = rows.get(i + 1, {"text": lines[i], "words": []})
            f.write(json.dumps({"key": key, "text": row["text"], "words": row["words"]}, ensure_ascii=False) + "\n")
    print(f"wrote {len(keys)} paragraphs to {args.out}")


def diff(args) -> None:
    def load(path):
        return {r["key"]: r for r in map(json.loads, Path(path).read_text(encoding="utf-8").splitlines())}

    def sounds(row):
        """Phoneme tokens, each with the word it came from; word labels may differ by design."""
        return [(p, w["word"]) for w in row["words"] for p in w["phonemes"].split()]

    base, change = load(args.base), load(args.change)
    changes = collections.Counter()
    shown = 0
    for key, b in base.items():
        c = change.get(key)
        if c is None:
            continue
        bs, cs = sounds(b), sounds(c)
        matcher = difflib.SequenceMatcher(None, [p for p, _ in bs], [p for p, _ in cs], autojunk=False)
        for op, i1, i2, j1, j2 in matcher.get_opcodes():
            if op == "equal":
                continue
            before = " ".join(dict.fromkeys(w for _, w in bs[max(0, i1 - 1):i2 + 1]))
            after = " ".join(dict.fromkeys(w for _, w in cs[max(0, j1 - 1):j2 + 1]))
            changes[(before, after)] += 1
            if shown < args.limit:
                shown += 1
                print(f"{key}: {before!r} [{' '.join(p for p, _ in bs[i1:i2])}]")
                print(f"{' ' * len(key)}  -> {after!r} [{' '.join(p for p, _ in cs[j1:j2])}]")
    total = sum(changes.values())
    print(f"\n{total} changed spans in {len(base)} paragraphs, {len(changes)} distinct")
    for (before, after), n in changes.most_common(args.limit):
        print(f"  {n:4d}  {before!r} -> {after!r}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    d = sub.add_parser("dump")
    d.add_argument("--out", required=True)
    d.add_argument("--kokoro-dir", default=os.environ.get(
        "FLUIDAUDIO_KOKORO_DIR", str(Path.home() / ".cache/fluidaudio/Models/kokoro")))
    d.add_argument("--vocab", default=os.environ.get(
        "FLUIDAUDIO_KOKORO_VOCAB", str(Path.home() / ".cache/fluidaudio/Models/kokoro-82m-coreml/ANE/vocab.json")))
    d.add_argument("--cli", default=str(REPO / ".build" / "debug" / "fluidaudiocli"))
    c = sub.add_parser("diff")
    c.add_argument("base")
    c.add_argument("change")
    c.add_argument("--limit", type=int, default=40)
    args = parser.parse_args()
    dump(args) if args.command == "dump" else diff(args)


if __name__ == "__main__":
    main()
