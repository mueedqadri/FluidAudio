"""Synthesize a paragraph chunk-by-chunk under a chosen split policy.

Each chunk is fed to the CLI on its own and the pieces are joined with the
same 0.05 s seam silence the Swift synthesizer inserts, so the result is what
the app would produce with that policy in the chunker.
"""
import json, subprocess, sys, wave
import numpy as np
import split_policy as S

CLI = "/Users/mueedqadri/Documents/Code/FluidAudio/.build/release/fluidaudiocli"
SR, CAP = 44100, 110

def read(p):
    with wave.open(p, "rb") as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32)/32768

def main(key, policy, mark="", butt=False):
    """mark: what to close a non-terminal chunk with before handing it over.
    Empty keeps production behaviour (preprocess appends a period); "," puts a
    comma there instead, which preprocess then leaves alone."""
    text = json.load(open("paragraphs.json"))[key]
    chunks = S.chunk(text, CAP, policy)
    if mark:
        chunks = [c if c.rstrip()[-1] in ".!?" else c.rstrip() + mark for c in chunks]
    gap = np.zeros(int(0.05*SR), dtype=np.float32)
    parts = []
    for i, c in enumerate(chunks):
        out = f"out/_piece{i}.wav"
        subprocess.run([CLI, "tts", c, "--backend", "supertonic3", "--voice", "M1",
                        "--ve-variant", "int8", "-o", out],
                       check=True, capture_output=True)
        # butt-join non-terminal seams: silence is its own boundary cue, and it
        # stacks with the fabricated punctuation rather than replacing it.
        if i:
            prev_terminal = chunks[i - 1].rstrip()[-1] in ".!?"
            if prev_terminal or not butt:
                parts.append(gap)
        parts.append(read(out))
        print(f"  {i+1}: [{len(c):3}] {c!r}")
    audio = np.concatenate(parts)
    dest = f"out/policy-{key}-{policy}{'-comma' if mark else ''}{'-butt' if butt else ''}.wav"
    pcm = (np.clip(audio, -1, 1)*32767).astype("<i2")
    with wave.open(dest, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
    print(f"  -> {dest}  {len(audio)/SR:.2f}s")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2],
         sys.argv[3] if len(sys.argv) > 3 else "",
         "butt" in sys.argv[4:])
