import type { GroupGoalRunStatus } from "../shared/group-goal-run.ts";
import type { RoutineRequestOperation } from "../shared/routine-request.ts";
import { nextCronRuns, type RoutineCronSchedule } from "../shared/routine-schedule.ts";
import type { PartPair, RoutinePart } from "./package-parts.ts";

export interface RoutineIntervalWindow {
  start: string;
  end: string;
}

export interface RoutineIntervalSchedule {
  type: "interval";
  everyMinutes: number;
  anchorAt: number;
  /** Local weekdays (`0` is Sunday). Missing means every day. */
  weekdays?: number[];
  /** Local, same-day wall-clock window. Missing means all day. */
  window?: RoutineIntervalWindow;
  /** Inclusive epoch-millisecond cutoff. Missing means the series never ends. */
  endsAt?: number;
}

/** Input-only nullable restrictions let current clients deliberately clear a
 * restriction while an omitted field remains distinguishable for legacy
 * clients that know only the interval cadence and anchor. */
export type RoutineIntervalScheduleInput = Omit<RoutineIntervalSchedule, "weekdays" | "window" | "endsAt"> & {
  weekdays?: number[] | null;
  window?: RoutineIntervalWindow | null;
  endsAt?: number | null;
};

export type RoutineSchedule =
  | { type: "once"; at: number }
  | { type: "daily"; time: string; weekdays: number[] }
  | RoutineCronSchedule
  | RoutineIntervalSchedule;

export type RoutineScheduleInput =
  | Exclude<RoutineSchedule, RoutineIntervalSchedule>
  | RoutineIntervalScheduleInput;

/** `cloud` runs the agent itself inside the bot's Boat VM. `maus` keeps
 * using the provider selected on the MAUS and only borrows its configured
 * computer tools, if any. */
export type RoutineRunOn = "maus" | "cloud";
export type RoutineTarget = "bot" | "room-goal";
export type RoutineGoalStatus = Exclude<GroupGoalRunStatus, "working">;
export interface RoutineContextAttachment {
  id: string;
  kind: "file" | "image";
  name: string;
  path: string;
  size: number;
}

export type RoutineRunTrigger = "schedule" | "manual" | "webhook";

export type RoutineRunStatus =
  | "queued"
  | "running"
  | "waiting"
  | "completed"
  | "failed"
  | "cancelled"
  | "missed";

export interface Routine {
  id: string;
  name: string;
  prompt: string;
  target: RoutineTarget;
  /** A bot routine's owner, or the lead coordinator for a room goal. */
  botId: string;
  groupId?: string;
  runOn: RoutineRunOn;
  enabled: boolean;
  schedule: RoutineSchedule;
  /** Legacy calendar/display length. Kept for persisted-data compatibility. */
  durationMinutes: number;
  /** Optional safety cap for active work. Missing means no timeout. */
  timeoutMinutes?: number;
  attachments?: RoutineContextAttachment[];
  /** Carry the previous run's report into the next run's prompt, so recurring
   * work builds on itself instead of restarting cold. Optional so existing
   * files migrate in place. */
  continuity?: boolean;
  /** Default skips overlapping scheduled occurrences. Queue retains at most
   * one pending scheduled run; manual/webhook requests stay independent. */
  overlap?: "skip" | "queue";
  skippedRuns?: number;
  lastSkippedAt?: number;
  /** Derived from retained terminal receipts, not another persisted authority. */
  failureStreak?: number;
  /** Conversation that created this routine in chat. Calendar/import-created
   * routines intentionally have no source, and older files migrate in place. */
  sourceThreadId?: string;
  /** Stable visible report destination (the bot's main thread unless the
   * person chose another); execution still gets a fresh task. */
  resultsThreadId?: string;
  /** Server-private: added from the organization's library. Never on the
   * wire (routineWithHealth drops it); packageStamps() reads it. */
  installedPackage?: RoutinePackageStamp;
  nextRunAt: number | null;
  createdAt: number;
  updatedAt: number;
}

/** Which organization install a routine came from, its key in the package,
 * and each part's release and written hashes (server/package-parts.ts). */
export interface RoutinePackageStamp {
  installId: string;
  key: string;
  parts: Record<RoutinePart, PartPair>;
}

export interface RoutineRun {
  id: string;
  routineId: string;
  routineName: string;
  /** Snapshot the work so an edited/deleted definition cannot rewrite history. */
  prompt?: string;
  /** Snapshot of the legacy calendar/display length. */
  durationMinutes?: number;
  /** Snapshot of the optional active-work safety cap. */
  timeoutMinutes?: number;
  attachments?: RoutineContextAttachment[];
  target: RoutineTarget;
  /** Exact terminal room outcome. `status` remains the scheduler lifecycle
   * while this preserves blocked/needs-input/limit semantics and closes the
   * cross-file crash-recovery gap with the room's goal card. */
  goalStatus?: RoutineGoalStatus;
  /** Snapshot the room as well as the coordinator so edited definitions do
   * not redirect already-queued team work. */
  groupId?: string;
  botId: string;
  runOn: RoutineRunOn;
  scheduledFor: number;
  status: RoutineRunStatus;
  manual: boolean;
  /** First tick a queued run was skipped because its target bot or room was
   * busy. Deferral behind a busy target is unbounded, so this timestamp is
   * what surfaces the wait instead of leaving the run looking freshly queued. */
  deferredAt?: number;
  /** When the one-per-run deferral notice was raised, so restarts and repeat
   * ticks stay quiet. */
  deferredNoticeAt?: number;
  /** Why this receipt exists. Kept optional so version-1 files migrate in place. */
  triggerSource?: RoutineRunTrigger;
  webhookId?: string;
  deliveryId?: string;
  /** Snapshot the routine's reporting destination. Execution remains on the
   * separate `threadId` so recurring work never contaminates chat context. */
  sourceThreadId?: string;
  /** Snapshot of the chosen destination, never redirected by later edits. */
  resultsThreadId?: string;
  threadId?: string;
  startedAt?: number;
  finishedAt?: number;
  output?: string;
  /** Human-readable reason the detached execution is waiting. */
  attention?: string;
  error?: string;
  cost?: number | null;
  denials?: string[];
  createdAt: number;
  seenAt?: number;
}

