// Conformance driver: replays routines-ops.json against the REAL
// server/routines.ts RoutineManager.
// Usage: OMB_DATA_DIR=<dir> node --experimental-strip-types apply-routines-node.ts <ops.json> <out-log>
// Writes {log, frames, bridgeCalls}: per-op results, emit frames (derived
// from bridgeCalls), and every scripted bridge callback as the same
// snake_case `{op, ...payload}` shape the Jac harness posts to the bridge.
// Time is fully scripted: setNow ops move `now`; async work (runNow /
// cancelRun / runtimeEvent / tick queue microtask ticks) is drained via
// settle() so op boundaries are deterministic. Run under TZ=America/New_York.
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  RoutineManager,
  nextOccurrence,
  type Routine,
  type RoutineRun,
  type RoutineSchedule,
} from "../../../server/routines.ts";
import { nextCronRuns } from "../../../shared/routine-schedule.ts";

interface Op {
  op: string;
  as?: string;
  [key: string]: unknown;
}
interface LogEntry {
  op: string;
  result?: unknown;
  error?: string;
}

const [opsPath, logPath] = process.argv.slice(2);
const { ops } = JSON.parse(readFileSync(opsPath, "utf8")) as { ops: Op[] };
const DATA_DIR = process.env.OMB_DATA_DIR!;
const file = join(DATA_DIR, "routines.json");

// --- scripted bridge state (mirrors bridge-stub.mjs) -----------------------
const botStates: Record<string, string> = {};
const goalStates: Record<string, string> = {};
const pending: Record<string, boolean> = {};
let startTurnError: string | null = null;
let startGoalError: string | null = null;
let joinEnabled = false;
let isResultsFlag = false;
let taskN = 0;
let goalTaskN = 0;

const bridgeCalls: Array<Record<string, unknown>> = [];
const record = (op: string, payload: Record<string, unknown>) => {
  const call: Record<string, unknown> = { op };
  for (const [k, v] of Object.entries(payload)) call[k] = v === undefined ? null : v;
  bridgeCalls.push(call);
};
const clone = <T,>(v: T): T => structuredClone(v);

const options = {
  file,
  now: () => controls.now,
  emit: (payload: Record<string, unknown>) => record("emit", { payload }),
  botState: (botId: string) => {
    record("bot_state", { bot_id: botId });
    return (botStates[botId] ?? "ready") as "ready" | "busy" | "missing";
  },
  goalState: (groupId: string, coordinatorBotId: string) => {
    record("goal_state", { group_id: groupId, coordinator_bot_id: coordinatorBotId });
    return (goalStates[groupId] ?? "ready") as "ready" | "busy" | "missing";
  },
  createTask: (botId: string, title: string, activate: boolean | undefined, run: RoutineRun | undefined) => {
    record("create_task", { bot_id: botId, title, activate: activate ?? false, run: clone(run) });
    return { threadId: `thread-${++taskN}` };
  },
  joinConversation: (run: RoutineRun) => {
    record("join_conversation", { run: clone(run) });
    return joinEnabled ? `thread-${++taskN}` : null;
  },
  createGoalTask: (groupId: string, title: string) => {
    record("create_goal_task", { group_id: groupId, title });
    return { threadId: `goal-thread-${++goalTaskN}` };
  },
  isResultsThread: (botId: string, threadId: string) => {
    record("is_results_thread", { bot_id: botId, thread_id: threadId });
    return isResultsFlag;
  },
  resolveResultsThread: (routine: Routine, forceNew: boolean) => {
    record("resolve_results_thread", { routine: clone(routine), force_new: forceNew });
    return undefined;
  },
  discardResultsThread: (botId: string, threadId: string) => {
    record("discard_results_thread", { bot_id: botId, thread_id: threadId });
  },
  startTurn: async (
    botId: string,
    threadId: string,
    prompt: string,
    runOn: string,
    triggerSource: string,
    onDispatchError: (message: string) => void,
  ) => {
    record("start_turn", { bot_id: botId, thread_id: threadId, prompt, run_on: runOn, trigger_source: triggerSource });
    if (startTurnError !== null) onDispatchError(startTurnError);
  },
  startGoal: async (
    groupId: string,
    threadId: string,
    prompt: string,
    coordinatorBotId: string,
    runId: string,
    onDispatchError: (message: string) => void,
  ) => {
    record("start_goal", { group_id: groupId, thread_id: threadId, prompt, coordinator_bot_id: coordinatorBotId, run_id: runId });
    if (startGoalError !== null) onDispatchError(startGoalError);
  },
  interruptTurn: async (botId: string, threadId: string) => {
    record("interrupt_turn", { bot_id: botId, thread_id: threadId });
  },
  interruptGoal: async (groupId: string, threadId: string, outcome?: { status: string; detail: string }) => {
    const payload: Record<string, unknown> = { group_id: groupId, thread_id: threadId };
    if (outcome) payload.outcome = outcome;
    record("interrupt_goal", payload);
  },
  onRunChanged: (run: RoutineRun) => record("run_changed", { run: clone(run) }),
  onRunFailed: (run: RoutineRun) => record("run_failed", { run: clone(run) }),
  onRunDeferred: (run: RoutineRun) => record("run_deferred", { run: clone(run) }),
  hasPendingDelegations: (threadId: string) => {
    record("has_pending_delegations", { thread_id: threadId });
    return pending[threadId] === true;
  },
};

