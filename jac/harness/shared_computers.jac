"""SharedComputers port - the lent-computer rendezvous on Jac (phase 4).

Faithful port of server/shared-computers.ts. In-memory only: authority over
local resources stays on the desktop, and a restart or disconnect NEVER
replays an operation with an unknown outcome.

The rendezvous is a graph: a LendingBoard node holds one LentComputer per
(registering session, desktop id) over `Lends` edges, and each queued bot
operation is a ComputerJob node hanging off its computer over `Queues`
edges (at most one: a busy computer refuses). Partitioned by owner: an
entry is keyed by the registering session, so another session can never
take over an id, and a bot turn sees only the computers of the person it
acts for. A turn that acts for nobody provable (principal null) sees none.

Waiting is real blocking in the Jac threadpool (sync def:pub runs on its own
worker thread): a desktop's long poll waits on its computer's wake Event, a
bot's request waits on its job's done Event. Those Python objects live in
side tables keyed by node identity (never node attributes).

Hooks (`_sc["hooks"]`):
  sessions_live(list[str]) -> dict[str,bool]  node bridge `shared_sessions_live`
  job_active(ref) -> bool   node bridge `shared_job_active`: node keeps the
      requesting turn's `active()` closure under an opaque ref.
"""

import os;
import re;
import json;
import hmac;
import time;
import uuid;
import threading;

import from routines { _bridge }

glob TOTAL: int = 100;
glob RETAIN_MS: int = 14 * 24 * 60 * 60000;
glob ONLINE_MS: int = 40000;
glob OFFLINE: str = "This shared computer is offline. Keep its desktop app open; do not substitute files on the server.";
glob _HEX64: any = re.compile("^[a-f0-9]{64}$");

node LendingBoard {}

node LentComputer {
    has session: str,
        person: str,
        computer_id: str,
        registration: dict[str, any] = {},
        secret: str = "",
        seen: int = 0;
}

node ComputerJob {
    has job_id: str,
        operation: dict[str, any] = {},
        active_ref: str = "",
        sent: bool = False;
}

edge Lends: any --> any {}
edge Queues: any --> any {}

glob _sc: dict[str, any] = {};
glob _sc_lock: any = threading.RLock();

class SharedComputerError(Exception) {
    # Error carrying an HTTP status (JS `Object.assign(new Error, {status})`).
}

def _failure(message: str, status: int = 409) -> Exception {
    err = SharedComputerError(message);
    setattr(err, "status", status);
    return err;
}

def _fail(status: int, message: str) {
    raise _failure(message, status);
}

def _status_of(e: Exception) -> int {
    s = getattr(e, "status", None);
    return s if isinstance(s, int) and not isinstance(s, bool) else 500;
}

# ── default hooks (production wiring) ─────────────────────────────────────

def _hook_sessions_live(sessions: list[str]) -> dict[str, any] {
    res = _bridge("shared_sessions_live", {"sessions": sessions});
    live = res.get("live");
    return live if isinstance(live, dict) else {};
}

def _hook_job_active(ref: str) -> bool {
    return _bridge("shared_job_active", {"ref": ref}).get("active") is True;
}

def _default_hooks -> dict[str, any] {
    return {"sessions_live": _hook_sessions_live, "job_active": _hook_job_active};
}

def _reset {
    with _sc_lock {
        for w in list(_sc.get("wakes", {}).values()) {
            w.set();
        }
        _sc.update({
            "board": LendingBoard(),
            "wakes": {},
            "waiters": {},
            "now_ms": None,
            "poll_ms": 20000,
            "job_ms": 45000,
            "hooks": _default_hooks(),
        });
    }
}

def _now -> int {
    v = _sc.get("now_ms");
    if v is not None {
        return int(v);
    }
    return int(time.time() * 1000);
}

# ── graph helpers ──────────────────────────────────────────────────────────

def _board -> LendingBoard {
    return _sc["board"];
}

def _entries -> list[any] {
    return [_board() ->:Lends:->][?:LentComputer];
}

