// Node-side seam for the Jac computers subsystem (phase 4 of the Jac
// migration). The managers live in the harness:
//   jac/harness/computer_control.jac   who is driving (+ the lent-screen lease)
//   jac/harness/team_computers.jac     team-computers.json
//   jac/harness/shared_computers.jac   computers lent by paired desktops
//   jac/harness/container_computer.jac Local VM lifecycle over docker/podman
//   jac/harness/local_computer.jac     the CUA descriptor ("this computer")
// This module owns the async facades, the sync read mirrors hot node paths
// need (control snapshots and team assignments), and the bridge ops Jac
// calls back into node with (node-owned facts: sessions, turn liveness, the
// TurnResources "computer:host" seat, and the SSE fan-out).
//
// Transport: short, ordering-sensitive mutations (control, team registry,
// lent-screen lease) ride the serialized `jacOp` queue like routines and
// webhooks. Blocking calls — a desktop's 20 s long poll, a bot request that
// waits up to 45 s for its desktop, docker builds and screenshots — go over
// `jacCall`, a direct, unserialized POST: they are independent of routine
// ordering and must never stall that queue. The harness serves sync def:pub
// on a worker pool, so they run concurrently there too.
//
// Bridge handlers below never re-enter jacOp (they would deadlock against
// the op awaiting their answer); they read mirrors and node state only.

import { randomUUID } from "node:crypto";

import {
  NO_CONTROL,
  type ControlLeaseReleaseResult,
  type ControlLeaseResult,
  type ControlSnapshot,
  type SharedComputerJob,
  type SharedComputerOperation,
  type SharedComputerOwner,
  type SharedComputerRegistration,
  type SharedComputerStatus,
  type TeamComputerRecord,
} from "../shared/computers.ts";
import type {
  ContainerComputerStatus,
  ContainerExecResult,
  ContainerRuntimeStatus,
  LifecycleAction,
  LocalVmTarget,
  Runtime,
} from "./container-computer.ts";
import { SHARED_LOCAL_VM_TARGET } from "./container-computer.ts";
import type { LocalComputerConnection } from "./local-computer.ts";
import { jacOp, jacOpUnordered, jacUnavailable } from "./jac-routines.ts";

type BridgePayload = Record<string, unknown>;

// ── unserialized transport ─────────────────────────────────────────────────

const statusError = (message: string, status: number) => Object.assign(new Error(message), { status });

/** One direct op, outside the serialized queue, with its own time budget
 * (long polls, bot requests, image builds, frames, exec). */
export function jacCall<T = unknown>(name: string, args: Record<string, unknown>, timeoutMs: number): Promise<T> {
  return jacOpUnordered<T>(name, args, timeoutMs);
}

// ── who is driving: mirror + facade ─────────────────────────────────────────

interface ControlMirrorEntry { snapshot: ControlSnapshot; lease: string | null }
const controlMirror = new Map<string, ControlMirrorEntry>();
let controlListener: (key: string, snapshot: ControlSnapshot) => void = () => {};

function controlMirrorPut(key: string, snapshot: ControlSnapshot, lease: string | null): void {
  if (!snapshot.held && snapshot.helpReason === null) controlMirror.delete(key);
  else controlMirror.set(key, { snapshot: { ...snapshot }, lease: snapshot.held ? lease : null });
}

const asSnapshot = (value: unknown): ControlSnapshot => {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  return {
    held: raw.held === true,
    helpReason: typeof raw.helpReason === "string" ? raw.helpReason : null,
    heldSinceMs: typeof raw.heldSinceMs === "number" ? raw.heldSinceMs : null,
  };
};

