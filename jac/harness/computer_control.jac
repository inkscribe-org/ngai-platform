"""Who is driving a computer - ComputerControl + SharedComputerControl on Jac (phase 4).

Faithful port of server/computer-control.ts and server/shared-computer-control.ts.

The record is a graph: one ControlBoard node holds a ControlRecord per key
(a bot id, or `computer_<id>` for a team computer) over `Controls` edges,
and one SharedLease per lent-screen lease over `Leases` edges. Both are
per-boot on purpose (a hold is a live fact about who is at the screen; a
stale hold surviving a restart would brick a bot's computer), so the board
hangs off a module glob, never off `root`.

The rules (unchanged from the TS):
  - A bot can only ASK for hands (request_help); it never takes control and
    cannot clear a hold. Only the person takes and releases.
  - Releasing control also settles any open help request.
  - An opaque workspace lease id is never part of a snapshot or a frame.

Hooks (`_cc["hooks"]`):
  on_change(key, snapshot, lease) -> node bridge `computer_control_changed`
      (mirror + per-member SSE broadcast + the Electron browser gate). The
      lease rides the bridge only so node's sync mirror can answer
      ownsLease; node never broadcasts it.
  held() / claim(id) / release(id) -> node bridge ops over node's
      TurnResources ("computer:host" seat) for the lent-screen lease.
  schedule(delay_ms, fn) -> a cancellable timer (threading.Timer).
"""

import os;
import time;
import threading;

import from routines { _bridge }

glob MAX_REASON_CHARS: int = 280;
glob LEASE_EXPIRY_MS: int = 40000;
glob DEFAULT_HELP_REASON: str = "the bot asked you to take over";
glob SHARED_BUSY: str = "This computer is in use locally or held by a person. Wait, then observe it again before acting.";

node ControlBoard {}

node ControlRecord {
    has key: str,
        held_since_ms: (int | None) = None,
        help_reason: (str | None) = None,
        help_request_id: (str | None) = None,
        control_lease_id: (str | None) = None;
}

node SharedLease {
    has lease_id: str,
        generation: int = 0,
        last_activity: int = 0;
}

edge Controls: any --> any {}
edge Leases: any --> any {}

glob _cc: dict[str, any] = {};
glob _cc_lock: any = threading.RLock();

class ControlError(Exception) {
    # Error carrying an HTTP status (JS `Object.assign(new Error, {status})`).
}

def _fail(status: int, message: str) {
    err = ControlError(message);
    setattr(err, "status", status);
    raise err;
}

def _status_of(e: Exception) -> int {
    s = getattr(e, "status", None);
    return s if isinstance(s, int) and not isinstance(s, bool) else 500;
}

# ── default hooks (production wiring) ─────────────────────────────────────

def _hook_on_change(key: str, snapshot: dict[str, any], lease: any) {
    try {
        _bridge("computer_control_changed", {"key": key, "snapshot": snapshot, "control_lease_id": lease});
    } except Exception as e {
        print(f"computer-control: change bridge failed: {e}");
    }
}

def _hook_held -> bool {
    return _bridge("shared_control_held", {}).get("held") is True;
}

def _hook_claim(lease_id: str) -> bool {
    return _bridge("shared_control_claim", {"id": lease_id}).get("claimed") is True;
}

def _hook_release(lease_id: str) {
    _bridge("shared_control_release", {"id": lease_id});
}

def _hook_schedule(delay_ms: int, fn: any) -> any {
    t = threading.Timer(delay_ms / 1000.0, fn);
    t.daemon = True;
    t.start();
    return t;
}

def _default_hooks -> dict[str, any] {
    return {
        "on_change": _hook_on_change,
        "held": _hook_held,
        "claim": _hook_claim,
        "release": _hook_release,
        "schedule": _hook_schedule,
    };
}

def _reset {
    with _cc_lock {
        for t in list(_cc.get("timers", {}).values()) {
            try { t.cancel(); } except Exception { }
        }
        _cc.update({
            "board": ControlBoard(),
            "now_ms": None,
            "seq": 0,
            "timers": {},
            "hooks": _default_hooks(),
        });
    }
}

