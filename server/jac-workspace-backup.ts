// Node-side seam for workspace backups on Jac (phase 4 of the Jac
// migration). Snapshot, encryption, staging, the restore journal and the
// boot-time swap live in jac/harness/workspace_backup.jac. This module owns
// the async facade (same signatures as the old server/workspace-backup.ts,
// dataDir first) and the one callback the Jac side needs from node: the
// config policy (portableWorkspaceConfig / restoredWorkspaceConfig), which
// is bound to node's config schema.
//
// That callback is a per-operation loopback listener, not the routine
// bridge: a restore is applied at boot before node listens, and an export or
// commit runs while the maintenance gate answers /api traffic with 503. The
// listener lives exactly as long as its op and checks the harness token.
//
// Ordering: export and commit hold the jacOp chain for their whole run (the
// harness also pauses its scheduler in-process), so no routine or webhook
// write interleaves with the snapshot; staging touches only its own job
// folder and runs beside the chain.

import { createServer, type IncomingMessage } from "node:http";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { timingSafeEqual } from "node:crypto";
import type { AddressInfo } from "node:net";

import type { WorkspaceBackupClientState, WorkspaceBackupPrivateMetadata, WorkspaceBackupSummary } from "../shared/workspace-backup.ts";
import { jacBridgeToken, jacLongOp, jacOp } from "./jac-routines.ts";
import { portableWorkspaceConfig, restoredWorkspaceConfig } from "./workspace-backup-policy.ts";

export type { WorkspaceBackupSummary, WorkspaceBackupPrivateMetadata } from "../shared/workspace-backup.ts";
export {
  MAX_WORKSPACE_BACKUP_BYTES, MAX_WORKSPACE_BACKUP_FILES, MAX_WORKSPACE_BACKUP_UPLOAD_BYTES,
} from "../shared/workspace-backup.ts";
export { omittedFromWorkspaceBackup } from "./workspace-backup-policy.ts";

export interface CreateWorkspaceBackupOptions {
  password: string;
  clientState?: WorkspaceBackupClientState;
  appVersion?: string;
}
export type CreatedWorkspaceBackup = { id: string; path: string; summary: WorkspaceBackupSummary };
export interface WorkspaceRestoreResult {
  restored: boolean;
  rolledBack?: boolean;
  id?: string;
  safetyCopyPath?: string;
  summary?: WorkspaceBackupSummary;
  clientState?: WorkspaceBackupClientState;
}
export type LastWorkspaceRestore = WorkspaceRestoreResult & { restored: true; id: string };

// ── config policy callback ────────────────────────────────────────────────

function readJsonBody(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let bytes = 0;
    req.on("data", (chunk: Buffer) => {
      bytes += chunk.length;
      // Config documents are capped at the 16 MiB metadata limit Jac-side.
      if (bytes > 40 * 1024 * 1024) { reject(new Error("policy request too large")); req.destroy(); return; }
      chunks.push(chunk);
    });
    req.once("end", () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}")); } catch (error) { reject(error); }
    });
    req.once("error", reject);
  });
}

/** One policy decision, exactly as the old in-process call made it. */
export function workspaceBackupConfigPolicy(action: unknown, config: unknown, destination: unknown): Record<string, unknown> {
  if (action === "portable") return portableWorkspaceConfig(config);
  if (action === "restored") return restoredWorkspaceConfig(config, destination);
  throw new Error("Unknown workspace configuration policy.");
}

async function withConfigPolicy<T>(work: (policyUrl: string) => Promise<T>): Promise<T> {
  const expected = Buffer.from(jacBridgeToken());
  const server = createServer((req, res) => {
    const reply = (status: number, body: unknown) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };
    const actual = Buffer.from(String(req.headers["x-omb-jac-token"] ?? ""));
    if (req.method !== "POST" || actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
      reply(403, { error: "unauthorized" });
      return;
    }
    readJsonBody(req).then((body) => {
      const call = (body ?? {}) as { action?: unknown; config?: unknown; destination?: unknown };
      try {
        reply(200, { config: workspaceBackupConfigPolicy(call.action, call.config, call.destination) });
      } catch (error) {
        reply(200, { error: error instanceof Error ? error.message : "Invalid workspace configuration in backup." });
      }
    }, () => reply(400, { error: "Invalid workspace configuration request." }));
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve());
  });
  try {
    const { port } = server.address() as AddressInfo;
    return await work(`http://127.0.0.1:${port}/`);
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}

