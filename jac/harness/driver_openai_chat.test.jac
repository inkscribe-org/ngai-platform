"""Ported invariants of the chat-completions runtime (openai-compat kind).

Annexes driver_openai_chat.jac (no self-import). Specs:
  server/drivers/openai-chat-protocol.test.ts  -> "protocol: ..."
  server/drivers/chat-tool-approval.test.ts    -> "approval: ..."
  server/drivers/chat-mcp-tools.test.ts        -> "mcp: ..." / "schema: ..."
  server/drivers/openai-chat.test.ts           -> "runtime: ..."
  server/drivers/openai-chat-tools.test.ts     -> "tools: ..."

Real transports only: a ThreadingHTTPServer plays the provider (SSE or JSON
bodies, held streams, dropped sockets), node child processes play the MCP
servers (stdio JSON-RPC), and turns run through the drivers.jac ops exactly
as the node shim calls them; events are captured at the bridge."""

import os;
import re;
import sys;
import json;
import time;
import uuid;
import shutil;
import signal;
import tempfile;
import threading;
import http.server;
import base64;
import zlib;

import from driver_claude_support { augmented_path }

import from driver_openai_chat_protocol { provider_error }

import from drivers {
    _state as _drivers_state, _instances as _drivers_instances, driver_create, driver_send_turn, driver_respond,
    driver_steer, driver_interrupt_turn, driver_dispose, driver_generate_text,
}

glob API_KEY_CANARY: str = "fixture-credential-cda00ee8d8384f54";
glob _fx: dict[str, any] = {"events": {}, "calls": [], "cleanups": [], "listeners": []};

# ── bridge capture ─────────────────────────────────────────────────────────

def _capture(op: str, payload: dict[str, any]) -> dict[str, any] {
    _fx["calls"].append({"op": op, "payload": payload});
    if op == "driver_event" {
        iid = payload["instance_id"];
        if iid not in _fx["events"] { _fx["events"][iid] = []; }
        _fx["events"][iid].append(payload["event"]);
        for fn in list(_fx["listeners"]) { fn(iid, payload["event"]); }
    }
    return {"ok": True};
}

def _install_bridge {
    _drivers_state.update({"bridge_fn": _capture});
}

def _events(iid: str) -> list[any] {
    return _fx["events"].get(iid) or [];
}

def _until(pred: any, timeout: float = 10.0) -> any {
    deadline = time.monotonic() + timeout;
    while time.monotonic() < deadline {
        hit = pred();
        if hit { return hit; }
        time.sleep(0.01);
    }
    raise AssertionError("condition not met within " + str(timeout) + "s");
}

def _find(iid: str, kind: str) -> any {
    for ev in _events(iid) {
        if ev.get("type") == kind { return ev; }
    }
    return None;
}

def _all(iid: str, kind: str) -> list[any] {
    return [ev for ev in _events(iid) if ev.get("type") == kind];
}

def _trace(iid: str) -> str {
    # Failure context: the event types plus every error message so far.
    parts: list[str] = [];
    for ev in _events(iid) {
        parts.append(ev.get("type", "?") + ((": " + str(ev.get("message"))) if ev.get("message") else ""));
    }
    return " | ".join(parts)[0:3000];
}

def _completed(iid: str, timeout: float = 15.0) -> dict[str, any] {
    def done() -> any { return _find(iid, "turn.completed"); }
    try {
        return _until(done, timeout);
    } except AssertionError {
        raise AssertionError("no turn.completed: " + _trace(iid));
    }
}

def _opened(iid: str, timeout: float = 10.0) -> dict[str, any] {
    def hit() -> any { return _find(iid, "request.opened"); }
    try {
        return _until(hit, timeout);
    } except AssertionError {
        raise AssertionError("no request.opened: " + _trace(iid));
    }
}

def _cleanup {
    while _fx["cleanups"] {
        fn = _fx["cleanups"].pop();
        try { fn(); } except Exception { }
    }
    _fx["listeners"].clear();
}

def _tmpdir(prefix: str) -> str {
    d = tempfile.mkdtemp(prefix=prefix);
    def rm { shutil.rmtree(d, ignore_errors=True); }
    _fx["cleanups"].append(rm);
    return d;
}

def _alive(pid: int) -> bool {
    try {
        os.kill(pid, 0);
    } except ProcessLookupError {
        return False;
    } except Exception {
        return True;
    }
    # A zombie still answers kill(0): count it as dead.
    try {
        with open("/proc/" + str(pid) + "/stat", "r") as fh {
            return fh.read().split(") ")[-1].split(" ")[0] != "Z";
        }
    } except Exception {
        return True;
    }
}

# ── fake provider ──────────────────────────────────────────────────────────

def chunk(delta: any, finish: any = None) -> dict[str, any] {
    return {"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]};
}

def tool_call(name: str = "audit_write", args: str = "{\"name\":\"receipt\",\"value\":\"done\"}", cid: str = "call_write") -> dict[str, any] {
    return {"index": 0, "id": cid, "type": "function", "function": {"name": name, "arguments": args}};
}

def _start_provider(script: any) -> dict[str, any] {
    # script(body, w, round): w["sse"](chunks, done=True), w["json"](status,
    # obj), w["raw"](status, text, ctype), w["hold"](), w["destroy"]().
    srv: dict[str, any] = {"requests": [], "release": threading.Event(), "mcp": [], "mcp_started": threading.Event()};
    def handle(h: any) {
        length = int(h.headers.get("content-length") or "0");
        data = h.rfile.read(length).decode("utf-8") if length else "";
        if h.path == "/v1/models" {
            _send(h, 200, "{\"data\":[]}", "application/json");
            return;
        }
        if h.path == "/mcp-start" {
            srv["mcp"].append(json.loads(data));
            srv["mcp_started"].set();
            _send(h, 200, "ok", "text/plain");
            return;
        }
        body = json.loads(data);
        srv["requests"].append(body);
        w = _writer(h, srv);
        script(body, w, len(srv["requests"]));
    }
    def quiet(h: any, fmt: any, *args: any) { }
    handler = type("FakeProvider", (http.server.BaseHTTPRequestHandler,), {"do_POST": handle, "log_message": quiet});
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler);
    server.daemon_threads = True;
    threading.Thread(target=server.serve_forever, daemon=True).start();
    srv["origin"] = "http://127.0.0.1:" + str(server.server_address[1]);
    def stop {
        srv["release"].set();
        server.shutdown();
        server.server_close();
    }
    _fx["cleanups"].append(stop);
    return srv;
}

def _send(h: any, status: int, text: str, ctype: str) {
    raw = text.encode("utf-8");
    h.send_response(status);
    h.send_header("content-type", ctype);
    h.send_header("content-length", str(len(raw)));
    h.end_headers();
    h.wfile.write(raw);
}

def _writer(h: any, srv: dict[str, any]) -> dict[str, any] {
    def sse(chunks: list[any], done: bool = True) {
        h.send_response(200);
        h.send_header("content-type", "text/event-stream");
        h.end_headers();
        for c in chunks { h.wfile.write(("data: " + json.dumps(c) + "\n\n").encode("utf-8")); }
        h.wfile.flush();
        if done {
            h.wfile.write(b"data: [DONE]\n\n");
        } else {
            srv["release"].wait(30);
        }
    }
    def as_json(status: int, value: any) { _send(h, status, json.dumps(value), "application/json"); }
    def raw(status: int, text: str, ctype: str = "text/event-stream") {
        h.send_response(status);
        h.send_header("content-type", ctype);
        h.end_headers();
        h.wfile.write(text.encode("utf-8"));
        h.wfile.flush();
    }
    def more(text: str) {
        h.wfile.write(text.encode("utf-8"));
        h.wfile.flush();
    }
    def hold { srv["release"].wait(30); }
    def destroy {
        h.close_connection = True;
        try { h.connection.shutdown(2); } except Exception { }
    }
    return {"sse": sse, "json": as_json, "raw": raw, "more": more, "hold": hold, "destroy": destroy};
}

def answer(w: dict[str, any], text: str = "The operation is complete.") {
    w["sse"]([chunk({"content": text}, "stop")]);
}

# ── fake MCP (node, MCP on the wire) ───────────────────────────────────────

glob MCP_SCRIPT: str = """
import { appendFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
const [directory, callback] = process.argv.slice(2);
writeFileSync(join(directory, "pid"), String(process.pid));
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\\n");
const schema = { type: "object", properties: { name: { type: "string" }, value: { type: "string" } }, required: ["name", "value"], additionalProperties: false };
createInterface({ input: process.stdin }).on("line", async (line) => {
  const request = JSON.parse(line);
  if (request.method === "initialize") {
    reply(request.id, { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "fixture", version: "1" } });
  } else if (request.method === "tools/list") {
    reply(request.id, { tools: ["write", "wait", "fail"].map((name) => ({ name, description: "Synthetic fixture operation", inputSchema: schema })) });
  } else if (request.method === "tools/call") {
    const { name, arguments: args } = request.params;
    await fetch(callback + "/mcp-start", { method: "POST", body: JSON.stringify({ name, args }) });
    if (name === "fail") {
      reply(request.id, { isError: true, content: [{ type: "text", text: "Synthetic tool failed before writing." }] });
      return;
    }
    if (name === "wait") await new Promise((resolve) => setTimeout(resolve, 30_000));
    appendFileSync(join(directory, "effects.ndjson"), JSON.stringify({ name, ...args }) + "\\n");
    reply(request.id, { content: [{ type: "text", text: "Stored " + args.name + "=" + args.value }] });
  } else if (request.id !== undefined && request.method === "ping") reply(request.id, {});
});
""";

glob PNG_B64: str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jBv0AAAAASUVORK5CYII=";

def _node() -> str {
    return shutil.which("node") or "node";
}

# A chat-tools fixture: provider + MCP helper + an openai-compat instance.
def fixture(script: any, api_key: str = API_KEY_CANARY, mcp_script: str = "") -> dict[str, any] {
    _install_bridge();
    srv = _start_provider(script);
    d = _tmpdir("omb-chat-tools-");
    helper = os.path.join(d, "mcp.mjs");
    with open(helper, "w") as fh { fh.write(mcp_script or MCP_SCRIPT); }
    iid = str(uuid.uuid4());
    created = driver_create(
        omb_token=None, instance_id=iid, kind="openai-compat", display_name="Tool contract fixture",
        environment={"FIXTURE_CHAT_KEY": api_key}, enabled=True,
        config={"url": srv["origin"] + "/v1", "apiKeyEnv": "FIXTURE_CHAT_KEY"},
    );
    assert created["ok"], created;
    def dispose { driver_dispose(omb_token=None, instance_id=iid); }
    _fx["cleanups"].append(dispose);
    f: dict[str, any] = {
        "iid": iid, "srv": srv, "requests": srv["requests"], "dir": d, "thread": str(uuid.uuid4()),
        "integrations": {"custom": {"audit": {"command": _node(), "args": [helper, d, srv["origin"]], "env": {}}}},
    };
    return f;
}

def start(f: dict[str, any], extra: dict[str, any] = {}) -> str {
    turn: dict[str, any] = {"threadId": f["thread"], "text": "Store the synthetic receipt.", "model": "fixture-model", "integrations": f["integrations"]};
    turn.update(extra);
    for (k, v) in list(turn.items()) {
        if v is None { turn.pop(k); }
    }
    out = driver_send_turn(omb_token=None, instance_id=f["iid"], turn=turn);
    assert out["ok"], out;
    return out["turn_id"];
}

def effects(f: dict[str, any]) -> list[any] {
    path = os.path.join(f["dir"], "effects.ndjson");
    if not os.path.exists(path) { return []; }
    with open(path) as fh { return [json.loads(l) for l in fh.read().strip().split("\n") if l]; }
}

def respond_card(f: dict[str, any], request_id: str, behavior: str, message: any = None, thread: any = None) -> str {
    decision: dict[str, any] = {"behavior": behavior};
    if message is not None { decision["message"] = message; }
    return driver_respond(omb_token=None, instance_id=f["iid"], thread_id=thread or f["thread"], request_id=request_id, decision=decision)["outcome"];
}

def decide(f: dict[str, any], behavior: str = "allow") -> str {
    ev = _opened(f["iid"]);
    assert ev["requestType"] == "permission";
    assert effects(f) == [];
    return respond_card(f, ev["requestId"], behavior);
}

def auto_allow(f: dict[str, any]) -> list[str] {
    seen: list[str] = [];
    def on(iid: str, ev: dict[str, any]) {
        if iid == f["iid"] and ev.get("type") == "request.opened" {
            seen.append(ev["requestId"]);
            threading.Thread(target=respond_card, args=(f, ev["requestId"], "allow"), daemon=True).start();
        }
    }
    _fx["listeners"].append(on);
    return seen;
}

def tools_of(request: dict[str, any]) -> any {
    if "tools" not in request { return None; }
    return [t["function"]["name"] for t in request["tools"]];
}

def compat(origin: str, extra_config: dict[str, any] = {}, env: dict[str, any] = {}) -> str {
    _install_bridge();
    iid = str(uuid.uuid4());
    config: dict[str, any] = {"url": origin, "apiKeyEnv": "K", "model": "m"};
    config.update(extra_config);
    environment: dict[str, any] = {"K": "secret"};
    environment.update(env);
    created = driver_create(omb_token=None, instance_id=iid, kind="openai-compat", display_name="Compat",
        environment=environment, enabled=True, config=config);
    assert created["ok"], created;
    def dispose { driver_dispose(omb_token=None, instance_id=iid); }
    _fx["cleanups"].append(dispose);
    return iid;
}

def run_turn(script: any) -> list[any] {
    # openai-chat.test.ts runTurn: one plain turn against `script`.
    srv = _start_provider(script);
    iid = compat(srv["origin"] + "/v1", {"model": "MiniMax-M3"});
    out = driver_send_turn(omb_token=None, instance_id=iid, turn={"threadId": "thread", "text": "hi"});
    assert out["ok"], out;
    _completed(iid);
    return _events(iid);
}

def body_of(text: str) -> any {
    def script(body: any, w: dict[str, any], n: int) { w["raw"](200, text); }
    return script;
}

# ═══ protocol (openai-chat-protocol.test.ts) ═══════════════════════════════

glob COMPLETE_CALL: dict[str, any] = {"id": "call_echo", "type": "function", "function": {"name": "echo", "arguments": "{}"}};

