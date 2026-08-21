# Contributing

The most useful contribution right now is **a reading from hardware that is not
an M2 Max**. Everything in this app was measured on one machine, and the parts
most likely to be wrong elsewhere are the SMC sensor map and the fan decoder.

## Reporting hardware differences

```sh
swift run telemetry-probe --thermal    # sensor inventory + per-group response
swift run telemetry-probe --live       # every collector, headless
swift run telemetry-probe --discover   # which engines were found, and how
```

Paste the output along with your chip and macOS version. `--thermal` output
contains no prompts, no model names you did not load, and no identifiers.

## The one rule

**A measurement is a number; the absence of one is `—`.** If you cannot read a
quantity, publish `.unavailable` with the reason, never a zero, an interpolation,
or a plausible default. Most of the code in `Sources/Telemetry` exists because
some engine served a plausible wrong number and something had to refuse it.

Concretely:

- Derive a rate only from two observations of a counter you have proven is
  advancing. Several engine counters do not reset at request start.
- Do not fuse sampling domains. Each source carries its own timestamps.
- An engine's own reported figure is published as *the engine's*, not laundered
  into a measurement of ours.
- Nothing in this app may cause an engine to load a model, start a generation,
  or read prompt text. That is the whole premise; a PR that breaks it will not
  be merged regardless of what it adds.

## Before opening a PR

```sh
swift build
swift test                                    # must stay green
swift run -c release telemetry-probe --cost   # asserts the collector CPU budget
```

New behaviour in `Sources/Telemetry` needs a test. If you found a trap — an
engine reporting something misleading — add the test that fails on the naive
reading, and write down the measurement in
[`docs/ENGINEERING-NOTES.md`](docs/ENGINEERING-NOTES.md). The notes are the
point of the project as much as the app is.

## Sign your work (DCO)

Add a `Signed-off-by` line to each commit — `git commit -s` does it for you:

```
Signed-off-by: Your Name <your.email@example.com>
```

That line is the [Developer Certificate of Origin](https://developercertificate.org/):
you are stating that you wrote the patch, or otherwise have the right to submit
it under this project's licence (GPL-3.0). It is one line, not a copyright
assignment — you keep the copyright in your own work.

## Scope

In scope: more engines, more hardware, better attribution, honest measurement.

Out of scope: chat UIs, model management, benchmarking leaderboards, and
anything that writes to hardware other than the two fan keys `aithermald`
already allowlists.
