#!/usr/bin/env python3
"""Counterbalanced replication of the regular-vs-entropy pair.

The first attempt was confounded: `regular` ran first on cold GPU buffers and
`entropy` second on warm ones, so ordering alone could have produced the gap.
This alternates conditions, discards a warm-up run, and reports the spread
WITHIN each condition so the between-condition difference can be judged against
the noise rather than asserted.
"""
import json, statistics as st, subprocess, sys, time, urllib.request

REGULAR = ("Output a markdown table with exactly 60 rows and these columns: n, n squared, "
           "n cubed, 2^n, and n! for n = 1 through 60. Use scientific notation above 1e12. "
           "Output only the table, no commentary.")
ENTROPY = ("Write 60 numbered aphorisms about instrumentation and measurement, in the voice "
           "of a working engineer who distrusts dashboards. Each must be one sentence, must "
           "not repeat an image or noun used in any earlier line, and must avoid the words "
           "data, metric, signal, and truth. Output only the numbered list.")

def endpoint():
    out = subprocess.run(["ps","-Ao","args="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "llama-server" in line and "grep" not in line:
            a = line.split()
            return a[a.index("--port")+1], a[a.index("--api-key")+1]
    sys.exit("no llama-server")

PORT, KEY = endpoint()

def run(prompt, max_tokens, temp=0.7):
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/v1/chat/completions",
        data=json.dumps({"messages":[{"role":"user","content":prompt}],
                         "max_tokens":max_tokens,"temperature":temp,"stream":True}).encode(),
        headers={"Content-Type":"application/json","Authorization":f"Bearer {KEY}"})
    t0=time.perf_counter(); ttft=None; n=0
    for raw in urllib.request.urlopen(req, timeout=900):
        if not raw.startswith(b"data: "): continue
        c=raw[6:].strip()
        if c==b"[DONE]": break
        try: d=json.loads(c)
        except Exception: continue
        dl=(d.get("choices") or [{}])[0].get("delta",{})
        if dl.get("content") or dl.get("reasoning_content"):
            now=time.perf_counter()
            if ttft is None: ttft=now-t0
            n+=1
    total=time.perf_counter()-t0
    decode=total-(ttft or 0)
    return {"ttft":ttft,"tokens":n,"rate":n/decode if decode>0 else 0}

MAX=300
TRIALS=3
print(f"warm-up (discarded) ...", flush=True)
run(REGULAR, 60)

order=[]
for i in range(TRIALS):
    order += [("regular",REGULAR),("entropy",ENTROPY)] if i%2==0 else \
             [("entropy",ENTROPY),("regular",REGULAR)]

res={"regular":[],"entropy":[]}
print(f"\n{'#':>2} {'condition':>10} {'TTFT':>7} {'tok':>5} {'tok/s':>7}")
for i,(name,p) in enumerate(order,1):
    r=run(p,MAX)
    res[name].append(r["rate"])
    print(f"{i:2d} {name:>10} {r['ttft']:7.2f} {r['tokens']:5d} {r['rate']:7.2f}", flush=True)

print(f"\n─── replication result ({TRIALS} trials each, alternating order) ───")
for name in ("regular","entropy"):
    v=res[name]
    sd=st.stdev(v) if len(v)>1 else 0
    print(f"  {name:>8}  mean {st.mean(v):6.2f} tok/s   sd {sd:5.2f}   runs {[round(x,2) for x in v]}")
a,b=st.mean(res['regular']),st.mean(res['entropy'])
pooled=max([st.stdev(res[k]) if len(res[k])>1 else 0 for k in res])
diff=a-b
print(f"\n  difference: {diff:+.2f} tok/s ({diff/b*100:+.1f}%)")
print(f"  largest within-condition sd: {pooled:.2f} tok/s")
if abs(diff) > 2*pooled and pooled>0:
    print("  -> difference exceeds 2x the within-condition spread: REPLICATED")
elif pooled==0:
    print("  -> insufficient trials to estimate spread")
else:
    print("  -> difference is WITHIN the noise: NOT replicated")