def _raises(fn: any, pattern: str = "") -> str {
    try {
        fn();
    } except Exception as e {
        if pattern { assert re.search(pattern, str(e)) is not None, str(e); }
        return str(e);
    }
    raise AssertionError("expected an exception");
}

test "protocol: treats explicit null continuation fields as absent" {
    calls = new_tool_calls();
    calls.add([{"index": 0, "id": "call_echo", "type": "function", "function": {"name": "echo", "arguments": ""}}], True);
    calls.add([{"index": 0, "id": None, "type": None, "function": {"name": None, "arguments": None}}], True);
    calls.add([{"index": 0, "id": None, "function": {"name": None, "arguments": "{}"}}], True);
    assert calls.finish("tool_calls", False) == [COMPLETE_CALL];
}

test "protocol: still rejects incomplete calls after null-only deltas" {
    calls = new_tool_calls();
    calls.add([{"index": 0, "id": None, "type": None, "function": {"name": None, "arguments": None}}], True);
    def fin { calls.finish("tool_calls", False); }
    _raises(fin, "incomplete or duplicate");
}

test "protocol: rejects unsupported or malformed continuation fields" {
    for delta in [
        {"index": 0, "type": "computer"}, {"index": 0, "function": None}, {"index": 0, "function": []},
        {"index": 0, "function": {"name": 1}}, {"index": 0, "function": {"arguments": 1}},
    ] {
        calls = new_tool_calls();
        def add { calls.add([delta], True); }
        _raises(add);
    }
}

test "protocol: preserves tool-call size limits" {
    for spec in [["call_large_name", "n" * 65, "{}"], ["call_large_args", "echo", "x" * 256001]] {
        calls = new_tool_calls();
        def add { calls.add([{"index": 0, "id": spec[0], "function": {"name": spec[1], "arguments": spec[2]}}], True); }
        _raises(add, "size limit");
    }
}

test "protocol: accepts 32 calls in one reply and refuses a 33rd" {
    calls = new_tool_calls();
    batch: list[any] = [];
    for i in range(32) {
        c = dict(COMPLETE_CALL);
        c["index"] = i;
        c["id"] = "call_" + str(i);
        batch.append(c);
    }
    calls.add(batch, True);
    assert len(calls.finish("tool_calls", False)) == 32;
    extra = dict(COMPLETE_CALL);
    extra["index"] = 32;
    def add { new_tool_calls().add([extra], True); }
    _raises(add, "invalid tool-call index");
}

test "protocol: rejects null required fields in non-streaming responses" {
    variants: list[any] = [];
    for field in ["id", "type", "function"] {
        c = json.loads(json.dumps(COMPLETE_CALL));
        c[field] = None;
        variants.append(c);
    }
    for field in ["name", "arguments"] {
        c = json.loads(json.dumps(COMPLETE_CALL));
        c["function"][field] = None;
        variants.append(c);
    }
    for c in variants {
        calls = new_tool_calls();
        def add { calls.add([c], False); calls.finish("tool_calls", False); }
        _raises(add);
    }
}

test "protocol: provider error verdicts" {
    assert provider_error({"base_resp": {"status_code": 1008, "status_msg": "insufficient balance"}}) == "upstream error 1008: insufficient balance";
    assert provider_error({"error": {"type": "x"}}) == "unknown error";
    assert provider_error({"error": "plain"}) == "plain";
    assert provider_error({"base_resp": {"status_code": 0}}) is None;
    assert rejects_key(401, "") and not rejects_key(401, "rate limit");
    assert rejects_key(400, "{\"error\":{\"code\":\"invalid_api_key\"}}") and not rejects_key(403, "You do not have access to this model");
    assert announces_action("Checking the page first —") and announces_action("Let me look.") and not announces_action("Done?");
}

# ═══ approval (chat-tool-approval.test.ts) ═════════════════════════════════

def _gate(timeout_ms: float = 900000.0, opens: any = None) -> dict[str, any] {
    rec: dict[str, any] = {"open": [], "resolved": [], "open_q": [], "resolved_q": [], "signal": new_signal()};
    def on_open(ask: dict[str, any]) {
        rec["open"].append(ask);
        if opens is not None { opens(rec, ask); }
    }
    def on_resolved(ask: dict[str, any], allowed: bool, source: str) { rec["resolved"].append([ask, allowed, source]); }
    def on_open_q(ask: dict[str, any], questions: list[any]) {
        rec["open_q"].append(ask);
        if opens is not None { opens(rec, ask); }
    }
    def on_resolved_q(ask: dict[str, any], answered: bool, source: str) { rec["resolved_q"].append([ask, answered, source]); }
    rec["gate"] = new_approval(rec["signal"], {"open": on_open, "resolved": on_resolved, "open_question": on_open_q, "resolved_question": on_resolved_q}, timeout_ms);
    return rec;
}

def _async(fn: any, *args: any) -> dict[str, any] {
    box: dict[str, any] = {"done": threading.Event(), "value": None};
    def run {
        box["value"] = fn(*args);
        box["done"].set();
    }
    threading.Thread(target=run, daemon=True).start();
    return box;
}

def _value(box: dict[str, any]) -> any {
    assert box["done"].wait(10), "pending forever";
    return box["value"];
}

glob QUESTIONS: list[any] = [{"question": "Ship the fixture?", "options": [{"label": "Yes"}, {"label": "No"}]}];

test "approval: denies an unanswered request when its deadline expires and rejects late approval" {
    r = _gate(100.0);
    box = _async(r["gate"].ask, "audit_write", "Write the fixture receipt");
    assert _value(box) is False;
    assert len(r["resolved"]) == 1 and r["resolved"][0][1:] == [False, "timeout"];
    assert r["gate"].answer(r["open"][0]["id"], "allow", None) == "unavailable";
}

test "approval: denies a cancelled ask and never opens another one for the cancelled turn" {
    r = _gate();
    box = _async(r["gate"].ask, "audit_write", "Write the fixture receipt");
    def opened -> bool { return len(r["open"]) == 1; }
    _until(opened);
    r["signal"].abort();
    assert _value(box) is False;
    assert r["resolved"][0][1:] == [False, "system"];
    assert r["gate"].answer(r["open"][0]["id"], "allow", None) == "unavailable";
    assert r["gate"].ask("audit_write", "A later request") is False;
    assert len(r["open"]) == 1;
}

test "approval: closes every outstanding ask and permanently refuses future requests" {
    r = _gate();
    first = _async(r["gate"].ask, "audit_write", "First fixture receipt");
    second = _async(r["gate"].ask, "audit_write", "Second fixture receipt");
    def both -> bool { return len(r["open"]) == 2; }
    _until(both);
    r["gate"].close();
    r["gate"].close();
    assert [_value(first), _value(second)] == [False, False];
    assert len(r["resolved"]) == 2;
    for ask in r["open"] { assert r["gate"].answer(ask["id"], "allow", None) == "unavailable"; }
    assert r["gate"].ask("audit_write", "Request after close") is False;
    assert len(r["open"]) == 2;
}

test "approval: registers the request before publishing it so a synchronous harness approval works" {
    answered: list[str] = [];
    def opens(rec: dict[str, any], ask: dict[str, any]) { answered.append(rec["gate"].answer(ask["id"], "allow", None)); }
    r = _gate(900000.0, opens);
    assert r["gate"].ask("audit_write", "Write the fixture receipt") is True;
    assert answered == ["allowed-once"];
    assert len(r["resolved"]) == 1 and r["resolved"][0][0]["tool"] == "audit_write" and r["resolved"][0][1:] == [True, "user"];
    assert r["gate"].answer(r["resolved"][0][0]["id"], "allow", None) == "unavailable";
}

test "approval: resolves the person's reply verbatim and registers before publishing" {
    reply = "The user answered your questions.\n\nQ: Ship the fixture?\nA: Yes";
    answered: list[str] = [];
    def opens(rec: dict[str, any], ask: dict[str, any]) { answered.append(rec["gate"].answer(ask["id"], "answer", reply)); }
    r = _gate(900000.0, opens);
    assert r["gate"].question("ask_user", "Ship the fixture?", QUESTIONS) == reply;
    assert answered == ["answered"];
    assert r["resolved_q"][0][1:] == [True, "user"];
    assert r["gate"].answer(r["resolved_q"][0][0]["id"], "answer", "a late reply") == "unavailable";
}

test "approval: resolves null when its deadline expires and rejects a late answer" {
    r = _gate(100.0);
    assert r["gate"].question("ask_user", "Ship the fixture?", QUESTIONS) is None;
    assert r["resolved_q"][0][1:] == [False, "timeout"];
    assert r["gate"].answer(r["open_q"][0]["id"], "answer", "late") == "unavailable";
}

test "approval: resolves null when the turn aborts and never opens another ask" {
    r = _gate();
    box = _async(r["gate"].question, "ask_user", "Ship the fixture?", QUESTIONS);
    def opened -> bool { return len(r["open_q"]) == 1; }
    _until(opened);
    r["signal"].abort();
    assert _value(box) is None;
    assert r["resolved_q"][0][1:] == [False, "system"];
    assert r["gate"].question("ask_user", "A later ask", QUESTIONS) is None;
    assert len(r["open_q"]) == 1;
}

test "approval: closes an outstanding question as unanswered" {
    r = _gate();
    box = _async(r["gate"].question, "ask_user", "Ship the fixture?", QUESTIONS);
    def opened -> bool { return len(r["open_q"]) == 1; }
    _until(opened);
    r["gate"].close();
    assert _value(box) is None;
    assert r["resolved_q"][0][1:] == [False, "system"];
    assert r["gate"].answer(r["open_q"][0]["id"], "answer", "late") == "unavailable";
}

test "approval: keeps a question pending for an allow or a blank reply, then denies on request" {
    r = _gate();
    box = _async(r["gate"].question, "ask_user", "Ship the fixture?", QUESTIONS);
    def opened -> bool { return len(r["open_q"]) == 1; }
    _until(opened);
    rid = r["open_q"][0]["id"];
    assert r["gate"].answer(rid, "allow", None) == "unavailable";
    assert r["gate"].answer(rid, "answer", "   ") == "unavailable";
    assert r["gate"].answer(rid, "deny", None) == "rejected";
    assert _value(box) is None;
    assert r["resolved_q"][0][1:] == [False, "user"];
}

test "approval: never lets a reply settle a permission card" {
    r = _gate();
    box = _async(r["gate"].ask, "audit_write", "Write the fixture receipt");
    def opened -> bool { return len(r["open"]) == 1; }
    _until(opened);
    rid = r["open"][0]["id"];
    assert r["gate"].answer(rid, "answer", "Yes, write it") == "unavailable";
    assert r["gate"].answer(rid, "allow", None) == "allowed-once";
    assert _value(box) is True;
}

# ═══ MCP session (chat-mcp-tools.test.ts) ══════════════════════════════════

glob SCHEMA: dict[str, any] = {"type": "object", "properties": {"value": {"type": "string"}}, "required": ["value"], "additionalProperties": False};

def mcp_fixture(body: str = "", tool_schema: any = None) -> dict[str, any] {
    d = _tmpdir("omb-chat-mcp-");
    script = os.path.join(d, "fake-mcp.mjs");
    receipt = os.path.join(d, "receipt.json");
    schema_json = json.dumps(tool_schema if tool_schema is not None else SCHEMA);
    lines = [
        "#!/usr/bin/env node",
        "import { writeFileSync } from \"node:fs\";",
        "import { spawn } from \"node:child_process\";",
        "const receipt = process.env.RECEIPT;",
        "const schema = " + schema_json + ";",
        "const calls = [];",
        "const send = (message) => process.stdout.write(JSON.stringify(message) + \"\\n\");",
        "const reply = (message, result) => send({jsonrpc:\"2.0\",id:message.id,result});",
        "let buffer = \"\";",
        "process.stdin.setEncoding(\"utf8\");",
        "process.stdin.on(\"data\", (chunk) => {",
        "  buffer += chunk;",
        "  let newline;",
        "  while ((newline = buffer.indexOf(\"\\n\")) !== -1) {",
        "    const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);",
        "    const message = JSON.parse(line);",
        "    calls.push(message);",
        "    writeFileSync(receipt, JSON.stringify({pid:process.pid,path:process.env.PATH,omb:Object.fromEntries(Object.entries(process.env).filter(([name]) => name.startsWith(\"OMB_\"))),calls}));",
        "    " + body,
        "    if (message.method === \"initialize\") reply(message, {protocolVersion:\"2024-11-05\",capabilities:{tools:{}}});",
        "    else if (message.method === \"tools/list\") reply(message, {tools:[{name:\"write\",description:\"Fixture write\",inputSchema:schema}]});",
        "    else if (message.method === \"tools/call\") reply(message, {content:[{type:\"text\",text:\"recorded:\" + message.params.arguments.value}]});",
        "  }",
        "});",
    ];
    with open(script, "w") as fh { fh.write("\n".join(lines) + "\n"); }
    os.chmod(script, 0o755);
    sig = new_signal();
    _fx["cleanups"].append(sig.abort);
    return {"dir": d, "script": script, "receipt": receipt, "signal": sig,
            "server": {"command": script, "args": [], "env": {"RECEIPT": receipt}}};
}

def mcp_read(f: dict[str, any]) -> dict[str, any] {
    with open(f["receipt"]) as fh { return json.loads(fh.read()); }
}

def mcp_mount(f: dict[str, any], computer_use: bool = False, local: bool = False, scope: any = None, integrations: any = None, timeout_ms: any = None) -> any {
    ints = integrations;
    if ints is None {
        ints = {"localComputer": f["server"]} if local else {"custom": {"audit": f["server"]}};
    }
    session = mount_chat_tools(ints, f["signal"], computer_use, scope, timeout_ms);
    _fx["cleanups"].append(session._close_quietly_session);
    return session;
}

def _calls_of(f: dict[str, any], method: str) -> list[any] {
    return [c for c in mcp_read(f)["calls"] if c["method"] == method];
}

test "mcp: starts no server when the owner selected no MCP tools" {
    f = mcp_fixture();
    session = mcp_mount(f, False, False, {"allow": ["native:ask_user"]});
    assert session.definitions == [];
    assert not os.path.exists(f["receipt"]);
    _cleanup();
}

