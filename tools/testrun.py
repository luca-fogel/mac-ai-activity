#!/usr/bin/env python3
"""Fire a controlled prompt at the live llama-server and report GROUND TRUTH.

AI Activity can only *bound* TTFT, because it is not the client — it sees the
request through 1 Hz polls. This script IS the client, so it knows the real
TTFT and the real token count. Run it, then compare against what the app
displayed: that is how you validate the instrument rather than trusting it.

Endpoint + API key are read from the llama-server process argv, exactly as the
app does, because Bionic regenerates both on every launch.

  ./tools/testrun.py --prompt cold      long novel prompt: prefill spike
  ./tools/testrun.py --prompt regular   low-entropy: speculation should thrive
  ./tools/testrun.py --prompt entropy   high-entropy: speculation should struggle
"""
import argparse, json, re, subprocess, sys, time, urllib.request

def discover():
    out = subprocess.run(["ps", "-Ao", "pid=,args="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "llama-server" not in line or "grep" in line:
            continue
        argv = line.split()
        def flag(name):
            if name in argv:
                i = argv.index(name)
                if i + 1 < len(argv): return argv[i + 1]
            return None
        port, key = flag("--port"), flag("--api-key")
        if port:
            return flag("--host") or "127.0.0.1", int(port), key
    sys.exit("no llama-server found (is Bionic serving a model?)")

# ---- prompts -------------------------------------------------------------
# regular vs entropy are a MATCHED PAIR: same instruction shape, same token
# budget, deliberately different predictability. Speculative decoding accepts
# more drafted tokens on predictable text, so if draft-mtp is doing anything
# the emitted tok/s should differ measurably between them. That difference is
# the only observable signature of speculation available to us — /slots exposes
# no accept/reject counters at all.
PROMPTS = {
"regular": (
 "Output a markdown table with exactly 60 rows and these columns: n, n squared, "
 "n cubed, 2^n, and n! for n = 1 through 60. Use scientific notation above 1e12. "
 "Output only the table, no commentary."),

"entropy": (
 "Write 60 numbered aphorisms about instrumentation and measurement, in the voice "
 "of a working engineer who distrusts dashboards. Each must be one sentence, must "
 "not repeat an image or noun used in any earlier line, and must avoid the words "
 "data, metric, signal, and truth. Output only the numbered list."),

"cold": None,   # built from the user's own files at runtime
}

def cold_prompt():
    docs = []
    for p in ["README.md", "../qwen-control-mac/README.md"]:
        try:
            with open(p) as f: docs.append((p, f.read()))
        except OSError: pass
    if not docs:
        sys.exit("cold prompt needs README.md; run from the ai-activity repo root")
    body = "\n\n".join(f"=== {name} ===\n{text}" for name, text in docs)
    return (body + "\n\n---\n\nYou have read the design notes for two local-AI tools "
            "built on the same Mac. Write a technical comparison covering: what each "
            "measures that the other does not, where their claims about memory "
            "disagree and which is more defensible, and three concrete failure modes "
            "that would make either report a confidently wrong number. Be specific "
            "and cite the mechanisms.")

ap = argparse.ArgumentParser()
ap.add_argument("--prompt", default="cold", choices=list(PROMPTS))
ap.add_argument("--max-tokens", type=int, default=1200)
ap.add_argument("--temp", type=float, default=0.7)
a = ap.parse_args()

text = cold_prompt() if a.prompt == "cold" else PROMPTS[a.prompt]
host, port, key = discover()
print(f"→ {host}:{port}   prompt='{a.prompt}'   ~{len(text)//4} prompt tokens est."
      f"   max_tokens={a.max_tokens}\n", flush=True)

req = urllib.request.Request(
    f"http://{host}:{port}/v1/chat/completions",
    data=json.dumps({
        "messages": [{"role": "user", "content": text}],
        "max_tokens": a.max_tokens, "temperature": a.temp, "stream": True,
    }).encode(),
    headers={"Content-Type": "application/json",
             **({"Authorization": f"Bearer {key}"} if key else {})})

t0 = time.perf_counter()
ttft = None
n = 0
marks = []
with urllib.request.urlopen(req, timeout=900) as r:
    for raw in r:
        if not raw.startswith(b"data: "): continue
        chunk = raw[6:].strip()
        if chunk == b"[DONE]": break
        try: d = json.loads(chunk)
        except Exception: continue
        delta = (d.get("choices") or [{}])[0].get("delta", {})
        piece = delta.get("content") or delta.get("reasoning_content") or ""
        if not piece: continue
        now = time.perf_counter()
        if ttft is None:
            ttft = now - t0
            print(f"  TTFT (ground truth) {ttft:.3f} s", flush=True)
        n += 1
        marks.append(now)
        if n % 100 == 0:
            recent = marks[-50:]
            inst = 49 / (recent[-1] - recent[0]) if len(recent) > 1 else 0
            print(f"  {n:5d} tok   inst {inst:6.2f} tok/s   "
                  f"avg {n/(now-t0-(ttft or 0)):6.2f} tok/s", flush=True)

total = time.perf_counter() - t0
decode = total - (ttft or 0)
print(f"\n─── ground truth ───────────────────────────────")
print(f"  TTFT            {ttft:.3f} s" if ttft else "  no tokens")
print(f"  tokens emitted  {n}")
print(f"  decode wall     {decode:.2f} s")
print(f"  decode rate     {n/decode:.2f} tok/s" if decode > 0 else "")
print(f"  total wall      {total:.2f} s")
print("\nCompare against AI Activity: its TTFT should BRACKET the value above,")
print("and its emitted tok/s should sit slightly BELOW (polling steals decode time).")
