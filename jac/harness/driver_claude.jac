"""Claude driver — the Jac port of server/drivers/claude.ts (kind
claudeAgent). Per-thread CLI process kept warm across turns under
--input-format stream-json: the prompt goes in over stdin as one stream-json
message, a turn settles on the CLI's real `result` frame, and the
conversation continues later via --resume <sessionId>. Integrations become
MCP servers in a 0600 config file the CLI reads once; a per-turn permission
broker (driver_claude_broker.jac) answers the spawned permission proxy.

The node shim (server/jac-drivers.ts) forwards the adapter surface here over
the serialized op queue and decodes config; events travel back through
drivers.emit_event as bridge op driver_event."""

import os;
import json;
import re;
import time;
import threading;
import subprocess;
import signal;
import shutil;
import sys;
import tempfile;
import hashlib;

import from drivers { emit_event, driver_register_kind }
import from driver_claude_broker { create_permission_broker }
import from driver_claude_support {
    new_uuid, parse_version_triple, version_at_least, claude_cli_supports,
    CLAUDE_REPLAY_FLOOR, auto_compact_window, 
    resolve_claude_turn_model, apply_claude_inject, CLAUDE_ACCOUNT_ENV_KEYS,
    strip_workspace_credential_env, resolve_claude_config_dir, inherits_user_config,
    read_claude_auth_settings, augmented_path, user_home, resolve_proxy, node_exec_path,
    NODE_ENV_FLAG, GUEST_CLAUDE_TOOLS, GUEST_FORBIDDEN_TOOLS, GUEST_CLAUDE_PERMISSIONS,
    with_why, assert_tool_scope_supported, can_use_mcp_server, gate_server, result_budget,
    ASK_USER_QUESTION_TOOL, parse_ask_questions, ask_question_summary,
    question_choices, parse_choices, command_summary, ask_input_summary, tool_detail_preview,
    RETRY_MAX_ATTEMPTS, compute_backoff, classify_error, session_idle_policy,
    turn_cost_from_running_total, claude_cost_snapshot, restored_cost_base,
    read_cost_history, record_cost_state, sum_native_turn_results,
    classify_resume_failure, may_replay, recovery_prompt_for,
    claude_auth_failure, claude_version_too_old, first_text, with_volatile_note,
    claude_user_message, extract_mcp_images,
    hook_token_file, claude_hook_settings, permission_socket_path,
    broker_socket_candidates, project_mcp_servers,
}
glob NO_ANTHROPIC_KEY: str = "No Anthropic API key — open Settings → API keys.";

glob STEERED_CONTINUATION_GRACE_MS: int = 2000;

glob STEERED_CONTINUATION_SILENCE_MS: int = 30000;

glob PROC_KILL_GRACE_MS: int = 5000;

glob PROBE_TIMEOUT_S: float = 8.0;

glob REVIEW_TIMEOUT_S: float = 60.0;

def _fake_timer_scale(name: str) -> float {
    raw = os.environ.get(name);
    if not raw { return 1.0; }
    try {
        value = float(raw);
    } except Exception {
        return 1.0;
    }
    return value if value else 1.0;
}

# ── per-instance state ─────────────────────────────────────────────────────

def _create(inst: dict[str, any]) {
    st: dict[str, any] = {
        "cli_version": None,
        "cli_version_checked": False,
        "cli_has_autocompact": None,
    };
    inst["claude_state"] = st;
    inst["retry_state"] = {};
    policy = session_idle_policy("CLAUDE", dict(os.environ));
    inst["idle_ms"] = policy["idle_ms"];
    if inherits_user_config(dict(os.environ)) {
        print("claude (" + str(inst["instance_id"]) + "): OMB_CLAUDE_INHERIT_USER_CONFIG=1 — bots inherit this machine's Claude Code MCP servers, skills, hooks and CLAUDE.md on every turn; remove it unless a bot needs a user-scope server", file=sys.stderr);
    }
}

def _config(inst: dict[str, any]) -> dict[str, any] {
    return inst["config"] if isinstance(inst.get("config"), dict) else {};
}

def _permission_mode_for(config: dict[str, any], turn: dict[str, any]) -> str {
    # A bot-level mode is authoritative for this turn: an old provider
    # instance may still be configured with bypassPermissions; Ask/Auto must
    # restore Claude's interactive broker instead of inheriting that bypass.
    approval = turn.get("approvalMode");
    if approval is None { return config.get("permissionMode") or "acceptEdits"; }
    if approval == "full" { return "bypassPermissions"; }
    if approval == "auto" { return "auto"; }
    if approval == "edits" { return "acceptEdits"; }
    return "default";
}

def _claude_environment(inst: dict[str, any], model: any) -> dict[str, any] {
    # The CLI environment shared by auth probes and real turns: the harness
    # process's env plus the instance's, minus this session's identity and
    # workspace credentials. Returns {env, injected, model}.
    config = _config(inst);
    instance_env: any = inst["environment"] if isinstance(inst.get("environment"), dict) else {};
    env: dict[str, any] = dict(os.environ);
    for (key, value) in instance_env.items() {
        if value is not None { env[key] = value if isinstance(value, str) else str(value); }
    }
    env["PATH"] = augmented_path(env);
    env["NPM_CONFIG_LOGLEVEL"] = "error";
    config_dir = config.get("configDir");
    if isinstance(config_dir, str) and config_dir.strip() {
        env["CLAUDE_CONFIG_DIR"] = resolve_claude_config_dir(config_dir, env);
        for key in CLAUDE_ACCOUNT_ENV_KEYS {
            # Explicit custom endpoint settings still work; subscription OAuth
            # always belongs to this account's CLI-managed login, never its
            # parent's.
            if key.startswith("CLAUDE_CODE_OAUTH_") or key.endswith("_FILE_DESCRIPTOR") or key not in instance_env {
                env.pop(key, None);
            }
        }
    } elif env.get("CLAUDE_CONFIG_DIR") {
        env["CLAUDE_CONFIG_DIR"] = resolve_claude_config_dir(None, env);
    }
    env.pop("CLAUDECODE", None);
    env.pop("CLAUDE_CODE_ENTRYPOINT", None);
    strip_workspace_credential_env(env);
    model_arg = None if config.get("managed") else model;
    applied = apply_claude_inject(env, model_arg);
    # A key set on purpose for this workspace (the instance environment)
    # stays; one riding along in the parent's env never does.
    if not applied["injected"] and not instance_env.get("ANTHROPIC_API_KEY") {
        env.pop("ANTHROPIC_API_KEY", None);
    }
    clean: dict[str, any] = {};
    for (key, value) in env.items() {
        if value is not None { clean[key] = value if isinstance(value, str) else str(value); }
    }
    return {"env": clean, "injected": applied["injected"], "model": applied["model"]};
}

# ── process plumbing (server/procs.ts) ─────────────────────────────────────

def _describe_spawn_failure(err: any, cli: str) -> dict[str, any] {
    code = getattr(err, "errno", None);
    if isinstance(err, FileNotFoundError) or code == errno_enoent() {
        return {"message": "`" + cli + "` isn't installed, or isn't on this app's PATH", "setup": True};
    }
    if isinstance(err, PermissionError) {
        return {"message": "`" + cli + "` isn't executable — check its file permissions", "setup": True};
    }
    return {"message": "spawn failed: " + str(err), "setup": False};
}

def errno_enoent() -> int {
    import errno;
    return errno.ENOENT;
}

def _exec_cli(cli: str, args: list[any], env: dict[str, any], timeout_s: float) -> dict[str, any] {
    # One-shot CLI probe (auth status, --version); answers on argv alone.
    try {
        proc = subprocess.run(
            [cli] + list(args),
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout_s
        );
    } except Exception {
        return {"ok": False, "stdout": ""};
    }
    return {"ok": proc.returncode == 0, "stdout": proc.stdout or ""};
}

def _stop_tree(session: dict[str, any], pid: int, timeout_ms: float) -> bool {
    # Stop an owned CLI group, including its MCP helpers: the process was
    # started in its own session, so the group is kill(-pid). Confirmed stop
    # means the process exited AND the group is gone.
    proc = session["proc"];
    if os.name == "nt" {
        try {
            subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                capture_output=True,
                timeout=(timeout_ms / 1000.0) + 5.0
            );
        } except Exception {
        }
        try {
            proc.wait(timeout=(timeout_ms / 1000.0) + 5.0);
            return True;
        } except Exception {
            return False;
        }
    }

    def _exited() -> bool {
        return proc.poll() is not None;
    }

    def _settled() -> bool {
        if not _exited() { return False; }
        try {
            os.killpg(pid, 0);
            return False;
        } except ProcessLookupError {
            return True;
        } except Exception {
            return False;
        }
    }

    def _signal(sig: any) {
        try {
            os.killpg(pid, sig);
        } except Exception {
            try {
                if sig == signal.SIGKILL {
                    proc.kill();
                } else {
                    proc.terminate();
                }
            } except Exception {
            }
        }
    }

    def _wait(ms: float) -> bool {
        deadline = time.monotonic() + ms / 1000.0;
        while not _settled() {
            remaining = deadline - time.monotonic();
            if remaining <= 0 { return False; }
            time.sleep(min(0.025, remaining));
        }
        return True;
    }

    if _settled() { return True; }
    _signal(signal.SIGTERM);
    if _wait(timeout_ms) { return True; }
    _signal(signal.SIGKILL);
    return _wait(1000);
}

