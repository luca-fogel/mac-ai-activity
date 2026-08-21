"""One benchmark client, pointed at either engine's OpenAI-compatible endpoint.

The whole point is that this file does not know which engine it is talking to.
Jan's `mlx-server` (MLX-Swift) and Bionic/LM Studio's bundled MLX runtime are
measured by the same code, over the same protocol, on the same weights — the
models in ~/.lmstudio/models are shared, and Jan's own model.yml entries point
straight at them, so there is one copy on disk and no chance of comparing
different quantizations by accident.

What is measured, and why it is measured this way:

* **Prompt tokens are matched EXACTLY**, by building the long prompt with the
  model's own tokenizer and truncating to a token count rather than a character
  count. Prefill rate is tokens/second, so a prompt that differs by 5% between
  engines moves the number by 5% for no reason.
* **TTFT is client-side**, because that is the only definition a caller can act
  on. Engine-reported timings are collected too, when the engine offers them,
  and reported alongside rather than mixed in — Jan's mlx-server returns a
  `timings` object, LM Studio does not.
* **Decode rate excludes the first token.** The first delta arrives at the end
  of prefill, so counting it in the decode window charges prefill time to
  decode.
* **Reasoning tokens count.** Both engines stream them in `reasoning_content`
  rather than `content` for these models, and a client waiting for the answer
  waits through them. Dropping them would understate output by most of it.
* **A warmup run is discarded**, and greedy decoding (temperature 0) is used so
  the output length is not itself a random variable.
"""
import json, os, subprocess, sys, time, urllib.request

SHORT = "Explain in detail how a hash table handles collisions."
FILLER = ("The quick brown fox jumps over the lazy dog near the riverbank while "
          "seventeen migrating herons circle above the old stone bridge. ")


def post_stream(url, model, prompt, max_tokens, timeout=900):
    """One request. Returns client-side timings plus whatever the engine states."""
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens, "temperature": 0, "stream": True,
        "stream_options": {"include_usage": True},
    }).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json"})

    t0 = time.perf_counter()
    ttft = None
    n = 0
    usage = None
    timings = None
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: "):
                continue
            data = line[6:]
            if data == "[DONE]":
                break
            try:
                ch = json.loads(data)
            except json.JSONDecodeError:
                continue
            if ch.get("usage"):
                usage = ch["usage"]
            if ch.get("timings"):
                timings = ch["timings"]
            for c in ch.get("choices", []):
                d = c.get("delta") or {}
                # Reasoning models put the bulk of the output here.
                if d.get("content") or d.get("reasoning_content") or d.get("reasoning"):
                    if ttft is None:
                        ttft = time.perf_counter() - t0
                    n += 1
    wall = time.perf_counter() - t0

    ptoks = (usage or {}).get("prompt_tokens")
    gen = (usage or {}).get("completion_tokens", n)
    out = {
        "prompt_tokens": ptoks,
        "gen_tokens": gen,
        "ttft_s": round(ttft, 3) if ttft else None,
        "wall_s": round(wall, 2),
        # Prefill rate: prompt tokens divided by the time to the first token.
        "prefill_tps": round(ptoks / ttft, 1) if ptoks and ttft else None,
        # Decode rate: everything after the first token, over the time after it.
        "decode_tps": round((n - 1) / (wall - ttft), 2)
        if ttft and wall > ttft and n > 1 else None,
        "stream_deltas": n,
    }
    if timings:
        out["engine_prefill_tps"] = round(timings.get("prompt_per_second", 0), 1) or None
        out["engine_decode_tps"] = round(timings.get("predicted_per_second", 0), 2) or None
    return out


def long_prompt(model_dir, target_tokens):
    """A prompt of EXACTLY `target_tokens` tokens, per this model's tokenizer.

    Character-based filler would give each model a different prompt length and
    silently make the prefill numbers incomparable across models.
    """
    from transformers import AutoTokenizer
    tok = AutoTokenizer.from_pretrained(model_dir)
    ids = tok.encode(FILLER * 240)[:target_tokens]
    return tok.decode(ids), len(ids)


def peak_rss_gb(pids):
    """Summed RSS across a process tree, in GiB. 0 when nothing matched."""
    total = 0
    for pid in pids:
        try:
            out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=5).stdout.strip()
            if out:
                total += int(out.split()[0])
        except Exception:
            pass
    return round(total / 1048576, 2)


def bench(url, model_id, model_dir, pids=(), ctx_tokens=4000,
          short_max=256, long_max=128, label=""):
    """Warmup, then a short-prompt run and a long-prompt run."""
    result = {"label": label, "model_id": model_id}

    # Discarded as a throughput measurement, but TIMED, because for an mmap'd
    # MLX model this is where the weights actually arrive.
    #
    # "Load time" is not trustworthy on its own here: both engines mmap the
    # safetensors, so a model whose file is already in the page cache reports a
    # ~1 s load and then faults the pages in during the first real request.
    # MEASURED: mlx-server served /v1/models 1.05 s after launch for a 5.6 GB
    # model it had opened minutes earlier. Load plus warmup is the honest
    # "time until this thing is useful"; load alone flatters a warm cache.
    try:
        w0 = time.perf_counter()
        post_stream(url, model_id, "Say hi.", 16, timeout=600)
        result["warmup_s"] = round(time.perf_counter() - w0, 2)
    except Exception as e:
        result["error"] = f"warmup failed: {e}"
        return result

    peak = peak_rss_gb(pids)
    try:
        result["short"] = post_stream(url, model_id, SHORT, short_max)
        peak = max(peak, peak_rss_gb(pids))
    except Exception as e:
        result["short"] = {"error": str(e)}

    try:
        prompt, n = long_prompt(model_dir, ctx_tokens)
        result["long_prompt_tokens_requested"] = n
        result["long"] = post_stream(url, model_id, prompt, long_max)
        peak = max(peak, peak_rss_gb(pids))
    except Exception as e:
        result["long"] = {"error": str(e)}

    result["peak_rss_gb"] = peak
    return result


if __name__ == "__main__":
    # bench_engine.py <url> <model_id> <model_dir> <label> [pid ...]
    url, model_id, model_dir, label = sys.argv[1:5]
    pids = [int(p) for p in sys.argv[5:]]
    print(json.dumps(bench(url, model_id, model_dir, pids, label=label), indent=2))
