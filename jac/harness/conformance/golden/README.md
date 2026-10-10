# Routines conformance golden

`routines-node-log.json.gz` and `routines-node.routines.json` are the node
side of `../run-routines.sh`: `routines-ops.json` replayed through the TS
`RoutineManager`, which phase 2 deleted. Re-record only if
`routines-ops.json` changes:

```
git worktree add /tmp/pre-port b99ecc9          # last commit with RoutineManager
git show "$(git log --format=%H -1 --grep="^phase 2: routines on Jac")":jac/harness/conformance/apply-routines-node.ts \
  > /tmp/pre-port/jac/harness/conformance/apply-routines-node.ts
cp routines-ops.json /tmp/pre-port/jac/harness/conformance/
cd /tmp/pre-port/jac/harness/conformance && mkdir -p /tmp/g/data
OMB_DATA_DIR=/tmp/g/data TZ=America/New_York \
  node --experimental-strip-types apply-routines-node.ts routines-ops.json /tmp/g/node-log.json
gzip -9 -n -c /tmp/g/node-log.json > routines-node-log.json.gz
cp /tmp/g/data/routines.json routines-node.routines.json
```
