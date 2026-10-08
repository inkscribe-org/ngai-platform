// Structural diff of the two op logs + .dump output of the two databases.
// Usage: node diff-logs.mjs <node-log> <jac-log> <node-dump> <jac-dump>
// Exit 0 = byte-parity; non-zero prints the first N divergences.
import { readFileSync } from "node:fs";

const [nodeLogPath, jacLogPath, nodeDumpPath, jacDumpPath] = process.argv.slice(2);
let failures = 0;

// Error strings differ in prefix across runtimes (node: "Error: x", python:
// the bare message). Compare the message core.
const normError = (e) => String(e).replace(/^\w*Error:\s*/, "").replace(/^<urlopen error /, "");

const canon = (v) =>
  JSON.stringify(v, (k, x) => (typeof x === "number" && Number.isInteger(x) ? x : x));

const nodeLog = JSON.parse(readFileSync(nodeLogPath, "utf8"));
const jacLog = JSON.parse(readFileSync(jacLogPath, "utf8"));

if (nodeLog.length !== jacLog.length) {
  console.log(`LOG LENGTH MISMATCH: node=${nodeLog.length} jac=${jacLog.length}`);
  failures++;
}
for (let i = 0; i < Math.min(nodeLog.length, jacLog.length); i++) {
  const a = nodeLog[i];
  const b = jacLog[i];
  if (a.op !== b.op) {
    console.log(`op[${i}] name mismatch: ${a.op} vs ${b.op}`);
    failures++;
    continue;
  }
  // A result shaped {error: "..."} and an error field are the same thing —
  // node handlers catch into result; HTTP errors land in error.
  const aErr = a.error ?? (a.result && a.result.error);
  const bErr = b.error ?? (b.result && b.result.error);
  if (aErr || bErr) {
    if (!aErr || !bErr) {
      console.log(`op[${i}] ${a.op}: one side errored\n  node: ${aErr ?? JSON.stringify(a.result)?.slice(0, 300)}\n  jac:  ${bErr ?? JSON.stringify(b.result)?.slice(0, 300)}`);
      failures++;
    } else if (normError(aErr) !== normError(bErr)) {
      console.log(`op[${i}] ${a.op}: error text differs\n  node: ${aErr}\n  jac:  ${bErr}`);
      failures++;
    }
    continue;
  }
  const ca = canon(a.result);
  const cb = canon(b.result);
  if (ca !== cb) {
    console.log(`op[${i}] ${a.op}: result differs\n  node: ${String(ca).slice(0, 500)}\n  jac:  ${String(cb).slice(0, 500)}`);
    failures++;
  }
}

const nodeDump = readFileSync(nodeDumpPath, "utf8");
const jacDump = readFileSync(jacDumpPath, "utf8");
if (nodeDump === jacDump) {
  console.log("DB DUMP: identical");
} else {
  const a = nodeDump.split("\n");
  const b = jacDump.split("\n");
  for (let i = 0; i < Math.max(a.length, b.length) && failures < 40; i++) {
    if (a[i] !== b[i]) {
      console.log(`dump line ${i + 1}:\n  node: ${a[i]}\n  jac:  ${b[i]}`);
      failures++;
    }
  }
}
console.log(failures === 0 ? "CONFORMANCE: PASS" : `CONFORMANCE: FAIL (${failures} divergences)`);
process.exit(failures === 0 ? 0 : 1);
