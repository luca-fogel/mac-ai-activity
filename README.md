# AI Activity

A live instrument panel for everything local-AI on this Mac. Observe-only,
no persistence, native SwiftUI.

```sh
./build.sh              # build + ad-hoc sign + install to ~/Applications
open -a "AI Activity"   # or Cmd-Space "AI Activity"
```

## What it shows

| View | Answers |
|---|---|
| **Timeline** | What did that generation cost, and what happened when — token output, GPU, memory and power on one shared time axis |
| **Slots** | What is each of llama-server's 4 slots doing, and with which sampler settings |
| **Engines** | Which runtime is actually burning resources (hue is earned by residency) |
| **Sources** (⌘I) | Per-source health, measured rates, observer cost, and what is *not* measurable |

Headline metric: **joules per token** = system watts ÷ emitted tok/s, with the
idle floor subtracted so you can see the marginal cost of inference.

## The six traps this was built around

Each of these silently produces a plausible, wrong number. All are covered by
tests in `Tests/TelemetryTests`.

1. **Context fill has no honest single denominator.** `/slots` and `/props`
   both report `n_ctx` = the *model maximum* (262144). `--fit-ctx` (16384) is a
   fit *target*, not a ceiling — a live slot was observed holding 17,460 tokens,
   i.e. 106% of it. The allocated per-slot window is not exposed anywhere, so
   `ContextFill` publishes the absolute count, both ratios named, and marks the
   real window `.unavailable`.
2. **Idle slots serve frozen counters.** A never-used slot exposes only
   `[id, is_processing, n_ctx, speculative]`; a previously-used idle slot
   exposes stale values from its last request. Rates are computed only across
   two consecutive `.processing` observations with the same `id_task`.
3. **`n_prompt_tokens` grows during decode** (it is total context). Using it as
   the cache-rate denominator makes the hit rate decay toward zero over a long
   generation. Use `cache / (cache + processed)` — both freeze after prefill.
4. **Backend CPU reads ~0.2% during generation.** llama.cpp blocks on a Metal
   command-buffer wait, so the CPU thread sleeps. Any activity predicate keyed
   on CPU reports idle through every inference. The Engines view explains this
   rather than hiding it.
5. **`/slots` emits raw control bytes inside JSON strings**, hard-failing
   `JSONDecoder`. `LenientJSON` repairs them and counts the repairs.
6. **`n_decoded` is not reset at request start.** Through the whole of prefill
   it holds the *previous* request's final count. Measured: it read `400` — the
   exact token count of the preceding run — for 14 s while
   `n_prompt_tokens_processed` climbed 1106 → 1618 and the client had received
   nothing, then reset to `11` the moment decode began. Deriving a rate from
   that window produced a confident, entirely fictional "12.4 tok/s". Slots are
   therefore classified `.prefilling` until the counter is proven trustworthy,
   and `nDecoded` is published as `nil` until then.

## Design rules

- **`Optional` means absent.** A measurement is a number; the absence of one is
  `—`. They are never confusable, in the types or on screen.
- **Domains are never fused.** System samples at ~10 Hz, `/slots` at ~1 Hz,
  power at ~0.25 Hz. Each carries its own timestamps; the UI aligns them on a
  shared axis and never interpolates the slow ones onto the fast grid.
- **Every derived number is an `Estimate`** carrying value, uncertainty, sample
  count and confidence. TTFT is published as a bounded interval, never a point.
- **Confidence maps to ink and decoration, never to hue.** Hue is spent on
  engine identity (chrome only) and phase/status (plot areas only).
- **The observer effect is first-class.** Polling `/slots` occupies the decode
  loop, so the app measures and displays its own cost, and offers a
  minimum-perturbation cadence.

## Measured cost

| | |
|---|---|
| `GPUAccelerator.sample()` | **26.9 µs** (vs 3.3 ms for the whole IORegistry dict, 22 ms shelling `ioreg`) |
| `MachMemory.sample()` | **3.7 µs** |
| Combined collector tick | **30.6 µs → 0.03% of one core at 10 Hz** |
| App, window visible | ~8% of one core |
| App, window occluded | ~3.4% of one core |

