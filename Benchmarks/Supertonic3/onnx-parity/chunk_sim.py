import re
ABBR=["Dr.","Mr.","Mrs.","Ms.","Prof.","Sr.","Jr.","St.","Ave.","Rd.","Blvd.","Dept.","Inc.","Ltd.","Co.","Corp.","etc.","vs.","i.e.","e.g.","Ph.D."]
def split_sentences(t):
    out=[];last=0
    for m in re.finditer(r"([.!?])\s+",t):
        before=t[last:m.start()];punc=m.group(1)
        if not any((before.strip()+punc).endswith(a) for a in ABBR):
            out.append(t[last:m.end()]);last=m.end()
    if last<len(t):out.append(t[last:])
    return out or [t]
def pack_words(p,mx,ch):
    cur=""
    for w in p.split():
        if len(cur)+len(w)+1>mx and cur: ch.append(cur);cur=""
        cur = w if not cur else cur+" "+w
    if cur.strip():ch.append(cur.strip())
def pack_commas(s,mx,ch):
    cur=""
    for raw in s.split(","):
        part=raw.strip()
        if not part:continue
        if len(part)>mx:
            if cur.strip():ch.append(cur.strip())
            cur=""
            pack_words(part,mx,ch);continue
        if len(cur)+len(part)+2>mx and cur: ch.append(cur);cur=""
        cur = part if not cur else cur+", "+part
    if cur.strip():ch.append(cur.strip())
def chunk(text,mx=70):
    ch=[];cur=""
    for s in split_sentences(text.strip()):
        s=s.strip()
        if not s:continue
        if len(s)>mx:
            if cur.strip():ch.append(cur.strip())
            cur=""
            pack_commas(s,mx,ch);continue
        if len(cur)+len(s)+1>mx and cur: ch.append(cur);cur=""
        cur = s if not cur else cur+" "+s
    if cur.strip():ch.append(cur.strip())
    return ch

if __name__ == "__main__":
    para=("The Neural Engine is a specialized coprocessor, and it handles the matrix "
    "multiplications that dominate transformer inference. Because it runs at low power, "
    "Apple pushes as much of the model onto it as possible. In practice, however, the "
    "scheduler falls back to the CPU whenever an operator is unsupported, which makes "
    "latency hard to predict across device generations.")
    print("block len:",len(para))
    for i,c in enumerate(chunk(para)):
        ends = c[-1] if c else ''
        print(f"{i}: [{len(c):3}] {c!r}  -> appended-period: {ends not in '.!?;:,\'\"'}")
