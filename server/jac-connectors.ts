// Node-side seam for the Jac connected-apps subsystem (phase 4 of the Jac
// migration). Composio Sessions, the managed broker, the MCP relay, the
// connection inventory, auth links, the marketplace catalog, grant
// validation, the call-time grants verdict and the missing-scope note live
// in jac/harness/connectors.jac. This module owns:
//
//   * the async facade index.ts calls (same names the old composio.ts and
//     connector-verdict.ts exported), over `jacOpUnordered` — connected-app
//     calls wait on Composio for up to 10 minutes and have no ordering
//     contract with routines, so they stay off the serialized op chain;
//   * a sync mirror of the connection mode for the call sites that cannot
//     await (system-prompt builders, capability gates): node's own config
//     plus the broker state the harness reported;
//   * the managed-broker credential the desktop parent sends here. Node
//     keeps it and every op carries it, so a respawned harness never forgets
//     it (the TS module held it in this process's memory too).
//
// The stdio MCP bridge (connector-proxy.ts) stays a node process: provider
// CLIs spawn it per turn, like the phase-3 permission proxy.

import type { AppConfig } from "./config.ts";
import { jacOpUnordered } from "./jac-routines.ts";
import { SPAWNED_PROXIES } from "./proxy-paths.ts";
import type { ConnectorToolGrant } from "../shared/wire.ts";

type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

// ── wire types (were exported by composio.ts / connector-verdict.ts) ──────

export interface ConnectedAccountSummary {
  id: string;
  alias?: string;
  status: string;
}

export interface ConnectorServiceState {
  connected: boolean;
  pending: boolean;
  status: string;
  accounts: ConnectedAccountSummary[];
}

export interface ComposioMcpIntegration {
  command: string;
  args: string[];
  env: Record<string, string>;
}

interface IntegrationContext {
  harnessUrl: string;
  commsToken: string;
  botId: string;
  threadId: string;
  /** undefined is the legacy all-tools bot (no advertisement filtering). */
  connectorTools?: Record<string, ConnectorToolGrant>;
}

export interface ConnectorToolListing {
  name: string;
  description?: string;
}

export interface ToolkitCard {
  slug: string;
  label: string;
  blurb: string;
  logo: string | null;
  noAuth?: boolean;
  domain: string | null;
}

export type CatalogStopReason =
  | "end"
  | "total-reached"
  | "page-stuck"
  | "cursor-repeated"
  | "http-error"
  | "bad-page"
  | "limit";

export interface CatalogPagination {
  items: number;
  totalItems?: number;
  stalled: boolean;
  reason?: CatalogStopReason;
  complete: boolean;
}

export type ConnectorAvailability = "configured" | "unconfigured" | "unreadable";
export type ConnectorSetup = "ready" | "needs-setup" | "service-unavailable";

export type ConnectorCall =
  | { kind: "passthrough" }
  | { kind: "tools"; invoked: string; names: string[] }
  | { kind: "unrecognized"; invoked: string; reason: string };

export interface ConnectorDenial {
  tool: string;
  service: string | null;
  onGrantedService: boolean;
}

export interface ConnectorVerdict {
  allowed: boolean;
  legacy: boolean;
  denials: ConnectorDenial[];
  rule: string;
  /** The model-facing refusal when the verdict denies, else null. */
  refusal: string | null;
}

export interface RelayedMcp {
  status: number;
  bytes: Uint8Array;
  contentType: string;
  transportSessionId?: string;
}

// ── transport ─────────────────────────────────────────────────────────────

const OP_TIMEOUT_MS = 5 * 60_000;
const RELAY_TIMEOUT_MS = 11 * 60_000;

/** The broker credential the desktop parent sent, after the harness
 * validated it: undefined = never sent (env decides), null = cleared. */
let managedAccess: { url: string; token: string } | null | undefined;

function managedArg(): { access: { url: string; token: string } | null } | null {
  return managedAccess === undefined ? null : { access: managedAccess };
}

function cfgArg(cfg: AppConfig): { composio: AppConfig["composio"] | null } {
  return { composio: cfg.composio ?? null };
}

/** Every kwarg is sent explicitly (undefined becomes null): the fused jac
 * binary binds the stringified default for an omitted optional kwarg. */
async function op<T>(name: string, args: Record<string, unknown>, timeoutMs = OP_TIMEOUT_MS): Promise<T> {
  const explicit = Object.fromEntries(Object.entries(args).map(([key, value]) => [key, value ?? null]));
  try {
    return await jacOpUnordered<T>(`connectors_${name}`, explicit, timeoutMs);
  } catch (error) {
    // jacOp names the routines harness; here the subsystem is connected apps.
    if (error instanceof Error && /^routines unavailable/.test(error.message)) {
      error.message = error.message.replace(/^routines unavailable/, "connected apps unavailable");
    }
    throw error;
  }
}

