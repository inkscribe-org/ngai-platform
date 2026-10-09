// Differential cron probe: node nextCronRuns (croner@10 semantics via
// shared/routine-schedule.ts) vs the Jac harness's routine_next_occurrence.
// Usage:
//   node cron-probe.mjs <jac-base-url>
// (start the server yourself, or set JAC_SPAWN=1 to have this script spawn
//  a temporary `jac run --no-client`.)
// Exit 0 = every case agrees (including both sides rejecting the same
// expressions); nonzero prints each mismatch.
import { spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { nextCronRuns } from "../../../shared/routine-schedule.ts";

const [baseUrlArg] = process.argv.slice(2);
const argvUrl = process.argv.indexOf("--url");
const baseUrl = baseUrlArg ?? (argvUrl >= 0 ? process.argv[argvUrl + 1] : undefined) ?? "http://localhost:18802";
const TOKEN = process.env.OMB_JAC_TOKEN ?? "";

// ── case matrix ───────────────────────────────────────────────────────────
// [label, expression, timeZone, afterMs, count]
const T = {
  utc: "UTC",
  ny: "America/New_York",
  syd: "Australia/Sydney",
  kolkata: "Asia/Kolkata",
};
// 2026-03-08 is the US spring-forward day (02:00 → 03:00 local);
// 2026-11-01 is fall-back (02:00 → 01:00 local). Epoch refs are UTC ms.
const cases = [
  // plain stars + steps
  ["every-minute", "* * * * *", T.utc, 1789286400000, 3],
  ["step5", "*/5 * * * *", T.utc, 1789286400000, 3],
  ["step7-minutes", "*/7 * * * *", T.utc, 1789286400000, 3],
  ["range-minutes", "10-20 * * * *", T.utc, 1789286400000, 3],
  ["list-hours", "0 1,7,13 * * *", T.utc, 1789286400000, 4],
  ["range-hours", "30 9-17 * * *", T.utc, 1789286400000, 3],
  // names
  ["month-names", "0 0 1 JAN,Jul *", T.utc, 1789286400000, 2],
  ["day-names", "0 12 * * MON", T.utc, 1789286400000, 3],
  ["day-names-mixed", "30 8 * * mon,fri", T.utc, 1789286400000, 3],
  ["month-name-range", "0 0 1 JAN-MAR *", T.utc, 1789286400000, 3],
  // dom / dow combinations (croner: both restricted → OR)
  ["dom-only", "0 0 13 * *", T.utc, 1789286400000, 3],
  ["dow-only", "0 0 * * 0", T.utc, 1789286400000, 3],
  ["dom-and-dow", "0 0 13 * 1", T.utc, 1789286400000, 4],
  ["dom-or-dow-lists", "0 3 1,15 * 6", T.utc, 1789286400000, 4],
  ["sunday-7", "0 0 * * 7", T.utc, 1789286400000, 2],
  // day-of-month edge values
  ["feb-30-impossible", "0 0 30 2 *", T.utc, 1789286400000, 1],
  ["feb-29", "0 5 29 2 *", T.utc, 1789286400000, 1],
  ["day-31-short-month", "0 0 31 4 *", T.utc, 1789286400000, 1],
  ["last-day-L", "0 0 L * *", T.utc, 1789286400000, 3],
  ["last-weekday-W", "0 0 15W * *", T.utc, 1789286400000, 3],
  ["nth-weekday", "0 9 * * 1#3", T.utc, 1789286400000, 2],
  // DST: America/New_York spring-forward — 02:00 local does not exist
  ["ny-spring-gap-explicit", "0 2 8 3 *", T.ny, 1772926800000, 2],
  ["ny-spring-gap-step", "30 1-3 * * *", T.ny, 1772923200000, 6],
  ["ny-after-gap", "0 3 * * *", T.ny, 1772926800000, 2],
  ["ny-normal-daily", "0 9 * * *", T.ny, 1772926800000, 3],
  // DST: fall-back — 01:30 local occurs twice
  ["ny-fall-repeat", "30 1 1 11 *", T.ny, 1764660000000, 2],
  ["ny-fall-window", "0 1 * * *", T.ny, 1793602800000, 3],
  ["ny-quarterly", "0 12 1 1,4,7,10 *", T.ny, 1767262800000, 4],
  // Australia/Sydney: opposite-hemisphere DST (2026-04-05 back, 10-04 fwd)
  ["syd-fall-back", "0 2 5 4 *", T.syd, 1775326800000, 2],
  ["syd-spring-forward", "0 2 4 10 *", T.syd, 1791124800000, 2],
  ["syd-daily", "30 22 * * *", T.syd, 1775280000000, 3],
  // Asia/Kolkata: no DST, +05:30 offset
  ["kolkata-daily", "15 6 * * *", T.kolkata, 1789266000000, 3],
  ["kolkata-weekly", "0 20 * * FRI", T.kolkata, 1789266000000, 3],
  // seconds-free 5-field with minutes ranges crossing hours
  ["crossing-range", "55-10 * * * *", T.utc, 1789286400000, 4],
  ["stepped-range", "0 9-17/2 * * *", T.utc, 1789286400000, 3],
  ["stepped-dom", "0 0 */3 * *", T.utc, 1789286400000, 4],
  // year-boundary
  ["year-end", "59 23 31 12 *", T.utc, 1767225599000, 2],
  ["leap-day", "0 0 29 2 *", T.utc, 1767225599000, 1],
  // validation: both sides must reject identically
  ["four-fields", "0 0 * *", T.utc, 1789286400000, 1],
  ["six-fields", "0 0 0 * * *", T.utc, 1789286400000, 1],
  ["macro-string", "@daily", T.utc, 1789286400000, 1],
  ["bad-second-slot", "61 0 * * *", T.utc, 1789286400000, 1],
  ["bad-hour", "0 25 * * *", T.utc, 1789286400000, 1],
  ["bad-dom-zero", "0 0 0 * *", T.utc, 1789286400000, 1],
  ["bad-dow-eight", "0 0 * * 8", T.utc, 1789286400000, 1],
  ["bad-month-name", "0 0 1 Foo *", T.utc, 1789286400000, 1],
  ["illegal-char", "0 0 * * &", T.utc, 1789286400000, 1],
];

async function jacNext(expression, timeZone, after, count) {
  const res = await fetch(`${baseUrl}/function/routine_next_occurrence`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ omb_token: TOKEN, schedule: { type: "cron", expression, timeZone }, after, count }),
  });
  const payload = await res.json();
  const result = payload?.data?.result;
  if (result && typeof result === "object" && result.ok === false) {
    return { error: result.error };
  }
  return { runs: result?.runs ?? [] };
}