def _entry(session: str, computer_id: str) -> any {
    for e in _entries() {
        if e.session == session and e.computer_id == computer_id {
            return e;
        }
    }
    return None;
}

def _jobs(e: LentComputer) -> list[any] {
    return [e ->:Queues:->][?:ComputerJob];
}

def _live(sessions: list[str]) -> dict[str, any] {
    if not sessions {
        return {};
    }
    got = _sc["hooks"]["sessions_live"](list(dict.fromkeys(sessions)));
    return got if isinstance(got, dict) else {};
}

def _session_live(session: str) -> bool {
    return _live([session]).get(session) is True;
}

def _wake(e: LentComputer) {
    w = _sc["wakes"].pop(id(e), None);
    if w is not None {
        w.set();
    }
}

def _remove(e: LentComputer) {
    _board() del ->:Lends:-> e;
    _wake(e);
}

# Settle one job: the waiting request thread wakes with the result or error.
def _finish(e: LentComputer, job: ComputerJob, error: any, result: any = None) {
    e del ->:Queues:-> job;
    waiter = _sc["waiters"].pop(job.job_id, None);
    if waiter is not None {
        waiter["error"] = error;
        waiter["result"] = result;
        waiter["done"].set();
    }
}

def _active(job: ComputerJob) -> bool {
    try {
        return _sc["hooks"]["job_active"](job.active_ref) is True;
    } except Exception {
        return False;
    }
}

# ── scope check ────────────────────────────────────────────────────────────

# The scopes the desktop registered, checked by the server as well. The
# desktop's own grant is the authority and checks every operation again.
def shared_computer_scope_refusal(registration: dict[str, any], operation: dict[str, any]) -> any {
    action = operation.get("action");
    if action == "run_command" {
        return None if registration.get("terminal") else "Terminal access is not lent to this server.";
    }
    if action in ("computer_tools", "computer_call") {
        return None if registration.get("computer") else "Apps and screen are not lent to this server.";
    }
    if action in ("list_files", "read_file", "write_file") {
        lent: any = None;
        for f in registration.get("folders", []) {
            if lent is None and f.get("id") == operation.get("folder_id") {
                lent = f;
            }
        }
        if lent is None {
            return "This folder has not been shared with this server.";
        }
        return "This folder is read-only." if action == "write_file" and not lent.get("write") else None;
    }
    return None;
}

# ── SharedComputers ────────────────────────────────────────────────────────

def _online(e: LentComputer, live: dict[str, any]) -> bool {
    return live.get(e.session) is True and _now() - e.seen < ONLINE_MS;
}

# Forget entries whose session ended or that have been silent too long.
def _reap {
    entries = _entries();
    live = _live([e.session for e in entries]);
    for e in entries {
        if len(_jobs(e)) == 0 and (live.get(e.session) is not True or _now() - e.seen > RETAIN_MS) {
            _remove(e);
        }
    }
}

def _authorize(computer_id: str, session: str, secret: str) -> LentComputer {
    e = _entry(session, computer_id);
    if e is None or not _session_live(session) or not isinstance(secret, str) or _HEX64.match(secret) is None or not hmac.compare_digest(secret.encode("utf-8"), e.secret.encode("utf-8")) {
        _fail(403, "Shared computer is disconnected or not authorized");
    }
    return e;
}

def sc_register(registration: dict[str, any], owner: dict[str, any], secret: str) {
    with _sc_lock {
        if not isinstance(secret, str) or _HEX64.match(secret) is None {
            _fail(400, "Invalid computer credential");
        }
        old = _entry(owner["session"], registration["id"]);
        if old is not None {
            _authorize(registration["id"], owner["session"], secret);
            old.registration = registration;
            old.seen = _now();
            return;
        }
        _reap();
        # A paired desktop runs one grant per server, so a new id from the
        # same session is a new save: its earlier entry is stale and goes.
        for stale in _entries() {
            if stale.session != owner["session"] {
                continue;
            }
            _remove(stale);
            for job in _jobs(stale) {
                _finish(stale, job, _failure("This computer's access changed. An in-flight action may have completed; inspect before retrying."));
            }
        }
        if len(_entries()) >= TOTAL {
            _fail(409, "Too many shared computers");
        }
        e = LentComputer(
            session=owner["session"], person=owner["person"], computer_id=registration["id"],
            registration=registration, secret=secret, seen=_now()
        );
        _board() +>:Lends:+> e;
    }
}

