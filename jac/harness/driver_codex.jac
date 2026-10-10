"""Codex driver — the Jac port of server/drivers/codex.ts (kind codex).

The official `codex` CLI runs headless as `codex app-server`: newline-
delimited JSON-RPC on stdio. Each turn launches a fresh app-server, runs the
initialize → config/read → thread/start|resume → turn/start handshake, and
settles on the real `turn/completed` notification. Approval and question
requests arrive as server→client JSON-RPC requests and surface as
request.opened events answered through driver_respond (no MCP proxy or
socket, unlike claude). The resume cursor is the codex thread id.

Threading model (node's event loop → OS threads): the op that sends a turn
does the synchronous setup (spawn, live registration, turn.started) and
returns; a handshake thread drives the blocking RPCs; one reader thread per
app-server parses stdout in order — RPC responses resolve the waiting
handshake, server requests and notifications are handled inline, exactly
in the order the TS `data` handler saw them. Turn state that the TS driver
kept in closures lives in two records: the logical turn (`lt`, shared by
every retry attempt) and the attempt (`a`, one app-server process).

Declarative surface (config decode, catalog, auth, device/plan sign-in,
snapshot) stays node-side in the TS driver; a ChatGPT-plan turn receives its
access token from the shim's prepareJacTurn hook as turn["_jac"]."""

import os;
import re;
import sys;
import json;
import time;
import uuid;
import shlex;
import signal;
import threading;
import subprocess;

import from drivers { emit_event, driver_register_kind }
import from driver_claude { _kill_cli_tree, _describe_spawn_failure }
import from driver_claude_support {
    strip_workspace_credential_env, augmented_path, can_use_mcp_server,
    assert_tool_scope_supported, command_summary, tool_detail_preview,
    classify_error, compute_backoff, RETRY_MAX_ATTEMPTS,
    classify_resume_failure, may_replay, recovery_prompt_for,
    extract_mcp_images, question_choices,
}
import from driver_codex_support {
    js, data_dir, sha256_hex, env_ms, env_scale, server_version, DRIVER_KIND,
    codex_user_error, rpc_error, is_rpc_error, error_message,
    missing_native_codex_thread, chatgpt_plan_codex_args, managed_codex_args,
    codex_tool_surface_args, GUEST_CONFINED_CODEX_ARGS, decode_codex_selection,
    codex_local_provider_args, mount_mcp_server, is_harness_owned_mcp_env_name,
    codex_config_mcp_server_names, mounted_mcp_server_name, codex_gate_server,
    granted_permissions, additional_permission_summary, mcp_app_approval_form,
    codex_shell_disabled, named_approval_params, with_resolved_sandbox,
    custom_approval_params, permission_profile_unsupported, permission_command,
    permission_launch_cwd, codex_native_log_message,
    codex_native_incoming_log_message, append_native,
    codex_developer_instructions, sync_codex_instructions,
    volatile_context_note, with_context_note, parse_protocol_ask_questions,
    question_answers_by_id,
}

glob DENY_TIMEOUT_NOTE: str = "OpenMausBot: nobody answered this permission request in time. Skip this action and finish what you can without it.";
glob ASK_TIMEOUT_S: float = 900.0;
glob RPC_TIMEOUT_MS: float = 60000.0;
glob PROC_KILL_GRACE_MS: float = 5000.0;
glob NATIVE_SOURCE: str = "codex.app-server";
glob TOO_MANY_EARLY: int = 1024;

# Logged once per name (mirrors the module-level Sets in codex.ts).
glob _noted: dict[str, any] = {"sse": {}, "renamed": {}};

# ── per-instance state ─────────────────────────────────────────────────────

def _create(inst: dict[str, any]) {
    inst["codex_lock"] = threading.RLock();
}

def _config(inst: dict[str, any]) -> dict[str, any] {
    return inst["config"] if isinstance(inst.get("config"), dict) else {};
}

def _instance_env(inst: dict[str, any]) -> dict[str, any] {
    return inst["environment"] if isinstance(inst.get("environment"), dict) else {};
}

def _is_plan(config: dict[str, any]) -> bool {
    return config.get("authMode") == "chatgpt-plan";
}

def _managed(config: dict[str, any]) -> any {
    managed = config.get("managed");
    return managed if isinstance(managed, dict) else None;
}

def plan_codex_home(instance_id: str) -> str {
    # Provider homes are excluded from portable backups and Move to Cloud.
    return os.path.join(data_dir(), "providers", "chatgpt-plan", sha256_hex(instance_id), "codex");
}

def child_env(inst: dict[str, any]) -> dict[str, any] {
    env: dict[str, any] = dict(os.environ);
    for (key, value) in _instance_env(inst).items() {
        if value is not None { env[key] = value if isinstance(value, str) else str(value); }
    }
    env["PATH"] = augmented_path(dict(os.environ));
    env["NPM_CONFIG_LOGLEVEL"] = "error";
    # The CLI owns its own ChatGPT login; a leaked API key silently flips
    # billing to pay-as-you-go.
    env.pop("OPENAI_API_KEY", None);
    strip_workspace_credential_env(env);
    env.pop("OPENMAUSBOT_CHATGPT_TOKEN", None);
    if _is_plan(_config(inst)) { env["CODEX_HOME"] = plan_codex_home(inst["instance_id"]); }
    return env;
}

def _resolve_cli(cli: str) -> list[any] {
    # procs.ts resolveCliSpawn: one tokenizer pass, except a real unquoted
    # path containing spaces.
    trimmed = cli.strip();
    if " " in trimmed and not os.path.exists(trimmed) {
        try {
            tokens = shlex.split(trimmed);
        } except Exception {
            tokens = [trimmed];
        }
        if tokens { return tokens; }
    }
    return [trimmed];
}

def _note_once(kind: str, name: str, message: str) {
    seen = _noted[kind];
    if name in seen { return; }
    seen[name] = True;
    print(message, file=sys.stderr);
}

# ── events ─────────────────────────────────────────────────────────────────

def _emit(inst: dict[str, any], lt: dict[str, any], fields: dict[str, any]) {
    out: dict[str, any] = {"threadId": lt["thread_id"], "turnId": lt["turn_id"]};
    for (key, value) in fields.items() { out[key] = value; }
    emit_event(inst, out);
}

def _set_if(target: dict[str, any], key: str, value: any) {
    # TS spreads drop undefined fields; never send them as null.
    if value is not None { target[key] = value; }
}

# ── JSON-RPC transport ─────────────────────────────────────────────────────

def _send(a: dict[str, any], payload: dict[str, any]) {
    proc = a.get("proc");
    if proc is not None {
        a["write_lock"].acquire();
        try {
            proc.stdin.write((js(payload) + "\n").encode("utf-8"));
            proc.stdin.flush();
        } except Exception {
        } finally {
            a["write_lock"].release();
        }
    }
    append_native(a["thread_id"], "out", NATIVE_SOURCE, codex_native_log_message(payload));
}

def _ms_text(ms: float) -> str {
    return str(int(ms)) if ms == int(ms) else str(ms);
}

# Blocking request: returns the result or raises (rpc_error, timeout, or
# "turn settled"). A wedged app-server can accept stdin and never reply, so
# every request carries a timeout.
def _request(a: dict[str, any], method: str, params: any, timeout_ms: float = RPC_TIMEOUT_MS) -> any {
    rec: dict[str, any] = {"event": threading.Event(), "result": None, "error": None, "method": method, "params": params};
    a["lock"].acquire();
    try {
        rid = a["next_id"];
        a["next_id"] = rid + 1;
        if method == "config/read" { a["sensitive_ids"].add(rid); }
        if a["settled"] {
            rec["error"] = RuntimeError("turn settled");
            rec["event"].set();
        } else {
            a["pending"][rid] = rec;
        }
    } finally {
        a["lock"].release();
    }
    if rec["event"].is_set() {
        early_failure: Exception = rec["error"];
        raise early_failure;
    }
    _send(a, {"jsonrpc": "2.0", "id": rid, "method": method, "params": params});
    if not rec["event"].wait(timeout_ms / 1000.0) {
        timed_out = False;
        a["lock"].acquire();
        try {
            if a["pending"].pop(rid, None) is not None { timed_out = True; }
        } finally {
            a["lock"].release();
        }
        if timed_out {
            raise RuntimeError("codex " + method + " timed out after " + _ms_text(timeout_ms) + "ms");
        }
        rec["event"].wait();
    }
    if rec["error"] is not None {
        failure: Exception = rec["error"];
        raise failure;
    }
    return rec["result"];
}