test "mcp: filters original identities before catalog limits, alias conversion and schema compilation" {
    f = mcp_fixture("if (message.method === \"tools/list\") { reply(message, {tools:[ {name:\"read-notes\",inputSchema:schema}, {name:\"read_notes\",inputSchema:{$ref:\"https://example.invalid/private\"}}, ...Array.from({length:129}, (_,i) => ({name:\"excluded\"+i,inputSchema:{type:\"object\"},description:\"withheld-description\"})) ]}); return; }");
    session = mcp_mount(f, False, False, {"allow": ["mcp:audit:read-notes"]});
    assert session.definitions == [{"type": "function", "function": {"name": "audit_read_notes", "description": "Configured MCP tool", "parameters": SCHEMA}}];
    def blocked { session.execute("audit_read_notes_2", {"value": "blocked"}, f["signal"]); }
    _raises(blocked, "not advertised");
    assert _calls_of(f, "tools/call") == [];
    session.execute("audit_read_notes", {"value": "allowed"}, f["signal"]);
    assert [c["params"] for c in _calls_of(f, "tools/call")] == [{"name": "read-notes", "arguments": {"value": "allowed"}}];
    _cleanup();
}

test "mcp: rejects corrupt selection before starting any MCP process" {
    f = mcp_fixture();
    def bad { mcp_mount(f, False, False, {"allow": None}); }
    _raises(bad, "(?i)tool selection");
    assert not os.path.exists(f["receipt"]);
    _cleanup();
}

test "mcp: discovers without executing, preserves schemas and validates before forwarding original arguments" {
    f = mcp_fixture();
    session = mcp_mount(f);
    assert session.definitions == [{"type": "function", "function": {"name": "audit_write", "description": "Fixture write", "parameters": SCHEMA}}];
    assert _calls_of(f, "tools/call") == [];
    def bad_args { session.validate("audit_write", {"value": 42}); }
    _raises(bad_args, "input schema");
    def unknown { session.execute("not_registered", {}, f["signal"]); }
    _raises(unknown, "not advertised");
    assert _calls_of(f, "tools/call") == [];
    assert session.execute("audit_write", {"value": "receipt"}, f["signal"]) == {"text": "recorded:receipt", "ok": True};
    last = mcp_read(f)["calls"][-1];
    assert last["method"] == "tools/call" and last["params"] == {"name": "write", "arguments": {"value": "receipt"}};
    pid = mcp_read(f)["pid"];
    session.close();
    assert not _alive(pid);
    def again { session.execute("audit_write", {"value": "again"}, f["signal"]); }
    _raises(again, "closed");
    _cleanup();
}

test "mcp: drops a blank url for agent_browser_read only on the built-in browser" {
    for mount_as in ["browser", "custom"] {
        read_schema = {"type": "object", "properties": {"url": {"type": "string"}}, "additionalProperties": False};
        f = mcp_fixture("if (message.method === \"tools/list\") { reply(message, {tools:[{name:\"agent_browser_read\",description:\"Omit url to read the active tab.\",inputSchema:schema}]}); continue; }", read_schema);
        ints = {"browser": f["server"]} if mount_as == "browser" else {"custom": {"browser": f["server"]}};
        session = mcp_mount(f, True, False, None, ints);
        name = session.definitions[0]["function"]["name"];
        session.execute(name, {"url": " "}, f["signal"]);
        session.execute(name, {"url": "https://example.com"}, f["signal"]);
        got = [c["params"]["arguments"] for c in _calls_of(f, "tools/call")];
        first = {} if mount_as == "browser" else {"url": " "};
        assert got == [first, {"url": "https://example.com"}], got;
        _cleanup();
    }
}

test "mcp: starts servers with the widened PATH, and a PATH on the descriptor wins" {
    f = mcp_fixture();
    mcp_mount(f);
    assert mcp_read(f)["path"] == augmented_path(dict(os.environ));
    g = mcp_fixture();
    own_path = augmented_path(dict(os.environ)) + ":/opt/own-tools";
    g["server"]["env"]["PATH"] = own_path;
    mcp_mount(g);
    assert mcp_read(g)["path"] == own_path;
    _cleanup();
}

test "mcp: keeps the operator's control-plane secrets from a chat bot's tool servers, but not what the descriptor grants" {
    secrets = ["OMB_CLOUD_READY_TOKEN", "OMB_CLOUD_BOOTSTRAP", "OMB_LICENSE_KEY", "OMB_INSTALLATION_CREDENTIAL"];
    saved: dict[str, any] = {};
    for k in secrets + ["OMB_CLOUDFLARED_PATH"] { saved[k] = os.environ.get(k); }
    for k in secrets { os.environ[k] = "should-not-leak"; }
    os.environ["OMB_CLOUDFLARED_PATH"] = "/usr/local/bin/cloudflared";
    try {
        f = mcp_fixture();
        f["server"]["env"]["OMB_COMMS_TOKEN"] = "turn-capability";
        mcp_mount(f);
        seen = mcp_read(f)["omb"];
        assert seen["OMB_CLOUDFLARED_PATH"] == "/usr/local/bin/cloudflared" and seen["OMB_COMMS_TOKEN"] == "turn-capability";
        for k in secrets { assert k not in seen; }
    } finally {
        for (k, v) in saved.items() {
            if v is None { os.environ.pop(k, None); } else { os.environ[k] = v; }
        }
        _cleanup();
    }
}

test "mcp: mounts only supported descriptors and preserves conversations with no tools" {
    sig = new_signal();
    session = mount_chat_tools({"phone": {"command": "must-not-launch", "args": [], "env": {}}}, sig);
    assert session.definitions == [];
    session.close();
}

test "mcp: paginates deterministically and keeps colliding names within 64 characters" {
    long_name = "x" * 100;
    f = mcp_fixture("if (message.method === \"tools/list\") { reply(message, message.params.cursor ? {tools:[{name:" + json.dumps(long_name + "-second") + ",inputSchema:schema}]} : {tools:[{name:" + json.dumps(long_name) + ",inputSchema:schema}],nextCursor:\"second\"}); continue; }");
    session = mcp_mount(f);
    names = [d["function"]["name"] for d in session.definitions];
    assert len(set(names)) == 2 and all([len(n) <= 64 for n in names]) and names[1].endswith("_2"), names;
    assert len(_calls_of(f, "tools/list")) == 2;
    _cleanup();
}

test "mcp: fails startup and awaits child cleanup for every protocol violation" {
    cases = [
        "reply(message, {tools:[],nextCursor:\"same\"});",
        "reply(message, {tools:Array.from({length:129},(_,i)=>({name:\"tool\"+i,inputSchema:schema}))});",
        "reply(message, {tools:[{name:\"same\",inputSchema:schema},{name:\"same\",inputSchema:schema}]});",
        "process.stdout.write('{\"result\":1}\\n');",
        "process.stdout.write(\"x\".repeat(2*1024*1024+1));",
        "process.stdout.write(\"x\".repeat(2*1024*1024+1) + \"\\n\");",
        "process.stdout.write(\"\\n\".repeat(10001));",
        "reply(message, {tools:[{name:\"write\",inputSchema:schema,description:\"x\".repeat(1024*1024)}]});",
    ];
    for response in cases {
        f = mcp_fixture("if (message.method === \"tools/list\") { " + response + " continue; }");
        def mount_it { mcp_mount(f); }
        _raises(mount_it, "MCP");
        assert not _alive(mcp_read(f)["pid"]), response;
        _cleanup();
    }
}

test "mcp: rejects untrusted transport error text without leaking it" {
    f = mcp_fixture("if (message.method === \"tools/call\") { send({jsonrpc:\"2.0\",id:message.id,error:{code:-1,message:\"secret-fixture-key\"}}); continue; }");
    session = mcp_mount(f);
    outcome = "";
    try {
        session.execute("audit_write", {"value": "test"}, f["signal"]);
    } except ChatToolSessionError as e {
        outcome = str(e);
    }
    assert "MCP request failed" in outcome and "secret-fixture-key" not in outcome, outcome;
    assert not _alive(mcp_read(f)["pid"]);
    _cleanup();
}

test "mcp: rejects malformed tool content instead of accepting an empty successful result" {
    f = mcp_fixture("if (message.method === \"tools/call\") { reply(message,{content:[{type:\"text\",text:42}]}); continue; }");
    session = mcp_mount(f);
    outcome = "";
    try {
        session.execute("audit_write", {"value": "test"}, f["signal"]);
    } except ChatToolSessionError as e {
        outcome = str(e);
    }
    assert "invalid content" in outcome, outcome;
    assert not _alive(mcp_read(f)["pid"]);
    closed = False;
    try {
        session.validate("audit_write", {"value": "test"});
    } except ChatToolSessionError {
        closed = True;
    }
    assert closed;
    _cleanup();
}

test "mcp: keeps schema errors recoverable without dispatching or closing the transport" {
    f = mcp_fixture();
    session = mcp_mount(f);
    kind = "none";
    try {
        session.execute("audit_write", {"value": 42}, f["signal"]);
    } except ChatToolSessionError {
        kind = "session";
    } except Exception {
        kind = "recoverable";
    }
    assert kind == "recoverable";
    assert _calls_of(f, "tools/call") == [];
    assert session.execute("audit_write", {"value": "valid"}, f["signal"])["ok"] is True;
    _cleanup();
}

test "mcp: returns ordinary MCP tool errors while keeping the session available" {
    f = mcp_fixture("if(message.method === \"tools/call\" && message.params.arguments.value === \"fail\") { reply(message,{isError:true,content:[{type:\"text\",text:\"fixture operation refused\"}]}); continue; }");
    session = mcp_mount(f);
    assert session.execute("audit_write", {"value": "fail"}, f["signal"]) == {"ok": False, "text": "fixture operation refused"};
    assert session.execute("audit_write", {"value": "valid"}, f["signal"])["ok"] is True;
    _cleanup();
}

test "mcp: does not claim success for an unsupported result" {
    for has_text in [False, True] {
        part = "{type:\"text\",text:\"partial result\"}," if has_text else "";
        f = mcp_fixture("if(message.method === \"tools/call\") { reply(message,{content:[" + part + "{type:\"image\",data:\"fixture\",mimeType:\"image/png\"}]}); continue; }");
        session = mcp_mount(f);
        result = session.execute("audit_write", {"value": "valid"}, f["signal"]);
        assert result["ok"] is False and "unsupported MCP content" in result["text"] and "inspect its state before retrying" in result["text"];
        if has_text { assert "partial result" in result["text"]; }
        _cleanup();
    }
}

test "mcp: closes already mounted peers when another server fails startup" {
    ready = mcp_fixture();
    failed = mcp_fixture("if(message.method === \"tools/list\") { reply(message,{tools:\"invalid\"}); continue; }");
    def mount_both { mount_chat_tools({"custom": {"ready": ready["server"], "failed": failed["server"]}}, ready["signal"]); }
    _raises(mount_both, "invalid result");
    assert not _alive(mcp_read(ready)["pid"]) and not _alive(mcp_read(failed)["pid"]);
    _cleanup();
}

test "mcp: returns declared tool errors and bounds aggregate text without splitting UTF-8" {
    f = mcp_fixture("if (message.method === \"tools/call\") { reply(message,{isError:true,content:[{type:\"text\",text:\"á\".repeat(30000)},{type:\"image\",data:\"ignored\",mimeType:\"image/png\"}],structuredContent:{status:\"failed\"}}); continue; }");
    session = mcp_mount(f);
    result = session.execute("audit_write", {"value": "test"}, f["signal"]);
    assert result["ok"] is False and len(result["text"].encode("utf-8")) < 52000;
    assert "truncated" in result["text"] and "\ufffd" not in result["text"];
    _cleanup();
}

test "mcp: cancels initialize, tools/list and tools/call and awaits its owned process tree" {
    for method in ["initialize", "tools/list", "tools/call"] {
        f = mcp_fixture("if (message.method === " + json.dumps(method) + ") { const helper = spawn(process.execPath,[\"-e\",\"setInterval(()=>{},1000)\"],{stdio:\"ignore\"}); helper.on(\"spawn\",()=>writeFileSync(receipt,JSON.stringify({pid:process.pid,helper:helper.pid,calls}))); continue; }");
        def run_it -> any {
            try {
                session = mcp_mount(f);
                if method == "tools/call" { session.execute("audit_write", {"value": "test"}, f["signal"]); }
                return "resolved";
            } except Exception as e {
                return str(e);
            }
        }
        box = _async(run_it);
        # Capture the pids when the helper first appears: the fixture rewrites
        # its receipt on every later message (the cancel notification
        # included), without the helper field.
        seen: dict[str, any] = {};
        def helper_up -> bool {
            try {
                r = mcp_read(f);
            } except Exception {
                return False;
            }
            if r.get("helper", 0) > 0 {
                seen.update({"pid": r["pid"], "helper": r["helper"]});
                return True;
            }
            return False;
        }
        _until(helper_up);
        f["signal"].abort();
        outcome = _value(box);
        assert re.search("cancelled|closed", outcome) is not None, outcome;
        assert not _alive(seen["pid"]) and not _alive(seen["helper"]), method;
        _cleanup();
    }
}

test "mcp: honors the configured per-call timeout instead of the fixed default" {
    delayed = "if (message.method === \"tools/call\") { setTimeout(() => reply(message, {content:[{type:\"text\",text:\"recorded:\"+message.params.arguments.value}]}), 400); return; }";
    f = mcp_fixture(delayed);
    short = mcp_mount(f, False, False, None, None, 100);
    def slow { short.execute("audit_write", {"value": "x"}, f["signal"]); }
    _raises(slow, "MCP request timed out");
    assert len(_calls_of(f, "tools/call")) == 1;
    generous = mcp_mount(f, False, False, None, None, 5000);
    out = generous.execute("audit_write", {"value": "y"}, f["signal"]);
    assert out["ok"] is True and out["text"] == "recorded:y";
    _cleanup();
}

# ═══ schema validation (chat-mcp-tools.test.ts) ════════════════════════════

test "schema: retains native unsigned/composition constraints while exposing an object schema" {
    f = mcp_fixture("", {"type": "object", "properties": {"value": {"type": "integer", "format": "uint32"}}, "anyOf": [{"required": ["value"]}], "additionalProperties": False});
    session = mcp_mount(f, True);
    assert "anyOf" not in session.definitions[0]["function"]["parameters"];
    assert "\"anyOf\"" in session.definitions[0]["function"]["description"];
    for bad in [{}, {"value": -1}, {"value": 4294967296}] {
        def v { session.validate("audit_write", bad); }
        _raises(v, "input schema");
    }
    session.validate("audit_write", {"value": 42});
    _cleanup();
}