def _kill_cli_tree(session: dict[str, any], timeout_ms: float = 5000.0) -> bool {
    # Memoized like procs.ts: a first in-flight stop is joined, a confirmed
    # stop is remembered so a delayed caller cannot signal a reused pid; a
    # failed attempt may be retried.
    ks = session["kill_state"];
    pid = session["proc"].pid;
    if not pid or pid <= 1 or pid == os.getpid() { return False; }
    owner = False;
    ks["lock"].acquire();
    try {
        if ks["running"] {
            owner = False;
        } elif ks["result"] is True {
            return True;
        } else {
            ks["running"] = True;
            ks["event"].clear();
            owner = True;
        }
    } finally {
        ks["lock"].release();
    }
    if not owner {
        ks["event"].wait((timeout_ms + 1500.0) / 1000.0);
        return bool(ks["result"]);
    }
    stopped = _stop_tree(session, pid, timeout_ms);
    ks["lock"].acquire();
    try {
        ks["running"] = False;
        if stopped {
            ks["result"] = True;
        } else {
            ks["result"] = None;
        }
        ks["event"].set();
    } finally {
        ks["lock"].release();
    }
    return stopped;
}

# ── session lifecycle ──────────────────────────────────────────────────────

def _stop_session(inst: dict[str, any], session: dict[str, any]) {
    def run() {
        stopped = _kill_cli_tree(session, PROC_KILL_GRACE_MS);
        if stopped and session.get("finish_close") is not None {
            try {
                session["finish_close"]();
            } except Exception {
            }
        }
    }
    t = threading.Thread(target=run, daemon=True);
    t.start();
}

def _close_session(inst: dict[str, any], thread_id: str, why: str) {
    s = inst["sessions"].get(thread_id);
    if s is None or s.get("closing") { return; }
    s["closing"] = True;
    if s.get("idle_timer") is not None {
        try {
            s["idle_timer"].cancel();
        } except Exception {
        }
        s["idle_timer"] = None;
    }
    # Broker ownership belongs to this session: detach and close it before a
    # replacement can bind the same per-thread socket.
    broker = s.get("broker");
    s["broker"] = None;
    if broker is not None {
        try {
            broker["close"]();
        } except Exception {
        }
    }
    # stdin EOF is the CLI's exit signal; give it a moment, then insist
    try {
        s["proc"].stdin.close();
    } except Exception {
    }

    def insist() {
        _stop_session(inst, s);
    }
    timer = threading.Timer(PROC_KILL_GRACE_MS / 1000.0, insist);
    timer.daemon = True;
    timer.start();
}

def _arm_idle(inst: dict[str, any], thread_id: str) {
    s = inst["sessions"].get(thread_id);
    if s is None { return; }
    if s.get("idle_timer") is not None {
        try {
            s["idle_timer"].cancel();
        } except Exception {
        }
    }

    def fire() {
        _close_session(inst, thread_id, "idle");
    }
    timer = threading.Timer(inst.get("idle_ms", 600000) / 1000.0, fire);
    timer.daemon = True;
    s["idle_timer"] = timer;
    timer.start();
}

def _write_user(session: dict[str, any], prompt_msg: dict[str, any]) -> bool {
    try {
        data = (json.dumps(prompt_msg) + "\n").encode("utf-8");
        stdin = session["proc"].stdin;
        stdin.write(data);
        stdin.flush();
        return True;
    } except Exception {
        return False;
    }
}

# Best-effort removal of the private temp dir holding `path`.

def _discard_temp_dir(path: any) {
    if path { shutil.rmtree(os.path.dirname(path), True); }
}

def _remove_private_temp_dir(path: any) -> bool {
    if not path { return True; }
    try {
        shutil.rmtree(os.path.dirname(path), ignore_errors=False);
        return True;
    } except Exception {
        return False;
    }
}

# ── events ─────────────────────────────────────────────────────────────────

def _base(thread_id: str, turn_id: str) -> dict[str, any] {
    return {"threadId": thread_id, "turnId": turn_id};
}

def _emit(inst: dict[str, any], event: dict[str, any]) {
    emit_event(inst, event);
}

def _emit_simple(inst: dict[str, any], thread_id: str, turn_id: str, event: dict[str, any]) {
    out = _base(thread_id, turn_id);
    for (key, value) in event.items() {
        out[key] = value;
    }
    _emit(inst, out);
}

# ── settle + stream handling ───────────────────────────────────────────────

# Atomic check-then-set of a one-shot flag: settle/close race between the
# stdout pump, the close watcher, the continuation timers and Stop.

def _claim(session: dict[str, any], rec: dict[str, any], key: str) -> bool {
    session["lock"].acquire();
    try {
        if rec.get(key) { return False; }
        rec[key] = True;
        return True;
    } finally {
        session["lock"].release();
    }
}

def _settle(inst: dict[str, any], session: dict[str, any], ok: bool, stop_reason: any, total: any = None, usage: any = None) {
    # Settles the TURN, not the process: the CLI stays for the next message
    # until it has been quiet for the idle policy's delay.
    thread_id = session["thread_id"];
    t = session.get("turn");
    if t is None or not _claim(session, t, "settled") { return; }
    for key in ["continuation_grace", "continuation_silence"] {
        timer = t.get(key);
        if timer is not None {
            try {
                timer.cancel();
            } except Exception {
            }
            t[key] = None;
        }
    }
    broker = session.get("broker");
    if broker is not None {
        try {
            broker["pause"]();
        } except Exception {
        }
    }
    # The config file holds live credentials — the CLI read it at start; it
    # must not sit on disk for the life of the session.
    if session.get("mcp_config_path") {
        _discard_temp_dir(session["mcp_config_path"]);
        session["mcp_config_path"] = None;
    }
    if session.get("system_prompt_path") {
        if _remove_private_temp_dir(session["system_prompt_path"]) {
            session["system_prompt_path"] = None;
        }
    }
    inst["live"].pop(thread_id, None);
    session["turn"] = None;
    inst["retry_state"].pop(thread_id, None);
    if stop_reason == "update_required" {
        _close_session(inst, thread_id, "update required");
    }
    cost = turn_cost_from_running_total(total, session.get("cost_total"));
    if total is not None { session["cost_total"] = total; }
    ev = _base(thread_id, t["turn_id"]);
    ev["type"] = "turn.completed";
    ev["ok"] = ok;
    ev["stopReason"] = stop_reason;
    ev["cost"] = cost;
    if usage is not None { ev["usage"] = usage; }
    _emit(inst, ev);
    if session["proc"].poll() is None and not session.get("closing") {
        _arm_idle(inst, thread_id);
    }
}

def _settle_result(inst: dict[str, any], session: dict[str, any], result: dict[str, any]) {
    _settle(inst, session, bool(result.get("ok")), result.get("stopReason"), result.get("cost"), result.get("usage"));
}

def _note_cost_state(session: dict[str, any], total: any, model_usage: any, usage4: list[any]) {
    state = claude_cost_snapshot(total, model_usage);
    if state is None { return; }
    if not session.get("cost_seen") {
        if session.get("session_id") {
            history = read_cost_history().get(session["session_id"], []);
            session["cost_total"] = restored_cost_base(history, state, usage4);
        } else {
            session["cost_total"] = None;
        }
        session["cost_seen"] = True;
    }
    if session.get("session_id") {
        record_cost_state(session["session_id"], state);
    }
}