def _reject_all(a: dict[str, any], message: str) {
    a["lock"].acquire();
    try {
        recs = list(a["pending"].values());
        a["pending"].clear();
    } finally {
        a["lock"].release();
    }
    for rec in recs {
        rec["error"] = RuntimeError(message);
        rec["event"].set();
    }
}

# Reader-thread resolution. thread/start|resume and turn/start bind their ids
# synchronously, before any later line of the same chunk is handled.
def _resolve_response(inst: dict[str, any], lt: dict[str, any], a: dict[str, any], msg: dict[str, any]) {
    rid = msg.get("id");
    a["lock"].acquire();
    try {
        rec = a["pending"].pop(rid, None) if isinstance(rid, int) else None;
    } finally {
        a["lock"].release();
    }
    if rec is None { return; }
    if msg.get("error") {
        rec["error"] = rpc_error(msg["error"]);
        rec["event"].set();
        return;
    }
    v = msg.get("result");
    method = rec["method"];
    params = rec["params"];
    if method == "thread/start" or method == "thread/resume" {
        thread = v.get("thread") if isinstance(v, dict) else None;
        returned_id = thread.get("id") if isinstance(thread, dict) else None;
        requested_id = params.get("threadId") if method == "thread/resume" and isinstance(params, dict) else None;
        if isinstance(returned_id, str) and returned_id {
            a["codex_thread_id"] = returned_id;
        } elif isinstance(requested_id, str) and requested_id {
            a["codex_thread_id"] = requested_id;
        }
    }
    if method == "turn/start" {
        turn = v.get("turn") if isinstance(v, dict) else None;
        native_turn = turn.get("id") if isinstance(turn, dict) else None;
        if not isinstance(native_turn, str) or not native_turn {
            rec["error"] = RuntimeError("Codex did not return a native turn id");
            rec["event"].set();
            return;
        }
        a["codex_turn_id"] = native_turn;
        a["starting_native_turn"] = False;
        early = list(a["early"]);
        a["early"].clear();
        for notification in early {
            if a["settled"] { break; }
            _handle_notification(inst, lt, a, notification);
        }
    }
    rec["result"] = v;
    rec["event"].set();
}

# ── settle / stop ──────────────────────────────────────────────────────────

def _proc_alive(a: dict[str, any]) -> bool {
    proc = a.get("proc");
    return proc is not None and proc.poll() is None;
}

def _terminate(a: dict[str, any]) -> bool {
    if a.get("proc") is None { return True; }
    return _kill_cli_tree(a, PROC_KILL_GRACE_MS);
}

# Stop asks the app-server to end the turn itself before any signal: a
# protocol interrupt keeps the session the authority; the kill is only
# escalation for a server that will not answer.
def _stop_attempt(inst: dict[str, any], lt: dict[str, any], a: dict[str, any]) -> bool {
    lt["stop_requested"] = True;
    lt["stop_event"].set();
    do_interrupt = False;
    a["lock"].acquire();
    try {
        if not a["settled"] and not a["interrupt_requested"] and a["codex_thread_id"] and a["codex_turn_id"] and _proc_alive(a) {
            a["interrupt_requested"] = True;
            do_interrupt = True;
        }
    } finally {
        a["lock"].release();
    }
    if do_interrupt {
        grace = env_ms("FAKE_CODEX_INTERRUPT_GRACE_MS", 750.0);
        try {
            _request(a, "turn/interrupt", {"threadId": a["codex_thread_id"], "turnId": a["codex_turn_id"]}, grace);
        } except Exception {
            # Old CLI without the method, or a wedged server: escalate below.
        }
        # Wait for settle's synchronous half (asks resolved, completion
        # armed) — what the TS event loop guaranteed before a Stop resumed.
        deadline = time.monotonic() + grace / 1000.0;
        while not a["settle_ready"].is_set() and time.monotonic() < deadline {
            time.sleep(0.015);
        }
    }
    stopped = _terminate(a);
    if stopped and a["settled"] and not a["settle_ready"].is_set() {
        # settle() is mid-flight on another thread: let it arm completion.
        a["settle_ready"].wait(5.0);
    }
    complete = a.get("complete");
    if stopped and complete is not None { complete(); }
    return stopped;
}

def _settle(inst: dict[str, any], lt: dict[str, any], a: dict[str, any], ok: bool, stop_reason: any) {
    a["lock"].acquire();
    try {
        if a["settled"] { return; }
        a["settled"] = True;
    } finally {
        a["lock"].release();
    }
    for finish in list(a["asks"].values()) {
        finish("deny", "OpenMausBot: the turn ended", "system");
    }
    _reject_all(a, "turn settled");

    def complete() {
        # Exactly one caller emits turn.completed; a caller that loses the
        # race returns only once that event has been delivered, so a Stop
        # never resolves ahead of the completion it caused.
        lock = inst["codex_lock"];
        mine = False;
        lock.acquire();
        try {
            live = inst["live"].get(lt["thread_id"]);
            if live is not None and live.get("attempt") is a {
                inst["live"].pop(lt["thread_id"], None);
                a["completing"] = True;
                mine = True;
            }
        } finally {
            lock.release();
        }
        if not mine {
            if a["completing"] { a["completed"].wait(5.0); }
            return;
        }
        try {
            ev: dict[str, any] = {"type": "turn.completed", "ok": ok, "stopReason": stop_reason, "cost": None};
            _set_if(ev, "usage", a["usage"]);
            _emit(inst, lt, ev);
        } finally {
            a["completed"].set();
        }
    }
    a["complete"] = complete;
    a["settle_ready"].set();
    if not _stop_attempt(inst, lt, a) {
        _emit(inst, lt, {"type": "runtime.error", "message": "codex did not shut down after termination was requested"});
    }
}

# ── steering ───────────────────────────────────────────────────────────────

# expectedTurnId is the protocol's precondition: a turn that moved on (or a
# CLI without turn/steer) answers with an RPC error → "refused", and the
# caller queues. A timeout after delivery, or a settle while the answer was
# in flight, is "indeterminate": the words may already be running.
def _steer_attempt(lt: dict[str, any], a: dict[str, any], text: str) -> str {
    if a["settled"] or a["abandoned"] or lt["stop_requested"] or not a["codex_thread_id"] or not a["codex_turn_id"] { return "refused"; }
    if not _proc_alive(a) { return "refused"; }
    try {
        _request(a, "turn/steer", {
            "threadId": a["codex_thread_id"],
            "input": [{"type": "text", "text": text}],
            "expectedTurnId": a["codex_turn_id"],
        }, env_ms("FAKE_CODEX_STEER_TIMEOUT_MS", 10000.0));
        return "steered";
    } except Exception as e {
        if a["settled"] or "timed out" in error_message(e) { return "indeterminate"; }
        return "refused";
    }
}

# ── server → client requests (approvals, questions) ────────────────────────

