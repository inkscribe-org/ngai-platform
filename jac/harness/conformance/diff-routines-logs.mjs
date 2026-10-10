// Differ for the routines conformance pair: deep-compares the op logs,
// emit-frame sequences and bridge-call sequences, and byte-compares the two
// routines.json files. Nondeterministic ids (crypto.randomUUID on both
// sides) are normalized positionally: the k-th distinct UUID value seen
// across BOTH logs is rewritten to "UUID-k", so identity is compared while
// literal randomness is not.
// Usage: node diff-routines-logs.mjs <node-log> <jac-log> <node-json> <jac-json>
import { readFileSync } from "node:fs";

const [nodeLogPath, jacLogPath, nodeJsonPath, jacJsonPath] = process.argv.slice(2);
const nodeLog = JSON.parse(readFileSync(nodeLogPath, "utf8"));
const jacLog = JSON.parse(readFileSync(jacLogPath, "utf8"));

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function makeNormalizer() {
  // Per-log map: the k-th distinct UUID *within one side's streams* becomes
  // UUID-k. A shared map would shift the second log by the first log's count.
  const uuidMap = new Map();
  let uuidCounter = 0;
  function normalize(value) {
    if (typeof value === "string") {
      if (UUID_RE.test(value)) {
        if (!uuidMap.has(value)) uuidMap.set(value, `UUID-${uuidCounter++}`);
        return uuidMap.get(value);
      }
      return value;
    }
    if (Array.isArray(value)) return value.map((v) => normalize(v));
    if (value && typeof value === "object") {
      const out = {};
      for (const [k, v] of Object.entries(value)) out[k] = normalize(v);
      return out;
    }
    return value;
  }
  return normalize;
}

let failures = 0;
const fail = (msg) => { failures++; console.error(`MISMATCH ${msg}`); };

function same(a, b, path) {
  if (a === b) return true;
  if (typeof a !== typeof b) return false;
  if (a === null || b === null || a === undefined || b === undefined) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!same(a[i], b[i], `${path}[${i}]`)) return false;
    return true;
  }
  if (typeof a === "object") {
    const ka = Object.keys(a);
    const kb = Object.keys(b);
    if (ka.length !== kb.length) return false;
    for (const k of ka) {
      if (!(k in b)) return false;
      if (!same(a[k], b[k], `${path}.${k}`)) return false;
    }
    return true;
  }
  return false;
}

const normLog = (log, normalize) => ({
  log: log.log.map((entry) => normalize(entry)),
  frames: log.frames.map((f) => normalize(f)),
  bridgeCalls: log.bridgeCalls.map((c) => normalize(c)),
});

const node = normLog(nodeLog, makeNormalizer());
const jac = normLog(jacLog, makeNormalizer());

if (node.log.length !== jac.log.length) {
  fail(`op count: node ${node.log.length} vs jac ${jac.log.length}`);
}
const len = Math.min(node.log.length, jac.log.length);
for (let i = 0; i < len; i++) {
  const a = node.log[i];
  const b = jac.log[i];
  if (a.op !== b.op) { fail(`op[${i}] name: ${a.op} vs ${b.op}`); continue; }
  if (!!a.error !== !!b.error) {
    fail(`op[${i}] ${a.op}: node ${a.error ? `errored (${a.error})` : "ok"} vs jac ${b.error ? `errored (${b.error})` : "ok"}`);
    continue;
  }
  if (a.error) {
    if (a.error !== b.error) fail(`op[${i}] ${a.op} error text: "${a.error}" vs "${b.error}"`);
    continue;
  }
  if (!same(a.result, b.result, `${a.op}`)) {
    fail(`op[${i}] ${a.op} result:\n  node: ${JSON.stringify(a.result)}\n  jac:  ${JSON.stringify(b.result)}`);
  }
}
if (node.frames.length !== jac.frames.length) {
  fail(`emit frame count: node ${node.frames.length} vs jac ${jac.frames.length}`);
} else {
  for (let i = 0; i < node.frames.length; i++) {
    if (!same(node.frames[i], jac.frames[i], `frame[${i}]`)) {
      fail(`frame[${i}]:\n  node: ${JSON.stringify(node.frames[i])}\n  jac:  ${JSON.stringify(jac.frames[i])}`);
    }
  }
}
if (node.bridgeCalls.length !== jac.bridgeCalls.length) {
  fail(`bridge call count: node ${node.bridgeCalls.length} vs jac ${jac.bridgeCalls.length}`);
} else {
  for (let i = 0; i < node.bridgeCalls.length; i++) {
    if (!same(node.bridgeCalls[i], jac.bridgeCalls[i], `bridge[${i}]`)) {
      fail(`bridge[${i}]:\n  node: ${JSON.stringify(node.bridgeCalls[i])}\n  jac:  ${JSON.stringify(jac.bridgeCalls[i])}`);
    }
  }
}

const nodeJson = readFileSync(nodeJsonPath);
const jacJson = readFileSync(jacJsonPath);
// Byte parity modulo randomness: re-map each side's persisted uuids through
// that side's log-derived map (same appearance order on both sides), then
// compare canonical JSON. Key order comes from each writer, so equality here
// still proves identical structure and content.
const canon = (buf, normalize) => JSON.stringify(normalize(JSON.parse(buf.toString("utf8"))));
if (canon(nodeJson, makeNormalizer()) !== canon(jacJson, makeNormalizer())) {
  fail(`routines.json differs after uuid normalization`);
  const an = JSON.stringify(JSON.parse(nodeJson.toString("utf8")), null, 2).split("\n");
  const bj = JSON.stringify(JSON.parse(jacJson.toString("utf8")), null, 2).split("\n");
  for (let i = 0; i < Math.max(an.length, bj.length); i++) {
    if (an[i] !== bj[i]) {
      console.error(`  first line diff at ${i + 1}:\n  node: ${(an[i] ?? "<eof>").slice(0, 200)}\n  jac:  ${(bj[i] ?? "<eof>").slice(0, 200)}`);
      break;
    }
  }
}

if (failures > 0) {
  console.error(`FAILED: ${failures} mismatch(es)`);
  process.exit(1);
}
console.log("logs, frames, bridge calls and routines.json all match");