def _handle_line(inst: dict[str, any], session: dict[str, any], line: str) {
    if session.get("closing") { return; }
    try {
        o = json.loads(line);
    } except Exception {
        return;
    }
    if not isinstance(o, dict) { return; }
    thread_id = session["thread_id"];
    t = session.get("turn");

    def turn_id() -> str {
        cur = session.get("turn");
        return cur["turn_id"] if cur is not None else session["launch_turn_id"];
    }

    kind = o.get("type");
    if kind == "system" {
        if o.get("subtype") == "init" {
            # A guest's session proves its tool set before it does anything.
            cur = session.get("turn");
            tools: any = o.get("tools") if isinstance(o.get("tools"), list) else [];
            if cur is not None and cur["input"].get("guestConfined") and (o.get("permissionMode") != "default" or _forbidden_tool(tools)) {
                _emit_simple(inst, thread_id, turn_id(), {"type": "runtime.error", "message": with_why("This Claude Code kept its shell, so it can't run this turn. Update Claude Code.", cur["input"].get("confinedWhy"))});
                session["closing"] = True;
                _stop_session(inst, session);
                return;
            }
            session["saw_init"] = True;
            if session.get("turn") is not None { session["turn"]["awaiting_init"] = False; }
            pm = o.get("permissionMode");
            session["native_permission_mode"] = pm if isinstance(pm, str) else None;
            sid = o.get("session_id");
            if isinstance(sid, str) { session["session_id"] = sid; }
            # The turn the CLI starts for a steered message it could not
            # fold: the held result now waits for this one's, bounded.
            held = session.get("turn");
            if held is not None and held.get("continuation_grace") is not None {
                try {
                    held["continuation_grace"].cancel();
                } except Exception {
                }
                held["continuation_grace"] = None;
                if held.get("continuation_silence") is not None {
                    try {
                        held["continuation_silence"].cancel();
                    } except Exception {
                    }
                }

                def silent() {
                    if session.get("turn") is not held or held.get("settled") or held.get("deferred") is None { return; }
                    if held.get("stop_requested") or session.get("closing") { return; }
                    held["continuation_silence"] = None;
                    _emit_simple(inst, thread_id, held["turn_id"], {"type": "runtime.error", "message": "Claude began a steered message but went silent; the turn was closed."});
                    _settle_result(inst, session, held["deferred"]);
                }
                silence = threading.Timer(STEERED_CONTINUATION_SILENCE_MS * _fake_timer_scale("FAKE_CLAUDE_STEER_SILENCE_SCALE") / 1000.0, silent);
                silence.daemon = True;
                held["continuation_silence"] = silence;
                silence.start();
            }
            ev = _base(thread_id, turn_id());
            ev["type"] = "session.started";
            ev["sessionId"] = o.get("session_id");
            ev["model"] = o.get("model");
            retry = inst["retry_state"].get(thread_id);
            if retry is not None and retry.get("rebuilt") { ev["rebuilt"] = True; }
            _emit(inst, ev);
        } elif o.get("subtype") == "thinking_tokens" {
            _emit_simple(inst, thread_id, turn_id(), {"type": "item.updated", "itemType": "reasoning", "tokens": o.get("estimated_tokens")});
        }
        return;
    }
    if kind == "stream_event" {
        # subagent narration is dropped — parallel Tasks would interleave
        if o.get("parent_tool_use_id") { return; }
        ev_o: any = o.get("event") if isinstance(o.get("event"), dict) else {};
        if ev_o.get("type") != "content_block_delta" { return; }
        d: any = ev_o.get("delta") if isinstance(ev_o.get("delta"), dict) else {};
        if d.get("type") == "text_delta" and isinstance(d.get("text"), str) and d.get("text") {
            if session.get("turn") is not None { session["turn"]["saw_stream_delta"] = True; }
            _emit_simple(inst, thread_id, turn_id(), {"type": "content.delta", "streamKind": "assistant_text", "delta": d["text"]});
        } elif d.get("type") == "thinking_delta" and isinstance(d.get("thinking"), str) and d.get("thinking") {
            _emit_simple(inst, thread_id, turn_id(), {"type": "content.delta", "streamKind": "reasoning_text", "delta": d["thinking"]});
        }
        return;
    }
    if kind == "assistant" {
        msg: any = o.get("message") if isinstance(o.get("message"), dict) else {};
        text = first_text(msg.get("content"));
        if claude_auth_failure(o, text) {
            if session.get("turn") is not None { session["turn"]["auth_failed"] = True; }
            _emit_simple(inst, thread_id, turn_id(), {"type": "runtime.error", "message": text, "setup": True});
            return;
        }
        if claude_version_too_old(o, text) {
            if session.get("turn") is not None { session["turn"]["update_required"] = True; }
            _emit_simple(inst, thread_id, turn_id(), {"type": "runtime.error", "message": text, "setup": True, "claudeUpdate": True});
            return;
        }
        if text.strip() {
            # The CLI's own report of any other API error is still shown,
            # but marked: the model never produced it.
            synthetic: dict[str, any] = {};
            if o.get("is_api_error_message") is True or isinstance(o.get("error"), str) {
                synthetic["synthetic"] = True;
            }
            cur = session.get("turn");
            if cur is None or not cur.get("saw_stream_delta") {
                ev = _base(thread_id, turn_id());
                for (k2, v2) in synthetic.items() { ev[k2] = v2; }
                ev["type"] = "content.delta";
                ev["streamKind"] = "assistant_text";
                ev["delta"] = text;
                _emit(inst, ev);
            }
            if session.get("turn") is not None { session["turn"]["saw_stream_delta"] = False; }
            ev = _base(thread_id, turn_id());
            for (k2, v2) in synthetic.items() { ev[k2] = v2; }
            ev["type"] = "item.completed";
            ev["itemType"] = "assistant_text";
            ev["text"] = text;
            _emit(inst, ev);
        }
        content = msg.get("content");
        if isinstance(content, list) {
            for b in content {
                if isinstance(b, dict) and b.get("type") == "tool_use" {
                    _emit_simple(inst, thread_id, turn_id(), {
                        "type": "item.started",
                        "itemType": "tool",
                        "itemId": b.get("id"),
                        "title": b.get("name"),
                        "summary": command_summary(b.get("input")),
                        "input": tool_detail_preview(b.get("input")),
                    });
                }
            }
        }
        usage_m = msg.get("usage");
        if isinstance(usage_m, dict) {
            ev = _base(thread_id, turn_id());
            ev["type"] = "thread.token-usage.updated";
            ev["input"] = (usage_m.get("input_tokens") or 0) + (usage_m.get("cache_read_input_tokens") or 0);
            ev["output"] = usage_m.get("output_tokens") or 0;
            cached = usage_m.get("cache_read_input_tokens");
            if isinstance(cached, (int, float)) { ev["cachedInput"] = cached; }
            ev["contextTokens"] = (usage_m.get("input_tokens") or 0) + (usage_m.get("cache_read_input_tokens") or 0) + (usage_m.get("cache_creation_input_tokens") or 0);
            _emit(inst, ev);
        }
        return;
    }
    if kind == "user" {
        # --replay-user-messages: a model call took this stdin message in.
        if o.get("isReplay") is True {
            if isinstance(o.get("uuid"), str) and session.get("turn") is not None {
                session["turn"]["pending_steers"].discard(o["uuid"]);
            }
            return;
        }
        msg_u: any = o.get("message") if isinstance(o.get("message"), dict) else {};
        content_u = msg_u.get("content");
        if isinstance(content_u, list) {
            for b in content_u {
                if isinstance(b, dict) and b.get("type") == "tool_result" {
                    _emit_simple(inst, thread_id, turn_id(), {
                        "type": "item.completed",
                        "itemType": "tool",
                        "itemId": b.get("tool_use_id"),
                        "ok": not b.get("is_error"),
                        "output": tool_detail_preview(b.get("content")),
                    });
                    for img in extract_mcp_images(b.get("content")) {
                        _emit_simple(inst, thread_id, turn_id(), {"type": "item.completed", "itemType": "assistant_image", "data": img["data"]});
                    }
                }
            }
        }
        return;
    }
    if kind == "result" {
        # A synthetic background completion is not the user turn's result.
        origin = o.get("origin");
        if isinstance(origin, dict) and origin.get("kind") == "task-notification" { return; }
        u: any = o.get("usage") if isinstance(o.get("usage"), dict) else {};
        _note_cost_state(session, o.get("total_cost_usd"), o.get("modelUsage"), [
            u.get("input_tokens") or 0,
            u.get("cache_read_input_tokens") or 0,
            u.get("cache_creation_input_tokens") or 0,
            u.get("output_tokens") or 0,
        ]);
        native: dict[str, any] = {
            "ok": o.get("is_error") is not True,
            "cost": o.get("total_cost_usd") if isinstance(o.get("total_cost_usd"), (int, float)) else None,
        };
        t_now = session.get("turn");
        if t_now is not None and t_now.get("auth_failed") {
            native["stopReason"] = "auth_required";
        } elif t_now is not None and t_now.get("update_required") {
            native["stopReason"] = "update_required";
        } else {
            native["stopReason"] = o.get("stop_reason") if o.get("stop_reason") is not None else o.get("terminal_reason");
        }
        if u is not None and isinstance(u, dict) and u {
            usage_out: dict[str, any] = {
                "input": (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0),
                "output": u.get("output_tokens") or 0,
            };
            cached_u = u.get("cache_read_input_tokens");
            if isinstance(cached_u, (int, float)) { usage_out["cachedInput"] = cached_u; }
            native["usage"] = usage_out;
        }
        # Does another user turn follow this result without more input?
        # queued_turn_count decides only above 0; with --replay a steer still
        # pending runs next, and without it any steer holds the result.
        queued = o.get("queued_turn_count") if isinstance(o.get("queued_turn_count"), (int, float)) else 0;
        t2 = session.get("turn");
        if t2 is not None and not t2.get("settled") and (queued > 0 or len(t2["pending_steers"]) > 0) {
            if not session.get("replays_user_messages") { t2["pending_steers"].clear(); }
            t2["deferred"] = sum_native_turn_results(t2.get("deferred"), native);

            def grace_fire() {
                # No init came: the message was folded into the call that
                # just finished, and the held result is the turn's.
                if session.get("turn") is not t2 or t2.get("settled") { return; }
                if t2.get("stop_requested") or session.get("closing") { return; }
                t2["continuation_grace"] = None;
                if t2.get("deferred") is not None { _settle_result(inst, session, t2["deferred"]); }
            }

            def arm_grace() {
                if t2.get("continuation_grace") is not None {
                    try {
                        t2["continuation_grace"].cancel();
                    } except Exception {
                    }
                }
                timer_g = threading.Timer(STEERED_CONTINUATION_GRACE_MS * _fake_timer_scale("FAKE_CLAUDE_STEER_GRACE_SCALE") / 1000.0, grace_fire);
                timer_g.daemon = True;
                t2["continuation_grace"] = timer_g;
                timer_g.start();
            }
            t2["arm_grace"] = arm_grace;
            arm_grace();
            return;
        }
        held_before = t2.get("deferred") if t2 is not None else None;
        _settle_result(inst, session, sum_native_turn_results(held_before, native));
        return;
    }
}

def _forbidden_tool(tools: list[any]) -> bool {
    for tool in tools {
        if isinstance(tool, str) and tool in GUEST_FORBIDDEN_TOOLS { return True; }
    }
    return False;
}

# ── send turn ──────────────────────────────────────────────────────────────

def _read_cli_version(config: dict[str, any], env: dict[str, any]) -> any {
    r = _exec_cli(config.get("cli") or "claude", ["--version"], env, PROBE_TIMEOUT_S);
    if not r["ok"] { return None; }
    out = (r["stdout"] or "").strip();
    return out or None;
}

