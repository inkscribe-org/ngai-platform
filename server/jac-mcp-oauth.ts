// Node-side seam for MCP OAuth sign-in (phase 4 of the Jac migration). The
// manager, its token store (mcp-oauth.json), discovery and the loopback
// callback listener live in jac/harness/mcp_oauth.jac. This module owns the
// async facade and a synchronous read mirror of each server's sign-in state
// for the call sites that cannot await (the MCP server listing, the turn
// prompt's server list, engineMcpServers).
//
// Ops go through jacOpUnordered, not the serialized routine chain: a sign-in
// waits on the network (discovery, registration, a token refresh at turn
// start) and must never stall the scheduler. The Jac side is lock-guarded.
// Emit frames ({kind:"mcp.oauth", name, url, auth}) arrive through the
// routines `emit` bridge op and are applied here — never broadcast.

import type { McpServerSpec } from "./contracts.ts";
import { jacOpUnordered, jacUnavailable } from "./jac-routines.ts";

export type McpSignInPhase = "waiting" | "succeeded" | "failed" | "cancelled" | "expired";

export interface McpSignInStatus {
  phase: McpSignInPhase;
  flowId: string;
  authorizationUrl: string | null;
  expiresAt: string;
  message?: string;
}

export type McpAuthState = "signed-in" | "needs-sign-in" | "none";

/** A failed op: `status` is the HTTP answer (400/404/409 for a sign-in the
 * person can act on, 502 when a sign-in could not start, 503 when the
 * harness is down); `code` is set for "not-oauth" | "no-registration" |
 * "port-busy". */
export interface McpOAuthOpError extends Error {
  status?: number;
  code?: string;
}

// ── read mirror ──────────────────────────────────────────────────────────

const mirror = new Map<string, { url: string; auth: Exclude<McpAuthState, "none"> }>();

/** Apply one emit payload. Returns false for frames this mirror ignores. */
export function mcpOAuthMirrorApplyFrame(payload: Record<string, unknown>): boolean {
  if (payload.kind !== "mcp.oauth" || typeof payload.name !== "string") return false;
  if ((payload.auth === "signed-in" || payload.auth === "needs-sign-in") && typeof payload.url === "string") {
    mirror.set(payload.name, { url: payload.url, auth: payload.auth });
  } else {
    mirror.delete(payload.name);
  }
  return true;
}

async function mirrorRefresh(): Promise<void> {
  const { states } = await jacOpUnordered<{ states?: Record<string, { url: string; auth: McpAuthState }> }>("mcp_oauth_states");
  mirror.clear();
  for (const [name, state] of Object.entries(states ?? {})) {
    if (state.auth === "signed-in" || state.auth === "needs-sign-in") mirror.set(name, { url: state.url, auth: state.auth });
  }
}

/** A server's sign-in state at this URL, from the mirror. */
export function mcpAuthState(name: string, url: string): McpAuthState {
  const state = mirror.get(name);
  return state && state.url === url ? state.auth : "none";
}

const isUrlServer = (server: McpServerSpec): server is Extract<McpServerSpec, { url: string }> => "url" in server;

/** The servers a turn may mount: a URL server waiting for sign-in would
 * only answer 401 mid-turn, so it stays out until someone signs in. */
export function withoutPendingSignIn(servers: Record<string, McpServerSpec>): Record<string, McpServerSpec> {
  return Object.fromEntries(Object.entries(servers).filter(([name, server]) =>
    !isUrlServer(server) || mcpAuthState(name, server.url) !== "needs-sign-in"));
}

/** The redirect URI a sign-in for this server uses, to register with an app
 * made in advance for it. Same FNV-1a port as mcp_oauth.jac preferred_port
 * (its test pins these vectors); kept here because the listing is sync. */
