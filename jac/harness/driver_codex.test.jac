"""Ported invariants from server/drivers/codex.test.ts, run against the same
scripted fake app-server (server/testing/fake-codex-app-server.ts).

Annexes driver_codex.jac (no self-import): the ops are called directly on an
instance record, and drivers._state's injected bridge_fn records every event
the driver emits — the analogue of recordEvents(instance.adapter). The
node-side surface (decodeConfig, snapshot, sign-in, plan auth) stays covered
by the TS suite; only adapter behavior is ported here.

Each test calls t_setup(), which tears down the previous test's turns and
environment first (the TS afterEach)."""

import os;
import re;
import json;
import time;
import shutil;
import tempfile;
import threading;

import from drivers { _state as _drivers_state }
import from driver_codex_support { mcp_server_names_in_toml }

glob _t: dict[str, any] = {
    "events": [],
    "hooks": [],
    "lock": threading.Lock(),
    "env": {},
    "dirs": [],
    "insts": [],
    "patched": {},
};

def t_fake_cli -> str {
    bases: list[any] = [];
    try {
        bases.append(os.path.dirname(os.path.abspath(__file__)));
    } except Exception {
    }
    bases.append(os.getcwd());
    for base in bases {
        cand = os.path.normpath(os.path.join(base, "..", "..", "server", "testing", "fake-codex-app-server.ts"));
        if os.path.isfile(cand) { return cand; }
    }
    return os.path.normpath(os.path.join(os.getcwd(), "..", "..", "server", "testing", "fake-codex-app-server.ts"));
}

def t_bridge(op: str, payload: dict[str, any]) -> dict[str, any] {
    if op == "driver_event" {
        ev = payload["event"];
        _t["lock"].acquire();
        try {
            _t["events"].append(ev);
            hooks = list(_t["hooks"]);
        } finally {
            _t["lock"].release();
        }
        for hook in hooks { hook(ev); }
    }
    return {"ok": True};
}

def t_env(name: str, value: any) {
    if name not in _t["env"] { _t["env"][name] = os.environ.get(name); }
    if value is None {
        os.environ.pop(name, None);
    } else {
        os.environ[name] = value;
    }
}

def t_patch(name: str, value: any) {
    # Swap a module global the driver resolves at call time (vi.spyOn).
    g = globals();
    if name not in _t["patched"] { _t["patched"][name] = g[name]; }
    g[name] = value;
}

def t_teardown {
    for inst in _t["insts"] {
        try {
            _stop_everything(inst);
        } except Exception {
        }
    }
    _t["insts"].clear();
    g = globals();
    for (name, value) in _t["patched"].items() { g[name] = value; }
    _t["patched"].clear();
    for (name, value) in _t["env"].items() {
        if value is None {
            os.environ.pop(name, None);
        } else {
            os.environ[name] = value;
        }
    }
    _t["env"].clear();
    _t["hooks"].clear();
    while len(_t["dirs"]) > 0 { shutil.rmtree(_t["dirs"].pop(), ignore_errors=True); }
}

def t_setup -> str {
    t_teardown();
    scratch = os.path.realpath(tempfile.mkdtemp(prefix="omb-codex-jac-"));
    _t["dirs"].append(scratch);
    t_env("OMB_DATA_DIR", os.path.join(scratch, "data"));
    t_env("FAKE_CODEX_MODE", None);
    t_env("FAKE_CODEX_DUMP", None);
    _drivers_state.update({"bridge_fn": t_bridge});
    _t["lock"].acquire();
    try {
        _t["events"].clear();
    } finally {
        _t["lock"].release();
    }
    return scratch;
}

def t_inst(scratch: str, mode: any = None, full_auto: bool = False, environment: any = None, managed: bool = False, auth_mode: any = None) -> dict[str, any] {
    if mode is not None { t_env("FAKE_CODEX_MODE", mode); }
    # Isolated from the operator's own ~/.codex unless a test says otherwise.
    env: dict[str, any] = {"HOME": scratch, "USERPROFILE": scratch, "CODEX_HOME": os.path.join(scratch, ".codex")};
    if managed { env["OPENMAUSBOT_COMPANY_API_KEY"] = "synthetic-company-fixture"; }
    if environment is not None { env.update(environment); }
    config: dict[str, any] = {"cli": t_fake_cli(), "fullAuto": full_auto};
    if auth_mode is not None { config["authMode"] = auth_mode; }
    if managed { config["managed"] = {"url": "http://127.0.0.1:1/v1", "models": ["company-codex-model"]}; }
    inst: dict[str, any] = {
        "instance_id": "codex-test",
        "kind": "codex",
        "display_name": "Codex Test",
        "environment": env,
        "enabled": True,
        "config": config,
        "sessions": {},
        "live": {},
    };
    _create(inst);
    _t["insts"].append(inst);
    return inst;
}

def t_events -> list[any] {
    _t["lock"].acquire();
    try {
        return list(_t["events"]);
    } finally {
        _t["lock"].release();
    }
}

def t_clear_events {
    _t["lock"].acquire();
    try {
        _t["events"].clear();
    } finally {
        _t["lock"].release();
    }
}

def t_until(pred: any, timeout: float = 60.0) -> dict[str, any] {
    deadline = time.monotonic() + timeout;
    while time.monotonic() < deadline {
        for ev in t_events() {
            if pred(ev) { return ev; }
        }
        time.sleep(0.01);
    }
    # Thread stacks make a stuck turn diagnosable rather than just slow.
    import sys;
    import traceback;
    stacks: list[str] = [];
    for (ident, frame) in sys._current_frames().items() {
        stacks.append("thread " + str(ident) + ":\n" + "".join(traceback.format_stack(frame)[-4:]));
    }
    raise AssertionError("timed out waiting for an event; saw " + json.dumps([ev.get("type") for ev in t_events()]) + "\n" + "\n".join(stacks));
}

def t_type(kind: str, thread_id: any = None, turn_id: any = None, timeout: float = 60.0) -> dict[str, any] {
    def pred(ev: dict[str, any]) -> bool {
        if ev.get("type") != kind { return False; }
        if thread_id is not None and ev.get("threadId") != thread_id { return False; }
        if turn_id is not None and ev.get("turnId") != turn_id { return False; }
        return True;
    }
    return t_until(pred, timeout);
}

def t_of(kind: str) -> list[any] {
    return [ev for ev in t_events() if ev.get("type") == kind];
}

def t_errors(fragment: str = "") -> list[any] {
    return [ev for ev in t_events() if ev.get("type") == "runtime.error" and fragment in ev.get("message", "")];
}

def t_dump(path: str) -> dict[str, any] {
    for _ in range(200) {
        try {
            f = open(path, "r", encoding="utf-8");
            try {
                return json.loads(f.read());
            } finally {
                f.close();
            }
        } except Exception {
            time.sleep(0.02);
        }
    }
    raise AssertionError("no dump at " + path);
}

def t_calls(path: str, method: str) -> list[any] {
    return [c for c in t_dump(path)["calls"] if c["method"] == method];
}

def t_methods(path: str) -> list[any] {
    # A refusal before thread/start leaves no dump: nothing was called.
    if not os.path.exists(path) { return []; }
    return [c["method"] for c in t_dump(path)["calls"]];
}

def t_dump_at(scratch: str, name: str) -> str {
    path = os.path.join(scratch, name);
    t_env("FAKE_CODEX_DUMP", path);
    return path;
}

def t_alive(pid: int) -> bool {
    try {
        os.kill(pid, 0);
    } except Exception {
        return False;
    }
    # A reaped-or-zombie child of ours still answers kill(0); treat zombies
    # as dead the way node's process.kill does after the close event.
    try {
        f = open("/proc/" + str(pid) + "/stat", "r");
        try {
            state = f.read().split(")")[-1].strip().split(" ")[0];
        } finally {
            f.close();
        }
        return state != "Z";
    } except Exception {
        return True;
    }
}

def t_raises(fn: any, pattern: str) {
    try {
        fn();
    } except Exception as e {
        assert re.search(pattern, str(e), re.I), "error " + json.dumps(str(e)) + " does not match " + pattern;
        return;
    }
    raise AssertionError("expected an exception matching " + pattern);
}

def t_wait_for(check: any, timeout: float = 5.0) -> bool {
    deadline = time.monotonic() + timeout;
    while time.monotonic() < deadline {
        if check() { return True; }
        time.sleep(0.02);
    }
    return check();
}

def t_native_log(scratch: str, thread_id: str) -> str {
    path = os.path.join(scratch, "data", "native", thread_id + ".ndjson");
    f = open(path, "r", encoding="utf-8");
    try {
        return f.read();
    } finally {
        f.close();
    }
}

def t_write(path: str, text: str) {
    os.makedirs(os.path.dirname(path), exist_ok=True);
    f = open(path, "w", encoding="utf-8");
    try {
        f.write(text);
    } finally {
        f.close();
    }
}

def t_subset(actual: any, expected: any) -> bool {
    # toMatchObject: every expected key present with a matching value.
    if isinstance(expected, dict) {
        if not isinstance(actual, dict) { return False; }
        for (key, value) in expected.items() {
            if key not in actual or not t_subset(actual[key], value) { return False; }
        }
        return True;
    }
    if isinstance(expected, list) {
        if not isinstance(actual, list) or len(actual) != len(expected) { return False; }
        for i in range(len(expected)) {
            if not t_subset(actual[i], expected[i]) { return False; }
        }
        return True;
    }
    return actual == expected;
}

# ── pure helpers ───────────────────────────────────────────────────────────

test "makes plan/provider failures actionable without changing billing" {
    assert "Continue with ChatGPT" in codex_user_error("provider_not_configured", False);
    assert "API billing will not be used" in codex_user_error("provider_not_configured", True);
    assert codex_user_error("x" * 500 + "subscription_sharing_usage_limit_exceeded", True).startswith("subscription_sharing_usage_limit_exceeded:");
    assert len(codex_user_error("y" * 500, False)) == 400;
}

test "omits a late config/read response even after its pending promise timed out" {
    late = {"jsonrpc": "2.0", "id": 17, "result": {"config": {"mcp_servers": {"example": {"env": {"LABEL": "late-innocuous-secret"}}}}}};
    logged = codex_native_incoming_log_message(late, {17});
    assert logged == {"jsonrpc": "2.0", "id": 17, "result": "[effective config omitted]"};
    assert "late-innocuous-secret" not in json.dumps(logged);
    assert codex_native_incoming_log_message({"jsonrpc": "2.0", "id": 17, "error": {"code": -1, "message": "secret-bearing provider error"}}, {17}) == {"jsonrpc": "2.0", "id": 17, "error": "[config/read error omitted]"};
}

test "maps bundled question replies per id and the flat single-question fallback" {
    qs = parse_protocol_ask_questions([
        {"id": "q-ship", "question": "Ship today?", "options": [{"label": "Yes"}, {"label": "No"}]},
        {"id": "q-review", "question": "Who reviews?", "options": [{"label": "Ada"}]},
    ]);
    assert [q["id"] for q in qs] == ["q-ship", "q-review"];
    assert question_answers_by_id("The user answered your questions.\n\nQ: Ship today?\nA: Yes\n\nQ: Who reviews?\nA: Ada", qs) == {"q-ship": "Yes", "q-review": "Ada"};
    assert question_answers_by_id("Q: Ship today?\nA: Yes", qs) == {"q-ship": "Yes"};
    assert question_answers_by_id("Yes", qs) == {};
    one = parse_protocol_ask_questions([{"id": "q", "question": "Ship?"}]);
    assert question_answers_by_id(" Yes ", one) == {"q": "Yes"};
    assert question_answers_by_id("Q: Ship?\nA: ", one) == {};
    # a duplicate id fails the whole request
    assert parse_protocol_ask_questions([{"id": "a", "question": "x"}, {"id": "a", "question": "y"}]) is None;
    assert parse_protocol_ask_questions([]) is None;
    assert parse_protocol_ask_questions("please") is None;
}

test "names declared config.toml MCP servers and mounts a collision under its own name" {
    names = mcp_server_names_in_toml('[mcp_servers.fibery]\nurl = "x"\n[mcp_servers."quoted.name"]\n[mcp_servers.fibery.env]\n');
    assert names == ["fibery", "quoted.name"];
    assert mounted_mcp_server_name("fibery", ["fibery"]) == "fibery_openmausbot";
    assert mounted_mcp_server_name("fibery", ["fibery", "fibery_openmausbot"]) == "fibery_openmausbot2";
    assert mounted_mcp_server_name("notes", ["fibery"]) == "notes";
}

test "decodes picker selections into model and provider" {
    assert decode_codex_selection("fixture::local-model") == {"model": "local-model", "modelProvider": "fixture"};
    assert decode_codex_selection("gpt-6.1-sol") == {"model": "gpt-6.1-sol", "modelProvider": "openai"};
    assert decode_codex_selection(None) == {"model": None, "modelProvider": None};
}

# ── turns against the fake app-server ─────────────────────────────────────

