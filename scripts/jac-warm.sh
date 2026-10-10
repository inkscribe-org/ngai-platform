#!/usr/bin/env bash
# Compile the Jac harness once so later boots are warm (~2s instead of
# minutes; see AGENTS.md §9). Boots `jac run` in jac/harness against a
# throwaway data dir, waits until an op answers, then stops it. The compile
# cache lands in jac/harness/.jac/.
#
# Usage: scripts/jac-warm.sh [timeout-seconds]   (default 2400)
# Env:   JAC (binary; default: the jac.toml pin under jacup, else `jac`)
set -euo pipefail
cd "$(dirname "$0")/../jac/harness"

TIMEOUT="${1:-2400}"
PIN=$(sed -n 's/^jac-version *= *"\(.*\)"/\1/p' jac.toml)
JAC="${JAC:-}"
if [ -z "$JAC" ]; then
  if [ -x "$HOME/.local/share/jacup/versions/$PIN/jac" ]; then JAC="$HOME/.local/share/jacup/versions/$PIN/jac"; else JAC=jac; fi
fi
PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
DATA=$(mktemp -d)
LOG="$DATA/jac.log"
export TMPDIR="${XDG_CACHE_HOME:-$HOME/.cache}/jac/tmp"
mkdir -p "$TMPDIR"

OMB_DATA_DIR="$DATA" "$JAC" run --no-client -p "$PORT" > "$LOG" 2>&1 &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; rm -rf "$DATA"; }
trap cleanup EXIT

START=$(date +%s)
until curl -sf -m 2 -X POST "http://127.0.0.1:$PORT/function/routine_state" \
    -H 'content-type: application/json' -d '{}' > /dev/null 2>&1; do
  if ! kill -0 "$PID" 2>/dev/null || grep -q "✖" "$LOG"; then
    echo "jac harness failed to boot:" >&2
    grep -v '"level": "INFO"' "$LOG" | tail -60 >&2
    exit 1
  fi
  if [ $(( $(date +%s) - START )) -ge "$TIMEOUT" ]; then
    echo "jac harness not ready after ${TIMEOUT}s" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  sleep 3
done
echo "jac harness warm after $(( $(date +%s) - START ))s ($("$JAC" --version 2>/dev/null | head -1))"