const controls = { now: 0 };
let manager = new RoutineManager(options as ConstructorParameters<typeof RoutineManager>[0]);

// runNow/cancelRun/handleRuntimeEvent/failThread/finishGoalRun enqueue
// microtask ticks; drain them so the next op starts from a quiescent state.
async function settle() {
  const yieldToLoop = () => {
    const { promise, resolve } = Promise.withResolvers<void>();
    setImmediate(resolve);
    return promise;
  };
  for (let i = 0; i < 25; i++) {
    await yieldToLoop();
    let guard = 0;
    while (manager.isTicking && guard++ < 100000) await yieldToLoop();
  }
}

// --- $ref resolution -------------------------------------------------------
const captures: Record<string, unknown> = {};
function resolve(value: unknown): unknown {
  if (typeof value === "string") {
    if (value.startsWith("$ref:")) {
      let cur: unknown = captures;
      for (const part of value.slice(5).split(".")) {
        if (cur === null || cur === undefined) throw new Error(`$ref path "${value}" dead at "${part}"`);
        cur = (cur as Record<string, unknown>)[part];
      }
      return cur;
    }
    return value;
  }
  if (Array.isArray(value)) return value.map(resolve);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) out[k] = resolve(v);
    return out;
  }
  return value;
}

// nextOccurrence corpus ops mirror the jac op: cron goes straight to
// nextCronRuns (validation inside), everything else cleans first, then
// iterates the single-step nextOccurrence.
const probeFile = join(mkdtempSync(join(tmpdir(), "omb-routines-probe-")), "probe.json");
function cleanSchedule(input: unknown, at: number): RoutineSchedule {
  const probe = new RoutineManager({
    file: probeFile,
    now: () => at,
    botState: () => "ready",
    createTask: () => ({ threadId: "probe" }),
  } as ConstructorParameters<typeof RoutineManager>[0]);
  const routine = probe.create({
    name: "probe",
    prompt: "probe",
    botId: "probe",
    schedule: input as RoutineSchedule,
  });
  return routine.schedule;
}

const num = (op: Op, key: string): number | undefined => (op[key] === undefined ? undefined : (op[key] as number));
const str = (op: Op, key: string): string => op[key] as string;