def _mk_session_record(thread_id: str) -> dict[str, any] {
    ks: dict[str, any] = {"lock": threading.RLock(), "event": threading.Event(), "running": False, "result": None};
    return {
        "thread_id": thread_id,
        "proc": None,
        "broker": None,
        "mcp_config_path": None,
        "system_prompt_path": None,
        "args_key": None,
        "volatile": "",
        "session_id": None,
        "launch_session_id": None,
        "saw_init": False,
        "native_permission_mode": None,
        "replays_user_messages": False,
        "turn": None,
        "idle_timer": None,
        "closing": False,
        "stderr": "",
        "cost_total": None,
        "cost_seen": False,
        "close_finalized": False,
        "finish_close": None,
        "launch_turn_id": None,
        "kill_state": ks,
        "lock": threading.RLock(),
        "closed": threading.Event(),
    };
}

def _pump_stdout(inst: dict[str, any], session: dict[str, any]) {
    try {
        stream = session["proc"].stdout;
        for raw in iter(stream.readline, b"") {
            if session.get("closing") { break; }
            line = raw.decode("utf-8", "replace").strip();
            if line {
                try {
                    _handle_line(inst, session, line);
                } except Exception {
                }
            }
        }
    } except Exception {
    }
}

def _pump_stderr(session: dict[str, any]) {
    try {
        stream = session["proc"].stderr;
        for raw in iter(stream.readline, b"") {
            tail = (session.get("stderr") or "") + raw.decode("utf-8", "replace");
            if len(tail) > 8192 { tail = tail[len(tail) - 8192:]; }
            session["stderr"] = tail;
        }
    } except Exception {
    }
}

def _watch_close(inst: dict[str, any], session: dict[str, any]) {
    code = session["proc"].wait();

    def finish() -> bool {
        return _finalize_close(inst, session, code);
    }
    session["finish_close"] = finish;
    try {
        finish();
    } except Exception {
    }
    session["closed"].set();
}

def _finalize_close(inst: dict[str, any], session: dict[str, any], code: any) -> bool {
    if session.get("close_finalized") { return True; }
    thread_id = session["thread_id"];
    # The root can close while its MCP helpers are still running. Join an
    # in-flight stop (or reap its remaining group) before releasing the turn
    # so a replacement cannot overlap the old helpers.
    if not _kill_cli_tree(session, 0.0) {
        broker = session.get("broker");
        if broker is not None {
            session["broker"] = None;
            try {
                broker["close"]();
            } except Exception {
            }
        }
        tid = session["launch_turn_id"];
        cur = session.get("turn");
        if cur is not None { tid = cur["turn_id"]; }
        _emit_simple(inst, thread_id, tid, {"type": "runtime.error", "message": "Claude could not be confirmed stopped; its helper processes may still be running."});
        return False;
    }
    if not _claim(session, session, "close_finalized") { return True; }
    t = session.get("turn");
    # A turn still running when the process died is a failed turn; a process
    # that exited between turns is just a session ending.
    if t is not None and t.get("stop_requested") and not t.get("settled") {
        _settle(inst, session, False, "interrupted");
    } elif t is not None and t.get("deferred") is not None and not t.get("settled") {
        # The prompt was answered — a native result is held for a steered
        # continuation — and the process went away. Never relaunch.
        held = t["deferred"];
        if t.get("continuation_grace") is not None {
            _settle_result(inst, session, held);
        } else {
            tail = (session.get("stderr") or "").strip()[-300:];
            message = "claude exited " + str(code) + " before result";
            if tail { message = message + ": " + tail; }
            _emit_simple(inst, thread_id, t["turn_id"], {"type": "runtime.error", "message": message});
            failed = dict(held);
            failed["ok"] = False;
            failed["stopReason"] = "exit_before_result";
            _settle_result(inst, session, failed);
        }
    } elif t is not None and not t.get("settled") {
        _retry_after_close(inst, session, t, code);
        return True;
    }
    _teardown_session(inst, session);
    return True;
}

def _teardown_session(inst: dict[str, any], session: dict[str, any]) {
    thread_id = session["thread_id"];
    if session.get("idle_timer") is not None {
        try {
            session["idle_timer"].cancel();
        } except Exception {
        }
    }
    broker = session.get("broker");
    if broker is not None {
        try {
            broker["close"]();
        } except Exception {
        }
    }
    if session.get("mcp_config_path") {
        _discard_temp_dir(session["mcp_config_path"]);
    }
    _remove_private_temp_dir(session.get("system_prompt_path"));
    if inst["sessions"].get(thread_id) is session {
        inst["sessions"].pop(thread_id, None);
    }
}

def _cleanup_launch_resources(inst: dict[str, any], thread_id: str, broker: any, mcp_config_path: any, system_prompt_path: any) {
    if broker is not None {
        try {
            broker["close"]();
        } except Exception {
        }
    }
    if mcp_config_path {
        _discard_temp_dir(mcp_config_path);
    }
    if system_prompt_path {
        _remove_private_temp_dir(system_prompt_path);
    }
    inst["retry_state"].pop(thread_id, None);
}

def _relaunch_later(
    inst: dict[str, any],
    thread_id: str,
    turn_id: str,
    turn: dict[str, any],
    retry: dict[str, any],
    retry_abort: any,
    delay_ms: float,
    cursor: any,
    rebuilt: bool = False
) {
    retry_scale = _fake_timer_scale("FAKE_CLAUDE_RETRY_SCALE");

    def run() {
        retry_abort.wait(max(0.001, delay_ms * retry_scale / 1000.0));
        # An interrupt during the backoff landed here via stop(): the turn
        # settles as interrupted and no zombie relaunch happens.
        if retry["cancelled"] {
            inst["live"].pop(thread_id, None);
            inst["retry_state"].pop(thread_id, None);
            _emit_simple(inst, thread_id, turn_id, {"type": "turn.completed", "ok": False, "stopReason": "interrupted", "cost": None});
            return;
        }
        # Keep Stop reachable while the relaunch sets up: this handle only
        # records the cancellation; the relaunched send honors it pre-spawn.
        def stop_retry() {
            retry["cancelled"] = True;
            retry_abort.set();
        }
        inst["live"][thread_id] = {"stop": stop_retry, "turn_id": turn_id, "broker": None};
        nt = dict(turn);
        nt["sessionReset"] = False;
        nt["resumeCursor"] = cursor;
        try {
            _send_turn_impl(inst, nt, turn_id);
        } except Exception as e {
            live_now = inst["live"].get(thread_id);
            if live_now is not None and live_now.get("turn_id") == turn_id {
                inst["live"].pop(thread_id, None);
            }
            inst["retry_state"].pop(thread_id, None);
            _emit_simple(inst, thread_id, turn_id, {"type": "runtime.error", "message": str(e)});
            _emit_simple(inst, thread_id, turn_id, {"type": "turn.completed", "ok": False, "stopReason": "exit_before_result", "cost": None});
        }
    }
    t = threading.Thread(target=run, daemon=True);
    t.start();
}

def _retry_after_close(inst: dict[str, any], session: dict[str, any], t: dict[str, any], code: any) {
    thread_id = session["thread_id"];
    turn = t["input"];
    turn_id = t["turn_id"];
    retry_abort = t["retry_abort"];
    retry = inst["retry_state"].setdefault(thread_id, {"attempt": 0, "cancelled": False, "rebuilt": False});
    tail = (session.get("stderr") or "").strip()[-300:];
    message = "claude exited " + str(code) + " before result";
    if tail { message = message + ": " + tail; }
    verdict = classify_error(message, code);
    # A process kept warm from an earlier turn ended before it announced this
    # one: it never took the prompt. The same turn resumes at once, no retry
    # budget spent.
    ended_before_turn = t.get("awaiting_init") is True;
    retry_worthy = not retry["cancelled"] and (ended_before_turn or (code != 0 and verdict["transient"] and not t.get("saw_stream_delta") and retry["attempt"] < RETRY_MAX_ATTEMPTS - 1));
    if retry_worthy {
        # The CLI is gone but the TURN continues: keep the thread busy, emit
        # no terminal event, and relaunch after the backoff.
        failed_broker = session.get("broker");
        session["broker"] = None;
        if failed_broker is not None {
            try {
                failed_broker["pause"]();
                failed_broker["close"]();
            } except Exception {
            }
        }
        if session.get("mcp_config_path") {
            _discard_temp_dir(session["mcp_config_path"]);
            session["mcp_config_path"] = None;
        }
        if session.get("system_prompt_path") {
            _remove_private_temp_dir(session["system_prompt_path"]);
            session["system_prompt_path"] = None;
        }
        inst["sessions"].pop(thread_id, None);
        session["turn"] = None;
        delay_ms = 0.0;
        if not ended_before_turn {
            retry["attempt"] += 1;
            delay_ms = compute_backoff(retry["attempt"] - 1);
            _emit_simple(inst, thread_id, turn_id, {"type": "turn.retrying", "attempt": retry["attempt"], "delayMs": delay_ms, "reason": verdict["reason"]});
        }
        cursor = session.get("session_id") or session.get("launch_session_id");
        _relaunch_later(inst, thread_id, turn_id, turn, retry, retry_abort, delay_ms, cursor);
        return;
    }
    # A --resume that the CLI never acknowledged: it exited without an init
    # frame, so it never read the prompt and this turn has caused nothing.
    # One fresh session, carrying the harness's rebuild of the conversation.
    resume_failure = classify_resume_failure(
        bool(session.get("launch_session_id")),
        not session.get("saw_init"),
        bool(session.get("saw_init")),
        bool(t.get("saw_stream_delta"))
    );
    if may_replay(resume_failure) and not retry["cancelled"] {
        recovery = recovery_prompt_for(turn.get("recoveryText"), turn.get("text") or "", resume_failure);
        failed_broker = session.get("broker");
        session["broker"] = None;
        if failed_broker is not None {
            try {
                failed_broker["close"]();
            } except Exception {
            }
        }
        if session.get("mcp_config_path") {
            _discard_temp_dir(session["mcp_config_path"]);
            session["mcp_config_path"] = None;
        }
        if session.get("system_prompt_path") {
            _remove_private_temp_dir(session["system_prompt_path"]);
            session["system_prompt_path"] = None;
        }
        inst["sessions"].pop(thread_id, None);
        session["turn"] = None;
        retry["rebuilt"] = recovery["replayed"];
        inst["retry_state"][thread_id] = retry;
        nt = dict(turn);
        nt["resumeCursor"] = None;
        nt["recoveryText"] = None;
        nt["text"] = recovery["text"];
        _emit_simple(inst, thread_id, turn_id, {"type": "turn.retrying", "attempt": retry["attempt"] + 1, "delayMs": 0, "reason": "resume_rejected"});
        _relaunch_later(inst, thread_id, turn_id, nt, retry, retry_abort, 0.0, None);
        return;
    }
    inst["retry_state"].pop(thread_id, None);
    _emit_simple(inst, thread_id, turn_id, {"type": "runtime.error", "message": message});
    _settle(inst, session, False, "exit_before_result");
}

