"""Drivers subsystem — phase 3 of the Jac migration.

Node owns the SPI boundary: a shim ProviderDriver (server/jac-drivers.ts)
forwards adapter calls here over the serialized op queue, and events travel
back over the node bridge as op `driver_event` — the same transport and
ordering rules the routines subsystem uses (jac-routines.ts, routines.jac).

Per-kind logic lives in driver_<kind>.jac modules that register handlers in
_impls at import; ops dispatch on instance["kind"]. Implemented kinds today:
  driver_stub — a seam fixture that replays a scripted event list, so the
    node↔Jac adapter contract is verifiable without a real engine.
"""

import os;
import json;
import time;
import threading;
import uuid;
import urllib.request;

glob _instances: dict[str, any] = {};      # instance_id -> instance record
glob _impls: dict[str, any] = {};          # kind -> dict of callables
# Mutable module state lives in a dict: a def cannot rebind a glob.
#   bridge_fn  — injected callable for tests
#   bridge_url — None unresolved, "" no node
glob _state: dict[str, any] = {"bridge_fn": None, "bridge_url": None};
glob _stub_calls: list[any] = [];

def driver_register_kind(kind: str, impl_fns: dict[str, any]) {
    _impls[kind] = impl_fns;
}

def _now_iso -> str {
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + f".{int(time.time() * 1000) % 1000:03d}Z";
}

def _new_event_id -> str {
    return f"ev-{uuid.uuid4().hex[:12]}";
}

def _guard(omb_token: any) -> dict[str, any] {
    want = os.environ.get("OMB_JAC_TOKEN") or "";
    if want and omb_token != want {
        return {"ok": False, "status": 401, "error": "bad token"};
    }
    return {"ok": True};
}

# ── bridge emit (jac -> node), same contract as routines._bridge ───────────

def _resolve_bridge_url -> any {
    if _state["bridge_url"] is None {
        base = os.environ.get("OMB_ROUTINES_BRIDGE_URL") or os.environ.get("OMB_NODE_URL");
        # 0.37.21 rejects any str stored into a None-initialized glob dict
        # slot (E1001, literal-narrowed per key); dict.update bypasses the
        # subscript-assign narrowing while keeping the None/""/URL semantics.
        _state.update({"bridge_url": (base.rstrip("/") + "/api/internal/routine-bridge") if base else ""});
    }
    return _state["bridge_url"] or None;
}

def _bridge(op: str, payload: dict[str, any]) -> dict[str, any] {
    call = {"op": op};
    call.update(payload);
    bridge_fn = _state["bridge_fn"];
    if bridge_fn is not None {
        _stub_calls.append(call);
        result = bridge_fn(op, payload);
        return result if isinstance(result, dict) else {};
    }
    url = _resolve_bridge_url();
    if url is None {
        _stub_calls.append(call);
        return {"ok": True};
    }
    body = json.dumps(call).encode("utf-8");
    headers = {"content-type": "application/json"};
    token = os.environ.get("OMB_JAC_TOKEN");
    if token {
        headers["x-omb-jac-token"] = token;
    }
    req = urllib.request.Request(url, data=body, headers=headers, method="POST");
    try {
        resp = urllib.request.urlopen(req, timeout=5);
        try {
            raw = resp.read().decode("utf-8");
        } finally {
            resp.close();
        }
        if not raw { return {}; }
        parsed = json.loads(raw);
        return parsed if isinstance(parsed, dict) else {};
    } except Exception as e {
        # A bridge failure must never crash a turn's event path; the fold
        # degrades to "event lost", same as an in-process listener throwing.
        return {"ok": False, "error": str(e)};
    }
}

# ── emit ───────────────────────────────────────────────────────────────────
# Every RuntimeEvent a driver produces goes through emit_event: node stamps
# providerInstanceId at the bus, so drivers must NOT set it. Events carry the
# wire names verbatim (type, threadId, turnId, itemId, requestId, …).

def emit_event(instance: dict[str, any], event: dict[str, any]) {
    if "eventId" not in event {
        event["eventId"] = _new_event_id();
    }
    if "provider" not in event {
        event["provider"] = instance["kind"];
    }
    if "createdAt" not in event {
        event["createdAt"] = _now_iso();
    }
    _bridge("driver_event", {
        "instance_id": instance["instance_id"],
        "event": event,
    });
}

# ── registry + dispatch ────────────────────────────────────────────────────

def _fail(error: str, status: int = 500, code: str = "") -> dict[str, any] {
    out: dict[str, any] = {"ok": False, "status": status};
    if code {
        out["code"] = code;
        out["error"] = f"[{code}] {error}";
    } else {
        out["error"] = error;
    }
    return out;
}

# Shared op preamble: auth, instance lookup, per-kind impl table.
# Returns (inst, impl_fns, None) or (None, None, failure_response).
def _resolve(omb_token: any, instance_id: any) -> tuple[any, any, any] {
    g = _guard(omb_token);
    if not g["ok"] { return (None, None, g); }
    inst = _instances.get(instance_id);
    if inst is None {
        return (None, None, _fail(f"unknown instance {instance_id!r}", 404));
    }
    return (inst, _impls.get(inst["kind"]) or {}, None);
}