# The online computers one person lent.
def sc_list(principal: any) -> list[any] {
    if not principal {
        return [];
    }
    with _sc_lock {
        mine = [e for e in _entries() if e.person == principal];
        live = _live([e.session for e in mine]);
        return [e.registration for e in mine if _online(e, live)];
    }
}

# What one person has lent, online or not. No secret, no session.
def sc_status(principal: any) -> list[any] {
    if not principal {
        return [];
    }
    with _sc_lock {
        _reap();
        mine = [e for e in _entries() if e.person == principal];
        live = _live([e.session for e in mine]);
        out: list[any] = [];
        for e in mine {
            reg = e.registration;
            out.append({
                "id": reg["id"], "name": reg["name"], "online": _online(e, live),
                "busy": len(_jobs(e)) > 0, "lastSeenAt": e.seen,
                "scopes": {
                    "folders": [{"id": f["id"], "name": f["name"], "write": f["write"]} for f in reg["folders"]],
                    "terminal": reg["terminal"], "screen": reg["computer"],
                },
            });
        }
        return out;
    }
}

def _next(e: LentComputer) -> any {
    for job in _jobs(e) {
        if not _active(job) {
            _finish(e, job, _failure("The requesting turn ended"));
            continue;
        }
        if not job.sent {
            job.sent = True;
            return {"id": job.job_id, "operation": job.operation};
        }
    }
    return None;
}

def sc_poll(computer_id: str, session: str, secret: str) -> any {
    wake: any = None;
    with _sc_lock {
        e = _authorize(computer_id, session, secret);
        if id(e) in _sc["wakes"] {
            _fail(409, "A computer poll is already running");
        }
        e.seen = _now();
        queued = _next(e);
        if queued is not None {
            return queued;
        }
        wake = threading.Event();
        _sc["wakes"][id(e)] = wake;
    }
    wake.wait(_sc["poll_ms"] / 1000.0);
    with _sc_lock {
        if _sc["wakes"].get(id(e)) is wake {
            _sc["wakes"].pop(id(e), None);
        }
        e = _authorize(computer_id, session, secret);
        e.seen = _now();
        return _next(e);
    }
}

def sc_live_job(computer_id: str, session: str, secret: str, job_id: str) -> bool {
    with _sc_lock {
        e = _authorize(computer_id, session, secret);
        e.seen = _now();
        for job in _jobs(e) {
            if job.job_id == job_id {
                return job.sent is True and _active(job);
            }
        }
        return False;
    }
}

def sc_complete(computer_id: str, session: str, secret: str, job_id: str, result: any) {
    with _sc_lock {
        e = _authorize(computer_id, session, secret);
        found: any = None;
        for job in _jobs(e) {
            if job.job_id == job_id {
                found = job;
            }
        }
        if found is None or not found.sent {
            _fail(409, "This computer operation expired; it will not be replayed");
        }
        error: any = None;
        if not _active(found) {
            error = _failure("The requesting turn ended");
        }
        _finish(e, found, error, result);
    }
}

def sc_disconnect(computer_id: str, session: str, secret: str) {
    with _sc_lock {
        e = _authorize(computer_id, session, secret);
        _remove(e);
        for job in _jobs(e) {
            _finish(e, job, _failure("Computer disconnected. An in-flight action may have completed; inspect before retrying."));
        }
    }
}

