#!/usr/bin/env python3
"""Dump canonical Misaki per-token phonemes for a corpus as JSONL.

Same shape as `fluidaudiocli phonemize-parity`:
  {"i": n, "text": line, "words": [{"word": ..., "phonemes": ...}]}

Setup:
  uv venv --python 3.12 ~/misaki-parity
  VIRTUAL_ENV=~/misaki-parity uv pip install "misaki[en]" spacy num2words click \
    en_core_web_sm@https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl
  ~/misaki-parity/bin/python misaki_dump.py --input corpus.txt --output misaki.jsonl
"""

import argparse
import json


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    from misaki import en

    g2p = en.G2P(trf=False, british=False, fallback=None)

    with open(args.input, encoding="utf-8") as f:
        lines = f.read().splitlines()

    total = 0
    with open(args.output, "w", encoding="utf-8") as out:
        for i, raw in enumerate(lines, start=1):
            line = raw.strip()
            if not line:
                continue
            _, tokens = g2p(line)
            words = []
            for t in tokens:
                phonemes = t.phonemes
                if phonemes is None:
                    phonemes = f"<OOV:{t.text}>"
                words.append({"word": t.text, "phonemes": phonemes})
            total += len(words)
            out.write(json.dumps({"i": i, "text": line, "words": words}, ensure_ascii=False) + "\n")

    print(f"misaki_dump: wrote {total} tokens to {args.output}")


if __name__ == "__main__":
    main()