// ── facade ────────────────────────────────────────────────────────────────

/** Snapshot and encrypt the workspace. The caller holds the maintenance gate. */
export async function createWorkspaceBackup(dataDir: string, options: CreateWorkspaceBackupOptions): Promise<CreatedWorkspaceBackup> {
  if (Object.hasOwn(options, "credentials")) throw new Error("Workspace backups do not transfer credentials.");
  return withConfigPolicy((policyUrl) => jacLongOp<CreatedWorkspaceBackup>("workspace_backup_create", {
    data_dir: dataDir, policy_url: policyUrl, password: options.password,
    ...(options.clientState !== undefined ? { client_state: options.clientState } : {}),
    ...(options.appVersion !== undefined ? { app_version: options.appVersion } : {}),
  }, { serialize: true }));
}

/** Authenticate, inspect and extract an uploaded archive into its own job. */
export async function stageWorkspaceBackup(dataDir: string, archivePath: string, options: { password: string; currentAppVersion?: string }): Promise<{ id: string; summary: WorkspaceBackupSummary }> {
  return withConfigPolicy((policyUrl) => jacLongOp<{ id: string; summary: WorkspaceBackupSummary }>("workspace_backup_stage", {
    data_dir: dataDir, policy_url: policyUrl, archive_path: archivePath, password: options.password,
    ...(options.currentAppVersion !== undefined ? { current_app_version: options.currentAppVersion } : {}),
  }));
}

export async function readStagedWorkspaceBackup(dataDir: string, id: string): Promise<WorkspaceBackupPrivateMetadata & { id: string }> {
  return (await jacOp<{ staged: WorkspaceBackupPrivateMetadata & { id: string } }>("workspace_backup_read_staged", { data_dir: dataDir, id })).staged;
}

/** Validate, adapt and record a restart request. The scheduler stays paused. */
export async function commitPendingWorkspaceRestore(dataDir: string, id: string): Promise<{ id: string; restartRequired: true; summary: WorkspaceBackupSummary }> {
  return withConfigPolicy((policyUrl) => jacLongOp("workspace_backup_commit", { data_dir: dataDir, policy_url: policyUrl, id }, { serialize: true }));
}

export async function readPendingWorkspaceRestoreMetadata(dataDir: string): Promise<(WorkspaceBackupPrivateMetadata & { id: string }) | null> {
  return (await jacOp<{ pending: (WorkspaceBackupPrivateMetadata & { id: string }) | null }>("workspace_backup_read_pending", { data_dir: dataDir })).pending;
}

/** Swap a committed restore in (or roll back an interrupted one). The
 * harness then drops its routines/webhooks state and message-db handle so
 * nothing it serves predates the restored files. */
export async function applyPendingWorkspaceRestore(dataDir: string): Promise<WorkspaceRestoreResult> {
  return withConfigPolicy(async (policyUrl) =>
    (await jacLongOp<{ result: WorkspaceRestoreResult }>("workspace_backup_apply_pending", { data_dir: dataDir, policy_url: policyUrl })).result);
}

export async function readLastWorkspaceRestore(dataDir: string): Promise<LastWorkspaceRestore | null> {
  return (await jacOp<{ receipt: LastWorkspaceRestore | null }>("workspace_backup_read_last", { data_dir: dataDir })).receipt;
}

/** Delete only an unreferenced upload/export/staging job. */
export async function removeWorkspaceBackupJob(dataDir: string, id: string): Promise<void> {
  // A job can hold gigabytes; deleting it may outlast the 30 s op budget.
  await jacLongOp("workspace_backup_remove_job", { data_dir: dataDir, id });
}

/** Whether startup has restore work to do (a committed restart request or
 * an interrupted swap). Only then does boot wait for the harness before
 * loading any state; the last-restore receipt is read once it is up. */
export function workspaceRestoreWorkPending(dataDir: string): boolean {
  const root = join(dataDir, ".backups");
  if (existsSync(join(root, "pending-restore.json"))) return true;
  try {
    const journal: unknown = JSON.parse(readFileSync(join(root, "restore-journal.json"), "utf8"));
    return Boolean(journal && typeof journal === "object" && (journal as { phase?: unknown }).phase === "applying");
  } catch (error) {
    // An unreadable journal is the harness's to judge (it refuses it).
    return existsSync(join(root, "restore-journal.json")) && !(error instanceof Error && "code" in error && error.code === "ENOENT");
  }
}