function nodeNext(expression, timeZone, after, count) {
  try {
    const runs = nextCronRuns({ type: "cron", expression, timeZone }, after, count);
    return { runs };
  } catch (e) {
    return { error: e instanceof Error ? e.message : String(e) };
  }
}

let jacChild;
async function ensureServer() {
  try {
    const probe = await fetch(`${baseUrl}/function/health`, { method: "POST", body: "{}" });
    if (probe.ok) return;
  } catch { /* not up */ }
  if (process.env.JAC_SPAWN !== "1") {
    console.error(`no jac server at ${baseUrl}; start one or set JAC_SPAWN=1`);
    process.exit(2);
  }
  const dir = mkdtempSync(join(tmpdir(), "omb-cron-probe-"));
  jacChild = spawn("jac", ["run", "--no-client", "-p", "18802"], { cwd: join(import.meta.dirname, ".."), env: { ...process.env, OMB_DATA_DIR: dir, OMB_JAC_TOKEN: TOKEN }, stdio: "ignore" });
  for (let i = 0; i < 600; i++) {
    try {
      // A real def: /function/health answers before the endpoint table is live.
      const probe = await fetch(`${baseUrl}/function/routine_state`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ omb_token: TOKEN }),
      });
      if (probe.ok) return;
    } catch { /* retry */ }
    await new Promise((r) => setTimeout(r, 1000));
  }
  console.error("spawned jac server did not become healthy");
  process.exit(2);
}

await ensureServer();
let mismatches = 0;
for (const [label, expression, timeZone, after, count] of cases) {
  const node = nodeNext(expression, timeZone, after, count);
  let jac;
  try {
    jac = await jacNext(expression, timeZone, after, count);
  } catch (e) {
    console.error(`${label}: jac request failed: ${e}`);
    mismatches++;
    continue;
  }
  if (!!node.error !== !!jac.error) {
    console.error(`${label}: node ${node.error ? `rejected ("${node.error}")` : `accepted ${JSON.stringify(node.runs)}`} vs jac ${jac.error ? `rejected ("${jac.error}")` : `accepted ${JSON.stringify(jac.runs)}`}`);
    mismatches++;
    continue;
  }
  if (node.error) continue; // both rejected
  if (node.runs.length !== jac.runs.length || node.runs.some((v, i) => v !== jac.runs[i])) {
    console.error(`${label}: node ${JSON.stringify(node.runs)} vs jac ${JSON.stringify(jac.runs)}`);
    mismatches++;
  }
}
jacChild?.kill();
if (mismatches > 0) {
  console.error(`FAILED: ${mismatches}/${cases.length} cases disagree`);
  process.exit(1);
}
console.log(`cron parity: ${cases.length}/${cases.length} cases match`);
