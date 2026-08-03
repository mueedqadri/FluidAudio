"""Locate low-energy gaps in a clip and report their position and length."""
import sys, wave
import numpy as np

def load(p):
    with wave.open(p, "rb") as w:
        sr = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32)/32768
    return x, sr

def gaps(path, thresh_db=-42, min_ms=90):
    x, sr = load(path)
    win = int(0.010*sr)
    n = len(x)//win
    e = np.array([np.sqrt((x[i*win:(i+1)*win]**2).mean()+1e-12) for i in range(n)])
    db = 20*np.log10(e/max(e.max(), 1e-9))
    quiet = db < thresh_db
    out, i = [], 0
    while i < n:
        if quiet[i]:
            j = i
            while j < n and quiet[j]: j += 1
            ms = (j-i)*10
            if ms >= min_ms and i > 0 and j < n:
                out.append((i*10/1000, ms))
            i = j
        else:
            i += 1
    return out, len(x)/sr

for p in sys.argv[1:]:
    g, dur = gaps(p)
    print(f"\n{p}   {dur:.2f}s   {len(g)} gaps >=90ms")
    for t, ms in g:
        print(f"   {t:6.2f}s   {ms:4d} ms")