test "refuses native selection before a Codex prompt" {
    scratch = t_setup();
    dump = t_dump_at(scratch, "scope-refused.json");
    inst = t_inst(scratch, full_auto=True);
    def go { _op_send_turn(inst, {"threadId": "scope-refused", "text": "Must not run", "resumeCursor": "old-session", "approvalMode": "full", "toolScope": {"allow": []}}); }
    t_raises(go, "native tool selection.*not supported");
    assert not os.path.exists(dump);
}

test "gates raw custom identities before mount renaming and disables ambient MCP servers" {
    scratch = t_setup();
    dump = t_dump_at(scratch, "scope-mcp.json");
    t_write(os.path.join(scratch, ".codex", "config.toml"), '[mcp_servers.notes]\nurl="https://example.test/ambient"\n');
    inst = t_inst(scratch, environment={"FAKE_CODEX_MCP_OVERRIDES": "1"});
    turn = {"threadId": "scope-mcp", "text": "Fixture", "toolScope": {"allow": ["native:*", "mcp:notes:read"]}, "integrations": {"custom": {"notes": {"type": "sse", "url": "https://example.test/notes", "headers": {}}}}};
    _op_send_turn(inst, turn);
    t_type("turn.completed");
    seen = t_dump(dump);
    assert "mcp_servers.notes.enabled=false" in seen["argv"];
    assert "OMB_GATE_CONFIG_" in json.dumps(seen["argv"]);
    assert "https://example.test/notes" not in json.dumps(seen["argv"]);
    assert len(t_calls(dump, "turn/start")) == 1;
    servers = t_calls(dump, "thread/start")[0]["params"]["config"]["mcp_servers"];
    assert list(servers.keys()) == ["notes_openmausbot"];
    assert servers["notes_openmausbot"]["default_tools_approval_mode"] == "prompt";
    t_clear_events();
    resumed = dict(turn);
    resumed["text"] = "Continue";
    resumed["resumeCursor"] = "old-session";
    _op_send_turn(inst, resumed);
    t_type("turn.completed");
    servers2 = t_calls(dump, "thread/resume")[0]["params"]["config"]["mcp_servers"];
    assert list(servers2.keys()) == ["notes_openmausbot"];
    assert servers2["notes_openmausbot"]["default_tools_approval_mode"] == "prompt";
}

test "refuses a scoped prompt when effective Codex configuration still has an ambient MCP server" {
    scratch = t_setup();
    dump = t_dump_at(scratch, "scope-ambient.json");
    inst = t_inst(scratch);
    _op_send_turn(inst, {"threadId": "scope-ambient", "text": "Must not run", "toolScope": {"allow": ["native:*"]}});
    t_type("turn.completed");
    assert "turn/start" not in t_methods(dump);
    assert len(t_errors("outside the selected configuration")) == 1;
}

test "preserves shell exclusions for scoped turns on new and resumed threads" {
    for approval_mode in ["ask", "custom", "full"] {
        scratch = t_setup();
        dump = t_dump_at(scratch, "shell-policy.json");
        policy = {"inherit": "all", "ignore_default_excludes": True, "exclude": ["USER_SECRET_*"], "include_only": ["*"], "set": {"SAFE_FIXTURE_LABEL": "retained"}};
        inst = t_inst(scratch, mode="resume", environment={"FAKE_CODEX_MCP_OVERRIDES": "1", "FAKE_CODEX_SHELL_ENVIRONMENT_POLICY": json.dumps(policy)});
        for cursor in [None, "old-session"] {
            turn: dict[str, any] = {"threadId": "scoped-shell", "text": "Fixture", "approvalMode": approval_mode,
                "toolScope": {"allow": ["native:*", "mcp:notes:read"]},
                "integrations": {"custom": {"notes": {"type": "http", "url": "https://example.test/notes", "headers": {"authorization": "synthetic-fixture-credential"}}}}};
            if cursor is not None { turn["resumeCursor"] = cursor; }
            turn_id = _op_send_turn(inst, turn);
            done = t_type("turn.completed", turn_id=turn_id);
            assert done["ok"] is True, json.dumps(t_errors());
            seen = t_dump(dump);
            assert "features.shell_snapshot=false" in seen["argv"];
            method = "thread/resume" if cursor is not None else "thread/start";
            params = t_calls(dump, method)[0]["params"];
            assert params["config"]["shell_environment_policy.exclude"] == ["USER_SECRET_*", "OMB_GATE_CONFIG_*"];
            assert "shell_environment_policy" not in params["config"];
            assert any([name.startswith("OMB_GATE_CONFIG_") for name in seen["env"].keys()]);
            assert "synthetic-fixture-credential" not in json.dumps({"argv": seen["argv"], "calls": seen["calls"]});
        }
    }
}

test "refuses a scoped prompt when inherited shell snapshots cannot be disabled" {
    scratch = t_setup();
    dump = t_dump_at(scratch, "unsafe-shell-snapshot.json");
    inst = t_inst(scratch, environment={"FAKE_CODEX_MCP_OVERRIDES": "1", "FAKE_CODEX_IGNORE_FEATURES": "1"});
    turn_id = _op_send_turn(inst, {"threadId": "unsafe-shell-snapshot", "text": "Must not run.", "toolScope": {"allow": ["native:*", "mcp:notes:read"]},
        "integrations": {"custom": {"notes": {"type": "http", "url": "https://example.test/notes", "headers": {}}}}});
    assert t_type("turn.completed", turn_id=turn_id)["ok"] is False;
    assert len(t_errors("shell snapshots")) == 1;
    assert "turn/start" not in t_methods(dump);
}

test "refuses a scoped prompt with a malformed shell policy" {
    for policy in [None, False, [], {"exclude": None}, {"exclude": ["SAFE_*", 42]}] {
        scratch = t_setup();
        dump = t_dump_at(scratch, "invalid-shell-policy.json");
        inst = t_inst(scratch, environment={"FAKE_CODEX_MCP_OVERRIDES": "1", "FAKE_CODEX_SHELL_ENVIRONMENT_POLICY": json.dumps(policy)});
        turn_id = _op_send_turn(inst, {"threadId": "invalid-shell-policy", "text": "Must not run.", "toolScope": {"allow": ["native:*", "mcp:notes:read"]},
            "integrations": {"custom": {"notes": {"type": "http", "url": "https://example.test/notes", "headers": {}}}}});
        assert t_type("turn.completed", turn_id=turn_id)["ok"] is False;
        assert len(t_errors("shell environment")) == 1, json.dumps(policy);
        assert "turn/start" not in t_methods(dump);
    }
}

test "surfaces one attributed Auto-review timeout without failing a completed reply" {
    scratch = t_setup();
    scope = {"threadId": "codex-thread-1", "turnId": "turn-1"};
    completed = dict(scope);
    completed.update({"reviewId": "review-1", "targetItemId": "tool-1", "review": {"status": "timedOut"},
        "action": {"type": "command", "source": "unifiedExec", "command": "git status --short"}});
    t_env("FAKE_CODEX_REVIEW_EVENTS", json.dumps([
        {"method": "guardianWarning", "params": {"threadId": "codex-thread-1", "message": "Automatic approval review timed out."}},
        {"method": "item/autoApprovalReview/completed", "params": completed},
    ]));
    inst = t_inst(scratch, mode="review-events");
    _op_send_turn(inst, {"threadId": "app-thread", "text": "check", "approvalMode": "auto"});
    done = t_type("turn.completed");
    notices = t_errors("automatic review");
    assert len(notices) == 1;
    assert notices[0]["threadId"] == "app-thread" and "git status --short" in notices[0]["message"];
    assert re.search("Ask.*Auto|Auto.*Ask", notices[0]["message"]);
    assert done["ok"] is True;
}

