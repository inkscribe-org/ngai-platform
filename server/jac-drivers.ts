// Node-side seam for drivers implemented in the Jac harness (phase 3 of the
// Jac migration). A Jac-backed driver keeps the inner TypeScript driver for
// everything declarative — driverKind, metadata, install descriptor, model
// catalog, config decode — and replaces only `create()`: the returned
// ProviderInstance forwards the whole ProviderAdapter surface over the
// serialized `jacOp` queue (server/jac-routines.ts), exactly the transport
// routines already use.
//
// Events flow the other way: driver code in Jac posts each RuntimeEvent to
// the node bridge as op `driver_event`, which calls the shim adapter's
// registered listeners. The shim is attached to the same EventBus as every
// other instance, so stamping (providerInstanceId), delta merging, the
// per-thread ndjson tee and the SSE fanout are all the unchanged node path —
// an event emitted by Jac is byte-identical downstream to one emitted
// in-process.
//
// Ordering: Jac's emit is synchronous HTTP per event, in emission order, so
// listener order is preserved. Bridge handlers never re-enter jacOp
// (jac-routines.ts deadlock rule); state the adapter must answer
// synchronously (hasSession) lives in the mirror below, updated by events
// before listeners see them — the same "mirror first" rule as routines.
//
// Enablement: OMB_JAC_DRIVERS is a comma list of driver kinds to route to
// the Jac harness ("all" for every kind Jac implements). Unset kinds keep
// their TypeScript driver; OMB_JAC=0 disables the whole seam. An enabled
// kind whose Jac side is unreachable fails create() → the registry records
// an unavailable shadow, never a silent TS fallback (that would fork
// semantics between processes).

import type {
  AnyProviderDriver,
  RuntimeEvent,
  RuntimeEventListener,
  ThreadId,
  ProviderDriver,
  ProviderInstance,
  ProviderSnapshot,
  SendTurnInput,
  SteerOutcome,
  TextGenerationOptions,
  TurnStartResult,
} from "./contracts.ts";
import { jacEnabled, jacOp } from "./jac-routines.ts";

/** Kinds the Jac harness should serve. Comma-separated; "all" opts in every
 * kind — Jac answers "unknown kind" for ones it doesn't implement yet. */
export function jacDriverKinds(): Record<string, true> | "all" | null {
  if (!jacEnabled()) return null;
  const raw = process.env.OMB_JAC_DRIVERS?.trim();
  if (!raw) return null;
  if (raw === "all") return "all";
  const kinds: Record<string, true> = {};
  for (const k of raw.split(",").map((k) => k.trim()).filter(Boolean)) kinds[k] = true;
  return kinds;
}

// ── sync mirrors ───────────────────────────────────────────────────────────
// adapter.hasSession is synchronous; the Jac side owns the live sessions, so
// session boundaries mirror here off the event stream before listeners run.
// hasSession means "a turn process is live for this thread" (the TS claude
// driver reads `active.has(threadId)`), so we track live turns, not resume
// cursors.

const liveTurns = new Map<string, Set<ThreadId>>(); // instanceId → threadIds
function mirrorEvent(instanceId: string, event: RuntimeEvent): void {
  const threadId = event.threadId;
  if (!threadId) return;
  if (event.type === "turn.started") {
    let set = liveTurns.get(instanceId);
    if (!set) liveTurns.set(instanceId, (set = new Set()));
    set.add(threadId);
  } else if (event.type === "turn.completed" || event.type === "session.exited") {
    liveTurns.get(instanceId)?.delete(threadId);
  }
}

// ── event delivery (bridge op `driver_event` calls this) ──────────────────

const listenersByInstance = new Map<string, Set<RuntimeEventListener>>();

/** Jac → node: deliver one RuntimeEvent to the shim adapter's listeners.
 * Mirror updates run first so a listener's synchronous hasSession reads see
 * the state the event announced. Bridge-safe: never touches jacOp. */
export function jacDriverEvent(instanceId: string, event: RuntimeEvent): { ok: true } {
  mirrorEvent(instanceId, event);
  const listeners = listenersByInstance.get(instanceId);
  if (listeners) {
    for (const listener of [...listeners]) {
      try {
        listener(event);
      } catch (error) {
        console.error("jac-drivers: listener threw:", error instanceof Error ? error.message : String(error));
      }
    }
  }
  return { ok: true };
}

/** Drop everything an instance mirrored (registry dispose path). */
function forgetInstance(instanceId: string): void {
  liveTurns.delete(instanceId);
  listenersByInstance.delete(instanceId);
}

// ── the shim instance ──────────────────────────────────────────────────────

interface DriverError extends Error {
  status?: number;
  code?: string;
}

async function driverOp<T>(op: string, args: Record<string, unknown>): Promise<T> {
  return jacOp<T>(`driver_${op}`, args);
}

function rethrowTyped(error: unknown): never {
  // Jac surfaces typed failures as {ok:false,error,code}; jacOp already
  // threw with .status — re-tag the few codes callers branch on.
  if (error instanceof Error && (error as DriverError).code === undefined) {
    const match = /\[([a-z_]+)\]\s*(.*)$/s.exec(error.message);
    if (match) (error as DriverError).code = match[1];
  }
  throw error;
}