test "schema: carries large images from custom and built-in servers" {
    png = base64.b64decode(PNG_B64);
    size = 2 * 1024 * 1024 + 12;
    payload = b"tEXt" + b"fixture\x00" + (b"\x00" * (size - 20));
    piece = (size - 12).to_bytes(4, "big") + payload + zlib.crc32(payload).to_bytes(4, "big");
    data = base64.b64encode(png[0:len(png) - 12] + piece + png[len(png) - 12:]).decode("ascii");
    for local in [False, True] {
        f = mcp_fixture("if(message.method === \"tools/call\") { reply(message,{content:[{type:\"image\",mimeType:\"image/png\",data:readFileSync(process.env.IMAGE_FILE,\"utf8\")}]}); continue; }");
        with open(f["script"]) as fh { src = fh.read(); }
        with open(f["script"], "w") as fh { fh.write(src.replace("import { writeFileSync }", "import { writeFileSync, readFileSync }")); }
        f["server"]["env"]["IMAGE_FILE"] = os.path.join(f["dir"], "image.txt");
        with open(f["server"]["env"]["IMAGE_FILE"], "w") as fh { fh.write(data); }
        session = mcp_mount(f, True, local);
        result = session.execute("computer_write" if local else "audit_write", {"value": "screenshot"}, f["signal"]);
        assert result == {"ok": True, "text": "Screenshot captured.", "images": [{"type": "image_url", "image_url": {"url": "data:image/png;base64," + data}}]};
        _cleanup();
    }
}

test "schema: keeps a bounded frame limit for image-enabled custom servers" {
    f = mcp_fixture("if(message.method === \"tools/call\") { process.stdout.write(\"x\".repeat(32*1024*1024+1)); continue; }");
    session = mcp_mount(f, True);
    def big { session.execute("audit_write", {"value": "large"}, f["signal"]); }
    _raises(big, "(?i)frame|limit");
    _cleanup();
}

test "schema: rejects malformed image results without claiming execution success" {
    f = mcp_fixture("if(message.method === \"tools/call\") { reply(message,{content:[{type:\"image\",mimeType:\"image/png\",data:\"not-base64\"}]}); continue; }");
    session = mcp_mount(f, True);
    def bad { session.execute("audit_write", {"value": "screenshot"}, f["signal"]); }
    _raises(bad, "Invalid or oversized MCP image");
    _cleanup();
}

test "schema: enforces original constraints without defaults or coercion" {
    cases = [
        [{"type": "object", "properties": {"value": {"type": "string", "minLength": 2}}, "required": ["value"]}, {"value": "😀"}],
        [{"type": "object", "properties": {"value": {"type": "string", "enum": ["a"], "minLength": 2}}, "required": ["value"]}, {"value": "a"}],
        [{"type": "object", "properties": {"value": {"type": "array", "minItems": 2}}, "required": ["value"]}, {"value": []}],
        [{"type": "object", "properties": {"value": {"type": "string", "default": "fallback"}}, "required": ["value"]}, {}],
        [{"type": "object", "required": ["value"]}, {}],
        [{"type": "object", "properties": {"value": {"type": "array", "items": {"type": "string"}, "uniqueItems": True}}, "required": ["value"]}, {"value": ["a", "a"]}],
    ];
    for c in cases {
        f = mcp_fixture("", c[0]);
        session = mcp_mount(f);
        def v { session.validate("audit_write", c[1]); }
        _raises(v, "input schema");
        assert _calls_of(f, "tools/call") == [];
        assert session.definitions[0]["function"]["parameters"] == c[0];
        _cleanup();
    }
}

test "schema: retains composition and draft 2020-12 constraints" {
    f = mcp_fixture("", {"$schema": "https://json-schema.org/draft/2020-12/schema", "type": "object",
        "properties": {"value": {"type": "array", "items": {"type": "number"}, "contains": {"const": 2}, "minContains": 1}},
        "required": ["value"], "additionalProperties": False});
    session = mcp_mount(f);
    def v { session.validate("audit_write", {"value": [1]}); }
    _raises(v, "input schema");
    session.validate("audit_write", {"value": [2]});
    _cleanup();
}

test "schema: enforces the standard email, uri and date-time formats" {
    for c in [["email", "user@example.com", "invalid"], ["uri", "https://example.com/path", "not a uri"], ["date-time", "2026-09-13T12:00:00Z", "2026-13-41"]] {
        f = mcp_fixture("", {"type": "object", "properties": {"value": {"type": "string", "format": c[0]}}, "required": ["value"]});
        session = mcp_mount(f);
        session.validate("audit_write", {"value": c[1]});
        def v { session.validate("audit_write", {"value": c[2]}); }
        _raises(v, "input schema");
        _cleanup();
    }
}

test "schema: refuses schemas it cannot validate instead of silently weakening them" {
    for s in [
        {"type": "object", "properties": {"value": {"type": "string", "format": "unregistered-format"}}},
        {"type": "object", "properties": {"value": {"$ref": "https://example.invalid/private-schema"}}},
        {"type": "object", "properties": {"value": {"type": "string", "unrecognizedAssertion": True}}},
    ] {
        f = mcp_fixture("", s);
        def m { mcp_mount(f); }
        _raises(m, "schema could not be validated");
        assert not _alive(mcp_read(f)["pid"]);
        _cleanup();
    }
}

# ═══ runtime (openai-chat.test.ts) ═════════════════════════════════════════

def _data_dir {
    # Native logs and handoffs land in a throwaway data dir, never the
    # operator's ~/.openmausbot.
    if not os.environ.get("OMB_CHAT_TEST_DATA") {
        d = tempfile.mkdtemp(prefix="omb-chat-data-");
        os.environ["OMB_CHAT_TEST_DATA"] = d;
        os.environ["OMB_DATA_DIR"] = d;
    }
}

def _json_script(value: any) -> any {
    def script(body: any, w: dict[str, any], n: int) { w["json"](200, value); }
    return script;
}

def _gen(iid: str) -> dict[str, any] {
    return driver_generate_text(omb_token=None, instance_id=iid, prompt="summarize", options={});
}

glob HELPER_CHOICES: list[any] = [{"message": {"content": "helper result"}, "finish_reason": "stop"}];

test "runtime: reports the actual helper model and known provider usage once, preserving the text result" {
    srv = _start_provider(_json_script({"model": "grok-3-mini-actual", "choices": HELPER_CHOICES,
        "usage": {"prompt_tokens": 120, "completion_tokens": 20, "prompt_tokens_details": {"cached_tokens": 100}, "cost": 0.004}}));
    iid = compat(srv["origin"] + "/v1");
    out = _gen(iid);
    assert out["ok"] and out["text"] == "helper result" and "failure" not in out;
    assert srv["requests"][0]["model"] == "m" and srv["requests"][0]["stream"] is False and "stream_options" not in srv["requests"][0];
    assert out["usage"] == {"model": "grok-3-mini-actual", "input": 120, "output": 20, "cachedInput": 100, "costUsd": 0.004};
    _cleanup();
}

test "runtime: preserves unknown usage and explicit zeroes" {
    cases = [
        [None, {"model": "m"}],
        [{"prompt_tokens": "12", "completion_tokens": -1, "cost": None}, {"model": "m"}],
        [{"prompt_tokens": 0, "completion_tokens": 0, "prompt_tokens_details": {"cached_tokens": 0}, "cost": 0}, {"model": "m", "input": 0, "output": 0, "cachedInput": 0, "costUsd": 0}],
    ];
    for c in cases {
        payload: dict[str, any] = {"choices": HELPER_CHOICES};
        if c[0] is not None { payload["usage"] = c[0]; }
        srv = _start_provider(_json_script(payload));
        out = _gen(compat(srv["origin"] + "/v1"));
        assert out["usage"] == c[1], out;
        _cleanup();
    }
}

test "runtime: reports billed usage before rejecting unusable helper output" {
    bodies = [
        {"choices": [{"message": {"content": None, "tool_calls": [{"id": "call-1", "type": "function", "function": {"name": "unexpected", "arguments": "{}"}}]}, "finish_reason": "tool_calls"}]},
        {"choices": []},
        {"error": {"message": "synthetic provider failure"}},
    ];
    for b in bodies {
        payload = dict(b);
        payload["usage"] = {"prompt_tokens": 10, "completion_tokens": 5};
        srv = _start_provider(_json_script(payload));
        out = _gen(compat(srv["origin"] + "/v1"));
        assert isinstance(out.get("failure"), str) and "text" not in out;
        assert out["usage"] == {"model": "m", "input": 10, "output": 5};
        _cleanup();
    }
}

test "runtime: does not invent usage for malformed JSON" {
    def script(body: any, w: dict[str, any], n: int) { w["raw"](200, "not JSON", "application/json"); }
    srv = _start_provider(script);
    out = _gen(compat(srv["origin"] + "/v1"));
    assert isinstance(out.get("failure"), str) and "usage" not in out;
    _cleanup();
}

test "runtime: scopes schemas and blocks a remembered native question even under Full access" {
    f = fixture_late();
    receipt = os.path.join(f["dir"], "calls.txt");
    first_calls = [
        {"index": 0, "id": "selected", "type": "function", "function": {"name": "fx_write", "arguments": "{}"}},
        {"index": 1, "id": "withheld", "type": "function", "function": {"name": "ask_user", "arguments": json.dumps({"questions": [{"question": "Must not be shown"}]})}},
    ];
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 {
            w["sse"]([{"choices": [{"index": 0, "delta": {"tool_calls": first_calls}}]}, chunk({}, "tool_calls")]);
        } else {
            w["sse"]([chunk({"content": "Finished."}), chunk({}, "stop")]);
        }
    }
    f["srv"]["script"] = script;
    server = _receipt_server(f["dir"], receipt);
    start(f, {"text": "Use only the selected tool.", "approvalMode": "full", "toolScope": {"allow": ["mcp:fx:write"]}, "integrations": {"custom": {"fx": server}}});
    done = _completed(f["iid"]);
    assert tools_of(f["requests"][0]) == ["fx_write"];
    assert _all(f["iid"], "request.opened") == [];
    with open(receipt) as fh { assert fh.read() == "write\n"; }
    withheld = [m for m in f["requests"][1]["messages"] if m["role"] == "tool" and m["tool_call_id"] == "withheld"][0];
    assert json.loads(withheld["content"])["ok"] is False and re.search("(?i)tool selection excludes", withheld["content"]) is not None;
    assert _events(f["iid"])[-1]["type"] == "turn.completed" and done["ok"] is False;
    _cleanup();
}

def _noop_script(body: any, w: dict[str, any], n: int) { answer(w); }

def _receipt_server(d: str, receipt: str) -> dict[str, any] {
    path = os.path.join(d, "fx-mcp.mjs");
    src = "\n".join([
        "import { appendFileSync } from \"node:fs\";",
        "const send = (m) => process.stdout.write(JSON.stringify(m) + \"\\n\");",
        "let buffer = \"\";",
        "process.stdin.setEncoding(\"utf8\");",
        "process.stdin.on(\"data\", (chunk) => {",
        "  buffer += chunk; let nl;",
        "  while ((nl = buffer.indexOf(\"\\n\")) !== -1) {",
        "    const line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1);",
        "    const m = JSON.parse(line);",
        "    if (m.method === \"initialize\") send({jsonrpc:\"2.0\",id:m.id,result:{protocolVersion:\"2024-11-05\",capabilities:{tools:{}}}});",
        "    else if (m.method === \"tools/list\") send({jsonrpc:\"2.0\",id:m.id,result:{tools:[{name:\"write\",description:\"Fixture write\",inputSchema:{type:\"object\",properties:{},additionalProperties:false}}]}});",
        "    else if (m.method === \"tools/call\") {",
        "      if (process.env.RECEIPT) appendFileSync(process.env.RECEIPT, m.params.name + \"\\n\");",
        "      if (process.env.FAIL) send({jsonrpc:\"2.0\",id:m.id,result:{isError:true,content:[{type:\"text\",text:\"boom\"}]}});",
        "      else send({jsonrpc:\"2.0\",id:m.id,result:{content:[{type:\"text\",text:\"done\"}]}});",
        "    }",
        "  }",
        "});",
    ]);
    with open(path, "w") as fh { fh.write(src + "\n"); }
    env: dict[str, any] = {};
    if receipt { env["RECEIPT"] = receipt; }
    return {"command": _node(), "args": [path], "env": env};
}

def fixture_late() -> dict[str, any] {
    holder: dict[str, any] = {};
    def run(body: any, w: dict[str, any], n: int) { holder["f"]["srv"]["script"](body, w, n); }
    f = fixture(run);
    holder["f"] = f;
    f["srv"]["script"] = _noop_script;
    return f;
}

