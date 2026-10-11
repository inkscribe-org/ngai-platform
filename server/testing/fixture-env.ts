// The Jac side of a spawned fixture server's environment.
//
// Fixture servers run with HOME redirected into a throwaway directory, so
// left to themselves they resolve no jac binary (CI: "routines unavailable"
// 503s) or an unpinned one, and re-extract the ~830MB jac runtime into the
// throwaway they are about to delete. Every env a test builds for a spawned
// server spreads this in, exactly like control-omb's
// verificationServerEnvironment does.

import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { operatorJacEnv } from "../jac-binary.ts";

/**
 * Jac-sidecar environment entries a fixture server inherits: the operator's
 * pinned binary, the operator's warm runtime cache, a stable tmpdir for the
 * embedded Postgres daemon's socket, and the driver-kind gate.
 */
export function jacFixtureEnv(env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const operator = operatorJacEnv(env);
  const drivers = env.OMB_JAC_DRIVERS?.trim();
  // Jac's embedded Postgres daemon is shared machine-wide and outlives any
  // one fixture; its socket dir lives under <cache>/jac/tmp (see
  // jac-routines.ts's jacSharedTmpdir). A TMPDIR inside a fixture's own
  // sandbox would be deleted at teardown and orphan the daemon — every
  // subsequent boot would block 60s then fail (ENOENT).
  const jacTmp = join(operator.XDG_CACHE_HOME, "jac", "tmp");
  try {
    mkdirSync(jacTmp, { recursive: true });
  } catch { /* jac creates it at harness spawn */ }
  return {
    ...(operator.OMB_JAC_BIN ? { OMB_JAC_BIN: operator.OMB_JAC_BIN } : {}),
    XDG_CACHE_HOME: operator.XDG_CACHE_HOME,
    ...(drivers ? { OMB_JAC_DRIVERS: drivers } : {}),
    TMPDIR: jacTmp,
  };
}

/**
 * Whether a spawned fixture server would get a working jac sidecar: the
 * same resolution `jacFixtureEnv` performs found a binary that exists.
 * Suites that need the harness mark themselves `skipIf(!jacAvailable())`
 * on runners without jac — one resolution, never a second one here.
 */
export function jacAvailable(env: NodeJS.ProcessEnv = process.env): boolean {
  const bin = operatorJacEnv(env).OMB_JAC_BIN;
  return typeof bin === "string" && existsSync(bin);
}