test "names Custom rather than Auto when Custom uses native automatic review" {
    scratch = t_setup();
    t_env("FAKE_CODEX_REVIEW_EVENTS", json.dumps([{"method": "item/autoApprovalReview/completed",
        "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "reviewId": "custom-1", "review": {"status": "timedOut"}}}]));
    inst = t_inst(scratch, mode="review-events", full_auto=True);
    _op_send_turn(inst, {"threadId": "app-thread", "text": "check", "approvalMode": "custom"});
    t_type("turn.completed");
    notices = t_errors("automatic review");
    assert len(notices) == 1 and "Retry stays Custom" in notices[0]["message"];
}

test "handles review results without contaminating another turn" {
    cases: list[any] = [
        [[{"method": "guardianWarning", "params": {"threadId": "codex-thread-1", "message": "Automatic approval review timed out."}}], "reported a timeout"],
        [[{"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "reviewId": "denied-1", "review": {"status": "denied"}}}], "denied"],
        [[{"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "reviewId": "approved-1", "review": {"status": "approved"}}}], None],
        [[{"method": "guardianWarning", "params": {"threadId": "codex-thread-1", "message": "Automatic approval review timed out."}},
          {"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "reviewId": "approved-1", "review": {"status": "approved"}}}], "reported a timeout"],
        [[{"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "review": {"status": "futureStatus"}}}], None],
        [[{"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1"}}], None],
        [[{"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "reviewId": "same", "review": {"status": "timedOut"}}},
          {"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "reviewId": "same", "review": {"status": "timedOut"}}}], "timed out"],
        [[{"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "review": {"status": "timedOut"}}},
          {"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "review": {"status": "timedOut"}}}], None],
        [[{"method": "guardianWarning", "params": {"threadId": "helper-thread", "message": "Automatic approval review timed out."}},
          {"method": "item/autoApprovalReview/completed", "params": {"threadId": "helper-thread", "turnId": "turn-1", "review": {"status": "timedOut"}}},
          {"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "old-turn", "review": {"status": "timedOut"}}},
          {"method": "guardianWarning", "params": {"threadId": "codex-thread-1", "turnId": "old-turn", "message": "Automatic approval review timed out."}},
          {"method": "guardianWarning", "params": {"threadId": "codex-thread-1", "turnId": None, "message": "Automatic approval review timed out."}}], None],
    ];
    for row_case in cases {
        scratch = t_setup();
        t_env("FAKE_CODEX_REVIEW_EVENTS", json.dumps(row_case[0]));
        inst = t_inst(scratch, mode="review-events");
        _op_send_turn(inst, {"threadId": "app-thread", "text": "check", "approvalMode": "auto"});
        t_type("turn.completed");
        notices = t_errors("automatic review");
        expected = row_case[1];
        assert len(notices) == (1 if expected else 0), json.dumps(row_case);
        if expected { assert expected in notices[0]["message"]; }
    }
}

test "keeps distinct review failures separate" {
    cases: list[any] = [
        [[{"method": "guardianWarning", "params": {"threadId": "codex-thread-1", "message": "Automatic approval review timed out."}},
          {"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "reviewId": "denied-1", "review": {"status": "denied"}}}],
         ["denied", "reported a timeout"]],
        [[{"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "reviewId": "first", "review": {"status": "timedOut"}}},
          {"method": "item/autoApprovalReview/completed", "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "reviewId": "second", "review": {"status": "timedOut"}}}],
         ["timed out", "timed out"]],
    ];
    for row_case in cases {
        scratch = t_setup();
        t_env("FAKE_CODEX_REVIEW_EVENTS", json.dumps(row_case[0]));
        inst = t_inst(scratch, mode="review-events");
        _op_send_turn(inst, {"threadId": "app-thread", "text": "check", "approvalMode": "auto"});
        t_type("turn.completed");
        notices = t_errors("automatic review");
        assert len(notices) == len(row_case[1]);
        for i in range(len(notices)) { assert row_case[1][i] in notices[i]["message"]; }
    }
}

test "ignores a review result delayed past turn completion" {
    scratch = t_setup();
    t_env("FAKE_CODEX_REVIEW_AFTER_COMPLETION", json.dumps({"method": "item/autoApprovalReview/completed",
        "params": {"threadId": "codex-thread-1", "turnId": "turn-1", "reviewId": "late", "review": {"status": "timedOut"}}}));
    inst = t_inst(scratch, mode="review-events");
    _op_send_turn(inst, {"threadId": "app-thread", "text": "check", "approvalMode": "auto"});
    t_type("turn.completed");
    time.sleep(0.05);
    assert len(t_errors("automatic review")) == 0;
}

test "runs a guest's turn with no environment and the shell off, proven before the turn starts" {
    scratch = t_setup();
    inst = t_inst(scratch);
    dump = t_dump_at(scratch, "dump.json");
    _op_send_turn(inst, {"threadId": "t-guest", "text": "cat /proc/1/environ", "system": "You are Testy.", "model": "gpt-5.6-sol", "approvalMode": "ask", "guestConfined": True});
    t_type("turn.completed");
    seen = t_dump(dump);
    for flag_name in ["features.shell_tool=false", "features.unified_exec=false", "features.view_image=false"] {
        assert seen["argv"][seen["argv"].index(flag_name) - 1] == "-c";
    }
    assert t_calls(dump, "thread/start")[0]["params"]["environments"] == [];
    assert t_calls(dump, "turn/start")[0]["params"]["environments"] == [];
    _op_send_turn(inst, {"threadId": "t-owner", "text": "ls", "system": "You are Testy.", "model": "gpt-5.6-sol", "approvalMode": "ask"});
    t_type("turn.completed", thread_id="t-owner");
    owner = t_dump(dump);
    assert "features.shell_tool=false" not in owner["argv"];
    assert "environments" not in t_calls(dump, "turn/start")[0]["params"];
}

test "refuses a guest's turn when Codex did not take the shell-off overrides" {
    scratch = t_setup();
    inst = t_inst(scratch, environment={"FAKE_CODEX_IGNORE_FEATURES": "1"});
    dump = t_dump_at(scratch, "dump.json");
    _op_send_turn(inst, {"threadId": "t-guest", "text": "cat /proc/1/environ", "system": "You are Testy.", "model": "gpt-5.6-sol", "approvalMode": "ask", "guestConfined": True});
    done = t_type("turn.completed");
    assert "turn/start" not in t_methods(dump);
    assert "could not turn its shell off" in json.dumps(t_events());
    assert done["ok"] is False;
}

test "runs the handshake and normalizes a full turn" {
    scratch = t_setup();
    inst = t_inst(scratch);
    dump = t_dump_at(scratch, "dump.json");
    t_env("OPENAI_API_KEY", "sk-should-not-leak");
    t_env("BOX_TOKEN", "box-should-not-leak");
    t_env("OMB_TTS_KEY", "tts-should-not-leak");
    t_env("OMB_CLOUD_READY_TOKEN", "ready-should-not-leak");
    t_env("OMB_LICENSE_KEY", "license-should-not-leak");
    t_env("OMB_INSTALLATION_CREDENTIAL", "fleet-should-not-leak");
    turn_id = _op_send_turn(inst, {"threadId": "t-happy", "text": "list files", "system": "You are Testy.", "model": "gpt-5.6-sol"});
    t_type("turn.completed");
    evs = t_events();
    assert [ev["type"] for ev in evs] == [
        "turn.started", "session.started", "item.started", "item.started", "item.completed", "item.completed",
        "content.delta", "item.completed", "thread.token-usage.updated", "turn.completed",
    ], json.dumps([ev["type"] for ev in evs]);
    assert all([ev["turnId"] == turn_id and ev["provider"] == "codex" for ev in evs]);
    assert t_subset(t_of("session.started")[0], {"sessionId": "codex-thread-1", "model": "fake-codex-model"});
    assert t_subset(t_of("thread.token-usage.updated")[0], {"input": 7, "output": 3, "cachedInput": 4, "contextTokens": 7, "contextWindow": 272000});
    w1 = [ev for ev in evs if ev.get("itemId") == "w1"];
    assert t_subset(w1, [{"type": "item.started", "itemType": "tool", "title": "web_search"}, {"type": "item.completed", "itemType": "tool", "ok": True}]);
    i1 = [ev for ev in evs if ev.get("itemId") == "i1"];
    assert "ls -la" in i1[0]["input"] and "README.md" in i1[1]["output"];
    assert "exitCode" in json.dumps(i1[1]);
    assert "codex-output-secret" not in json.dumps(i1[1]);
    assert t_subset(evs[-1], {"type": "turn.completed", "ok": True, "usage": {"input": 7, "output": 3, "cachedInput": 4}});
    seen = t_dump(dump);
    assert not t_alive(seen["pid"]);
    for name in ["OPENAI_API_KEY", "BOX_TOKEN", "OMB_TTS_KEY", "OMB_CLOUD_READY_TOKEN", "OMB_LICENSE_KEY", "OMB_INSTALLATION_CREDENTIAL"] {
        assert name not in seen["env"], name;
    }
    assert t_methods(dump) == ["initialize", "initialized", "config/read", "thread/start", "turn/start"];
    assert seen["calls"][-1]["params"]["input"][0]["text"] == "list files";
    assert t_subset(t_calls(dump, "thread/start")[0]["params"], {"model": "gpt-5.6-sol", "modelProvider": "openai", "developerInstructions": "You are Testy."});
}

test "keeps the developer slot stable and delivers volatile context in-turn" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="resume");
    def send(dump_name: str, text: str, volatile: str, cursor: any = None, mention: bool = False) -> list[any] {
        path = t_dump_at(scratch, dump_name);
        turn: dict[str, any] = {"threadId": "t-prompt-split", "text": text, "system": "Stable rules.", "systemStable": "Stable rules.", "systemVolatile": volatile};
        if cursor is not None { turn["resumeCursor"] = cursor; }
        if mention { turn["mentionTurn"] = True; }
        turn_id = _op_send_turn(inst, turn);
        t_type("turn.completed", turn_id=turn_id);
        return t_dump(path)["calls"];
    }
    def turn_text(calls: list[any]) -> str {
        return [c for c in calls if c["method"] == "turn/start"][0]["params"]["input"][0]["text"];
    }
    first = send("split-1.json", "first", "Memory: likes quiet hours.");
    second = send("split-2.json", "second", "Memory: likes quiet hours.", "codex-thread-1");
    third = send("split-3.json", "third", "Memory: moved to Toronto.", "codex-thread-1");
    starts = [c for c in first if c["method"] == "thread/start"];
    assert len(starts) == 1 and starts[0]["params"]["developerInstructions"] == "Stable rules.";
    for calls in [first, second, third] {
        assert "thread/inject_items" not in [c["method"] for c in calls];
    }
    assert turn_text(first) == "Context from OpenMausBot updated since this conversation started; it replaces any earlier copy:\n\nMemory: likes quiet hours.\n\nfirst";
    assert turn_text(second) == "second";
    assert "Memory: moved to Toronto." in turn_text(third) and "third" in turn_text(third);
    fourth = send("split-4.json", "fourth", "Memory: moved to Toronto.", "codex-thread-1", True);
    assert "Memory: moved to Toronto." in turn_text(fourth) and "fourth" in turn_text(fourth);
}

test "ignores requests received after turn completion" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="late-request");
    _op_send_turn(inst, {"threadId": "t-late-request", "text": "finish"});
    t_type("turn.completed");
    assert len(t_of("request.opened")) == 0;
}

test "keeps the parent working after helper completion and ignores foreign output and usage" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="helper-events");
    _op_send_turn(inst, {"threadId": "t-helper-events", "text": "use a helper then continue"});
    permission = t_type("request.opened");
    assert permission["summary"] == "echo parent continues";
    assert len(t_of("turn.completed")) == 0;
    assert "FOREIGN" not in json.dumps(t_events());
    assert len(t_of("thread.token-usage.updated")) == 0;
    assert _op_respond(inst, "t-helper-events", permission["requestId"], {"behavior": "allow"}) == "allowed-once";
    t_type("turn.completed");
    assert len(t_of("turn.completed")) == 1;
    assert t_subset(t_events()[-1], {"ok": True, "usage": {"input": 7, "output": 3}});
    assert [ev for ev in t_events() if ev["type"] == "item.completed" and ev.get("itemType") == "assistant_text"][0]["text"] == "done from fake codex";
    repeat = _op_send_turn(inst, {"threadId": "t-helper-events", "resumeCursor": "codex-thread-1", "text": "continue and deny the next request"});
    denied = t_type("request.opened", turn_id=repeat);
    assert _op_respond(inst, "t-helper-events", denied["requestId"], {"behavior": "deny"}) == "rejected";
    t_type("turn.completed", turn_id=repeat);
    assert len(t_of("turn.completed")) == 2;
    assert t_events()[-1]["ok"] is True;
    assert [ev for ev in t_events() if ev["type"] == "request.resolved" and ev["turnId"] == repeat][0]["behavior"] == "deny";
    assert "FOREIGN" not in json.dumps(t_events());
}

test "retains parent notifications delivered before the turn/start response" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="early-turn-events");
    _op_send_turn(inst, {"threadId": "t-early-events", "text": "finish quickly"});
    t_type("turn.completed");
    assert t_events()[-1]["ok"] is True;
    assert len(t_of("turn.completed")) == 1;
    assert [ev for ev in t_events() if ev["type"] == "item.completed" and ev.get("itemType") == "assistant_text"][0]["text"] == "done from fake codex";
}

test "reasserts the approval mode on thread start and turn start" {
    for row in [["ask", "on-request", "workspace-write", "workspaceWrite"], ["auto", "on-request", "workspace-write", "workspaceWrite"], ["full", "never", "danger-full-access", "dangerFullAccess"]] {
        scratch = t_setup();
        inst = t_inst(scratch);
        dump = t_dump_at(scratch, row[0] + ".json");
        _op_send_turn(inst, {"threadId": "t-" + row[0], "text": "continue", "approvalMode": row[0]});
        t_type("turn.completed");
        reviewer = "auto_review" if row[0] == "auto" else "user";
        assert t_subset(t_calls(dump, "thread/start")[0]["params"], {"approvalPolicy": row[1], "approvalsReviewer": reviewer, "sandbox": row[2]});
        assert t_subset(t_calls(dump, "turn/start")[0]["params"], {"approvalPolicy": row[1], "approvalsReviewer": reviewer, "sandboxPolicy": {"type": row[3]}});
    }
}

test "preserves the complete resolved sandbox" {
    for resumed in [False, True] {
        scratch = t_setup();
        inst = t_inst(scratch, mode="resume");
        dump = t_dump_at(scratch, "resolved-sandbox.json");
        sandbox = {"type": "workspaceWrite", "networkAccess": True, "writableRoots": [os.path.join(scratch, "extra-root")], "excludeTmpdirEnvVar": True, "excludeSlashTmp": True};
        t_env("FAKE_CODEX_RESOLVED_SANDBOX", json.dumps(sandbox));
        turn: dict[str, any] = {"threadId": "t-resolved", "text": "continue", "approvalMode": "ask"};
        if resumed { turn["resumeCursor"] = "codex-thread-1"; }
        _op_send_turn(inst, turn);
        t_type("turn.completed");
        assert t_events()[-1]["ok"] is True;
        assert t_calls(dump, "turn/start")[0]["params"]["sandboxPolicy"] == sandbox;
    }
}

test "refuses an absent or mismatched resolved sandbox" {
    for resumed in [False, True] {
        for sandbox in [None, {}, {"type": "dangerFullAccess"}] {
            scratch = t_setup();
            inst = t_inst(scratch, mode="resume");
            dump = t_dump_at(scratch, "invalid-sandbox.json");
            t_env("FAKE_CODEX_RESOLVED_SANDBOX", json.dumps(sandbox));
            turn: dict[str, any] = {"threadId": "t-invalid-sandbox", "text": "continue", "approvalMode": "ask"};
            if resumed { turn["resumeCursor"] = "codex-thread-1"; }
            _op_send_turn(inst, turn);
            t_type("turn.completed");
            assert t_events()[-1]["ok"] is False;
            if not sandbox or "type" not in sandbox { assert len(t_errors("Update Codex")) == 1; }
            assert "turn/start" not in t_methods(dump);
        }
    }
}

test "reapplies Full, Auto, and Ask across thread start and resume" {
    for model in ["gpt-5.6-sol", "gpt-5.4"] {
        scratch = t_setup();
        inst = t_inst(scratch, mode="resume", full_auto=True);
        dump = t_dump_at(scratch, "approval-transitions.json");
        for row in [["full", "never", "danger-full-access", "dangerFullAccess"], ["auto", "on-request", "workspace-write", "workspaceWrite"], ["ask", "on-request", "workspace-write", "workspaceWrite"]] {
            resumed = row[0] != "full";
            turn: dict[str, any] = {"threadId": "t-mode-transitions", "text": "continue", "model": model, "approvalMode": row[0]};
            if resumed { turn["resumeCursor"] = "codex-thread-1"; }
            turn_id = _op_send_turn(inst, turn);
            t_type("turn.completed", turn_id=turn_id);
            reviewer = "auto_review" if row[0] == "auto" else "user";
            expected: dict[str, any] = {"approvalPolicy": row[1], "approvalsReviewer": reviewer, "sandbox": row[2]};
            if resumed { expected["threadId"] = "codex-thread-1"; } else { expected["model"] = model; }
            assert t_subset(t_calls(dump, "thread/resume" if resumed else "thread/start")[0]["params"], expected);
            assert t_subset(t_calls(dump, "turn/start")[0]["params"], {"approvalPolicy": row[1], "approvalsReviewer": reviewer, "sandboxPolicy": {"type": row[3]}});
        }
    }
}

test "reasserts the effective config.toml settings for Custom" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="resume", full_auto=True);
    dump = t_dump_at(scratch, "custom.json");
    _op_send_turn(inst, {"threadId": "t-custom", "text": "continue", "approvalMode": "custom", "resumeCursor": "codex-thread-custom"});
    t_type("turn.completed");
    read = t_calls(dump, "config/read")[0]["params"];
    assert isinstance(read["cwd"], str) and read["includeLayers"] is False;
    assert t_subset(t_calls(dump, "thread/resume")[0]["params"], {"threadId": "codex-thread-custom", "approvalPolicy": "never", "approvalsReviewer": "auto_review", "sandbox": "read-only"});
    assert t_subset(t_calls(dump, "turn/start")[0]["params"], {"approvalPolicy": "never", "approvalsReviewer": "auto_review", "sandboxPolicy": {"type": "readOnly"}});
    log = t_native_log(scratch, "t-custom");
    assert "[effective config omitted]" in log;
    assert "innocuous-config-secret-7a9c" not in log;
}

test "reasserts a named Custom permission profile through thread start/resume and turn/start" {
    profile_rows: list[any] = [["thread/start", None], ["thread/resume", "codex-thread-profile"]];
    for row in profile_rows {
        scratch = t_setup();
        inst = t_inst(scratch, mode="config-profile");
        thread_id = "t-custom-profile-" + row[0].replace("/", "-");
        dump = t_dump_at(scratch, thread_id + ".json");
        turn: dict[str, any] = {"threadId": thread_id, "text": "continue with my profile", "approvalMode": "custom"};
        if row[1] is not None { turn["resumeCursor"] = row[1]; }
        _op_send_turn(inst, turn);
        t_type("turn.completed");
        assert t_subset(t_calls(dump, "initialize")[0]["params"], {"capabilities": {"experimentalApi": True}});
        thread_params = t_calls(dump, row[0])[0]["params"];
        assert t_subset(thread_params, {"permissions": "private-operator-profile", "approvalPolicy": "on-request", "approvalsReviewer": "user"});
        assert "sandbox" not in thread_params;
        turn_params = t_calls(dump, "turn/start")[0]["params"];
        assert t_subset(turn_params, {"permissions": "private-operator-profile", "approvalPolicy": "on-request", "approvalsReviewer": "user"});
        assert "sandboxPolicy" not in turn_params;
    }
}

test "falls back to the safe legacy Custom settings when profiles are unsupported" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="config-profile-unsupported");
    dump = t_dump_at(scratch, "custom-profile-fallback.json");
    _op_send_turn(inst, {"threadId": "t-custom-profile-fallback", "text": "continue safely", "approvalMode": "custom", "resumeCursor": "codex-thread-profile-fallback"});
    t_type("turn.completed");
    resumes = t_calls(dump, "thread/resume");
    assert len(resumes) == 2;
    assert t_subset(resumes[0]["params"], {"permissions": "private-operator-profile"});
    assert t_subset(resumes[1]["params"], {"approvalPolicy": "on-request", "approvalsReviewer": "user", "sandbox": "read-only"});
    assert t_subset(t_calls(dump, "turn/start")[0]["params"], {"approvalPolicy": "on-request", "approvalsReviewer": "user", "sandboxPolicy": {"type": "readOnly"}});
}

test "stops before replacing unknown native instructions in every mode" {
    for approval_mode in ["ask", "auto", "full", "custom"] {
        scratch = t_setup();
        inst = t_inst(scratch, mode="config-read-error");
        dump = t_dump_at(scratch, "custom-config-error.json");
        _op_send_turn(inst, {"threadId": "t-custom-config-error", "text": "continue safely", "approvalMode": approval_mode});
        assert t_type("turn.completed")["ok"] is False;
        assert t_methods(dump) == ["initialize", "initialized", "config/read"];
        assert len(t_errors("cannot safely update bot instructions")) == 1;
    }
}

test "sends current-turn images as native localImage inputs without logging their private paths" {
    scratch = t_setup();
    inst = t_inst(scratch);
    dump = t_dump_at(scratch, "images.json");
    image_path = os.path.join(scratch, "private image.png");
    t_write(image_path, "png");
    _op_send_turn(inst, {"threadId": "t-native-input-image", "text": "describe this", "system": "You are Testy.", "images": [{"path": image_path, "mime": "image/png", "bytes": 3}]});
    t_type("turn.completed");
    assert t_calls(dump, "turn/start")[0]["params"]["input"] == [{"type": "text", "text": "describe this"}, {"type": "localImage", "path": image_path}];
    log = t_native_log(scratch, "t-native-input-image");
    assert '"type":"localImage"' in log;
    assert "[private attachment path omitted]" in log;
    assert image_path not in log;
}

test "normalizes native image generation bytes without exposing the provider path" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="image");
    _op_send_turn(inst, {"threadId": "t-image", "text": "make an image", "model": "gpt-5.6-sol"});
    t_type("turn.completed");
    image = [ev for ev in t_events() if ev["type"] == "item.completed" and ev.get("itemType") == "assistant_image"][0];
    assert t_subset(image, {"itemType": "assistant_image", "itemId": "img1", "alt": "a tiny green mouse"});
    assert image["data"].startswith("iVBOR");
    assert "provider-owned-path" not in json.dumps(image);
}

test "keeps the full command when a Windows interpreter prefix is long" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="windows-command");
    _op_send_turn(inst, {"threadId": "t-windows-command", "text": "read notes"});
    command = " ".join(["\"C:\\WINDOWS\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\"", "-Command",
        "\"Get-Content -Raw -LiteralPath 'C:\\Users\\Ada\\workspaces\\" + "very-long-folder\\" * 8 + "NOTES.md'\""]);
    assert len(command) > 200;
    opened = t_type("request.opened");
    assert t_of("item.started")[0]["title"] == command;
    assert t_subset(opened, {"requestType": "permission", "summary": command});
    _op_respond(inst, "t-windows-command", opened["requestId"], {"behavior": "allow"});
    t_type("turn.completed");
}

test "uses the instance environment for the Codex process" {
    scratch = t_setup();
    codex_home = os.path.join(scratch, "custom-codex-home");
    inst = t_inst(scratch, environment={"CODEX_HOME": codex_home});
    dump = t_dump_at(scratch, "environment.json");
    _op_send_turn(inst, {"threadId": "t-environment", "text": "hi"});
    t_type("turn.completed");
    assert t_dump(dump)["env"]["CODEX_HOME"] == codex_home;
}

test "mounts connected apps without placing credential values in argv" {
    scratch = t_setup();
    inst = t_inst(scratch);
    dump = t_dump_at(scratch, "composio.json");
    _op_send_turn(inst, {"threadId": "t-composio", "text": "check mail", "integrations": {
        "composio": {"command": "/usr/bin/node", "args": ["/tmp/connector-proxy.js"], "env": {"OMB_CONNECTOR_UPSTREAM_URL": "http://127.0.0.1:8799/api/internal/connectors/mcp", "OMB_CONNECTOR_TOKEN": "per-turn-connector-token"}},
        "agents": {"command": "/usr/bin/node", "args": ["/tmp/agents-proxy.js"], "env": {"OMB_COMMS_TOKEN": "peer-comms-secret"}},
    }});
    t_type("turn.completed");
    seen = t_dump(dump);
    argv = " ".join(seen["argv"]);
    assert "mcp_servers.openmausbot_connectors.command" in argv;
    assert "OMB_CONNECTOR_TOKEN" in argv and "per-turn-connector-token" not in argv;
    assert seen["env"]["OMB_CONNECTOR_TOKEN"] == "per-turn-connector-token";
    assert seen["env"]["OMB_COMMS_TOKEN"] == "peer-comms-secret";
}

test "mounts custom MCP servers on-request while built-ins stay pre-quieted" {
    scratch = t_setup();
    inst = t_inst(scratch);
    dump = t_dump_at(scratch, "custom-mcp.json");
    _op_send_turn(inst, {"threadId": "t-custom-mcp", "text": "go", "integrations": {
        "custom": {"notes": {"command": "npx", "args": ["-y", "@x/notes-mcp"], "env": {"NOTES_TOKEN": "tok-notes"}}},
        "composio": {"command": "/usr/bin/node", "args": ["/tmp/connector-proxy.js"], "env": {"OMB_COMMS_TOKEN": "per-boot-token"}},
    }});
    t_type("turn.completed");
    seen = t_dump(dump);
    argv = " ".join(seen["argv"]);
    assert "mcp_servers.notes.command" in argv and "NOTES_TOKEN" in argv and "tok-notes" not in argv;
    assert seen["env"]["NOTES_TOKEN"] == "tok-notes";
    assert "mcp_servers.openmausbot_connectors.default_tools_approval_mode" in argv;
    assert "mcp_servers.notes.default_tools_approval_mode" not in argv;
    assert 'mcp_servers.notes.args=["-y","@x/notes-mcp"]' in seen["argv"];
}

test "mounts a custom server under its own name when the user's config.toml already has one by that name" {
    scratch = t_setup();
    codex_home = os.path.join(scratch, "collision-codex-home");
    t_write(os.path.join(codex_home, "config.toml"), '[mcp_servers.fibery]\nurl = "https://mcp-eu-svc.fibery.io/mcp"\n');
    inst = t_inst(scratch, environment={"CODEX_HOME": codex_home});
    dump = t_dump_at(scratch, "collision.json");
    _op_send_turn(inst, {"threadId": "t-collision", "text": "go", "integrations": {"custom": {
        "fibery": {"command": "uv", "args": ["tool", "run", "fibery-mcp-server"], "env": {}},
        "notes": {"command": "npx", "args": ["-y", "@x/notes-mcp"], "env": {}},
    }}});
    t_type("turn.completed");
    argv = " ".join(t_dump(dump)["argv"]);
    assert "mcp_servers.fibery_openmausbot.command" in argv;
    assert "mcp_servers.fibery.command" not in argv;
    assert "mcp_servers.notes.command" in argv;
}

test "mounts a url server for codex to connect to, header values off argv" {
    scratch = t_setup();
    inst = t_inst(scratch);
    dump = t_dump_at(scratch, "remote-mcp.json");
    _op_send_turn(inst, {"threadId": "t-remote-mcp", "text": "go", "integrations": {"custom": {
        "docs": {"type": "http", "url": "https://docs.example/mcp", "headers": {"Authorization": "Bearer tok-docs", "X-Org": "acme"}},
        "legacy": {"type": "sse", "url": "https://old.example/sse", "headers": {}},
    }}});
    t_type("turn.completed");
    seen = t_dump(dump);
    argv = " ".join(seen["argv"]);
    assert 'mcp_servers.docs.url="https://docs.example/mcp"' in seen["argv"];
    assert 'mcp_servers.docs.bearer_token_env_var="OMB_MCP_HEADER_DOCS_BEARER"' in seen["argv"];
    assert 'mcp_servers.docs.env_http_headers={ "X-Org" = "OMB_MCP_HEADER_DOCS_1" }' in seen["argv"];
    assert "tok-docs" not in argv;
    assert seen["env"]["OMB_MCP_HEADER_DOCS_BEARER"] == "tok-docs";
    assert seen["env"]["OMB_MCP_HEADER_DOCS_1"] == "acme";
    assert "mcp_servers.docs.default_tools_approval_mode" not in argv;
    assert "mcp_servers.legacy" not in argv;
}

test "does not let a custom MCP server capture a built-in capability variable" {
    scratch = t_setup();
    inst = t_inst(scratch);
    def go {
        _op_send_turn(inst, {"threadId": "t-custom-mcp-collision", "text": "go", "integrations": {
            "agents": {"command": "/usr/bin/node", "args": ["/tmp/agents-proxy.js"], "env": {"OMB_COMMS_TOKEN": "fresh-turn-bearer"}},
            "custom": {"hostile": {"command": "hostile-mcp", "args": [], "env": {"OMB_HARNESS_URL": "https://attacker.invalid"}}},
        }});
    }
    t_raises(go, "reserved environment variable.*OMB_HARNESS_URL");
}

test "pre-allows peer-agent comms and the built-in browser without exposing tokens" {
    for approval_mode in ["ask", "auto"] {
        scratch = t_setup();
        inst = t_inst(scratch);
        dump = t_dump_at(scratch, "agents.json");
        _op_send_turn(inst, {"threadId": "t-agents", "text": "ask the researcher", "approvalMode": approval_mode, "integrations": {
            "agents": {"command": "/usr/bin/node", "args": ["/tmp/agents-proxy.js"], "env": {"ELECTRON_RUN_AS_NODE": "1", "OMB_COMMS_TOKEN": "peer-comms-secret"}},
            "browser": {"command": "/usr/bin/node", "args": ["/tmp/harness-mcp-proxy.js"], "env": {"OMB_MCP_TOKEN": "browser-capability-secret"}},
        }});
        t_type("turn.completed");
        seen = t_dump(dump);
        argv = " ".join(seen["argv"]);
        assert 'mcp_servers.agents.default_tools_approval_mode="auto"' in seen["argv"];
        assert 'mcp_servers.browser.default_tools_approval_mode="auto"' in seen["argv"];
        for flag in ["features.browser_use=false", "features.browser_use_external=false", "features.computer_use=false"] { assert flag in seen["argv"]; }
        assert not any([arg.startswith("web_search=") for arg in seen["argv"]]);
        assert "peer-comms-secret" not in argv and "browser-capability-secret" not in argv;
        assert seen["env"]["OMB_COMMS_TOKEN"] == "peer-comms-secret";
        reviewer = "auto_review" if approval_mode == "auto" else "user";
        for method in ["thread/start", "turn/start"] {
            assert t_subset(t_calls(dump, method)[0]["params"], {"approvalPolicy": "on-request", "approvalsReviewer": reviewer});
        }
    }
}

test "sends the local provider when the picker id is custom-encoded" {
    scratch = t_setup();
    inst = t_inst(scratch, environment={"UNSLOTH_STUDIO_AUTH_TOKEN": "unsloth-secret"});
    dump = t_dump_at(scratch, "dump.json");
    _op_send_turn(inst, {"threadId": "t-local", "text": "hi", "model": "unsloth::Qwen3.6-35B-A3B-bf16:qwen3-5-6-n-r-reasoning"});
    t_type("turn.completed");
    assert t_subset(t_calls(dump, "thread/start")[0]["params"], {"model": "Qwen3.6-35B-A3B-bf16:qwen3-5-6-n-r-reasoning", "modelProvider": "unsloth"});
    seen = t_dump(dump);
    assert 'model_providers.unsloth.base_url="http://127.0.0.1:8888/v1"' in seen["argv"];
    assert "unsloth-secret" not in json.dumps(seen["argv"]);
    assert seen["env"]["OPENMAUSBOT_LOCAL_UNSLOTH_API_KEY"] == "unsloth-secret";
}

test "streams agentMessage deltas without re-emitting the settled text" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="stream");
    _op_send_turn(inst, {"threadId": "t-stream", "text": "hi"});
    t_type("turn.completed");
    deltas = [ev["delta"] for ev in t_events() if ev["type"] == "content.delta" and ev["streamKind"] == "assistant_text"];
    assert deltas == ["done from ", "fake codex"];
    settled = [ev for ev in t_events() if ev["type"] == "item.completed" and ev.get("itemType") == "assistant_text"];
    assert len(settled) == 1 and settled[0]["text"] == "done from fake codex";
}

test "tries thread/resume with a cursor and reuses the thread id" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="resume");
    dump = t_dump_at(scratch, "dump.json");
    _op_send_turn(inst, {"threadId": "t-resume", "text": "again", "resumeCursor": "codex-thread-9", "approvalMode": "full"});
    assert t_type("session.started")["sessionId"] == "codex-thread-9";
    t_type("turn.completed");
    methods = t_methods(dump);
    assert "thread/resume" in methods and "thread/start" not in methods;
    assert t_subset(t_calls(dump, "thread/resume")[0]["params"], {"approvalPolicy": "never", "approvalsReviewer": "user", "sandbox": "danger-full-access"});
    assert t_subset(t_calls(dump, "turn/start")[0]["params"], {"approvalPolicy": "never", "approvalsReviewer": "user", "sandboxPolicy": {"type": "dangerFullAccess"}});
}

test "reasserts the selected model and provider after app-server restarts" {
    cases: list[any] = [
        ["native", {}, [["fixture::local-model", "local-model", "fixture"], ["gpt-6.1-sol", "gpt-6.1-sol", "openai"], ["fixture::other-model", "other-model", "fixture"]]],
        ["plan", {"auth_mode": "chatgpt-plan"}, [["gpt-5.6-sol", "gpt-5.6-sol", "openai_chatgpt_plan"], ["gpt-6.1-sol", "gpt-6.1-sol", "openai_chatgpt_plan"]]],
        ["company", {"managed": True}, [["company-codex-model", "company-codex-model", "openmaus_company"], ["company-codex-model", "company-codex-model", "openmaus_company"]]],
    ];
    for row_case in cases {
        scratch = t_setup();
        t_env("OPENMAUSBOT_CHATGPT_TOKEN", "inherited-token-must-not-leak");
        t_env("OPENAI_API_KEY", "inherited-api-key-must-not-leak");
        opts = row_case[1];
        plan = opts.get("auth_mode") is not None;
        inst = t_inst(scratch, mode="resume", managed=bool(opts.get("managed")), auth_mode=opts.get("auth_mode"));
        dump = t_dump_at(scratch, "model-provider-resume.json");
        pids: dict[int, bool] = {};
        index = 0;
        for row in row_case[2] {
            turn: dict[str, any] = {"threadId": "t-model-provider-resume", "text": "Continue", "model": row[0]};
            if index { turn["resumeCursor"] = "codex-thread-1"; }
            if plan { turn["_jac"] = {"planToken": "synthetic-chatgpt-token"}; }
            turn_id = _op_send_turn(inst, turn);
            t_type("turn.completed", turn_id=turn_id);
            assert t_events()[-1]["ok"] is True, row_case[0];
            assert [ev for ev in t_events() if ev["type"] == "session.started" and ev["turnId"] == turn_id][0]["sessionId"] == "codex-thread-1";
            seen = t_dump(dump);
            pids[seen["pid"]] = True;
            assert "OPENAI_API_KEY" not in seen["env"];
            assert seen["env"].get("OPENMAUSBOT_CHATGPT_TOKEN") == ("synthetic-chatgpt-token" if plan else None);
            assert "synthetic-chatgpt-token" not in json.dumps({"argv": seen["argv"], "calls": seen["calls"]});
            if plan {
                assert seen["env"]["CODEX_HOME"].startswith(os.path.join(scratch, "data", "providers", "chatgpt-plan") + os.sep);
                assert 'shell_environment_policy.exclude=["OPENMAUSBOT_CHATGPT_TOKEN"]' in seen["argv"];
            } else {
                assert seen["env"]["CODEX_HOME"] == os.path.join(scratch, ".codex");
            }
            thread_calls = [c for c in seen["calls"] if c["method"] in ["thread/start", "thread/resume"]];
            assert len(thread_calls) == 1;
            expected: dict[str, any] = {"model": row[1], "modelProvider": row[2]};
            if index { expected["threadId"] = "codex-thread-1"; }
            assert thread_calls[0]["method"] == ("thread/resume" if index else "thread/start");
            assert t_subset(thread_calls[0]["params"], expected), json.dumps(thread_calls[0]);
            index += 1;
        }
        assert len(pids) == len(row_case[2]);
    }
}

test "fails a rejected resume without silently replacing native history" {
    scratch = t_setup();
    inst = t_inst(scratch);
    dump = t_dump_at(scratch, "personal-missing-thread.json");
    _op_send_turn(inst, {"threadId": "t-fallback", "text": "go", "resumeCursor": "gone-thread", "recoveryText": "Previous messages\nUser: go"});
    assert t_type("turn.completed")["ok"] is False;
    assert len(t_of("session.started")) == 0;
    assert "thread/start" not in t_methods(dump);
}

test "names the missing Company prerequisites instead of one blanket refusal" {
    scratch = t_setup();
    inst = t_inst(scratch, managed=True);
    def no_model { _op_send_turn(inst, {"threadId": "company-no-model", "text": "hi"}); }
    t_raises(no_model, "no model is selected");
    def off_list { _op_send_turn(inst, {"threadId": "company-off-list-model", "text": "hi", "model": "personal-model"}); }
    t_raises(off_list, "personal-model is not approved for your organization");
    inst2 = t_inst(scratch, managed=True, environment={"OPENMAUSBOT_COMPANY_API_KEY": ""});
    def no_key { _op_send_turn(inst2, {"threadId": "company-no-key", "text": "hi", "model": "company-codex-model"}); }
    t_raises(no_key, "OPENMAUSBOT_COMPANY_API_KEY is missing");
    inst3 = t_inst(scratch, managed=True, environment={"CODEX_HOME": ""});
    def no_home { _op_send_turn(inst3, {"threadId": "company-no-home", "text": "hi", "model": "company-codex-model"}); }
    t_raises(no_home, "CODEX_HOME is missing");
}

test "rebuilds a missing Company native thread once with its approved model and canonical history" {
    scratch = t_setup();
    inst = t_inst(scratch, managed=True);
    dump = t_dump_at(scratch, "company-missing-thread.json");
    recovery_text = "User: Remember ALPHA.\nAssistant: Remembered.\nUser: What did I say?";
    image_path = os.path.join(scratch, "current-image.png");
    _op_send_turn(inst, {"threadId": "company-missing-thread", "text": "What did I say?", "resumeCursor": "gone-company-thread",
        "recoveryText": recovery_text, "model": "company-codex-model", "system": "Keep current bot rules.", "approvalMode": "full",
        "cwd": scratch, "images": [{"path": image_path, "mime": "image/png", "bytes": 1}]});
    assert t_type("turn.completed")["ok"] is True;
    assert t_methods(dump) == ["initialize", "initialized", "config/read", "thread/resume", "thread/start", "turn/start"];
    start = t_calls(dump, "thread/start")[0]["params"];
    assert t_subset(start, {"model": "company-codex-model", "modelProvider": "openmaus_company", "cwd": scratch,
        "approvalPolicy": "never", "sandbox": "danger-full-access", "ephemeral": False});
    assert "Keep current bot rules." in start["developerInstructions"];
    assert t_subset(t_calls(dump, "turn/start")[0]["params"], {"threadId": "codex-thread-1", "input": [{"type": "text", "text": recovery_text}, {"type": "localImage", "path": image_path}]});
    seen = t_dump(dump);
    assert 'model_provider="openmaus_company"' in seen["argv"];
    assert "synthetic-company-fixture" not in json.dumps(seen["argv"]);
    sessions = t_of("session.started");
    assert len(sessions) == 1 and t_subset(sessions[0], {"sessionId": "codex-thread-1", "rebuilt": True});
}

test "rebuilds a missing personal thread only for a turn whose recovery text is the replay" {
    scratch = t_setup();
    inst = t_inst(scratch);
    dump = t_dump_at(scratch, "personal-missing-replay.json");
    recovery_text = "[This conversation received an update outside your provider session.]\nUser: go";
    _op_send_turn(inst, {"threadId": "t-personal-replay", "text": "go", "resumeCursor": "gone-thread", "recoveryText": recovery_text, "recoveryIsReplay": True});
    assert t_type("turn.completed")["ok"] is True;
    assert "thread/start" in t_methods(dump);
    assert t_calls(dump, "turn/start")[0]["params"]["input"] == [{"type": "text", "text": recovery_text}];
    sessions = t_of("session.started");
    assert len(sessions) == 1 and sessions[0].get("rebuilt") is True;
}

test "does not announce a rebuilt Company thread when the recovery text is the turn itself" {
    scratch = t_setup();
    inst = t_inst(scratch, managed=True);
    dump = t_dump_at(scratch, "company-no-replay.json");
    _op_send_turn(inst, {"threadId": "company-no-replay", "text": "Continue", "resumeCursor": "gone-company-thread", "recoveryText": "Continue", "model": "company-codex-model"});
    assert t_type("turn.completed")["ok"] is True;
    assert "thread/start" in t_methods(dump);
    assert "rebuilt" not in t_of("session.started")[-1];
}

test "keeps successful Company resumes native without replaying the canonical transcript" {
    scratch = t_setup();
    inst = t_inst(scratch, managed=True, mode="resume");
    dump = t_dump_at(scratch, "company-resume.json");
    _op_send_turn(inst, {"threadId": "company-resume", "text": "Continue", "resumeCursor": "company-existing-thread", "recoveryText": "Old history must not be replayed", "model": "company-codex-model"});
    assert t_type("turn.completed")["ok"] is True;
    assert "thread/start" not in t_methods(dump);
    assert t_calls(dump, "turn/start")[0]["params"]["input"] == [{"type": "text", "text": "Continue"}];
}

test "does not replace missing Company native history without canonical recovery text" {
    for recovery_text in [None, "", "  \n"] {
        scratch = t_setup();
        inst = t_inst(scratch, managed=True);
        dump = t_dump_at(scratch, "company-no-recovery.json");
        turn: dict[str, any] = {"threadId": "company-no-recovery", "text": "Continue", "resumeCursor": "gone-thread", "model": "company-codex-model"};
        if recovery_text is not None { turn["recoveryText"] = recovery_text; }
        _op_send_turn(inst, turn);
        assert t_type("turn.completed")["ok"] is False;
        methods = t_methods(dump);
        assert "thread/start" not in methods and "turn/start" not in methods;
    }
}

test "does not rebuild Company history on an unrelated resume rejection" {
    for err in [
        {"code": -32603, "message": "401 Unauthorized: missing bearer"},
        {"code": -32603, "message": "503: This task was blocked by our safety systems."},
        {"code": -32603, "message": "network error: connection reset"},
        {"code": -32600, "message": "404 endpoint not found"},
        {"code": -32600, "message": "no rollout found for thread id another-thread"},
        {"code": -32603, "message": "no rollout found for thread id gone-thread"},
        {"code": -32600, "message": "thread not found in an unrelated provider response"},
    ] {
        scratch = t_setup();
        inst = t_inst(scratch, managed=True);
        dump = t_dump_at(scratch, "company-rejected-resume.json");
        t_env("FAKE_CODEX_RESUME_ERROR", json.dumps(err));
        t_env("FAKE_CODEX_RETRY_SCALE", "0.001");
        _op_send_turn(inst, {"threadId": "company-rejected-resume", "text": "Continue", "resumeCursor": "gone-thread", "recoveryText": "History\nUser: Continue", "model": "company-codex-model"});
        assert t_type("turn.completed")["ok"] is False;
        methods = t_methods(dump);
        assert "thread/start" not in methods and "turn/start" not in methods, err["message"];
        assert len(t_of("session.started")) == 0;
    }
}

test "does not repeatedly rebuild Company history when the replacement start fails" {
    scratch = t_setup();
    inst = t_inst(scratch, managed=True);
    dump = t_dump_at(scratch, "company-failed-recovery.json");
    t_env("FAKE_CODEX_START_ERROR", json.dumps({"code": -32603, "message": "503: unavailable"}));
    t_env("FAKE_CODEX_RETRY_SCALE", "0.001");
    _op_send_turn(inst, {"threadId": "company-failed-recovery", "text": "Continue", "resumeCursor": "gone-thread", "recoveryText": "History\nUser: Continue", "model": "company-codex-model"});
    assert t_type("turn.completed")["ok"] is False;
    assert len(t_calls(dump, "thread/start")) == 1;
    assert "turn/start" not in t_methods(dump);
    assert len(t_of("turn.retrying")) == 0;
}

test "never rebuilds Company history again after user submission" {
    for mode in ["happy", "resume-then-missing"] {
        scratch = t_setup();
        inst = t_inst(scratch, managed=True, mode=mode);
        dump = t_dump_at(scratch, "company-submitted-turn.json");
        attempts = os.path.join(scratch, "company-submitted-attempts");
        t_env("FAKE_CODEX_TRANSIENTS", "1");
        t_env("FAKE_CODEX_STATE", attempts);
        t_env("FAKE_CODEX_RETRY_SCALE", "0.001");
        _op_send_turn(inst, {"threadId": "company-submitted-turn", "text": "Continue", "resumeCursor": "gone-thread", "recoveryText": "History\nUser: Continue", "model": "company-codex-model"});
        assert t_type("turn.completed")["ok"] is False, mode;
        f = open(attempts, "r");
        assert f.read() == "1";
        f.close();
        assert len(t_calls(dump, "thread/start")) == (1 if mode == "happy" else 0);
        assert len(t_of("turn.retrying")) == (0 if mode == "happy" else 1);
    }
}

test "fails before user submission if native instruction updates are unsupported" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="instructions-unsupported");
    dump = t_dump_at(scratch, "unsupported.json");
    _op_send_turn(inst, {"threadId": "t-old-codex", "text": "go", "system": "rules", "resumeCursor": "old-session"});
    assert t_type("turn.completed")["ok"] is False;
    assert len(t_errors("Update Codex")) == 1;
    methods = t_methods(dump);
    assert "turn/start" not in methods and "thread/start" not in methods;
}

test "reasserts current instructions across processes and recovery" {
    for row in [["resume", "codex-thread-1"], ["config-profile-unsupported", "codex-thread-1"]] {
        scratch = t_setup();
        dump = t_dump_at(scratch, "instructions.json");
        instructions = "You are Testy. Follow the bot rules. " * 100;
        systems = [instructions, instructions, "You are Renamed. Use the new rules.", "", None];
        inst = t_inst(scratch, mode=row[0]);
        index = 0;
        for system in systems {
            # A fresh instance each turn rules out an in-memory cache.
            if index > 0 { inst = t_inst(scratch, mode=row[0]); }
            turn: dict[str, any] = {"threadId": "t-instructions", "text": "message-" + str(index), "approvalMode": "custom"};
            if system is not None { turn["system"] = system; }
            if index > 0 { turn["resumeCursor"] = row[1]; }
            turn_id = _op_send_turn(inst, turn);
            t_type("turn.completed", turn_id=turn_id);
            calls = t_dump(dump)["calls"];
            thread_calls = [c for c in calls if c["method"] in ["thread/start", "thread/resume"]];
            assert len(thread_calls) > 0;
            for call in thread_calls { assert call["params"]["developerInstructions"] == (system or ""); }
            if index > 0 { assert thread_calls[0]["method"] == "thread/resume"; }
            updates = [c for c in calls if c["method"] == "thread/inject_items"];
            assert len(updates) == (1 if index == 2 or index == 3 else 0), row[0] + " " + str(index);
            if updates { assert (system or "No OpenMausBot bot-specific instructions remain.") in json.dumps(updates[0]["params"]); }
            for call in [c for c in calls if c["method"] == "turn/start"] {
                assert call["params"]["input"] == [{"type": "text", "text": "message-" + str(index)}];
            }
            index += 1;
        }
    }
}

test "preserves configured native rules and keeps them private" {
    for approval_mode in ["ask", "auto", "full", "custom"] {
        scratch = t_setup();
        inst = t_inst(scratch, mode="resume");
        t_env("FAKE_CODEX_INSTRUCTIONS", "Private native rules.");
        dump = t_dump_at(scratch, "native-instructions.json");
        thread_id = "t-native-instructions-" + approval_mode;
        index = 0;
        for system in ["Bot rules.", "", None] {
            turn: dict[str, any] = {"threadId": thread_id, "text": "message-" + str(index), "approvalMode": approval_mode};
            if system is not None { turn["system"] = system; }
            if index > 0 { turn["resumeCursor"] = "codex-thread-1"; }
            turn_id = _op_send_turn(inst, turn);
            assert t_type("turn.completed", turn_id=turn_id)["ok"] is True;
            calls = t_dump(dump)["calls"];
            thread_call = [c for c in calls if c["method"] == ("thread/resume" if index else "thread/start")][0];
            assert thread_call["params"]["developerInstructions"] == (system or "No OpenMausBot bot-specific instructions remain.") + "\n\nPrivate native rules.";
            assert len([c for c in calls if c["method"] == "thread/inject_items"]) == (1 if index == 1 else 0);
            assert [c for c in calls if c["method"] == "turn/start"][0]["params"]["input"] == [{"type": "text", "text": "message-" + str(index)}];
            index += 1;
        }
        log = t_native_log(scratch, thread_id);
        assert "[effective config omitted]" in log and "[developer instructions omitted]" in log and "[developer instruction update omitted]" in log;
        assert "Private native rules." not in log and "Bot rules." not in log and "innocuous-config-secret-7a9c" not in log;
    }
}

test "surfaces an approval request and forwards the user's decision" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="approval");
    dump = t_dump_at(scratch, "dump.json");
    _op_send_turn(inst, {"threadId": "t-approve", "text": "clean up", "cwd": scratch});
    opened = t_type("request.opened");
    assert t_subset(opened, {"requestType": "permission", "tool": "shell", "summary": "rm -rf scratch"});
    assert opened["command"] == {"command": "rm -rf scratch", "cwd": os.path.realpath(scratch)};
    assert _op_respond(inst, "t-approve", opened["requestId"], {"behavior": "allow"}) == "allowed-once";
    assert t_subset(t_type("request.resolved"), {"behavior": "allow", "source": "user"});
    t_type("turn.completed");
    assert t_dump(dump)["decision"] == {"decision": "approved"};
    # settled: a late answer has no answerer
    assert _op_respond(inst, "t-approve", opened["requestId"], {"behavior": "allow"}) == "unavailable";
}

test "emits a command descriptor only for trustworthy shell input" {
    long_cmd = "printf '  " + "complete input " * 30 + "'\n  pwd  ";
    cases: list[any] = [
        ["item/commandExecution/requestApproval", {"command": long_cmd}, True],
        ["item/commandExecution/requestApproval", {"command": "pwd", "additionalPermissions": {"network": {"enabled": True}}}, True],
        ["item/commandExecution/requestApproval", {"command": "pwd", "networkApprovalContext": {"host": "example.test", "protocol": "https"}}, True],
        ["execCommandApproval", {"command": ["echo", "do not join argv"]}, False],
        ["item/commandExecution/requestApproval", {"reason": "echo display only"}, False],
        ["item/commandExecution/requestApproval", {"command": "pwd", "cwd": "unknown-relative-directory"}, False],
        ["item/fileChange/requestApproval", {"command": "echo not a shell approval"}, False],
        ["item/permissions/requestApproval", {"command": "echo not a shell approval", "permissions": {"network": {"enabled": True}}}, False],
    ];
    for row_case in cases {
        scratch = t_setup();
        inst = t_inst(scratch, mode="approval");
        effective_cwd = os.path.join(scratch, "effective-command-directory");
        native_params: dict[str, any] = {"cwd": effective_cwd};
        native_params.update(row_case[1]);
        t_env("FAKE_CODEX_APPROVAL_REQUEST", json.dumps({"method": row_case[0], "params": native_params}));
        _op_send_turn(inst, {"threadId": "t-native-command-descriptor", "text": "go", "cwd": scratch});
        opened = t_type("request.opened");
        if row_case[2] {
            assert opened.get("command") == {"command": row_case[1]["command"], "cwd": effective_cwd}, json.dumps(row_case);
        } else {
            assert "command" not in opened, json.dumps(row_case);
        }
        if row_case[0] == "item/permissions/requestApproval" or "additionalPermissions" in row_case[1] or "networkApprovalContext" in row_case[1] {
            assert opened.get("requiresExplicitApproval") is True;
        }
        _op_respond(inst, "t-native-command-descriptor", opened["requestId"], {"behavior": "deny"});
        t_type("turn.completed");
    }
}

test "does not infer a helper's working directory from the parent turn" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="approval");
    t_env("FAKE_CODEX_APPROVAL_REQUEST", json.dumps({"method": "item/commandExecution/requestApproval", "params": {"threadId": "helper-thread", "command": "pwd"}}));
    _op_send_turn(inst, {"threadId": "t-helper-command-descriptor", "text": "go", "cwd": scratch});
    opened = t_type("request.opened");
    assert "command" not in opened;
    _op_respond(inst, "t-helper-command-descriptor", opened["requestId"], {"behavior": "deny"});
    t_type("turn.completed");
}

test "answers a single-question ask and keeps its reply scoped to that question" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="question");
    dump = t_dump_at(scratch, "question-single.json");
    _op_send_turn(inst, {"threadId": "t-question-single", "text": "ask me"});
    opened = t_type("request.opened");
    labels = ["Yes", "No", "Maybe", "Later", "Soon", "Never"];
    assert t_subset(opened, {"requestType": "question", "tool": "ask_user", "summary": "Ship today?", "choices": labels,
        "questions": [{"question": "Ship today?", "options": [{"label": label} for label in labels]}]});
    assert "command" not in opened;
    assert _op_respond(inst, "t-question-single", opened["requestId"], {"behavior": "answer", "message": "Yes"}) == "answered";
    assert t_subset(t_type("request.resolved"), {"behavior": "answer", "source": "user"});
    t_type("turn.completed");
    assert t_dump(dump)["decision"] == {"answers": {"q-ship": {"answers": ["Yes"]}}};
}

test "opens one card for a bundled ask and maps a block reply per question id" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="multi-question");
    dump = t_dump_at(scratch, "question-multi.json");
    _op_send_turn(inst, {"threadId": "t-question-multi", "text": "ask me twice"});
    opened = t_type("request.opened");
    assert t_subset(opened, {"requestType": "question", "tool": "ask_user", "summary": "Ship today? · Who reviews?",
        "questions": [{"question": "Ship today?", "options": [{"label": "Yes"}, {"label": "No"}]}, {"question": "Who reviews?", "options": [{"label": "Ada"}, {"label": "Lin"}]}]});
    assert "choices" not in opened;
    assert len(t_of("request.opened")) == 1;
    _op_respond(inst, "t-question-multi", opened["requestId"], {"behavior": "answer", "message": "The user answered your questions.\n\nQ: Ship today?\nA: Yes\n\nQ: Who reviews?\nA: Ada"});
    t_type("turn.completed");
    assert t_dump(dump)["decision"] == {"answers": {"q-ship": {"answers": ["Yes"]}, "q-review": {"answers": ["Ada"]}}};
}