def _card_raised_for(mode: str) -> bool {
    def script(body: any, w: dict[str, any], n: int) {
        w["sse"]([{"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "c1", "type": "function", "function": {"name": "fx_write", "arguments": "{}"}}]}}]}, chunk({}, "tool_calls")]);
    }
    f = fixture(script);
    start(f, {"text": "hi", "approvalMode": mode, "integrations": {"custom": {"fx": _receipt_server(f["dir"], "")}}, "model": None});
    def seen -> any {
        for ev in _events(f["iid"]) {
            if ev["type"] in ["request.opened", "item.started", "turn.completed"] { return True; }
        }
        return False;
    }
    _until(seen);
    opened = _find(f["iid"], "request.opened") is not None;
    driver_interrupt_turn(omb_token=None, instance_id=f["iid"], thread_id=f["thread"], turn_id=None);
    _cleanup();
    return opened;
}

test "runtime: holds a card for every tool call when the bot is on Ask" {
    assert _card_raised_for("ask") is True;
}

test "runtime: answers for the person under Full access, so no card is raised" {
    assert _card_raised_for("full") is False;
}

test "runtime: still holds an ask_user card under Full access and returns the reply verbatim" {
    ask_args = json.dumps({"questions": [{"question": "Ship the fixture?", "options": [{"label": "Yes"}, {"label": "No"}]}]});
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 {
            w["sse"]([{"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "ask1", "type": "function", "function": {"name": "ask_user", "arguments": ask_args}}]}}]}, chunk({}, "tool_calls")]);
        } else {
            w["sse"]([chunk({"content": "Shipped."}), chunk({}, "stop")]);
        }
    }
    f = fixture(script);
    start(f, {"text": "hi", "approvalMode": "full", "integrations": None});
    opened = _opened(f["iid"]);
    assert opened["requestType"] == "question" and opened["tool"] == "ask_user" and opened["summary"] == "Ship the fixture?";
    assert opened["questions"] == [{"question": "Ship the fixture?", "options": [{"label": "Yes"}, {"label": "No"}]}];
    assert opened["choices"] == ["Yes", "No"];
    assert "ask_user" in tools_of(f["requests"][0]);
    reply = "The user answered your questions.\n\nQ: Ship the fixture?\nA: Yes";
    assert respond_card(f, opened["requestId"], "answer", reply) == "answered";
    done = _completed(f["iid"]);
    assert len(_all(f["iid"], "request.opened")) == 1;
    resolved = _all(f["iid"], "request.resolved");
    assert len(resolved) == 1 and resolved[0]["behavior"] == "answer" and resolved[0]["source"] == "user";
    tool_message = f["requests"][1]["messages"][-1];
    assert tool_message["role"] == "tool" and tool_message["tool_call_id"] == "ask1";
    assert json.loads(tool_message["content"]) == {"ok": True, "result": reply};
    assert done["ok"] is True;
    _cleanup();
}

test "runtime: ends the turn on a failed tool call, never asks to run it again, and does not continue it by itself" {
    _data_dir();
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 {
            w["sse"]([{"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "c1", "type": "function", "function": {"name": "fx_write", "arguments": "{}"}}]}}]}, chunk({}, "tool_calls")]);
        } else {
            w["sse"]([chunk({"content": "Done after failure."}), chunk({}, "stop")]);
        }
    }
    f = fixture(script);
    server = _receipt_server(f["dir"], "");
    server["env"]["FAIL"] = "1";
    start(f, {"text": "Use the tool, then answer.", "approvalMode": "full", "integrations": {"custom": {"fx": server}}});
    done = _completed(f["iid"]);
    assert len(f["requests"]) == 2;
    for req in f["requests"] {
        for m in req["messages"] {
            assert not (m["role"] == "user" and re.search("(?i)re-run the failed", str(m["content"])));
        }
    }
    assert done["ok"] is False and done["stopReason"] == "tool_error";
    assert any([re.search("One or more tool operations failed", e.get("message") or "") is not None for e in _all(f["iid"], "runtime.error")]);
    assert _all(f["iid"], "cap.exhausted") == [];
    _cleanup();
}

test "runtime: refuses steer with no running turn" {
    srv = _start_provider(_noop_script);
    iid = compat(srv["origin"] + "/v1");
    assert driver_steer(omb_token=None, instance_id=iid, thread_id="thread", text="peer context")["outcome"] == "refused";
    _cleanup();
}

test "runtime: delivers mid-turn asides into the next completion request after the tool round" {
    gate = threading.Event();
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 {
            gate.wait(10);
            w["sse"]([{"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "c1", "type": "function", "function": {"name": "fx_write", "arguments": "{}"}}]}}]}, chunk({}, "tool_calls")]);
        } else {
            w["sse"]([chunk({"content": "done."}), chunk({}, "stop")]);
        }
    }
    f = fixture(script);
    f["thread"] = "t";
    start(f, {"text": "hi", "approvalMode": "full", "integrations": {"custom": {"fx": _receipt_server(f["dir"], "")}}});
    def sent -> bool { return len(f["requests"]) >= 1; }
    _until(sent);
    aside = "[aside from @Peer — peer context, not steering]\nheads up\n[end aside]";
    assert driver_steer(omb_token=None, instance_id=f["iid"], thread_id="t", text=aside)["outcome"] == "steered";
    assert driver_steer(omb_token=None, instance_id=f["iid"], thread_id="t", text="second aside")["outcome"] == "steered";
    gate.set();
    done = _completed(f["iid"]);
    first = f["requests"][0]["messages"];
    second = f["requests"][1]["messages"];
    assert not any([isinstance(m["content"], str) and "aside from @Peer" in m["content"] for m in first]);
    roles = [m["role"] for m in second];
    tool_index = len(roles) - 1 - roles[::-1].index("tool");
    aside_index = [i for i in range(len(second)) if second[i]["role"] == "user" and isinstance(second[i]["content"], str) and "aside from @Peer" in second[i]["content"]][0];
    assert aside_index == len(second) - 1 and aside_index > tool_index;
    assert "[end aside]\n\nsecond aside" in second[aside_index]["content"];
    assert done["ok"] is True;
    assert driver_steer(omb_token=None, instance_id=f["iid"], thread_id="t", text="late")["outcome"] == "refused";
    _cleanup();
}

def _item_text(events: list[any]) -> any {
    for ev in events {
        if ev["type"] == "item.completed" { return ev.get("text"); }
    }
    return None;
}

def _no_error(events: list[any]) -> bool {
    return not any([ev["type"] == "runtime.error" for ev in events]);
}

test "runtime: treats EOF after a finish_reason chunk as a clean completion when [DONE] never arrives" {
    events = run_turn(body_of("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"<think>\\nuser said hi\\n</think>Hello!\"}}]}\n\n" + "data: {\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"delta\":{\"content\":\" How can I help?\"}}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":9}}\n\n"));
    assert _item_text(events) == "<think>\nuser said hi\n</think>Hello! How can I help?";
    assert _no_error(events);
    assert events[-1]["type"] == "turn.completed" and events[-1]["ok"] is True and events[-1]["usage"] == {"input": 5, "output": 9};
    _cleanup();
}

test "runtime: parses a final finish_reason+usage frame with no trailing newline before the socket closes" {
    events = run_turn(body_of("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}]}\n\n" + "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":9}}"));
    assert _item_text(events) == "Hello" and _no_error(events);
    assert events[-1]["ok"] is True and events[-1]["usage"] == {"input": 5, "output": 9};
    _cleanup();
}

test "runtime: splits a final unterminated frame across two stream chunks" {
    def script(body: any, w: dict[str, any], n: int) {
        h_write = w["raw"];
        h_write(200, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}]}\n\n" + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"comple");
        time.sleep(0.2);
        w["more"]("tion_tokens\":9}}");
    }
    events = run_turn(script);
    assert _item_text(events) == "Hello" and _no_error(events);
    assert events[-1]["ok"] is True and events[-1]["usage"] == {"input": 5, "output": 9};
    _cleanup();
}

test "runtime: does not misfire on an empty final flush when the stream ends cleanly on a newline" {
    events = run_turn(body_of("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}]}\n\n" + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n"));
    assert _item_text(events) == "hi" and _no_error(events);
    assert events[-1]["ok"] is True and events[-1]["usage"] == {"input": 1, "output": 1};
    _cleanup();
}

test "runtime: settles a turn whose stream was cut mid-frame instead of failing it" {
    events = run_turn(body_of("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"},\"finish_reason\":\"stop\"}]}\n\n" + "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\" wor"));
    assert _item_text(events) == "Hello" and _no_error(events) and events[-1]["ok"] is True;
    _cleanup();
}

test "runtime: still honors data: [DONE]" {
    events = run_turn(body_of("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n"));
    assert _item_text(events) == "hi" and events[-1]["ok"] is True;
    _cleanup();
}

test "runtime: surfaces an HTTP 200 whose body is a MiniMax base_resp error instead of finishing silently" {
    events = run_turn(body_of("{\"base_resp\":{\"status_code\":1008,\"status_msg\":\"insufficient balance\"}}"));
    errs = [e for e in events if e["type"] == "runtime.error"];
    assert errs[0]["message"] == "provider returned a completion error: upstream error 1008: insufficient balance";
    assert events[-1]["ok"] is False and events[-1]["stopReason"] == "error";
    _cleanup();
}

test "runtime: surfaces an OpenAI-style error object returned with HTTP 200" {
    events = run_turn(body_of("{\"error\":{\"message\":\"token is unusable (1004)\",\"type\":\"authorized_error\"}}"));
    errs = [e for e in events if e["type"] == "runtime.error"];
    assert errs[0]["message"] == "provider returned a completion error: token is unusable (1004)";
    _cleanup();
}

test "runtime: reports a stream truncated before finish_reason as an error, not an interrupt" {
    events = run_turn(body_of("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}\n\n"));
    errs = [e for e in events if e["type"] == "runtime.error"];
    assert errs[0]["message"] == "Stream ended before completion";
    assert events[-1]["ok"] is False and events[-1]["stopReason"] == "error";
    _cleanup();
}

test "runtime: streams reasoning before the answer on a [DONE]-less reasoning stream" {
    events = run_turn(body_of("data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"user said hi\"}}]}\n\n" + "data: {\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"delta\":{\"content\":\"Hello!\"}}]}\n\n" + "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":9}}\n\n"));
    assert [e["streamKind"] for e in events if e["type"] == "content.delta"] == ["reasoning_text", "assistant_text"];
    assert _item_text(events) == "Hello!";
    assert events[-1]["ok"] is True and events[-1]["usage"] == {"input": 5, "output": 9};
    _cleanup();
}

glob REFUSAL: dict[str, any] = {
    "message": "Tool call validation failed: tool call validation failed: attempted to call tool 'JSON' which was not in request",
    "type": "invalid_request_error",
    "code": "tool_use_failed",
    "failed_generation": "{\"name\":\"JSON\",\"arguments\":{\"restam\":7}}",
};

def _refused_stream(w: dict[str, any]) {
    w["raw"](200, "data: " + json.dumps({"choices": [{"index": 0, "delta": {"reasoning": "They want JSON."}}]}) + "\n\n" + "data: " + json.dumps({"error": REFUSAL}) + "\n\n");
}

def _refusal_answer(w: dict[str, any]) {
    w["raw"](200, "data: {\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"delta\":{\"content\":\"{\\\"restam\\\":7}\"}}]}\n\ndata: [DONE]\n\n");
}

test "runtime: sends the request again when the provider refuses a made-up tool call (mid-stream and as HTTP 400)" {
    for mode in ["stream", "http"] {
        def script(body: any, w: dict[str, any], n: int) {
            if n == 1 {
                if mode == "stream" { _refused_stream(w); } else { w["json"](400, {"error": REFUSAL}); }
            } else {
                _refusal_answer(w);
            }
        }
        srv = _start_provider(script);
        iid = compat(srv["origin"] + "/v1");
        driver_send_turn(omb_token=None, instance_id=iid, turn={"threadId": "thread", "text": "hi"});
        _completed(iid);
        events = _events(iid);
        assert len(srv["requests"]) == 2;
        retry = _find(iid, "turn.retrying");
        assert retry["attempt"] == 1 and retry["delayMs"] == 0 and retry["reason"] == "tool_use_failed";
        assert _no_error(events) and _item_text(events) == "{\"restam\":7}" and events[-1]["ok"] is True;
        _cleanup();
    }
}

test "runtime: stops after three refusals, says what happened and what to do, and logs each refusal whole" {
    _data_dir();
    log = os.path.join(native_dir(), "thread.ndjson");
    if os.path.exists(log) { os.remove(log); }
    def script(body: any, w: dict[str, any], n: int) { _refused_stream(w); }
    srv = _start_provider(script);
    iid = compat(srv["origin"] + "/v1");
    driver_send_turn(omb_token=None, instance_id=iid, turn={"threadId": "thread", "text": "hi"});
    done = _completed(iid);
    assert len(srv["requests"]) == 3;
    assert [e["attempt"] for e in _all(iid, "turn.retrying")] == [1, 2];
    assert _find(iid, "runtime.error")["message"] == "The model tried to use a tool it was not given (\"JSON\"). Nothing ran. Retry; if it keeps happening, rephrase the request or choose another model. Provider: " + REFUSAL["message"];
    assert done["ok"] is False and done["stopReason"] == "error";
    with open(log) as fh { entries = [json.loads(l) for l in fh.read().strip().split("\n")]; }
    refusals = [e["msg"] for e in entries if isinstance(e.get("msg"), dict) and e["msg"].get("refused")];
    assert refusals == [{"refused": "tool_use_failed", "attempt": a, "error": REFUSAL} for a in [1, 2, 3]], refusals;
    _cleanup();
}

test "runtime: does not claim a tool was made up when the provider rejected its arguments" {
    invalid = dict(REFUSAL);
    invalid["message"] = "Tool call validation failed: parameters for tool ask_user did not match schema: errors: [missing properties: 'questions']";
    events = run_turn(body_of("data: " + json.dumps({"error": invalid}) + "\n\n"));
    assert [e for e in events if e["type"] == "runtime.error"][0]["message"] == "The model made a tool call the provider rejected. Nothing ran. Retry; if it keeps happening, rephrase the request or choose another model. Provider: " + invalid["message"];
    _cleanup();
}

test "runtime: does not resend once answer text has streamed, so attempts never join in one reply" {
    counter: dict[str, int] = {"n": 0};
    def script(body: any, w: dict[str, any], n: int) {
        counter["n"] += 1;
        w["raw"](200, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Sobram\"}}]}\n\n" + "data: " + json.dumps({"error": REFUSAL}) + "\n\n");
    }
    events = run_turn(script);
    assert counter["n"] == 1;
    assert not any([e["type"] == "turn.retrying" for e in events]);
    assert [e for e in events if e["type"] == "runtime.error"][0]["message"].startswith("The model tried to use a tool it was not given (\"JSON\")");
    _cleanup();
}

test "runtime: does not resend other provider errors" {
    other = dict(REFUSAL);
    other["code"] = "invalid_request_error";
    counter: dict[str, int] = {"n": 0};
    def script(body: any, w: dict[str, any], n: int) {
        counter["n"] += 1;
        w["raw"](200, "data: " + json.dumps({"error": other}) + "\n\n");
    }
    events = run_turn(script);
    assert counter["n"] == 1 and not any([e["type"] == "turn.retrying" for e in events]) and events[-1]["ok"] is False;
    _cleanup();
}

def _verdicts() -> list[any] {
    return [c["payload"] for c in _fx["calls"] if c["op"] == "key_verdict"];
}

test "runtime: a 401 reports the key rejected by fingerprint; a later success reports it accepted" {
    _fx["calls"].clear();
    mode: dict[str, str] = {"m": "reject"};
    def script(body: any, w: dict[str, any], n: int) {
        if mode["m"] == "reject" {
            w["json"](401, {"error": {"message": "Incorrect API key provided", "code": "invalid_api_key"}});
        } else {
            w["sse"]([{"choices": [{"delta": {"content": "ok"}, "finish_reason": "stop"}]}]);
        }
    }
    srv = _start_provider(script);
    iid = compat(srv["origin"] + "/v1", {}, {"K": "fixture-revoked-key"});
    driver_send_turn(omb_token=None, instance_id=iid, turn={"threadId": "thread", "text": "hi"});
    _completed(iid);
    assert "HTTP 401" in _find(iid, "runtime.error")["message"];
    rejected = [v for v in _verdicts() if v["rejected"] is True];
    assert len(rejected) == 1 and rejected[0]["url"] == srv["origin"] + "/v1" and rejected[0]["fingerprint"] == key_fingerprint("fixture-revoked-key");
    assert "fixture-revoked-key" not in json.dumps(_fx["calls"]);
    _fx["events"][iid] = [];
    mode["m"] = "accept";
    driver_send_turn(omb_token=None, instance_id=iid, turn={"threadId": "thread", "text": "hi"});
    _completed(iid);
    assert _verdicts()[-1]["rejected"] is False;
    _cleanup();
}

test "runtime: rate limits, quota and model access leave the key Ready" {
    for c in [
        [429, {"error": {"message": "Rate limit reached", "code": "rate_limit_exceeded"}}],
        [429, {"error": {"message": "You exceeded your current quota", "code": "insufficient_quota"}}],
        [403, {"error": {"message": "You do not have access to this model"}}],
    ] {
        _fx["calls"].clear();
        def script(body: any, w: dict[str, any], n: int) { w["json"](c[0], c[1]); }
        srv = _start_provider(script);
        iid = compat(srv["origin"] + "/v1");
        driver_send_turn(omb_token=None, instance_id=iid, turn={"threadId": "thread", "text": "hi"});
        _completed(iid);
        assert not any([v["rejected"] for v in _verdicts()]);
        _cleanup();
    }
}

# ═══ tools (openai-chat-tools.test.ts) ═════════════════════════════════════

glob UNSUPPORTED: dict[str, any] = {"error": {"message": "This model does not support tools."}};

def _status_script(status: any, err: any) -> any {
    def script(body: any, w: dict[str, any], n: int) { w["json"](status, err); }
    return script;
}

test "tools: retries a plain turn once without optional questions after explicit rejection" {
    for c in [
        [400, UNSUPPORTED],
        [422, {"error": {"code": "unsupported_parameter", "param": "tools", "message": "Unsupported request parameter."}}],
        [400, {"error": "tools are not supported by this model"}],
        [400, {"error": {"message": "Unrecognized parameter: 'tools'"}}],
    ] {
        def script(body: any, w: dict[str, any], n: int) {
            if n == 1 { w["json"](c[0], c[1]); } else { answer(w, "Plain reply."); }
        }
        f = fixture(script);
        start(f, {"integrations": None});
        assert _completed(f["iid"])["ok"] is True;
        assert len(f["requests"]) == 2;
        assert tools_of(f["requests"][0]) == ["ask_user"] and "tools" not in f["requests"][1];
        assert f["requests"][1]["messages"] == f["requests"][0]["messages"];
        # A rejection for this turn is not a persisted provider setting.
        _fx["events"][f["iid"]] = [];
        start(f, {"integrations": None});
        assert _completed(f["iid"])["ok"] is True;
        assert tools_of(f["requests"][2]) == ["ask_user"];
        _cleanup();
    }
}

test "tools: does not downgrade tools for unrelated errors" {
    for c in [
        [401, UNSUPPORTED], [403, UNSUPPORTED], [429, UNSUPPORTED], [500, UNSUPPORTED],
        [400, {"error": {"message": "Invalid API key; tools are not supported."}}],
        [400, {"error": {"message": "Invalid schema for tools[0].function.parameters."}}],
        [400, {"error": {"message": "Unsupported parameter: tools[0].function.parameters."}}],
        [400, {"error": {"code": "unsupported_parameter", "param": "temperature", "message": "Unsupported parameter: temperature"}}],
        [400, {"error": {"message": "Invalid request body."}}],
        [404, {"error": {"message": "Unknown model."}}],
        [200, UNSUPPORTED],
    ] {
        f = fixture(_status_script(c[0], c[1]));
        start(f, {"integrations": None});
        assert _completed(f["iid"])["ok"] is False, c;
        assert len(f["requests"]) == 1 and tools_of(f["requests"][0]) == ["ask_user"], c;
        _cleanup();
    }
}

test "tools: does not retry network failures or strip tools mounted by the person" {
    for network in [False, True] {
        def script(body: any, w: dict[str, any], n: int) {
            if network { w["destroy"](); } else { w["json"](400, UNSUPPORTED); }
        }
        f = fixture(script);
        start(f, {"integrations": None} if network else {});
        assert _completed(f["iid"])["ok"] is False;
        assert len(f["requests"]) == 1;
        if not network { assert "audit_write" in tools_of(f["requests"][0]); }
        assert effects(f) == [];
        _cleanup();
    }
}

test "tools: does not repeat an unsupported-tools rejection after its one plain retry" {
    f = fixture(_status_script(400, UNSUPPORTED));
    start(f, {"integrations": None});
    assert _completed(f["iid"])["ok"] is False;
    assert len(f["requests"]) == 2 and "tools" not in f["requests"][1];
    _cleanup();
}

test "tools: does not retry a streamed error after partial output" {
    def script(body: any, w: dict[str, any], n: int) { w["sse"]([chunk({"content": "Already started."}), UNSUPPORTED]); }
    f = fixture(script);
    start(f, {"integrations": None});
    assert _completed(f["iid"])["ok"] is False;
    assert len(f["requests"]) == 1 and _find(f["iid"], "content.delta") is not None;
    _cleanup();
}

test "tools: does not replay after a question has been answered" {
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 {
            w["sse"]([chunk({"tool_calls": [tool_call("ask_user", json.dumps({"questions": [{"question": "Ship it?"}]}), "ask")]}, "tool_calls")]);
        } else {
            w["json"](400, UNSUPPORTED);
        }
    }
    f = fixture(script);
    start(f, {"integrations": None});
    q = _opened(f["iid"]);
    respond_card(f, q["requestId"], "answer", "Yes");
    assert _completed(f["iid"])["ok"] is False;
    assert len(f["requests"]) == 2 and f["requests"][1]["tools"] == f["requests"][0]["tools"];
    _cleanup();
}

def _image_mcp() -> str {
    return MCP_SCRIPT.replace("text: \"Stored \" + args.name + \"=\" + args.value", "text: \"Screenshot captured\" }, { type: \"image\", mimeType: \"image/png\", data: " + json.dumps(PNG_B64));
}

test "tools: delivers localComputer and browser screenshots after tool results and preserves approval" {
    for source in ["localComputer", "browser"] {
        prefix = "browser" if source == "browser" else "computer";
        def script(body: any, w: dict[str, any], n: int) {
            if n == 1 { w["sse"]([chunk({"tool_calls": [tool_call(prefix + "_write")]}, "tool_calls")]); }
            else { answer(w, "Inspected the fixture screenshot."); }
        }
        f = fixture(script, API_KEY_CANARY, _image_mcp());
        image_path = os.path.join(f["dir"], "input.png");
        with open(image_path, "wb") as fh { fh.write(base64.b64decode(PNG_B64)); }
        start(f, {"integrations": {source: f["integrations"]["custom"]["audit"]}, "images": [{"path": image_path, "mime": "image/png", "bytes": 69}]});
        decide(f);
        assert _completed(f["iid"])["ok"] is True;
        assert len(effects(f)) == 1 and len(f["requests"]) == 2;
        assert f["requests"][0]["messages"][-1]["content"] == [
            {"type": "text", "text": "Store the synthetic receipt."},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + PNG_B64}},
        ];
        tool_msg = f["requests"][1]["messages"][-2];
        assert tool_msg["role"] == "tool" and tool_msg["tool_call_id"] == "call_write";
        assert f["requests"][1]["messages"][-1] == {"role": "user", "content": [
            {"type": "text", "text": "Screenshot result from tool call call_write:"},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + PNG_B64}},
        ]};
        _cleanup();
    }
}

test "tools: keeps every tool response ahead of screenshots in a multiple-call batch" {
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 {
            second = tool_call("computer_write", "{\"name\":\"second\",\"value\":\"done\"}", "second");
            second["index"] = 1;
            w["sse"]([chunk({"tool_calls": [tool_call("computer_write", "{\"name\":\"first\",\"value\":\"done\"}", "first"), second]}, "tool_calls")]);
        } else { answer(w); }
    }
    f = fixture(script, API_KEY_CANARY, _image_mcp());
    auto_allow(f);
    start(f, {"integrations": {"localComputer": f["integrations"]["custom"]["audit"]}});
    assert _completed(f["iid"])["ok"] is True;
    assert len(effects(f)) == 2;
    tail = f["requests"][1]["messages"][-3:];
    assert tail[0]["tool_call_id"] == "first" and tail[1]["tool_call_id"] == "second" and tail[2]["role"] == "user";
    assert [p["type"] for p in tail[2]["content"]] == ["text", "image_url", "text", "image_url"];
    assert tail[2]["content"][0]["text"] == "Screenshot result from tool call first:" and tail[2]["content"][2]["text"] == "Screenshot result from tool call second:";
    _cleanup();
}

test "tools: does not execute a denied computer action" {
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 { w["sse"]([chunk({"tool_calls": [tool_call("computer_write")]}, "tool_calls")]); }
        else { answer(w, "The action was denied."); }
    }
    f = fixture(script);
    start(f, {"integrations": {"localComputer": f["integrations"]["custom"]["audit"]}});
    decide(f, "deny");
    assert _completed(f["iid"])["ok"] is False;
    assert effects(f) == [];
    last = f["requests"][1]["messages"][-1];
    assert last["role"] == "tool" and "Permission denied" in last["content"];
    _cleanup();
}

test "tools: handles content:null tool calls when a compatible endpoint returns a JSON completion" {
    def script(body: any, w: dict[str, any], n: int) {
        message = {"role": "assistant", "content": None, "tool_calls": [{"id": "call_write", "type": "function", "function": tool_call()["function"]}]} if n == 1 else {"role": "assistant", "content": "The receipt was stored."};
        w["json"](200, {"choices": [{"index": 0, "message": message, "finish_reason": "tool_calls" if n == 1 else "stop"}]});
    }
    f = fixture(script);
    start(f);
    decide(f);
    assert _completed(f["iid"])["ok"] is True;
    assert effects(f) == [{"name": "receipt", "value": "done"}] and len(f["requests"]) == 2;
    last = f["requests"][1]["messages"][-1];
    assert last["role"] == "tool" and last["tool_call_id"] == "call_write" and "Stored receipt=done" in last["content"];
    _cleanup();
}

test "tools: advertises the mounted schema and runs an authorized call before returning its result to the model" {
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 { w["sse"]([chunk({"content": None, "tool_calls": [tool_call()]}, "tool_calls")]); } else { answer(w); }
    }
    f = fixture(script);
    start(f);
    assert decide(f) == "allowed-once";
    assert _completed(f["iid"])["ok"] is True;
    audit = [t for t in f["requests"][0]["tools"] if t["function"]["name"] == "audit_write"][0];
    assert audit["type"] == "function" and audit["function"]["parameters"]["required"] == ["name", "value"];
    assert effects(f) == [{"name": "receipt", "value": "done"}];
    assert len(f["requests"]) == 2 and f["requests"][1]["tools"] == f["requests"][0]["tools"];
    tail = f["requests"][1]["messages"][-2:];
    assert tail[0]["role"] == "assistant" and tail[0]["tool_calls"][0]["id"] == "call_write";
    assert tail[1]["role"] == "tool" and tail[1]["tool_call_id"] == "call_write" and "Stored receipt=done" in tail[1]["content"];
    started = [e for e in _events(f["iid"]) if e["type"] == "item.started" and e["itemType"] == "tool"][0];
    assert any([e["type"] == "item.completed" and e.get("itemType") == "tool" and e["itemId"] == started["itemId"] and e["ok"] is True for e in _events(f["iid"])]);
    assert _events(f["iid"])[-1]["type"] == "turn.completed" and _events(f["iid"])[-1]["ok"] is True;
    _cleanup();
}

