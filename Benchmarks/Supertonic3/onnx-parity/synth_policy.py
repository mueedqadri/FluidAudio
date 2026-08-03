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

def main(key, policy):
    text = json.load(open("paragraphs.json"))[key]
    chunks = S.chunk(text, CAP, policy)
    gap = np.zeros(int(0.05*SR), dtype=np.float32)
    parts = []
    for i, c in enumerate(chunks):
        out = f"out/_piece{i}.wav"
        subprocess.run([CLI, "tts", c, "--backend", "supertonic3", "--voice", "M1",
                        "--ve-variant", "int8", "-o", out],
                       check=True, capture_output=True)
        if i: parts.append(gap)
        parts.append(read(out))
        print(f"  {i+1}: [{len(c):3}] {c!r}")
    audio = np.concatenate(parts)
    dest = f"out/policy-{key}-{policy}.wav"
    pcm = (np.clip(audio, -1, 1)*32767).astype("<i2")
    with wave.open(dest, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
    print(f"  -> {dest}  {len(audio)/SR:.2f}s")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