test "answers only the question ids a partial block reply covers" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="multi-question");
    dump = t_dump_at(scratch, "question-partial.json");
    _op_send_turn(inst, {"threadId": "t-question-partial", "text": "ask me twice"});
    opened = t_type("request.opened");
    _op_respond(inst, "t-question-partial", opened["requestId"], {"behavior": "answer", "message": "The user answered your questions.\n\nQ: Ship today?\nA: Yes"});
    t_type("turn.completed");
    assert t_dump(dump)["decision"] == {"answers": {"q-ship": {"answers": ["Yes"]}}};
}

test "builds the card from the questions that parsed, not the raw entries" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="mixed-question");
    dump = t_dump_at(scratch, "question-mixed.json");
    _op_send_turn(inst, {"threadId": "t-question-mixed", "text": "ask me"});
    opened = t_type("request.opened");
    assert t_subset(opened, {"requestType": "question", "summary": "Who reviews?", "choices": ["Ada", "Lin"],
        "questions": [{"question": "Who reviews?", "options": [{"label": "Ada"}, {"label": "Lin"}]}]});
    _op_respond(inst, "t-question-mixed", opened["requestId"], {"behavior": "answer", "message": "Q: Who reviews?\nA: First paragraph\n\nsecond paragraph"});
    t_type("turn.completed");
    assert t_dump(dump)["decision"] == {"answers": {"q-review": {"answers": ["First paragraph\n\nsecond paragraph"]}}};
}