const handlers: Record<string, (op: Op) => unknown | Promise<unknown>> = {
  boot: () => {
    manager = new RoutineManager(options as ConstructorParameters<typeof RoutineManager>[0]);
    return { ok: true };
  },
  setNow: (op) => {
    controls.now = op.now as number;
    return { ok: true };
  },
  tick: async () => {
    await manager.tick();
    return { ok: true };
  },
  listRoutines: () => ({ routines: manager.listRoutines() }),
  packageStamps: () => ({ stamps: manager.packageStamps() }),
  stampInstalledPackage: (op) => manager.stampInstalledPackage(str(op, "id"), op.stamp as never),
  listRuns: (op) => ({
    runs: manager.listRuns(num(op, "from"), num(op, "to")),
  }),
  wakeHold: (op) => manager.wakeHold(num(op, "horizonMs")),
  activeRunForBot: (op) => ({ run: manager.activeRunForBot(str(op, "botId")) }),
  activeBotRunForBot: (op) => ({ run: manager.activeBotRunForBot(str(op, "botId")) }),
  isActiveThread: (op) => ({ active: manager.isActiveThread(str(op, "threadId")) }),
  runForThread: (op) => ({ run: manager.runForThread(str(op, "threadId")) }),
  create: (op) => ({ routine: manager.create(op.input as never, op.request as never) }),
  update: (op) => ({ routine: manager.update(str(op, "id"), op.patch as never, op.request as never) }),
  remove: (op) => ({ removed: manager.remove(str(op, "id"), op.request as never) }),
  runNow: (op) => manager.runNow(str(op, "id"), op.request as never),
  cancelRun: (op) => manager.cancelRun(str(op, "id")),
  markSeen: (op) => ({ run: manager.markSeen(str(op, "id")) }),
  markAllSeen: () => ({ runs: manager.markAllSeen() }),
  disableForBot: (op) => {
    manager.disableForBot(str(op, "botId"));
    return { ok: true };
  },
  disableForGroup: (op) => {
    manager.disableForGroup(str(op, "groupId"));
    return { ok: true };
  },
  enqueueWebhook: (op) => manager.enqueueWebhook(op.input as never),
  webhookRunReceipt: (op) => ({
    run: manager.webhookRunReceipt(str(op, "webhookId"), str(op, "deliveryId")),
  }),
  activeWebhookRunCount: (op) => ({ count: manager.activeWebhookRunCount(str(op, "webhookId")) }),
  cancelQueuedWebhook: (op) => {
    manager.cancelQueuedWebhook(str(op, "webhookId"), (op.message as string) ?? "");
    return { ok: true };
  },
  runtimeEvent: async (op) => ({ run: await manager.handleRuntimeEvent(op.event as never) }),
  failThread: (op) => {
    manager.failThread(str(op, "threadId"), (op.message as string) ?? "");
    return { ok: true };
  },
  finishGoalRun: (op) => ({
    run: manager.finishGoalRun(str(op, "runId"), op.status as never, (op.detail as string) ?? ""),
  }),
  receipt: (op) => ({ receipt: manager.routineRequestReceipt(str(op, "requestId")) }),
  receiptOwners: () => ({ owners: manager.routineRequestReceiptOwners() }),
  forgetReceipt: (op) => ({ removed: manager.forgetRoutineRequestReceipt(op.request as never) }),
  forgetReceiptsForThread: (op) => ({
    removed: manager.forgetRoutineRequestReceiptsForThread(str(op, "threadId")),
  }),
  reconcileReceipts: (op) => ({
    removed: manager.reconcileRoutineRequestReceipts(op.reachable as never),
  }),
  nextOccurrence: (op) => {
    const schedule = op.schedule as { type?: string };
    const after = (op.after as number) ?? controls.now;
    const count = (op.count as number) ?? 1;
    if (schedule?.type === "cron") {
      return { runs: nextCronRuns(schedule as never, after, count) };
    }
    const clean = cleanSchedule(schedule, after);
    if (clean.type === "cron") return { runs: nextCronRuns(clean as never, after, count) };
    const runs: number[] = [];
    let cursor = after;
    for (let i = 0; i < count && i < 1000; i++) {
      const next = nextOccurrence(clean, cursor);
      if (next === null) break;
      runs.push(next);
      cursor = next;
    }
    return { runs };
  },

  // control ops — driver + bridge stub only, never part of either impl
  setBotState: (op) => {
    botStates[str(op, "botId")] = str(op, "state");
    return true;
  },
  setGoalState: (op) => {
    goalStates[str(op, "groupId")] = str(op, "state");
    return true;
  },
  setPending: (op) => {
    pending[str(op, "threadId")] = op.pending === true;
    return true;
  },
  setStartTurnError: (op) => {
    startTurnError = (op.error as string | null) ?? null;
    return true;
  },
  setStartGoalError: (op) => {
    startGoalError = (op.error as string | null) ?? null;
    return true;
  },
  setJoin: (op) => {
    joinEnabled = op.enabled === true;
    return true;
  },
  setIsResultsThread: (op) => {
    isResultsFlag = op.ok === true;
    return true;
  },
};

const log: LogEntry[] = [];
for (const raw of ops) {
  let op: Op;
  try {
    op = resolve(raw) as Op;
  } catch (e) {
    log.push({ op: raw.op, error: String(e) });
    continue;
  }
  const handler = handlers[op.op];
  if (!handler) {
    log.push({ op: op.op, error: "no handler" });
    continue;
  }
  try {
    const result = await handler(op);
    await settle();
    if (op.as) captures[op.as] = result;
    log.push({ op: op.op, result });
  } catch (e) {
    await settle();
    log.push({ op: op.op, error: String(e) });
  }
}

writeFileSync(
  logPath,
  JSON.stringify({ log, frames: bridgeCalls.filter((c) => c.op === "emit").map((c) => c.payload), bridgeCalls }, null, 2),
);
console.log(`applied ${ops.length} ops`);
