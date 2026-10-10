"""Ported invariants from server/computer-control.test.ts and the
SharedComputerControl case of server/shared-computers.test.ts.

Annexes computer_control.jac (no self-import). onChange becomes a recorded
hook; node's TurnResources "computer:host" seat becomes a one-holder fake;
timers become a manual scheduler the test fires.
"""

import json;

def _tracked -> list[any] {
    _reset();
    changes: list[any] = [];
    def _on_change(key: str, snapshot: dict[str, any], lease: any) {
        changes.append({"botId": key, "snapshot": snapshot});
    }
    _cc["hooks"]["on_change"] = _on_change;
    return changes;
}

test "starts disengaged for an unknown bot" {
    _tracked();
    assert cc_snapshot("b1") == {"held": False, "helpReason": None, "heldSinceMs": None};
}

test "take then release, each broadcast once" {
    changes = _tracked();
    held = cc_take("b1");
    assert held["held"] is True;
    assert held["heldSinceMs"] is not None;
    assert cc_release("b1")["held"] is False;
    assert [c["snapshot"]["held"] for c in changes] == [True, False];
}

test "a second take does not reset how long the hold has lasted" {
    _tracked();
    _cc["now_ms"] = 1000;
    cc_take("b1");
    _cc["now_ms"] = 5000;
    assert cc_take("b1")["heldSinceMs"] == 1000;
}

test "atomically acquires a workspace lease without exposing its id" {
    changes = _tracked();
    lease = "5b6bbbd2-b88b-4c50-a748-ec87f332662f";
    acquired = cc_acquire_lease("b1", lease);
    assert acquired["owned"] is True and acquired["acquired"] is True;
    assert acquired["snapshot"]["held"] is True;
    assert "controlLeaseId" not in acquired["snapshot"];
    assert lease not in json.dumps(changes);
    same = cc_acquire_lease("b1", lease);
    assert same["owned"] is True and same["acquired"] is False;
    assert len(changes) == 1;
}

test "does not acquire or release a hold owned by another surface" {
    changes = _tracked();
    cc_take("b1");
    lease = "57c7f3ef-e41d-4adf-bbda-0bd25bb03893";
    got = cc_acquire_lease("b1", lease);
    assert got["owned"] is False and got["acquired"] is False and got["snapshot"]["held"] is True;
    rel = cc_release_lease("b1", lease);
    assert rel["released"] is False and rel["snapshot"]["held"] is True;
    assert [c["snapshot"]["held"] for c in changes] == [True];
}

test "conditionally releases only the matching workspace lease" {
    changes = _tracked();
    owner = "33e62f3a-89d9-4117-b48a-15f7deae3252";
    other = "ed602995-306f-480a-8817-e8d8c8fe7d90";
    cc_acquire_lease("b1", owner);
    assert cc_release_lease("b1", other)["released"] is False;
    assert cc_snapshot("b1")["held"] is True;
    rel = cc_release_lease("b1", owner);
    assert rel["released"] is True and rel["snapshot"]["held"] is False;
    assert [c["snapshot"]["held"] for c in changes] == [True, False];
}

test "requestHelp surfaces the plea but never grants control" {
    _tracked();
    snap = cc_request_help("b1", "  please log in for me  ");
    assert snap["held"] is False;
    assert snap["helpReason"] == "please log in for me";
}

test "an empty reason still reads as a plea" {
    _tracked();
    assert cc_request_help("b1", None)["helpReason"] == "the bot asked you to take over";
}

test "a shouted second reason cannot clobber the one the person is reading" {
    _tracked();
    cc_request_help("b1", "first");
    assert cc_request_help("b1", "second")["helpReason"] == "first";
}

test "expires only the help request that owns the timeout" {
    changes = _tracked();
    first = cc_request_help_lease("b1", "first");
    assert cc_expire_help("b1", "some-older-request")["helpReason"] == "first";
    assert len(changes) == 1;
    assert cc_expire_help("b1", first["requestId"])["helpReason"] is None;
    assert len(changes) == 2;
}

test "an old timeout cannot dismiss a newer plea" {
    _tracked();
    first = cc_request_help_lease("b1", "first");
    cc_dismiss_help("b1");
    second = cc_request_help_lease("b1", "second");
    assert second["requestId"] != first["requestId"];
    assert cc_expire_help("b1", first["requestId"])["helpReason"] == "second";
}

test "a novel-length reason is cut to card size" {
    _tracked();
    assert len(cc_request_help("b1", "x" * 2000)["helpReason"]) == 280;
}

test "release settles an open help request in the same change" {
    _tracked();
    cc_request_help("b1", "stuck on a captcha");
    cc_take("b1");
    assert cc_release("b1") == {"held": False, "helpReason": None, "heldSinceMs": None};
}

test "dismiss clears the plea without taking control" {
    _tracked();
    cc_request_help("b1", "stuck");
    after = cc_dismiss_help("b1");
    assert after["helpReason"] is None;
    assert after["held"] is False;
}

test "dismiss while driving keeps the hold" {
    _tracked();
    cc_take("b1");
    cc_request_help("b1", "also this");
    after = cc_dismiss_help("b1");
    assert after["held"] is True;
    assert after["helpReason"] is None;
}

