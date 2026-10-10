import { parseStoredConfig } from "./config.ts";

// Connection sections deliberately stay on the destination as a whole: a
// restored URL must never redirect an API key retained from that device.
// Allowlisting ordinary settings also keeps future/unknown auth fields out.
const PORTABLE_CONFIG_KEYS = [
  "profile", "language", "budgets", "billing", "rooms", "threads",
  "localVm", "features", "browserProfiles",
] as const;

export function portableWorkspaceConfig(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid workspace configuration in backup.");
  const config = parseStoredConfig(value as Parameters<typeof parseStoredConfig>[0]);
  return Object.fromEntries(PORTABLE_CONFIG_KEYS.filter((key) => config[key] !== undefined).map((key) => [key, config[key]]));
}

// Switches that belong to the machine even inside a portable section.
// Computer sharing (lending a computer to this server) opens routes and a
// desktop connector here, so a restored workspace never turns it on or off.
const DESTINATION_FEATURES = ["sharedComputers"] as const;

export function restoredWorkspaceConfig(portable: unknown, destination: unknown): Record<string, unknown> {
  if (!destination || typeof destination !== "object" || Array.isArray(destination)) throw new Error("Invalid destination workspace configuration; connections were not changed.");
  const merged = { ...destination } as Record<string, unknown>;
  for (const key of PORTABLE_CONFIG_KEYS) delete merged[key];
  const restored = { ...merged, ...portableWorkspaceConfig(portable) };
  const own = (destination as { features?: Record<string, unknown> }).features ?? {};
  const features: Record<string, unknown> = { ...(restored.features as Record<string, unknown> | undefined) };
  for (const key of DESTINATION_FEATURES) {
    delete features[key];
    if (own[key] !== undefined) features[key] = own[key];
  }
  if (Object.keys(features).length) restored.features = features;
  else delete restored.features;
  return restored;
}

/** Exact app-owned authentication paths, not a scan of user document text. */
export function excludedWorkspaceAuthPath(path: string): boolean {
  // Machine/provider-specific execution grants are not portable template data.
  if (/^command-allowlist\.json(?:$|\.\d+\.[0-9a-f-]+\.tmp$)/.test(path)) return true;
  // MCP sign-in tokens belong to this machine's browser sign-ins.
  if (/^mcp-oauth\.json(?:$|\.\d+\.[0-9a-f-]+\.tmp$)/.test(path)) return true;
  return /^(?:(?:providers|caddy|chrome-profile|\.agent-browser)(?:\/|$)|workspace-credentials\.json$|external-runtimes\.json$|browser-engine-key$)/.test(path) ||
    /^(?:config\.json|webhooks\.json|workspace-credentials\.json|external-runtimes\.json|browser-engine-key|sessions\.json|tunnel-account\.json)\.\d+(?:\.[0-9a-f-]+)?\.tmp$/.test(path) ||
    /^(?:vm-home|vm-homes\/[^/]+)\/\.browser-profiles(?:\/|$)/.test(path);
}

/** The Organization library files Electron main downloads and verifies
 * (docs/desktop-library.md): the catalog, a catalog write in progress, and the
 * cached release files. Main fetches them again from Admin, and sign-out
 * deletes them, so a backup never keeps an Organization's package bytes. The
 * runtime's own `org-library/state.json` and `presets.json` are backed up. Like
 * the hook tokens below, an archive that holds them still restores. */
export function redownloadedOrgLibraryPath(path: string): boolean {
  return /^org-library\/(?:catalog\.json(?:\.[0-9a-f-]{36}\.tmp)?$|blobs(?:\/|$))/.test(path);
}

/** Per-turn engine hook bearers (`hook-tokens/<digest>.token`, written by the
 * Claude driver). They are dead once their turn settles, so they are never
 * exported. Unlike the saved auth paths above they are not refused on import:
 * v0.1.85 did export them, and such a backup must still restore, without them.
 * The same holds for the session registry's open marker: it describes the
 * process that wrote it, so it is never exported or installed, and a restore
 * leaves the destination's own marker where it is (workspace-backup.ts). */
export function ephemeralWorkspaceTokenPath(path: string): boolean {
  return /^(?:hook-tokens(?:\/|$)|sessions\.json\.open$)/.test(path);
}

/** Top-level names a snapshot never carries. The archive itself is made by
 * jac/harness/workspace_backup.jac (EXCLUDED there is authoritative); this
 * copy only sizes a move for cloud-move.ts. Keep the two lists identical. */
export const WORKSPACE_BACKUP_EXCLUDED_NAMES: ReadonlySet<string> = new Set([
  ".backups", "tools", "cache", ".cache", "tmp", ".tmp", "dist-native", "tunnel-runtime",
  ".openmausbot-server-child", "environment-id", "sessions.json", "tunnel-account.json",
  "team-computers.json",
  "openmausbot-server.lease", "box-create-requests.lock", "messages.db-wal", "messages.db-shm",
  "decider-log",
  "cloud-owner.json",
]);
function excludedTopLevel(name: string): boolean {
  return WORKSPACE_BACKUP_EXCLUDED_NAMES.has(name) || excludedWorkspaceAuthPath(name) || name.startsWith("openmausbot-server.lease.") || name.startsWith("box-create-requests.lock.") || /^perm-[A-Za-z0-9_-]+\.sock$/.test(name);
}

/** Whether a snapshot leaves out this workspace-relative path, by the same
 * rules as the export walk (cloud-move.ts sizes a move with it). Symbolic
 * links are the caller's to skip. */
export function omittedFromWorkspaceBackup(path: string): boolean {
  return excludedTopLevel(path.split("/")[0]) || excludedWorkspaceAuthPath(path) || ephemeralWorkspaceTokenPath(path) || redownloadedOrgLibraryPath(path);
}
