// Node-side seam for the Jac routines harness (phase 2 of the Jac
// migration). The scheduler, run-state machine and routines.json now live
// in jac/harness/routines.jac, served by `jac run --no-client` on loopback.
// This module owns: the harness process (spawn/health/supervision), the
// POST /function/<op> client with its shared-secret token, a serialized op
// queue preserving the old in-process RoutineManager's call ordering, a
// synchronous read mirror kept fresh by emit frames (for call sites that
// cannot await — visibility and lending predicates — and for Jac→node
// bridge handlers, which must never make a node→Jac request: a bridge op
// that awaited an op would deadlock behind the op that is awaiting it),
// and the async facade every other node call site uses.

import { spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync } from "node:fs";
import { createServer, request as httpRequest } from "node:http";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { DATA_DIR } from "./config.ts";
import { resolveJacBinary } from "./jac-binary.ts";
import type {
  Routine,
  RoutineRun,
  RoutineInput,
  RoutinePackageStamp,
  RoutineRequestCommit,
  RoutineRequestReceipt,
  RoutineRequestOwner,
} from "./routines.ts";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
const HARNESS_DIR = join(REPO_ROOT, "jac", "harness");
const HEALTH_TIMEOUT_MS = 300_000;
const OP_TIMEOUT_MS = 30_000;
const ACTIVE_RUN_STATUSES: readonly string[] = ["running", "waiting"];

export function jacEnabled(): boolean {
  return process.env.OMB_JAC !== "0";
}

/** Shared secret for both directions: node→Jac ops send it as the
 * `omb_token` kwarg, Jac→node bridge calls send it as the
 * `x-omb-jac-token` header. An explicit OMB_JAC_TOKEN wins so external
 * harnesses (conformance drivers) can match; otherwise one is minted here
 * and exported to the spawned child. */
let jacToken: string | null = null;
export function jacBridgeToken(): string {
  jacToken ??= process.env.OMB_JAC_TOKEN?.trim() || randomBytes(32).toString("hex");
  return jacToken;
}

/**
 * Stable tmpdir for the jac child's embedded-Postgres socket dir. Fixtures
 * redirect HOME into the dataDir, so anchor to XDG_CACHE_HOME (the fixture
 * forwards the operator's real cache) or the real HOME.
 */
function jacSharedTmpdir(): string {
  const root = process.env.XDG_CACHE_HOME
    || join(process.env.HOME || homedir(), ".cache");
  const dir = join(root, "jac", "tmp");
  try {
    mkdirSync(dir, { recursive: true });
  } catch { /* fall through */ }
  return dir;
}

// (the server tsconfig targets ES2023, before Promise.withResolvers landed)
function freeLoopbackPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address();
      const port = address && typeof address === "object" ? address.port : 0;
      probe.close(() => (port ? resolve(port) : reject(new Error("no ephemeral port"))));
    });
  });
}

// ── harness lifecycle ────────────────────────────────────────────────────

let jacUrl: string | null = process.env.OMB_JAC_URL?.trim().replace(/\/+$/, "") || null;
let jacChild: ChildProcess | null = null;
let spawnAttempt: Promise<string | null> | null = null;
let respawnTimer: ReturnType<typeof setTimeout> | undefined;
let respawnDelayMs = 1_000;
let unavailableLogged = false;
let unavailableReason: string | null = null;
let shuttingDown = false;

export function jacUnavailable(): boolean {
  return !jacEnabled() || jacUrl === null;
}

export function jacUnavailableReason(): string | null {
  if (!jacEnabled()) return "routines unavailable (OMB_JAC=0)";
  return jacUrl === null ? (unavailableReason ?? "routines unavailable") : null;
}

/** The HTTP-ish status a facade error carries (`{status}`), for callers
 * mapping jac failures onto response codes. */
function statusOf(error: unknown): number | undefined {
  return error !== null && typeof error === "object" && "status" in error && typeof error.status === "number"
    ? error.status
    : undefined;
}

function logUnavailableOnce(reason: string): void {
  unavailableReason = reason;
  if (unavailableLogged) return;
  unavailableLogged = true;
  console.error(`routines: ${reason} — routine routes will answer 503`);
}

