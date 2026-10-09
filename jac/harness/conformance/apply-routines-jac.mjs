// Conformance driver: replays routines-ops.json against the Jac routines
// harness via POST /function/routine_*, with the Jac→node bridge answered
// by an in-process stub server whose scripted state is driven by the same
// control ops the node driver honors (setBotState / setGoalState / ...).
// Usage:
//   node apply-routines-jac.mjs <ops.json> <out-log> [jac-base-url] [--stub-port N]
// Env: OMB_JAC_TOKEN must match the harness's token; OMB_DATA_DIR must be
// the harness's data dir. Run under TZ=America/New_York (pinned by
// run-routines.sh) so local-wall-time semantics match the node driver.
// Errors: an op envelope {ok:false,status,error} is rethrown as Error(error)
// so the log's error strings match the node driver's String(throwable).
import { createServer } from "node:http";
import { readFileSync, writeFileSync } from "node:fs";

const argv = process.argv.slice(2);
const stubPortArg = argv.indexOf("--stub-port");
const stubPort = stubPortArg >= 0 ? Number(argv[stubPortArg + 1]) : undefined;
if (stubPortArg >= 0) argv.splice(stubPortArg, 2);
const [opsPath, logPath, baseUrl = "http://localhost:18801"] = argv;

const { ops } = JSON.parse(readFileSync(opsPath, "utf8"));
const TOKEN = process.env.OMB_JAC_TOKEN ?? "";

// --- scripted bridge stub (mirrors apply-routines-node.ts callbacks) -------
const botStates = {};
const goalStates = {};
const pending = {};
let startTurnError = null;
let startGoalError = null;
let joinEnabled = false;
let isResultsFlag = false;
let taskN = 0;
let goalTaskN = 0;

const bridgeCalls = [];
let stubServer = null;
let stubUrl = null;

function startStub() {
  return new Promise((resolve, reject) => {
    stubServer = createServer((req, res) => {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        let call = {};
        try { call = JSON.parse(body || "{}"); } catch { call = {}; }
        const op = String(call.op ?? "");
        const record = {};
        for (const [k, v] of Object.entries(call)) record[k] = v === undefined ? null : v;
        bridgeCalls.push(record);
        const reply = stubReply(op, call);
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify(reply));
      });
    });
    stubServer.on("error", reject);
    // Two listens when --stub-port is given: retry-free binding is the
    // runner's job (it allocated the port moments earlier).
    stubServer.listen(stubPort ?? 0, "127.0.0.1", () => {
      stubUrl = `http://127.0.0.1:${stubServer.address().port}`;
      resolve(stubUrl);
    });
  });
}

function stubReply(op, call) {
  switch (op) {
    case "bot_state": return { state: botStates[call.bot_id] ?? "ready", exists: (botStates[call.bot_id] ?? "ready") !== "missing", busy: (botStates[call.bot_id] ?? "ready") === "busy" };
    case "goal_state": return { state: goalStates[call.group_id] ?? "ready", exists: (goalStates[call.group_id] ?? "ready") !== "missing", busy: (goalStates[call.group_id] ?? "ready") === "busy" };
    case "create_task": return { thread_id: `thread-${++taskN}` };
    case "join_conversation": return { thread_id: joinEnabled ? `thread-${++taskN}` : null };
    case "create_goal_task": return { thread_id: `goal-thread-${++goalTaskN}` };
    case "is_results_thread": return { ok: isResultsFlag };
    case "resolve_results_thread": return { thread_id: null };
    case "discard_results_thread": return { ok: true };
    case "start_turn": return startTurnError !== null ? { ok: false, error: startTurnError } : { ok: true };
    case "start_goal": return startGoalError !== null ? { ok: false, error: startGoalError } : { ok: true };
    case "interrupt_turn": return { ok: true };
    case "interrupt_goal": return { ok: true };
    case "run_changed": return { ok: true };
    case "run_failed": return { ok: true };
    case "run_deferred": return { ok: true };
    case "has_pending_delegations": return { pending: pending[call.thread_id] === true };
    case "emit": return { ok: true };
    default: return { ok: true };
  }
}