def _handle_server_request(inst: dict[str, any], lt: dict[str, any], a: dict[str, any], msg: dict[str, any]) {
    turn = lt["turn"];
    method = msg.get("method");
    params: any = msg.get("params") if isinstance(msg.get("params"), dict) else {};
    msg_id = msg.get("id");
    legacy = method == "execCommandApproval" or method == "applyPatchApproval";
    is_mcp_elicitation = method == "mcpServer/elicitation/request";
    meta = params.get("_meta") if isinstance(params.get("_meta"), dict) else {};
    is_legacy_mcp_permission = is_mcp_elicitation and meta.get("codex_approval_kind") == "mcp_tool_call";
    mcp_app_approval = mcp_app_approval_form(params) if is_mcp_elicitation else None;
    is_mcp_permission = is_legacy_mcp_permission or mcp_app_approval is not None;
    is_question = method == "item/tool/requestUserInput";
    is_additional_permission = method == "item/permissions/requestApproval";
    is_command = method == "execCommandApproval" or method == "item/commandExecution/requestApproval";
    is_permission = legacy or is_mcp_permission or is_additional_permission or method == "item/commandExecution/requestApproval" or method == "item/fileChange/requestApproval";
    # A normal MCP elicitation asks for real user input; unknown future
    # requests fail closed instead of being mistaken for commands.
    if not is_question and not is_permission {
        if is_mcp_elicitation {
            _send(a, {"jsonrpc": "2.0", "id": msg_id, "result": {"action": "decline"}});
        } else {
            _send(a, {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": "Unsupported server request: " + str(method)}});
        }
        return;
    }
    protocol_questions = parse_protocol_ask_questions(params.get("questions")) if is_question else None;
    if is_question and protocol_questions is None {
        refusal = "ask needs at least one answerable question — a string id and question text each; this request sent none." if isinstance(params.get("questions"), list) else "ask needs params.questions to be an array of questions, each with a string id and question text.";
        _send(a, {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32602, "message": refusal}});
        return;
    }
    mcp_tool: any = None;
    if is_legacy_mcp_permission {
        m = re.search(r'tool "([^"]+)"', str(params.get("message") if params.get("message") is not None else ""));
        if m is not None { mcp_tool = m.group(1); }
    }
    tool = "shell";
    if mcp_app_approval is not None {
        tool = mcp_app_approval["tool"];
    } elif is_legacy_mcp_permission {
        tool = mcp_tool or "mcp";
    } elif is_additional_permission {
        tool = "permissions";
    } elif method == "item/fileChange/requestApproval" or method == "applyPatchApproval" {
        tool = "edit";
    } elif is_question {
        tool = "ask_user";
    }

    def permission_result(allow: bool) -> dict[str, any] {
        if is_mcp_permission {
            if not allow { return {"action": "decline"}; }
            if mcp_app_approval is not None { return mcp_app_approval["allowResult"]; }
            return {"action": "accept", "content": {}};
        }
        if is_additional_permission {
            return {"permissions": granted_permissions(params.get("permissions")) if allow else {}, "scope": "turn"};
        }
        if allow { return {"decision": "approved" if legacy else "accept"}; }
        return {"decision": "denied" if legacy else "decline"};
    }

    if lt["auto_accept"] and is_permission {
        _send(a, {"jsonrpc": "2.0", "id": msg_id, "result": permission_result(True)});
        return;
    }
    request_id = str(uuid.uuid4());
    summary: any = tool;
    if is_additional_permission {
        summary = additional_permission_summary(params.get("permissions"), params.get("reason"));
    } elif is_mcp_permission {
        if mcp_app_approval is not None {
            summary = mcp_app_approval["summary"];
        } elif isinstance(params.get("message"), str) {
            summary = params["message"];
        } else {
            summary = "MCP access requested";
        }
    } elif isinstance(params.get("command"), str) {
        summary = params["command"];
    } elif protocol_questions is not None {
        summary = " · ".join([pair["question"]["question"] for pair in protocol_questions]);
    } elif isinstance(params.get("reason"), str) {
        summary = params["reason"];
    }
    # Flat choices only when one non-multiselect question can be answered by
    # a bare reply.
    choices: any = None;
    if is_question and protocol_questions is not None {
        choices = question_choices([pair["question"] for pair in protocol_questions]);
    }
    timer_box: dict[str, any] = {"timer": None};

    def finish(behavior: str, message: any = None, source: str = "user") {
        a["lock"].acquire();
        try {
            if a["asks"].pop(request_id, None) is None { return; }
        } finally {
            a["lock"].release();
        }
        timer = timer_box["timer"];
        if timer is not None { timer.cancel(); }
        if is_question {
            # Only the person's reply is filed; timeout and teardown send
            # empty answers so every id reads unanswered.
            mapped: dict[str, any] = {};
            if behavior == "answer" and source == "user" and isinstance(message, str) {
                mapped = question_answers_by_id(message, protocol_questions or []);
            }
            answers: dict[str, any] = {};
            for (qid, answer) in mapped.items() { answers[qid] = {"answers": [answer]}; }
            _send(a, {"jsonrpc": "2.0", "id": msg_id, "result": {"answers": answers}});
        } else {
            _send(a, {"jsonrpc": "2.0", "id": msg_id, "result": permission_result(behavior == "allow")});
        }
        _emit(inst, lt, {"type": "request.resolved", "requestId": request_id, "behavior": behavior, "source": source});
    }

    def on_timeout() {
        # A timed-out question resolves as denied, not answered.
        finish("deny", None if is_question else DENY_TIMEOUT_NOTE, "timeout");
    }
    timer = threading.Timer(ASK_TIMEOUT_S, on_timeout);
    timer.daemon = True;
    timer_box["timer"] = timer;
    a["asks"][request_id] = finish;
    timer.start();
    ev: dict[str, any] = {
        "type": "request.opened",
        "requestId": request_id,
        "requestType": "question" if is_question else "permission",
        "tool": tool,
        "summary": summary,
    };
    if is_command {
        cwd = params.get("cwd");
        if cwd is None {
            # Helpers may have a different workspace from their parent.
            if not params.get("threadId") or params.get("threadId") == a["codex_thread_id"] { cwd = lt["command_cwd"]; }
        }
        _set_if(ev, "command", permission_command(params.get("command"), cwd));
    }
    _set_if(ev, "choices", choices);
    if protocol_questions is not None {
        ev["questions"] = [pair["question"] for pair in protocol_questions];
    }
    if lt["controls_host"] { ev["approvalScope"] = "local-computer"; }
    explicit = is_additional_permission or (is_command and (params.get("additionalPermissions") is not None or params.get("networkApprovalContext") is not None));
    if explicit { ev["requiresExplicitApproval"] = True; }
    _emit(inst, lt, ev);
}

# ── notifications ──────────────────────────────────────────────────────────

def _review_notice(inst: dict[str, any], lt: dict[str, any], status: str, action: any) {
    mode = lt["approval_mode"];
    retry_mode = mode[0:1].upper() + mode[1:];
    if status == "warning" {
        _emit(inst, lt, {"type": "runtime.error",
            "message": "Codex automatic review reported a timeout. Check what ran before retrying. Retry stays " + retry_mode + ". Select Ask for human approval in approval settings."});
        return;
    }
    command: any = None;
    if isinstance(action, dict) and action.get("type") == "command" {
        command = command_summary({"command": action.get("command")});
    }
    target = ': "' + command[0:30] + '"' if command else " for the requested action";
    outcome = "timed out" if status == "timedOut" else "denied";
    _emit(inst, lt, {"type": "runtime.error",
        "message": "Codex automatic review " + outcome + target + ". Action did not run. Retry stays " + retry_mode + ". Select Ask for human approval in approval settings."});
}

def _usage_shape(u: dict[str, any]) -> dict[str, any] {
    return {
        "input": u.get("inputTokens") if u.get("inputTokens") is not None else 0,
        "output": u.get("outputTokens") if u.get("outputTokens") is not None else 0,
        "cachedInput": u.get("cachedInputTokens") if u.get("cachedInputTokens") is not None else 0,
    };
}

def _is_number(value: any) -> bool {
    return isinstance(value, (int, float)) and not isinstance(value, bool);
}

def _handle_notification(inst: dict[str, any], lt: dict[str, any], a: dict[str, any], msg: dict[str, any]) {
    p: any = msg.get("params") if isinstance(msg.get("params"), dict) else {};
    method = msg.get("method");
    # An app-server also emits notifications for native helper threads: only
    # this request's parent may write its transcript/usage or settle it.
    connection_error = method == "error" and "threadId" not in p and "turnId" not in p;
    if not connection_error {
        if not a["codex_thread_id"] or p.get("threadId") != a["codex_thread_id"] { return; }
        token_usage = p.get("tokenUsage") if isinstance(p.get("tokenUsage"), dict) else {};
        if not a["codex_turn_id"] and method == "thread/tokenUsage/updated" and token_usage.get("total") {
            # A total reported before this turn exists is what the process
            # carried in — the baseline, never a reading to replay.
            t0 = token_usage["total"];
            a["usage_baseline"] = _usage_shape(t0 if isinstance(t0, dict) else {});
            return;
        }
        if not a["codex_turn_id"] {
            # Some servers stream before acknowledging turn/start: keep a
            # bounded prefix, filtered against the authoritative response.
            if a["starting_native_turn"] {
                if len(a["early"]) >= TOO_MANY_EARLY {
                    _settle(inst, lt, a, False, "too_many_events_before_turn_start");
                } else {
                    a["early"].append(msg);
                }
            }
            return;
        }
        event_turn_id: any = None;
        if method == "turn/started" or method == "turn/completed" {
            turn_rec = p.get("turn");
            event_turn_id = turn_rec.get("id") if isinstance(turn_rec, dict) else None;
        } else {
            event_turn_id = p.get("turnId");
        }
        # guardianWarning is thread-scoped (Codex 0.147); never admit a
        # mismatched turnId. A JSON null is not "absent".
        guardian_unscoped = method == "guardianWarning" and "turnId" not in p;
        if event_turn_id != a["codex_turn_id"] and not guardian_unscoped { return; }
    }
    if method == "guardianWarning" {
        message = p.get("message");
        if isinstance(message, str) and re.search(r"automatic approval review.*timed out", message, re.I) { a["review_warning"] = True; }
    } elif method == "item/autoApprovalReview/completed" {
        review = p.get("review") if isinstance(p.get("review"), dict) else {};
        status = review.get("status");
        if status != "timedOut" and status != "denied" { return; }
        review_id = p.get("reviewId");
        # Without a reviewId, distinct failures cannot be separated from
        # duplicate notifications.
        if not isinstance(review_id, str) or not review_id { return; }
        if review_id not in a["seen_reviews"] {
            a["seen_reviews"].add(review_id);
            if status == "timedOut" { a["timed_out_review"] = True; }
            _review_notice(inst, lt, status, p.get("action"));
        }
    } elif method == "item/agentMessage/delta" {
        delta = p.get("delta") if isinstance(p.get("delta"), str) else "";
        if delta {
            a["saw_stream_delta"] = True;
            _emit(inst, lt, {"type": "content.delta", "streamKind": "assistant_text", "delta": delta});
        }
    } elif method == "item/reasoning/textDelta" or method == "item/reasoning/summaryTextDelta" {
        delta2 = p.get("delta") if isinstance(p.get("delta"), str) else "";
        if delta2 { _emit(inst, lt, {"type": "content.delta", "streamKind": "reasoning_text", "delta": delta2}); }
    } elif method == "item/started" {
        item: any = p.get("item") if isinstance(p.get("item"), dict) else {};
        kind = item.get("type");
        title: any = None;
        if kind == "commandExecution" {
            title = str(item.get("command")) if item.get("command") is not None else "shell";
        } elif kind == "fileChange" {
            title = "edit";
        } elif kind == "mcpToolCall" {
            title = item.get("tool") or item.get("name") or "mcp";
        } elif kind == "webSearch" {
            title = "web_search";
        }
        if title {
            ev: dict[str, any] = {"type": "item.started", "itemType": "tool", "title": title};
            _set_if(ev, "itemId", item.get("id"));
            preview_source: any = item.get("query");
            if kind == "commandExecution" {
                _set_if(ev, "summary", command_summary({"command": item.get("command")}));
                preview_source = {"command": item.get("command"), "cwd": item.get("cwd")};
            } elif kind == "mcpToolCall" {
                preview_source = item.get("arguments");
            } elif kind == "fileChange" {
                preview_source = item.get("changes");
            }
            _set_if(ev, "input", tool_detail_preview(preview_source));
            _emit(inst, lt, ev);
        }
    } elif method == "item/completed" {
        item2: any = p.get("item") if isinstance(p.get("item"), dict) else {};
        kind2 = item2.get("type");
        if kind2 == "agentMessage" {
            text = item2.get("text");
            if isinstance(text, str) and text.strip() {
                a["last_text"] = text;
                if not a["saw_stream_delta"] {
                    _emit(inst, lt, {"type": "content.delta", "streamKind": "assistant_text", "delta": text});
                }
                a["saw_stream_delta"] = False;
                _emit(inst, lt, {"type": "item.completed", "itemType": "assistant_text", "text": text});
            }
        } elif kind2 == "imageGeneration" and item2.get("status") != "failed" {
            # Bytes, never the provider-owned savedPath.
            result = item2.get("result");
            if isinstance(result, str) and result.strip() {
                img: dict[str, any] = {"type": "item.completed", "itemType": "assistant_image", "data": result};
                _set_if(img, "itemId", item2.get("id"));
                if isinstance(item2.get("revisedPrompt"), str) { img["alt"] = item2["revisedPrompt"]; }
                _emit(inst, lt, img);
            }
        } elif kind2 in ["commandExecution", "fileChange", "mcpToolCall", "webSearch"] {
            output_source: any = item2.get("action");
            if kind2 == "commandExecution" {
                output_source = {"output": item2.get("aggregatedOutput"), "exitCode": item2.get("exitCode")};
            } elif kind2 == "mcpToolCall" {
                output_source = item2.get("error") if item2.get("error") is not None else item2.get("result");
            } elif kind2 == "fileChange" {
                output_source = item2.get("changes");
            }
            done: dict[str, any] = {"type": "item.completed", "itemType": "tool"};
            _set_if(done, "itemId", item2.get("id"));
            done["ok"] = item2.get("status") != "failed" and item2.get("status") != "declined";
            _set_if(done, "output", tool_detail_preview(output_source));
            _emit(inst, lt, done);
            if kind2 == "mcpToolCall" {
                for image in extract_mcp_images(item2.get("result")) {
                    _emit(inst, lt, {"type": "item.completed", "itemType": "assistant_image", "data": image["data"]});
                }
            }
        } elif kind2 == "reasoning" {
            _emit(inst, lt, {"type": "item.updated", "itemType": "reasoning", "tokens": None});
        }
    } elif method == "thread/tokenUsage/updated" {
        # `total` is the whole app-server process; this turn's figure is the
        # total minus what the process carried before turn/start.
        usage_rec: any = p.get("tokenUsage") if isinstance(p.get("tokenUsage"), dict) else {};
        t: any = usage_rec.get("total") if isinstance(usage_rec.get("total"), dict) else None;
        last: any = usage_rec.get("last") if isinstance(usage_rec.get("last"), dict) else None;
        if t is not None {
            b = a["usage_baseline"] if a["usage_baseline"] is not None else {"input": 0, "output": 0, "cachedInput": 0};
            now = _usage_shape(t);
            usage: dict[str, any] = {"input": max(0, now["input"] - b["input"]), "output": max(0, now["output"] - b["output"])};
            if _is_number(t.get("cachedInputTokens")) { usage["cachedInput"] = max(0, now["cachedInput"] - b["cachedInput"]); }
            a["usage"] = usage;
        } elif last is not None {
            usage2: dict[str, any] = {
                "input": last.get("inputTokens") if last.get("inputTokens") is not None else 0,
                "output": last.get("outputTokens") if last.get("outputTokens") is not None else 0,
            };
            if _is_number(last.get("cachedInputTokens")) { usage2["cachedInput"] = last["cachedInputTokens"]; }
            a["usage"] = usage2;
        }
        if t is not None {
            window = usage_rec.get("modelContextWindow");
            tev: dict[str, any] = {
                "type": "thread.token-usage.updated",
                "input": t.get("inputTokens") if t.get("inputTokens") is not None else 0,
                "output": t.get("outputTokens") if t.get("outputTokens") is not None else 0,
            };
            if _is_number(t.get("cachedInputTokens")) { tev["cachedInput"] = t["cachedInputTokens"]; }
            # the last call's prompt is what fills the window
            if last is not None and _is_number(last.get("inputTokens")) { tev["contextTokens"] = last["inputTokens"]; }
            if _is_number(window) and window > 0 { tev["contextWindow"] = window; }
            _emit(inst, lt, tev);
        }
    } elif method == "turn/completed" {
        if a["review_warning"] and not a["timed_out_review"] { _review_notice(inst, lt, "warning", None); }
        tc: any = p.get("turn") if isinstance(p.get("turn"), dict) else {};
        err: any = tc.get("error") if isinstance(tc.get("error"), dict) else {};
        message2 = codex_user_error(err["message"], lt["plan"]) if isinstance(err.get("message"), str) else "";
        status2 = tc.get("status");
        if status2 != "completed" and message2 and message2 != a["last_error"] {
            a["last_error"] = message2;
            rev: dict[str, any] = {"type": "runtime.error", "message": message2};
            if classify_error(message2)["reason"] == "auth" { rev["setup"] = True; }
            _emit(inst, lt, rev);
        }
        stop_reason: any = None;
        if status2 != "completed" {
            if classify_error(message2 or a["last_error"])["reason"] == "provider_safety" {
                stop_reason = "provider_safety";
            } else {
                stop_reason = message2 or status2 or "failed";
            }
        }
        _settle(inst, lt, a, status2 == "completed", stop_reason);
    } elif method == "error" {
        # shape drift: 0.144 sends {message}, 0.139 nests {error:{message}}
        nested = p.get("error") if isinstance(p.get("error"), dict) else {};
        raw_message = p.get("message") if p.get("message") is not None else nested.get("message");
        if raw_message {
            a["last_error"] = codex_user_error(str(raw_message), lt["plan"]);
            _emit(inst, lt, {"type": "runtime.error", "message": a["last_error"]});
        }
    }
}

# ── stdout / stderr / close ────────────────────────────────────────────────

def _handle_line(inst: dict[str, any], lt: dict[str, any], a: dict[str, any], line: str) {
    if not line.strip() { return; }
    try {
        msg = json.loads(line);
    } except Exception {
        return;
    }
    a["stderr_since_output"] = "";
    append_native(lt["thread_id"], "in", NATIVE_SOURCE, codex_native_incoming_log_message(msg, a["sensitive_ids"]));
    if not isinstance(msg, dict) { return; }
    has_id = "id" in msg;
    if has_id and ("result" in msg or "error" in msg) {
        _resolve_response(inst, lt, a, msg);
    } elif has_id and msg.get("method") {
        _handle_server_request(inst, lt, a, msg);
    } elif msg.get("method") {
        _handle_notification(inst, lt, a, msg);
    }
}

def _pump_stderr(a: dict[str, any]) {
    try {
        stream = a["proc"].stderr;
        while True {
            chunk = stream.read1(4096) if hasattr(stream, "read1") else stream.read(4096);
            if not chunk { break; }
            text = chunk.decode("utf-8", "replace");
            a["lock"].acquire();
            try {
                whole = a["stderr"] + text;
                a["stderr"] = whole[len(whole) - 8192:] if len(whole) > 8192 else whole;
                recent = a["stderr_since_output"] + text;
                a["stderr_since_output"] = recent[len(recent) - 2048:] if len(recent) > 2048 else recent;
            } finally {
                a["lock"].release();
            }
        }
    } except Exception {
    }
}

def _pump_stdout(inst: dict[str, any], lt: dict[str, any], a: dict[str, any]) {
    proc = a["proc"];
    try {
        for raw in iter(proc.stdout.readline, b"") {
            if a["abandoned"] or a["settled"] { continue; }
            line = raw.decode("utf-8", "replace");
            if line.endswith("\n") { line = line[0:len(line) - 1]; }
            try {
                _handle_line(inst, lt, a, line);
            } except Exception as e {
                print("codex (" + str(inst["instance_id"]) + "): line handler failed: " + str(e), file=sys.stderr);
            }
        }
    } except Exception {
    }
    # 'close' fires after stdio drains: stderr first, then the exit status.
    stderr_thread = a.get("stderr_thread");
    if stderr_thread is not None { stderr_thread.join(5.0); }
    rc = proc.wait();
    try {
        _on_close(inst, lt, a, rc);
    } except Exception as e {
        print("codex (" + str(inst["instance_id"]) + "): close handler failed: " + str(e), file=sys.stderr);
    }
}

def _signal_name(rc: any) -> any {
    if not isinstance(rc, int) or rc >= 0 { return None; }
    try {
        return signal.Signals(0 - rc).name;
    } except Exception {
        return "SIG" + str(0 - rc);
    }
}

def _on_close(inst: dict[str, any], lt: dict[str, any], a: dict[str, any], rc: any) {
    if a["abandoned"] { return; }
    if a["settled"] {
        # Root exit alone cannot release a turn after an uncertain stop;
        # recheck its group.
        _stop_attempt(inst, lt, a);
        return;
    }
    # An intentional stop killed (or outlived) the child before the turn
    # acknowledged its own end: settle quietly, never report the signal.
    if lt["stop_requested"] {
        _settle(inst, lt, a, False, "interrupted");
        return;
    }
    sig = _signal_name(rc);
    code: any = None if sig is not None else rc;
    # Only stderr after the last protocol message can explain an exit.
    recent = a["stderr_since_output"].strip();
    had_streamed = a["codex_turn_id"] is not None or a["saw_stream_delta"];
    verdict: dict[str, any] = {"transient": False, "reason": "interrupted"};
    if sig is None { verdict = classify_error(recent, code); }
    # Safe re-dispatch: only when the app-server never acknowledged
    # turn/start and nothing was buffered — a replay cannot duplicate work.
    if not lt["stop_requested"] and a["codex_turn_id"] is None and len(a["early"]) == 0 and verdict["transient"] and a["attempt"] < RETRY_MAX_ATTEMPTS - 1 {
        delay_ms = compute_backoff(a["attempt"]);
        next_attempt = a["attempt"] + 1;
        _emit(inst, lt, {"type": "turn.retrying", "attempt": next_attempt, "delayMs": delay_ms, "reason": verdict["reason"]});
        # Retire this attempt before anything else runs.
        a["abandoned"] = True;

        def relaunch() {
            if _proc_alive(a) and not _terminate(a) {
                _settle(inst, lt, a, False, "shutdown_timeout");
                return;
            }
            _backoff_then_relaunch(inst, lt, a, next_attempt, delay_ms);
        }
        threading.Thread(target=relaunch, daemon=True).start();
        return;
    }
    detail = "";
    if recent {
        detail = ": " + recent[len(recent) - 300:] if len(recent) > 300 else ": " + recent;
    } elif had_streamed and a["stderr"].strip() {
        detail = "; no stderr after the last app-server output";
    }
    code_text = "null" if code is None else str(code);
    sig_text = " (signal " + sig + ")" if sig is not None else "";
    _emit(inst, lt, {"type": "runtime.error", "message": "codex exited " + code_text + sig_text + " before turn/completed" + detail});
    _settle(inst, lt, a, False, "exit_before_result");
}

def _backoff_then_relaunch(inst: dict[str, any], lt: dict[str, any], a: dict[str, any], next_attempt: int, delay_ms: int) {
    # Stop wakes the backoff at once, so the turn settles now.
    wait_ms = max(1, round(delay_ms * env_scale("FAKE_CODEX_RETRY_SCALE")));
    lt["stop_event"].wait(wait_ms / 1000.0);
    if not lt["stop_requested"] {
        try {
            _launch_attempt(inst, lt, next_attempt);
        } except Exception {
        }
    } else {
        _settle(inst, lt, a, False, "interrupted");
    }
}

# ── launch ─────────────────────────────────────────────────────────────────

def _new_attempt(lt: dict[str, any], attempt: int) -> dict[str, any] {
    ks: dict[str, any] = {"lock": threading.RLock(), "event": threading.Event(), "running": False, "result": None};
    return {
        "thread_id": lt["thread_id"],
        "attempt": attempt,
        "proc": None,
        "kill_state": ks,
        "lock": threading.RLock(),
        "write_lock": threading.Lock(),
        "abandoned": False,
        "settled": False,
        "codex_thread_id": None,
        "codex_turn_id": None,
        "starting_native_turn": False,
        "early": [],
        "last_error": "",
        "last_text": "",
        "saw_stream_delta": False,
        "usage": None,
        "usage_baseline": None,
        "asks": {},
        "next_id": 1,
        "sensitive_ids": set(),
        "pending": {},
        "stderr": "",
        "stderr_since_output": "",
        "interrupt_requested": False,
        "complete": None,
        "settle_ready": threading.Event(),
        "completing": False,
        "completed": threading.Event(),
        "seen_reviews": set(),
        "review_warning": False,
        "timed_out_review": False,
        "spawn_error": None,
        "stderr_thread": None,
    };
}

# Synchronous half of launchAttempt: argv + env, spawn, live registration,
# turn.started. The handshake then runs on its own thread.
def _launch_attempt(inst: dict[str, any], lt: dict[str, any], attempt: int) {
    config = _config(inst);
    turn = lt["turn"];
    thread_id = lt["thread_id"];
    scope = turn.get("toolScope");
    scoped = scope is not None;
    integrations: any = turn.get("integrations") if isinstance(turn.get("integrations"), dict) else {};
    env = child_env(inst);
    if lt["plan_token"] { env["OPENMAUSBOT_CHATGPT_TOKEN"] = lt["plan_token"]; }
    managed = _managed(config);
    args: list[any] = ["app-server"];
    if lt["plan"] {
        args.extend(chatgpt_plan_codex_args());
    } elif managed is not None {
        args.extend(managed_codex_args(managed));
    } else {
        args.extend(codex_local_provider_args(env, turn.get("model")));
    }
    args.extend(codex_tool_surface_args());
    # Native snapshots can restore inherited variables after the shell policy
    # filtered them; scoped MCP gate settings must stay private.
    if scoped { args.extend(["-c", "features.shell_snapshot=false"]); }
    # A guest-driven turn: no shell and no file reads, whatever the
    # person's own config says (-c wins over config files).
    if turn.get("guestConfined") { args.extend(GUEST_CONFINED_CODEX_ARGS); }
    selected_mcp: dict[str, any] = {};
    selected_approvals: dict[str, any] = {};

    def scoped_server(name: str, mount_name: str, server: any) -> any {
        if not can_use_mcp_server(scope, name) { return None; }
        if not scoped { return server; }
        return codex_gate_server(name, server, thread_id, 0, scope, {"ELECTRON_RUN_AS_NODE": "1"}, "OMB_GATE_CONFIG_" + sha256_hex(mount_name));
    }

    def mount_selected(name: str, mount_name: str, server: any, pre_approved: bool = True) {
        selected = scoped_server(name, mount_name, server);
        if selected is not None {
            selected_mcp[mount_name] = selected;
            selected_approvals[mount_name] = pre_approved;
            mount_mcp_server(args, env, mount_name, selected, pre_approved);
            if scoped and not pre_approved {
                args.extend(["-c", "mcp_servers." + mount_name + '.default_tools_approval_mode="prompt"']);
            }
        }
    }
    if integrations.get("composio") { mount_selected("composio", "openmausbot_connectors", integrations["composio"]); }
    if integrations.get("agents") { mount_selected("agents", "agents", integrations["agents"]); }
    # The host daemon and the isolated Local VM both arrive as a direct Cua
    # Driver stdio MCP server.
    if integrations.get("localComputer") { mount_selected("computer", "computer", integrations["localComputer"]); }
    if integrations.get("browser") { mount_selected("browser", "browser", integrations["browser"]); }
    # A custom server named like one in the user's own config.toml would be
    # merged with it by the -c override; it mounts under a name of its own.
    declared = codex_config_mcp_server_names(env);
    if scoped {
        for name in declared { args.extend(["-c", "mcp_servers." + name + ".enabled=false"]); }
    }
    custom: any = integrations.get("custom") if isinstance(integrations.get("custom"), dict) else {};
    for (cname, server) in custom.items() {
        # codex speaks streamable HTTP, not the older SSE transport.
        if not scoped and isinstance(server, dict) and "url" in server and server.get("type") == "sse" {
            _note_once("sse", cname, "codex: MCP server " + js(cname) + " uses the SSE transport, which codex does not speak — it is available to Claude bots only");
            continue;
        }
        mount_name = mounted_mcp_server_name(cname, declared);
        if mount_name != cname {
            _note_once("renamed", cname, "codex: MCP server " + js(cname) + " is also declared in Codex's own config.toml — mounted as " + js(mount_name) + " for this bot so the two do not merge");
        }
        mount_selected(cname, mount_name, server, False);
    }
    phone = integrations.get("phone");
    if phone {
        if scoped {
            mount_selected("phone", "openmausbot_phone", phone);
        } else {
            phone_env: any = phone.get("env") if isinstance(phone.get("env"), dict) else {};
            for (key, value) in phone_env.items() { env[key] = value; }
            prefix = "mcp_servers.openmausbot_phone";
            args.extend([
                "-c", prefix + ".command=" + js(phone.get("command")),
                "-c", prefix + ".args=" + js(phone.get("args") or []),
                "-c", prefix + ".env_vars=" + js(list(phone_env.keys())),
                "-c", prefix + '.default_tools_approval_mode="auto"',
            ]);
        }
    }
    selection_config: dict[str, any] = {};
    if scoped {
        servers: dict[str, any] = {};
        for (mname, spec) in selected_mcp.items() {
            if isinstance(spec, dict) and "command" in spec {
                spec_env: any = spec.get("env") if isinstance(spec.get("env"), dict) else {};
                servers[mname] = {
                    "command": spec.get("command"),
                    "args": spec.get("args"),
                    "env_vars": list(spec_env.keys()),
                    "env": {},
                    "default_tools_approval_mode": "auto" if selected_approvals.get(mname) else "prompt",
                };
            } else {
                servers[mname] = {};
            }
        }
        selection_config = {"config": {"mcp_servers": servers}};
    }
    cwd = turn.get("cwd") or os.path.expanduser("~");
    lt["cwd"] = cwd;
    lt["command_cwd"] = permission_launch_cwd(cwd);
    a = _new_attempt(lt, attempt);
    a["selected_mcp"] = selected_mcp;
    a["selected_approvals"] = selected_approvals;
    a["selection_config"] = selection_config;
    cli: str = config["cli"] if isinstance(config.get("cli"), str) else "codex";
    try {
        a["proc"] = subprocess.Popen(
            _resolve_cli(cli) + args,
            cwd=cwd,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            start_new_session=(os.name != "nt")
        );
    } except Exception as e {
        a["spawn_error"] = e;
    }
    if a["proc"] is not None {
        t_err = threading.Thread(target=_pump_stderr, args=(a,), daemon=True);
        a["stderr_thread"] = t_err;
        t_err.start();
        threading.Thread(target=_pump_stdout, args=(inst, lt, a), daemon=True).start();
    }
    lock = inst["codex_lock"];
    lock.acquire();
    try {
        inst["live"][thread_id] = {"turn_id": lt["turn_id"], "attempt": a, "lt": lt};
    } finally {
        lock.release();
    }
    lt["current"] = a;
    # A relaunch is the same logical turn: announce it once.
    if attempt == 0 { _emit(inst, lt, {"type": "turn.started"}); }
    threading.Thread(target=_handshake_guarded, args=(inst, lt, a), daemon=True).start();
}

def _handshake_guarded(inst: dict[str, any], lt: dict[str, any], a: dict[str, any]) {
    # A thread that dies silently would strand the turn: always report.
    try {
        _handshake(inst, lt, a);
    } except Exception as e {
        import traceback;
        print("codex (" + str(inst["instance_id"]) + "): handshake thread failed: " + traceback.format_exc(), file=sys.stderr);
        try {
            _handshake_failed(inst, lt, a, e);
        } except Exception {
        }
    }
}

def _start_or_resume(a: dict[str, any], method: str, params: dict[str, any], approval: dict[str, any]) -> dict[str, any] {
    # Older servers may require the legacy permission selector; retry once
    # with the fallback before any user submission. Returns {result, approval}.
    merged = dict(params);
    merged.update(approval["thread"]);
    try {
        return {"result": _request(a, method, merged), "approval": approval};
    } except Exception as e {
        if approval.get("fallback") is None or not permission_profile_unsupported(e) { raise e; }
    }
    fallback = approval["fallback"];
    merged2 = dict(params);
    merged2.update(fallback["thread"]);
    return {"result": _request(a, method, merged2), "approval": fallback};
}

def _handshake(inst: dict[str, any], lt: dict[str, any], a: dict[str, any]) {
    config = _config(inst);
    turn = lt["turn"];
    thread_id = lt["thread_id"];
    if a["spawn_error"] is not None {
        cli_name: str = config["cli"] if isinstance(config.get("cli"), str) else "codex";
        failure = _describe_spawn_failure(a["spawn_error"], cli_name);
        _emit(inst, lt, {"type": "runtime.error", "message": failure["message"], "setup": failure["setup"]});
        _settle(inst, lt, a, False, "spawn_error");
        return;
    }
    scoped = turn.get("toolScope") is not None;
    managed = _managed(config);
    cwd = lt["cwd"];
    try {
        _request(a, "initialize", {
            "clientInfo": {"name": "openmausbot", "title": "OpenMausBot", "version": server_version()},
            # Named permission profiles are an experimental app-server field
            # in Codex 0.151; older servers ignore the capability.
            "capabilities": {"experimentalApi": True},
        });
        _send(a, {"jsonrpc": "2.0", "method": "initialized", "params": {}});
        # developerInstructions replaces native config: read it for every
        # approval mode so existing rules survive.
        effective_config: any = None;
        try {
            configured = _request(a, "config/read", {"cwd": cwd, "includeLayers": False});
            effective_config = configured.get("config") if isinstance(configured, dict) else None;
        } except Exception as e {
            invalid = is_rpc_error(e) and re.match(r"^invalid configuration\b", error_message(e), re.I) is not None;
            if invalid {
                raise RuntimeError("Codex rejected its configuration as invalid. Check ~/.codex/config.toml (or CODEX_HOME) for a broken entry, then retry.");
            }
            raise RuntimeError("Could not read Codex configuration; cannot safely update bot instructions. Retry after checking Codex.");
        }
        effective: any = effective_config if isinstance(effective_config, dict) else {};
        selection_config = a["selection_config"];
        if scoped {
            features: any = effective.get("features") if isinstance(effective.get("features"), dict) else {};
            if features.get("shell_snapshot") is not False {
                raise RuntimeError("Codex could not disable inherited shell snapshots. No prompt was sent.");
            }
            # Gate descriptors belong to MCP children, never native shell
            # tools: extend the effective exclusions for new and resumed threads.
            has_policy = "shell_environment_policy" in effective;
            raw_policy = effective.get("shell_environment_policy");
            if has_policy and not isinstance(raw_policy, dict) {
                raise RuntimeError("Codex could not confirm its shell environment policy. No prompt was sent.");
            }
            policy: any = raw_policy if isinstance(raw_policy, dict) else {};
            excluded: any = policy.get("exclude") if "exclude" in policy else [];
            if not isinstance(excluded, list) {
                raise RuntimeError("Codex could not confirm its shell environment exclusions. No prompt was sent.");
            }
            for name in excluded {
                if not isinstance(name, str) {
                    raise RuntimeError("Codex could not confirm its shell environment exclusions. No prompt was sent.");
                }
            }
            merged_excludes: list[any] = [];
            for name in excluded + ["OMB_GATE_CONFIG_*"] {
                if name not in merged_excludes { merged_excludes.append(name); }
            }
            selection_config["config"]["shell_environment_policy.exclude"] = merged_excludes;
            catalog = effective.get("mcp_servers");
            if not isinstance(catalog, dict) {
                raise RuntimeError("Codex could not confirm its selected MCP configuration. No prompt was sent.");
            }
            for (mname, cat_entry) in catalog.items() {
                if isinstance(cat_entry, dict) and cat_entry.get("enabled") is False { continue; }
                expected = a["selected_mcp"].get(mname);
                actual: any = cat_entry if isinstance(cat_entry, dict) else {};
                bad = expected is None or not isinstance(expected, dict) or "command" not in expected or actual.get("command") != expected.get("command");
                if not bad {
                    expected_env: any = expected.get("env") if isinstance(expected.get("env"), dict) else {};
                    actual_env = actual.get("env");
                    actual_tools = actual.get("tools");
                    bad = js(actual.get("args") if actual.get("args") is not None else []) != js(expected.get("args") if expected.get("args") is not None else [])
                        or not isinstance(actual.get("env_vars"), list)
                        or js(sorted([str(v) for v in actual.get("env_vars") or []])) != js(sorted(list(expected_env.keys())))
                        or actual.get("default_tools_approval_mode") != ("auto" if a["selected_approvals"].get(mname) else "prompt")
                        or (actual_env is not None and (not isinstance(actual_env, dict) or len(actual_env) > 0))
                        or (actual_tools is not None and (not isinstance(actual_tools, dict) or len(actual_tools) > 0));
                }
                if bad {
                    raise RuntimeError("Codex has an MCP server outside the selected configuration. Disable native MCP entries for this account before using tool selection. No prompt was sent.");
                }
            }
        }
        # Proven before the turn starts: a Codex that did not take the
        # overrides runs nothing for a guest.
        if turn.get("guestConfined") and not codex_shell_disabled(effective_config) {
            why = turn.get("confinedWhy");
            raise RuntimeError("This Codex could not turn its shell off, so it can't run this turn. Update Codex, or switch this bot to Claude." + (" " + why if why else ""));
        }
        # Only the stable half belongs in the developer slot; the volatile
        # half rides the turn that changed it.
        prompt_split = isinstance(turn.get("systemStable"), str) and isinstance(turn.get("systemVolatile"), str);
        stable = turn["systemStable"] if prompt_split else (turn.get("system") or "");
        developer_instructions = codex_developer_instructions(effective_config, stable);
        approval: dict[str, any] = custom_approval_params(effective_config) if lt["approval_mode"] == "custom" else named_approval_params(lt["approval_mode"]);
        # Codex's `never` is not "grant everything": only explicit Full may
        # synthesize approvals.
        lt["auto_accept"] = lt["approval_mode"] == "full";
        selection: dict[str, any] = {};
        if managed is not None {
            selection = {"model": turn.get("model"), "modelProvider": "openmaus_company"};
        } elif lt["plan"] {
            selection = {"model": turn.get("model"), "modelProvider": "openai_chatgpt_plan"};
        } else {
            selection = decode_codex_selection(turn.get("model"));
        }
        cursor = turn.get("resumeCursor") if isinstance(turn.get("resumeCursor"), str) and turn.get("resumeCursor") else None;
        started_model: any = None;
        resumed_native_thread = False;
        rebuilt_from_replay = False;
        prompt_text = turn.get("text") or "";
        if cursor is not None {
            resume_params: dict[str, any] = dict(selection_config);
            resume_params["threadId"] = cursor;
            resume_params["developerInstructions"] = developer_instructions;
            resume_params["model"] = selection.get("model");
            if selection.get("modelProvider") { resume_params["modelProvider"] = selection["modelProvider"]; }
            try {
                outcome = _start_or_resume(a, "thread/resume", resume_params, approval);
                approval = with_resolved_sandbox(outcome["approval"], outcome["result"]);
                resumed: any = outcome["result"] if isinstance(outcome["result"], dict) else {};
                resumed_thread: any = resumed.get("thread") if isinstance(resumed.get("thread"), dict) else {};
                a["codex_thread_id"] = resumed_thread.get("id") or cursor;
                resumed_native_thread = True;
            } except Exception as e {
                failure_kind = classify_resume_failure(True, is_rpc_error(e), lt["prompt_submitted"], a["saw_stream_delta"]);
                recovery_text = turn.get("recoveryText");
                if (managed is None and not turn.get("recoveryIsReplay")) or lt["recovered_missing_session"] or lt["stop_requested"] or a["settled"] or not (isinstance(recovery_text, str) and recovery_text.strip()) or not missing_native_codex_thread(e, cursor) or not may_replay(failure_kind) {
                    raise e;
                }
                # The prompt was never submitted: rebuild once, through the
                # same approved model/provider below.
                lt["recovered_missing_session"] = True;
                rebuild = recovery_prompt_for(recovery_text, turn.get("text") or "", failure_kind);
                rebuilt_from_replay = rebuild["replayed"];
                prompt_text = rebuild["text"];
            }
        }
        if not a["codex_thread_id"] {
            start_params: dict[str, any] = dict(selection_config);
            start_params["developerInstructions"] = developer_instructions;
            start_params["cwd"] = cwd;
            start_params["model"] = selection.get("model");
            if selection.get("modelProvider") { start_params["modelProvider"] = selection["modelProvider"]; }
            if turn.get("guestConfined") { start_params["environments"] = []; }
            start_params["ephemeral"] = False;
            started = _start_or_resume(a, "thread/start", start_params, approval);
            approval = with_resolved_sandbox(started["approval"], started["result"]);
            started_rec: any = started["result"] if isinstance(started["result"], dict) else {};
            started_thread: any = started_rec.get("thread") if isinstance(started_rec.get("thread"), dict) else {};
            a["codex_thread_id"] = started_thread.get("id");
            started_model = started_rec.get("model");
        }
        if not a["codex_thread_id"] { raise RuntimeError("Codex did not return a native thread id"); }

        def rpc(method: str, params: any) -> any {
            return _request(a, method, params);
        }
        volatile = (turn.get("systemVolatile") or "") if prompt_split else "";
        synced = sync_codex_instructions(thread_id, a["codex_thread_id"], developer_instructions, volatile, resumed_native_thread, rpc, bool(turn.get("mentionTurn")));
        # A changed volatile half rides the next user input as a labelled
        # context block, never the developer slot.
        if synced["deliver_volatile"] {
            prompt_text = with_context_note(volatile_context_note(volatile, synced["had_volatile"]), prompt_text);
        }
        session_ev: dict[str, any] = {"type": "session.started", "sessionId": a["codex_thread_id"], "model": started_model or turn.get("model") or None};
        if rebuilt_from_replay { session_ev["rebuilt"] = True; }
        _emit(inst, lt, session_ev);
        turn_input: list[any] = [];
        if prompt_text { turn_input.append({"type": "text", "text": prompt_text}); }
        images: any = turn.get("images") if isinstance(turn.get("images"), list) else [];
        for image in images {
            turn_input.append({"type": "localImage", "path": image.get("path") if isinstance(image, dict) else None});
        }

        def start_turn(params_approval: dict[str, any]) -> any {
            lt["prompt_submitted"] = True;
            a["starting_native_turn"] = True;
            turn_params: dict[str, any] = {"threadId": a["codex_thread_id"], "input": turn_input};
            turn_params.update(params_approval["turn"]);
            # No environment: no exec_command, apply_patch or view_image.
            if turn.get("guestConfined") { turn_params["environments"] = []; }
            # Spread, not null: null leaves the thread's effort alone.
            if turn.get("effort") { turn_params["effort"] = turn["effort"]; }
            return _request(a, "turn/start", turn_params);
        }
        try {
            start_turn(approval);
        } except Exception as e {
            if approval.get("fallback") is None or not permission_profile_unsupported(e) { raise e; }
            approval = approval["fallback"];
            start_turn(approval);
        }
        # turn/start accepted the input: only now may the receipt claim the
        # volatile half was delivered.
        commit = synced["commit_volatile"];
        if commit is not None { commit(); }
    } except Exception as e {
        _handshake_failed(inst, lt, a, e);
    }
}

def _handshake_failed(inst: dict[str, any], lt: dict[str, any], a: dict[str, any], e: any) {
    message = codex_user_error(error_message(e), lt["plan"]);
    needs_auth = re.search(r"(?:\b401\b|unauthorized|missing bearer|authentication required)", message, re.I) is not None;
    verdict = classify_error(error_message(e));
    # main's abandoned attempt never retries, nor does a session already
    # recovered once from canonical history, nor a turn Stop already asked
    # to end.
    if not a["settled"] and not a["abandoned"] and not lt["recovered_missing_session"] and not lt["stop_requested"] and not needs_auth and verdict["transient"] and a["attempt"] < RETRY_MAX_ATTEMPTS - 1 and a["saw_stream_delta"] is False {
        delay_ms = compute_backoff(a["attempt"]);
        next_attempt = a["attempt"] + 1;
        _emit(inst, lt, {"type": "turn.retrying", "attempt": next_attempt, "delayMs": delay_ms, "reason": verdict["reason"]});
        # This app-server never exits by itself: retire it and silence its
        # late handlers before the replacement launches.
        a["abandoned"] = True;
        if not _terminate(a) {
            _settle(inst, lt, a, False, "shutdown_timeout");
            return;
        }
        _backoff_then_relaunch(inst, lt, a, next_attempt, delay_ms);
        return;
    }
    # abandoned marks an attempt retired by a retry: its late rpc timeouts
    # must neither report a spurious error nor relaunch again.
    if not a["settled"] and not a["abandoned"] {
        ev: dict[str, any] = {"type": "runtime.error", "message": message};
        if needs_auth { ev["setup"] = True; }
        _emit(inst, lt, ev);
        reason = "rpc_error";
        if needs_auth {
            reason = "auth_required";
        } elif verdict["reason"] == "provider_safety" {
            reason = "provider_safety";
        }
        _settle(inst, lt, a, False, reason);
    }
}

# ── ops ────────────────────────────────────────────────────────────────────

def _op_send_turn(inst: dict[str, any], raw_turn: dict[str, any]) -> str {
    config = _config(inst);
    turn: dict[str, any] = dict(raw_turn);
    context: any = turn.pop("_jac", None);
    if not isinstance(context, dict) { context = {}; }
    turn["toolScope"] = assert_tool_scope_supported(DRIVER_KIND, turn.get("toolScope"));
    plan = _is_plan(config);
    managed = _managed(config);
    if plan {
        # The node half (prepareJacTurn) owns sign-in, catalog and the plan
        # generation checks; it hands over the access token per turn.
        if not context.get("planToken") {
            raise RuntimeError("The ChatGPT account changed while this message was preparing. Select a connected account and send again.");
        }
        os.makedirs(plan_codex_home(inst["instance_id"]), mode=0o700, exist_ok=True);
    }
    if managed is not None {
        # Name the broken prerequisite instead of one blanket refusal.
        model = turn.get("model");
        models: any = managed.get("models") if isinstance(managed.get("models"), list) else [];
        instance_env = _instance_env(inst);
        if not model {
            raise RuntimeError("Company model access is unavailable: no model is selected. Reconnect your organization; personal billing will not be used.");
        }
        if model not in models {
            raise RuntimeError("Company model access is unavailable: " + str(model) + " is not approved for your organization. Reconnect your organization; personal billing will not be used.");
        }
        if not instance_env.get("OPENMAUSBOT_COMPANY_API_KEY") {
            raise RuntimeError("Company model access is unavailable: OPENMAUSBOT_COMPANY_API_KEY is missing. Reconnect your organization; personal billing will not be used.");
        }
        if not instance_env.get("CODEX_HOME") {
            raise RuntimeError("Company model access is unavailable: CODEX_HOME is missing. Reconnect your organization; personal billing will not be used.");
        }
    }
    thread_id = turn["threadId"];
    # Direct adapter callers predating the per-bot selector keep the
    # instance's legacy fullAuto; harness turns always send a mode.
    approval_mode = turn.get("approvalMode");
    if not isinstance(approval_mode, str) or not approval_mode {
        approval_mode = "full" if config.get("fullAuto") is True else "ask";
    }
    integrations: any = turn.get("integrations") if isinstance(turn.get("integrations"), dict) else {};
    custom: any = integrations.get("custom") if isinstance(integrations.get("custom"), dict) else {};
    for (name, server) in custom.items() {
        if not isinstance(server, dict) or "url" in server { continue; }
        server_env: any = server.get("env") if isinstance(server.get("env"), dict) else {};
        for key in server_env.keys() {
            if is_harness_owned_mcp_env_name(key) {
                raise RuntimeError("Custom MCP server “" + name + "” cannot set reserved environment variable “" + key + "”");
            }
        }
    }
    lock = inst["codex_lock"];
    lock.acquire();
    try {
        if thread_id in inst["live"] { raise RuntimeError("a turn is already running on this thread"); }
        turn_id = str(uuid.uuid4());
        local_computer = integrations.get("localComputer");
        lt: dict[str, any] = {
            "thread_id": thread_id,
            "turn_id": turn_id,
            "turn": turn,
            "plan": plan,
            "plan_token": context.get("planToken"),
            "approval_mode": approval_mode,
            "auto_accept": approval_mode == "full",
            "controls_host": isinstance(local_computer, dict) and local_computer.get("scope") == "local-computer",
            "stop_requested": False,
            "stop_event": threading.Event(),
            "prompt_submitted": False,
            "recovered_missing_session": False,
            "current": None,
            "cwd": None,
            "command_cwd": None,
        };
        # Reserve the thread while the launch sets up: the TS check-then-set
        # is atomic on one event loop; here a placeholder keeps it so.
        inst["live"][thread_id] = {"turn_id": turn_id, "attempt": None, "lt": lt};
    } finally {
        lock.release();
    }
    try {
        _launch_attempt(inst, lt, 0);
    } except Exception as e {
        # codex.ts runs launchAttempt detached (`.catch(() => {})`): a setup
        # throw surfaces nowhere. Keep that contract, but release the thread.
        lock.acquire();
        try {
            cur = inst["live"].get(thread_id);
            if cur is not None and cur.get("attempt") is None { inst["live"].pop(thread_id, None); }
        } finally {
            lock.release();
        }
        print("codex (" + str(inst["instance_id"]) + "): launch failed: " + str(e), file=sys.stderr);
    }
    return turn_id;
}

def _live(inst: dict[str, any], thread_id: any) -> any {
    lock = inst["codex_lock"];
    lock.acquire();
    try {
        return inst["live"].get(thread_id);
    } finally {
        lock.release();
    }
}

def _op_interrupt(inst: dict[str, any], thread_id: any, turn_id: any) {
    live = _live(inst, thread_id);
    if live is None or live.get("attempt") is None { return; }
    _stop_attempt(inst, live["lt"], live["attempt"]);
}

def _op_steer(inst: dict[str, any], thread_id: any, text: any) -> str {
    live = _live(inst, thread_id);
    if live is None or live.get("attempt") is None { return "refused"; }
    return _steer_attempt(live["lt"], live["attempt"], text if isinstance(text, str) else "");
}

def _op_respond(inst: dict[str, any], thread_id: any, request_id: any, decision: dict[str, any]) -> str {
    live = _live(inst, thread_id);
    if live is None or live.get("attempt") is None { return "unavailable"; }
    finish = live["attempt"]["asks"].get(request_id);
    # settled, timed out, or turn gone
    if finish is None { return "unavailable"; }
    behavior = decision.get("behavior");
    finish(behavior, decision.get("message"), "user");
    if behavior == "allow" { return "allowed-once"; }
    if behavior == "answer" { return "answered"; }
    return "rejected";
}

def _stop_everything(inst: dict[str, any]) {
    lock = inst["codex_lock"];
    lock.acquire();
    try {
        lives = [live for live in inst["live"].values() if live.get("attempt") is not None];
    } finally {
        lock.release();
    }
    workers: list[any] = [];
    for live in lives {
        worker = threading.Thread(target=_stop_attempt, args=(inst, live["lt"], live["attempt"]), daemon=True);
        worker.start();
        workers.append(worker);
    }
    for worker in workers { worker.join(); }
}

def _op_stop_all(inst: dict[str, any]) { _stop_everything(inst); }

def _op_dispose(inst: dict[str, any]) { _stop_everything(inst); }

# ── registration ───────────────────────────────────────────────────────────

with entry {
    driver_register_kind(DRIVER_KIND, {
        "create": _create,
        "send_turn": _op_send_turn,
        "interrupt_turn": _op_interrupt,
        "respond": _op_respond,
        "steer": _op_steer,
        "stop_all": _op_stop_all,
        "dispose": _op_dispose,
    });
}
