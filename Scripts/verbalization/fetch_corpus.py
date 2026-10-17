#!/usr/bin/env python3
"""Fetch the third-party test sets into the verbalization cache.

Dograh's TTS verbalization set (1,080 English sentences, 27 types, 40 each):
https://github.com/dograh-hq/experiments, benchmarks/tts-verbalization,
data and results under CC BY 4.0 (credit: Dograh). It is fetched at a pinned
commit and checked by sha256, never committed here.

Apple's PolyNorm benchmark is not used: it is CC BY-NC-ND 4.0.
"""

import hashlib
import os
import sys
import urllib.request
from pathlib import Path

CACHE = Path(os.environ.get("VERBALIZATION_CACHE", Path.home() / ".cache" / "fluidaudio" / "verbalization"))

SOURCES = {
    "dograh-en-US.jsonl": (
        "https://raw.githubusercontent.com/dograh-hq/experiments/"
        "cd2ed098bfe7f7649101ec7f4b73e093e2781701/benchmarks/tts-verbalization/data/synthetic/en-US.jsonl",
        "c34716bb06625f30062c1fd8abd865ce8c5cee61f625a23a5ee22bdf69f140c8",
    ),
}


def main() -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    for name, (url, sha256) in SOURCES.items():
        path = CACHE / name
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == sha256:
            print(f"{path} is current")
            continue
        data = urllib.request.urlopen(url, timeout=60).read()
        digest = hashlib.sha256(data).hexdigest()
        if digest != sha256:
            sys.exit(f"{name}: sha256 {digest}, expected {sha256}")
        path.write_bytes(data)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