test "tools: preserves ordinary transcript chat and leaves textual tool imitations as text" {
    imitation = "<tool_call>{\"name\":\"audit_write\",\"arguments\":{\"value\":\"pretend\"}}</tool_call>";
    def script(body: any, w: dict[str, any], n: int) { answer(w, imitation); }
    f = fixture(script);
    start(f, {"integrations": None, "system": "Fixture persona", "transcript": [{"role": "user", "text": "Earlier question"}, {"role": "assistant", "text": "Earlier answer"}]});
    assert _completed(f["iid"])["ok"] is True;
    assert len(f["requests"]) == 1 and tools_of(f["requests"][0]) == ["ask_user"];
    assert [m["role"] for m in f["requests"][0]["messages"]] == ["system", "user", "assistant", "user"];
    assert _item_text(_events(f["iid"])) == imitation;
    assert not any([e["type"] in ["request.opened", "item.started"] for e in _events(f["iid"])]);
    assert effects(f) == [] and not os.path.exists(os.path.join(f["dir"], "pid"));
    _cleanup();
}

test "tools: offers ask_user beside mounted tools and returns the card reply verbatim for many questions" {
    questions = [
        {"question": "Which receipt?", "options": [{"label": "Original"}, {"label": "Copy"}]},
        {"question": "Notify accounting?", "options": [{"label": "Yes"}, {"label": "No"}]},
    ];
    reply = "The user answered your questions.\n\nQ: Which receipt?\nA: Original\n\nQ: Notify accounting?\nA: No";
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 { w["sse"]([chunk({"content": None, "tool_calls": [tool_call("ask_user", json.dumps({"questions": questions}), "call_ask")]}, "tool_calls")]); }
        else { answer(w, "Both answers recorded."); }
    }
    f = fixture(script);
    start(f);
    opened = _opened(f["iid"]);
    assert opened["requestType"] == "question" and opened["tool"] == "ask_user" and opened["questions"] == questions;
    assert "choices" not in opened;
    assert "ask_user" in tools_of(f["requests"][0]);
    assert respond_card(f, opened["requestId"], "answer", reply) == "answered";
    assert _completed(f["iid"])["ok"] is True;
    last = f["requests"][1]["messages"][-1];
    assert last["tool_call_id"] == "call_ask" and json.loads(last["content"]) == {"ok": True, "result": reply};
    assert effects(f) == [];
    _cleanup();
}