export function mcpOAuthRedirectUri(url: string): string {
  let hash = 0x811c9dc5;
  for (const char of url) {
    hash ^= char.charCodeAt(0);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return `http://127.0.0.1:${20_000 + (hash % 20_000)}/mcp-oauth/callback`;
}

// ── facade ───────────────────────────────────────────────────────────────

/** Housekeeping that must never wait out a harness (re)boot — a logout, a
 * listing, a turn's start: skipped (the fallback) unless the harness is up. */
function whenUp<T>(run: () => Promise<T>, fallback: T): Promise<T> {
  return jacUnavailable() ? Promise.resolve(fallback) : run();
}

export const jacMcpOAuth = {
  /** Load the mirror; safe to call again (another process may have written
   * mcp-oauth.json, which the Jac side reads through on every call). */
  refresh: () => whenUp(mirrorRefresh, undefined),

  start: async (name: string, url: string, owner: string): Promise<McpSignInStatus> =>
    (await jacOpUnordered<{ auth: McpSignInStatus }>("mcp_oauth_start", { name, url, owner, www_authenticate: null })).auth,

  status: async (name: string, flowId: string, owner: string): Promise<McpSignInStatus | undefined> =>
    (await jacOpUnordered<{ auth: McpSignInStatus | null }>("mcp_oauth_status", { name, flow_id: flowId, owner })).auth ?? undefined,

  cancelFlow: async (name: string, owner: string, flowId: string | undefined): Promise<void> => {
    await jacOpUnordered("mcp_oauth_cancel_flow", { name, owner, flow_id: flowId ?? null });
  },

  completeCallback: async (name: string, flowId: string, callbackUrl: string, owner: string): Promise<McpSignInStatus> =>
    (await jacOpUnordered<{ auth: McpSignInStatus }>("mcp_oauth_complete", { name, flow_id: flowId, callback_url: callbackUrl, owner })).auth,

  revokeOwner: (owner: string): Promise<void> =>
    whenUp(async () => { await jacOpUnordered("mcp_oauth_revoke_owner", { owner }); }, undefined),

  signOut: async (name: string, url: string): Promise<void> => {
    await jacOpUnordered("mcp_oauth_sign_out", { name, url });
  },

  forget: async (name: string): Promise<void> => {
    await jacOpUnordered("mcp_oauth_forget", { name });
  },

  markNeedsSignIn: async (name: string, url: string): Promise<void> => {
    await jacOpUnordered("mcp_oauth_mark_needs_sign_in", { name, url });
  },

  /** Give each signed-in URL server a fresh bearer token, replacing any
   * Authorization header it was configured with; a server whose token can
   * no longer be had is left out. With no signed-in server in the mirror
   * this is withoutPendingSignIn, without a round trip. If the harness is
   * down, signed-in servers are left out (they would only answer 401). */
  withSignIn: async (servers: Record<string, McpServerSpec>): Promise<Record<string, McpServerSpec>> => {
    const pending = withoutPendingSignIn(servers);
    const signedIn = Object.entries(pending).some(([name, server]) => isUrlServer(server) && mcpAuthState(name, server.url) === "signed-in");
    if (!signedIn) return pending;
    const unsigned = () => Object.fromEntries(Object.entries(pending).filter(([name, server]) =>
      !isUrlServer(server) || mcpAuthState(name, server.url) !== "signed-in"));
    if (jacUnavailable()) return unsigned();
    try {
      return (await jacOpUnordered<{ servers: Record<string, McpServerSpec> }>("mcp_oauth_with_sign_in", { servers: pending })).servers;
    } catch {
      return unsigned();
    }
  },

  /** Whether a 401 from this URL leads to a usable OAuth sign-in, bounded
   * by `timeoutMs` across the whole discovery. */
  offersSignIn: (url: string, wwwAuthenticate: string | null, timeoutMs: number): Promise<boolean> =>
    whenUp(async () => (await jacOpUnordered<{ meta: unknown }>(
      "mcp_oauth_discover", { url, www_authenticate: wwwAuthenticate, timeout_ms: timeoutMs },
    )).meta != null, false),

  dispose: (): Promise<void> => whenUp(async () => { await jacOpUnordered("mcp_oauth_dispose"); }, undefined),
};

export type JacMcpOAuth = typeof jacMcpOAuth;
