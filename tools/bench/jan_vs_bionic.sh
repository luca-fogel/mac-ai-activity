#!/bin/bash
# Jan's MLX-Swift engine vs Bionic/LM Studio's bundled MLX runtime, on the SAME
# weights.
#
# Jan ships `mlx-server`, a native MLX-Swift binary, and its MLX model entries
# are pointers into ~/.lmstudio/models — so both engines read one copy of each
# model off disk. There is no quantization difference to confound this.
#
# Rules, all of them there to stop a number being wrong rather than to be tidy:
#   * ONE model resident at a time. These are 15 GB models on a 64 GB machine
#     and the other engine is stopped before each run; two resident at once
#     swaps, and a swapping benchmark measures the SSD.
#   * Each engine is measured by the same client (bench_engine.py) over the same
#     protocol, with prompt token counts matched exactly per model.
#   * Load time is wall-clock to first successful /v1/models answer, which is
#     what a user waits through.
#   * PARALLELISM IS MATCHED; CONTEXT CANNOT BE. Left to itself LM Studio loaded
#     Qwen3.8 27B with parallel 4, which alone changes the KV footprint, so
#     --parallel 1 is now passed and DOES apply. --context-length does NOT:
#     VERIFIED, requesting 8192 and 16384 both left `lms ps` reporting 262144,
#     so LM Studio ignores it for MLX models.
#
#     That turns out not to matter here, and it is worth writing down why rather
#     than leaving it as an unmatched variable. MEASURED: the 9B model idle after
#     load held 7.52 GB and only grew to 11.02 GB during the 4k run. A
#     preallocated 262144-token cache would be tens of GB. So the reported
#     context is a CEILING and MLX grows the cache on demand — at a ~4.1k-token
#     working set both engines allocate for ~4.1k tokens, whatever ceiling they
#     advertise. Jan's --ctx-size 8192 is likewise a cap, never reached.
#   * COOLDOWN between runs. The first pass ran Jan then Bionic for every model,
#     and by the end the machine was at 79 C with fans at 6200 rpm — an
#     ordering that systematically penalises whichever engine goes second.
#     Each measurement now waits for the die to settle, and the order alternates
#     per model so any residual bias is visible instead of baked in.
set -uo pipefail

# Self-locating, so the harness runs from wherever the repo is checked out
# rather than from the one directory it was written in. Exported because the
# quoted heredocs below cannot expand a shell variable and read it from the
# environment instead.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BENCH_HOME="$HERE"

LMS="$HOME/.lmstudio/bin/lms"
PY="$HOME/.venvs/mlx/bin/python3"
MLXSRV="/Applications/Jan.app/Contents/Resources/resources/bin/mlx-server"
MODELS="$HOME/.lmstudio/models/lmstudio-community"
OUT="${BENCH_OUT:-$HERE/results/jan_vs_bionic.jsonl}"
LOGS="${BENCH_LOGS:-$HERE/logs}"
PORT=8199
CTX=8192
COOLDOWN="${COOLDOWN:-60}"

# name | lms key | model directory
SPECS=(
  "Qwen3.5 9B|qwen/qwen3.5-9b|$MODELS/Qwen3.5-9B-MLX-4bit"
  "Gemma 4 E4B|google/gemma-4-e4b|$MODELS/gemma-4-E4B-it-MLX-4bit"
  "Gemma 4 26B A4B QAT|google/gemma-4-26b-a4b-qat|$MODELS/gemma-4-26B-A4B-it-QAT-MLX-4bit"
  "Qwen3.8 27B|qwen/qwen3.8-27b|$MODELS/Qwen3.8-27B-MLX-4bit"
)

log() { printf '%s\n' "$*" >&2; }

quiesce() {
  # Both engines idle, and give the OS a moment to actually release the pages.
  "$LMS" unload --all >/dev/null 2>&1
  pkill -f "mlx-server --model" >/dev/null 2>&1
  sleep 5
}

cooldown() {
  # A benchmark that heats the machine measures the fan curve as much as the
  # engine. 60 s of idle between runs is not enough to reach ambient, but it is
  # enough to make the two engines face comparable conditions.
  log "  ...cooling ${COOLDOWN}s"
  sleep "$COOLDOWN"
}