def _now -> int {
    v = _cc.get("now_ms");
    if v is not None {
        return int(v);
    }
    return int(time.time() * 1000);
}

# ── ComputerControl ────────────────────────────────────────────────────────

def _no_control -> dict[str, any] {
    return {"held": False, "helpReason": None, "heldSinceMs": None};
}

def _record(wanted: str) -> any {
    hits = [_cc["board"] ->:Controls:->][?:ControlRecord][?key == wanted];
    return hits[0] if hits else None;
}

def _put(key: str, held_since: any, reason: any, request_id: any, lease: any) -> any {
    rec = _record(key);
    if rec is None {
        rec = ControlRecord(key=key);
        _cc["board"] +>:Controls:+> rec;
    }
    rec.held_since_ms = held_since;
    rec.help_reason = reason;
    rec.help_request_id = request_id;
    rec.control_lease_id = lease;
    return rec;
}

def _drop(key: str) -> bool {
    rec = _record(key);
    if rec is None {
        return False;
    }
    _cc["board"] del ->:Controls:-> rec;
    return True;
}

def cc_snapshot(key: str) -> dict[str, any] {
    with _cc_lock {
        rec = _record(key);
        if rec is None {
            return _no_control();
        }
        return {
            "held": rec.held_since_ms is not None,
            "helpReason": rec.help_reason,
            "heldSinceMs": rec.held_since_ms,
        };
    }
}

def _changed(key: str) -> dict[str, any] {
    snap = cc_snapshot(key);
    rec = _record(key);
    lease: any = None;
    if rec is not None {
        lease = rec.control_lease_id;
    }
    _cc["hooks"]["on_change"](key, snap, lease);
    return snap;
}

# The person takes the wheel. Idempotent: a second click must not reset
# heldSinceMs and make the hold look newer than it is.
def cc_take(key: str) -> dict[str, any] {
    with _cc_lock {
        rec = _record(key);
        if rec is not None and rec.held_since_ms is not None {
            return cc_snapshot(key);
        }
        reason: any = None;
        request_id: any = None;
        if rec is not None {
            reason = rec.help_reason;
            request_id = rec.help_request_id;
        }
        _put(key, _now(), reason, request_id, None);
        return _changed(key);
    }
}

# Atomically take or re-check a workspace-owned hold. The opaque lease is
# never returned in a snapshot, broadcast, or API response.
def cc_acquire_lease(key: str, lease: str) -> dict[str, any] {
    with _cc_lock {
        rec = _record(key);
        if rec is not None and rec.held_since_ms is not None {
            return {
                "snapshot": cc_snapshot(key),
                "owned": rec.control_lease_id == lease,
                "acquired": False,
            };
        }
        reason: any = None;
        request_id: any = None;
        if rec is not None {
            reason = rec.help_reason;
            request_id = rec.help_request_id;
        }
        _put(key, _now(), reason, request_id, lease);
        return {"snapshot": _changed(key), "owned": True, "acquired": True};
    }
}

# Whether this workspace lease holds the wheel right now. Read-only.
def cc_owns_lease(key: str, lease: str) -> bool {
    with _cc_lock {
        rec = _record(key);
        return rec is not None and rec.held_since_ms is not None and rec.control_lease_id == lease;
    }
}

# The person hands the wheel back; also settles any open help request.
def cc_release(key: str) -> dict[str, any] {
    with _cc_lock {
        if not _drop(key) {
            return _no_control();
        }
        return _changed(key);
    }
}

# Release only the hold created by this workspace lease.
def cc_release_lease(key: str, lease: str) -> dict[str, any] {
    with _cc_lock {
        rec = _record(key);
        if rec is None or rec.held_since_ms is None or rec.control_lease_id != lease {
            return {"snapshot": cc_snapshot(key), "released": False};
        }
        _drop(key);
        return {"snapshot": _changed(key), "released": True};
    }
}

def cc_request_help(key: str, reason: any) -> dict[str, any] {
    return cc_request_help_lease(key, reason)["snapshot"];
}