export const computerControl = {
  /** The change listener (per-member SSE, the Electron browser gate). */
  onChange(listener: (key: string, snapshot: ControlSnapshot) => void): void { controlListener = listener; },
  /** Reload the mirror; a respawned harness starts with no holds. */
  async start(): Promise<void> {
    const { entries } = await jacOp<{ entries?: Array<{ key: string; snapshot: unknown; controlLeaseId?: string | null }> }>("computer_control_list");
    controlMirror.clear();
    for (const entry of entries ?? []) controlMirrorPut(entry.key, asSnapshot(entry.snapshot), entry.controlLeaseId ?? null);
  },
  snapshot(key: string): ControlSnapshot {
    const entry = controlMirror.get(key);
    return entry ? { ...entry.snapshot } : { ...NO_CONTROL };
  },
  ownsLease(key: string, controlLeaseId: string): boolean {
    const entry = controlMirror.get(key);
    return entry?.snapshot.held === true && entry.lease === controlLeaseId;
  },
  take: async (key: string): Promise<ControlSnapshot> =>
    asSnapshot((await jacOp<{ snapshot: unknown }>("computer_control_take", { key })).snapshot),
  release: async (key: string): Promise<ControlSnapshot> =>
    asSnapshot((await jacOp<{ snapshot: unknown }>("computer_control_release", { key })).snapshot),
  acquireLease: async (key: string, controlLeaseId: string): Promise<ControlLeaseResult> => {
    const result = await jacOp<ControlLeaseResult>("computer_control_acquire_lease", { key, control_lease_id: controlLeaseId });
    return { snapshot: asSnapshot(result.snapshot), owned: result.owned === true, acquired: result.acquired === true };
  },
  releaseLease: async (key: string, controlLeaseId: string): Promise<ControlLeaseReleaseResult> => {
    const result = await jacOp<ControlLeaseReleaseResult>("computer_control_release_lease", { key, control_lease_id: controlLeaseId });
    return { snapshot: asSnapshot(result.snapshot), released: result.released === true };
  },
  requestHelpLease: async (key: string, reason: unknown): Promise<{ snapshot: ControlSnapshot; requestId: string }> => {
    const result = await jacOp<{ snapshot: unknown; requestId: string }>("computer_control_request_help", { key, reason: typeof reason === "string" ? reason : null });
    return { snapshot: asSnapshot(result.snapshot), requestId: result.requestId };
  },
  requestHelp: async (key: string, reason: unknown): Promise<ControlSnapshot> => (await computerControl.requestHelpLease(key, reason)).snapshot,
  dismissHelp: async (key: string): Promise<ControlSnapshot> =>
    asSnapshot((await jacOp<{ snapshot: unknown }>("computer_control_dismiss_help", { key })).snapshot),
  expireHelp: async (key: string, requestId: unknown): Promise<ControlSnapshot> =>
    asSnapshot((await jacOp<{ snapshot: unknown }>("computer_control_expire_help", { key, request_id: typeof requestId === "string" ? requestId : null })).snapshot),
  /** The bot is gone. Fire-and-forget: the mirror and listeners update from
   * the harness's change frame. */
  forget(key: string): void {
    if (!controlMirror.has(key)) return;
    void jacOp("computer_control_forget", { key }).catch((error) => console.error(`computer-control: forget failed: ${error instanceof Error ? error.message : String(error)}`));
  },
};

// ── team computers: mirror + facade ────────────────────────────────────────

let teamEnvironmentId = "";
let teamRecords: TeamComputerRecord[] = [];
let teamProblem: string | null = null;

function teamApplyView(view: { computers?: TeamComputerRecord[]; problem?: string | null } | undefined): void {
  if (!view) return;
  teamRecords = (view.computers ?? []).map(entry => ({ ...entry }));
  teamProblem = view.problem ?? null;
}

const teamOp = async <T>(name: string, args: Record<string, unknown> = {}): Promise<T> => {
  const result = await jacOp<T & { view?: { computers?: TeamComputerRecord[]; problem?: string | null } }>(name, { environment_id: teamEnvironmentId, ...args });
  teamApplyView(result.view);
  return result;
};

const trimSection = (section: string | undefined): string => section?.trim() || "";

/** Named team computers. Reads answer from the mirror (hot routing paths
 * call them synchronously); a registry the harness could not load fails
 * closed with 503 exactly as the in-process registry did. Before the first
 * load the mirror is empty, the cold-start truth routines also use. */