test "tools: returns an unanswered ask_user as a denial the model must not paper over" {
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 { w["sse"]([chunk({"content": None, "tool_calls": [tool_call("ask_user", json.dumps({"questions": [{"question": "Ship it?"}]}), "call_ask")]}, "tool_calls")]); }
        else { answer(w, "I went ahead and shipped it."); }
    }
    f = fixture(script);
    start(f);
    opened = _opened(f["iid"]);
    assert respond_card(f, opened["requestId"], "deny") == "rejected";
    done = _completed(f["iid"]);
    assert done["ok"] is False and done["denials"] == ["ask_user"];
    last = f["requests"][1]["messages"][-1];
    content = json.loads(last["content"]);
    assert last["tool_call_id"] == "call_ask" and content["ok"] is False and "did not answer" in content["result"];
    _cleanup();
}

test "tools: cancels a pending ask with the turn and resolves its card as unanswered" {
    def script(body: any, w: dict[str, any], n: int) {
        w["sse"]([chunk({"content": None, "tool_calls": [tool_call("ask_user", json.dumps({"questions": [{"question": "Ship it?"}]}), "call_ask")]}, "tool_calls")]);
    }
    f = fixture(script);
    turn_id = start(f);
    opened = _opened(f["iid"]);
    driver_interrupt_turn(omb_token=None, instance_id=f["iid"], thread_id=f["thread"], turn_id=turn_id);
    done = _completed(f["iid"]);
    assert done["ok"] is False and done["stopReason"] == "interrupted";
    assert any([e["type"] == "request.resolved" and e["behavior"] == "deny" and e["source"] == "system" for e in _events(f["iid"])]);
    assert respond_card(f, opened["requestId"], "answer", "late") == "unavailable";
    _cleanup();
}

test "tools: denies a malformed ask_user call with teaching text instead of opening a card" {
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 { w["sse"]([chunk({"content": None, "tool_calls": [tool_call("ask_user", "{\"questions\":[]}", "call_ask")]}, "tool_calls")]); }
        else { answer(w, "The question was not asked."); }
    }
    f = fixture(script);
    start(f);
    done = _completed(f["iid"]);
    assert done["ok"] is False and done["denials"] == ["ask_user"];
    assert _find(f["iid"], "request.opened") is None;
    content = json.loads(f["requests"][1]["messages"][-1]["content"]);
    assert content["ok"] is False and re.search("(?i)questions array", content["result"]) is not None;
    assert effects(f) == [];
    _cleanup();
}

glob DETAILS: list[any] = [
    {"type": "reasoning.text", "id": "trace-text", "format": "fixture-format", "index": 2, "text": "Opaque reasoning text", "signature": "synthetic-text-signature"},
    {"type": "reasoning.encrypted", "id": "trace-encrypted", "format": "fixture-format", "index": 1, "data": "synthetic-encrypted-segment-a"},
    {"type": "reasoning.encrypted", "id": "trace-encrypted", "format": "fixture-format", "index": 1, "data": "synthetic-encrypted-segment-b", "signature": "synthetic-encrypted-signature"},
];

test "tools: preserves opaque reasoning details and their original order through JSON and SSE tool continuation" {
    for fmt in ["JSON", "SSE"] {
        def script(body: any, w: dict[str, any], n: int) {
            if n > 1 { answer(w); return; }
            if fmt == "JSON" {
                w["json"](200, {"choices": [{"message": {"role": "assistant", "content": None, "reasoning": "Synthetic reasoning.", "reasoning_details": DETAILS,
                    "tool_calls": [{"id": "call_write", "type": "function", "function": tool_call()["function"]}]}, "finish_reason": "tool_calls"}]});
            } else {
                w["sse"]([
                    chunk({"reasoning": "Synthetic ", "reasoning_details": DETAILS[0:2]}),
                    chunk({"reasoning": "reasoning.", "reasoning_details": DETAILS[2:], "content": None, "tool_calls": [tool_call()]}, "tool_calls"),
                ]);
            }
        }
        f = fixture(script);
        start(f);
        decide(f);
        assert _completed(f["iid"])["ok"] is True;
        assistant = [m for m in f["requests"][1]["messages"] if m["role"] == "assistant"][0];
        assert assistant["content"] is None and assistant["reasoning_content"] == "Synthetic reasoning.";
        assert assistant["reasoning_details"] == DETAILS;
        texts = [e["text"] for e in _events(f["iid"]) if e["type"] == "item.completed" and e.get("itemType") == "assistant_text"];
        assert texts == ["The operation is complete."];
        if fmt == "SSE" {
            assert "".join([e["delta"] for e in _events(f["iid"]) if e["type"] == "content.delta" and e["streamKind"] == "reasoning_text"]) == "Synthetic reasoning.";
        }
        assert "synthetic-encrypted" not in json.dumps(_events(f["iid"]));
        assert effects(f) == [{"name": "receipt", "value": "done"}];
        _cleanup();
    }
}

glob REASONING_REJECTION: dict[str, any] = {"error": {
    "message": "'messages.2' : for 'role:assistant' the following must be satisfied[('messages.2' : property 'reasoning_content' is unsupported)]",
    "type": "invalid_request_error",
}};

def _reasoning_tool_round(w: dict[str, any]) {
    w["sse"]([chunk({"reasoning": "Synthetic reasoning."}), chunk({"content": None, "tool_calls": [tool_call()]}, "tool_calls")]);
}

test "tools: resends a tool continuation without reasoning_content once an endpoint rejects it, and omits it afterwards" {
    def script(body: any, w: dict[str, any], n: int) {
        if any(["reasoning_content" in m for m in body["messages"]]) { w["json"](400, REASONING_REJECTION); }
        elif body["messages"][-1]["role"] == "tool" { answer(w); }
        else { _reasoning_tool_round(w); }
    }
    f = fixture(script);
    start(f, {"approvalMode": "full"});
    assert _completed(f["iid"])["ok"] is True;
    assert len(f["requests"]) == 3;
    assert [m for m in f["requests"][1]["messages"] if m["role"] == "assistant"][0]["reasoning_content"] == "Synthetic reasoning.";
    resent = f["requests"][2]["messages"];
    assert not any(["reasoning_content" in m for m in resent]);
    stripped: list[any] = [];
    for m in f["requests"][1]["messages"] {
        c = dict(m);
        c.pop("reasoning_content", None);
        stripped.append(c);
    }
    assert resent == stripped;
    assert effects(f) == [{"name": "receipt", "value": "done"}] and _find(f["iid"], "runtime.error") is None;
    _fx["events"][f["iid"]] = [];
    start(f, {"approvalMode": "full"});
    assert _completed(f["iid"])["ok"] is True;
    assert len(f["requests"]) == 5;
    assert f["requests"][4]["messages"][-2]["role"] == "assistant" and f["requests"][4]["messages"][-2]["tool_calls"][0]["id"] == "call_write";
    assert not any(["reasoning_content" in m for m in f["requests"][4]["messages"]]);
    _cleanup();
}

test "tools: keeps reasoning_content and fails on unrelated HTTP errors" {
    for c in [
        [400, {"error": {"message": "Invalid request body."}}],
        [400, {"error": {"message": "reasoning_content is required for thinking-mode tool calls."}}],
        [401, REASONING_REJECTION],
        [500, REASONING_REJECTION],
    ] {
        def script(body: any, w: dict[str, any], n: int) {
            if n == 1 { _reasoning_tool_round(w); } else { w["json"](c[0], c[1]); }
        }
        f = fixture(script);
        start(f, {"approvalMode": "full"});
        assert _completed(f["iid"])["ok"] is False;
        assert len(f["requests"]) == 2;
        assert [m for m in f["requests"][1]["messages"] if m["role"] == "assistant"][0]["reasoning_content"] == "Synthetic reasoning.";
        assert effects(f) == [{"name": "receipt", "value": "done"}];
        _cleanup();
    }
}

test "tools: fails an SSE response that never completes properly instead of completing successfully" {
    for text in [
        "data: [DONE]\n\n",
        "data: {invalid\n\ndata: [DONE]\n\n",
        "data: {}\n\ndata: [DONE]\n\n",
        "data: " + json.dumps(chunk({"content": "Partial response"})) + "\n\ndata: {invalid\n\ndata: " + json.dumps(chunk({}, "stop")) + "\n\ndata: [DONE]\n\n",
    ] {
        f = fixture(body_of(text));
        start(f, {"integrations": None});
        assert _completed(f["iid"])["ok"] is False, text;
        assert len(f["requests"]) == 1 and effects(f) == [] and _find(f["iid"], "runtime.error") is not None;
        assert len(_all(f["iid"], "turn.completed")) == 1;
        _cleanup();
    }
}

test "tools: preserves ordinary text surrounded by normal role, empty finish, and usage frames" {
    def script(body: any, w: dict[str, any], n: int) {
        w["sse"]([chunk({"role": "assistant", "content": ""}), chunk({"content": "Hello from "}), chunk({"content": "the fixture."}), chunk({}, "stop"),
            {"choices": [], "usage": {"prompt_tokens": 12, "completion_tokens": 4}}]);
    }
    f = fixture(script);
    start(f, {"integrations": None});
    done = _completed(f["iid"]);
    assert done["ok"] is True and done["usage"] == {"input": 12, "output": 4};
    assert _item_text(_events(f["iid"])) == "Hello from the fixture.";
    assert not any([e["type"] in ["runtime.error", "request.opened"] for e in _events(f["iid"])]);
    assert tools_of(f["requests"][0]) == ["ask_user"];
    _cleanup();
}

test "tools: rejects a JSON completion without a usable message instead of reporting an empty successful turn" {
    for b in [{}, {"choices": []}, {"choices": [{"message": {}, "finish_reason": "stop"}]},
              {"choices": [{"message": {"content": None}, "finish_reason": "stop"}]},
              {"choices": [{"message": {"content": "   "}, "finish_reason": "stop"}]}] {
        f = fixture(_json_script(b));
        start(f, {"integrations": None});
        assert _completed(f["iid"])["ok"] is False, b;
        assert len(f["requests"]) == 1 and _find(f["iid"], "runtime.error") is not None;
        assert not any([e["type"] == "item.completed" and e.get("itemType") == "assistant_text" for e in _events(f["iid"])]);
        _cleanup();
    }
}

test "tools: redacts a configured credential split across content and reasoning deltas before publishing any fragment" {
    pieces = [API_KEY_CANARY[0:19], API_KEY_CANARY[19:27], API_KEY_CANARY[27:]];
    for field in ["content", "reasoning_content"] {
        def script(body: any, w: dict[str, any], n: int) {
            w["sse"]([chunk({field: "Before " + pieces[0]}), chunk({field: pieces[1]}), chunk({field: pieces[2] + " after."}, "stop")]);
        }
        f = fixture(script);
        start(f, {"integrations": None});
        assert _completed(f["iid"])["ok"] is True;
        combined = "".join([e["delta"] for e in _all(f["iid"], "content.delta")]);
        assert _item_text(_events(f["iid"])) == combined;
        assert "Before " in combined and " after." in combined and API_KEY_CANARY not in combined;
        dumped = json.dumps(_events(f["iid"]));
        for p in pieces { assert p not in dumped, p; }
        _cleanup();
    }
}

test "tools: redacts an overlapping-prefix credential received in one chunk or split chunks" {
    for pieces in [["abab"], ["ab", "ab"]] {
        def script(body: any, w: dict[str, any], n: int) {
            frames = [chunk({"content": "Before "})] + [chunk({"content": p}) for p in pieces] + [chunk({"content": " after."}, "stop")];
            w["sse"](frames);
        }
        f = fixture(script, "abab");
        start(f, {"integrations": None});
        assert _completed(f["iid"])["ok"] is True;
        combined = "".join([e["delta"] for e in _all(f["iid"], "content.delta")]);
        assert combined == "Before [redacted] after.", combined;
        assert _item_text(_events(f["iid"])) == combined and "abab" not in json.dumps(_events(f["iid"]));
        _cleanup();
    }
}

test "tools: redacts a configured credential echoed by a tool from events, diagnostics, and the returned tool result" {
    _data_dir();
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 { w["sse"]([chunk({"tool_calls": [tool_call("audit_write", json.dumps({"name": "receipt", "value": API_KEY_CANARY}))]}, "tool_calls")]); }
        else { answer(w); }
    }
    f = fixture(script);
    start(f);
    decide(f);
    assert _completed(f["iid"])["ok"] is True;
    assert effects(f) == [{"name": "receipt", "value": API_KEY_CANARY}];
    last = f["requests"][1]["messages"][-1];
    assert "Stored receipt=" in last["content"] and API_KEY_CANARY not in last["content"];
    assert API_KEY_CANARY not in json.dumps(_events(f["iid"]));
    with open(os.path.join(native_dir(), f["thread"] + ".ndjson")) as fh { assert API_KEY_CANARY not in fh.read(); }
    _cleanup();
}

test "tools: never promotes textual tool syntax into execution, even when that tool is mounted" {
    imitation = "<tool_call>{\"name\":\"audit_write\",\"arguments\":{\"name\":\"receipt\",\"value\":\"pretend\"}}</tool_call>";
    def script(body: any, w: dict[str, any], n: int) { answer(w, imitation); }
    f = fixture(script);
    start(f);
    assert _completed(f["iid"])["ok"] is True;
    assert "audit_write" in tools_of(f["requests"][0]);
    assert not any([e["type"] in ["request.opened", "item.started"] for e in _events(f["iid"])]);
    assert effects(f) == [] and len(f["requests"]) == 1;
    _cleanup();
}

test "tools: accepts null continuation fields while accumulating interleaved calls" {
    def script(body: any, w: dict[str, any], n: int) {
        if n > 1 { answer(w); return; }
        second = tool_call("audit_write", "{\"name\":\"second\",", "call_second");
        second["index"] = 1;
        w["sse"]([
            chunk({"tool_calls": [tool_call("audit_write", "{\"name\":\"first\",", "call_first"), second]}),
            chunk({"tool_calls": [{"index": 1, "id": None, "type": None, "function": {"name": None, "arguments": "\"value\":\"two\"}"}}]}),
            chunk({"tool_calls": [{"index": 0, "function": {"arguments": "\"value\":\"one\"}"}}]}, "tool_calls"),
        ]);
    }
    f = fixture(script);
    approved = auto_allow(f);
    start(f);
    assert _completed(f["iid"])["ok"] is True;
    assert len(set(approved)) == 2;
    assert effects(f) == [{"name": "first", "value": "one"}, {"name": "second", "value": "two"}];
    tool_msgs = [m for m in f["requests"][1]["messages"] if m["role"] == "tool"];
    assert [m["tool_call_id"] for m in tool_msgs] == ["call_first", "call_second"];
    assert "Stored first=one" in tool_msgs[0]["content"] and "Stored second=two" in tool_msgs[1]["content"];
    _cleanup();
}