// ── sync mirror: the connection mode ──────────────────────────────────────

/** The harness's reading of OMB_COMPOSIO_BROKER_URL/TOKEN (it inherits this
 * process's env); null until start() answered. */
let envBroker: { ok: boolean; error: string | null } | null = null;

function projectApiKey(cfg: AppConfig): string | null {
  return cfg.composio?.apiKey?.trim() || null;
}

function brokerAvailable(): boolean {
  if (managedAccess !== undefined) return managedAccess !== null;
  if (envBroker?.error) throw new Error(envBroker.error);
  return envBroker?.ok === true;
}

export function connectionMode(cfg: AppConfig): "managed" | "self-hosted" | "unavailable" {
  if (projectApiKey(cfg)) return "self-hosted";
  if (brokerAvailable()) return "managed";
  return "unavailable";
}

export function configured(cfg: AppConfig): boolean {
  return connectionMode(cfg) !== "unavailable";
}

/** Three answers: the desktop shell sets OMB_CREDENTIAL_STORE=unavailable
 * when it could not read credentials.bin this launch. */
export function connectorAvailability(
  cfg: AppConfig,
  storeState: string | undefined = process.env.OMB_CREDENTIAL_STORE,
): ConnectorAvailability {
  if (configured(cfg)) return "configured";
  return storeState === "unavailable" ? "unreadable" : "unconfigured";
}

/** Only the packaged desktop app (OMB_DESKTOP_PARENT=1) registers with the
 * managed service, so only there is a missing service an outage. */
export function connectorSetup(
  cfg: AppConfig,
  desktopManaged: boolean = process.env.OMB_DESKTOP_PARENT === "1",
): ConnectorSetup {
  if (configured(cfg)) return "ready";
  return desktopManaged ? "service-unavailable" : "needs-setup";
}

/** Read the harness's env broker state; safe to call again after a respawn. */
export async function start(): Promise<void> {
  const state = await op<{ env_broker?: boolean; env_error?: string | null }>("state", {});
  envBroker = { ok: state.env_broker === true, error: state.env_error ?? null };
}

// ── managed broker credential (desktop parent → here → every op) ──────────

let accessChain: Promise<unknown> = Promise.resolve();

/** Validate and adopt a broker credential (null clears it). In order. */
export function setManagedBrokerAccess(access: unknown): Promise<void> {
  const applied = accessChain.then(async () => {
    if (access === null) {
      // Nothing to validate; the next op carries the cleared state.
      managedAccess = null;
      return;
    }
    if (!access || typeof access !== "object" || Array.isArray(access)) {
      throw new Error("The connected-apps service credential must be an object");
    }
    const { access: normalized } = await op<{ access: { url: string; token: string } | null }>(
      "set_broker_access",
      { access },
    );
    managedAccess = normalized;
  });
  accessChain = applied.catch(() => undefined);
  return applied;
}

/** The desktop parent's private message. Recognized synchronously (the
 * caller tries other handlers first); validation happens in the harness and
 * a rejected credential is logged exactly like the old synchronous throw. */
export function applyManagedBrokerMessage(message: unknown): boolean {
  if (!message || typeof message !== "object" || Array.isArray(message)) return false;
  const record = message as Record<string, unknown>;
  if (record.type !== "openmausbot:managed-composio" || !Object.hasOwn(record, "access")) return false;
  setManagedBrokerAccess(record.access).catch((error) => {
    console.error(`[desktop-sync] rejected private parent message: ${error instanceof Error ? error.message : String(error)}`);
  });
  return true;
}

// ── async facade ──────────────────────────────────────────────────────────

/** Validate a project key and return one reusable Session for this install. */
export function prepareProjectSession(
  apiKey: string,
  current?: { apiKey?: string; userId?: string; sessionId?: string },
): Promise<{ apiKey: string; userId: string; sessionId: string }> {
  return op("prepare_project_session", { api_key: apiKey, current: current ?? null, managed: managedArg() });
}

export async function mcpIntegration(cfg: AppConfig, context: IntegrationContext): Promise<ComposioMcpIntegration | null> {
  const { integration } = await op<{ integration: ComposioMcpIntegration | null }>("mcp_integration", {
    cfg: cfgArg(cfg),
    context,
    command: process.execPath,
    args: [SPAWNED_PROXIES.connectors],
    managed: managedArg(),
  });
  return integration;
}

/** Relay one JSON-RPC frame to the Session (or managed broker) MCP
 * endpoint. Session discovery runs first; `beforeSend` runs after it and
 * immediately before dispatch, so turn authority and mutable permissions
 * are judged as late as possible. `scopeHintSlugs` are the app tools the
 * call runs, for the missing-OAuth-scope note (MOCA-273). */