function makeInstance(inner: ProviderInstance, instanceId: string): ProviderInstance {
  const listeners = new Set<RuntimeEventListener>();
  listenersByInstance.set(instanceId, listeners);
  const adapter = inner.adapter;
  return {
    ...inner,
    // The declarative surface (displayName, models catalog, auth method) is
    // the TS driver's; behavior is Jac's.
    snapshot: async () => {
      try {
        return await driverOp<ProviderSnapshot>("snapshot", { instance_id: instanceId });
      } catch (error) {
        console.error(`jac-drivers: snapshot ${instanceId}:`, error instanceof Error ? error.message : String(error));
        return inner.snapshot();
      }
    },
    adapter: {
      ...adapter,
      sendTurn: async (turn: SendTurnInput): Promise<TurnStartResult> => {
        try {
          const result = await driverOp<{ turn_id?: string; turnId?: string }>("send_turn", {
            instance_id: instanceId,
            turn,
          });
          const turnId = result.turnId ?? result.turn_id;
          if (typeof turnId !== "string" || !turnId) {
            throw new Error("jac driver answered sendTurn without a turnId");
          }
          return { turnId };
        } catch (error) {
          rethrowTyped(error);
        }
      },
      interruptTurn: async (threadId: ThreadId, turnId?: string) => {
        try {
          await driverOp("interrupt_turn", { instance_id: instanceId, thread_id: threadId, turn_id: turnId });
        } catch (error) {
          rethrowTyped(error);
        }
      },
      respondToRequest: async (threadId, requestId, decision) => {
        try {
          const result = await driverOp<{ outcome?: string }>("respond", {
            instance_id: instanceId,
            thread_id: threadId,
            request_id: requestId,
            decision,
          });
          const outcome = result.outcome;
          return outcome === "allowed-once" || outcome === "rejected" || outcome === "answered"
            ? outcome
            : "unavailable";
        } catch {
          // fail-closed: an unreachable Jac broker is "no answerer"
          return "unavailable";
        }
      },
      steer: adapter.steer
        ? async (threadId: ThreadId, text: string): Promise<SteerOutcome> => {
            try {
              const result = await driverOp<{ outcome?: string }>("steer", {
                instance_id: instanceId,
                thread_id: threadId,
                text,
              });
              return result.outcome === "steered" || result.outcome === "refused" ? result.outcome : "indeterminate";
            } catch {
              return "indeterminate";
            }
          }
        : undefined,
      hasSession: (threadId: ThreadId) => liveTurns.get(instanceId)?.has(threadId) ?? false,
      stopAll: async () => {
        try {
          await driverOp("stop_all", { instance_id: instanceId });
        } catch (error) {
          rethrowTyped(error);
        }
      },
      onEvent: (listener: RuntimeEventListener) => {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    },
    generateText: inner.generateText
      ? (prompt: string, options?: TextGenerationOptions) =>
          driverOp<{ text?: string }>("generate_text", {
            instance_id: instanceId,
            prompt,
            options,
          }).then((r) => r.text ?? "")
      : undefined,
    reviewPermission: inner.reviewPermission
      ? (prompt: string, _signal?: AbortSignal) =>
          driverOp<{ text?: string }>("review_permission", {
            instance_id: instanceId,
            prompt,
          }).then((r) => r.text ?? "")
      : undefined,
    dispose: async () => {
      try {
        await driverOp("dispose", { instance_id: instanceId });
      } catch (error) {
        console.error(`jac-drivers: dispose ${instanceId}:`, error instanceof Error ? error.message : String(error));
      } finally {
        forgetInstance(instanceId);
      }
    },
  };
}

/** Wrap a TypeScript driver so create() produces a Jac-backed instance.
 * The inner driver still decodes config, owns metadata/install/catalog, and
 * is created once — its declarative instance (snapshot source, capabilities
 * literal, auth surface) stays the node's; only its adapter is swapped for
 * the Jac facade. The inner adapter's own processes never spawn: nothing
 * calls its sendTurn. */
export function jacifyDriver<Config>(driver: ProviderDriver<Config>): AnyProviderDriver {
  return {
    ...driver,
    create: async (input) => {
      const inner = await driver.create(input);
      try {
        await driverOp("create", {
          instance_id: input.instanceId,
          kind: driver.driverKind,
          display_name: input.displayName,
          environment: input.environment,
          enabled: input.enabled,
          config: input.config,
        });
      } catch (error) {
        // The Jac half could not come up — dispose the declarative half and
        // let the registry record an unavailable shadow.
        await inner.dispose().catch(() => {});
        rethrowTyped(error);
      }
      return makeInstance(inner, input.instanceId);
    },
  };
}

/** Map a driver list through jacifyDriver for OMB_JAC_DRIVERS-enabled kinds. */
export function jacifyDrivers(drivers: readonly AnyProviderDriver[]): readonly AnyProviderDriver[] {
  const kinds = jacDriverKinds();
  if (kinds === null) return drivers;
  return drivers.map((d) => (kinds === "all" || kinds[d.driverKind] === true ? jacifyDriver(d) : d));
}