export const teamComputers = {
  /** The workspace identity every op names; the harness (re)loads
   * team-computers.json lazily for it, so ops work even before start(). */
  configure(environmentId: string): void { teamEnvironmentId = environmentId; },
  async start(): Promise<void> {
    teamApplyView(await jacOp("team_computer_load", { environment_id: teamEnvironmentId }));
  },
  list(): TeamComputerRecord[] {
    if (teamProblem) throw statusError(teamProblem, 503);
    return teamRecords.map(entry => ({ ...entry }));
  },
  get(id: string): TeamComputerRecord | undefined { return teamComputers.list().find(entry => entry.id === id); },
  forSection(section: string | undefined): TeamComputerRecord | undefined {
    return teamComputers.list().find(entry => entry.section !== null && entry.section === trimSection(section));
  },
  forBot(bot: { computer?: string; cloudBackend?: string; section?: string }): TeamComputerRecord | undefined {
    // Explicit destinations are permissions, not suggestions. Only Auto inherits.
    return bot.computer === undefined && bot.cloudBackend !== "vps" ? teamComputers.forSection(bot.section) : undefined;
  },
  create: async (name: string, id: string): Promise<TeamComputerRecord> =>
    (await teamOp<{ computer: TeamComputerRecord }>("team_computer_create", { name, id })).computer,
  assign: async (id: string, section: string | null): Promise<TeamComputerRecord> =>
    (await teamOp<{ computer: TeamComputerRecord }>("team_computer_assign", { id, section })).computer,
  setProblem: async (id: string, problem?: string): Promise<TeamComputerRecord> =>
    (await teamOp<{ computer: TeamComputerRecord }>("team_computer_set_problem", { id, problem: problem ?? null })).computer,
  /** Relabel a team's assignment for Store.renameSection, which is
   * synchronous and transactional. The mirror changes now (the harness is
   * the only writer and node its only caller, so this is the state the
   * queued op will reach); a failed op reloads the mirror from the file. */
  renameSection(from: string, to: string): boolean {
    const entry = teamComputers.forSection(from);
    if (!entry || from === to) return false;
    if (teamComputers.forSection(to)) throw statusError("This team already has a computer", 409);
    teamRecords = teamRecords.map(candidate => candidate.id === entry.id ? { ...candidate, section: to.trim() } : candidate);
    void teamOp("team_computer_rename_section", { from_name: from, to_name: to }).catch(async (error) => {
      console.error(`team computers: rename failed: ${error instanceof Error ? error.message : String(error)}`);
      try { teamApplyView(await jacOp("team_computer_list", { environment_id: teamEnvironmentId })); } catch { /* keep the mirror */ }
    });
    return true;
  },
};
export type TeamComputers = typeof teamComputers;

// ── computers lent by a paired desktop ─────────────────────────────────────

/** The person a bot turn acts for, from the harness's own record of which
 * message started it: that request must name this exact turn generation (a
 * continuation of the same request adds its generation), must not have been
 * stopped, and its message must come from a person. Anything else is nobody. */
export function provenRequestPerson(
  request: { messageId?: string; generations: ReadonlySet<string>; stopped?: boolean } | undefined,
  generation: string,
  personOf: (messageId: string) => string | undefined,
): string | null {
  if (!request?.messageId || request.stopped || !request.generations.has(generation)) return null;
  return personOf(request.messageId) ?? null;
}

const activeRefs = new Map<string, () => boolean>();
let sessionLive: (sessionId: string) => boolean = () => false;

