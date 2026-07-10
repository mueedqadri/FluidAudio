# Misaki parity report — KokoroAne English frontend

Date: 2026-07-09. Reference: canonical Python Misaki (`hexgrad/misaki` main,
pip `misaki[en]` with spaCy `en_core_web_sm`, `fallback=None`).

## Method

Per-word phoneme diff over two Project Gutenberg corpora:

- *The Great Gatsby* (fiction, ~48k words)
- Keynes, *The Economic Consequences of the Peace* (nonfiction, ~70k words,
  dense with years/currency/numbers)

Pipeline (all in `scripts/parity/` + the `phonemize-parity` CLI subcommand):

```sh
swift run fluidaudiocli phonemize-parity --input corpus.txt --output swift.jsonl
~/misaki-parity/bin/python scripts/parity/misaki_dump.py --input corpus.txt --output misaki.jsonl
python3 scripts/parity/diff_report.py --swift swift.jsonl --misaki misaki.jsonl
```

The frontend reads its lexicon from the installed cache, so regenerate that
first when the pinned misaki version moves:

```sh
~/misaki-parity/bin/python scripts/generate_us_lexicon_cache.py \
    ~/.cache/fluidaudio/Models/kokoro/us_lexicon_cache.json
```

Both sides emit `{"i", "text", "words": [{word, phonemes}]}` JSONL; the differ
aligns word streams per line (`SequenceMatcher`), compares mismatched regions
jointly (so `1999` vs `one thousand …` tokenization differences compare
fairly), and clusters mismatches into heuristic classes. OOV words return
`<OOV:word>` markers instead of running BART, so fallback-bound words are
visible.

## Result

| Corpus | Baseline mismatch | After port | After lexicon regen |
| --- | --- | --- | --- |
| Gatsby | 19.04% | 0.65% | **0.61%** |
| Keynes | 19.78% | 1.54% | **1.37%** |

The last column regenerates `us_lexicon_cache.json` from misaki 0.9.4 via
`Scripts/generate_us_lexicon_cache.py` (see below). Word-for-word against the
previous run: 121 words improved, **0 regressed**.

## What was ported (in impact order)

1. **Final symbol remap `ɾ→T`, `ʔ→t`** (misaki/en.py `__call__` tail) —
   Kokoro v1.0 was trained on that alphabet; every flapped-t word (`little`,
   `water`, `waited`, `sitting`, …) differed before this.
2. **Context-sensitive function words** (`get_special_case`): `the`→`ði/ðə`
   and `to`→`tu/tə/tʊ` by the following sound, `a`→`ɐ`, `an`→`ɐn`, `I`→`ˌI`,
   `in` stress, `by` ADV, `vs`, `used` past vs "used to", `that` DT,
   `that's`. Resolution now runs right-to-left threading Misaki's
   `TokenContext` (`future_vowel`, `future_to`). ~13% of all corpus words.
3. **Capitalization stress** (`cap_stresses` + full `apply_stress` port in
   `MisakiStress.swift`): capitalized words gain a secondary stress when
   unstressed (`He`→`hˌi`), ALL-CAPS gain a primary.
4. **Phrase-final strong forms**: the 32 `None`-keyed gold entries
   (`this.`→`ðˈɪs`) hardcoded, selected when `futureVowel == nil`.
5. **Number verbalization** (`EnglishTextNormalizer`): years
   (`1999`→`nineteen ninety nine`), currency (`$1.50`→`one dollar and fifty
   cents`, `£500,000,000`→`five hundred million pounds`), comma-grouped
   numbers.
6. **Tight compounds** (`resolve_tokens` port): all-letter compounds
   (`living-room`, `MacReader`) join without spaces and demote surplus
   primary stresses; letter-spelled initialisms take Misaki's `get_NNP`
   shape (`FBI`→`ˌɛfbˌiˈI`, Roman numerals `II`→`ˌIˈI`).
7. **Contractions** the lexicon lacks whole: `'d`/`'ll`/`'m` suffix stripping
   (`Where'd`→`wˌɛɹd`, `that'll`→`ðætəl`).
8. **Residual digit runs** read as numbers instead of reaching BART; OOV
   fallback receives the original-cased spelling (the BART grapheme vocab is
   case-sensitive).
9. **Lexicon regeneration** (`Scripts/generate_us_lexicon_cache.py`): the
   HF-hosted `us_lexicon_cache.json` snapshot predated 236 gold corrections
   (`mention`/`essential`/`substantial` ʃ→ʧ, `status` æ→A). The script rebuilds
   the flattened `{lower, caseSensitive}` cache from the installed misaki's
   `us_gold.json` + `us_silver.json`, so the snapshot tracks whatever version
   the parity venv pins.

## Accepted residual divergences

- **NLTagger vs spaCy POS disagreement** (~0.2%): `that` DT/IN, `in`,
  capitalized sentence-initial words. Symmetric noise, not fixable without
  swapping taggers.
- **Tense heteronyms**: `read`/`reread`/`wound` past tense stay DEFAULT
  (NLTagger has no tense).
- **OOV names**: both sides guess (`<OOV:…>` here, `❓`/BART there) — not a
  porting gap. `oov-misaki-only` rows are words *this* frontend resolves and
  the reference cannot (footnote digits, accented spellings).
- **Times**: `6:00 a.m.` is deliberately normalized here (`six o'clock a m`);
  canonical Misaki has no time handling and reads raw digits. Ours is kept.
- **Rare title abbreviations**: `Sen.`/`Gen.`/`Rep.`/`Adm.`/… deliberately
  expand to their spoken word (`senator`); canonical Misaki reads the stem
  through the lexicon (`sˈɛn`, and `Adm.` comes out as "Adam"). `Mr.`/`Mrs.`/
  `Ms.`/`Dr.` match canonical exactly (`EnglishTitleAbbreviations`).

## Known defect: hyphens adjoining digits

`EnglishTextNormalizer` verbalizes numbers before tokenization and leaves the
hyphen behind, so digit-adjacent hyphens glue normalized words together and a
leading minus is dropped outright:

| Input | This frontend | Canonical Misaki |
| --- | --- | --- |
| `-5` | `fˈIv` ("five") | `mˈInəs fˈIv` ("minus five") |
| `1-2` | `wˌʌntˈu` | `wˈʌntˌu` (stress differs) |
| `COVID-19` | `kˌOvɪdnˌIntˈin` | `kˈOvˌɪd nˌIntˈin` (prespace) |
| `2022-04-15` | "two thousand twenty two-zero four-fifteen" | "twenty twenty two zero four fifteen" |

`-5` losing its sign is the one that changes meaning. All-letter compounds
(`well-defined`, `state-of-the-art`, `T-shirt`, `mother-in-law`) are exact.

Rerun the loop after any frontend change; the diff should only shrink.
