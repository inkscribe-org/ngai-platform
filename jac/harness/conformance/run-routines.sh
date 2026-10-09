#!/usr/bin/env bash
# Routines conformance run: replay routines-ops.json through the REAL
# server/routines.ts RoutineManager and the Jac harness, then diff op
# results, emit frames, bridge-call sequences and the routines.json bytes.
#
# Both sides run under TZ=America/New_York so local-wall-time semantics are
# deterministic. The Jac harness gets OMB_ROUTINES_TEST_CLOCK=1 (set_now /
# tick / reset ops) and OMB_ROUTINES_BRIDGE_URL pointing at the stub the
# jac driver hosts.
#
# Usage: ./run-routines.sh [jac-base-url]
set -euo pipefail
cd "$(dirname "$0")"

JAC_URL="${JAC_URL:-}"
WORK=$(mktemp -d /tmp/omb-routines-conformance-XXXXXX)
NODE_DIR="$WORK/node-data"
JAC_DIR="$WORK/jac-data"
JAC_PID=""
STUB_PORT=""
cleanup() {
  [ -n "$JAC_PID" ] && kill "$JAC_PID" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$NODE_DIR" "$JAC_DIR"

if [ -z "$JAC_URL" ]; then
  JAC_PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
  if curl -sf -m 2 -X POST "http://localhost:$JAC_PORT/function/health" -d '{}' > /dev/null 2>&1; then
    echo "port $JAC_PORT unexpectedly taken" >&2
    exit 2
  fi
fi
STUB_PORT=$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')

echo "== node side =="
OMB_DATA_DIR="$NODE_DIR" TZ=America/New_York \
  node --experimental-strip-types apply-routines-node.ts routines-ops.json "$WORK/node-log.json"

echo "== jac side =="
if [ -z "$JAC_URL" ]; then
  (cd .. && exec env OMB_DATA_DIR="$JAC_DIR" OMB_JAC_TOKEN=conformance-token \
    OMB_ROUTINES_TEST_CLOCK=1 OMB_ROUTINES_BRIDGE_URL="http://127.0.0.1:$STUB_PORT" \
    TZ=America/New_York jac run --no-client -p "$JAC_PORT") > "$WORK/jac-server.log" 2>&1 &
  JAC_PID=$!
  JAC_URL="http://localhost:$JAC_PORT"
  for i in $(seq 1 600); do
    # routine_state only answers once the endpoint table is live; health
    # answers earlier and would let ops hit a compiling server.
    curl -sf -m 2 -X POST "$JAC_URL/function/routine_state" -H 'x-omb-jac-token: conformance-token' -H 'content-type: application/json' -d '{"omb_token":"conformance-token"}' > /dev/null 2>&1 && break
    # First compile of routines.jac takes minutes; fail hard if it never comes up.
    if [ "$i" = "600" ]; then
      echo "jac server did not become healthy" >&2
      tail -40 "$WORK/jac-server.log" >&2 || true
      exit 2
    fi
    sleep 1
  done
fi
OMB_DATA_DIR="$JAC_DIR" OMB_JAC_TOKEN=conformance-token TZ=America/New_York \
  node apply-routines-jac.mjs routines-ops.json "$WORK/jac-log.json" "$JAC_URL" --stub-port "$STUB_PORT"

echo "== diff =="
node diff-routines-logs.mjs "$WORK/node-log.json" "$WORK/jac-log.json" "$NODE_DIR/routines.json" "$JAC_DIR/routines.json"
echo "artifacts: $WORK"