# ── ops (re-bound onto harness.jac as driver_*) ────────────────────────────

def:pub driver_create(
    omb_token: any = None,
    instance_id: any = None,
    kind: any = None,
    display_name: any = None,
    environment: any = None,
    enabled: any = True,
    config: any = None
) -> dict[str, any] {
    g = _guard(omb_token);
    if not g["ok"] { return g; }
    if not isinstance(instance_id, str) or not isinstance(kind, str) {
        return _fail("driver_create needs instance_id and kind", 400);
    }
    impl_fns = _impls.get(kind);
    if impl_fns is None {
        return _fail(f"jac harness has no driver for kind {kind!r}", 501);
    }
    inst = {
        "instance_id": instance_id,
        "kind": kind,
        "display_name": display_name or kind,
        "environment": environment if isinstance(environment, dict) else {},
        "enabled": bool(enabled),
        "config": config if isinstance(config, dict) else {},
        "sessions": {},   # thread_id -> per-kind session record
        "live": {},       # thread_id -> live turn record
    };
    if "create" in impl_fns {
        try {
            impl_fns["create"](inst);
        } except Exception as e {
            return _fail(f"{kind} create failed: {e}", 500);
        }
    }
    _instances[instance_id] = inst;
    return {"ok": True};
}


def:pub driver_send_turn(
    omb_token: any = None,
    instance_id: any = None,
    turn: any = None
) -> dict[str, any] {
    (inst, impl_fns, err) = _resolve(omb_token, instance_id);
    if err is not None { return err; }
    if not isinstance(turn, dict) or not isinstance(turn.get("threadId"), str) {
        return _fail("send_turn needs turn.threadId", 400);
    }
    send = impl_fns.get("send_turn");
    if send is None {
        return _fail(f"{inst['kind']} does not take turns", 501);
    }
    try {
        turn_id = send(inst, turn);
    } except Exception as e {
        return _fail(str(e), 500);
    }
    return {"ok": True, "turn_id": turn_id};
}


def:pub driver_interrupt_turn(
    omb_token: any = None,
    instance_id: any = None,
    thread_id: any = None,
    turn_id: any = None
) -> dict[str, any] {
    (inst, impl_fns, err) = _resolve(omb_token, instance_id);
    if err is not None { return err; }
    interrupt = impl_fns.get("interrupt_turn");
    if interrupt is not None {
        try {
            interrupt(inst, thread_id, turn_id if isinstance(turn_id, str) else None);
        } except Exception as e {
            return _fail(str(e), 500);
        }
    }
    return {"ok": True};
}


def:pub driver_respond(
    omb_token: any = None,
    instance_id: any = None,
    thread_id: any = None,
    request_id: any = None,
    decision: any = None
) -> dict[str, any] {
    (inst, impl_fns, err) = _resolve(omb_token, instance_id);
    if err is not None { return err; }
    respond = impl_fns.get("respond");
    outcome = "unavailable";
    if respond is not None {
        try {
            outcome = respond(inst, thread_id, request_id, decision if isinstance(decision, dict) else {});
        } except Exception {
        }
    }
    return {"ok": True, "outcome": outcome};
}


def:pub driver_steer(
    omb_token: any = None,
    instance_id: any = None,
    thread_id: any = None,
    text: any = None
) -> dict[str, any] {
    (inst, impl_fns, err) = _resolve(omb_token, instance_id);
    if err is not None { return err; }
    steer = impl_fns.get("steer");
    outcome = "indeterminate";
    if steer is not None {
        try {
            outcome = steer(inst, thread_id, text if isinstance(text, str) else "");
        } except Exception {
        }
    }
    return {"ok": True, "outcome": outcome};
}


def:pub driver_stop_all(omb_token: any = None, instance_id: any = None) -> dict[str, any] {
    g = _guard(omb_token);
    if not g["ok"] { return g; }
    inst = _instances.get(instance_id);
    if inst is None { return {"ok": True}; }
    impl_fns = _impls.get(inst["kind"]) or {};
    stop_all = impl_fns.get("stop_all");
    if stop_all is not None {
        try {
            stop_all(inst);
        } except Exception as e {
            return _fail(str(e), 500);
        }
    }
    return {"ok": True};
}


def:pub driver_dispose(omb_token: any = None, instance_id: any = None) -> dict[str, any] {
    g = _guard(omb_token);
    if not g["ok"] { return g; }
    inst = _instances.pop(instance_id, None);
    if inst is None { return {"ok": True}; }
    impl_fns = _impls.get(inst["kind"]) or {};
    dispose = impl_fns.get("dispose");
    if dispose is not None {
        try {
            dispose(inst);
        } except Exception {
        }
    }
    return {"ok": True};
}


