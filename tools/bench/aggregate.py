"""Combine repeated benchmark passes into means with an explicit noise floor.

The reason this file exists: the first two passes of this benchmark disagreed
with each other by up to 23% on the SAME engine with the SAME configuration.
Most of that was thermal — pass 1 ran without cooldowns and the machine finished
at 79 C — but it establishes the point that a single pass cannot distinguish a
real 5% engine difference from run-to-run scatter.

So every number here is a mean over passes, carrying the half-range across those
passes as its uncertainty, and a Jan-vs-Bionic difference is only called for one
side when it exceeds the combined scatter of both. Anything smaller is reported
as a tie, because that is what the data supports.
"""
import json, os, statistics, sys

ORDER = ["Qwen3.5 9B", "Gemma 4 E4B", "Gemma 4 26B A4B QAT", "Qwen3.8 27B"]
# RSS is summed over a process tree. Jan's is one process; Bionic's includes the
# Electron UI and its helpers, measured idle with no model loaded.
BIONIC_BASELINE_GB = 0.83


def load(paths):
    runs = {}
    for p in paths:
        for line in open(os.path.expanduser(p)):
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            runs.setdefault((d.get("model"), d.get("engine")), []).append(d)
    return runs


def values(recs, section, key):
    out = []
    for r in recs:
        if "error" in r:
            continue
        s = r.get(section) or {}
        if "error" in s or s.get(key) is None:
            continue
        out.append(s[key])
    return out


def stat(vals):
    """Mean and half-range. Half-range, not stdev: with two or three passes a
    sample stdev is barely meaningful, while the observed spread is a fact."""
    if not vals:
        return None, None
    return statistics.fmean(vals), (max(vals) - min(vals)) / 2


def verdict(j, js, b, bs, higher_is_better=True):
    """Who won, or whether the passes cannot tell them apart."""
    if j is None or b is None:
        return "—", "—"
    diff = (j - b) / b * 100
    if not higher_is_better:
        diff = -diff
    # Combined scatter, expressed in the same percentage terms.
    noise = ((js or 0) + (bs or 0)) / b * 100
    pct = f"{diff:+.1f}%"
    if abs(diff) <= max(noise, 1.0):
        return pct, f"tie (scatter ±{noise:.1f}%)"
    return pct, ("Jan" if diff > 0 else "Bionic")


def table(runs, title, section, key, nd=1, unit="", higher_is_better=True):
    print(f"\n### {title}\n")
    print("| Model | Jan (MLX-Swift) | Bionic (LM Studio MLX) | difference | faster |")
    print("|---|---|---|---|---|")
    for m in ORDER:
        jv = values(runs.get((m, "jan"), []), section, key)
        bv = values(runs.get((m, "bionic"), []), section, key)
        j, js = stat(jv)
        b, bs = stat(bv)
        pct, who = verdict(j, js, b, bs, higher_is_better)
        def cell(v, s):
            if v is None:
                return "—"
            return f"{v:.{nd}f}{unit} ±{s:.{nd}f}" if s else f"{v:.{nd}f}{unit}"
        print(f"| {m} | {cell(j, js)} | {cell(b, bs)} | {pct} | {who} |")