export async function relayMcp(
  cfg: AppConfig,
  payload: JsonValue,
  transportSessionId?: string,
  beforeSend?: () => void | Promise<void>,
  scopeHintSlugs: readonly string[] = [],
): Promise<RelayedMcp> {
  const { handle } = await op<{ handle: string }>("relay_target", {
    cfg: cfgArg(cfg),
    transport_session_id: transportSessionId ?? null,
    managed: managedArg(),
  });
  await beforeSend?.();
  const sent = await op<{ status: number; body_b64: string; content_type: string; transport_session_id?: string | null }>(
    "relay_send",
    { handle, payload, scope_hint_slugs: [...scopeHintSlugs] },
    RELAY_TIMEOUT_MS,
  );
  return {
    status: sent.status,
    bytes: new Uint8Array(Buffer.from(sent.body_b64, "base64")),
    contentType: sent.content_type,
    transportSessionId: sent.transport_session_id ?? undefined,
  };
}

export async function connectedServices(cfg: AppConfig): Promise<Record<string, ConnectorServiceState>> {
  return (await op<{ services: Record<string, ConnectorServiceState> }>("connected_services", { cfg: cfgArg(cfg), managed: managedArg() })).services;
}

export async function connectedServiceSlugs(cfg: AppConfig): Promise<readonly string[]> {
  return (await op<{ slugs: string[] }>("connected_service_slugs", { cfg: cfgArg(cfg), managed: managedArg() })).slugs;
}

/** Semantic validation for a connectorTools patch: the rejection or null. */
export async function validateConnectorGrants(
  cfg: AppConfig,
  grants: Record<string, ConnectorToolGrant>,
): Promise<string | null> {
  return (await op<{ error: string | null }>("validate_grants", { cfg: cfgArg(cfg), grants, managed: managedArg() })).error;
}

export async function listConnectorTools(
  cfg: AppConfig,
  options: { force?: boolean } = {},
): Promise<Record<string, ConnectorToolListing[]>> {
  return (await op<{ services: Record<string, ConnectorToolListing[]> }>("list_tools", {
    cfg: cfgArg(cfg),
    force: options.force === true,
    managed: managedArg(),
  })).services;
}

/** Status per requested slug (keys as given, `x` included); null asks for
 * the curated marketplace slugs. */
export async function connectionStatus(cfg: AppConfig, slugs: string[] | null): Promise<Record<string, ConnectorServiceState>> {
  return (await op<{ services: Record<string, ConnectorServiceState> }>("connection_status", {
    cfg: cfgArg(cfg),
    slugs,
    managed: managedArg(),
  })).services;
}

export function removeService(cfg: AppConfig, slug: string): Promise<{ removed: number }> {
  return op("remove_service", { cfg: cfgArg(cfg), slug, managed: managedArg() });
}

export function removeAccount(cfg: AppConfig, slug: string, accountId: string): Promise<{ removed: number }> {
  return op("remove_account", { cfg: cfgArg(cfg), slug, account_id: accountId, managed: managedArg() });
}

export function authorizeService(cfg: AppConfig, slug: string, requestedAlias?: unknown): Promise<{ url: string }> {
  return op("authorize", { cfg: cfgArg(cfg), slug, alias: requestedAlias ?? null, managed: managedArg() });
}

export function listToolkits(cfg: AppConfig): Promise<{ cards: ToolkitCard[]; source: "api" | "curated"; pagination?: CatalogPagination }> {
  return op("list_toolkits", { cfg: cfgArg(cfg), managed: managedArg() });
}

export async function toolkitCard(cfg: AppConfig, slug: string): Promise<ToolkitCard> {
  return (await op<{ card: ToolkitCard }>("toolkit_card", { cfg: cfgArg(cfg), slug, managed: managedArg() })).card;
}

export async function normalizeAccountAlias(value: unknown): Promise<string | undefined> {
  return (await op<{ alias: string | null }>("normalize_alias", { value: value ?? null })).alias ?? undefined;
}

/** Classify one relayed frame; `refusal` is the model-facing text for an
 * unrecognized shape. */
export async function connectorCallFromFrame(frame: unknown): Promise<{ call: ConnectorCall; refusal: string | null }> {
  return op("classify_call", { frame: frame ?? null });
}

/** Judge distinct target names against a bot's grants (undefined = the
 * legacy all-tools bot) and the connected-service slugs. */
export function evaluateConnectorTools(
  names: string[],
  grants: Record<string, ConnectorToolGrant> | undefined,
  candidates: readonly string[] = [],
): Promise<ConnectorVerdict> {
  return op("evaluate", { names, grants: grants ?? null, legacy: grants === undefined, candidates: [...candidates] });
}