# Open a help request and return the id that owns it. A reason shouted while
# one is open is ignored: it must not clobber the one the person is reading.
def cc_request_help_lease(key: str, reason: any) -> dict[str, any] {
    with _cc_lock {
        text = "";
        if isinstance(reason, str) {
            text = _js_slice(_js_trim(reason), MAX_REASON_CHARS);
        }
        rec = _record(key);
        if rec is None {
            rec = _put(key, None, None, None, None);
        }
        if rec.help_reason is None {
            rec.help_reason = text or DEFAULT_HELP_REASON;
            _cc["seq"] = _cc["seq"] + 1;
            rec.help_request_id = f"{key}-{_cc['seq']}";
        }
        request_id = rec.help_request_id;
        return {"snapshot": _changed(key), "requestId": request_id};
    }
}

# The person declines without taking over; the waiting bot is told.
def cc_dismiss_help(key: str) -> dict[str, any] {
    with _cc_lock {
        rec = _record(key);
        if rec is None or rec.help_reason is None {
            return cc_snapshot(key);
        }
        rec.help_reason = None;
        rec.help_request_id = None;
        if rec.held_since_ms is None {
            _drop(key);
        }
        return _changed(key);
    }
}

# Expire an unanswered plea; an old proxy's timeout cannot dismiss a newer one.
def cc_expire_help(key: str, request_id: any) -> dict[str, any] {
    with _cc_lock {
        rec = _record(key);
        if rec is None or rec.help_request_id != request_id {
            return cc_snapshot(key);
        }
        rec.help_reason = None;
        rec.help_request_id = None;
        if rec.held_since_ms is None {
            _drop(key);
        }
        return _changed(key);
    }
}

# The bot is gone; a hold on a deleted bot's computer means nothing.
def cc_forget(key: str) {
    with _cc_lock {
        if _drop(key) {
            _cc["hooks"]["on_change"](key, _no_control(), None);
        }
    }
}

# Every record, for node's mirror after a (re)start. Internal: carries leases.
def cc_entries -> list[any] {
    with _cc_lock {
        out: list[any] = [];
        for rec in [_cc["board"] ->:Controls:->][?:ControlRecord] {
            out.append({"key": rec.key, "snapshot": cc_snapshot(rec.key), "controlLeaseId": rec.control_lease_id});
        }
        return out;
    }
}

# ── SharedComputerControl (a lent screen vs local turns) ───────────────────
# A local desktop call competes with ordinary bot turns for the same screen.
# Leases expire if Electron crashes; human takeover always wins renewal.

def _lease(wanted: str) -> any {
    hits = [_cc["board"] ->:Leases:->][?:SharedLease][?lease_id == wanted];
    return hits[0] if hits else None;
}

def sc_acquire(lease_id: str) {
    with _cc_lock {
        hooks = _cc["hooks"];
        if hooks["held"]() or not hooks["claim"](lease_id) {
            sc_release(lease_id);
            _fail(409, SHARED_BUSY);
        }
        _arm(lease_id);
    }
}

# Extends a held lease for one long desktop action without re-running the
# takeover checks. Renewing an expired or released id is a no-op.
def sc_renew(lease_id: str) {
    with _cc_lock {
        if _lease(lease_id) is not None {
            _arm(lease_id);
        }
    }
}

# (Re)arm the expiry timer. The generation makes a stale timer a no-op: only
# the callback of the newest arming may release the lease.
def _arm(lease_id: str) {
    previous = _lease(lease_id);
    generation = 1;
    if previous is not None {
        generation = previous.generation + 1;
    } else {
        previous = SharedLease(lease_id=lease_id);
        _cc["board"] +>:Leases:+> previous;
    }
    old = _cc["timers"].pop(lease_id, None);
    if old is not None {
        old.cancel();
    }
    previous.generation = generation;
    previous.last_activity = _now();
    def _expire {
        with _cc_lock {
            current = _lease(lease_id);
            if current is not None and current.generation == generation {
                sc_release(lease_id);
            }
        }
    }
    _cc["timers"][lease_id] = _cc["hooks"]["schedule"](LEASE_EXPIRY_MS, _expire);
}

