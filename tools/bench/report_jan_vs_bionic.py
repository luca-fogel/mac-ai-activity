"""Render jan_vs_bionic.jsonl as a comparison table.

Deltas are always Jan relative to Bionic, so a positive number means Jan won.
A metric missing on either side prints as a dash rather than as zero — one
engine failing to load a model is a result, not a 0 t/s measurement.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1
                          else os.path.join(HERE, "results/jan_vs_bionic.jsonl"))
ORDER = ["Qwen3.5 9B", "Gemma 4 E4B", "Gemma 4 26B A4B QAT", "Qwen3.8 27B"]

rows = {}
for line in open(PATH):
    line = line.strip()
    if not line:
        continue
    d = json.loads(line)
    rows.setdefault(d.get("model"), {})[d.get("engine")] = d


def get(rec, section, key):
    if not rec or "error" in rec:
        return None
    s = rec.get(section) or {}
    if "error" in s:
        return None
    return s.get(key)


def fmt(v, unit="", nd=1):
    if v is None:
        return "—"
    return f"{v:.{nd}f}{unit}" if isinstance(v, float) else f"{v}{unit}"


def delta(a, b):
    """Jan vs Bionic, as a signed percentage."""
    if a is None or b is None or not b:
        return "—"
    return f"{(a - b) / b * 100:+.1f}%"


def table(title, section, key, unit="", nd=1, higher_is_better=True):
    print(f"\n### {title}\n")
    print("| Model | Jan (MLX-Swift) | Bionic (LM Studio MLX) | Jan vs Bionic |")
    print("|---|---|---|---|")
    for m in ORDER:
        r = rows.get(m, {})
        j, b = get(r.get("jan"), section, key), get(r.get("bionic"), section, key)
        d = delta(j, b) if higher_is_better else delta(b, j)
        print(f"| {m} | {fmt(j, unit, nd)} | {fmt(b, unit, nd)} | {d} |")


print("# Jan's MLX-Swift engine vs Bionic/LM Studio's MLX runtime")
print("\nSame weights (one copy in `~/.lmstudio/models`, which Jan's model.yml")
print("entries point at), same client, same prompts, prompt token counts matched")
print("exactly, greedy decoding, warmup discarded, one model resident at a time.")

# Errors first: a model that would not load is the most important fact there is.
problems = []
for m in ORDER:
    for eng in ("jan", "bionic"):
        rec = rows.get(m, {}).get(eng)
        if rec is None:
            problems.append(f"- **{m}** / {eng}: not run")
        elif "error" in rec:
            problems.append(f"- **{m}** / {eng}: {rec['error']}")
        else:
            for sec in ("short", "long"):
                s = rec.get(sec) or {}
                if "error" in s:
                    problems.append(f"- **{m}** / {eng} / {sec}: {s['error'][:120]}")
if problems:
    print("\n## Did not run\n")
    print("\n".join(problems))

table("Decode, short prompt (tok/s)", "short", "decode_tps", nd=1)
table("Decode, 4k prompt (tok/s)", "long", "decode_tps", nd=1)
table("Prefill, 4k prompt (tok/s)", "long", "prefill_tps", nd=0)
table("TTFT, 4k prompt (s — lower is better)", "long", "ttft_s", "s", nd=2,
      higher_is_better=False)

print("\n### Memory and startup\n")
print("| Model | Jan peak RSS | Bionic peak RSS | Jan load+warmup | Bionic load+warmup |")
print("|---|---|---|---|---|")
for m in ORDER:
    r = rows.get(m, {})
    j, b = r.get("jan") or {}, r.get("bionic") or {}
    def ready(x):
        if not x or "error" in x:
            return "—"
        return f"{x.get('load_s', 0) + x.get('warmup_s', 0):.1f}s"
    def rss(x):
        v = (x or {}).get("peak_rss_gb")
        return f"{v:.2f} GB" if v else "—"
    print(f"| {m} | {rss(j)} | {rss(b)} | {ready(j)} | {ready(b)} |")

# Jan states its own timings; agreement with the client is the harness's own
# sanity check, so it is shown rather than assumed.
print("\n### Harness validation: Jan's self-reported vs client-measured decode\n")
print("| Model | client | engine `timings` | agreement |")
print("|---|---|---|---|")
for m in ORDER:
    r = (rows.get(m, {}) or {}).get("jan")
    c, e = get(r, "short", "decode_tps"), get(r, "short", "engine_decode_tps")
    agree = "—" if c is None or e is None or not e else f"{abs(c - e) / e * 100:.2f}% apart"
    print(f"| {m} | {fmt(c, nd=2)} | {fmt(e, nd=2)} | {agree} |")

print("\n### Prompt length parity\n")
print("The long prompt is built from the model's own tokenizer, so the TEXT is")
print("identical; any remaining difference is each engine's chat template, which")
print("adds a different number of special tokens. What matters is the size of")
print("that difference relative to a 4k prompt, since prefill rate scales with it.\n")
print("| Model | Jan 4k prompt | Bionic 4k prompt | difference |")
print("|---|---|---|---|")
for m in ORDER:
    r = rows.get(m, {})
    jl = get(r.get("jan"), "long", "prompt_tokens")
    bl = get(r.get("bionic"), "long", "prompt_tokens")
    if jl is None or bl is None:
        d = "—"
    elif jl == bl:
        d = "identical"
    else:
        d = f"{abs(jl - bl)} tok ({abs(jl - bl) / bl * 100:.2f}%)"
    print(f"| {m} | {jl} | {bl} | {d} |")


# ---- Repeatability, when a second pass is available -------------------------
#
# Jan's configuration did not change between passes, so comparing Jan to itself
# isolates everything that is NOT the engine: thermal drift, page-cache state,
# whatever else the machine was doing. It is the error bar for every other
# number in this file. Without it, a 5% engine difference and 5% noise are
# indistinguishable.
other = os.path.expanduser(sys.argv[2]) if len(sys.argv) > 2 else None
if other and os.path.exists(other):
    prev = {}
    for line in open(other):
        line = line.strip()
        if line:
            d = json.loads(line)
            prev.setdefault(d.get("model"), {})[d.get("engine")] = d
    print("\n### Repeatability: same engine, same config, two passes\n")
    print("| Model | metric | pass 1 | pass 2 | drift |")
    print("|---|---|---|---|---|")
    for m in ORDER:
        for sec, key, nm in (("short", "decode_tps", "decode short"),
                             ("long", "decode_tps", "decode 4k"),
                             ("long", "prefill_tps", "prefill 4k")):
            a = get((prev.get(m) or {}).get("jan"), sec, key)
            b = get((rows.get(m) or {}).get("jan"), sec, key)
            if a is None or b is None:
                continue
            print(f"| {m} | {nm} | {a} | {b} | {delta(b, a)} |")
