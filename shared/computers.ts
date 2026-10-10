// Wire contracts for the computers subsystem. The managers live in the Jac
// harness (jac/harness/{computer_control,team_computers,shared_computers,
// container_computer,local_computer}.jac); node validates requests with these
// schemas and reads results through server/jac-computers.ts.
import { z } from "zod";

// ── who is driving (computer_control.jac) ─────────────────────────────────

export interface ControlSnapshot {
  /** True while the person is driving; the bot's hands are refused. */
  held: boolean;
  /** The bot's open plea for help, verbatim, or null when none is open. */
  helpReason: string | null;
  heldSinceMs: number | null;
}

export interface ControlLeaseResult {
  snapshot: ControlSnapshot;
  /** True only when this lease currently owns the hold. */
  owned: boolean;
  /** True only when this call changed an unheld record into a held one. */
  acquired: boolean;
}

export interface ControlLeaseReleaseResult {
  snapshot: ControlSnapshot;
  /** True only when this call removed a hold owned by the supplied lease. */
  released: boolean;
}

export const NO_CONTROL: ControlSnapshot = { held: false, helpReason: null, heldSinceMs: null };

// ── team computers (team_computers.jac) ────────────────────────────────────

const teamComputerName = z.string().trim().min(1).max(60).refine(value => [...value].every(character => character.charCodeAt(0) >= 32 && character.charCodeAt(0) !== 127));

export const teamComputerCreate = z.object({
  name: teamComputerName,
  acknowledgeCost: z.literal(true),
  // Clients may keep this id across a lost create response. It is not a Boat id.
  requestId: z.string().uuid(),
}).strict();
export const teamComputerAssignment = z.object({
  section: z.string().trim().max(60).nullable(),
  acknowledgeSharedAccess: z.literal(true),
}).strict();

export interface TeamComputerRecord {
  id: string;
  name: string;
  section: string | null;
  createdAt: number;
  problem?: string;
}
export const teamComputerOwner = (id: string): string => `computer_${id}`;

// ── computers lent by a paired desktop (shared_computers.jac) ──────────────

const sharedFolder = z.object({ id: z.string().uuid(), name: z.string().min(1).max(120), write: z.boolean() }).strict();
export const sharedComputerRegistration = z.object({
  id: z.string().uuid(), name: z.string().min(1).max(120), environmentId: z.string().uuid(),
  folders: z.array(sharedFolder).max(20), terminal: z.boolean(), computer: z.boolean(),
}).strict();
export const sharedComputerOperation = z.object({
  computer_id: z.string().uuid(),
  action: z.enum(["list_files", "read_file", "write_file", "run_command", "computer_tools", "computer_call"]),
  folder_id: z.string().uuid().optional(), path: z.string().max(2048).optional(),
  content: z.string().max(350_000).optional(), encoding: z.enum(["utf8", "base64"]).optional(),
  expected_sha256: z.string().regex(/^[a-f0-9]{64}$/).optional(),
  command: z.string().max(8000).optional(), tool_name: z.string().max(100).optional(),
  arguments: z.record(z.string(), z.unknown()).optional(),
}).strict();
export type SharedComputerRegistration = z.infer<typeof sharedComputerRegistration>;
export type SharedComputerOperation = z.infer<typeof sharedComputerOperation>;
/** Who lent a computer: the paired session that registered it (it alone may
 * poll, answer and disconnect) and the person behind that session (only that
 * person's bot turns may see or use it). */
export type SharedComputerOwner = { session: string; person: string };
export type SharedComputerStatus = {
  id: string; name: string; online: boolean; busy: boolean; lastSeenAt: number;
  scopes: { folders: { id: string; name: string; write: boolean }[]; terminal: boolean; screen: boolean };
};
export type SharedComputerJob = { id: string; operation: SharedComputerOperation };
