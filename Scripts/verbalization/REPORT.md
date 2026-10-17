# Verbalization report — KokoroAne English frontend

How the frontend reads numbers, symbols and abbreviations, scored by text.
Baseline measured 2026-10-16 at `b6879249` with the lexicon bundled in
ONarrator (`kokoro-coreml-v1/us_lexicon_cache.json`).

## Method

`score.py` phonemizes each item twice with `fluidaudiocli phonemize-parity`
(EnglishTextNormalizer and the phonemizer chain, no Core ML): the written
sentence, and each accepted spoken reading. An item passes when the
phonemes match after stress marks, punctuation and the `ɾ`/`T`/`ʔ` → `t` remap
are removed. Accepted readings are the item's own plus style variants
("five hundred and five", "the fourth of June", "twenty fourteen", "seven
oh four"), so a style difference is not an error. A word the chain cannot
resolve fails the item unless the spoken reading has the same word, so names
stay neutral.

`prose_check.py` guards the other direction: it phonemizes *The Great
Gatsby* and Keynes's *The Economic Consequences of the Peace* (the books in
`Scripts/parity/REPORT.md`), paragraph by paragraph, and diffs two runs.
Two runs of the same build differ by 0 spans in 2,382 paragraphs.

```sh
swift build --product fluidaudiocli
python3 Scripts/verbalization/fetch_corpus.py
K=<dir with us_lexicon_cache.json>; V=<ANE/vocab.json>
python3 Scripts/verbalization/score.py --kokoro-dir "$K" --vocab "$V"
python3 Scripts/verbalization/score.py --kokoro-dir "$K" --vocab "$V" --failures Date
python3 Scripts/verbalization/prose_check.py dump --out base.jsonl --kokoro-dir "$K" --vocab "$V"
python3 Scripts/verbalization/prose_check.py diff base.jsonl change.jsonl
```

A change to the frontend must raise its own types, lower none, and leave
the prose diff empty outside the forms it targets.

## Test sets

- **dograh**: 1,080 sentences, 27 types × 40, from
  [dograh-hq/experiments](https://github.com/dograh-hq/experiments)
  (`benchmarks/tts-verbalization`, CC BY 4.0, credit Dograh). Fetched at
  commit `cd2ed098` and checked by sha256; not committed here. One reading
  per item; some are debatable (it spells "NATO" as letters).
- **papers** (`papers.jsonl`): 22 research-paper sentences written for this
  report: author–year citations, figure and section references, Latin
  abbreviations, page ranges, comparison symbols. Bracketed numeric
  citations ("[12]") are left out: ONarrator skips them before speech.
- Apple's PolyNorm benchmark is not used: it is CC BY-NC-ND 4.0.

## Baseline (`b6879249`)

| Set | Pass |
| --- | --- |
| dograh | **352 of 1,080** (346 matching the listed reading exactly) |
| papers | **2 of 22** |

dograh by type:

| Type | Pass | Type | Pass |
| --- | --- | --- | --- |
| Cardinal | 40 | Unit | 5 |
| Currency | 40 | Version Numbers | 4 |
| Decimal | 40 | Chemical Formula | 2 |
| Ordinal | 40 | Address | 0 |
| Time | 36 | Date | 0 |
| Abbreviation | 35 | Fractions | 0 |
| Initialism or Acronym | 35 | Geographic Coordinates | 0 |
| Stock Ticker | 35 | Hashtag or Mention | 0 |
| Biological Classification | 18 | ISBN | 0 |
| Musical Notation | 16 | License Plate or Serial Numbers | 0 |
| Legal Reference | 6 | Mathematical Expression | 0 |
| | | Phone Number | 0 |
| | | Roman Numeral | 0 |
| | | Sports score | 0 |
| | | URL or Email | 0 |
| | | Vehicle or Product Code | 0 |

papers: the two passes are "i.e."/"e.g." read as letters and a plain
year. Every other item fails on something real: "et al." (`et` is
unresolved and `al` reads as the name Al), "Fig."/"Sec." read as "fig" and
"sec", "Eq.", "Ch.", "cf.", "pp.", "vol." and "hrs" unresolved, "no. 140"
read as "no", ranges without "to", `%`, `<`, `=`, `±`, `×` and `°` silent,
"3.1.2" as three separate digits, "1.3B" as "1 3B".

URL and email items are scored on the frontend alone. In ONarrator the app
rewrites links before speech ("link to granite.dev"), so those 0 of 40 say
little about what a listener hears.
