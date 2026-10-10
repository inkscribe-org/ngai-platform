"""Ported invariants from server/shared-computers.test.ts (SharedComputers).

Annexes shared_computers.jac (no self-import). Node's `sessionLive` and each
turn's `active()` closure become a fake hook table; a bot request blocks its
worker thread exactly as the def:pub does, so tests run it on a thread and
join. vitest's fake clock becomes `_sc["now_ms"]`; the 20 s long poll and
45 s job timeout shrink through `poll_ms` / `job_ms`.

provenRequestPerson stays with node (it reads node's request records) and
its cases live with server/jac-computers.ts's facade.
"""

glob SECRET: str = "a" * 64;
glob OTHER: str = "b" * 64;
glob ALICE: dict[str, str] = {"session": "owner", "person": "p_alice"};
glob BOB: dict[str, str] = {"session": "intruder", "person": "p_bob"};

def _registration(scopes: dict[str, any] = {}) -> dict[str, any] {
    reg: dict[str, any] = {
        "id": str(uuid.uuid4()), "name": "Desktop", "environmentId": str(uuid.uuid4()),
        "folders": [], "terminal": False, "computer": False,
    };
    reg.update(scopes);
    return reg;
}

def _broker(live: any) -> dict[str, any] {
    _reset();
    h: dict[str, any] = {"refs": {}, "live": live};
    def _sessions_live(sessions: list[str]) -> dict[str, any] {
        return {s: h["live"](s) is True for s in sessions};
    }
    def _job_active(ref: str) -> bool {
        fn = h["refs"].get(ref);
        return fn is not None and fn() is True;
    }
    _sc["hooks"] = {"sessions_live": _sessions_live, "job_active": _job_active};
    _sc.update({"now_ms": 1000000, "poll_ms": 50, "job_ms": 5000});
    return h;
}

def _always(session: str) -> bool { return True; }

def _yes -> bool { return True; }

# A bot request on its own thread, as the def:pub runs on a worker.
def _request(h: dict[str, any], operation: dict[str, any], principal: any, active: any) -> dict[str, any] {
    ref = str(uuid.uuid4());
    h["refs"][ref] = active;
    out: dict[str, any] = {"done": False, "result": None, "error": None};
    def _run {
        try {
            out["result"] = sc_request(operation, principal, ref);
        } except Exception as e {
            out["error"] = e;
        }
        out["done"] = True;
    }
    t = threading.Thread(target=_run, daemon=True);
    out["thread"] = t;
    t.start();
    return out;
}

def _join(out: dict[str, any]) -> dict[str, any] {
    out["thread"].join(10);
    assert out["done"], "request never settled";
    return out;
}

# Wait until a request has queued its job (or failed fast).
def _settle_queue(out: dict[str, any]) {
    for i in range(200) {
        if out["done"] or len(_sc["waiters"]) > 0 {
            return;
        }
        time.sleep(0.005);
    }
}

def _rejects(out: dict[str, any], pattern: str) -> int {
    _join(out);
    e = out["error"];
    assert e is not None, "expected a rejection matching " + pattern;
    assert re.search(pattern, str(e)) is not None, str(e);
    return _status_of(e);
}

def _raises(fn: any, pattern: str) -> int {
    try {
        fn();
    } except Exception as e {
        assert re.search(pattern, str(e)) is not None, str(e);
        return _status_of(e);
    }
    assert False, "expected a failure matching " + pattern;
    return 0;
}

test "requires both the owning paired session and the connector secret" {
    def _owner_only(session: str) -> bool { return session == "owner"; }
    _broker(_owner_only);
    c = _registration();
    sc_register(c, ALICE, SECRET);
    for pair in [["intruder", SECRET], ["owner", "wrong"], ["owner", "é" * 64]] {
        def _poll { sc_poll(c["id"], pair[0], pair[1]); }
        assert _raises(_poll, "not authorized") == 403;
    }
    assert SECRET not in json.dumps(sc_list(ALICE["person"]));
    sc_close();
}

test "delivers a job once, refuses concurrent work, and never replays after disconnect" {
    h = _broker(_always);
    c = _registration();
    sc_register(c, ALICE, SECRET);
    operation = {"computer_id": c["id"], "action": "computer_tools"};
    lent = _registration({"computer": True});
    lent["id"] = c["id"];
    sc_register(lent, ALICE, SECRET);
    result = _request(h, operation, ALICE["person"], _yes);
    _settle_queue(result);
    busy = _request(h, operation, ALICE["person"], _yes);
    _rejects(busy, "busy");
    job = sc_poll(c["id"], "owner", SECRET);
    assert job["operation"] == operation;
    assert sc_live_job(c["id"], "owner", SECRET, job["id"]) is True;
    sc_complete(c["id"], "owner", SECRET, job["id"], {"ok": True});
    assert _join(result)["result"] == {"ok": True};
    def _again { sc_complete(c["id"], "owner", SECRET, job["id"], {}); }
    _raises(_again, "expired");
    pending = _request(h, operation, ALICE["person"], _yes);
    _settle_queue(pending);
    sc_poll(c["id"], "owner", SECRET);
    sc_disconnect(c["id"], "owner", SECRET);
    _rejects(pending, "in-flight");
    assert sc_list(ALICE["person"]) == [];
    _rejects(_request(h, operation, ALICE["person"], _yes), "offline");
    sc_close();
}

