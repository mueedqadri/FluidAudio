#!/usr/bin/env python3
"""Generate us_lexicon_cache.json from Misaki's us_gold.json / us_silver.json.

The runtime lexicon (`LexiconAssetCache`) is a *flattened* view of Misaki's two
dictionaries: one pronunciation per word, phonemes exploded to a character
list. POS-keyed gold entries collapse to their `DEFAULT` reading; the
phonemizer restores the other readings from `EnglishHeteronyms.swift`, and the
context-sensitive function words come from `get_special_case`.

Schema (matches the file FluidInference hosts on the kokoro HF repo):

    {"lower": {word: [phoneme, ...]}, "caseSensitive": {Word: [phoneme, ...]}}

`lower` is keyed by the lower-cased spelling of every gold and silver entry
(gold wins on collision); `caseSensitive` holds only the entries whose spelling
is not already lower-case (`Polish`, `FBI`, `A-list`), which is what lets the
phonemizer prefer an exact-spelling hit before folding case.

Regenerate whenever the pinned misaki version changes — upstream corrects gold
pronunciations (e.g. `mention` ʃ→ʧ) and the shipped snapshot goes stale.

Usage:
  generate_us_lexicon_cache.py <output.json> [--gold PATH] [--silver PATH]

With no explicit paths the dictionaries are read from the installed `misaki`
package, so the output tracks whatever version is on the current interpreter.
"""

import argparse
import importlib.resources
import json
import sys


def load_packaged(name: str) -> dict:
    from misaki import data

    with importlib.resources.open_text(data, name) as r:
        return json.load(r)


def flatten(entry) -> str:
    """One pronunciation per word: gold dicts collapse to DEFAULT."""
    return entry if isinstance(entry, str) else entry["DEFAULT"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--gold", help="path to us_gold.json (default: packaged)")
    parser.add_argument("--silver", help="path to us_silver.json (default: packaged)")
    args = parser.parse_args()

    gold = json.load(open(args.gold, encoding="utf-8")) if args.gold else load_packaged("us_gold.json")
    silver = json.load(open(args.silver, encoding="utf-8")) if args.silver else load_packaged("us_silver.json")

    lower: dict[str, list[str]] = {}
    case_sensitive: dict[str, list[str]] = {}

    # Silver first so gold overwrites it on collision, mirroring
    # `Lexicon.lookup`, which probes golds before silvers.
    for source in (silver, gold):
        for word, entry in source.items():
            phonemes = list(flatten(entry))
            lower[word.lower()] = phonemes
            if word != word.lower():
                case_sensitive[word] = phonemes

    payload = {"lower": lower, "caseSensitive": case_sensitive}
    with open(args.output, "w", encoding="utf-8") as out:
        json.dump(payload, out, ensure_ascii=False, separators=(",", ":"))

    print(
        f"wrote {args.output}: {len(lower)} lower, {len(case_sensitive)} case-sensitive",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