## Validating the app against ground truth

`tools/testrun.py` fires a controlled prompt and reports the **real** TTFT and
token count, because it *is* the client — something the app can never be. Use it
to check the app rather than trusting it.

```sh
./tools/testrun.py --prompt cold      # long novel prompt: big prefill
./tools/testrun.py --prompt regular   # low-entropy, speculation should thrive
./tools/testrun.py --prompt entropy   # high-entropy, speculation should struggle
```

`regular` and `entropy` are a matched pair: same shape, same token budget,
deliberately different predictability. Since `/slots` exposes no accept/reject
counters, the tok/s difference between them is the only observable signature of
speculative decoding available.

Measured 2026-08-18 on Qwen3.8-27B-Q5_K_M (M2 Max, on AC):

| run | TTFT | decode |
|---|---|---|
| regular (predictable table) | 13.56 s (cold buffers) | **8.72 tok/s** |
| entropy (novel prose) | 1.42 s | **7.90 tok/s** |
| cold (4.5k-token prompt, cache miss) | **55.4 s** | 4.62 tok/s |
| cold (same prompt, cache hit) | **1.19 s** | 10.28 tok/s |

The last two rows are the same prompt: prompt-cache reuse turned a 55 s wait into
1.2 s, a **47x** difference. That is what the cache-reuse bar in the Slots view is
measuring.

### Replication of the regular-vs-entropy pair

`tools/abtest.py` runs the pair counterbalanced and repeated, because the first
attempt was confounded — `regular` ran first on cold GPU buffers.

Two blocks of 6 alternating trials (12 runs, 300 tokens each), block 2 starting
with the opposite condition:

| | regular | entropy | raw difference | verdict |
|---|---|---|---|---|
| block 1 | 7.87 ± 0.70 | 7.32 ± 0.79 | +7.6% | within noise |
| block 2 | 7.63 ± 0.39 | 7.42 ± 0.27 | +2.8% | within noise |
| pooled, detrended | +0.152 | −0.152 | **+4.0%** | p = 0.024 (exact permutation, n=6 each) |

**Neither block replicates on its own.** Run-to-run drift is the dominant term:
block 1 fell **−0.37 tok/s per run (−22% over six runs)** while block 2 was flat
(+0.09), so the drift is a settling artifact of the preceding cold runs rather
than a general law. It is 5x larger than the effect being measured, which is
why the original uncounterbalanced pair was almost certainly measuring drift.

Pooling both blocks with within-block detrending, `regular` is 4.0% faster and
an exact permutation test gives p = 0.024. Three caveats keep this modest:
the detrending was chosen *after* seeing the drift; a single prompt pair
confounds predictability with format (a numeric table vs prose, which differ in
tokenization as well as entropy); and 4% is small next to the 22% drift. Treat
it as a directional result that survived one replication attempt, not a
measurement of draft acceptance.

`swift run -c release telemetry-probe --cost` asserts the collector budget and
fails on regression. `--live`, `--discover` and `--power` run the collectors
headless.

## Why not reuse llmctl / qwen-control

`llmctl status --json` and `qwen-control`'s `/state` were evaluated and
rejected as *runtime* dependencies: both shell out (175 ms for `/state`), and
every field they provide is now collected natively in microseconds. `llmctl`'s
`sysmem()` **formula** is preserved exactly in `MachMemory` — excluding
file-backed page cache from "used" is hard-won and non-obvious, because a
20–46 GB mmap'd GGUF in the cache would otherwise read as memory pressure.

## Not measurable here

- GPU/ANE wattage — needs root (`powermetrics`). Whole-system watts via
  `AppleSmartBattery` is root-free and is what the app uses.
- Speculative accept rate — `/slots` exposes the configuration only, and
  `/metrics` returns 501 because Bionic does not pass `--metrics`.
- Power on AC — battery amperage reflects charging current, not load.
