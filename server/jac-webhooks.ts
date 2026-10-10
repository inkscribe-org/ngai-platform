// Node-side seam for the Jac webhooks subsystem (phase 4 of the Jac
// migration). WebhookManager, webhooks.json and the delivery/attempt
// bookkeeping live in jac/harness/webhooks.jac; its run queue calls go
// straight to routines.jac in-process. This module owns the async facade
// over the serialized `jacOp` queue and a synchronous read mirror for the
// call sites that cannot await (audit snapshots, visibility filters,
// bot-summary builders). Emit frames ({kind:"webhook"|"webhook.deleted"|
// "webhook.attempt"}) arrive through the routines `emit` bridge op, which
// applies them here before broadcasting — the same mirror-first rule as
// jac-routines.ts.

import type { WebhookAttempt, WebhookTrigger } from "../shared/webhooks.ts";
import type { JsonValue } from "./schema.ts";
import { jacOp } from "./jac-routines.ts";
import type { WebhookReceiveResult, WebhookReceiver } from "./webhook-ingress.ts";

// ── read mirror ──────────────────────────────────────────────────────────

const mirrorHooks = new Map<string, WebhookTrigger>(); // newest first, like the file
let mirrorAttempts: WebhookAttempt[] = [];

function mirrorPut(webhook: WebhookTrigger): void {
  if (!mirrorHooks.has(webhook.id)) {
    // New triggers are unshifted in the manager; keep that order.
    const rest = [...mirrorHooks.entries()];
    mirrorHooks.clear();
    mirrorHooks.set(webhook.id, webhook);
    for (const [id, hook] of rest) mirrorHooks.set(id, hook);
  } else {
    mirrorHooks.set(webhook.id, webhook);
  }
}

function mirrorPutAttempt(attempt: WebhookAttempt): void {
  const at = mirrorAttempts.findIndex((candidate) => candidate.id === attempt.id);
  if (at === -1) mirrorAttempts.push(attempt);
  else mirrorAttempts[at] = attempt; // the rolling 401 record is replaced in place
}

/** Apply one emit payload. Returns false for frames this mirror ignores. */
export function webhookMirrorApplyFrame(payload: Record<string, unknown>): boolean {
  if (payload.kind === "webhook" && payload.webhook !== null && typeof payload.webhook === "object") {
    mirrorPut(payload.webhook as WebhookTrigger);
    return true;
  }
  if (payload.kind === "webhook.deleted" && typeof payload.webhookId === "string") {
    mirrorHooks.delete(payload.webhookId);
    mirrorAttempts = mirrorAttempts.filter((attempt) => attempt.webhookId !== payload.webhookId);
    return true;
  }
  if (payload.kind === "webhook.attempt" && payload.attempt !== null && typeof payload.attempt === "object") {
    mirrorPutAttempt(payload.attempt as WebhookAttempt);
    return true;
  }
  return false;
}

async function mirrorRefresh(): Promise<void> {
  const listed = await jacOp<{ webhooks?: WebhookTrigger[]; attempts?: WebhookAttempt[] }>("webhook_list");
  mirrorHooks.clear();
  for (const hook of listed.webhooks ?? []) mirrorHooks.set(hook.id, hook);
  mirrorAttempts = listed.attempts ?? [];
}

// ── facade ───────────────────────────────────────────────────────────────

export interface CreatedWebhook {
  webhook: WebhookTrigger;
  secret: string;
}

export const jacWebhooks = {
  /** Load the mirror once the harness answers; safe to call again after a
   * harness respawn (the file is the source of truth). */
  start: () => mirrorRefresh(),

  /** Synchronous reads, from the mirror. */
  list: (): WebhookTrigger[] => [...mirrorHooks.values()].map((hook) => structuredClone(hook)),
  listAttempts: (): WebhookAttempt[] => mirrorAttempts.map((attempt) => ({ ...attempt })),

  create: async (input: JsonValue): Promise<CreatedWebhook> => {
    const created = await jacOp<CreatedWebhook>("webhook_create", { input });
    mirrorPut(created.webhook);
    return created;
  },

  update: async (id: string, patch: JsonValue): Promise<WebhookTrigger | null> => {
    const { webhook } = await jacOp<{ webhook: WebhookTrigger | null }>("webhook_update", { id, patch });
    if (webhook) mirrorPut(webhook);
    return webhook;
  },

  remove: async (id: string): Promise<boolean> => {
    const { removed } = await jacOp<{ removed: boolean }>("webhook_remove", { id });
    if (removed) webhookMirrorApplyFrame({ kind: "webhook.deleted", webhookId: id });
    return removed;
  },

  rotateSecret: async (id: string): Promise<CreatedWebhook | null> => {
    const rotated = await jacOp<{ webhook: WebhookTrigger | null; secret?: string }>("webhook_rotate", { id });
    if (!rotated.webhook || !rotated.secret) return null;
    mirrorPut(rotated.webhook);
    return { webhook: rotated.webhook, secret: rotated.secret };
  },

  disableForBot: async (botId: string): Promise<void> => {
    await jacOp("webhook_disable_for_bot", { bot_id: botId });
  },

  test: async (id: string, payload: JsonValue | undefined): Promise<WebhookReceiveResult | null> =>
    (await jacOp<{ result: WebhookReceiveResult | null }>("webhook_test", { id, payload: payload ?? null })).result,
};

/** The ingress listener's view: authorize records the rolling 401 attempt
 * itself, so a bad capability URL costs one op and no body buffering. */
export const jacWebhookReceiver: WebhookReceiver = {
  authorize: async (endpointId, secret, event) =>
    (await jacOp<{ authorized: boolean }>("webhook_authorize", { endpoint_id: endpointId, secret, event })).authorized,
  receive: async (endpointId, secret, event) =>
    (await jacOp<{ result: WebhookReceiveResult }>("webhook_receive", { endpoint_id: endpointId, secret, event })).result,
  recordRejected: async (endpointId, status, reason, event) => {
    await jacOp("webhook_record_rejected", { endpoint_id: endpointId, status, reason, event });
  },
};

export type JacWebhooks = typeof jacWebhooks;
