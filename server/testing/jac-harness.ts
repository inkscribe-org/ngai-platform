// In-process tests that call a Jac facade (server/jac-*.ts) spawn the real
// harness through jac-routines.ts. setup.ts has redirected HOME into a
// throwaway directory, so point the spawn at the operator's pinned jacup
// binary and jac runtime cache, the way index.test.ts forwards them.
import { operatorJacEnv } from "../jac-binary.ts";
import { ensureJacHarness, stopJacHarness } from "../jac-routines.ts";

export function useOperatorJac(): string | null {
  const env = operatorJacEnv();
  process.env.XDG_CACHE_HOME = env.XDG_CACHE_HOME;
  if (env.OMB_JAC_BIN) process.env.OMB_JAC_BIN = env.OMB_JAC_BIN;
  return env.OMB_JAC_BIN ?? null;
}

/** Boot the harness once for a test file (call from beforeAll with a long
 * timeout); throws when it cannot come up so failures name the cause. */
export async function startTestJacHarness(): Promise<string> {
  if (!useOperatorJac()) throw new Error("no jac binary: install jacup (jac/harness/jac.toml pins the version)");
  const url = await ensureJacHarness();
  if (!url) throw new Error("the Jac harness did not become ready");
  return url;
}

export { stopJacHarness };