def _send_turn_impl(inst: dict[str, any], turn: dict[str, any], logical_turn_id: any = None) -> str {
    config = _config(inst);
    instance_env: any = inst["environment"] if isinstance(inst.get("environment"), dict) else {};
    turn = dict(turn);
    turn["toolScope"] = assert_tool_scope_supported("claudeAgent", turn.get("toolScope"));
    managed_models = config.get("managedModels");
    if managed_models and (not turn.get("model") or turn.get("model") not in managed_models) {
        raise RuntimeError("This model is not assigned to this workspace.");
    }
    if config.get("requireApiKey") and not instance_env.get("ANTHROPIC_API_KEY") {
        raise RuntimeError(NO_ANTHROPIC_KEY);
    }
    if config.get("managed") and (not turn.get("model") or "::" in str(turn.get("model")) or not config.get("configDir") or not instance_env.get("ANTHROPIC_API_KEY") or not instance_env.get("ANTHROPIC_BASE_URL")) {
        raise RuntimeError("Company model access is unavailable. Reconnect your organization; personal billing will not be used.");
    }
    # driver_send_turn already validated threadId is a str.
    thread_id = str(turn["threadId"]);
    bot_id = turn.get("botId");
    sessions: dict[str, any] = inst["sessions"];
    active: dict[str, any] = inst["live"];
    # An internal relaunch keeps the logical turn's stop handle in `active`
    # while it sets up, so Stop is never a silent no-op between two CLI
    # processes of the same turn.
    relaunch = logical_turn_id is not None;
    if not relaunch {
        stopped: any = sessions.get(thread_id);
        warm_stop = stopped is not None and stopped.get("turn") is not None and stopped["turn"].get("stop_requested") and active.get(thread_id, {}).get("turn_id") == stopped["turn"].get("turn_id");
        if warm_stop {
            if _kill_cli_tree(stopped, PROC_KILL_GRACE_MS) {
                stopped["closed"].wait(10.0);
            }
        }
        if thread_id in active {
            raise RuntimeError("a turn is already running on this thread");
        }
    }
    permission_mode = _permission_mode_for(config, turn);
    integrations: any = turn.get("integrations") if isinstance(turn.get("integrations"), dict) else {};
    local_computer: any = integrations.get("localComputer") if isinstance(integrations.get("localComputer"), dict) else None;
    controls_host = local_computer is not None and local_computer.get("scope") == "local-computer";
    if controls_host and permission_mode == "bypassPermissions" and turn.get("approvalMode") != "full" {
        raise RuntimeError("local computer control requires the interactive approval broker");
    }
    # Materialize before creating a broker or process: a missing/corrupt
    # attachment must fail this call without leaving a live session behind.
    prompt_msg = claude_user_message(turn.get("text") or "", turn.get("images"));
    turn_id = logical_turn_id if logical_turn_id is not None else new_uuid();
    retry_abort = threading.Event();
    retry = inst["retry_state"].get(thread_id);
    if retry is None {
        retry = {"attempt": 0, "cancelled": False, "rebuilt": False};
        inst["retry_state"][thread_id] = retry;
    }
    if not relaunch {
        retry["cancelled"] = False;
        retry["rebuilt"] = False;
    }
    resume_cursor = turn.get("resumeCursor");
    session_id = resume_cursor if not turn.get("sessionReset") and isinstance(resume_cursor, str) else None;
    new_session_id = None if session_id else new_uuid();

    args: list[any] = [
        "-p",
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--verbose",  # required by stream-json output
        "--include-partial-messages",
        "--permission-mode", permission_mode,
    ];
    guest_confined = bool(turn.get("guestConfined"));
    if guest_confined and permission_mode != "default" {
        raise RuntimeError("A guest's turn on this Cloud runs only in Ask.");
    }
    if guest_confined {
        args.append("--restricted");
        args.append("--tools");
        args.append(",".join(GUEST_CLAUDE_TOOLS));
    }
    config_tools = config.get("tools");
    if not guest_confined and config_tools is not None {
        args.append("--tools");
        args.append(",".join(config_tools));
    }
    disallowed = config.get("disallowedTools");
    if disallowed {
        args.append("--disallowedTools");
        args.append(",".join(disallowed));
    }
    probe = _claude_environment(inst, None);
    turn_environment = probe["env"];
    st = inst["claude_state"];
    if not st["cli_version_checked"] {
        version = _read_cli_version(config, turn_environment);
        if version is not None {
            st["cli_version"] = parse_version_triple(version);
            st["cli_version_checked"] = True;
        }
    }
    cli_version = st["cli_version"];
    if guest_confined and not claude_cli_supports(cli_version, "--restricted") {
        raise RuntimeError(with_why("This Claude Code is too old to run this turn without a shell. Update Claude Code.", turn.get("confinedWhy")));
    }
    # Each stdin message echoed as a model call takes it in: how a turn tells
    # a folded steer from one that runs next.
    replays_user_messages = cli_version is None or version_at_least(cli_version, CLAUDE_REPLAY_FLOOR);
    if replays_user_messages {
        args.append("--replay-user-messages");
    }
    isolated = not inherits_user_config(turn_environment);
    if turn.get("toolScope") is not None and (not isolated or turn.get("mcpFromUserConfig") or cli_version is None or not claude_cli_supports(cli_version, "--strict-mcp-config")) {
        raise RuntimeError("Claude cannot confirm a restricted MCP configuration for this account. Disable inherited Claude MCP servers and use a current, identifiable Claude CLI before using tool selection.");
    }
    if isolated {
        # A bot gets the tools and instructions its owner gave it, not
        # whatever this machine's Claude Code happens to be set up with.
        # Each flag only on a CLI that accepts it: an unknown flag is an
        # argument error that would fail every turn.
        if not turn.get("mcpFromUserConfig") and claude_cli_supports(cli_version, "--strict-mcp-config") {
            args.append("--strict-mcp-config");
        }
        if claude_cli_supports(cli_version, "--setting-sources") {
            args.append("--setting-sources");
            args.append("project");
        }
    }
    compact_window = auto_compact_window(turn_environment);
    if compact_window and st.get("cli_has_autocompact") is True {
        args.append("--autocompact");
        args.append(compact_window);
    }
    # Every turn refreshes the recorded system prompt, on --resume too,
    # gated by the version floor like every other flag the CLI may predate.
    if st["cli_version_checked"] and claude_cli_supports(cli_version, "--system-prompt-snapshot") {
        args.append("--system-prompt-snapshot");
        args.append("off");
    }
    turn_model = turn.get("model") if config.get("managed") else resolve_claude_turn_model(turn.get("model"), turn_environment);
    env_pair = _claude_environment(inst, turn_model);
    env = env_pair["env"];
    injected_model = env_pair["model"] if config.get("managed") else env_pair["model"];
    if injected_model {
        args.append("--model");
        args.append(injected_model);
    }
    if turn.get("effort") {
        args.append("--effort");
        args.append(turn.get("effort"));
    }
    return _launch_or_reuse(
        inst, config, turn, thread_id, bot_id, turn_id, retry, retry_abort, relaunch,
        permission_mode, integrations, controls_host, guest_confined, prompt_msg,
        session_id, new_session_id, args, env, injected_model, env_pair,
        isolated, replays_user_messages
    );
}

# ── launch: warm reuse or fresh CLI process ────────────────────────────────