test "turn cancellation rejects queued and already delivered actions" {
    h = _broker(_always);
    c = _registration({"computer": True});
    sc_register(c, ALICE, SECRET);
    state: dict[str, bool] = {"active": True};
    def _active -> bool { return state["active"]; }
    pending = _request(h, {"computer_id": c["id"], "action": "computer_tools"}, ALICE["person"], _active);
    _settle_queue(pending);
    job = sc_poll(c["id"], "owner", SECRET);
    state["active"] = False;
    assert sc_live_job(c["id"], "owner", SECRET, job["id"]) is False;
    sc_complete(c["id"], "owner", SECRET, job["id"], {});
    _rejects(pending, "turn ended");
    state["active"] = True;
    queued = _request(h, {"computer_id": c["id"], "action": "computer_tools"}, ALICE["person"], _active);
    _settle_queue(queued);
    state["active"] = False;
    assert sc_poll(c["id"], "owner", SECRET) is None;
    _rejects(queued, "turn ended");
    sc_close();
}

test "expires offline registrations and rejects revoked sessions" {
    state: dict[str, bool] = {"valid": True};
    def _valid(session: str) -> bool { return state["valid"]; }
    _broker(_valid);
    c = _registration();
    sc_register(c, ALICE, SECRET);
    state["valid"] = False;
    assert sc_list(ALICE["person"]) == [];
    def _poll { sc_poll(c["id"], "owner", SECRET); }
    _raises(_poll, "not authorized");
    state["valid"] = True;
    _sc["now_ms"] = _sc["now_ms"] + 40001;
    assert sc_list(ALICE["person"]) == [];
    sc_close();
}

test "another person's bot turn cannot list or use a lent computer" {
    h = _broker(_always);
    c = _registration({"terminal": True, "computer": True, "folders": [{"id": str(uuid.uuid4()), "name": "Docs", "write": True}]});
    sc_register(c, ALICE, SECRET);
    assert len(sc_list(ALICE["person"])) == 1;
    assert sc_list(BOB["person"]) == [];
    assert sc_list(None) == [];
    op = {"computer_id": c["id"], "action": "run_command", "command": "id"};
    _rejects(_request(h, op, BOB["person"], _yes), "offline");
    assert _rejects(_request(h, op, None, _yes), "only a conversation started") == 403;
    assert sc_poll(c["id"], ALICE["session"], SECRET) is None;
    sc_close();
}

test "a second session cannot squat a lent computer's id, even after its owner goes offline" {
    h = _broker(_always);
    c = _registration({"folders": [{"id": str(uuid.uuid4()), "name": "Docs", "write": True}]});
    sc_register(c, ALICE, SECRET);
    _sc["now_ms"] = _sc["now_ms"] + 40001;
    sc_register(c, BOB, OTHER);
    op = {"computer_id": c["id"], "action": "write_file", "folder_id": c["folders"][0]["id"], "path": "a.txt", "content": "secret"};
    _rejects(_request(h, op, ALICE["person"], _yes), "offline");
    assert sc_list(ALICE["person"]) == [];
    sc_register(c, ALICE, SECRET);
    assert len(sc_list(ALICE["person"])) == 1;
    def _poll { sc_poll(c["id"], BOB["session"], SECRET); }
    assert _raises(_poll, "not authorized") == 403;
    sc_close();
}

test "a new grant from the same desktop replaces its earlier one; other desktops are untouched" {
    h = _broker(_always);
    first = _registration({"computer": True});
    sc_register(first, ALICE, SECRET);
    bobs = _registration({"computer": True});
    sc_register(bobs, BOB, OTHER);
    pending = _request(h, {"computer_id": first["id"], "action": "computer_tools"}, ALICE["person"], _yes);
    _settle_queue(pending);
    second = _registration({"computer": True});
    sc_register(second, ALICE, OTHER);
    _rejects(pending, "access changed");
    assert [r["id"] for r in sc_list(ALICE["person"])] == [second["id"]];
    assert [r["id"] for r in sc_list(BOB["person"])] == [bobs["id"]];
    def _poll { sc_poll(first["id"], ALICE["session"], SECRET); }
    assert _raises(_poll, "not authorized") == 403;
    sc_close();
}

test "one session cannot fill the registry for everyone else" {
    _broker(_always);
    for i in range(50) {
        sc_register(_registration(), ALICE, SECRET);
    }
    sc_register(_registration(), BOB, OTHER);
    assert len(sc_list(BOB["person"])) == 1;
    sc_close();
}

