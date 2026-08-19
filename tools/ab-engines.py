#!/usr/bin/env python3
"""Interleaved benchmark: llama.cpp (GGUF) vs mlx-lm (MLX), same prompt.

Interleaved rather than blocked, because a previous benchmark here showed
run-to-run drift of -22% across six consecutive runs -- five times larger than
the effect under test. Alternating conditions is the only way the comparison
survives that.

Measures TTFT and decode rate client-side (ground truth), and integrates
whole-system power over each run so energy per token is comparable across
engines -- which is the metric that actually matters and the one neither
engine reports itself.
"""
import json, re, statistics as st, subprocess, sys, threading, time, urllib.request

PROMPT = ("Explain, in careful technical prose, why measuring the throughput of a "
          "local language model is harder than it looks. Cover at least: cold versus "
          "warm caches, the difference between prefill and decode, why wall-clock "
          "timing can mislead, and what an honest benchmark must report.")
MAX_TOKENS = 220
TRIALS = 3

def discover_gguf():
    out = subprocess.run(["ps", "-Ao", "args="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "llama-server" in line and "grep" not in line:
            a = line.split()
            def f(n):
                return a[a.index(n) + 1] if n in a and a.index(n) + 1 < len(a) else None
            return f("--port"), f("--api-key")
    return None, None

def system_watts():
    """PowerTelemetryData.SystemLoad in mW -- valid on AC and on battery."""
    out = subprocess.run(["ioreg", "-r", "-c", "AppleSmartBattery", "-w0"],
                         capture_output=True, text=True).stdout
    m = re.search(r'"SystemLoad"=(\d+)', out)
    if not m:
        return None
    u = int(m.group(1))
    mw = u - 2**64 if u > 2**63 else u      # published unsigned, actually signed
    # Negative means the battery is charging: that is net flow, not system draw.
    return mw / 1000 if 0 < mw < 200_000 else None

class PowerSampler(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True); self.stop_flag = False; self.samples = []
    def run(self):
        while not self.stop_flag:
            w = system_watts()
            if w: self.samples.append((time.perf_counter(), w))
            time.sleep(1.0)
    def energy(self):
        j = 0.0
        for (t0, w0), (t1, w1) in zip(self.samples, self.samples[1:]):
            j += (w0 + w1) / 2 * (t1 - t0)
        return j if len(self.samples) >= 2 else None
    def mean_watts(self):
        return st.mean(w for _, w in self.samples) if self.samples else None

def run_once(url, key, model=None):
    body = {"messages": [{"role": "user", "content": PROMPT}],
            "max_tokens": MAX_TOKENS, "temperature": 0.7, "stream": True}
    if model: body["model"] = model
    h = {"Content-Type": "application/json"}
    if key: h["Authorization"] = "Bearer " + key
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h)

    p = PowerSampler(); p.start()
    t0 = time.perf_counter(); ttft = None; n = 0
    for raw in urllib.request.urlopen(req, timeout=900):
        if not raw.startswith(b"data: "): continue
        c = raw[6:].strip()
        if c == b"[DONE]": break
        try: d = json.loads(c)
        except Exception: continue
        dl = (d.get("choices") or [{}])[0].get("delta", {})
        # Key differs by engine: llama.cpp emits reasoning_content, mlx-lm
        # emits reasoning. Both also emit content. Count every emitted token.
        if dl.get("content") or dl.get("reasoning_content") or dl.get("reasoning"):
            if ttft is None: ttft = time.perf_counter() - t0
            n += 1
    total = time.perf_counter() - t0
    p.stop_flag = True; p.join(timeout=2)
    decode = total - (ttft or 0)
    return {"ttft": ttft, "tokens": n, "decode": decode,
            "rate": n / decode if decode > 0 else 0,
            "energy": p.energy(), "watts": p.mean_watts(), "total": total}

port, key = discover_gguf()
if not port: sys.exit("no llama-server found")
ENGINES = {
    "GGUF Q5_K_M": (f"http://127.0.0.1:{port}/v1/chat/completions", key, None),
    "MLX 4bit":    ("http://127.0.0.1:8131/v1/chat/completions", None, None),
}

print(f"llama.cpp on :{port}   mlx-lm on :8131   {MAX_TOKENS} tokens x {TRIALS} trials, interleaved\n")
print("warm-up (discarded) ...", flush=True)
for name, (u, k, m) in ENGINES.items():
    try: run_once(u, k, m)
    except Exception as e: sys.exit(f"{name} warm-up failed: {e}")

res = {k: [] for k in ENGINES}
order = []
for i in range(TRIALS):
    names = list(ENGINES) if i % 2 == 0 else list(ENGINES)[::-1]
    order += names

print(f"\n{'#':>2} {'engine':>12} {'TTFT':>7} {'tok':>5} {'tok/s':>7} {'W':>7} {'J':>8} {'J/tok':>7}")
for i, name in enumerate(order, 1):
    u, k, m = ENGINES[name]
    r = run_once(u, k, m)
    res[name].append(r)
    jt = (r["energy"] / r["tokens"]) if (r["energy"] and r["tokens"]) else None
    def fmt(v, w, p=2):
        return ("%*.*f" % (w, p, v)) if v is not None else ("%*s" % (w, "-"))
    print(f"{i:2d} {name:>12} {fmt(r['ttft'],7)} {r['tokens']:5d} {fmt(r['rate'],7)} "
          f"{fmt(r['watts'],7,1)} {fmt(r['energy'],8,0)} {fmt(jt,7)}", flush=True)

print("\n─── result ─────────────────────────────────────────────")
for name in ENGINES:
    rs = [x["rate"] for x in res[name]]
    js = [x["energy"] / x["tokens"] for x in res[name] if x["energy"] and x["tokens"]]
    ts = [x["ttft"] for x in res[name]]
    sd = st.stdev(rs) if len(rs) > 1 else 0
    print(f"  {name:>12}  {st.mean(rs):6.2f} +/- {sd:.2f} tok/s   "
          f"TTFT {st.mean(ts):5.2f}s   "
          f"{(st.mean(js) if js else float('nan')):5.2f} J/tok")
a, b = list(ENGINES)
ra, rb = st.mean([x["rate"] for x in res[a]]), st.mean([x["rate"] for x in res[b]])
print(f"\n  {b} is {rb/ra - 1:+.1%} on throughput vs {a}")
ja = [x["energy"]/x["tokens"] for x in res[a] if x["energy"] and x["tokens"]]
jb = [x["energy"]/x["tokens"] for x in res[b] if x["energy"] and x["tokens"]]
if ja and jb:
    print(f"  {b} is {st.mean(jb)/st.mean(ja) - 1:+.1%} on energy per token vs {a}")
print("\n  CAVEAT: 4-bit vs 5-bit K-quant. MLX has a precision advantage going in;")
print("  this is a comparison of what each stack actually ships, not of the runtimes")
print("  at matched precision.")
