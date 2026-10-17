#!/usr/bin/env python3
"""Ask the linked NeMo engine how it reads every English abbreviation.

Candidates are NeMo's own whitelist abbreviations (`tts.tsv` words that end in
a period, not letter runs such as `A.D.`), its address words (`St`, `Ave`),
and every entry of our `EnglishAbbreviationTable`. Each is read inside five
frame sentences (before a name, after a street name, in an address, before a
number, alone), so the output says both what NeMo says and where it says it.

NeMo's lists are fetched from NeMo-text-processing at a pinned commit and
checked by sha256 (Apache 2.0, credit: NVIDIA); the readings come from the
grammars `fluidaudiocli nemo-normalize` links, so a list entry the engine
does not read is reported, not trusted.

Usage:
  swift build -c release --product fluidaudiocli
  python3 Scripts/verbalization/abbreviation_map.py --cli .build/release/fluidaudiocli --json readings.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
CACHE = Path(os.environ.get("VERBALIZATION_CACHE", Path.home() / ".cache" / "fluidaudio" / "verbalization"))
TABLE = REPO / "Sources" / "FluidAudio" / "TTS" / "Shared" / "EnglishAbbreviationTable.swift"

NEMO_COMMIT = "cb104cad6d1fc35c5c7941b73f1f728b4b7f63d9"
NEMO_DATA = f"https://raw.githubusercontent.com/NVIDIA/NeMo-text-processing/{NEMO_COMMIT}/nemo_text_processing/text_normalization/en/data"
SOURCES = {
    "nemo-en-whitelist-tts.tsv": (
        f"{NEMO_DATA}/whitelist/tts.tsv",
        "92ee8f555810701ca872fd37e5034b71f9d615908b8f7c8ca79814d8890279ef",
    ),
    "nemo-en-address-word.tsv": (
        f"{NEMO_DATA}/address/address_word.tsv",
        "717165e2be4e84d3388a5a966aef14d0a0590ca0fb7d45c756c8b3ada4a24632",
    ),
}

# Where an abbreviation is read; `X` is replaced by it.
FRAMES = {
    "beforeName": "We met X Smith today.",
    "afterName": "It is on Elm X today.",
    "address": "It is at 12 Elm X today.",
    "beforeNumber": "See X 4 today.",
    "alone": "It was X today.",
}
NEUTRAL = "zebra"


def fetch(name: str) -> str:
    url, sha256 = SOURCES[name]
    path = CACHE / name
    if not path.exists():
        CACHE.mkdir(parents=True, exist_ok=True)
        path.write_bytes(urllib.request.urlopen(url, timeout=60).read())
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if sha256 and digest != sha256:
        sys.exit(f"{name}: sha256 {digest}, expected {sha256}")
    return data.decode("utf-8")


def nemo_candidates() -> dict[str, str]:
    """NeMo's whitelist words that end in a period, and its address words."""
    listed = {}
    for line in fetch("nemo-en-whitelist-tts.tsv").splitlines():
        written, _, spoken = line.partition("\t")
        if not written.endswith(".") or re.fullmatch(r"(?:[A-Za-z]\.\s?)+", written):
            continue
        if not re.fullmatch(r"[A-Za-z][A-Za-z.]*\.", written):
            continue
        listed.setdefault(written, spoken)
    for line in fetch("nemo-en-address-word.tsv").splitlines():
        written, _, spoken = line.partition("\t")
        if written and written != spoken.lower():
            listed.setdefault(written.capitalize() + ".", spoken)
    return listed


def table_candidates() -> dict[str, str]:
    """Written forms and readings of our table, as NeMo would see them in text."""
    source = TABLE.read_text(encoding="utf-8")
    found = {}
    for block, suffix in (("titles", "."), ("beforeNumber", "."), ("afterNumber", "s")):
        body = re.search(rf"private static let {block}: \[Entry\] = \[(.*?)\]\.map", source, re.S)
        for written, spoken in re.findall(r'\("([^"]+)", "([^"]+)"', body.group(1)):
            found.setdefault(written + suffix, spoken)
    for written, spoken in re.findall(r'Entry\(written: "([^"]+)", spoken: "([^"]+)", context: \.anywhere', source):
        found.setdefault(written, spoken)
    return found


def normalize(cli: str, lines: list[str]) -> list[str]:
    out = subprocess.run([cli, "nemo-normalize"], input="\n".join(lines) + "\n",
                         capture_output=True, text=True, check=True).stdout.splitlines()
    if len(out) != len(lines):
        sys.exit(f"nemo-normalize returned {len(out)} lines for {len(lines)}")
    return out