test "tools: keeps Full access across router model changes without per-tool approvals" {
    def script(body: any, w: dict[str, any], n: int) {
        frame = chunk({"tool_calls": [tool_call("audit_write", json.dumps({"name": "step-" + str(n), "value": "done"}), "call-" + str(n))]}, "tool_calls") if n <= 2 else chunk({"content": "Both operations completed."}, "stop");
        frame["model"] = "router-backend-" + str(n);
        w["sse"]([frame]);
    }
    f = fixture(script);
    start(f, {"approvalMode": "full"});
    assert _completed(f["iid"])["ok"] is True;
    assert len(effects(f)) == 2 and len(f["requests"]) == 3 and _find(f["iid"], "request.opened") is None;
    _cleanup();
}

test "tools: aggregates model usage across execution and continuation" {
    def script(body: any, w: dict[str, any], n: int) {
        first = chunk({"tool_calls": [tool_call()]}, "tool_calls") if n == 1 else chunk({"content": "Receipt verified."}, "stop");
        w["sse"]([first, {"choices": [], "usage": {"prompt_tokens": n * 10, "completion_tokens": n * 2}}]);
    }
    f = fixture(script);
    start(f);
    decide(f);
    done = _completed(f["iid"]);
    assert done["ok"] is True and done["usage"] == {"input": 30, "output": 6};
    _cleanup();
}

test "tools: returns denial to the model without treating a convincing final answer as successful execution" {
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 { w["sse"]([chunk({"tool_calls": [tool_call()]}, "tool_calls")]); } else { answer(w, "I successfully wrote the receipt."); }
    }
    f = fixture(script);
    start(f);
    assert decide(f, "deny") == "rejected";
    assert _completed(f["iid"])["ok"] is False;
    assert effects(f) == [] and len(f["requests"]) == 2;
    last = f["requests"][1]["messages"][-1];
    assert last["tool_call_id"] == "call_write" and re.search("(?i)denied|declined|not allowed", last["content"]) is not None;
    assert any([e["type"] == "item.completed" and e.get("itemType") == "tool" and e["ok"] is False for e in _events(f["iid"])]);
    _cleanup();
}

test "tools: keeps approvals bound to the pending request and thread" {
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 { w["sse"]([chunk({"tool_calls": [tool_call()]}, "tool_calls")]); } else { answer(w); }
    }
    f = fixture(script);
    start(f);
    request = _opened(f["iid"]);
    assert respond_card(f, request["requestId"], "allow", None, "another-thread") == "unavailable";
    assert respond_card(f, "unknown-request", "allow") == "unavailable";
    assert respond_card(f, request["requestId"], "answer") == "unavailable";
    assert effects(f) == [];
    assert decide(f) == "allowed-once";
    _completed(f["iid"]);
    assert respond_card(f, request["requestId"], "allow") == "unavailable";
    assert len(effects(f)) == 1;
    _cleanup();
}

test "tools: reports malformed or unknown calls without granting permission or executing" {
    for c in [["audit_write", "{\"name\":"], ["audit_write", "[]"], ["audit_write", "{\"name\":\"receipt\",\"value\":42}"], ["audit_unknown", "{\"name\":\"receipt\",\"value\":\"done\"}"]] {
        def script(body: any, w: dict[str, any], n: int) {
            if n == 1 { w["sse"]([chunk({"tool_calls": [tool_call(c[0], c[1])]}, "tool_calls")]); } else { answer(w); }
        }
        f = fixture(script);
        start(f);
        assert _completed(f["iid"])["ok"] is False, c;
        assert effects(f) == [] and _find(f["iid"], "request.opened") is None;
        assert any([e["type"] == "item.completed" and e.get("itemType") == "tool" and e["ok"] is False for e in _events(f["iid"])]);
        last = f["requests"][1]["messages"][-1];
        assert last["role"] == "tool" and last["tool_call_id"] == "call_write" and isinstance(last["content"], str);
        _cleanup();
    }
}

test "tools: rejects duplicate, missing, changed, truncated or absent calls before any tool can execute" {
    dup = tool_call();
    dup["index"] = 1;
    for frames in [
        [chunk({"tool_calls": [tool_call(), dup]}, "tool_calls")],
        [chunk({"tool_calls": [{"index": 0, "type": "function", "function": tool_call()["function"]}]}, "tool_calls")],
        [chunk({"tool_calls": [tool_call()]}), chunk({"tool_calls": [{"index": 0, "id": "a_different_call"}]}, "tool_calls")],
        [chunk({"tool_calls": [tool_call()]}, "length")],
        [chunk({}, "tool_calls")],
    ] {
        def script(body: any, w: dict[str, any], n: int) { w["sse"](frames); }
        f = fixture(script);
        start(f);
        assert _completed(f["iid"])["ok"] is False;
        assert effects(f) == [] and len(f["requests"]) == 1;
        assert _find(f["iid"], "request.opened") is None and _find(f["iid"], "runtime.error") is not None;
        _cleanup();
    }
}

test "tools: returns an MCP tool failure and preserves its unsuccessful operation status" {
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 { w["sse"]([chunk({"tool_calls": [tool_call("audit_fail")]}, "tool_calls")]); } else { answer(w); }
    }
    f = fixture(script);
    start(f);
    decide(f);
    assert _completed(f["iid"])["ok"] is False;
    assert effects(f) == [];
    assert "Synthetic tool failed" in f["requests"][1]["messages"][-1]["content"];
    _cleanup();
}

test "tools: fails explicitly if the model requests a structured tool when none was mounted" {
    def script(body: any, w: dict[str, any], n: int) { w["sse"]([chunk({"content": None, "tool_calls": [tool_call()]}, "tool_calls")]); }
    f = fixture(script);
    start(f, {"integrations": None});
    assert _completed(f["iid"])["ok"] is False;
    assert effects(f) == [];
    assert any([e["type"] == "runtime.error" or (e["type"] == "item.completed" and e.get("itemType") == "tool" and not e["ok"]) for e in _events(f["iid"])]);
    _cleanup();
}

test "tools: never retries a provider error after a tool's effect has already happened" {
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 { w["sse"]([chunk({"tool_calls": [tool_call()]}, "tool_calls")]); } else { w["raw"](503, "Synthetic provider unavailable", "text/plain"); }
    }
    f = fixture(script);
    start(f);
    decide(f);
    assert _completed(f["iid"])["ok"] is False;
    assert len(effects(f)) == 1 and len(f["requests"]) == 2;
    assert _find(f["iid"], "turn.retrying") is None and len(_all(f["iid"], "turn.completed")) == 1;
    _cleanup();
}

test "tools: resends a refused tool call after a step ran without repeating it, and ends asking only for what's left" {
    message = "Tool call validation failed: tool call validation failed: attempted to call tool 'json' which was not in request.tools";
    def script(body: any, w: dict[str, any], n: int) {
        if n == 1 { w["sse"]([chunk({"tool_calls": [tool_call()]}, "tool_calls")]); }
        else { w["sse"]([{"error": {"message": message, "type": "invalid_request_error", "code": "tool_use_failed"}}]); }
    }
    f = fixture(script);
    start(f, {"approvalMode": "full"});
    done = _completed(f["iid"]);
    assert done["ok"] is False and done["stopReason"] == "error";
    assert len(effects(f)) == 1 and len(f["requests"]) == 4;
    assert any([m["role"] == "tool" and m.get("tool_call_id") == "call_write" for m in f["requests"][1]["messages"]]);
    assert f["requests"][2] == f["requests"][1] and f["requests"][3] == f["requests"][1];
    assert [[e["attempt"], e["reason"]] for e in _all(f["iid"], "turn.retrying")] == [[1, "tool_use_failed"], [2, "tool_use_failed"]];
    errs = _all(f["iid"], "runtime.error");
    assert len(errs) == 1 and errs[0]["message"] == "The model tried to use a tool it was not given (\"json\"). The steps before it already ran, so ask only for what's left. Provider: " + message;
    _cleanup();
}

test "tools: rejects a repeated call ID in a later model round before duplicating its effect" {
    def script(body: any, w: dict[str, any], n: int) { w["sse"]([chunk({"tool_calls": [tool_call()]}, "tool_calls")]); }
    f = fixture(script);
    start(f);
    decide(f);
    assert _completed(f["iid"])["ok"] is False;
    assert len(effects(f)) == 1 and len(f["requests"]) == 2 and len(_all(f["iid"], "request.opened")) == 1;
    assert any([re.search("(?i)repeat|duplicate", e["message"]) is not None for e in _all(f["iid"], "runtime.error")]);
    _cleanup();
}

test "tools: finishes a tool-heavy task that needs more than sixteen steps" {
    def script(body: any, w: dict[str, any], n: int) {
        if n <= 40 { w["sse"]([chunk({"tool_calls": [tool_call("audit_write", "{\"name\":\"step\",\"value\":\"" + str(n) + "\"}", "call_" + str(n))]}, "tool_calls")]); }
        else { answer(w); }
    }
    f = fixture(script);
    start(f, {"approvalMode": "full"});
    assert _completed(f["iid"], 60.0)["ok"] is True;
    assert len(f["requests"]) == 41 and len(effects(f)) == 40 and _find(f["iid"], "runtime.error") is None;
    _cleanup();
}

test "tools: stops a model that keeps requesting tools after 64 steps, with one next action that does not repeat the steps that ran" {
    def script(body: any, w: dict[str, any], n: int) {
        w["sse"]([chunk({"tool_calls": [tool_call("audit_write", "{\"name\":\"receipt\",\"value\":\"done\"}", "call_" + str(n))]}, "tool_calls")]);
    }
    f = fixture(script);
    auto_allow(f);
    start(f);
    done = _completed(f["iid"], 90.0);
    assert done["ok"] is False and done["stopReason"] == "error";
    assert len(f["requests"]) == 64 and len(effects(f)) == 64;
    errs = _all(f["iid"], "runtime.error");
    assert len(errs) == 1 and errs[0]["message"] == "Stopped after 64 steps without a final answer. The steps so far already ran, so ask only for what's left." and errs[0]["terminal"] is True;
    _cleanup();
}

test "tools: stops at 200 tool calls in one turn without running the batch that crosses it" {
    def script(body: any, w: dict[str, any], n: int) {
        calls: list[any] = [];
        for i in range(25) {
            c = tool_call("audit_write", "{\"name\":\"r" + str(n) + "\",\"value\":\"" + str(i) + "\"}", "call_" + str(n) + "_" + str(i));
            c["index"] = i;
            calls.append(c);
        }
        w["sse"]([chunk({"tool_calls": calls}, "tool_calls")]);
    }
    f = fixture(script);
    start(f, {"approvalMode": "full"});
    done = _completed(f["iid"], 120.0);
    assert done["ok"] is False and done["stopReason"] == "error";
    assert len(f["requests"]) == 9 and len(effects(f)) == 200;
    errs = _all(f["iid"], "runtime.error");
    assert len(errs) == 1 and errs[0]["message"] == "Stopped after 200 tool calls without a final answer. The steps so far already ran, so ask only for what's left.";
    _cleanup();
}

test "tools: keeps the native log small on a long turn with large tool results" {
    _data_dir();
    large = "note " * 4000;
    def script(body: any, w: dict[str, any], n: int) {
        if n <= 20 { w["sse"]([chunk({"tool_calls": [tool_call("audit_write", json.dumps({"name": "step" + str(n), "value": large}), "call_" + str(n))]}, "tool_calls")]); }
        else { answer(w); }
    }
    f = fixture(script);
    start(f, {"approvalMode": "full"});
    assert _completed(f["iid"], 60.0)["ok"] is True;
    assert len(effects(f)) == 20;
    with open(os.path.join(native_dir(), f["thread"] + ".ndjson")) as fh { log = fh.read(); }
    assert len(log) < len(large);
    outgoing = [json.loads(l)["msg"] for l in log.strip().split("\n") if json.loads(l)["dir"] == "out"];
    want = [{"model": "fixture-model", "messageCount": len(r["messages"]), "tools": tools_of(r)} for r in f["requests"]];
    assert outgoing == want;
    _cleanup();
}

test "tools: cancels during stream, approval, rpc and continuation, closes execution authority, and settles exactly once" {
    for stage in ["stream", "approval", "rpc", "continuation"] {
        held = threading.Event();
        def script(body: any, w: dict[str, any], n: int) {
            if stage == "stream" {
                held.set();
                w["sse"]([chunk({"tool_calls": [tool_call("audit_write", "{\"name\":")]})], False);
            } elif n == 1 {
                w["sse"]([chunk({"tool_calls": [tool_call("audit_wait" if stage == "rpc" else "audit_write")]}, "tool_calls")]);
            } else {
                held.set();
                w["sse"]([chunk({"content": "Finishing"})], False);
            }
        }
        f = fixture(script);
        turn_id = start(f);
        if stage == "stream" { assert held.wait(10); }
        elif stage == "approval" { _opened(f["iid"]); }
        else {
            decide(f);
            if stage == "rpc" { assert f["srv"]["mcp_started"].wait(10); } else { assert held.wait(10); }
        }
        driver_interrupt_turn(omb_token=None, instance_id=f["iid"], thread_id=f["thread"], turn_id=turn_id);
        done = _completed(f["iid"]);
        assert done["ok"] is False and done["stopReason"] == "interrupted", stage;
        assert len(effects(f)) == (1 if stage == "continuation" else 0), stage;
        assert len(f["requests"]) == (2 if stage == "continuation" else 1), stage;
        assert f["thread"] not in _drivers_instances[f["iid"]]["live"];
        with open(os.path.join(f["dir"], "pid")) as fh { pid = int(fh.read()); }
        assert not _alive(pid), stage;
        pending = _find(f["iid"], "request.opened");
        if pending is not None { assert respond_card(f, pending["requestId"], "allow") == "unavailable"; }
        assert len(_all(f["iid"], "turn.completed")) == 1;
        _cleanup();
    }
}