export const sharedComputers = {
  /** Node owns sessions; the harness asks through `shared_sessions_live`. */
  configure(options: { sessionLive: (sessionId: string) => boolean }): void { sessionLive = options.sessionLive; },
  register: async (registration: SharedComputerRegistration, owner: SharedComputerOwner, secret: string): Promise<void> => {
    await jacCall("shared_computer_register", { registration, session: owner.session, person: owner.person, secret }, 30_000);
  },
  list: async (principal: string | null): Promise<SharedComputerRegistration[]> =>
    (await jacCall<{ computers: SharedComputerRegistration[] }>("shared_computer_list", { principal }, 30_000)).computers,
  status: async (principal: string | null): Promise<SharedComputerStatus[]> =>
    (await jacCall<{ computers: SharedComputerStatus[] }>("shared_computer_status", { principal }, 30_000)).computers,
  poll: async (id: string, session: string, secret: string): Promise<SharedComputerJob | null> =>
    (await jacCall<{ job: SharedComputerJob | null }>("shared_computer_poll", { id, session, secret }, 50_000)).job,
  liveJob: async (id: string, session: string, secret: string, jobId: string): Promise<boolean> =>
    (await jacCall<{ active: boolean }>("shared_computer_live_job", { id, session, secret, job_id: jobId }, 30_000)).active,
  complete: async (id: string, session: string, secret: string, jobId: string, result: unknown): Promise<void> => {
    await jacCall("shared_computer_complete", { id, session, secret, job_id: jobId, result: result ?? null }, 30_000);
  },
  disconnect: async (id: string, session: string, secret: string): Promise<void> => {
    await jacCall("shared_computer_disconnect", { id, session, secret }, 30_000);
  },
  /** One bot operation; `active` stays node-side under an opaque ref the
   * harness checks through `shared_job_active` until the job settles. */
  request: async (operation: SharedComputerOperation, principal: string | null, active: () => boolean): Promise<unknown> => {
    const ref = randomUUID();
    activeRefs.set(ref, active);
    try {
      return (await jacCall<{ result: unknown }>("shared_computer_request", { operation, principal, active_ref: ref }, 75_000)).result;
    } finally {
      activeRefs.delete(ref);
    }
  },
  /** Best effort, never throws, and never boots a harness just to close. */
  close: async (): Promise<void> => {
    if (jacUnavailable()) return;
    await jacCall("shared_computer_close", {}, 5_000).catch(() => undefined);
  },
};

// ── the lent screen vs local turns (computer_control.jac) ───────────────────

let sharedControlHooks: { held: () => boolean; claim: (id: string) => boolean; release: (id: string) => void } = {
  held: () => true, claim: () => false, release: () => {},
};

export const sharedComputerControl = {
  configure(hooks: typeof sharedControlHooks): void { sharedControlHooks = hooks; },
  acquire: async (id: string): Promise<void> => { await jacOp("shared_control_lease", { action: "acquire", id }); },
  renew: async (id: string): Promise<void> => { await jacOp("shared_control_lease", { action: "renew", id }); },
  release: async (id: string): Promise<void> => { await jacOp("shared_control_lease", { action: "release", id }); },
  close: async (): Promise<void> => {
    if (jacUnavailable()) return;
    await jacCall("shared_control_close", {}, 5_000).catch(() => undefined);
  },
};

// ── Local VM (container_computer.jac) ───────────────────────────────────────

const targetArg = (target: LocalVmTarget) => ({
  key: target.key, containerName: target.containerName, workspaceDir: target.workspaceDir,
  viewerPort: target.viewerPort, label: target.label,
});

export async function containerRuntimeStatus(): Promise<ContainerRuntimeStatus> {
  return jacCall<ContainerRuntimeStatus>("computer_runtime_status", {}, 60_000);
}

export async function containerComputerStatus(
  target: LocalVmTarget = SHARED_LOCAL_VM_TARGET,
  options: { probeDesktop?: boolean } = {},
): Promise<ContainerComputerStatus> {
  return (await jacCall<{ status: ContainerComputerStatus }>("computer_vm_status", {
    target: targetArg(target), probe_desktop: options.probeDesktop !== false,
  }, 180_000)).status;
}

export async function containerComputerAction(
  action: LifecycleAction,
  target: LocalVmTarget = SHARED_LOCAL_VM_TARGET,
): Promise<ContainerComputerStatus> {
  // pull = base pull + build (10 min each); the others are 2 min plus two status probes.
  return (await jacCall<{ status: ContainerComputerStatus }>("computer_vm_action", { action, target: targetArg(target) }, 25 * 60_000)).status;
}

