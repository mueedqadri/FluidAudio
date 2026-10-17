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

## After NeMo (MAC-938)

`EnglishTextNormalizer.spokenText` runs NeMo's English grammars
(text-processing-rs v0.3.1) over sentences that contain a digit and keeps
only the rewrites of written words that hold one; a neighbouring word NeMo
rewrites on its own (`Mr.`, `i.e.`) stays as written. Time signatures are
read before NeMo, and the remaining digits go through the old rules. Each
rewrite keeps its written source, and the phonemizer's segments for it are
joined under that source, so word timings name `"1999"` rather than
`"nineteen"`, `"ninety"`, `"nine"`.

| Set | Before | After |
| --- | --- | --- |
| dograh | 352 | **611** (579 exact) |
| papers | 2 | **4** |

By type, before → after: Date 0 → 40, Fractions 0 → 40, Phone Number
0 → 37, Unit 5 → 38, License Plate or Serial Numbers 0 → 35, Mathematical
Expression 0 → 29, Vehicle or Product Code 0 → 21, Legal Reference 6 → 17,
ISBN 0 → 12, Musical Notation 16 → 17. No type went down. Still at 0–4:
Address, Geographic Coordinates, Hashtag or Mention, Roman Numeral, Sports
score, URL or Email, Chemical Formula, Version Numbers.

Prose check against `b6879249`: 480 changed spans in 2,382 paragraphs, all
at numbers (dates, years, money, clock times) or the word right beside one
(a stress change on "in" before a rewritten year). No change in text
without a digit. The dump took ~2 min against ~18 s before: NeMo costs
about 50 ms per paragraph that holds a digit on this Mac.

## Ranges, versions and symbols (MAC-939)

`EnglishTextNormalizer.spellRangesAndSymbols` runs before NeMo, for what
NeMo reads wrongly or not at all: ranges (`7–9`, `pp. 45-67`, `58-7`,
`1914-1918`, `6:15-6:30`), mixed numbers (`8-1/2`), version and section
numbers (`v2.5.0`, `version 4.26`, `3.1.2`), `1.3B`, `5 AM`, and `±`, `×`,
`<`, `>`, `≤`, `≥`, `=` beside a number, plus `B♭`/`F♯`. Arithmetic
(`705 - 30 = 675`) is left to NeMo, which reads it whole; its "equal sign"
after a percent becomes "equals". A hyphen is a range only between short
numbers or two years, so phone numbers, ISO dates and ISBNs keep theirs.

| Set | After MAC-938 | After MAC-939 |
| --- | --- | --- |
| dograh | 611 | **725** (693 exact) |
| papers | 4 | **9** |

By type: Sports score 0 → 40, Version Numbers 4 → 40, Mathematical
Expression 29 → 40, Musical Notation 17 → 40, Time 36 → 40. No type went
down. Prose check against MAC-938: 13 changed spans in 2,382 paragraphs,
all page and date ranges, clock ranges, mixed numbers ("eight and one
half") and one "equals".

## Paper abbreviations (MAC-940)

`EnglishReferenceAbbreviations.spell` runs first in the same pass: before a
number, Fig./Figs., Eq., Sec., Ch., p./pp., vol., no., Ref., Tab., Thm., Ex.
read as their words; anywhere, i.e. → "that is", e.g. → "for example",
cf. → "compare", viz., vs., approx., Proc.; `et al.` drops its period
mid-sentence; (Ed.) → "editor", "2nd ed." → "edition"; hrs, mins, secs after
a number; `2019b` → "twenty nineteen B". `et` and `ibid` get their sounds in
the phonemizer instead of the G2P guess.

The scorer's IPA placeholder held a digit, which the number pass rewrote
from MAC-938 on, so "et al." items failed whatever was read; it is letters
only now, and the MAC-939 papers figure was understated by it.

| Set | After MAC-939 | After MAC-940 |
| --- | --- | --- |
| dograh | 725 | **725** (693 exact) |
| papers | 9 | **22 of 22** |

Prose check against MAC-939: 3 changed spans in 2,382 paragraphs: "No. 249"
→ "number two forty nine", "(i.e. excluding" → "that is excluding", and
Gatsby's dialect "I et like a hog", where "et" (ate) now reads "ɛt" instead
of the G2P guess.