/** Children whose spawn itself failed (bad binary path): no exit event ever
 * fires, so health polling must check this instead of exitCode alone. */
const spawnFailed = new WeakSet<ChildProcess>();

async function waitForHealth(url: string, child: ChildProcess): Promise<boolean> {
  const deadline = Date.now() + HEALTH_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (child.exitCode !== null || spawnFailed.has(child)) return false;
    try {
      // /function/health answers before the harness finishes compiling its
      // endpoint table; a real def is only routed once the app is live.
      const response = await fetch(`${url}/function/routine_state`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ omb_token: jacBridgeToken() }),
        signal: AbortSignal.timeout(2_000),
      });
      if (response.ok) return true;
    } catch { /* not up yet */ }
    await new Promise<void>((resolve) => setTimeout(resolve, 250));
  }
  return false;
}

async function spawnHarness(): Promise<string | null> {
  const bin = resolveJacBinary();
  if (!bin) {
    logUnavailableOnce("no jac binary found (set OMB_JAC_BIN or install jacup)");
    return null;
  }
  let port: number;
  try {
    port = Number(process.env.OMB_JAC_PORT) || (await freeLoopbackPort());
  } catch (error) {
    logUnavailableOnce(`could not reserve a loopback port: ${(error as Error).message}`);
    return null;
  }
  const url = `http://127.0.0.1:${port}`;
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    OMB_DATA_DIR: DATA_DIR,
    OMB_JAC_TOKEN: jacBridgeToken(),
    OMB_NODE_URL: `http://127.0.0.1:${Number(process.env.OMB_PORT || process.env.OGB_PORT || 8799)}`,
    // Jac's embedded Postgres daemon is shared machine-wide and outlives
    // this child; it listens under <TMPDIR>/jacpg-<digest>. If TMPDIR points
    // into a fixture dataDir deleted at teardown, the daemon is orphaned and
    // every later boot blocks 60s then fails (ENOENT). Give jac a stable
    // tmpdir so the socket directory survives restarts.
    TMPDIR: jacSharedTmpdir(),
  };
  if (process.env.OMB_ROUTINES_TEST_CLOCK) env.OMB_ROUTINES_TEST_CLOCK = process.env.OMB_ROUTINES_TEST_CLOCK;
  const child = spawn(bin, ["run", "--no-client", "-p", String(port)], {
    cwd: HARNESS_DIR,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  jacChild = child;
  let output = "";
  // A bad binary path is an 'error' event, not a throw: unhandled, it would
  // take the whole node process down.
  child.once("error", (error) => {
    spawnFailed.add(child);
    output = `${output}${error.message}\n`.slice(-4_000);
    if (jacChild === child) jacChild = null;
  });
  child.stdout?.on("data", (chunk) => { output = `${output}${chunk}`.slice(-4_000); });
  child.stderr?.on("data", (chunk) => {
    output = `${output}${chunk}`.slice(-4_000);
    for (const line of String(chunk).split("\n")) {
      if (line.trim()) console.error(`[jac] ${line}`);
    }
  });
  child.once("exit", (code, signal) => {
    if (jacChild === child) {
      jacChild = null;
      if (jacUrl === url) jacUrl = null;
    }
    if (shuttingDown || !jacEnabled()) return;
    // A replacement harness reloads routines.json itself, but the
    // node-visible mirror and the boot hook (interrupted-run recovery)
    // belong to this side: both must re-run once the child answers.
    booted = null;
    console.error(`routines: jac harness exited (code ${code ?? signal}); restarting in ${respawnDelayMs}ms`);
    respawnTimer = setTimeout(() => {
      respawnTimer = undefined;
      spawnAttempt = null;
      void ensureJacHarness().then((up) => { if (up) void startJacRoutines(); });
    }, respawnDelayMs);
    respawnTimer.unref?.();
    respawnDelayMs = Math.min(respawnDelayMs * 2, 30_000);
  });
  if (await waitForHealth(url, child)) {
    jacUrl = url;
    respawnDelayMs = 1_000;
    unavailableReason = null;
    return url;
  }
  try { child.kill("SIGTERM"); } catch { /* already gone */ }
  logUnavailableOnce(`jac harness did not become ready${output ? `: ${output.trim().split("\n").pop()}` : ""}`);
  return null;
}

/** Resolve the Jac harness base URL: OMB_JAC_URL verbatim, else a spawned
 * (and thereafter supervised) `jac run` in jac/harness. null means the
 * routines subsystem is unavailable — callers must surface 503. */
export function ensureJacHarness(): Promise<string | null> {
  if (!jacEnabled()) return Promise.resolve(null);
  if (jacUrl) return Promise.resolve(jacUrl);
  spawnAttempt ??= spawnHarness().finally(() => { spawnAttempt = null; });
  return spawnAttempt;
}

/** Graceful shutdown hook: stop supervising and terminate the child. An
 * externally managed OMB_JAC_URL harness is left alone. */
export function stopJacHarness(): void {
  shuttingDown = true;
  clearTimeout(respawnTimer);
  respawnTimer = undefined;
  try { jacChild?.kill("SIGTERM"); } catch { /* already gone */ }
  jacChild = null;
}

// ── op transport ─────────────────────────────────────────────────────────

interface JacFailureEnvelope {
  ok: false;
  status?: number;
  error?: string;
  /** a machine-readable reason some subsystems add (mcp_oauth: "not-oauth"…) */
  code?: string;
}

/** A Jac op answers 200 with `{ok:false,status,error[,code]}` on failure;
 * surface that as a thrown error carrying the status (and code). */
function unwrapJacResult(result: unknown, fallback: string): unknown {
  if (result && typeof result === "object" && "ok" in result && result.ok === false) {
    const failed = result as JacFailureEnvelope;
    throw Object.assign(
      new Error(failed.error ?? fallback),
      { status: failed.status ?? 500, ...(typeof failed.code === "string" ? { code: failed.code } : {}) },
    );
  }
  return result;
}

async function jacOpRaw(name: string, args: Record<string, unknown>, timeoutMs = OP_TIMEOUT_MS): Promise<unknown> {
  const url = jacUrl ?? (await ensureJacHarness());
  if (!url) throw Object.assign(new Error("routines unavailable"), { status: 503 });
  let response: Response;
  try {
    response = await fetch(`${url}/function/${name}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ omb_token: jacBridgeToken(), ...args }),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (error) {
    throw Object.assign(
      new Error(`routines unavailable: ${error instanceof Error ? error.message : String(error)}`),
      { status: 503 },
    );
  }
  let result: unknown;
  try {
    const body = await response.json() as { data?: { result?: unknown }; error?: string };
    if (!response.ok) {
      throw Object.assign(new Error(body.error ?? `jac harness answered ${response.status}`), { status: response.status });
    }
    result = body.data?.result;
  } catch (error) {
    if (statusOf(error) !== undefined) throw error;
    throw Object.assign(new Error("jac harness returned a malformed response"), { status: 503 });
  }
  return unwrapJacResult(result, "routine operation failed");
}

/** Long operations (workspace backup snapshot/stage/restore, team backup
 * import) can run for minutes: fetch's undici dispatcher would abort them at
 * its 300 s headers timeout, so they go over node:http with no socket
 * timeout. Same envelope and failure mapping as jacOpRaw. */
async function jacLongOpRaw(name: string, args: Record<string, unknown>): Promise<unknown> {
  const url = jacUrl ?? (await ensureJacHarness());
  if (!url) throw Object.assign(new Error("routines unavailable"), { status: 503 });
  const payload = Buffer.from(JSON.stringify({ omb_token: jacBridgeToken(), ...args }));
  const { status, text } = await new Promise<{ status: number; text: string }>((resolve, reject) => {
    const req = httpRequest(`${url}/function/${name}`, {
      method: "POST",
      headers: { "content-type": "application/json", "content-length": payload.length },
    }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (chunk: Buffer) => chunks.push(chunk));
      res.once("end", () => resolve({ status: res.statusCode ?? 0, text: Buffer.concat(chunks).toString("utf8") }));
      res.once("error", reject);
    });
    req.once("error", (error) => reject(Object.assign(
      new Error(`routines unavailable: ${error.message}`), { status: 503 },
    )));
    req.end(payload);
  });
  let body: { data?: { result?: unknown }; error?: string };
  try { body = JSON.parse(text) as typeof body; }
  catch { throw Object.assign(new Error("jac harness returned a malformed response"), { status: 503 }); }
  if (status < 200 || status >= 300) {
    throw Object.assign(new Error(body.error ?? `jac harness answered ${status}`), { status });
  }
  return unwrapJacResult(body.data?.result, "operation failed");
}

// Every node→Jac call is serialized on one chain: the in-process manager
// applied each mutation before the next call, and ordering-sensitive pairs
// (a runtime event vs a manual run, mark-seen vs cancel) keep that
// guarantee here. Bridge handlers must never reach this queue — they would
// deadlock against the op that is awaiting their own response — so bridge
// code reads the mirror or schedules fire-and-forget writes only.
let opChain: Promise<unknown> = Promise.resolve();
export function jacOp<T = unknown>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  const call = opChain.then(() => jacOpRaw(name, args)) as Promise<T>;
  // A failed op must not poison the chain; the caller still sees it.
  opChain = call.then(() => undefined, () => undefined);
  return call;
}

/** An op outside the serialized chain, for subsystems with no ordering
 * contract against routines/webhooks and with slow upstream I/O (connected
 * apps relay a tool call for up to 10 minutes; MCP sign-in does discovery,
 * registration and token refresh). Queued, every routine op would stall
 * behind them. The harness serves sync defs on worker threads, so the Jac
 * side of such a subsystem must be thread-safe on its own. */
export function jacOpUnordered<T = unknown>(
  name: string,
  args: Record<string, unknown> = {},
  timeoutMs = OP_TIMEOUT_MS,
): Promise<T> {
  if (timeoutMs <= FETCH_HEADERS_LIMIT_MS) return jacOpRaw(name, args, timeoutMs) as Promise<T>;
  // fetch (undici) gives up waiting for response headers at 300s whatever
  // the signal says; longer budgets (Local VM image builds) use the raw
  // http transport with our own deadline.
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(Object.assign(new Error(`jac op ${name} timed out after ${timeoutMs}ms`), { status: 503 })),
      timeoutMs,
    );
  });
  return Promise.race([jacLongOpRaw(name, args), deadline]).finally(() => clearTimeout(timer)) as Promise<T>;
}
const FETCH_HEADERS_LIMIT_MS = 290_000;

/** A long op (no timeout). `serialize: true` holds the op chain for its
 * whole duration — the quiesce a workspace snapshot or restore commit
 * needs; otherwise it runs beside the chain (staging an upload touches only
 * its own job folder and must not stall routine traffic for minutes). */
export function jacLongOp<T = unknown>(name: string, args: Record<string, unknown> = {}, options: { serialize?: boolean } = {}): Promise<T> {
  if (!options.serialize) return jacLongOpRaw(name, args) as Promise<T>;
  const call = opChain.then(() => jacLongOpRaw(name, args)) as Promise<T>;
  opChain = call.then(() => undefined, () => undefined);
  return call;
}

// ── read mirror ──────────────────────────────────────────────────────────
// Emit frames ({kind:"routine",routine}, {kind:"routine.run",run},
// {kind:"routine.deleted",routineId}) update this store BEFORE they are
// broadcast-driven callback still sees the state the frame announced.
// Anything that can await should use the facade instead of guessing at
// this snapshot.

export interface RoutinePackageStampRow {
  routineId: string;
  botId: string;
  enabled: boolean;
  stamp: RoutinePackageStamp;
}

const mirrorRoutines = new Map<string, Routine>();
const mirrorStampRows = new Map<string, RoutinePackageStampRow>();
const mirrorRunById = new Map<string, RoutineRun>();

function mirrorRoutine(routine: Routine): void {
  mirrorRoutines.set(routine.id, routine);
  // Stamp rows are derived from installedPackage (routine_package_stamps
  // does the same Jac-side); keep them in step with every routine update.
  if (routine.installedPackage) {
    mirrorStampRows.set(routine.id, {
      routineId: routine.id,
      botId: routine.botId,
      enabled: routine.enabled,
      stamp: routine.installedPackage,
    });
  } else {
    mirrorStampRows.delete(routine.id);
  }
}

function mirrorPutRun(run: RoutineRun): void {
  mirrorRunById.set(run.id, run);
}

/** Apply one emit payload (the frames routines.ts used to put on the bus)
 * to the mirror. Returns false for payloads this mirror does not track. */
export function mirrorApplyFrame(payload: Record<string, unknown>): boolean {
  if (payload.kind === "routine" && payload.routine !== null && typeof payload.routine === "object") {
    mirrorRoutine(payload.routine as Routine);
    return true;
  }
  if (payload.kind === "routine.run" && payload.run !== null && typeof payload.run === "object") {
    mirrorPutRun(payload.run as RoutineRun);
    return true;
  }
  if (payload.kind === "routine.deleted" && typeof payload.routineId === "string") {
    mirrorRoutines.delete(payload.routineId);
    mirrorStampRows.delete(payload.routineId);
    return true;
  }
  return false;
}

export function mirrorListRoutines(): Routine[] {
  return [...mirrorRoutines.values()].map((routine) => structuredClone(routine));
}

export function mirrorListRuns(from?: number, to?: number): RoutineRun[] {
  return [...mirrorRunById.values()]
    .filter((run) => (from == null || run.scheduledFor >= from) && (to == null || run.scheduledFor <= to))
    .sort((a, b) => b.scheduledFor - a.scheduledFor)
    .map((run) => structuredClone(run));
}

/** One run per file order — the order RoutineManager.find() consulted. */
function mirrorRunWhere(predicate: (run: RoutineRun) => boolean): RoutineRun | null {
  for (const run of mirrorRunById.values()) {
    if (predicate(run)) return structuredClone(run);
  }
  return null;
}

export function mirrorRunForThread(threadId: string): RoutineRun | null {
  return mirrorRunWhere((run) => run.threadId === threadId);
}

/** One run by id — the bridge's start_goal looks up its coordinator bot
 * from the run jac just queued. */
export function mirrorRun(runId: string): RoutineRun | null {
  return mirrorRunById.get(runId) ?? null;
}

export function mirrorActiveRunForThread(threadId: string): RoutineRun | null {
  return mirrorRunWhere((run) => run.threadId === threadId && ACTIVE_RUN_STATUSES.includes(run.status));
}

export function mirrorIsActiveThread(threadId: string): boolean {
  return mirrorActiveRunForThread(threadId) !== null;
}

export function mirrorActiveRunForBot(botId: string): RoutineRun | null {
  return mirrorRunWhere((run) => run.botId === botId && ACTIVE_RUN_STATUSES.includes(run.status));
}

export function mirrorActiveBotRunForBot(botId: string): RoutineRun | null {
  return mirrorRunWhere(
    (run) => run.target === "bot" && run.botId === botId && ACTIVE_RUN_STATUSES.includes(run.status),
  );
}

export function mirrorPackageStamps(): RoutinePackageStampRow[] {
  return [...mirrorStampRows.values()].map((row) => structuredClone(row));
}

/** Whether the routines subsystem is likely mid-write (active runs a tick
 * is working). Stands in for RoutineManager.isTicking in the workspace-
 * maintenance idle predicate; exact ticking state is a Jac internal. */
export function mirrorBusy(): boolean {
  for (const run of mirrorRunById.values()) {
    if (["queued", "running", "waiting"].includes(run.status)) return true;
  }
  return false;
}

/** Pull the whole world into the mirror once the harness answers. */
async function mirrorRefresh(): Promise<void> {
  const listed = await jacOp<{ routines?: Routine[] }>("routine_list").catch(() => ({ routines: undefined }));
  const stamped = await jacOp<{ stamps?: RoutinePackageStampRow[] }>("routine_package_stamps").catch(() => ({ stamps: undefined }));
  const runs = await jacOp<{ runs?: RoutineRun[] }>("routine_list_runs").catch(() => ({ runs: undefined }));
  if (listed.routines) {
    mirrorRoutines.clear();
    for (const routine of listed.routines) mirrorRoutine(routine);
  }
  if (runs.runs) {
    mirrorRunById.clear();
    // Newest-first over the wire; the manager's .find() semantics consulted
    // file order, which is insertion order — reinsert oldest first.
    for (const run of [...runs.runs].reverse()) mirrorPutRun(run);
  }
  if (stamped.stamps) {
    mirrorStampRows.clear();
    for (const row of stamped.stamps) mirrorStampRows.set(row.routineId, row);
  }
}

/** One-time bring-up: harness up (when enabled), routine_boot, mirror
 * loaded. Idempotent; a disabled or failed harness resolves to null and
 * leaves the mirror empty, which the predicate sites read as "no
 * routines" — the `routines?.` they replace behaved the same way. */
let booted: Promise<string | null> | null = null;
export function startJacRoutines(): Promise<string | null> {
  booted ??= (async () => {
    const url = await ensureJacHarness();
    if (!url) return null;
    try {
      await jacOp("routine_boot");
    } catch (error) {
      logUnavailableOnce(`jac harness boot failed: ${error instanceof Error ? error.message : String(error)}`);
      return null;
    }
    await mirrorRefresh();
    return url;
  })();
  return booted;
}

// ── facade ───────────────────────────────────────────────────────────────

interface RoutineResult {
  routine?: Routine | null;
}

interface RunResult {
  run?: RoutineRun | null;
}

interface ListResult {
  routines?: Routine[];
}

interface RunsResult {
  runs?: RoutineRun[];
}

interface StampsResult {
  stamps?: RoutinePackageStampRow[];
}

function mirrorReturnedRoutine(result: RoutineResult | null | undefined): Routine | null {
  const routine = result?.routine ?? null;
  if (routine) mirrorRoutine(routine);
  return routine;
}

function mirrorReturnedRun(result: RunResult | null | undefined): RoutineRun | null {
  const run = result?.run ?? null;
  if (run) mirrorPutRun(run);
  return run;
}

const fireAndForget = (promise: Promise<unknown>) => {
  void promise.catch((error) => console.error(`routines: ${error instanceof Error ? error.message : String(error)}`));
};

export interface WebhookEnqueueInput {
  webhookId: string;
  webhookName: string;
  prompt: string;
  botId: string;
  runOn: Routine["runOn"];
  deliveryId: string;
  receivedAt: number;
}

export interface RoutineWakeHold {
  hold: boolean;
  reason?: "running" | "due";
  at?: number;
}

/** Async replacement for the RoutineManager surface node code calls. Each
 * method maps to one routine_* op; kwargs use the contract's snake_case. */
/** Whether the Jac scheduler is paused (mirrors RoutineManager.isTicking for
 * workspace maintenance's idle gate). A respawned harness starts unpaused. */
let schedulerPaused = false;
export function jacSchedulerTicking(): boolean {
  return jacEnabled() && jacUrl !== null && !schedulerPaused;
}

export const jacRoutines = {
  boot: () => jacOp<{ ok: boolean }>("routine_boot"),

  listRoutines: async (): Promise<Routine[]> =>
    (await jacOp<ListResult>("routine_list")).routines ?? [],

  listRuns: async (from?: number, to?: number): Promise<RoutineRun[]> =>
    (await jacOp<RunsResult>(
      "routine_list_runs",
      { ...(from !== undefined ? { from } : {}), ...(to !== undefined ? { to } : {}) },
    )).runs ?? [],

  packageStamps: async (): Promise<RoutinePackageStampRow[]> =>
    (await jacOp<StampsResult>("routine_package_stamps")).stamps ?? [],

  stampInstalledPackage: async (id: string, stamp: RoutinePackageStamp): Promise<boolean> => {
    const stamped = (await jacOp<{ stamped?: boolean }>("routine_stamp_installed_package", { id, stamp })).stamped === true;
    // The op emits no frame; reflect the stamp in the mirror ourselves.
    const routine = mirrorRoutines.get(id);
    if (stamped && routine) mirrorRoutine({ ...routine, installedPackage: stamp });
    return stamped;
  },

  wakeHold: (horizonMs?: number): Promise<RoutineWakeHold> =>
    jacOp<RoutineWakeHold>("routine_wake_hold", horizonMs === undefined ? {} : { horizon_ms: horizonMs }),

  create: async (input: RoutineInput, request?: RoutineRequestCommit): Promise<Routine> => {
    const routine = mirrorReturnedRoutine(
      await jacOp<RoutineResult>("routine_create", { input, ...(request ? { req: request } : {}) }),
    );
    if (!routine) throw Object.assign(new Error("routine_create returned no routine"), { status: 500 });
    return routine;
  },

  update: async (id: string, patch: Partial<RoutineInput>, request?: RoutineRequestCommit): Promise<Routine | null> =>
    mirrorReturnedRoutine(await jacOp<RoutineResult>("routine_update", { id, patch, ...(request ? { req: request } : {}) })),

  remove: async (id: string, request?: RoutineRequestCommit): Promise<boolean> => {
    const result = await jacOp<{ removed: boolean }>("routine_remove", { id, ...(request ? { req: request } : {}) });
    if (result.removed) {
      mirrorRoutines.delete(id);
      mirrorStampRows.delete(id);
    }
    return result.removed;
  },

  runNow: async (id: string, request?: RoutineRequestCommit): Promise<RoutineRun | null> =>
    mirrorReturnedRun(await jacOp<RunResult>("routine_run_now", { id, ...(request ? { req: request } : {}) })),

  cancelRun: async (id: string): Promise<RoutineRun | null> =>
    mirrorReturnedRun(await jacOp<RunResult>("routine_cancel_run", { id })),

  markSeen: async (id: string): Promise<RoutineRun | null> =>
    mirrorReturnedRun(await jacOp<RunResult>("routine_mark_seen", { id })),

  markAllSeen: async (): Promise<RoutineRun[]> => {
    const runs = (await jacOp<RunsResult>("routine_mark_all_seen")).runs ?? [];
    for (const run of runs) mirrorPutRun(run);
    return runs;
  },

  disableForBot: (botId: string): Promise<{ ok: boolean }> => {
    for (const routine of mirrorRoutines.values()) if (routine.botId === botId) routine.enabled = false;
    for (const row of mirrorStampRows.values()) if (row.botId === botId) row.enabled = false;
    return jacOp<{ ok: boolean }>("routine_disable_for_bot", { bot_id: botId });
  },

  disableForGroup: (groupId: string): Promise<{ ok: boolean }> => {
    const affected = new Set<string>();
    for (const routine of mirrorRoutines.values()) {
      if (routine.groupId === groupId) {
        routine.enabled = false;
        affected.add(routine.id);
      }
    }
    for (const row of mirrorStampRows.values()) if (affected.has(row.routineId)) row.enabled = false;
    return jacOp<{ ok: boolean }>("routine_disable_for_group", { group_id: groupId });
  },

  enqueueWebhook: (input: WebhookEnqueueInput): Promise<{ id: string }> =>
    jacOp<{ id: string }>("routine_enqueue_webhook", { input }),

  webhookRunReceipt: async (webhookId: string, deliveryId: string): Promise<{ id: string } | null> =>
    (await jacOp<{ run?: { id: string } | null }>(
      "routine_webhook_run_receipt",
      { webhook_id: webhookId, delivery_id: deliveryId },
    )).run ?? null,

  activeWebhookRunCount: async (webhookId: string): Promise<number> =>
    (await jacOp<{ count?: number }>("routine_active_webhook_run_count", { webhook_id: webhookId })).count ?? 0,

  cancelQueuedWebhook: async (webhookId: string, message: string): Promise<void> => {
    await jacOp("routine_cancel_queued_webhook", { webhook_id: webhookId, message });
  },

  routineRuntimeEvent: async (event: Record<string, unknown>): Promise<RoutineRun | null> =>
    mirrorReturnedRun(await jacOp<RunResult>("routine_runtime_event", { event })),

  failThread: async (threadId: string, message: string): Promise<void> => {
    await jacOp("routine_fail_thread", { thread_id: threadId, message });
  },

  finishGoalRun: async (runId: string, status: string, detail: string): Promise<RoutineRun | null> =>
    mirrorReturnedRun(await jacOp<RunResult>("routine_finish_goal_run", { run_id: runId, status, detail })),

  runForThread: async (threadId: string): Promise<RoutineRun | null> =>
    (await jacOp<RunResult>("routine_run_for_thread", { thread_id: threadId })).run ?? null,

  isActiveThread: async (threadId: string): Promise<boolean> =>
    (await jacOp<{ active?: boolean }>("routine_is_active_thread", { thread_id: threadId })).active === true,

  activeRunForBot: async (botId: string): Promise<RoutineRun | null> =>
    (await jacOp<RunResult>("routine_active_run_for_bot", { bot_id: botId })).run ?? null,

  activeBotRunForBot: async (botId: string): Promise<RoutineRun | null> =>
    (await jacOp<RunResult>("routine_active_bot_run_for_bot", { bot_id: botId })).run ?? null,

  routineRequestReceipt: async (requestId: string): Promise<RoutineRequestReceipt | null> =>
    (await jacOp<{ receipt?: RoutineRequestReceipt | null }>("routine_receipt", { request_id: requestId })).receipt ?? null,

  routineRequestReceiptOwners: async (): Promise<RoutineRequestOwner[]> =>
    (await jacOp<{ owners?: RoutineRequestOwner[] }>("routine_receipt_owners")).owners ?? [],

  forgetRoutineRequestReceipt: async (request: RoutineRequestCommit): Promise<boolean> =>
    (await jacOp<{ removed?: boolean }>("routine_forget_receipt", { req: request })).removed === true,

  forgetRoutineRequestReceiptsForThread: async (threadId: string): Promise<number> =>
    (await jacOp<{ removed?: number }>("routine_forget_receipts_for_thread", { thread_id: threadId })).removed ?? 0,

  reconcileRoutineRequestReceipts: async (reachable: readonly RoutineRequestOwner[]): Promise<number> =>
    (await jacOp<{ removed?: number }>("routine_reconcile_receipts", { reachable })).removed ?? 0,

  nextOccurrence: async (schedule: unknown, after: number, count = 1): Promise<number | null> => {
    const runs = (await jacOp<{ runs?: number[] }>("routine_next_occurrence", { schedule, after, count })).runs ?? [];
    return runs[0] ?? null;
  },

  /** Workspace-maintenance hooks: pause/resume the Jac scheduler tick.
   * routine_pause/resume are phase-2 contract additions; an older harness
   * answers 404, which is tolerated (mirrorBusy() below approximates the
   * same gate for the idle predicate). */
  pause: async (): Promise<void> => {
    try { await jacOp("routine_pause"); }
    catch (error) { if (statusOf(error) !== 404) throw error; else return; }
    schedulerPaused = true;
  },

  resume: async (): Promise<void> => {
    try { await jacOp("routine_resume"); }
    catch (error) { if (statusOf(error) !== 404) throw error; }
    schedulerPaused = false;
  },

  /** Fire-and-forget writes for listeners that cannot await and whose
   * ordering does not matter (disable/forget cleanup after a delete, and
   * run failure reports). */
  detached: {
    disableForBot: (botId: string) => fireAndForget(jacRoutines.disableForBot(botId)),
    disableForGroup: (groupId: string) => fireAndForget(jacRoutines.disableForGroup(groupId)),
    remove: (id: string, request?: RoutineRequestCommit) =>
      fireAndForget(jacRoutines.remove(id, request).then(() => undefined)),
    forgetRoutineRequestReceiptsForThread: (threadId: string) =>
      fireAndForget(jacRoutines.forgetRoutineRequestReceiptsForThread(threadId)),
    failThread: (threadId: string, message: string) =>
      fireAndForget(jacRoutines.failThread(threadId, message)),
    routineRuntimeEvent: (event: Record<string, unknown>) =>
      fireAndForget(jacRoutines.routineRuntimeEvent(event)),
  },
};

/** The facade's static shape — the RoutineOps surface RoutineRequestService
 * consumes is declared locally in routine-requests.ts; jacRoutines
 * satisfies it structurally. */
export type JacRoutines = typeof jacRoutines;