export async function containerComputerExists(runtime: Runtime, target: LocalVmTarget): Promise<boolean> {
  return (await jacCall<{ exists: boolean }>("computer_vm_exists", { runtime, target: targetArg(target) }, 30_000)).exists;
}

/** The raw frame the live screen poller broadcasts. */
export async function containerComputerFrame(target: LocalVmTarget = SHARED_LOCAL_VM_TARGET): Promise<{ png: string; format: "png" | "jpeg" }> {
  return jacCall<{ png: string; format: "png" | "jpeg" }>("computer_vm_frame", { target: targetArg(target) }, 240_000);
}

export async function containerComputerScreenshot(target: LocalVmTarget = SHARED_LOCAL_VM_TARGET): Promise<string> {
  const { png, format } = await containerComputerFrame(target);
  return `data:image/${format};base64,${png}`;
}

export async function containerExec(
  target: LocalVmTarget,
  command: string,
  options: { timeoutSeconds?: number; runtime?: Runtime } = {},
): Promise<ContainerExecResult> {
  // Same refusals, same order, as the harness: NaN/Infinity are not JSON,
  // so the finite check cannot travel and is answered here.
  if (!command.trim()) throw statusError("command is required", 400);
  if (command.length > 20_000) throw statusError("command is too long", 400);
  if (options.timeoutSeconds !== undefined && !Number.isFinite(options.timeoutSeconds)) {
    throw statusError("timeout_seconds must be finite", 400);
  }
  const seconds = options.timeoutSeconds === undefined ? 60 : Math.min(Math.max(Math.floor(options.timeoutSeconds), 1), 300);
  return jacCall<ContainerExecResult>("computer_vm_exec", {
    target: targetArg(target), command,
    timeout_seconds: options.timeoutSeconds ?? null,
    runtime: options.runtime ?? null,
  }, (seconds + 60) * 1000);
}

// ── this computer (local_computer.jac) ──────────────────────────────────────

export async function readCuaConnection(): Promise<LocalComputerConnection | null> {
  return (await jacCall<{ connection: LocalComputerConnection | null }>("computer_cua_connection", {}, 30_000)).connection;
}

export async function readCuaUnavailableReason(): Promise<string | null> {
  return (await jacCall<{ reason: string | null }>("computer_cua_unavailable_reason", {}, 30_000)).reason;
}

// ── bridge ops (Jac → node) ─────────────────────────────────────────────────

/** Spread into index.ts's routine-bridge op table. */
export const computersBridgeOps: Record<string, (payload: BridgePayload) => unknown> = {
  // Mirror first, then the listener sees the state the frame announced.
  computer_control_changed: (payload) => {
    const key = typeof payload.key === "string" ? payload.key : "";
    if (!key) return { ok: false };
    const snapshot = asSnapshot(payload.snapshot);
    controlMirrorPut(key, snapshot, typeof payload.control_lease_id === "string" ? payload.control_lease_id : null);
    controlListener(key, snapshot);
    return { ok: true };
  },
  shared_control_held: () => ({ held: sharedControlHooks.held() }),
  shared_control_claim: (payload) => ({ claimed: typeof payload.id === "string" && sharedControlHooks.claim(payload.id) }),
  shared_control_release: (payload) => {
    if (typeof payload.id === "string") sharedControlHooks.release(payload.id);
    return { ok: true };
  },
  shared_sessions_live: (payload) => {
    const sessions = Array.isArray(payload.sessions) ? payload.sessions.filter((id): id is string => typeof id === "string") : [];
    return { live: Object.fromEntries(sessions.map(id => [id, sessionLive(id)])) };
  },
  shared_job_active: (payload) => {
    const active = typeof payload.ref === "string" ? activeRefs.get(payload.ref) : undefined;
    let answer = false;
    try { answer = active?.() === true; } catch { answer = false; }
    return { active: answer };
  },
};