# ---------------------------------------------------------------- Jan
bench_jan() {
  local name="$1" dir="$2"
  quiesce
  cooldown
  log "  [jan] launching mlx-server"
  local t0 t1
  t0=$(python3 -c 'import time; print(time.perf_counter())')
  "$MLXSRV" --model "$dir" --port $PORT --ctx-size $CTX \
      >"$LOGS/jan-$PORT.log" 2>&1 &
  local pid=$!

  # Wait for the model to be served, not merely for the socket to open.
  local ok=0
  for _ in $(seq 1 180); do
    if curl -s -m 2 "http://127.0.0.1:$PORT/v1/models" | grep -q '"id"'; then ok=1; break; fi
    kill -0 $pid 2>/dev/null || break
    sleep 1
  done
  t1=$(python3 -c 'import time; print(time.perf_counter())')
  if [ $ok -ne 1 ]; then
    log "  [jan] FAILED to serve $name"
    python3 - "$name" <<'PY' >>"$OUT"
import json,sys
print(json.dumps({"engine":"jan","model":sys.argv[1],"error":"mlx-server did not serve the model"}))
PY
    tail -5 "$LOGS/jan-$PORT.log" >&2
    kill $pid 2>/dev/null; sleep 3
    return
  fi
  local load
  load=$(python3 -c "print(round($t1-$t0,2))")
  log "  [jan] serving after ${load}s"

  # mlx-server names the model itself; ask rather than assume.
  local mid
  mid=$(curl -s -m 5 "http://127.0.0.1:$PORT/v1/models" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')

  "$PY" - "$name" "$mid" "$dir" "$load" "$pid" "$PORT" <<'PY' >>"$OUT"
import json, sys
sys.path.insert(0, __import__("os").environ["BENCH_HOME"])
from bench_engine import bench
name, mid, d, load, pid, port = sys.argv[1:7]
r = bench(f"http://127.0.0.1:{port}/v1/chat/completions", mid, d, [int(pid)], label=name)
r.update(engine="jan", engine_detail="Jan mlx-server (MLX-Swift)", model=name,
         load_s=float(load))
print(json.dumps(r))
PY
  kill $pid 2>/dev/null; sleep 3
}

# ---------------------------------------------------------------- Bionic
bench_bionic() {
  local name="$1" key="$2" dir="$3"
  quiesce
  cooldown
  log "  [bionic] loading $key"
  local t0 t1
  t0=$(python3 -c 'import time; print(time.perf_counter())')
  # -c and --parallel matched to mlx-server, which serves one request into one
  # context. Without these LM Studio allocates the model's full trained window.
  if ! "$LMS" load "$key" -y --ttl 3600 -c $CTX --parallel 1 >/dev/null 2>&1; then
    log "  [bionic] FAILED to load $name"
    python3 - "$name" <<'PY' >>"$OUT"
import json,sys
print(json.dumps({"engine":"bionic","model":sys.argv[1],"error":"lms load failed"}))
PY
    return
  fi
  t1=$(python3 -c 'import time; print(time.perf_counter())')
  local load
  load=$(python3 -c "print(round($t1-$t0,2))")
  log "  [bionic] loaded after ${load}s"

  # The MLX runtime lives in a child of Bionic; attribute RAM to the whole tree.
  local pids
  pids=$(pgrep -f "Bionic" | tr '\n' ' ')

  # shellcheck disable=SC2086  -- deliberate word splitting: one argv per pid
  "$PY" - "$name" "$key" "$dir" "$load" $pids <<'PY' >>"$OUT"
import json, sys, os
sys.path.insert(0, os.environ["BENCH_HOME"])
from bench_engine import bench
name, key, d, load = sys.argv[1:5]
pids = [int(p) for p in sys.argv[5:]]
r = bench("http://127.0.0.1:1234/v1/chat/completions", key, d, pids, label=name)
r.update(engine="bionic", engine_detail="Bionic/LM Studio bundled MLX runtime",
         model=name, load_s=float(load))
print(json.dumps(r))
PY
  "$LMS" unload --all >/dev/null 2>&1
  sleep 3
}

# Optional substring filter, so the harness can be validated on the cheapest
# model before committing to four 15 GB load/unload cycles.
FILTER="${1:-}"

mkdir -p "$LOGS" "$(dirname "$OUT")"
: >"$OUT"
I=0
for spec in "${SPECS[@]}"; do
  IFS='|' read -r name key dir <<<"$spec"
  if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then continue; fi
  log ""
  log "=== $name ==="
  # Alternate which engine goes first, so thermal drift does not always land on
  # the same one.
  if [ $((I % 2)) -eq 0 ]; then
    bench_jan    "$name" "$dir"
    bench_bionic "$name" "$key" "$dir"
  else
    bench_bionic "$name" "$key" "$dir"
    bench_jan    "$name" "$dir"
  fi
  I=$((I + 1))
done
quiesce
log ""
log "done -> $OUT"