test "refuses an empty or malformed ask instead of opening a card" {
    for row in [["empty-question", "sent none"], ["malformed-question", "array of questions"]] {
        scratch = t_setup();
        inst = t_inst(scratch, mode=row[0]);
        dump = t_dump_at(scratch, "question-refused.json");
        _op_send_turn(inst, {"threadId": "t-" + row[0], "text": "ask me"});
        t_type("turn.completed");
        assert len(t_of("request.opened")) == 0;
        decision = t_dump(dump)["decision"];
        assert decision["error"]["code"] == -32602 and row[1] in decision["error"]["message"];
    }
}

test "times out an ask with empty answers and a timeout-sourced resolve" {
    scratch = t_setup();
    t_env("FAKE_CODEX_ASK_HOLD", "1");
    t_patch("ASK_TIMEOUT_S", 0.2);
    inst = t_inst(scratch, mode="multi-question");
    dump = t_dump_at(scratch, "question-timeout.json");
    _op_send_turn(inst, {"threadId": "t-question-timeout", "text": "ask me"});
    opened = t_type("request.opened");
    def resolved_pred(ev: dict[str, any]) -> bool { return ev["type"] == "request.resolved" and ev["requestId"] == opened["requestId"]; }
    assert t_subset(t_until(resolved_pred), {"behavior": "deny", "source": "timeout"});
    def has_decision -> bool { return t_dump(dump).get("decision") is not None; }
    assert t_wait_for(has_decision, 5.0);
    assert t_dump(dump)["decision"] == {"answers": {}};
}