def readings(cli: str, written: list[str]) -> dict[str, dict[str, str | None]]:
    """For each written form, NeMo's reading of it in each frame (None: the frame broke)."""
    frames = list(FRAMES.items())
    lines = [frame.replace("X", w) for w in [NEUTRAL] + written for _, frame in frames]
    out = normalize(cli, lines)
    around = {}
    for (name, _), said in zip(frames, out[: len(frames)]):
        before, _, after = said.partition(NEUTRAL)
        around[name] = (before, after)
    result = {}
    for i, w in enumerate(written):
        row = {}
        for j, (name, _) in enumerate(frames):
            said = out[(i + 1) * len(frames) + j]
            before, after = around[name]
            ok = said.startswith(before) and said.endswith(after) and len(said) >= len(before) + len(after)
            row[name] = said[len(before): len(said) - len(after)] if ok else None
        result[w] = row
    return result


def is_words(reading: str | None, written: str) -> bool:
    """A reading in words: not the written form, not letters or a casing of it (`ADM.`, `PHD`)."""
    if not reading or reading == written:
        return False
    letters = re.sub(r"[^A-Za-z]", "", written).upper()
    return any(c.islower() for c in reading) and re.sub(r"[^A-Za-z]", "", reading).upper() not in (letters, letters + "S")


def classify(written: str, said: dict[str, str | None]) -> list[tuple[str, str]]:
    """NeMo's (context, spoken) pairs for one written form: read the same in every
    frame is `anywhere`; read in an address is `streetSuffix`; a different reading
    before a name is a `title` (`St.` → Saint before a name, Street in an address)."""
    words = {frame: r for frame, r in said.items() if is_words(r, written)}
    if not words:
        return []
    if len(words) == len(FRAMES) and len(set(words.values())) == 1:
        return [("anywhere", words["alone"])]
    found = []
    if "address" in words:
        found.append(("streetSuffix", words["address"]))
    if "beforeName" in words and words["beforeName"] != words.get("address"):
        found.append(("title", words["beforeName"]))
    return found


def swift_entries(rows: list[dict]) -> str:
    lines = []
    for r in rows:
        for context, spoken in r["nemo"]:
            case = {"anywhere": ".anywhere(pattern: nil)", "streetSuffix": ".streetSuffix", "title": ".title"}[context]
            stem = r["written"] if context == "anywhere" else r["written"].rstrip(".")
            lines.append(f'        Entry(written: "{stem}", spoken: "{spoken}", context: {case}),')
    return "\n".join(lines)


GENERATED = '''// Generated by Scripts/verbalization/abbreviation_map.py; do not edit.
// NeMo-text-processing {commit} (en whitelist/tts.tsv, address/address_word.tsv),
// read through the grammars fluidaudiocli links.

extension EnglishAbbreviationTable {

    /// What NeMo says for each abbreviation it reads as words, and where it
    /// says it. Letter readings (`Ph.D.` → `PHD`) and casings (`Adm.` →
    /// `ADM.`) are left out.
    static let nemoEntries: [Entry] = [
{entries}
    ]
}
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cli", default=str(REPO / ".build" / "release" / "fluidaudiocli"))
    parser.add_argument("--json", metavar="PATH", help="write every candidate with its readings")
    parser.add_argument("--write", action="store_true", help="regenerate EnglishAbbreviationTable+NeMo.swift")
    args = parser.parse_args()

    nemo, ours = nemo_candidates(), table_candidates()
    written = sorted(set(nemo) | set(ours), key=str.lower)
    said = readings(args.cli, written)
    rows = [{"written": w, "nemoList": nemo.get(w), "ours": ours.get(w), "readings": said[w],
             "nemo": classify(w, said[w])} for w in written]
    if args.json:
        Path(args.json).write_text(json.dumps(rows, indent=1, ensure_ascii=False), encoding="utf-8")
    if args.write:
        out = TABLE.with_name("EnglishAbbreviationTable+NeMo.swift")
        out.write_text(GENERATED.replace("{commit}", NEMO_COMMIT[:8]).replace("{entries}", swift_entries(rows)), encoding="utf-8")
        print(f"wrote {sum(len(r['nemo']) for r in rows)} entries to {out.relative_to(REPO)}")
    for r in rows:
        mark = "both" if r["ours"] and r["nemo"] else "NeMo" if r["nemo"] else "ours" if r["ours"] else "none"
        print(f"{mark:5} {r['written']:10} ours={r['ours']!s:16} nemo={r['nemo']}")


if __name__ == "__main__":
    main()