def _launch_or_reuse(
    inst: dict[str, any],
    config: dict[str, any],
    turn: dict[str, any],
    thread_id: str,
    bot_id: any,
    turn_id: str,
    retry: dict[str, any],
    retry_abort: any,
    relaunch: bool,
    permission_mode: str,
    integrations: dict[str, any],
    controls_host: bool,
    guest_confined: bool,
    prompt_msg: dict[str, any],
    session_id: any,
    new_session_id: any,
    args: list[any],
    env: dict[str, any],
    injected_model: any,
    env_pair: dict[str, any],
    isolated: bool,
    replays_user_messages: bool
) -> str {
    sessions: dict[str, any] = inst["sessions"];
    active: dict[str, any] = inst["live"];
    instance_env: any = inst["environment"] if isinstance(inst.get("environment"), dict) else {};
    turn_environment = env;

    # integrations → MCP servers; pre-allow their tools (a headless
    # acceptEdits run silently denies anything unlisted)
    mcp_servers: dict[str, any] = {};
    allowed: list[any] = [];
    bot_owned: dict[str, bool] = {};
    if isinstance(integrations.get("composio"), dict) {
        mcp_servers["composio"] = dict(integrations["composio"]);
        allowed.append("mcp__composio");
    }
    if isinstance(integrations.get("localComputer"), dict) {
        local = integrations["localComputer"];
        mcp_servers["computer"] = {"command": local.get("command"), "args": local.get("args"), "env": local.get("env")};
        # Host tools always route through OpenMausBot's permission broker.
        if not controls_host { allowed.append("mcp__computer"); }
    }
    if isinstance(integrations.get("agents"), dict) {
        # Coordination is foundational, not an optional deferred lookup:
        # Claude waits for always-loaded tools before building the prompt.
        agents_server = dict(integrations["agents"]);
        agents_server["alwaysLoad"] = True;
        mcp_servers["agents"] = agents_server;
        allowed.append("mcp__agents");
    }
    if isinstance(integrations.get("phone"), dict) {
        mcp_servers["phone"] = dict(integrations["phone"]);
        allowed.append("mcp__phone");
    }
    if isinstance(integrations.get("browser"), dict) {
        mcp_servers["browser"] = dict(integrations["browser"]);
        allowed.append("mcp__browser");
    }
    if isinstance(integrations.get("dweb"), dict) {
        mcp_servers["dweb"] = {
            "command": node_exec_path(),
            "args": [resolve_proxy("drivers/dweb-proxy")],
            "env": {"ELECTRON_RUN_AS_NODE": "1", "DWEB_URL": integrations["dweb"].get("url")},
        };
        allowed.append("mcp__dweb");
    }
    for (name, server) in (integrations.get("custom") or {}).items() {
        if name in mcp_servers { continue; }
        mcp_servers[name] = dict(server) if isinstance(server, dict) else server;
        bot_owned[name] = True;
    }
    # --strict-mcp-config makes this config the CLI's only source, so a
    # server the bot's OWN project declares would otherwise vanish. Never
    # for a guest's turn: its folder is its own to write.
    cwd_hint = turn.get("cwd");
    if isolated and cwd_hint and not guest_confined {
        for (name, server) in project_mcp_servers(cwd_hint).items() {
            if name in mcp_servers { continue; }
            mcp_servers[name] = server;
            bot_owned[name] = True;
        }
    }
    # One tool call can put more into the conversation than the whole rest
    # of the session: harness-owned mounts are bounded and left alone, and
    # bot-owned servers go through the MCP gate.
    scope = turn.get("toolScope");
    budget = result_budget(turn_environment);
    gate_names: list[any] = list(bot_owned.keys()) if scope is None else list(mcp_servers.keys());
    for name in gate_names {
        if not can_use_mcp_server(scope, name) {
            mcp_servers.pop(name, None);
            continue;
        }
        gated = gate_server(name, mcp_servers[name], thread_id, budget if name in bot_owned else 0, scope);
        if gated is not None {
            merged = dict(gated);
            if isinstance(mcp_servers[name], dict) and mcp_servers[name].get("alwaysLoad") is True {
                merged["alwaysLoad"] = True;
            }
            mcp_servers[name] = merged;
        }
    }
    kept: list[any] = [];
    for name in allowed {
        if name[len("mcp__"):] in mcp_servers { kept.append(name); }
    }
    allowed = kept;
    # Keep ask_user available even in Full access. Native bypass skips
    # permission prompts, not questions requiring a person's answer.
    socket_path = permission_socket_path(thread_id, bot_id);
    if permission_mode != "bypassPermissions" {
        args.append("--permission-prompt-tool");
        args.append("mcp__ogb__approve");
    }
    permission_env: dict[str, any] = dict(NODE_ENV_FLAG);
    if scope is not None {
        permission_env["OMB_PERMISSION_TOOL_SCOPE"] = json.dumps(scope);
    }
    mcp_servers["ogb"] = {
        "command": node_exec_path(),
        "args": [resolve_proxy("permission-proxy"), socket_path],
        "env": permission_env,
        "alwaysLoad": True,
    };
    allowed.append("mcp__ogb");
    # A guest's turn pre-allows only the harness's own tools.
    if guest_confined {
        guest_kept: list[any] = [];
        for name in allowed {
            if name == "mcp__ogb" or name == "mcp__agents" { guest_kept.append(name); }
        }
        allowed = guest_kept;
    }
    # Secrets ride in the 0600 config file, never on argv.
    mcp_config_path: any = None;
    if mcp_servers {
        temp_root = tempfile.mkdtemp(prefix="omb-mcp-");
        mcp_config_path = os.path.join(temp_root, "mcp.json");
        args.append("--mcp-config");
        args.append(mcp_config_path);
        args.append("--allowedTools");
        args.append(",".join(allowed));
    }
    auth_settings: dict[str, any] = {};
    if isolated and not env_pair["injected"] {
        auth_settings = read_claude_auth_settings(env, instance_env);
    }
    hooks: any = integrations.get("hooks") if isinstance(integrations.get("hooks"), dict) else None;
    hook_helper_path = resolve_proxy("hooks/omb-hook");
    if hooks is not None {
        hook_token_path = hook_token_file(thread_id, bot_id);
        os.makedirs(os.path.dirname(hook_token_path), exist_ok=True);
        try {
            f = open(hook_token_path, "w", encoding="utf-8");
            try {
                f.write(hooks.get("token") or "");
            } finally {
                f.close();
            }
            os.chmod(hook_token_path, 0o600);
        } except Exception {
        }
        env["OMB_HOOK_URL"] = hooks.get("url");
        env["OMB_HOOK_TOKEN_FILE"] = hook_token_path;
        env["OMB_HOOK_NODE"] = node_exec_path();
        env["OMB_HOOK_HELPER"] = hook_helper_path;
    }
    settings: dict[str, any] = dict(auth_settings);
    if hooks is not None {
        settings["hooks"] = claude_hook_settings(hook_helper_path, node_exec_path());
    }
    if guest_confined {
        settings["permissions"] = GUEST_CLAUDE_PERMISSIONS;
    }
    auth_settings_path: any = None;
    if mcp_config_path and settings {
        auth_settings_path = os.path.join(os.path.dirname(mcp_config_path), "auth-settings.json");
        args.append("--settings");
        args.append(auth_settings_path);
    }
    env["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] = "1";
    cwd = turn.get("cwd") or user_home(env);
    command_cwd = cwd;
    try {
        command_cwd = os.path.realpath(cwd);
    } except Exception {
        command_cwd = cwd;
    }
    # Everything that shapes the process, minus session/turn-specific temp
    # paths — their contents are represented directly in the key instead.
    key_args: list[any] = [];
    prev = None;
    for a in args {
        if a != "--mcp-config" and a != "--settings" and prev != "--mcp-config" and prev != "--settings" {
            key_args.append(a);
        }
        prev = a;
    }
    auth_payload = json.dumps({
        "settings": auth_settings,
        "env": {key: env.get(key) for key in CLAUDE_ACCOUNT_ENV_KEYS},
    });
    args_key = json.dumps({
        "args": key_args,
        "system": turn.get("systemStable") if turn.get("systemStable") is not None else turn.get("system"),
        "mcpServers": mcp_servers,
        "cwd": cwd,
        "model": injected_model if injected_model else None,
        "base": env.get("ANTHROPIC_BASE_URL"),
        "configDir": env.get("CLAUDE_CONFIG_DIR"),
        "hooks": hooks is not None,
        "auth": hashlib.sha256(auth_payload.encode("utf-8")).hexdigest(),
    });

    # Reuse the live process when it is idle, unchanged, and is the session
    # the harness wants resumed.
    live: any = sessions.get(thread_id);
    warm = not turn.get("sessionReset") and live is not None and live.get("turn") is None and not live.get("closing") and live["proc"].poll() is None and live.get("args_key") == args_key and (session_id is None or session_id == live.get("session_id"));
    if warm {
        if live.get("idle_timer") is not None {
            try {
                live["idle_timer"].cancel();
            } except Exception {
            }
        }
        live["turn"] = {
            "turn_id": turn_id,
            "input": turn,
            "retry_abort": retry_abort,
            "settled": False,
            "saw_stream_delta": False,
            "awaiting_init": True,
            "auth_failed": False,
            "update_required": False,
            "stop_requested": False,
            "pending_steers": set(),
            "deferred": None,
            "continuation_grace": None,
            "continuation_silence": None,
            "arm_grace": None,
        };

        def stop_warm() {
            cur = live.get("turn");
            if cur is not None { cur["stop_requested"] = True; }
            _close_session(inst, thread_id, "interrupted");
            retry["cancelled"] = True;
            retry_abort.set();
            _stop_session(inst, live);
        }
        active[thread_id] = {"stop": stop_warm, "turn_id": turn_id, "broker": live.get("broker")};
        _emit_simple(inst, thread_id, turn_id, {"type": "turn.started"});
        volatile = turn.get("systemVolatile") or "";
        if volatile == live.get("volatile") and not turn.get("mentionTurn") {
            message = prompt_msg;
        } else {
            message = claude_user_message(with_volatile_note(turn.get("text") or "", volatile), turn.get("images"));
        }
        live["volatile"] = volatile;
        # A warm process can end between turns just as the next one is
        # written: nothing was submitted; its close resumes this same turn
        # on a fresh process (awaiting_init).
        running = live.get("turn");
        if not _write_user(live, message) and running is not None and not running.get("stop_requested") {
            _close_session(inst, thread_id, "stdin write failed");
        }
        if mcp_config_path {
            _discard_temp_dir(mcp_config_path);
        }
        return turn_id;
    }
    if live is not None {
        if turn.get("sessionReset") {
            _close_session(inst, thread_id, "context reset");
        } else {
            _close_session(inst, thread_id, "spawn contract changed");
        }
    }
    return _spawn_new_session(
        inst, config, turn, thread_id, bot_id, turn_id, retry, retry_abort, relaunch,
        permission_mode, controls_host, guest_confined, prompt_msg, session_id,
        new_session_id, args, env, mcp_servers, mcp_config_path, auth_settings_path,
        settings, cwd, command_cwd, args_key, isolated, replays_user_messages
    );
}

def _spawn_new_session(
    inst: dict[str, any],
    config: dict[str, any],
    turn: dict[str, any],
    thread_id: str,
    bot_id: any,
    turn_id: str,
    retry: dict[str, any],
    retry_abort: any,
    relaunch: bool,
    permission_mode: str,
    controls_host: bool,
    guest_confined: bool,
    prompt_msg: dict[str, any],
    session_id: any,
    new_session_id: any,
    args: list[any],
    env: dict[str, any],
    mcp_servers: dict[str, any],
    mcp_config_path: any,
    auth_settings_path: any,
    settings: dict[str, any],
    cwd: str,
    command_cwd: str,
    args_key: str,
    isolated: bool,
    replays_user_messages: bool
) -> str {
    sessions: dict[str, any] = inst["sessions"];
    active: dict[str, any] = inst["live"];
    broker: any = None;
    system_prompt_path: any = None;
    try {
        # Create the prompt file only for a new process; a compatible live
        # session has already consumed the same system prompt at launch.
        if turn.get("system") {
            temp_root = tempfile.mkdtemp(prefix="omb-system-");
            system_prompt_path = os.path.join(temp_root, "prompt.txt");
            f = open(system_prompt_path, "w", encoding="utf-8");
            try {
                f.write(turn["system"]);
            } finally {
                f.close();
            }
            os.chmod(system_prompt_path, 0o600);
            args.append("--append-system-prompt-file");
            args.append(system_prompt_path);
        }
        # Only create a broker for a new process; a retained process keeps
        # its existing proxy connection and broker across turns.
        if True {
            ask_tools: dict[str, any] = {};

            def event_turn_id() -> str {
                cur = inst["sessions"].get(thread_id);
                cur_turn = cur.get("turn") if cur is not None else None;
                return cur_turn["turn_id"] if cur_turn is not None else turn_id;
            }

            def on_ask(ask: dict[str, any]) {
                ask_tools[ask["id"]] = ask.get("tool") if isinstance(ask.get("tool"), str) else None;
                cur = inst["sessions"].get(thread_id);
                cur_turn = cur.get("turn") if cur is not None else None;
                native_mode = cur.get("native_permission_mode") if cur is not None else None;
                native_review = None;
                if permission_mode == "auto" and native_mode is not None {
                    native_review = "active" if native_mode == "auto" else "inactive";
                }
                questions = parse_ask_questions(ask.get("input")) if ask.get("tool") == ASK_USER_QUESTION_TOOL else None;
                ev = _base(thread_id, event_turn_id());
                ev["type"] = "request.opened";
                ev["requestId"] = ask["id"];
                ev["requestType"] = ask.get("kind");
                ev["tool"] = ask.get("tool");
                if questions is not None {
                    ev["summary"] = ask_question_summary(questions);
                } else {
                    fallback = ask_input_summary(ask.get("input"));
                    ev["summary"] = fallback if fallback is not None else (ask.get("tool") if ask.get("tool") else "tool");
                }
                tool_name = ask.get("tool");
                if ask.get("kind") == "permission" and tool_name == "Bash" {
                    command = permission_command_of(ask.get("input"), command_cwd);
                    if command is not None { ev["command"] = command; }
                    if ask.get("input", {}).get("dangerouslyDisableSandbox") is True {
                        ev["requiresExplicitApproval"] = True;
                    }
                }
                if native_review is not None { ev["nativeReview"] = native_review; }
                if ask.get("kind") == "permission" and not (controls_host and isinstance(tool_name, str) and tool_name.startswith("mcp__computer")) {
                    ev["allowSession"] = True;
                }
                if isinstance(tool_name, str) and controls_host and tool_name.startswith("mcp__computer") {
                    ev["approvalScope"] = "local-computer";
                }
                if questions is not None { ev["questions"] = questions; }
                if questions is not None {
                    flat = question_choices(questions);
                    if flat is not None { ev["choices"] = flat; }
                } else {
                    flat2 = parse_choices((ask.get("input") or {}).get("choices"));
                    if flat2 is not None { ev["choices"] = flat2; }
                }
                _emit(inst, ev);
            }

            def on_resolve(resolved: dict[str, any]) {
                ev = _base(thread_id, event_turn_id());
                ev["type"] = "request.resolved";
                ev["requestId"] = resolved["id"];
                ev["behavior"] = resolved["behavior"];
                ev["source"] = resolved["source"];
                tool_name = ask_tools.get(resolved["id"]);
                if isinstance(tool_name, str) and controls_host and tool_name.startswith("mcp__computer") {
                    ev["approvalScope"] = "local-computer";
                }
                ask_tools.pop(resolved["id"], None);
                _emit(inst, ev);
            }
            broker = create_permission_broker(
                broker_socket_candidates(thread_id, bot_id),
                on_ask,
                on_resolve,
                _broker_is_active(inst, thread_id),
                None
            );
            # A fallback bind means the deterministic pipe is still held by
            # an earlier process's child; the proxy learns its path from argv.
            if broker["socket_path"] != permission_socket_path(thread_id, bot_id) and mcp_config_path {
                mcp_servers["ogb"] = {
                    "command": node_exec_path(),
                    "args": [resolve_proxy("permission-proxy"), broker["socket_path"]],
                    "env": permission_env_of(inst, turn),
                    "alwaysLoad": True,
                };
            }
        }
        # Write once, only after the broker has selected its real endpoint.
        if mcp_config_path {
            f2 = open(mcp_config_path, "w", encoding="utf-8");
            try {
                f2.write(json.dumps({"mcpServers": mcp_servers}));
            } finally {
                f2.close();
            }
            os.chmod(mcp_config_path, 0o600);
        }
        if auth_settings_path {
            f3 = open(auth_settings_path, "w", encoding="utf-8");
            try {
                f3.write(json.dumps(settings));
            } finally {
                f3.close();
            }
            os.chmod(auth_settings_path, 0o600);
        }
        if session_id {
            args.append("--resume");
            args.append(session_id);
        } else {
            args.append("--session-id");
            args.append(new_session_id);
        }
    } except Exception as e {
        _cleanup_launch_resources(inst, thread_id, broker, mcp_config_path, system_prompt_path);
        raise e;
    }
    # Stop reached the relaunch handle while this attempt was still setting
    # up: settle as interrupted instead of spawning a nobody-wants process.
    if relaunch and retry["cancelled"] {
        _cleanup_launch_resources(inst, thread_id, broker, mcp_config_path, system_prompt_path);
        live_now = active.get(thread_id);
        if live_now is not None and live_now.get("turn_id") == turn_id {
            active.pop(thread_id, None);
        }
        _emit_simple(inst, thread_id, turn_id, {"type": "turn.completed", "ok": False, "stopReason": "interrupted", "cost": None});
        return turn_id;
    }
    cli = config.get("cli") or "claude";
    try {
        proc = subprocess.Popen(
            [cli] + list(args),
            cwd=cwd,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False
        );
    } except Exception as e {
        _cleanup_launch_resources(inst, thread_id, broker, mcp_config_path, system_prompt_path);
        raise RuntimeError(str(e));
    }
    session = _mk_session_record(thread_id);
    session["proc"] = proc;
    session["broker"] = broker;
    session["mcp_config_path"] = mcp_config_path;
    session["system_prompt_path"] = system_prompt_path;
    session["args_key"] = args_key;
    session["volatile"] = turn.get("systemVolatile") or "";
    session["session_id"] = session_id if session_id else new_session_id;
    session["launch_session_id"] = session_id;
    session["replays_user_messages"] = replays_user_messages;
    session["launch_turn_id"] = turn_id;
    session["turn"] = {
        "turn_id": turn_id,
        "input": turn,
        "retry_abort": retry_abort,
        "settled": False,
        "saw_stream_delta": False,
        "awaiting_init": False,
        "auth_failed": False,
        "update_required": False,
        "stop_requested": False,
        "pending_steers": set(),
        "deferred": None,
        "continuation_grace": None,
        "continuation_silence": None,
        "arm_grace": None,
    };
    sessions[thread_id] = session;
    t_out = threading.Thread(target=_pump_stdout, args=(inst, session), daemon=True);
    t_out.start();
    t_err = threading.Thread(target=_pump_stderr, args=(session,), daemon=True);
    t_err.start();
    t_close = threading.Thread(target=_watch_close, args=(inst, session), daemon=True);
    t_close.start();

    def stop_new() {
        cur = session.get("turn");
        if cur is not None { cur["stop_requested"] = True; }
        # Retire steering and approvals now, before a still-connected child
        # can submit more work.
        _close_session(inst, thread_id, "interrupted");
        retry["cancelled"] = True;
        retry_abort.set();
        _stop_session(inst, session);
    }
    active[thread_id] = {"stop": stop_new, "turn_id": turn_id, "broker": broker};
    _emit_simple(inst, thread_id, turn_id, {"type": "turn.started"});
    # Prompt over stdin as a stream-json message — never argv. stdin stays
    # OPEN: that is what keeps the session alive for a mid-turn steer or
    # the next turn; closeSession() ends it.
    if not _write_user(session, prompt_msg) {
        cur = session.get("turn");
        if cur is not None and not cur.get("stop_requested") {
            _settle(inst, session, False, "stdin_write_failed");
        }
        _close_session(inst, thread_id, "stdin write failed");
    }
    return turn_id;
}

def permission_env_of(inst: dict[str, any], turn: dict[str, any]) -> dict[str, any] {
    # The permission proxy's env: the node-runtime flag plus the turn's tool
    # selection, which the proxy enforces on the CLI's ask_user tool.
    env_p: dict[str, any] = dict(NODE_ENV_FLAG);
    if turn.get("toolScope") is not None {
        env_p["OMB_PERMISSION_TOOL_SCOPE"] = json.dumps(turn.get("toolScope"));
    }
    return env_p;
}

def permission_command_of(input: any, command_cwd: str) -> any {
    # Approval identity preserves every command byte, including whitespace
    # and newlines; only a command with an absolute directory qualifies.
    if not isinstance(input, dict) { return None; }
    command = input.get("command");
    if not isinstance(command, str) or not command.strip() or "\x00" in command { return None; }
    if not isinstance(command_cwd, str) or not os.path.isabs(command_cwd) or "\x00" in command_cwd { return None; }
    return {"command": command, "cwd": command_cwd};
}

def _broker_is_active(inst: dict[str, any], thread_id: str) -> any {
    def check() -> bool {
        cur = inst["sessions"].get(thread_id);
        return cur is not None and cur.get("turn") is not None;
    }
    return check;
}

# ── steer / interrupt / respond / stop / dispose ───────────────────────────

def _op_send_turn(inst: dict[str, any], turn: dict[str, any]) -> str {
    return _send_turn_impl(inst, turn, None);
}

def _op_interrupt(inst: dict[str, any], thread_id: any, turn_id: any) {
    live = inst["live"].get(thread_id);
    if live is not None {
        stop = live.get("stop");
        if stop is not None { stop(); }
    }
}

def _op_respond(inst: dict[str, any], thread_id: any, request_id: any, decision: dict[str, any]) -> str {
    # Fail-closed by construction: no broker, or an ask that already timed
    # out / settled, is `unavailable` — the caller denies.
    session = inst["sessions"].get(thread_id);
    broker = session.get("broker") if session is not None else None;
    if broker is None {
        live = inst["live"].get(thread_id);
        broker = live.get("broker") if live is not None else None;
    }
    if broker is None { return "unavailable"; }
    behavior = decision.get("behavior");
    ok = broker["answer"](request_id, behavior, decision.get("message"), decision.get("always"));
    if not ok { return "unavailable"; }
    if behavior == "allow" { return "allowed-once"; }
    if behavior == "answer" { return "answered"; }
    return "rejected";
}

def _op_steer(inst: dict[str, any], thread_id: any, text: any) -> str {
    # A user message into the running turn: the CLI delivers it before its
    # next model call, or as its next native turn. "refused" when nothing is
    # running here to steer or the stdin write provably failed.
    s = inst["sessions"].get(thread_id);
    if s is None or s.get("turn") is None or s["turn"].get("settled") or s.get("closing") or s["proc"].poll() is not None {
        return "refused";
    }
    t = s["turn"];
    steer_id = new_uuid();
    # Counted before the write: a result read while the words are still on
    # their way must hold for them too.
    t["pending_steers"].add(steer_id);
    msg = claude_user_message(text if isinstance(text, str) else "", None);
    msg["uuid"] = steer_id;
    if not _write_user(s, msg) {
        t["pending_steers"].discard(steer_id);
        return "refused";
    }
    # Written while a held result waits for a continuation's init: these
    # words get the whole grace to be announced too.
    if not t.get("settled") and t.get("continuation_grace") is not None and t.get("arm_grace") is not None {
        arm = t["arm_grace"];
        arm();
    }
    return "steered";
}

def _close_all(inst: dict[str, any], why: str) {
    for live in list(inst["live"].values()) {
        stop = live.get("stop");
        if stop is not None { stop(); }
    }
    for thread_id in list(inst["sessions"].keys()) {
        _close_session(inst, thread_id, why);
    }
}

def _op_stop_all(inst: dict[str, any]) { _close_all(inst, "stopAll"); }

def _op_dispose(inst: dict[str, any]) { _close_all(inst, "dispose"); }

# ── one-shot generation (generateText / reviewPermission) ──────────────────

def _generate_review(inst: dict[str, any], prompt: str) -> str {
    config = _config(inst);
    instance_env: any = inst["environment"] if isinstance(inst.get("environment"), dict) else {};
    if config.get("requireApiKey") and not instance_env.get("ANTHROPIC_API_KEY") {
        raise RuntimeError(NO_ANTHROPIC_KEY);
    }
    managed_models = config.get("managedModels");
    model = managed_models[0] if managed_models else "claude-haiku-4-5";
    env_pair = _claude_environment(inst, model);
    cli = config.get("cli") or "claude";
    args = ["-p", "--model", model, "--output-format", "text"];
    try {
        proc = subprocess.Popen(
            [cli] + args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env_pair["env"]
        );
    } except Exception as e {
        raise RuntimeError(str(e));
    }
    try {
        pair = proc.communicate(prompt.encode("utf-8"), timeout=REVIEW_TIMEOUT_S);
    } except subprocess.TimeoutExpired {
        try {
            proc.kill();
        } except Exception {
        }
        try {
            proc.communicate();
        } except Exception {
        }
        raise RuntimeError("Claude review timed out");
    } except Exception {
        try {
            proc.kill();
        } except Exception {
        }
        raise;
    }
    stdout = pair[0].decode("utf-8", "replace") if isinstance(pair[0], bytes) else (pair[0] or "");
    stderr = pair[1].decode("utf-8", "replace") if isinstance(pair[1], bytes) else (pair[1] or "");
    if proc.returncode == 0 { return stdout.strip(); }
    detail = stderr.strip();
    if detail { raise RuntimeError(detail); }
    raise RuntimeError("Claude review exited " + str(proc.returncode));
}

# Serves both generateText and reviewPermission: a one-shot Claude call with
# the prompt on stdin, never argv (approval summaries can carry paths,
# commands or secrets), and no tools or MCP servers mounted.

def _op_generate_text(inst: dict[str, any], prompt: any, options: any) -> str {
    return _generate_review(inst, prompt if isinstance(prompt, str) else "");
}

# ── snapshot ───────────────────────────────────────────────────────────────

def _op_snapshot(inst: dict[str, any]) -> dict[str, any] {
    config = _config(inst);
    instance_env: any = inst["environment"] if isinstance(inst.get("environment"), dict) else {};
    cli = config.get("cli") or "claude";
    env_pair = _claude_environment(inst, None);
    env = env_pair["env"];
    probe = _exec_cli(cli, ["--version"], env, PROBE_TIMEOUT_S);
    version = (probe["stdout"] or "").strip() if probe["ok"] else "";
    if not version {
        return {"state": "unavailable", "reason": "`" + cli + "` CLI not found"};
    }
    st = inst["claude_state"];
    st["cli_version"] = parse_version_triple(version);
    st["cli_version_checked"] = True;
    if config.get("requireApiKey") {
        # Never falls back to a login: without the key it is not set up.
        if not instance_env.get("ANTHROPIC_API_KEY") {
            return {"state": "unavailable", "version": version, "reason": NO_ANTHROPIC_KEY};
        }
        return {"state": "available", "version": version, "authenticated": True, "account": {"method": "api-key"}, "billing": "metered"};
    }
    auth = _exec_cli(cli, ["auth", "status", "--json"], env, PROBE_TIMEOUT_S);
    out: dict[str, any] = {"state": "available", "version": version, "billing": "subscription"};
    try {
        status = json.loads(auth["stdout"]);
    } except Exception {
        status = None;
    }
    if isinstance(status, dict) and status.get("loggedIn") is True {
        out["authenticated"] = True;
        account: dict[str, any] = {};
        email = status.get("email");
        org = status.get("orgName");
        if isinstance(email, str) and email.strip() and len(email) <= 254 and re.search(r"^[^\s@]+@[^\s@]+\.[^\s@]+$", email.strip()) {
            account["email"] = email.strip();
        }
        if isinstance(org, str) and org.strip() and len(org) <= 160 {
            account["organization"] = org.strip();
        }
        if status.get("authMethod") == "api_key" { account["method"] = "api-key"; }
        if account { out["account"] = account; }
    } else {
        out["authenticated"] = False;
    }
    return out;
}

# ── registration ───────────────────────────────────────────────────────────

with entry {
    driver_register_kind("claudeAgent", {
        "create": _create,
        "send_turn": _op_send_turn,
        "interrupt_turn": _op_interrupt,
        "respond": _op_respond,
        "steer": _op_steer,
        "stop_all": _op_stop_all,
        "dispose": _op_dispose,
        "snapshot": _op_snapshot,
        "generate_text": _op_generate_text,
        "review_permission": _op_generate_text,
    });
}
