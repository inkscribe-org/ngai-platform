import { afterAll, beforeAll, describe, expect, it } from "vitest";

import {
  advertisedWebhookBase,
  listenWebhookIngress,
  MAX_WEBHOOK_BODY_BYTES,
  webhookCredential,
  type WebhookEvent,
  type WebhookIngress,
  type WebhookReceiver,
} from "./webhook-ingress.ts";
import { WorkspaceBackupMaintenance } from "./workspace-backup-maintenance.ts";

// Transport-only fake: the manager semantics (dedup, verification capture,
// rolling 401 record, rejection bookkeeping) are pinned by
// jac/harness/webhooks.test.jac against the real Jac implementation.
interface FakeReceiver extends WebhookReceiver {
  queued: WebhookEvent[];
  rejected: Array<{ status: number; reason: string }>;
  unauthorized: number;
}

function fakeReceiver(endpoint: string, key: string): FakeReceiver {
  const seen = new Map<string, string>();
  const receiver: FakeReceiver = {
    queued: [],
    rejected: [],
    unauthorized: 0,
    authorize: async (endpointId, secret) => {
      const ok = endpointId === endpoint && secret === key;
      if (!ok) receiver.unauthorized += 1;
      return ok;
    },
    receive: async (_endpointId, _secret, event) => {
      const prior = event.deliveryId ? seen.get(event.deliveryId) : undefined;
      if (prior) return { runId: prior, deliveryId: event.deliveryId!, duplicate: true };
      receiver.queued.push(event);
      const runId = `run-${receiver.queued.length}`;
      if (event.deliveryId) seen.set(event.deliveryId, runId);
      return { runId, deliveryId: event.deliveryId ?? runId, duplicate: false };
    },
    recordRejected: async (_endpointId, status, reason) => {
      receiver.rejected.push({ status, reason });
    },
  };
  return receiver;
}

let ingress: WebhookIngress;
const endpointId = "wh_testendpoint";
const secret = "whsec_test/secret";
let manager: FakeReceiver;

beforeAll(async () => {
  manager = fakeReceiver(endpointId, secret);
  ingress = await listenWebhookIngress(manager, { port: 0 });
});

afterAll(async () => {
  await new Promise<void>((resolve) => ingress.server.close(() => resolve()));
});

describe("webhook-only ingress", () => {
  it("does not record or enqueue incoming webhooks during workspace backup", async () => {
    const gate = new WorkspaceBackupMaintenance();
    const guarded = await listenWebhookIngress(manager, { port: 0, claimRequest: () => gate.request() });
    const beforeQueued = manager.queued.length;
    const beforeUnauthorized = manager.unauthorized;
    try {
      await gate.run(async () => {
        const response = await fetch(`${guarded.baseUrl}/hooks/${endpointId}/${encodeURIComponent(secret)}`, { method: "POST", body: "{}" });
        expect(response.status).toBe(503);
        expect(manager.queued).toHaveLength(beforeQueued);
        expect(manager.unauthorized).toBe(beforeUnauthorized);
      }, { idle: () => true, pause: () => {}, resume: () => {}, flush: async () => {} });
    } finally {
      await new Promise<void>((resolve) => guarded.server.close(() => resolve()));
    }
  });

  it("exposes health but nothing from the main OpenMausBot API", async () => {
    const health = await fetch(`${ingress.baseUrl}/health`);
    expect(health.status).toBe(200);
    expect(await health.json()).toEqual({ app: "openmausbot-webhooks", ready: true });
    expect((await fetch(`${ingress.baseUrl}/api/bots`)).status).toBe(404);
  });

  it("accepts capability URLs and passes delivery metadata through", async () => {
    const credential = webhookCredential(ingress.baseUrl, endpointId, secret);
    const send = () => fetch(credential.url, {
      method: "POST",
      headers: { "content-type": "application/json", "idempotency-key": "delivery-1", "x-github-event": "push" },
      body: JSON.stringify({ ref: "main", id: "event-in-body" }),
    });
    const first = await send();
    expect(first.status).toBe(202);
    expect(await first.json()).toMatchObject({ accepted: true, duplicate: false, runId: "run-1" });
    const retry = await send();
    expect(await retry.json()).toMatchObject({ accepted: true, duplicate: true, runId: "run-1" });
    expect(manager.queued[0]).toMatchObject({
      payload: { ref: "main", id: "event-in-body" },
      contentType: "application/json",
      eventName: "push",
      deliveryId: "delivery-1",
    });
  });

  it("also accepts a bearer secret and parses form bodies", async () => {
    const response = await fetch(`${ingress.baseUrl}/hooks/${endpointId}`, {
      method: "POST",
      headers: { authorization: `Bearer ${secret}`, "content-type": "application/x-www-form-urlencoded" },
      body: "ticket=42&priority=high",
    });
    expect(response.status).toBe(202);
    expect(manager.queued.at(-1)?.payload).toEqual({ ticket: "42", priority: "high" });
  });

  it("rejects invalid credentials before reading the body, and records malformed JSON and oversized bodies", async () => {
    const before = manager.unauthorized;
    const unauthorized = await fetch(`${ingress.baseUrl}/hooks/${endpointId}/wrong`, { method: "POST", body: "{}" });
    expect(unauthorized.status).toBe(401);
    expect(manager.unauthorized).toBe(before + 1);

    const malformed = await fetch(`${ingress.baseUrl}/hooks/${endpointId}/${encodeURIComponent(secret)}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{",
    });
    expect(malformed.status).toBe(400);

    const oversized = await fetch(`${ingress.baseUrl}/hooks/${endpointId}/${encodeURIComponent(secret)}`, {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: "x".repeat(MAX_WEBHOOK_BODY_BYTES + 1),
    });
    expect(oversized.status).toBe(413);
    expect(manager.rejected.map((entry) => entry.status)).toEqual([400, 413]);
  });

  it("answers a malformed escape in the URL secret with 401, not 500", async () => {
    const response = await fetch(`${ingress.baseUrl}/hooks/${endpointId}/%E0%A4%A`, { method: "POST", body: "{}" });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "Invalid webhook URL or secret" });
  });
});

describe("advertised base URL", () => {
  it("hands senders the public base instead of the loopback listener", async () => {
    const proxied = await listenWebhookIngress(manager, { port: 0, publicBaseUrl: "https://bots.example.com/" });
    try {
      expect(proxied.baseUrl).toBe("https://bots.example.com");
      expect(proxied.host).toBe("127.0.0.1");
      const credential = webhookCredential(proxied.baseUrl, endpointId, secret);
      expect(credential.endpointUrl).toBe(`https://bots.example.com/hooks/${endpointId}`);
      // the listener itself is still local: the public base only changes what is advertised
      const health = await fetch(`http://127.0.0.1:${proxied.port}/health`);
      expect(health.status).toBe(200);
    } finally {
      await new Promise<void>((resolve) => proxied.server.close(() => resolve()));
    }
  });

  it("refuses a base that is not an absolute http(s) URL, naming the fix", () => {
    for (const bad of ["bots.example.com", "ftp://bots.example.com", "", "/hooks"]) {
      expect(() => advertisedWebhookBase(bad)).toThrow(/absolute http\(s\) URL such as https:\/\//);
    }
    expect(advertisedWebhookBase("http://10.0.0.5:8800///")).toBe("http://10.0.0.5:8800");
  });
});
