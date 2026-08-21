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
| **Cooling** | How hot the die actually is, what the fans are doing, and — with the helper installed — what you want them to do instead |
| **Sources** (⌘I) | Per-source health, measured rates, observer cost, and what is *not* measurable |

Engines: llama.cpp via **[Jan](#jan)** (router mode, multi-instance, log-based
telemetry) and via **Bionic**/LM Studio, plus Bionic's embedded MLX, **mlx-lm**,
LocalAI and Ollama.

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
   real window `.unavailable`. **Except under [Jan](#jan)**, which launches with
   auto-fit off and so pins the window down exactly — the one configuration
   where this app can state it.
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
- **Five source states, not two.** `absent` / `live` / `held` / `stale` / `dark`
  are rendered as visually incommensurable, and the distinctions are load-bearing:
  a stopped server is *absent*, not failed; a value whose source refreshes every
  ~4 s is *held*, not stale; a push stream between events is *absent*, not stale;
  and a source that has not answered yet is only *dark* once an attempt has
  actually failed. Judged by one pure function, `Freshness.judge`, against a
  per-source `FreshnessPolicy` — because these sources differ in kind, not merely
  in rate.
- **The observer effect is first-class.** Polling `/slots` occupies the decode
  loop, so the app measures and displays its own cost, and offers a
  minimum-perturbation cadence.

## Measured cost

Sampling and display are separate concerns, and only one of them is expensive.

| | |
|---|---|
| `GPUAccelerator.sample()` | **26.9 µs** (vs 3.3 ms for the whole IORegistry dict, 22 ms shelling `ioreg`) |
| `MachMemory.sample()` | **3.7 µs** |
| Combined collector tick | **30.6 µs** |
| **Whole collector feed, headless (no UI)** | **0.40% of one core** |
| Window open, no data attached | 0.20% |
| Window idle (1 Hz display) | **2.3%** |
| Window during a generation (5 Hz display) | **11.4%** |
| Window occluded | ~0 (display paused entirely) |

The collection layer meets its budget with room to spare; essentially all the
cost is SwiftUI re-laying-out the window, and it scales with the **display**
rate, not the sample rate. So the display rate is adaptive — 1 Hz idle
(Activity Monitor's own cadence), 5 Hz while generating — while **sampling stays
at full rate regardless**, so no history is lost and nothing analytical is
traded away. 10 Hz display was measured at 16.7% and judged not worth it.

This matters less than it looks for perturbation: llama.cpp inference is
GPU-bound and its own backend process uses ~0.2% CPU, so the app is not
competing for the resource under test. The real perturbation risk is `/slots`
polling, which is separately controlled in the Sources inspector.

## Jan

[Jan](https://www.jan.ai/) is supported as a first-class engine, and it is the
cheapest one here to watch. It is also structurally unlike every other engine in
this app, so most of the work was in not reporting confident nonsense about it.

Verified against **Jan 0.8.4 / llama.cpp b9967** on this machine.

### It is three tiers, not one process

```
Jan.app (Tauri)                        the UI, holds no weights
└── llama-server --models-preset …     the ROUTER, holds no weights
      ├── llama-server --alias A …     instance A, its own ephemeral port
      └── llama-server --alias B …     instance B, its own ephemeral port
```

Every other engine here is one process, one model, one port. Jan runs a router
in llama.cpp's experimental **router mode**, which holds no weights and spawns a
child server per model on demand, up to `--models-max` (2 by default: one user
model plus the bundled embedding model).

Consequences, each of which is a way to get a wrong number:

1. **The router is not a model server.** Its `/props` reports `"role":"router"`,
   `model_path: "none"`, `n_ctx: 0`. Describing it with the same fields as a
   model server produces a runtime that appears to hold a nil model in a
   zero-token context — which is what the roster header showed until
   `bestRuntime(for:)` learned to rank an engine's rows instead of taking the
   first.
2. **Jan and Bionic are indistinguishable by process name.** Both spawn a
   bundled binary named exactly `llama-server`. The registry keys its cache by
   engine, so filing one as the other made the two overwrite each other's
   descriptor on every scan — a permanent generation change, which tears down
   the slot state machines and resets every derived rate once a second. They are
   separated by install path, and `--models-preset` then distinguishes a router
   from a child.
3. **All ports are ephemeral, and appear in no config file.** The router takes
   whatever port Jan hands it (observed 61378, then 65391 after a restart);
   children are launched with `--port 0`, so the kernel assigns one. The only
   sources of truth are argv and the listening socket.
4. **Memory belongs to the children.** MEASURED: the router's footprint was
   45 MB while its 4B-model child held 3.0 GB. Attributing Jan's memory to the
   process that owns the port reports about 1.5% of what Jan is holding, so the
   system sampler follows every Jan pid, and the Engines view matches rows to
   processes **by pid** — matching by engine gave the router and a 3 GB instance
   identical footprints.

### The API key is in the environment

Jan mints a random `LLAMA_API_KEY` per launch and passes it in the router's
**environment**. It is not in argv, not in any config file, and not in the
keychain. Without it `/slots`, `/props` and `/metrics` all answer
`401 Invalid API Key` — i.e. the entire inference domain is dark for a server
that is running and healthy. `/health` and `/v1/models` stay open.

So `ProcArgs` now reads the environment as well as argv (`KERN_PROCARGS2`
returns both in one buffer). Children inherit the variable, so one read
authenticates all three tiers. It is wrapped in `APIKey` on the way out and is
never rendered, logged or copied into a sample.

### Asking the router a question can cost 3 GB

This is the one that mattered most, because this app's central promise is that
it is observe-only.

In router mode `/slots` and `/props` require a `?model=` parameter — and
`models_autoload` is on, so **naming a model that is not loaded makes the router
load it**. MEASURED: a single `GET /props?model=sentence-transformer-mini`
against an idle router spawned a child server and logged
`ensure_model: waiting until model name=… is fully loaded`. Against a 3 GB model
that same call would have pulled 3 GB off disk and into the GPU because a
monitor asked a question.

An observer that can do that is not an observer. So:

* the roster comes from **`/v1/models`**, which takes no model name and no key,
  and reports each model's residency plus the exact argv it would be launched
  with — enough to describe a model that has never run, without running it;
* slot telemetry comes from the **children's own ports**, where `/slots` is
  unproxied, needs no `?model=`, and cannot load anything;
* the router's own `/slots` is never polled at all.

Models Jan knows about but has not loaded are listed as unreachable and holding
nothing, which is exactly true — there is no process behind them.

### The context caveat lifts here

The first of [the six traps](#the-six-traps-this-was-built-around) is that there
is no honest denominator for context fill: `n_ctx` is the model maximum and
`--fit-ctx` is a target the server was observed to exceed by 6%.

Jan is the exception, and it is worth stating precisely because the app spends
so much effort refusing to guess. Jan launches every model with **auto-fit off**
(its own settings key, `llamacpp_fit_off_v1`), so `--ctx-size` is a real
allocation, divided evenly across `--parallel` slots. VERIFIED three ways for
the same child: launched `--ctx-size 8192 --parallel 2 --fit off`; its own log
line reads `n_slots = 2, n_ctx_slot = 4096`; and `/slots` reports `n_ctx: 4096`.

Meanwhile the child announces `n_ctx_train: 262144`. So under Jan the two
quantities this app normally cannot separate are **both** stated by the engine,
and they are 64x apart. `ContextFill` therefore publishes the allocated window
as a real `.high` estimate, the UI shows the one true ratio instead of two
hedged ones, and it also names the headroom — a slot given 4096 tokens of a
model trained for 262144 is a fact the user can act on.

Where the flags do not pin it down, nothing changes: the caveat and both named
denominators come back.

### Telemetry is free here

Everywhere else, per-token telemetry costs something: `/slots` is serialized
behind llama.cpp's decode loop, so each poll takes 100-450 ms of server time
away from generating — a cost this app measures and displays because it cannot
avoid it.

Jan avoids it. The router runs its children at verbosity 3 and pipes their
stdout into `~/Library/Application Support/Jan/data/logs/app.log`, where
llama.cpp's own instrumentation is already written down:

```
[52550] I slot launch_slot_: id  0 | task 1322 | processing task, is_child = 0
[52550] I slot print_timing: id  0 | task 1322 | n_decoded = 848, tg = 56.37 t/s, tg_3s = 52.56 t/s
[52550] I slot print_timing: id  0 | task 1322 | prompt eval time = 108.39 ms / 26 tokens (…, 239.88 tokens per second)
[52550] I slot print_timing: id  0 | task 1322 |        eval time = 16040.54 ms / 900 tokens (…, 56.11 tokens per second)
[52550] I slot      release: id  0 | task 1322 | stop processing: n_tokens = 929, truncated = 0
```

That is strictly more than `/slots` reports, and it is free:

* **`tg_3s` is a trailing 3-second rate** — the same quantity this app derives
  by differencing `n_decoded` across polls, except llama.cpp computes it
  internally and prints it. It is the engine's own number, so it is exact where
  ours is estimated, and it is published as the engine's, not laundered into a
  measurement of ours. `tg` next to it is the whole-request mean; the two are
  genuinely different (observed 59.13 vs 45.97 t/s in one line) and the key
  names differ only by a suffix, so a loose match silently reports an average as
  an instantaneous rate.
* **The receipt is exact.** `prompt eval time` is the true prefill duration, so
  TTFT arrives as a number rather than as the poll-interval-wide bracket
  `/slots` forces everywhere else. These become `PredictionSample`s at `.high`
  confidence — the same type LM Studio's receipts use.
* **The `[port]` prefix identifies the instance**, so two models logging
  concurrently stay separable.

`/slots` is then polled only for the two things the log genuinely does not
carry — live context occupancy and the sampler settings in force — and only
against an instance with a request actually in it. **An idle Jan is not polled
at all**; the status rail reads `self-cost 0 polls/min · 0% of server`.

That has one consequence worth naming, because it nearly produced exactly the
kind of false fault the five source states exist to prevent. A `/slots` channel
judged as a fixed-rate poll goes `stale` after two missed intervals — so
deliberately not polling an idle Jan lit an amber chip on a perfectly healthy
server. Jan's channel is therefore judged `eventDriven`: quiet means idle, not
broken, which is the same rule the app already applies to LM Studio's push
stream. `FreshnessPolicy.slots(for:)` owns that distinction, and both the status
rail and the Sources inspector go through it.

A child announces its model facts — `n_params`, `size`, `ftype`, `n_ctx` and
`n_ctx_train` — exactly once, in a `ready` message when it finishes loading. An
app that starts tailing afterwards, which is the normal case, would never see
it, so the quantization chip and the context-headroom line would be blank on a
machine where everything is working. So the existing log is read once at startup
and **only the identity-bearing lines are ingested**; timing lines are skipped
entirely, which is what stops a week-old generation reappearing as a fresh
receipt. (`n_ctx_train` has no other source: a child's `/props` returns
`model_alias`, `model_ftype`, `model_path`, `total_slots` and `n_ctx`, and
nothing about the model's trained ceiling.)

Two things the log cannot do, stated because silence must not read as idleness:
`print_timing` lines arrive every ~3 s rather than per token, so a 2 s
generation produces a receipt and no live rate at all; and the log is
instance-wide and carries no caller identity, so a generation driven by Jan's
chat window, by another app, or by this one are indistinguishable — the same
limitation as LM Studio's diagnostics stream.

### A fast model broke decode detection

Trap six is that `n_decoded` is not reset at request start: it holds the
previous request's value through the whole of prefill. The two signals that
established trust both required catching the counter early — seeing it drop, or
seeing it climb from below 64 while prompt processing had stopped.

Jan's default model is a 4B at ~72 tok/s whose prefill took **128 ms**. That is
over before the first 1 Hz poll, so the stale value was never observed (no drop
to see) and by the first reading the counter was already past 64. Neither signal
could ever fire: the slot reported `prefilling` for the entire generation and no
live decode rate was ever published for a server that was plainly decoding.

The third signal needs no luck, only two consecutive polls: **prompt processing
frozen while total context is still growing.** Only emitted tokens can do that,
so decode has begun regardless of what `n_decoded` reads. The protection is
intact — while prefill is still advancing the counter stays hidden — and it now
works on fast models generally, not just Jan's.

### What is still not measurable under Jan

* **`/metrics`.** Jan starts llama-server without `--metrics`, on the router and
  on every child, so it answers `501 This server does not support metrics
  endpoint`. Those counters would have given exact per-request token totals with
  no polling at all. Nothing this app does can enable them.
* **Anything about a model that is not loaded**, beyond what the catalogue
  states — see above.
* **Which client drove a generation.**

### Verifying it

```sh
swift run telemetry-probe --jan     # topology, key, catalogue, then live receipts
swift run telemetry-probe --live    # the whole collector, Jan included
```

`--jan` prints the discovered tiers, whether the key was found, the load hazard
and the metrics gap, then tails the log and prints each generation's live rates
and final receipt. It sends nothing that could make the router load a model.

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
fails on regression. `--live`, `--discover`, `--power` and `--thermal` run the
collectors headless; `--thermal` also asserts the SMC sweep's CPU budget and
prints what `aithermald` reports, if it is installed.

## Heat and fans

The Cooling view reads die temperatures and fan tachometers from the SMC, and —
with a small root helper installed — writes fan targets back. Reading is
root-free; writing is not, and that asymmetry is the whole shape of the design.

### The sensor map was measured, not assumed

Neither available path labels a sensor on this chip. `IOHIDEventSystemClient`
(the private API other tools use) does return names on an M2 Max, but they are
PMU-level — `tdie0` … `tdie10`, `TP0s`, `tcal` — with nothing indicating which
belong to the GPU. The SMC keyspace is unnamed by construction. So the CPU/GPU
split was established by load response: three phases (idle, 12-way CPU burn,
saturated MLX matmul) with every `flt` key in the `T*` space sampled at 0.5 Hz.

| prefix | keys | idle | CPU burn | GPU burn | verdict |
|---|---|---|---|---|---|
| `Tp` | 54 | 46–75 °C | **+40 … +52** | −38 … −10 | CPU performance cores |
| `Te` | 3 | 67–76 °C | +16 | +7.5 | CPU efficiency cores |
| `Tg` | 16 | 63–71 °C | +13 | **+17.5** | GPU |
| `TB` | 3 | 36 °C | flat | flat | battery pack |

The `Tp` sign flip is the strongest evidence in the table: those sensors go
*down* by up to 38 °C when the load moves to the GPU, which no shared-die
artefact would do. `Tf` (47 keys) responds to both loads and looks tempting
until you notice `Tf06` reads **115 °C at idle** and `Tf00` reads **0.07** —
whatever those are, they are not die temperatures. `TR`/`Th`/`Ts`/`TP`
(67 keys) are plausible and load-responsive but unattributable; they are listed
in the inventory and never headlined.

### Five traps in this domain, all measured

1. **A parked cluster reads colder than the room.** `Tp0g` read **113.3 °C**
   during the CPU burn and **23.3 °C** sixty seconds later during the GPU burn,
   while the GPU sensors sat at 82 °C. The cluster is power-gated, not cold. A
   headline labelled "CPU temperature" would therefore *fall* as the machine got
   hotter — and GPU-bound is what local inference always is. Readings below
   25 °C are classified `parked`, excluded from the hotspot, and counted on
   screen; a group with nothing left is `.unavailable`, never a number.
2. **The hotspot is a max, not a mean.** Averaging 54 P-core sensors answers a
   question about the die's *area*. Throttling is decided by the hottest spot,
   so that is what is published, with the cluster's spread as its uncertainty.
3. **A stopped fan is a measurement.** Both fans sit at **0 rpm** when the
   machine is cool — below the **2317 rpm** minimum the SMC will accept as a
   *forced* target. So manual control can only ever be **louder than automatic
   at idle**, and the UI says so rather than letting you discover it.
4. **`fpe2` vs `ui16`.** Fan keys are `flt ` on Apple Silicon but `fpe2` (14.2
   fixed point) on older hardware. Decoding one as the other reports **4x** the
   real rpm. Both are in the decoder and both are tested.
5. **There is no throttle percentage here.** `IOPMCopyCPUPowerStatus` returns
   `kIOReturnNotFound` and `pmset -g therm` records nothing: the Intel-era
   `CPU_Speed_Limit` does not exist on Apple Silicon. The app publishes
   `.unavailable` with that reason and leans on the OS thermal-pressure ladder,
   which is real, instead of inventing a percentage.

And one encoding trap that cost the first working build: `SMCKeyData_t.key` is a
**host-order integer**, not a four-byte string. Storing `'#KEY'` big-endian —
the intuitive reading of "four character code" — yields `result 0x84, key not
found` from a perfectly open connection.

### Cost: 13 ms of waiting, 0.76 ms of work

One SMC key read costs **195 µs of wall time but only 13.8 µs of CPU** — 93% of
it is the caller blocked on a microcontroller across a slow bus. A 76-key sweep
is therefore **13.0 ms wall, 0.76 ms CPU**. Both numbers matter, and they
point in opposite directions:

- 0.76 ms per second is **0.076% of one core**, so every sensor can be read every
  second. No rotating subsets, no reduced key map that might miss the hotspot.
- 13.0 ms of *blocking* inside `LiveTelemetryFeed`'s actor would punch a 13 ms
  hole in the 10 Hz system loop once a second — the mistake `LMStudioProbe`
  already cost this project once, at 240 ms.

So the sweep runs on its own dedicated thread and publishes through a stream
like any other source. `telemetry-probe --thermal` asserts both costs and fails
on regression. The `IOHIDEventSystem` path was benchmarked as the alternative
and rejected: **1016 µs per sensor, 4.6x worse**, for names that do not answer
the question anyway.

### Control: what `aithermald` will not do

Fan control needs root — and the refusal happens at the **kernel**, not in an
SMC status byte: as uid 501, `IOConnectCallStructMethod` returns
`kIOReturnNotPrivileged` (0xE00002C1) for a write while reads on the *same*
connection succeed. (`telemetry-probe --smc` walks into that boundary
deliberately and asserts it.) So control lives in a ~400-line LaunchDaemon
rather than in an app bundle carrying AppKit. The app is a client and is **not
trusted by it**:

```sh
sudo ./tools/install-cooling-helper.sh      # install + start
sudo ./tools/install-cooling-helper.sh --selftest    # prove the write path only
sudo ./tools/install-cooling-helper.sh --uninstall
```

Everything else in the app works without it, read-only.

| Rule | Enforced by |
|---|---|
| Only `F<n>Md` and `F<n>Tg`, for `n < FNum`, are ever written | a literal allowlist in `FanWriter` |
| No rpm outside the range the hardware itself reports (`F<n>Mn`/`F<n>Mx`) | `FanGuard.clamp`, and a clamp is always reported, never silent |
| Nothing held longer than **60 s** without renewal | lease, checked on the helper's own 1 Hz clock |
| Released the moment the hotspot hits the ceiling (default **95 °C**) — *even while the client is happily renewing* | `FanGuard.evaluate`, against a temperature the **helper** read |
| Released on serious/critical OS thermal pressure | same |
| Released if a commanded fan stops tracking for >8 s | same |
| Released on SIGTERM/SIGINT/SIGHUP and on exit | signal flag → run loop, never IOKit on a signal stack |
| Fans returned to automatic on **startup**, unconditionally | the only thing that recovers from a `SIGKILL`ed predecessor, which leaves the SMC holding its last rpm forever |
| Commands refused from any other uid | `getpeereid`, plus a 0660 root-owned socket |
| After a trip, manual control refused for 60 s *and* until the die is 5 °C clear of the ceiling | hysteresis, so a cutout cannot become a flap |

The dangerous half of this feature is therefore verifiable without overheating a
laptop: `FanGuard` is pure functions over values, and `FanGuardTests` exercises
every release path, the ordering between them, and the clamp boundaries. The
socket protocol is exercisable without root too —
`aithermald --serve --unprivileged --socket /tmp/x.sock` runs the whole control
plane and guard loop while the kernel refuses every write, which is how the
refusal path below was verified rather than assumed:

```
$ printf '{"version":1,"op":"set","targets":{"0":4200},"leaseSeconds":15}\n' | nc -U /tmp/x.sock
{"ok":false,"error":"SMC write to fan 0 failed: not privileged — SMC writes require root"}
$ printf '{"version":99,"op":"status"}\n' | nc -U /tmp/x.sock
{"ok":false,"error":"client speaks protocol 99, helper speaks 1"}
```

### Why an inference app should control fans at all

Because it knows something a thermostat cannot: **when the work starts.** A die
takes seconds to heat and a fan takes seconds to spin up, so a temperature curve
is always chasing. `Boost while generating` spins the fans up on the *request* —
the app can see a generation begin — and holds for a trailing window afterwards,
because a burst of short prompts should not produce a fan sawtooth. The boost is
a **floor**, not a cap: if the curve wants more air at 90 °C than the comfort
setting asks for, the hotter answer wins.

The Episodes table then carries the consequence: peak die temperature, the rise
across the generation, and a marker when the fans were **held by this app** —
because a tok/s figure measured under a forced fan is not comparable with one
measured on the SMC's own curve, and that has to be visible rather than
remembered.

### A by-product: `PSTR` may be the wattage this app has been missing

Not wired in, recorded here because it bears on the app's most-quoted
limitation. The SMC exposes `PSTR`, which behaves like whole-system power and is
readable **on AC**, where the `AppleSmartBattery` path reports nothing usable:

| condition | `PSTR` | battery path (`SystemLoad`) |
|---|---|---|
| idle | 5.1–9.0 W (mean ~7.1) | 6.74 W, held unchanged for 7 s |
| 12-way CPU burn | 44.0 W | — |
| saturated GPU matmul | 60.5 W | — |

They agree within ~6% at idle, and `PSTR` moves every sample where the battery
key refreshes every ~4 s. If that survives a proper on-battery load sweep, then
joules-per-token becomes answerable on AC — which is the difference between the
headline metric working always and working only when unplugged. It is left
unwired deliberately: one 8-sample agreement at one operating point is evidence,
not a calibration.

## Why not reuse llmctl / qwen-control

`llmctl status --json` and `qwen-control`'s `/state` were evaluated and
rejected as *runtime* dependencies: both shell out (175 ms for `/state`), and
every field they provide is now collected natively in microseconds. `llmctl`'s
`sysmem()` **formula** is preserved exactly in `MachMemory` — excluding
file-backed page cache from "used" is hard-won and non-obvious, because a
20–46 GB mmap'd GGUF in the cache would otherwise read as memory pressure.

## GGUF vs MLX, benchmarked

`tools/ab-engines.py` runs both engines **interleaved** (not blocked), because
run-to-run drift here was previously measured at -22% across six runs — five
times the effect under test.

Two blocks, 3 trials each, 220 tokens, identical prompt, Qwen3.8-27B:

| | mean | sd | TTFT |
|---|---|---|---|
| llama.cpp GGUF Q5_K_M | 7.56 tok/s | 0.33 | 4.77 s (sd 1.91) |
| mlx-lm MLX 4-bit | **12.21 tok/s** | 1.33 | 9.21 s (sd 7.26) |

**MLX is +61.4% on throughput**, with complete separation (slowest MLX run beat
the fastest GGUF run) and an exact permutation test at **p = 0.0022**.

Three things keep that from being the whole story:

- **Precision differs.** 4-bit group-64 vs 5-bit K-quant. MLX has an advantage
  going in, though 20% fewer bits does not obviously buy 61% more throughput.
- **GGUF was handicapped in MLX's favour too**: it ran with speculative decoding
  (`--spec-type draft-mtp`) and flash attention, and still lost.
- **TTFT is much worse and 3.8x more variable on MLX** — it swung from 0.28 s on
  a cache hit to 15.89 s on a miss. If you care about latency to first token
  rather than sustained throughput, that reverses the recommendation.

Energy per token could not be measured for this run: the machine was plugged in
and charging, and `SystemLoad` reports net battery flow (negative) rather than
system draw while charging. Unplug, or wait until the battery is full, to get it.

## Jan's MLX engine vs Bionic's, benchmarked

`tools/bench/jan_vs_bionic.sh` compares Jan's bundled `mlx-server` (MLX-Swift)
against Bionic/LM Studio's MLX runtime on **the same weights** — Jan's MLX model
entries are pointers into `~/.lmstudio/models`, so there is no quantization
difference to confound it. Full report and raw passes:
[`tools/bench/JAN_VS_BIONIC.md`](tools/bench/JAN_VS_BIONIC.md) and
`tools/bench/results/*.jsonl`. Two controlled passes, mean ± half-range.

**Prefill splits by architecture, not by engine**, which is why "engine X is
faster" is not a claim this data supports:

| 4k prefill (tok/s) | Jan | Bionic | faster |
|---|---|---|---|
| Qwen3.5 9B | 292 ±8 | 337 ±7 | Bionic, -13.4% |
| Gemma 4 E4B | **895 ±49** | 645 ±52 | **Jan, +38.6%** |
| Gemma 4 26B A4B QAT | 534 ±3 | 509 ±1 | Jan, +4.9% |
| Qwen3.8 27B | 85 ±1 | 92 ±0 | Bionic, -7.9% |

Decode is close to a wash, with Bionic marginally ahead where the two can be
separated at all. Where Jan wins clearly is elsewhere: **7-40% less resident
memory** (net of Bionic's 0.83 GB idle GUI baseline) and **2.5-3.6 s vs
6.7-9.1 s** to a first answer from cold.

Three things produced wrong numbers before they produced right ones, and the
harness carries all three:

- **Thermal drift dominated.** Pass 1 ran Jan-then-Bionic throughout and finished
  at 79 °C / 6200 rpm; the same engine at the same settings re-measured up to
  **23% faster** once cooled, worst on whatever ran last. Without the 60 s
  cooldowns and the alternating order, this benchmark measures the fan curve.
  `results/pass1_unmatched_context.jsonl` is kept as the evidence.
- **`lms load --context-length` is silently ignored for MLX models.** Requesting
  8192 and then 16384 left `lms ps` reporting 262144 both times. `--parallel`
  *does* apply, and LM Studio's default of 4 slots against Jan's 1 changes the KV
  footprint, so that one is matched and context is not — it cannot be. It is
  immaterial at a 4k working set (the 9B held 7.5 GB idle and 11.0 GB during the
  run, so MLX grows the cache on demand rather than preallocating) and unmeasured
  above it.
- **RSS undercounts mmap'd weights.** Gemma 4 E4B is 6.4 GB on disk and peaked at
  5.76 GB resident. These are pages held, not a model footprint.

The harness self-validates: Jan's engine reports its own `timings`, and the
client-side decode rate matched them to **0.00-0.08%** on three models (1.4% on
the 27B). Two passes give a scatter estimate, not a confidence interval, and this
is speed only — no output quality, no energy per token, nothing above 4k context.

## The MLX blind spot

Bionic can host **two backends at once**: llama.cpp (GGUF) and MLX (safetensors).
Only llama.cpp exposes `/slots`. The MLX runtime lives inside a `node` host as a
child of Bionic, binds **no listening socket**, and speaks Bionic's internal IPC —
so process-and-port discovery cannot see it at all.

The first version of this app therefore showed llama.cpp's model name and
"idle" while MLX was visibly generating at 98% GPU. That is the app breaking its
own rule: reporting a stale identity as if it were live. Fixed by

- asking LM Studio directly (`lms ps --json`, 240 ms, slow loop only) for what is
  resident, and distinguishing MLX by `format: safetensors`;
- picking the **working** runtime for the header rather than whichever one has an
  HTTP API;
- flagging **unattributed activity** — high GPU with no instrumented endpoint to
  account for it — instead of reporting idle.

### Half-closed: per-prediction, but still not per-token

`lms log stream --json --stats` taps LM Studio's own diagnostics channel
(`client.diagnostics.unstable_streamLogs`) and reports **completed predictions
for every client of the instance** — GUI, SDK, CLI and the HTTP server alike.
Verified with the OpenAI-compatible server switched **off**: GUI-driven
generations still arrive. Captured from the embedded MLX engine:

```
qwen/qwen3.8-27b [maxPredictedTokensReached]
  10.64 tok/s avg · TTFT 53.111 s · prompt 4063 · predicted 127
```

That is an exact, engine-reported receipt, and it is the app's **first exact
TTFT** — everywhere else TTFT is published as an `Interval` because we are not
the client and can only bracket it by the poll interval. Here the engine *was*
the client.

What it is **not** is a live rate. Exactly one object arrives at the END of a
prediction, correlated to the `generating -> processingPrompt` transition, and
nothing during decode. So:

- energy-per-token for MLX is now answerable, **retrospectively**;
- the live decode rate remains structurally unknowable, and is labelled that way
  rather than interpolated.

A single end-of-prediction summary carries no history, so it must never be fed to
`SlotStateMachine`, whose every derivation needs two observations of a growing
counter. It goes to the **episode** layer instead, where `Episode.tokens` was
already waiting for it.

Three things the integration defends against, all measured rather than assumed:

- **`--filter output` is load-bearing twice over.** It drops
  `llm.prediction.input` events, which are simultaneously the privacy exposure
  (the entire rendered prompt — 25k tokens observed) and the only observed source
  of malformed output: one arrived truncated at exactly 81920 bytes with an
  unterminated string. Every `output` event seen was under 2.2 KB and parsed
  cleanly. A whole generation costs **one line**.
- **The child must not outlive us.** Killing the parent leaves `lms log stream`
  running indefinitely — with no model loaded it never writes, so it never takes
  SIGPIPE from the closed pipe, and macOS has no `PR_SET_PDEATHSIG`. An orphan
  here would hold a live subscription to every prompt on the machine. The child
  runs under a shell that polls our pid; verified reaped after `kill -9`.
- **The API is named `unstable_`.** Every field in the stats block is optional in
  the engine's own schema, and `stats` itself is optional. Absence maps to
  `.unavailable`, never to zero.

No prompt or completion text ever enters a `Sample`. `PredictionSample` has no
field that could hold it — the same discipline `APIKey` applies to secrets.

## aienergy — the CLI

LM Studio already reports tok/s and TTFT, in its own UI and via
`lms chat --stats`, and reports them well. The one thing it has no data for is
**energy**. So `aienergy` does only that part:

```
$ aienergy watch
MODEL                    TOK   TOK/S     TTFT   W avg    J/TOK  NOTE
qwen/qwen3.5-9b          463    46.5    1.52s    25.4    0.519
qwen/qwen3.5-9b           42    63.8    1.51s    25.4    1.315
```

Those two rows are the point: the same model at the same wattage costs **2.5x
more energy per token** for a short generation, because a ~1.5 s time-to-first-
token is amortised over 42 tokens instead of 463. Nothing else on the machine
surfaces that.

`aienergy status` reports what is resident and whether power is readable at all.
`--json` emits NDJSON. Neither ever initiates a generation, and neither reads a
prompt or a completion.

### Why retrospective integration is the RIGHT design here

A receipt arrives when a prediction finishes, and it carries enough to
reconstruct the generation's duration — so power sampled continuously in the
background can be integrated over precisely that window, afterwards. That is
strictly better than the GUI's approach of opening and closing an episode on the
0.2 Hz roster clock, which missed any generation shorter than one poll: MEASURED,
a 131-token generation finished in ~2.2 s and got no energy envelope at all.

Two things the integration refuses to do:

- **Integrate a window it did not observe.** A window starting before the trace
  is `.unavailable` with the shortfall named, never a partial integral presented
  as a whole one — that would understate energy and so understate J/token. The
  trailing edge gets a small tolerance, because a sub-second tail is sampling
  phase, not missing data, on a source that refreshes every ~4 s.
- **Treat absent wattage as zero.** On AC there is no reading at all, and a zero
  would integrate to a generation that apparently cost nothing.

### `totalTimeSec` is not the generation's duration

MEASURED: a generation with `timeToFirstTokenSec: 1.494` and 43 tokens at
62.4 tok/s — about 2.18 s of real work — reported `totalTimeSec: 0.002`.
Integrating power over a 2 ms window produced 0.07 J and a joules-per-token
figure roughly 300x too small: plausible, precise, and wrong.

So duration is reconstructed from the two fields that ARE mutually consistent,
`ttft + tokens/rate`, and the engine's own figure is trusted only when it can be
checked against the TTFT it must contain. Where it cannot be checked, the result
is `.low` confidence rather than `.high` — an unverifiable number does not earn
the same standing as a verified one.

### Killing the child is harder than it looks

`lms log stream` holds a subscription to every prompt on the machine, so an
orphan is a privacy problem, not untidiness. Three mechanisms were tried and
MEASURED failing before the fourth worked:

1. Polling `kill -0 <our pid>` from a supervising shell — macOS **recycled the
   pid**, an unrelated process inherited it, and the watchdog polled a stranger
   forever while two streams kept running.
2. Closing a pipe the child reads, so its read returns EOF on our death — did not
   reliably reach the shell.
3. Terminating the shell — strands the CLI, because the shell is the only thing
   that would have killed it.
4. **Reading the grandchild's pid from the process table and signalling it
   directly**, plus an `EXIT/TERM/INT/HUP` trap in the shell for the crash case.
   Verified reaped under SIGINT, SIGTERM and SIGKILL.

A fifth bug hid behind those: `^C` did nothing at all, because the
`DispatchSource` was on `.main` while the main thread blocked in `sem.wait()`, so
the handler never ran — and SIGINT was `SIG_IGN`'d for the source to work. The
surviving child was never leaked; nothing had asked it to stop.

## Not measurable here

- GPU/ANE wattage — needs root (`powermetrics`). Whole-system watts via
  `AppleSmartBattery` is root-free and is what the app uses.
- **Live** per-token rate on MLX — one stats object per prediction, nothing during
  decode. The retrospective average is exact; the instantaneous rate does not
  exist to be read.
- Speculative accept rate on llama.cpp — `/slots` exposes the configuration only,
  and `/metrics` returns 501 because Bionic does not pass `--metrics`. LM Studio
  *does* report accepted/rejected draft counts per prediction, so it is
  measurable there whenever a draft model is in use.
- Power on AC — battery amperage reflects charging current, not load. (But see
  `PSTR` above: there may be a way out of this one.)
- CPU throttle percentage — `IOPMCopyCPUPowerStatus` returns `kIOReturnNotFound`
  on Apple Silicon and `pmset -g therm` records nothing. The OS thermal-pressure
  ladder is shown instead of a fabricated percentage.
- Which cluster a sensor belongs to, *from the hardware* — no available API says.
  The map in the Cooling view was established by load response, and the 67
  plausible `T*` sensors that could not be attributed that way are listed but
  never headlined.
- A manual fan setting quieter than automatic — the SMC accepts no forced target
  below 2317 rpm while its own loop stops the fans entirely when cool.
- True energy integration — `AccumulatedSystemEnergyConsumed` is now sampled at
  episode boundaries, but its units are undocumented, so the app publishes the
  implied ratio against the trapezoidal figure for calibration rather than
  asserting joules it cannot justify.