if __name__ == "__main__":
    runs = load(sys.argv[1:])
    n = max((len(v) for v in runs.values()), default=0)
    print("# Jan's MLX-Swift engine vs Bionic / LM Studio's MLX runtime")
    print(f"\nM2 Max, 64 GB. {n} controlled passes, mean ± half-range across passes.")
    print("Identical weights (a single copy under `~/.lmstudio/models`, which Jan's")
    print("own model.yml entries point at), identical client and prompts, greedy")
    print("decoding, warmup discarded, one model resident at a time, 60 s cooldown")
    print("before every run, engine order alternated per model.")
    print("\n`tie` means the gap is inside the combined run-to-run scatter, so these")
    print("passes cannot tell the two engines apart on that metric.")

    table(runs, "Decode throughput, short prompt (tok/s)", "short", "decode_tps")
    table(runs, "Decode throughput, 4k prompt (tok/s)", "long", "decode_tps")
    table(runs, "Prefill throughput, 4k prompt (tok/s)", "long", "prefill_tps", nd=0)
    table(runs, "Time to first token, 4k prompt (s)", "long", "ttft_s", nd=2,
          unit="s", higher_is_better=False)

    print("\n### Peak resident memory (GB)\n")
    print("Jan's figure is one process. Bionic's is its whole tree, so the app's")
    print(f"idle baseline ({BIONIC_BASELINE_GB} GB, measured with no model loaded) is")
    print("subtracted to leave a comparable engine-plus-weights figure.\n")
    print("| Model | Jan | Bionic (net of app) | difference |")
    print("|---|---|---|---|")
    for m in ORDER:
        jv = [r["peak_rss_gb"] for r in runs.get((m, "jan"), [])
              if "error" not in r and r.get("peak_rss_gb")]
        bv = [r["peak_rss_gb"] - BIONIC_BASELINE_GB
              for r in runs.get((m, "bionic"), [])
              if "error" not in r and r.get("peak_rss_gb")]
        j, _ = stat(jv)
        b, _ = stat(bv)
        d = f"Jan uses {(b - j) / b * 100:.0f}% less" if j and b and b > j else (
            f"{(j - b) / b * 100:+.0f}%" if j and b else "—")
        print(f"| {m} | {j:.2f} | {b:.2f} | {d} |" if j and b else f"| {m} | — | — | — |")

    print("\n### Time until the model can answer (s)\n")
    print("Server launch or `lms load`, plus the first request. Reported together")
    print("because both engines mmap the weights: load alone returns before the")
    print("pages are faulted in, so it flatters a warm page cache.\n")
    print("| Model | Jan | Bionic |")
    print("|---|---|---|")
    for m in ORDER:
        def ready(eng):
            v = [r.get("load_s", 0) + r.get("warmup_s", 0)
                 for r in runs.get((m, eng), []) if "error" not in r]
            return f"{statistics.fmean(v):.1f}s" if v else "—"
        print(f"| {m} | {ready('jan')} | {ready('bionic')} |")

    print("""
### How to read this, and what it does not say

* **Prefill splits by architecture, not by engine.** Jan wins prefill on both
  Gemma models and loses on both Qwen models, by margins well outside the
  scatter. Whatever is going on is kernel-level and model-shape-specific, so
  "engine X is faster" is not a claim this data supports — pick per model.
* **Decode is close to a wash**, with Bionic marginally ahead where the two can
  be separated at all. Jan's `mlx-server` starts with an MLX buffer cache limit
  of 20 MB (it prints this at launch); an aggressive cache cap is a plausible
  mechanism for both the slightly lower decode and the lower memory, but that is
  a hypothesis, not something measured here.
* **Peak RSS is resident pages, not allocation.** Both engines mmap the
  safetensors, so a model can be serving with fewer pages resident than the file
  is long: Gemma 4 E4B is 6.4 GB on disk and Jan peaked at 5.76 GB. Treat these
  as "what the process was holding", which is the number that competes for RAM,
  not as the model's footprint.
* **Context was NOT matched, and could not be.** LM Studio ignores
  `--context-length` for MLX models (verified: 8192 and 16384 both left it
  reporting 262144). It is immaterial at a 4k working set because neither engine
  preallocates the cache, but it is unmeasured at long context, and the memory
  results in particular could look different at 100k tokens.
* **Two passes is a scatter estimate, not a confidence interval.** Qwen3.5 9B was
  the noisiest model (±7% on short decode); the two large models were repeatable
  to under ±1%. Differences smaller than the quoted scatter are not resolved by
  this data.
* **Not measured:** energy per token, concurrent requests (both were pinned to
  one slot), quality of output, and anything above 4k context.
""")