test "reports one person's lent computers, online or asleep, with scopes and no secrets" {
    state: dict[str, bool] = {"live": True};
    def _live_fn(session: str) -> bool { return session != ALICE["session"] or state["live"]; }
    _broker(_live_fn);
    docs = {"id": str(uuid.uuid4()), "name": "Docs", "write": True};
    mac = _registration({"computer": True, "folders": [docs]});
    sc_register(mac, ALICE, SECRET);
    sc_register(_registration({"terminal": True}), BOB, OTHER);
    assert sc_status(ALICE["person"]) == [{
        "id": mac["id"], "name": "Desktop", "online": True, "busy": False, "lastSeenAt": 1000000,
        "scopes": {"folders": [docs], "terminal": False, "screen": True},
    }];
    assert sc_status(None) == [];
    assert SECRET not in json.dumps(sc_status(ALICE["person"]));
    _sc["now_ms"] = _sc["now_ms"] + 40001;
    got = sc_status(ALICE["person"]);
    assert got[0]["id"] == mac["id"] and got[0]["online"] is False;
    assert sc_list(ALICE["person"]) == [];
    state["live"] = False;
    assert sc_status(ALICE["person"]) == [];
    sc_close();
}

test "refuses shell, screen and writes a read-only grant never lent" {
    ro = {"id": str(uuid.uuid4()), "name": "Docs", "write": False};
    rw = {"id": str(uuid.uuid4()), "name": "Drafts", "write": True};
    lent = _registration({"folders": [ro, rw]});
    assert "Terminal" in shared_computer_scope_refusal(lent, {"action": "run_command"});
    assert "screen" in shared_computer_scope_refusal(lent, {"action": "computer_call"});
    assert "screen" in shared_computer_scope_refusal(lent, {"action": "computer_tools"});
    assert "read-only" in shared_computer_scope_refusal(lent, {"action": "write_file", "folder_id": ro["id"]});
    assert "not been shared" in shared_computer_scope_refusal(lent, {"action": "read_file", "folder_id": str(uuid.uuid4())});
    assert shared_computer_scope_refusal(lent, {"action": "read_file", "folder_id": ro["id"]}) is None;
    assert shared_computer_scope_refusal(lent, {"action": "write_file", "folder_id": rw["id"]}) is None;
}

test "never queues an out-of-scope operation for the desktop" {
    h = _broker(_always);
    ro = {"id": str(uuid.uuid4()), "name": "Docs", "write": False};
    lent = _registration({"folders": [ro]});
    sc_register(lent, ALICE, SECRET);
    assert _rejects(_request(h, {"computer_id": lent["id"], "action": "run_command", "command": "id"}, ALICE["person"], _yes), "Terminal") == 403;
    _rejects(_request(h, {"computer_id": lent["id"], "action": "write_file", "folder_id": ro["id"], "path": "x", "content": "y"}, ALICE["person"], _yes), "read-only");
    assert sc_poll(lent["id"], ALICE["session"], SECRET) is None;
    sc_close();
}

test "an unanswered job times out with an unknown outcome and frees the computer" {
    h = _broker(_always);
    c = _registration({"computer": True});
    sc_register(c, ALICE, SECRET);
    _sc["job_ms"] = 50;
    out = _request(h, {"computer_id": c["id"], "action": "computer_tools"}, ALICE["person"], _yes);
    assert _rejects(out, "timed out") == 409;
    assert sc_status(ALICE["person"])[0]["busy"] is False;
    sc_close();
}

test "a long poll wakes for a job queued while it waits, and one poll at a time" {
    h = _broker(_always);
    c = _registration({"computer": True});
    sc_register(c, ALICE, SECRET);
    _sc["poll_ms"] = 5000;
    got: dict[str, any] = {};
    def _poller { got["job"] = sc_poll(c["id"], "owner", SECRET); }
    t = threading.Thread(target=_poller, daemon=True);
    t.start();
    for i in range(200) {
        if len(_sc["wakes"]) > 0 { break; }
        time.sleep(0.005);
    }
    def _second { sc_poll(c["id"], "owner", SECRET); }
    _raises(_second, "already running");
    out = _request(h, {"computer_id": c["id"], "action": "computer_tools"}, ALICE["person"], _yes);
    t.join(5);
    assert got["job"]["operation"]["action"] == "computer_tools";
    sc_complete(c["id"], "owner", SECRET, got["job"]["id"], 7);
    assert _join(out)["result"] == 7;
    sc_close();
}

test "def:pub surface keeps the 400 for a malformed credential" {
    _broker(_always);
    bad = shared_computer_register(registration=_registration(), session="owner", person="p_alice", secret="nope");
    assert bad["ok"] is False and bad["status"] == 400;
    assert shared_computer_list(principal=None)["computers"] == [];
    sc_close();
}