test "answers MCP elicitations, app-access forms and additional permissions in their native shapes" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="mcp-elicitation");
    dump = t_dump_at(scratch, "mcp-elicitation.json");
    _op_send_turn(inst, {"threadId": "t-mcp-elicitation", "text": "list bots"});
    opened = t_type("request.opened");
    assert t_subset(opened, {"requestType": "permission", "tool": "list_bots", "summary": 'Allow the agents MCP server to run tool "list_bots"?'});
    _op_respond(inst, "t-mcp-elicitation", opened["requestId"], {"behavior": "allow"});
    t_type("turn.completed");
    assert t_dump(dump)["decision"] == {"action": "accept", "content": {}};

    scratch2 = t_setup();
    inst2 = t_inst(scratch2, mode="mcp-app-approval");
    dump2 = t_dump_at(scratch2, "mcp-app-approval.json");
    _op_send_turn(inst2, {"threadId": "t-mcp-app-approval", "text": "use Safari"});
    opened2 = t_type("request.opened");
    assert t_subset(opened2, {"requestType": "permission", "tool": "Safari", "summary": "Allow ChatGPT to use Safari?"});
    _op_respond(inst2, "t-mcp-app-approval", opened2["requestId"], {"behavior": "allow"});
    t_type("turn.completed");
    assert t_dump(dump2)["decision"] == {"action": "accept", "content": {"approval": "once"}};

    scratch3 = t_setup();
    inst3 = t_inst(scratch3, mode="mcp-app-approval");
    dump3 = t_dump_at(scratch3, "mcp-app-full.json");
    _op_send_turn(inst3, {"threadId": "t-mcp-app-full", "text": "use Safari", "approvalMode": "full"});
    t_type("turn.completed");
    assert len(t_of("request.opened")) == 0;
    assert t_dump(dump3)["decision"] == {"action": "accept", "content": {"approval": "once"}};

    scratch4 = t_setup();
    inst4 = t_inst(scratch4, mode="mcp-form");
    dump4 = t_dump_at(scratch4, "mcp-form.json");
    _op_send_turn(inst4, {"threadId": "t-mcp-form", "text": "configure the service", "approvalMode": "full"});
    t_type("turn.completed");
    assert len(t_of("request.opened")) == 0;
    assert t_dump(dump4)["decision"] == {"action": "decline"};

    scratch5 = t_setup();
    inst5 = t_inst(scratch5, mode="permissions-approval");
    dump5 = t_dump_at(scratch5, "permissions-approval.json");
    _op_send_turn(inst5, {"threadId": "t-permissions", "text": "use the network", "approvalMode": "full"});
    t_type("turn.completed");
    assert len(t_of("request.opened")) == 0;
    assert t_dump(dump5)["decision"] == {"permissions": {"network": {"enabled": True}}, "scope": "turn"};
}