def sc_release(lease_id: str) {
    with _cc_lock {
        lease = _lease(lease_id);
        if lease is not None {
            t = _cc["timers"].pop(lease_id, None);
            if t is not None {
                t.cancel();
            }
            _cc["board"] del ->:Leases:-> lease;
        }
        _cc["hooks"]["release"](lease_id);
    }
}

def sc_close {
    with _cc_lock {
        for lease in [_cc["board"] ->:Leases:->][?:SharedLease] {
            sc_release(lease.lease_id);
        }
    }
}

def sc_lease_ids -> list[str] {
    with _cc_lock {
        return [lease.lease_id for lease in [_cc["board"] ->:Leases:->][?:SharedLease]];
    }
}

# ── JS string semantics ────────────────────────────────────────────────────

glob _JS_SPACE: str = "\t\n\u000b\u000c\r                  　﻿";

def _js_trim(s: str) -> str {
    return s.strip(_JS_SPACE);
}

# String.prototype.slice(0, n) counts UTF-16 code units.
def _js_slice(s: str, n: int) -> str {
    units = s.encode("utf-16-le");
    if len(units) <= n * 2 {
        return s;
    }
    return units[:n * 2].decode("utf-16-le", errors="surrogatepass");
}

# ── HTTP surface (re-bound onto harness.jac as computer_control_*) ──────────

def _guard(omb_token: any) -> any {
    want = os.environ.get("OMB_JAC_TOKEN");
    if want and omb_token != want {
        return {"ok": False, "status": 403, "error": "unauthorized"};
    }
    return None;
}

def _invoke(omb_token: any, fn: any) -> any {
    g = _guard(omb_token);
    if g is not None { return g; }
    try {
        return fn();
    } except Exception as e {
        return {"ok": False, "status": _status_of(e), "error": str(e)};
    }
}

def _key_arg(key: any) -> str {
    if not isinstance(key, str) or not key {
        _fail(400, "key is required");
    }
    return key;
}

def:pub computer_control_list(omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"entries": cc_entries()}; }
    return _invoke(omb_token, _go);
}

def:pub computer_control_take(key: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"snapshot": cc_take(_key_arg(key))}; }
    return _invoke(omb_token, _go);
}

def:pub computer_control_release(key: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"snapshot": cc_release(_key_arg(key))}; }
    return _invoke(omb_token, _go);
}

def:pub computer_control_acquire_lease(key: any = None, control_lease_id: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        if not isinstance(control_lease_id, str) or not control_lease_id {
            _fail(400, "controlLeaseId is required");
        }
        return cc_acquire_lease(_key_arg(key), control_lease_id);
    }
    return _invoke(omb_token, _go);
}

def:pub computer_control_release_lease(key: any = None, control_lease_id: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        if not isinstance(control_lease_id, str) or not control_lease_id {
            _fail(400, "controlLeaseId is required");
        }
        return cc_release_lease(_key_arg(key), control_lease_id);
    }
    return _invoke(omb_token, _go);
}

def:pub computer_control_request_help(key: any = None, reason: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return cc_request_help_lease(_key_arg(key), reason); }
    return _invoke(omb_token, _go);
}

def:pub computer_control_dismiss_help(key: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"snapshot": cc_dismiss_help(_key_arg(key))}; }
    return _invoke(omb_token, _go);
}

def:pub computer_control_expire_help(key: any = None, request_id: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"snapshot": cc_expire_help(_key_arg(key), request_id)}; }
    return _invoke(omb_token, _go);
}

def:pub computer_control_forget(key: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        cc_forget(_key_arg(key));
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

def:pub shared_control_lease(action: any = None, id: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        if not isinstance(id, str) or not id {
            _fail(400, "Invalid computer lease");
        }
        if action == "acquire" {
            sc_acquire(id);
        } elif action == "renew" {
            sc_renew(id);
        } elif action == "release" {
            sc_release(id);
        } else {
            _fail(400, "Invalid computer lease");
        }
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

def:pub shared_control_close(omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        sc_close();
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

with entry {
    _reset();
}
