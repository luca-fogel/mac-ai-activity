# Jan's MLX-Swift engine vs Bionic / LM Studio's MLX runtime

M2 Max, 64 GB. 2 controlled passes, mean ± half-range across passes.
Identical weights (a single copy under `~/.lmstudio/models`, which Jan's
own model.yml entries point at), identical client and prompts, greedy
decoding, warmup discarded, one model resident at a time, 60 s cooldown
before every run, engine order alternated per model.

`tie` means the gap is inside the combined run-to-run scatter, so these
passes cannot tell the two engines apart on that metric.

### Decode throughput, short prompt (tok/s)

| Model | Jan (MLX-Swift) | Bionic (LM Studio MLX) | difference | faster |
|---|---|---|---|---|
| Qwen3.5 9B | 55.2 ±3.8 | 62.0 ±2.2 | -10.9% | Bionic |
| Gemma 4 E4B | 58.7 ±1.5 | 60.5 ±1.8 | -3.0% | tie (scatter ±5.5%) |
| Gemma 4 26B A4B QAT | 75.0 ±0.1 | 75.9 ±0.1 | -1.2% | Bionic |
| Qwen3.8 27B | 14.6 ±0.2 | 14.7 ±0.0 | -0.9% | tie (scatter ±1.7%) |

### Decode throughput, 4k prompt (tok/s)

| Model | Jan (MLX-Swift) | Bionic (LM Studio MLX) | difference | faster |
|---|---|---|---|---|
| Qwen3.5 9B | 44.6 ±2.7 | 45.9 ±1.8 | -2.7% | tie (scatter ±10.0%) |
| Gemma 4 E4B | 45.1 ±2.7 | 49.0 ±4.5 | -7.8% | tie (scatter ±14.7%) |
| Gemma 4 26B A4B QAT | 58.2 ±0.8 | 60.7 ±0.5 | -4.0% | Bionic |
| Qwen3.8 27B | 13.2 ±0.3 | 12.8 ±0.0 | +3.3% | Jan |

### Prefill throughput, 4k prompt (tok/s)

| Model | Jan (MLX-Swift) | Bionic (LM Studio MLX) | difference | faster |
|---|---|---|---|---|
| Qwen3.5 9B | 292 ±8 | 337 ±7 | -13.4% | Bionic |
| Gemma 4 E4B | 895 ±49 | 645 ±52 | +38.6% | Jan |
| Gemma 4 26B A4B QAT | 534 ±3 | 509 ±1 | +4.9% | Jan |
| Qwen3.8 27B | 85 ±1 | 92 ±0 | -7.9% | Bionic |

### Time to first token, 4k prompt (s)

| Model | Jan (MLX-Swift) | Bionic (LM Studio MLX) | difference | faster |
|---|---|---|---|---|
| Qwen3.5 9B | 13.75s ±0.36 | 11.90s ±0.25 | -15.6% | Bionic |
| Gemma 4 E4B | 4.50s ±0.25 | 6.26s ±0.50 | +28.2% | Jan |
| Gemma 4 26B A4B QAT | 7.51s ±0.05 | 7.88s ±0.02 | +4.7% | Jan |
| Qwen3.8 27B | 47.67s ±0.61 | 43.90s ±0.07 | -8.6% | Bionic |

### Peak resident memory (GB)

Jan's figure is one process. Bionic's is its whole tree, so the app's
idle baseline (0.83 GB, measured with no model loaded) is
subtracted to leave a comparable engine-plus-weights figure.

| Model | Jan | Bionic (net of app) | difference |
|---|---|---|---|
| Qwen3.5 9B | 5.75 | 8.53 | Jan uses 33% less |
| Gemma 4 E4B | 5.76 | 9.68 | Jan uses 40% less |
| Gemma 4 26B A4B QAT | 14.85 | 16.93 | Jan uses 12% less |
| Qwen3.8 27B | 15.18 | 16.39 | Jan uses 7% less |

### Time until the model can answer (s)

Server launch or `lms load`, plus the first request. Reported together
because both engines mmap the weights: load alone returns before the
pages are faulted in, so it flatters a warm page cache.

| Model | Jan | Bionic |
|---|---|---|
| Qwen3.5 9B | 2.5s | 6.7s |
| Gemma 4 E4B | 3.4s | 7.6s |
| Gemma 4 26B A4B QAT | 3.6s | 8.6s |
| Qwen3.8 27B | 3.6s | 9.1s |

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