export interface RoutineRequestReceipt {
  requestId: string;
  messageId: string;
  botId: string;
  threadId: string;
  action: RoutineRequestOperation["action"];
  fingerprintVersion: 1;
  /** SHA-256 of the strict normalized operation carried by the card. */
  fingerprint: string;
  resultId: string;
  appliedAt: number;
}

export interface RoutineRequestCommit {
  requestId: string;
  messageId: string;
  botId: string;
  threadId: string;
  action: RoutineRequestOperation["action"];
  fingerprintVersion: 1;
  fingerprint: string;
}

export interface RoutineInput {
  name: string;
  prompt: string;
  target?: RoutineTarget;
  botId: string;
  /** `null` deliberately clears a room when changing the target back to a bot. */
  groupId?: string | null;
  runOn?: RoutineRunOn;
  enabled?: boolean;
  schedule: RoutineScheduleInput;
  durationMinutes?: number;
  /** `null` deliberately removes an existing safety cap. */
  timeoutMinutes?: number | null;
  attachments?: RoutineContextAttachment[];
  continuity?: boolean;
  overlap?: "skip" | "queue";
  /** Omission preserves routing; null resets it to the bot's main thread. */
  resultsThreadId?: string | null;
}

export type RoutineRequestOwner = Pick<RoutineRequestReceipt, "requestId" | "messageId" | "botId" | "threadId">;

const ALL_DAYS = [0, 1, 2, 3, 4, 5, 6];
const MAX_DATE_MS = 8_640_000_000_000_000;
const LOCAL_DAY_MS = 24 * 60 * 60_000;
const INTERVAL_RESTRICTION_SEARCH_MS = 9 * LOCAL_DAY_MS;
const CLOCK_TIME = /^([01]\d|2[0-3]):([0-5]\d)$/;

function cleanDays(days: unknown): number[] {
  if (!Array.isArray(days)) return ALL_DAYS;
  const out = [...new Set(days.filter((d): d is number => Number.isInteger(d) && d >= 0 && d <= 6))].sort();
  return out.length ? out : ALL_DAYS;
}

function clockMinutes(value: string): number | null {
  const match = CLOCK_TIME.exec(value);
  return match ? Number(match[1]) * 60 + Number(match[2]) : null;
}

function intervalHasRestrictions(
  schedule: Pick<RoutineIntervalSchedule, "weekdays" | "window" | "endsAt">,
): boolean {
  return schedule.weekdays !== undefined || schedule.window !== undefined || schedule.endsAt !== undefined;
}

function intervalAllowsOccurrence(schedule: RoutineIntervalSchedule, at: number): boolean {
  if (schedule.endsAt !== undefined && at > schedule.endsAt) return false;
  const date = new Date(at);
  if (schedule.weekdays && !schedule.weekdays.includes(date.getDay())) return false;
  if (schedule.window) {
    const minute = date.getHours() * 60 + date.getMinutes();
    const start = clockMinutes(schedule.window.start)!;
    const end = clockMinutes(schedule.window.end)!;
    if (minute < start || minute >= end) return false;
  }
  return true;
}

function nextAlignedInterval(schedule: RoutineIntervalSchedule, after: number): number | null {
  if (schedule.anchorAt > after) return schedule.anchorAt;
  const intervalMs = schedule.everyMinutes * 60_000;
  const intervalsElapsed = Math.floor((after - schedule.anchorAt) / intervalMs);
  const candidate = schedule.anchorAt + (intervalsElapsed + 1) * intervalMs;
  return Number.isSafeInteger(candidate) && candidate <= MAX_DATE_MS ? candidate : null;
}

/** Next occurrence strictly after `after`: cron uses its saved zone, daily uses the host zone. */
export function nextOccurrence(schedule: RoutineSchedule, after: number): number | null {
  if (schedule.type === "once") return schedule.at > after ? schedule.at : null;
  if (schedule.type === "cron") return nextCronRuns(schedule, after, 1)[0] ?? null;
  if (schedule.type === "interval") {
    const intervalMs = schedule.everyMinutes * 60_000;
    let candidate = nextAlignedInterval(schedule, after);
    if (!intervalHasRestrictions(schedule)) return candidate;
    const maxCandidates = Math.ceil(INTERVAL_RESTRICTION_SEARCH_MS / intervalMs) + 2;
    for (let checked = 0; candidate !== null && checked < maxCandidates; checked++) {
      if (schedule.endsAt !== undefined && candidate > schedule.endsAt) return null;
      if (intervalAllowsOccurrence(schedule, candidate)) return candidate;
      const next = candidate + intervalMs;
      candidate = Number.isSafeInteger(next) && next <= MAX_DATE_MS ? next : null;
    }
    return null;
  }
  const [hour, minute] = schedule.time.split(":").map(Number);
  const weekdays = new Set(cleanDays(schedule.weekdays));
  for (let offset = 0; offset <= 8; offset++) {
    const d = new Date(after);
    d.setDate(d.getDate() + offset);
    d.setHours(hour, minute, 0, 0);
    if (d.getTime() > after && weekdays.has(d.getDay())) return d.getTime();
  }
  return null;
}