// --- op transport -----------------------------------------------------------
const endpointFor = (name) => `routine_${name.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase())}`;

async function jacOp(name, args) {
  const body = { omb_token: TOKEN, ...args };
  const res = await fetch(`${baseUrl}/function/${name}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`http ${res.status} from ${name}`);
  const payload = await res.json();
  const result = payload?.data?.result;
  if (result && typeof result === "object" && result.ok === false) {
    throw new Error(result.error ?? "unknown error");
  }
  return result;
}

// --- $ref resolution (identical semantics to the node driver) ---------------
const captures = {};
function resolve(value) {
  if (typeof value === "string") {
    if (value.startsWith("$ref:")) {
      let cur = captures;
      for (const part of value.slice(5).split(".")) {
        if (cur === null || cur === undefined) throw new Error(`$ref path "${value}" dead at "${part}"`);
        cur = cur[part];
      }
      return cur;
    }
    return value;
  }
  if (Array.isArray(value)) return value.map(resolve);
  if (value && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = resolve(v);
    return out;
  }
  return value;
}

const controls = { now: 0 };
const num = (op, key) => (op[key] === undefined ? undefined : op[key]);
const str = (op, key) => op[key];
const opt = (v) => (v === undefined ? null : v);

// op -> kwargs mapper. `unwrap` pulls the bare value the node driver's
// handler returns for the same corpus op (jac ops wrap some returns).
const opMap = {
  setNow: { ep: "routine_set_now", args: (op) => ({ now: op.now }) },
  tick: { ep: "routine_tick", args: () => ({}) },
  listRoutines: { ep: "routine_list", args: () => ({}) },
  packageStamps: { ep: "routine_package_stamps", args: () => ({}) },
  stampInstalledPackage: { ep: "routine_stamp_installed_package", args: (op) => ({ id: str(op, "id"), stamp: opt(op.stamp) }), unwrap: (r) => r.stamped },
  listRuns: { ep: "routine_list_runs", args: (op) => ({ from_: opt(num(op, "from")), to_: opt(num(op, "to")) }) },
  wakeHold: { ep: "routine_wake_hold", args: (op) => ({ horizon_ms: opt(num(op, "horizonMs")) }) },
  activeRunForBot: { ep: "routine_active_run_for_bot", args: (op) => ({ bot_id: str(op, "botId") }) },
  activeBotRunForBot: { ep: "routine_active_bot_run_for_bot", args: (op) => ({ bot_id: str(op, "botId") }) },
  isActiveThread: { ep: "routine_is_active_thread", args: (op) => ({ thread_id: str(op, "threadId") }) },
  runForThread: { ep: "routine_run_for_thread", args: (op) => ({ thread_id: str(op, "threadId") }) },
  create: { ep: "routine_create", args: (op) => ({ input: op.input, req: opt(op.request) }) },
  update: { ep: "routine_update", args: (op) => ({ id: str(op, "id"), patch: op.patch, req: opt(op.request) }) },
  remove: { ep: "routine_remove", args: (op) => ({ id: str(op, "id"), req: opt(op.request) }) },
  runNow: { ep: "routine_run_now", args: (op) => ({ id: str(op, "id"), req: opt(op.request) }), unwrap: (r) => r.run },
  cancelRun: { ep: "routine_cancel_run", args: (op) => ({ id: str(op, "id") }), unwrap: (r) => r.run },
  markSeen: { ep: "routine_mark_seen", args: (op) => ({ id: str(op, "id") }) },
  markAllSeen: { ep: "routine_mark_all_seen", args: () => ({}) },
  disableForBot: { ep: "routine_disable_for_bot", args: (op) => ({ bot_id: str(op, "botId") }) },
  disableForGroup: { ep: "routine_disable_for_group", args: (op) => ({ group_id: str(op, "groupId") }) },
  enqueueWebhook: { ep: "routine_enqueue_webhook", args: (op) => ({ input: op.input }) },
  webhookRunReceipt: { ep: "routine_webhook_run_receipt", args: (op) => ({ webhook_id: str(op, "webhookId"), delivery_id: str(op, "deliveryId") }) },
  activeWebhookRunCount: { ep: "routine_active_webhook_run_count", args: (op) => ({ webhook_id: str(op, "webhookId") }) },
  cancelQueuedWebhook: { ep: "routine_cancel_queued_webhook", args: (op) => ({ webhook_id: str(op, "webhookId"), message: opt(op.message) ?? "" }) },
  runtimeEvent: { ep: "routine_runtime_event", args: (op) => ({ event: op.event }) },
  failThread: { ep: "routine_fail_thread", args: (op) => ({ thread_id: str(op, "threadId"), message: opt(op.message) ?? "" }) },
  finishGoalRun: { ep: "routine_finish_goal_run", args: (op) => ({ run_id: str(op, "runId"), status: str(op, "status"), detail: opt(op.detail) ?? "" }) },
  receipt: { ep: "routine_receipt", args: (op) => ({ request_id: str(op, "requestId") }) },
  receiptOwners: { ep: "routine_receipt_owners", args: () => ({}) },
  forgetReceipt: { ep: "routine_forget_receipt", args: (op) => ({ req: op.request }) },
  forgetReceiptsForThread: { ep: "routine_forget_receipts_for_thread", args: (op) => ({ thread_id: str(op, "threadId") }) },
  reconcileReceipts: { ep: "routine_reconcile_receipts", args: (op) => ({ reachable: op.reachable ?? [] }) },
  nextOccurrence: {
    ep: "routine_next_occurrence",
    args: (op) => ({ schedule: op.schedule, after: opt(num(op, "after") ?? controls.now), count: opt(num(op, "count") ?? 1) }),
  },
};

async function handle(op) {
  if (op.op === "boot") {
    // The node driver re-constructs its manager over the same file; the
    // harness equivalent is reset + boot (both no-ops without the test
    // clock env, which run-routines.sh always sets).
    await jacOp("routine_reset", {});
    return jacOp("routine_boot", {});
  }
  const control = {
    setBotState: () => { botStates[op.botId] = op.state; return true; },
    setGoalState: () => { goalStates[op.groupId] = op.state; return true; },
    setPending: () => { pending[op.threadId] = op.pending === true; return true; },
    setStartTurnError: () => { startTurnError = op.error ?? null; return true; },
    setStartGoalError: () => { startGoalError = op.error ?? null; return true; },
    setJoin: () => { joinEnabled = op.enabled === true; return true; },
    setIsResultsThread: () => { isResultsFlag = op.ok === true; return true; },
  }[op.op];
  if (control) return control();
  const spec = opMap[op.op];
  if (!spec) throw new Error("no handler");
  const result = await jacOp(spec.ep, spec.args(op));
  return spec.unwrap ? spec.unwrap(result) : result;
}

await startStub();
if (stubPort !== undefined && !stubUrl.endsWith(`:${stubPort}`)) {
  console.error(`stub bound to ${stubUrl}, runner expected :${stubPort}`);
  process.exit(2);
}
if (process.env.OMB_PRINT_STUB_URL === "1") console.log(`stub ${stubUrl}`);

const log = [];
for (const raw of ops) {
  let op;
  try {
    op = resolve(raw);
  } catch (e) {
    log.push({ op: raw.op, error: String(e) });
    continue;
  }
  if (op.op === "setNow") controls.now = op.now;
  try {
    const result = await handle(op);
    if (op.as) captures[op.as] = result;
    log.push({ op: op.op, result });
  } catch (e) {
    log.push({ op: op.op, error: String(e) });
  }
}

stubServer?.close();
writeFileSync(
  logPath,
  JSON.stringify({ log, frames: bridgeCalls.filter((c) => c.op === "emit").map((c) => c.payload), bridgeCalls }, null, 2),
);
console.log(`applied ${ops.length} ops`);
