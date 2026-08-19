#!/bin/bash
# Starts mlx-lm's server with its log where AI Activity can read it.
#
# mlx-lm exposes only /health and /v1/models over HTTP -- no /slots, no
# /metrics -- so the log IS the telemetry channel. INFO level carries
# prompt-processing progress and prompt-cache state; DEBUG adds the response
# body with token counts.
set -euo pipefail
MODEL="${1:-$HOME/.lmstudio/models/lmstudio-community/Qwen3.8-27B-MLX-4bit}"
PORT="${2:-8131}"
LOG="$HOME/.local/state/mlx-lm/server.log"
mkdir -p "$(dirname "$LOG")"

# 8080 is LocalAI here, so mlx-lm's default would collide.
echo "model: $MODEL"
echo "port:  $PORT"
echo "log:   $LOG"
exec ~/.venvs/mlx/bin/mlx_lm.server \
  --model "$MODEL" --host 127.0.0.1 --port "$PORT" \
  --log-level DEBUG >>"$LOG" 2>&1
