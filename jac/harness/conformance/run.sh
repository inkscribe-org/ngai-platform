#!/usr/bin/env bash
# Conformance run: replay ops.json through node message-db and the Jac
# harness, then diff op results and sqlite dumps byte-for-byte.
#
# Usage: ./run.sh [jac-base-url]
#   Starts its own jac server unless JAC_URL is set (e.g. JAC_URL=http://localhost:18801).
set -euo pipefail
cd "$(dirname "$0")"

JAC_URL="${JAC_URL:-}"
WORK=$(mktemp -d /tmp/omb-conformance-XXXXXX)
NODE_DIR="$WORK/node-data"
JAC_DIR="$WORK/jac-data"
JAC_PID=""
mkdir -p "$NODE_DIR" "$JAC_DIR"

cleanup() {
  [ -n "$JAC_PID" ] && kill "$JAC_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "== node side =="
OMB_DATA_DIR="$NODE_DIR" node --experimental-strip-types apply-node.ts ops.json "$WORK/node-log.json"

if [ -z "$JAC_URL" ]; then
  if curl -sf -m 2 -X POST "http://localhost:18899/function/health" -d '{}' > /dev/null 2>&1; then
    echo "port 18899 already has a jac server; kill it or set JAC_URL" >&2
    exit 2
  fi
  (cd .. && exec env OMB_DATA_DIR="$JAC_DIR" jac run --no-client -p 18899) > "$WORK/jac-server.log" 2>&1 &
  JAC_PID=$!
  JAC_URL="http://localhost:18899"
  for i in $(seq 1 90); do
    curl -sf -m 2 -X POST "$JAC_URL/function/health" -H 'content-type: application/json' -d '{}' > /dev/null && break
    sleep 1
  done
fi
OMB_DATA_DIR="$JAC_DIR" node apply-jac.mjs ops.json "$WORK/jac-log.json" "$JAC_URL"

echo "== diff =="
sqlite3 "$NODE_DIR/messages.db" .dump > "$WORK/node.dump"
sqlite3 "$JAC_DIR/messages.db" .dump > "$WORK/jac.dump"
node diff-logs.mjs "$WORK/node-log.json" "$WORK/jac-log.json" "$WORK/node.dump" "$WORK/jac.dump"
echo "artifacts: $WORK"