# One bot operation for the person the turn acts for. Another person's
# computer answers exactly like one that does not exist.
def sc_request(operation: dict[str, any], principal: any, active_ref: str) -> any {
    waiter: dict[str, any] = {};
    job_id = str(uuid.uuid4());
    owner: any = None;
    with _sc_lock {
        if not principal {
            _fail(403, "This conversation cannot use a shared computer: only a conversation started by the person who shared it can.");
        }
        candidates = [e for e in _entries() if e.registration.get("id") == operation.get("computer_id") and e.person == principal];
        live = _live([e.session for e in candidates]);
        for e in candidates {
            if owner is None and _online(e, live) {
                owner = e;
            }
        }
        if owner is None {
            _fail(409, OFFLINE);
        }
        refusal = shared_computer_scope_refusal(owner.registration, operation);
        if refusal {
            _fail(403, refusal);
        }
        if len(_jobs(owner)) >= 1 {
            _fail(409, "This shared computer is busy. Wait for its current action to finish.");
        }
        job = ComputerJob(job_id=job_id, operation=operation, active_ref=active_ref);
        if not _active(job) {
            _fail(401, "The requesting turn ended");
        }
        waiter = {"done": threading.Event(), "error": None, "result": None};
        _sc["waiters"][job_id] = waiter;
        holder: LentComputer = owner;
        holder +>:Queues:+> job;
        _wake(holder);
    }
    if not waiter["done"].wait(_sc["job_ms"] / 1000.0) {
        with _sc_lock {
            for job in _jobs(owner) {
                if job.job_id == job_id {
                    _finish(owner, job, _failure("Computer action timed out. Its outcome is unknown; inspect before retrying."));
                }
            }
        }
    }
    if waiter["error"] is not None {
        err: Exception = waiter["error"];
        raise err;
    }
    return waiter["result"];
}

def sc_close {
    with _sc_lock {
        for e in _entries() {
            _wake(e);
            for job in _jobs(e) {
                _finish(e, job, _failure("Workspace stopped. Inspect any in-flight action before retrying."));
            }
        }
        _sc["board"] = LendingBoard();
    }
}

# ── HTTP surface (re-bound onto harness.jac as shared_computer_*) ───────────

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

def _str(v: any) -> str {
    return v if isinstance(v, str) else "";
}

def _principal(v: any) -> any {
    return v if isinstance(v, str) and v else None;
}

def:pub shared_computer_register(registration: any = None, session: any = None, person: any = None, secret: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        if not isinstance(registration, dict) or not isinstance(session, str) or not isinstance(person, str) {
            _fail(400, "Invalid computer registration");
        }
        sc_register(registration, {"session": session, "person": person}, _str(secret));
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

def:pub shared_computer_list(principal: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"computers": sc_list(_principal(principal))}; }
    return _invoke(omb_token, _go);
}

def:pub shared_computer_status(principal: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"computers": sc_status(_principal(principal))}; }
    return _invoke(omb_token, _go);
}

def:pub shared_computer_poll(id: any = None, session: any = None, secret: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"job": sc_poll(_str(id), _str(session), _str(secret))}; }
    return _invoke(omb_token, _go);
}

def:pub shared_computer_live_job(id: any = None, session: any = None, secret: any = None, job_id: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"active": sc_live_job(_str(id), _str(session), _str(secret), _str(job_id))}; }
    return _invoke(omb_token, _go);
}

def:pub shared_computer_complete(id: any = None, session: any = None, secret: any = None, job_id: any = None, result: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        sc_complete(_str(id), _str(session), _str(secret), _str(job_id), result);
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

def:pub shared_computer_disconnect(id: any = None, session: any = None, secret: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        sc_disconnect(_str(id), _str(session), _str(secret));
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

def:pub shared_computer_request(operation: any = None, principal: any = None, active_ref: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        if not isinstance(operation, dict) {
            _fail(400, "Invalid shared computer operation");
        }
        return {"result": sc_request(operation, _principal(principal), _str(active_ref))};
    }
    return _invoke(omb_token, _go);
}

def:pub shared_computer_close(omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        sc_close();
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

with entry {
    _reset();
}