test "does not turn Custom never + read-only into blanket permission grants" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="permissions-approval");
    dump = t_dump_at(scratch, "custom-permissions-approval.json");
    _op_send_turn(inst, {"threadId": "t-custom-permissions", "text": "use the network", "approvalMode": "custom"});
    opened = t_type("request.opened");
    assert t_subset(opened, {"requestType": "permission", "summary": 'Needs network access — Requested permissions: {"network":{"enabled":true}}', "requiresExplicitApproval": True});
    _op_respond(inst, "t-custom-permissions", opened["requestId"], {"behavior": "deny"});
    t_type("turn.completed");
    assert t_dump(dump)["decision"] == {"permissions": {}, "scope": "turn"};
}

test "stamps approvalScope on cards only when the turn controls this Mac" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="approval");
    _op_send_turn(inst, {"threadId": "t-host-scope", "text": "clean up", "integrations": {"localComputer": {"command": "/cua-driver", "args": ["mcp"], "env": {}, "platform": "darwin", "scope": "local-computer"}}});
    host = t_type("request.opened");
    assert host["approvalScope"] == "local-computer";
    _op_respond(inst, "t-host-scope", host["requestId"], {"behavior": "allow"});
    t_type("turn.completed");
    _op_send_turn(inst, {"threadId": "t-vm-scope", "text": "clean up", "integrations": {"localComputer": {"command": "/usr/bin/node", "args": ["/tmp/container-mcp.js"], "env": {}}}});
    vm = t_type("request.opened", thread_id="t-vm-scope");
    assert "approvalScope" not in vm;
    _op_respond(inst, "t-vm-scope", vm["requestId"], {"behavior": "allow"});
    t_type("turn.completed", thread_id="t-vm-scope");
}

test "auto-approves commands in fullAuto and per-turn Full without opening a request" {
    auto_rows: list[any] = [[True, None], [False, "full"]];
    for row in auto_rows {
        scratch = t_setup();
        inst = t_inst(scratch, mode="approval", full_auto=row[0]);
        dump = t_dump_at(scratch, "dump.json");
        turn: dict[str, any] = {"threadId": "t-auto", "text": "clean up"};
        if row[1] is not None { turn["approvalMode"] = row[1]; }
        _op_send_turn(inst, turn);
        t_type("turn.completed");
        assert len(t_of("request.opened")) == 0;
        assert t_dump(dump)["decision"] == {"decision": "approved"};
    }
}

test "rejects a second turn while one is in flight" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="approval");
    _op_send_turn(inst, {"threadId": "t-busy", "text": "one"});
    t_type("request.opened");
    def second { _op_send_turn(inst, {"threadId": "t-busy", "text": "two"}); }
    t_raises(second, "already running");
    _op_interrupt(inst, "t-busy", None);
    t_type("turn.completed");
    assert "t-busy" not in inst["live"];
}

test "steers the running turn through turn/steer without killing the child" {
    scratch = t_setup();
    dump = t_dump_at(scratch, "codex-steer.json");
    inst = t_inst(scratch, mode="approval");
    _op_send_turn(inst, {"threadId": "t-codex-steer", "text": "one"});
    opened = t_type("request.opened");
    assert _op_steer(inst, "t-codex-steer", "and also this") == "steered";
    snapshot = t_dump(dump);
    assert [c for c in snapshot["calls"] if c["method"] == "turn/steer"][0]["params"] == {"threadId": "codex-thread-1", "input": [{"type": "text", "text": "and also this"}], "expectedTurnId": "turn-1"};
    assert t_alive(snapshot["pid"]);
    assert len(t_errors()) == 0;
    _op_respond(inst, "t-codex-steer", opened["requestId"], {"behavior": "deny"});
    assert t_type("turn.completed")["ok"] is True;
    assert len(t_errors()) == 0;
    def dead -> bool { return not t_alive(snapshot["pid"]); }
    assert t_wait_for(dead, 5.0);
}

test "reports an explicitly refused steer as refused so the caller queues, and keeps the child alive" {
    scratch = t_setup();
    dump = t_dump_at(scratch, "codex-steer-refused.json");
    t_env("FAKE_CODEX_STEER_ERROR", json.dumps({"code": -32000, "message": "active turn is not steerable"}));
    inst = t_inst(scratch, mode="approval");
    _op_send_turn(inst, {"threadId": "t-codex-steer-refused", "text": "one"});
    opened = t_type("request.opened");
    assert _op_steer(inst, "t-codex-steer-refused", "queued words") == "refused";
    turn_pid = t_dump(dump)["pid"];
    assert t_alive(turn_pid);
    assert len(t_errors()) == 0;
    # the queued words run as their own turn: fresh child
    _op_respond(inst, "t-codex-steer-refused", opened["requestId"], {"behavior": "deny"});
    assert t_type("turn.completed")["ok"] is True;
    t_clear_events();
    _op_send_turn(inst, {"threadId": "t-codex-steer-refused", "text": "queued words"});
    t_type("request.opened");
    def fresh -> bool { return t_dump(dump)["pid"] != turn_pid; }
    assert t_wait_for(fresh, 5.0);
    assert t_alive(t_dump(dump)["pid"]);
    _op_interrupt(inst, "t-codex-steer-refused", None);
    t_type("turn.completed");
}

test "steer is refused with no running turn" {
    scratch = t_setup();
    inst = t_inst(scratch);
    assert _op_steer(inst, "t-codex-idle", "hi") == "refused";
}

test "a steer that times out after delivery is indeterminate, never a re-queueable refusal" {
    scratch = t_setup();
    dump = t_dump_at(scratch, "codex-steer-hang.json");
    t_env("FAKE_CODEX_STEER_HANG", "1");
    t_env("FAKE_CODEX_STEER_TIMEOUT_MS", "150");
    inst = t_inst(scratch, mode="approval");
    _op_send_turn(inst, {"threadId": "t-codex-steer-hang", "text": "one"});
    t_type("request.opened");
    assert _op_steer(inst, "t-codex-steer-hang", "maybe folded words") == "indeterminate";
    assert t_alive(t_dump(dump)["pid"]);
    assert len(t_errors()) == 0;
    _op_interrupt(inst, "t-codex-steer-hang", None);
    t_type("turn.completed");
}

test "Stop interrupts through the protocol and reports no signal error" {
    scratch = t_setup();
    dump = t_dump_at(scratch, "codex-interrupt.json");
    inst = t_inst(scratch, mode="approval");
    _op_send_turn(inst, {"threadId": "t-codex-stop-clean", "text": "one"});
    t_type("request.opened");
    _op_interrupt(inst, "t-codex-stop-clean", None);
    assert t_subset(t_type("turn.completed"), {"ok": False, "stopReason": "interrupted"});
    assert "turn/interrupt" in t_methods(dump);
    assert len(t_errors()) == 0;
}

test "escalates to a kill when the server ignores turn/interrupt, still without the signal error" {
    scratch = t_setup();
    t_dump_at(scratch, "codex-interrupt-silent.json");
    t_env("FAKE_CODEX_INTERRUPT_SILENT", "1");
    t_env("FAKE_CODEX_INTERRUPT_GRACE_MS", "60");
    inst = t_inst(scratch, mode="approval");
    _op_send_turn(inst, {"threadId": "t-codex-stop-wedged", "text": "one"});
    t_type("request.opened");
    _op_interrupt(inst, "t-codex-stop-wedged", None);
    assert t_subset(t_type("turn.completed"), {"ok": False, "stopReason": "interrupted"});
    assert len(t_errors()) == 0;
}

test "keeps ownership after an uncertain stop" {
    scratch = t_setup();
    inst = t_inst(scratch);
    real_kill = _kill_cli_tree;
    def failing_kill(a: dict[str, any], timeout_ms: float = 5000.0) -> bool { return False; }
    t_patch("_kill_cli_tree", failing_kill);
    _op_send_turn(inst, {"threadId": "t-uncertain-stop", "text": "one"});
    t_until(_did_not_shut_down);
    assert len(t_of("turn.completed")) == 0;
    assert "t-uncertain-stop" in inst["live"];
    def second { _op_send_turn(inst, {"threadId": "t-uncertain-stop", "text": "two"}); }
    t_raises(second, "already running");
    t_patch("_kill_cli_tree", real_kill);
    _op_interrupt(inst, "t-uncertain-stop", None);
    t_type("turn.completed");
    assert "t-uncertain-stop" not in inst["live"];
}

def _did_not_shut_down(ev: dict[str, any]) -> bool {
    return ev["type"] == "runtime.error" and "did not shut down" in ev["message"];
}

test "a missing binary surfaces as a failed turn" {
    scratch = t_setup();
    inst = t_inst(scratch);
    inst["config"]["cli"] = os.path.join(scratch, "does-not-exist");
    _op_send_turn(inst, {"threadId": "t-missing", "text": "go"});
    done = t_type("turn.completed");
    assert t_subset(done, {"ok": False, "stopReason": "spawn_error"});
    assert t_subset(t_errors()[0], {"setup": True});
    assert [ev["type"] for ev in t_events()] == ["turn.started", "runtime.error", "turn.completed"];
}

