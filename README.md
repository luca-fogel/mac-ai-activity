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

## The five traps this was built around

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