def:pub driver_snapshot(omb_token: any = None, instance_id: any = None) -> dict[str, any] {
    (inst, impl_fns, err) = _resolve(omb_token, instance_id);
    if err is not None { return err; }
    snapshot = impl_fns.get("snapshot");
    if snapshot is not None {
        try {
            snap = snapshot(inst);
            if isinstance(snap, dict) {
                snap["ok"] = True;
                return snap;
            }
        } except Exception as e {
            return _fail(str(e), 500);
        }
    }
    return _fail(f"{inst['kind']} has no jac-side snapshot", 501);
}


def:pub driver_generate_text(
    omb_token: any = None,
    instance_id: any = None,
    prompt: any = None,
    options: any = None
) -> dict[str, any] {
    (inst, impl_fns, err) = _resolve(omb_token, instance_id);
    if err is not None { return err; }
    generate = impl_fns.get("generate_text");
    if generate is None {
        return _fail(f"{inst['kind']} cannot generate text", 501);
    }
    try {
        text = generate(inst, prompt or "", options if isinstance(options, dict) else {});
        # A kind may answer {text|failure, usage}: node's onUsage callback
        # cannot cross the op queue, so the shim replays the usage report.
        if isinstance(text, dict) {
            out: dict[str, any] = {"ok": True};
            out.update(text);
            return out;
        }
        return {"ok": True, "text": text};
    } except Exception as e {
        return _fail(str(e), 500);
    }
}


def:pub driver_review_permission(
    omb_token: any = None,
    instance_id: any = None,
    prompt: any = None,
    options: any = None
) -> dict[str, any] {
    (inst, impl_fns, err) = _resolve(omb_token, instance_id);
    if err is not None { return err; }
    review = impl_fns.get("review_permission");
    if review is None { review = impl_fns.get("generate_text"); }
    if review is None {
        return _fail(f"{inst['kind']} cannot review permissions", 501);
    }
    try {
        text = review(inst, prompt or "", options if isinstance(options, dict) else {});
        return {"ok": True, "text": text};
    } except Exception as e {
        return _fail(str(e), 500);
    }
}


def:pub driver_state(omb_token: any = None) -> dict[str, any] {
    g = _guard(omb_token);
    if not g["ok"] { return g; }
    instances = {};
    for (iid, inst) in _instances.items() {
        instances[iid] = {
            "kind": inst["kind"],
            "display_name": inst["display_name"],
            "enabled": inst["enabled"],
            "sessions": sorted(inst["sessions"].keys()),
            "live": sorted(inst["live"].keys()),
        };
    }
    return {"ok": True, "instances": instances, "kinds": sorted(_impls.keys())};
}


# ── driver_stub: seam fixture ──────────────────────────────────────────────
# Replays a scripted event list over the bridge so the whole node seam —
# shim adapter, driver_event delivery, bus stamping, hasSession mirror — is
# verifiable without an engine. turn.script: a list of events merged onto
# {threadId, turnId}; no script means one assistant_text echo of the prompt.

def _stub_run(inst: dict[str, any], thread_id: str, turn_id: str, script: list[any]) {
    base = {"threadId": thread_id, "turnId": turn_id};
    for ev in script {
        live = inst["live"].get(thread_id);
        if live is None or live.get("stopped") { break; }
        out = dict(base);
        out.update(ev);
        emit_event(inst, out);
    }
    inst["live"].pop(thread_id, None);
}


def _stub_send_turn(inst: dict[str, any], turn: dict[str, any]) -> str {
    thread_id = turn["threadId"];
    turn_id = str(uuid.uuid4());
    inst["live"][thread_id] = {"turn_id": turn_id, "stopped": False};
    script = turn.get("script");
    if script is None {
        text = turn.get("text") or "";
        script = [
            {"type": "turn.started"},
            {"type": "item.completed", "itemType": "assistant_text", "text": f"stub:{text}"},
            {"type": "turn.completed", "ok": True},
        ];
    }
    threading.Thread(target=_stub_run, args=(inst, thread_id, turn_id, script), daemon=True).start();
    return turn_id;
}


def _stub_interrupt(inst: dict[str, any], thread_id: any, turn_id: any) {
    live = inst["live"].get(thread_id);
    if live is not None {
        live["stopped"] = True;
    }
}


def _stub_stop_all(inst: dict[str, any]) {
    for live in inst["live"].values() {
        live["stopped"] = True;
    }
}


def _stub_snapshot(inst: dict[str, any]) -> dict[str, any] {
    return {
        "instanceId": inst["instance_id"],
        "driverKind": inst["kind"],
        "displayName": inst["display_name"],
        "status": "ready",
        "live": sorted(inst["live"].keys()),
    };
}


with entry {
    driver_register_kind("driver_stub", {
        "send_turn": _stub_send_turn,
        "interrupt_turn": _stub_interrupt,
        "stop_all": _stub_stop_all,
        "snapshot": _stub_snapshot,
    });
}
