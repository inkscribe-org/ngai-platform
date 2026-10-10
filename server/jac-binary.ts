// Which `jac` executable runs the harness. Side-effect free so scripts
// (scripts/control-omb.ts fixtures) and the server share one answer.

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const HARNESS_TOML = fileURLToPath(new URL("../jac/harness/jac.toml", import.meta.url));

/** OMB_JAC_BIN as given, else the jacup install pinned by
 * jac/harness/jac.toml (`jac-version`), else the newest jacup install, else
 * `jac` on PATH. A jacup version other than the pin compiles a different
 * prepare-cache slot and recompiles from scratch on every boot. Never
 * throws — a sealed or bare PATH simply means "not available". */
export function resolveJacBinary(env: NodeJS.ProcessEnv = process.env, home: string = homedir()): string | null {
  const explicit = env.OMB_JAC_BIN?.trim();
  if (explicit) return explicit;
  try {
    const versionsDir = join(home, ".local", "share", "jacup", "versions");
    const versions = readdirSync(versionsDir)
      .filter((entry) => /^\d+\.\d+\.\d+/.test(entry))
      .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
    try {
      const pinned = readFileSync(HARNESS_TOML, "utf8").match(/^jac-version\s*=\s*"(\d+\.\d+\.\d+)"/m)?.[1];
      if (pinned && versions.includes(pinned) && existsSync(join(versionsDir, pinned, "jac"))) {
        return join(versionsDir, pinned, "jac");
      }
    } catch { /* missing toml falls through to newest */ }
    for (const version of versions) {
      const candidate = join(versionsDir, version, "jac");
      if (existsSync(candidate)) return candidate;
    }
  } catch { /* no jacup install */ }
  try {
    const found = execFileSync("which", ["jac"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], env }).trim();
    if (found) return found.split("\n", 1)[0]!;
  } catch { /* `which` missing or jac absent */ }
  return null;
}

/** For processes whose HOME was redirected into a throwaway directory
 * (vitest's setup, verification fixtures): the operator's pinned binary and
 * jac runtime cache (the ~830MB extraction and the shared Postgres socket
 * dir), resolved from the account's real home. */
export function operatorJacEnv(env: NodeJS.ProcessEnv = process.env): { OMB_JAC_BIN?: string; XDG_CACHE_HOME: string } {
  const home = userInfo().homedir;
  const bin = resolveJacBinary(env, home);
  return { ...(bin ? { OMB_JAC_BIN: bin } : {}), XDG_CACHE_HOME: env.XDG_CACHE_HOME || join(home, ".cache") };
}