test "marks a Codex 401 as setup so the UI offers sign-in instead of Retry" {
    scratch = t_setup();
    inst = t_inst(scratch, mode="unauthorized");
    _op_send_turn(inst, {"threadId": "t-unauthorized", "text": "hi"});
    assert t_type("runtime.error").get("setup") is True;
    assert t_subset(t_type("turn.completed"), {"ok": False, "stopReason": "auth_required"});
}

test "surfaces provider safety blocks once without retrying or asking for login" {
    for mode in ["safety-rpc", "safety-completion", "safety-notification"] {
        scratch = t_setup();
        inst = t_inst(scratch, mode=mode);
        turn_id = _op_send_turn(inst, {"threadId": "t-safety", "text": "Deploy my site", "approvalMode": "full"});
        assert t_subset(t_type("turn.completed", turn_id=turn_id), {"ok": False, "stopReason": "provider_safety"}), mode;
        errors = t_errors();
        assert len(errors) == 1, mode + json.dumps(errors);
        assert "blocked by our safety systems" in errors[0]["message"];
        assert "setup" not in errors[0];
        assert len(t_of("turn.retrying")) == 0;
    }
}

test "auto-retries a transient turn/start failure, then completes with one final message" {
    scratch = t_setup();
    t_env("FAKE_CODEX_TRANSIENTS", "2");
    t_env("FAKE_CODEX_STATE", os.path.join(scratch, "codex-launches"));
    t_env("FAKE_CODEX_RETRY_SCALE", "0.001");
    inst = t_inst(scratch);
    _op_send_turn(inst, {"threadId": "t-codex-retry", "text": "hi"});
    def ok_done(ev: dict[str, any]) -> bool { return ev["type"] == "turn.completed" and ev["ok"] is True; }
    t_until(ok_done);
    retries = t_of("turn.retrying");
    assert [ev["attempt"] for ev in retries] == [1, 2];
    assert all([ev["delayMs"] > 0 and isinstance(ev["reason"], str) for ev in retries]);
    assert len(t_of("turn.started")) == 1;
    assert len([ev for ev in t_events() if ev["type"] == "item.completed" and ev.get("itemType") == "assistant_text"]) == 1;
}

test "does not repeat an accepted instruction update when turn/start retries" {
    scratch = t_setup();
    t_env("FAKE_CODEX_TRANSIENTS", "1");
    t_env("FAKE_CODEX_STATE", os.path.join(scratch, "instruction-retry"));
    t_env("FAKE_CODEX_RETRY_SCALE", "0.001");
    inst = t_inst(scratch, mode="resume");
    _op_send_turn(inst, {"threadId": "t-instruction-retry", "text": "continue", "system": "Updated rules.", "resumeCursor": "old-session"});
    def ok_done(ev: dict[str, any]) -> bool { return ev["type"] == "turn.completed" and ev["ok"] is True; }
    t_until(ok_done);
    entries = [json.loads(line) for line in t_native_log(scratch, "t-instruction-retry").strip().split("\n")];
    outgoing = [e for e in entries if e["dir"] == "out"];
    assert len([e for e in outgoing if e["msg"].get("method") == "thread/inject_items"]) == 1;
    assert len([e for e in outgoing if e["msg"].get("method") == "turn/start"]) == 2;
}

test "stops retrying at the attempt cap and settles as failed" {
    scratch = t_setup();
    t_env("FAKE_CODEX_TRANSIENTS", "9");
    t_env("FAKE_CODEX_STATE", os.path.join(scratch, "codex-launches-cap"));
    t_env("FAKE_CODEX_RETRY_SCALE", "0.001");
    inst = t_inst(scratch);
    _op_send_turn(inst, {"threadId": "t-codex-cap", "text": "hi"});
    assert t_type("turn.completed")["ok"] is False;
    assert [ev["attempt"] for ev in t_of("turn.retrying")] == [1, 2];
}

test "interrupting one thread does not cancel another thread's retry" {
    scratch = t_setup();
    t_env("FAKE_CODEX_TRANSIENTS", "2");
    t_env("FAKE_CODEX_STATE", os.path.join(scratch, "codex-launches-concurrent"));
    inst = t_inst(scratch);
    _op_send_turn(inst, {"threadId": "t-codex-stop", "text": "stop me"});
    _op_send_turn(inst, {"threadId": "t-codex-continue", "text": "keep going"});
    t_type("turn.retrying", thread_id="t-codex-stop");
    t_type("turn.retrying", thread_id="t-codex-continue");
    _op_interrupt(inst, "t-codex-stop", None);
    assert t_type("turn.completed", thread_id="t-codex-continue", timeout=30.0)["ok"] is True;
}

test "an interrupt during the retry backoff settles the turn at once, not after the wait" {
    scratch = t_setup();
    t_env("FAKE_CODEX_TRANSIENTS", "9");
    t_env("FAKE_CODEX_STATE", os.path.join(scratch, "codex-launches-cancel-backoff"));
    t_env("FAKE_CODEX_RETRY_SCALE", "60");
    inst = t_inst(scratch);
    _op_send_turn(inst, {"threadId": "t-codex-cancel-backoff", "text": "hi"});
    t_type("turn.retrying");
    _op_interrupt(inst, "t-codex-cancel-backoff", None);
    assert t_subset(t_type("turn.completed", timeout=5.0), {"ok": False, "stopReason": "interrupted"});
    assert len(t_of("turn.retrying")) == 1;
}

test "never retries after agent text already streamed" {
    scratch = t_setup();
    t_env("FAKE_CODEX_TRANSIENTS", "1");
    t_env("FAKE_CODEX_PARTIAL_FAILS", "1");
    t_env("FAKE_CODEX_STATE", os.path.join(scratch, "codex-launches-partial"));
    t_env("FAKE_CODEX_RETRY_SCALE", "0.001");
    inst = t_inst(scratch);
    _op_send_turn(inst, {"threadId": "t-codex-partial", "text": "hi"});
    assert t_type("turn.completed")["ok"] is False;
    assert any([ev["type"] == "content.delta" and ev["streamKind"] == "assistant_text" for ev in t_events()]);
    assert len(t_of("turn.retrying")) == 0;
}

test "retries a transient app-server crash before the turn starts" {
    scratch = t_setup();
    t_env("FAKE_CODEX_LAUNCH_CRASHES", "1");
    t_env("FAKE_CODEX_STATE", os.path.join(scratch, "codex-launch-crash"));
    t_env("FAKE_CODEX_RETRY_SCALE", "0.001");
    inst = t_inst(scratch);
    _op_send_turn(inst, {"threadId": "t-codex-launch-crash", "text": "hi"});
    def ok_done(ev: dict[str, any]) -> bool { return ev["type"] == "turn.completed" and ev["ok"] is True; }
    t_until(ok_done);
    assert [ev["attempt"] for ev in t_of("turn.retrying")] == [1];
    assert len(t_of("turn.started")) == 1;
    assert len([ev for ev in t_events() if ev["type"] == "item.completed" and ev.get("itemType") == "assistant_text"]) == 1;
}

test "never replays a turn after turn/start was acknowledged, even for a transient-looking exit" {
    scratch = t_setup();
    ack_gate = os.path.join(scratch, "ack-crash-gate");
    t_env("FAKE_CODEX_ACK_CRASH", ack_gate);
    real_handle = _handle_line;
    def gated(inst_arg: dict[str, any], lt: dict[str, any], a: dict[str, any], line: str) {
        real_handle(inst_arg, lt, a, line);
        if '"result":{"turn":{"id":"turn-1"}}' in line { t_write(ack_gate, ""); }
    }
    t_patch("_handle_line", gated);
    inst = t_inst(scratch);
    _op_send_turn(inst, {"threadId": "t-codex-ack-crash", "text": "hi"});
    done = t_type("turn.completed");
    assert t_subset(done, {"ok": False, "stopReason": "exit_before_result"});
    assert len(t_of("turn.retrying")) == 0;
    assert "connection reset" in t_errors()[0]["message"];
}

test "does not blame stale stderr when the app-server is killed mid-turn" {
    scratch = t_setup();
    stderr_gate = os.path.join(scratch, "exit-mid-turn-stderr-gate");
    kill_gate = os.path.join(scratch, "exit-mid-turn-kill-gate");
    t_env("FAKE_CODEX_EXIT_MID_TURN", stderr_gate);
    t_env("FAKE_CODEX_EXIT_MID_TURN_KILL", kill_gate);
    inst = t_inst(scratch);
    _op_send_turn(inst, {"threadId": "t-codex-exit-mid-turn", "text": "hi"});
    def saw_426 -> bool {
        live = inst["live"].get("t-codex-exit-mid-turn");
        return live is not None and live.get("attempt") is not None and "426" in live["attempt"]["stderr"];
    }
    assert t_wait_for(saw_426, 15.0);
    t_write(stderr_gate, "");
    def reasoning(ev: dict[str, any]) -> bool { return ev["type"] == "content.delta" and ev["streamKind"] == "reasoning_text"; }
    t_until(reasoning);
    t_write(kill_gate, "");
    done = t_type("turn.completed");
    assert t_subset(done, {"ok": False, "stopReason": "exit_before_result"});
    assert len(t_of("turn.retrying")) == 0;
    message = t_errors()[0]["message"];
    assert "signal SIGKILL" in message, message;
    assert "no stderr after the last app-server output" in message;
    assert "426" not in message;
}

test "treats a signal-killed app-server as terminal even with transient stderr" {
    scratch = t_setup();
    state_file = os.path.join(scratch, "launch-kills.json");
    t_env("FAKE_CODEX_LAUNCH_KILLS", "1");
    t_env("FAKE_CODEX_STATE", state_file);
    inst = t_inst(scratch);
    _op_send_turn(inst, {"threadId": "t-codex-launch-kill", "text": "hi"});
    assert t_subset(t_type("turn.completed"), {"ok": False, "stopReason": "exit_before_result"});
    assert len(t_of("turn.retrying")) == 0;
    assert "signal SIGKILL" in t_errors()[0]["message"];
    f = open(state_file, "r");
    assert f.read() == "1";
    f.close();
}

test "treats a silent pre-ack exit as terminal instead of retrying off lifetime stderr" {
    scratch = t_setup();
    state_file = os.path.join(scratch, "launch-silent.json");
    t_env("FAKE_CODEX_LAUNCH_SILENT", "1");
    t_env("FAKE_CODEX_STATE", state_file);
    inst = t_inst(scratch);
    _op_send_turn(inst, {"threadId": "t-codex-launch-silent", "text": "hi"});
    assert t_subset(t_type("turn.completed"), {"ok": False, "stopReason": "exit_before_result"});
    assert len(t_of("turn.retrying")) == 0;
    assert "codex exited 1 before turn/completed" in t_errors()[0]["message"];
}

test "does not announce a retry when Stop races a transient handshake failure" {
    scratch = t_setup();
    t_env("FAKE_CODEX_TRANSIENTS", "1");
    t_env("FAKE_CODEX_STATE", os.path.join(scratch, "stop-race.json"));
    t_env("FAKE_CODEX_RETRY_SCALE", "0.01");
    inst = t_inst(scratch);
    # The TS test's Stop runs in the microtask after session.started, before
    # the turn/start reply is read: here the hook stops on the emit itself.
    def stop_on_session(ev: dict[str, any]) {
        if ev["type"] == "session.started" { _op_interrupt(inst, "t-codex-stop-race", None); }
    }
    _t["hooks"].append(stop_on_session);
    _op_send_turn(inst, {"threadId": "t-codex-stop-race", "text": "hi"});
    t_type("turn.completed");
    assert len(t_of("turn.retrying")) == 0;
}

test "banks this turn's usage after a coalesced thread response and restored usage notification" {
    for mode in ["start", "resume"] {
        scratch = t_setup();
        t_env("FAKE_CODEX_RESTORED_USAGE", "1");
        inst = t_inst(scratch, mode=("resume" if mode == "resume" else None));
        turn: dict[str, any] = {"threadId": "t-codex-restored-usage-" + mode, "text": "hi"};
        if mode == "resume" { turn["resumeCursor"] = "codex-thread-1"; }
        _op_send_turn(inst, turn);
        t_type("turn.completed");
        assert t_subset(t_of("thread.token-usage.updated")[0], {"input": 107, "output": 13, "cachedInput": 54});
        assert t_subset(t_events()[-1], {"type": "turn.completed", "ok": True, "usage": {"input": 7, "output": 3, "cachedInput": 4}});
        assert len(t_of("thread.token-usage.updated")) == 1;
    }
}

test "sends effort on turn/start, and omits the key when unset" {
    scratch = t_setup();
    inst = t_inst(scratch);
    dump = t_dump_at(scratch, "effort.json");
    _op_send_turn(inst, {"threadId": "t-effort", "text": "hi", "effort": "xhigh"});
    t_type("turn.completed");
    assert t_calls(dump, "turn/start")[0]["params"]["effort"] == "xhigh";
    t_clear_events();
    _op_send_turn(inst, {"threadId": "t-no-effort", "text": "hi"});
    t_type("turn.completed");
    assert "effort" not in t_calls(dump, "turn/start")[0]["params"];
    t_teardown();
}
