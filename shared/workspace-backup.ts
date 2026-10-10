/** Archive limits (enforced by jac/harness/workspace_backup.jac; the upload
 * and cloud-move transports in node check them before handing a file over). */
export const MAX_WORKSPACE_BACKUP_BYTES = 10 * 1024 ** 3;
export const MAX_WORKSPACE_BACKUP_FILES = 100_000;
export const MAX_WORKSPACE_BACKUP_UPLOAD_BYTES = MAX_WORKSPACE_BACKUP_BYTES + 256 * 1024 ** 2;

/** Full, encrypted workspace snapshots are distinct from additive team copies. */
export interface WorkspaceBackupSummary {
  format: "openmaus.workspace-backup";
  version: 1;
  id: string;
  createdAt: string;
  appVersion: string;
  files: number;
  directories: number;
  bytes: number;
  bots: number;
  groups: number;
  threads: number;
  messages: number;
  exclusions: string[];
  warnings: string[];
}

export type WorkspaceBackupClientState = Record<string, string>;

export interface WorkspaceBackupPrivateMetadata {
  summary: WorkspaceBackupSummary;
  clientState: WorkspaceBackupClientState;
}