test "dismissing nothing is silent" {
    changes = _tracked();
    cc_dismiss_help("b1");
    assert changes == [];
}

test "bots are independent" {
    _tracked();
    cc_take("b1");
    assert cc_snapshot("b2")["held"] is False;
}

test "forget clears a hold and tells the listeners" {
    changes = _tracked();
    cc_take("b1");
    cc_forget("b1");
    assert cc_snapshot("b1")["held"] is False;
    assert changes[-1]["snapshot"] == {"held": False, "helpReason": None, "heldSinceMs": None};
}

test "forgetting an unknown bot is silent" {
    changes = _tracked();
    cc_forget("ghost");
    assert changes == [];
}

test "reports whether a lease holds the computer without taking a free one" {
    _tracked();
    assert cc_owns_lease("bot", "lease-aaaaaaaaaaaaaa") is False;
    assert cc_snapshot("bot")["held"] is False;
    cc_acquire_lease("bot", "lease-aaaaaaaaaaaaaa");
    assert cc_owns_lease("bot", "lease-aaaaaaaaaaaaaa") is True;
    assert cc_owns_lease("bot", "lease-bbbbbbbbbbbbbb") is False;
    cc_release("bot");
    assert cc_owns_lease("bot", "lease-aaaaaaaaaaaaaa") is False;
}

test "the mirror feed carries the lease but snapshots never do" {
    _tracked();
    leases: list[any] = [];
    def _on_change(key: str, snapshot: dict[str, any], lease: any) {
        leases.append(lease);
    }
    _cc["hooks"]["on_change"] = _on_change;
    cc_acquire_lease("bot", "lease-cccccccccccccc");
    assert leases == ["lease-cccccccccccccc"];
    entries = cc_entries();
    assert entries == [{"key": "bot", "snapshot": cc_snapshot("bot"), "controlLeaseId": "lease-cccccccccccccc"}];
}

test "def:pub surface answers an envelope and refuses a bad token" {
    _tracked();
    os.environ["OMB_JAC_TOKEN"] = "tok";
    try {
        assert computer_control_take(key="b9", omb_token="nope")["status"] == 403;
        assert computer_control_take(key="b9", omb_token="tok")["snapshot"]["held"] is True;
        assert computer_control_take(key=None, omb_token="tok")["status"] == 400;
        bad = shared_control_lease(action="steal", id="x", omb_token="tok");
        assert bad["ok"] is False and bad["status"] == 400;
    } finally {
        del os.environ["OMB_JAC_TOKEN"];
    }
}

# ── SharedComputerControl ───────────────────────────────────────────────────

def _shared_harness -> dict[str, any] {
    _tracked();
    h: dict[str, any] = {"seat": None, "held": False, "timers": []};
    def _held -> bool { return h["held"]; }
    def _claim(lease_id: str) -> bool {
        owner = "shared:" + lease_id;
        if h["seat"] is None or h["seat"] == owner {
            h["seat"] = owner;
            return True;
        }
        return False;
    }
    def _release(lease_id: str) {
        if h["seat"] == "shared:" + lease_id {
            h["seat"] = None;
        }
    }
    def _schedule(delay_ms: int, fn: any) -> any {
        t = FakeTimer(delay_ms=delay_ms, fn=fn);
        h["timers"].append(t);
        return t;
    }
    _cc["hooks"].update({"held": _held, "claim": _claim, "release": _release, "schedule": _schedule});
    return h;
}

obj FakeTimer {
    has delay_ms: int, fn: any, cancelled: bool = False;

    def cancel {
        self.cancelled = True;
    }
}

def _advance(h: dict[str, any]) {
    pending = [t for t in h["timers"] if not t.cancelled];
    h["timers"] = [];
    for t in pending {
        t.fn();
    }
}

def _refused(lease_id: str) -> str {
    try {
        sc_acquire(lease_id);
    } except Exception as e {
        assert _status_of(e) == 409;
        return str(e);
    }
    return "";
}

test "shared screen calls respect local turns, human takeover, lease expiry and release" {
    h = _shared_harness();
    h["seat"] = "local";
    assert "in use locally" in _refused("remote");
    h["seat"] = None;
    sc_acquire("remote");
    assert h["seat"] == "shared:remote";
    h["held"] = True;
    assert "held by a person" in _refused("remote");
    # A refused acquire released the lease and its seat.
    assert h["seat"] is None;
    assert sc_lease_ids() == [];
    h["held"] = False;
    sc_acquire("remote");
    _advance(h);
    assert h["seat"] is None;
    assert sc_lease_ids() == [];
    sc_acquire("remote");
    sc_close();
    assert h["seat"] is None;
}

test "renew re-arms a held lease and a stale timer cannot release it" {
    h = _shared_harness();
    sc_acquire("remote");
    first = h["timers"][0];
    sc_renew("remote");
    assert first.cancelled is True;
    # The stale callback fires anyway (a timer that raced its cancel): no-op.
    first.fn();
    assert h["seat"] == "shared:remote";
    assert sc_lease_ids() == ["remote"];
    # Renewing an expired id is a no-op; only acquire brings it back.
    _advance(h);
    assert sc_lease_ids() == [];
    sc_renew("remote");
    assert sc_lease_ids() == [];
    assert h["timers"] == [];
}
