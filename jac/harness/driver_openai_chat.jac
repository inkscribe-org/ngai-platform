"""Chat-completions runtime — the Jac port of server/drivers/openai-chat.ts
(createOpenAIChatRuntime) and chat-tool-approval.ts, registered today for the
openai-compat kind (server/drivers/openai-compat.ts).

The runtime is provider-neutral: a kind supplies an options dict (key, base
URL, request body shape, error label, idle timeout, native-log shape,
reasoning/tool/image switches) and gets the whole adapter surface back as
impl fns for drivers.driver_register_kind. cerebras, mistral, minimax and
grok build on the same runtime in TS; porting one is a new `_<kind>_options`
plus a registration, nothing else.

One turn is one daemon thread: rebuild the request from the transcript,
stream a completion over HTTP (SSE or a JSON body), run structured tool calls
through the per-turn MCP session (driver_openai_chat_mcp.jac) behind the
approval gate, loop until a final answer or a safety stop. Every
RuntimeEvent goes out through drivers.emit_event. The node shim
(server/jac-drivers.ts) keeps the declarative surface — catalog, metadata,
auth, snapshot — and forwards adapter calls here."""

import os;
import re;
import ssl;
import json;
import time;
import uuid;
import socket;
import codecs;
import threading;
import http.client;
import urllib.parse;

import from drivers { emit_event, driver_register_kind, _bridge }
import from db { DATA_DIR }
import from driver_claude_support {
    parse_tool_scope, allows_tool, parse_ask_questions, ask_question_summary,
    question_choices, redact_secrets, redact_secrets_in_text, tool_detail_preview,
    classify_error, compute_backoff, RETRY_MAX_ATTEMPTS,
}
import from driver_openai_chat_protocol {
    ChatProtocolError, RejectedToolCallError, UnsupportedChatToolsError,
    UnsupportedReasoningReplayError, ChatToolSessionError, rejected_tool_call_error,
    new_tool_calls, new_reasoning_details, completion_error, rejects_tools_parameter,
    refused_tool_call, rejects_reasoning_replay, refused_tool_call_failure,
    announces_action, usage_from, usage_count, rejects_key, key_fingerprint,
}
import from driver_openai_chat_mcp {
    AbortError, new_signal, mount_chat_tools, assert_image_transport,
    chat_image_budget, chat_user_content, chat_tool_images,
}

# One turn's safety stops: model steps, and tool calls across all of them.
glob MAX_CHAT_ROUNDS: int = 64;
glob MAX_TURN_TOOL_CALLS: int = 200;
glob STREAM_BUFFER_CHARS: int = 2000000;
glob INTERRUPT_WAIT_S: float = 25.0;  # under node's 30 s op timeout (jac-routines.ts)
glob APPROVAL_TIMEOUT_MS: float = 900000.0;

glob ASK_USER_TOOL: str = "ask_user";
glob ASK_USER_TOOL_DEFINITION: dict[str, any] = {
    "type": "function",
    "function": {
        "name": "ask_user",
        "description": "Ask the person questions when the decision is theirs. Offer concrete options where they exist; they can always answer in their own words. Ask up to six questions in one call rather than one at a time.",
        "parameters": {
            "type": "object",
            "properties": {
                "questions": {
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 6,
                    "items": {
                        "type": "object",
                        "properties": {
                            "question": {"type": "string", "description": "The question to show the person."},
                            "header": {"type": "string", "description": "A short label for the question's tab."},
                            "multiSelect": {"type": "boolean", "description": "Whether several options may be picked."},
                            "options": {
                                "type": "array",
                                "maxItems": 12,
                                "description": "Suggested answers; the person may always write their own.",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "label": {"type": "string"},
                                        "description": {"type": "string"},
                                    },
                                    "required": ["label"],
                                    "additionalProperties": False,
                                },
                            },
                        },
                        "required": ["question"],
                        "additionalProperties": False,
                    },
                },
            },
            "required": ["questions"],
            "additionalProperties": False,
        },
    },
};

glob NUDGE_ANNOUNCED_ACTION: str = "You said what you would do next but called no tool. Do it now with your tools, or reply with your final answer if nothing is left to do.";
glob TEXT_ONLY_ATTACHMENT_NOTE: str = "[The person attached image(s), but this model cannot see images. Say so if the request depends on them.]";
glob TEXT_ONLY_SCREENSHOT_NOTE: str = "[Screenshot not shown: this model cannot see images. Read the page with a snapshot or a text tool instead.]";
glob SECRET_ENV_KEY_RE: any = re.compile(r"key|token|password|secret|authorization", re.I);

glob VOLATILE_CONTEXT_NOTE_PREFIX: str = "Context from OpenMausBot updated since this conversation started; it replaces any earlier copy:";
glob VOLATILE_CONTEXT_CLEARED_NOTE: str = "The OpenMausBot context notes from earlier in this conversation have been cleared; the standing instructions still apply.";

def stopped_after(count: str) -> str {
    return "Stopped after " + count + " without a final answer. The steps so far already ran, so ask only for what's left.";
}

def _now_iso() -> str {
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + f".{int(time.time() * 1000) % 1000:03d}Z";
}

def _js_len(text: str) -> int {
    # String.prototype.length: UTF-16 code units.
    return len(text.encode("utf-16-le")) // 2;
}

def _compact(value: any) -> str {
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False);
}

# ── prompt split (prompt-split.ts) ─────────────────────────────────────────

def prompt_halves(turn: dict[str, any]) -> dict[str, any] {
    stable = turn.get("systemStable");
    volatile = turn.get("systemVolatile");
    if not isinstance(stable, str) or not isinstance(volatile, str) {
        return {"stable": None, "volatile": ""};
    }
    return {"stable": stable, "volatile": volatile};
}

def volatile_context_note(volatile: str, had_volatile: bool) -> str {
    text = volatile.strip();
    if text { return VOLATILE_CONTEXT_NOTE_PREFIX + "\n\n" + text; }
    return VOLATILE_CONTEXT_CLEARED_NOTE if had_volatile else "";
}

def with_context_note(note: str, text: str) -> str {
    if not note { return text; }
    return (note + "\n\n" + text) if text else note;
}

# ── native protocol tee (native.ts) ────────────────────────────────────────

def native_dir() -> str {
    # NATIVE_DIR (config.ts): <data dir>/native, read per call so a relocated
    # data dir (tests, fixtures) is honoured without a re-import.
    return os.path.join(os.environ.get("OMB_DATA_DIR") or DATA_DIR, "native");
}

def append_native(thread_id: str, direction: str, source: str, msg: any) {
    # Never let logging break the run it is observing.
    try {
        d = native_dir();
        os.makedirs(d, exist_ok=True);
        line = _compact({"at": _now_iso(), "dir": direction, "source": source, "msg": redact_secrets(msg)}) + "\n";
        fd = os.open(os.path.join(d, thread_id + ".ndjson"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600);
        try {
            os.write(fd, line.encode("utf-8"));
        } finally {
            os.close(fd);
        }
    } except Exception {
    }
}

# ── automatic continuity (turn-continuation.ts) ────────────────────────────

glob NOT_RESUMABLE_RE: any = re.compile(r"not a multimodal model|unknown model|does not support|tool arguments do not match", re.I);
glob CAP_RE: any = re.compile(r"stopped after \d+ steps without a final answer|model-call limit reached", re.I);

def classify_continuable(stop_reason: any, failure: any) -> any {
    if not failure { return None; }
    if NOT_RESUMABLE_RE.search(failure) is not None { return None; }
    if CAP_RE.search(failure) is not None { return "cap"; }
    return None;
}

def handoff_dir() -> str {
    base = os.environ.get("OMB_DATA_DIR") or os.path.join(os.path.expanduser("~"), ".openmausbot");
    return os.path.join(base, "handoffs");
}

def write_turn_handoff(rec: dict[str, any]) -> any {
    try {
        d = handoff_dir();
        os.makedirs(d, exist_ok=True);
        written = _now_iso();
        stamp = re.sub(r"[:.]", "-", written);
        path = os.path.join(d, "cap-" + str(rec["threadId"])[0:8] + "-" + str(rec["turnId"])[0:8] + "-" + stamp + ".md");
        lines: list[str] = [];
        lines.extend(["# Handoff - turn ended without a final answer", ""]);
        lines.append("- Thread: " + rec["threadId"]);
        lines.append("- Turn: " + rec["turnId"]);
        lines.append("- Model: " + (rec.get("model") or "unknown"));
        lines.append("- Tool calls used: " + str(rec["toolCalls"]));
        if rec.get("hasUsage") and rec.get("usage") {
            lines.append("- Tokens this turn: " + str(rec["usage"]["input"]) + " in / " + str(rec["usage"]["output"]) + " out");
        }
        lines.append("- Stop reason: " + (rec.get("failure") or "unknown"));
        lines.extend(["- Written at: " + written, ""]);
        lines.extend(["## Original task (first user message)", "```"]);
        first_text = "null";
        for m in rec["messages"] {
            if m.get("role") == "user" {
                c = m.get("content");
                first_text = c if isinstance(c, str) else _compact(c);
                break;
            }
        }
        lines.extend([first_text[0:8000], "```", ""]);
        lines.extend(["## Work performed (tool calls in order)", ""]);
        n = 0;
        for m in rec["messages"] {
            if m.get("role") == "assistant" and isinstance(m.get("tool_calls"), list) {
                for tc in m["tool_calls"] {
                    n += 1;
                    fn = tc.get("function") or {};
                    args = re.sub(r"\s+", " ", str(fn.get("arguments") or ""))[0:300];
                    lines.append(str(n) + ". " + (fn.get("name") or "tool") + " - " + args);
                }
            } elif m.get("role") == "tool" {
                verdict = "?";
                try {
                    verdict = "ok" if json.loads(str(m.get("content"))).get("ok") else "FAILED";
                } except Exception {
                }
                lines.append("   result " + verdict + ": " + re.sub(r"\s+", " ", str(m.get("content") or ""))[0:220]);
            }
        }
        if n == 0 { lines.append("(none recorded)"); }
        lines.extend(["", "## Last assistant text", ""]);
        last: any = None;
        for m in reversed(rec["messages"]) {
            c = m.get("content");
            if m.get("role") == "assistant" and isinstance(c, str) and c.strip() {
                last = c;
                break;
            }
        }
        lines.extend([last[0:6000] if last else "(none)", ""]);
        lines.extend(["## Instructions for whoever continues this task", ""]);
        lines.append("1. Read this file completely.");
        lines.append("2. Re-verify the current state of every file, branch, and PR mentioned above before acting - it may be stale.");
        lines.append("3. Continue from the first unfinished step. Do not redo completed work.");
        lines.append("4. If you get close to your own turn budget, append your progress to this file before stopping.");
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600);
        try {
            os.write(fd, "\n".join(lines).encode("utf-8"));
        } finally {
            os.close(fd);
        }
        return path;
    } except Exception {
        return None;
    }
}

# ── approval gate (chat-tool-approval.ts) ──────────────────────────────────
# Register before publishing: a harness listener may answer synchronously.
# A card finishes exactly once; a second finish is a no-op because the card
# already left the pending map.

obj ChatToolApproval {
    has signal: any = None,
        hooks: dict[str, any] = {},
        timeout_ms: float = 900000.0,
        pending: dict[str, any] = {},
        closed: bool = False,
        lock: any = None;

    def _wait(card: dict[str, any]) {
        abort_card = _finisher(self, card, "system", None);
        remove = self.signal.on_abort(abort_card);
        if self.signal.aborted { abort_card(); }
        deadline = time.monotonic() + self.timeout_ms / 1000.0;
        while not card["event"].is_set() {
            left = deadline - time.monotonic();
            if left <= 0 {
                self.finish(card, "timeout", None);
                break;
            }
            card["event"].wait(min(left, 1.0));
        }
        remove();
    }

    def ask(tool: str, summary: str) -> bool {
        if self.closed or self.signal.aborted { return False; }
        card: dict[str, any] = {"kind": "permission", "ask": {"id": str(uuid.uuid4()), "tool": tool, "summary": summary},
                "event": threading.Event(), "result": False};
        self.lock.acquire();
        self.pending[card["ask"]["id"]] = card;
        self.lock.release();
        self.hooks["open"](card["ask"]);
        self._wait(card);
        return card["result"];
    }

    def question(tool: str, summary: str, questions: list[any]) -> any {
        if self.closed or self.signal.aborted { return None; }
        card: dict[str, any] = {"kind": "question", "ask": {"id": str(uuid.uuid4()), "tool": tool, "summary": summary},
                "event": threading.Event(), "result": None};
        self.lock.acquire();
        self.pending[card["ask"]["id"]] = card;
        self.lock.release();
        self.hooks["open_question"](card["ask"], questions);
        self._wait(card);
        return card["result"];
    }

    def finish(card: dict[str, any], source: str, decision: any) {
        self.lock.acquire();
        owned = self.pending.pop(card["ask"]["id"], None) is not None;
        self.lock.release();
        if not owned { return; }
        if card["kind"] == "permission" {
            allowed = isinstance(decision, dict) and decision.get("allowed") is True;
            card["result"] = allowed;
            self.hooks["resolved"](card["ask"], allowed, source);
        } else {
            # Only the person's reply resolves a question; a timeout or abort
            # resolves None so no system note can occupy the answer slot.
            msg = decision.get("message") if isinstance(decision, dict) else None;
            reply = msg if (isinstance(msg, str) and len(msg) > 0) else None;
            card["result"] = reply;
            self.hooks["resolved_question"](card["ask"], reply is not None, source);
        }
        card["event"].set();
    }

    def answer(request_id: any, behavior: any, message: any) -> str {
        self.lock.acquire();
        card = self.pending.get(request_id);
        self.lock.release();
        if card is None or self.signal.aborted { return "unavailable"; }
        if behavior == "deny" {
            self.finish(card, "user", None);
            return "rejected";
        }
        if card["kind"] == "permission" {
            # An answer is not a permission: only allow or deny settles it.
            if behavior != "allow" { return "unavailable"; }
            self.finish(card, "user", {"allowed": True});
            return "allowed-once";
        }
        # And an allow is not an answer: a question settles only on a real
        # reply, never a blank the model would have to interpret.
        if behavior == "answer" and isinstance(message, str) and message.strip() {
            self.finish(card, "user", {"message": message});
            return "answered";
        }
        return "unavailable";
    }

    def close {
        self.closed = True;
        self.lock.acquire();
        cards = list(self.pending.values());
        self.lock.release();
        for card in cards { self.finish(card, "system", None); }
    }
}

def _finisher(approval: ChatToolApproval, card: dict[str, any], source: str, decision: any) -> any {
    def run { approval.finish(card, source, decision); }
    return run;
}

def new_approval(signal: any, hooks: dict[str, any], timeout_ms: float = 900000.0) -> ChatToolApproval {
    return ChatToolApproval(signal=signal, hooks=hooks, timeout_ms=timeout_ms, pending={}, closed=False, lock=threading.Lock());
}

# ── HTTP ───────────────────────────────────────────────────────────────────

class IdleTimeoutError(Exception) {
}

def _idle_timeout() -> Exception {
    return IdleTimeoutError("Streaming idle timeout elapsed");
}

def _http_post(url: str, headers: dict[str, str], body: bytes, signal: any, timeout_ms: float) -> dict[str, any] {
    # fetch(url, {method: POST}) with an abort that closes the socket and an
    # idle timeout renewed on every read (socket timeout).
    parts = urllib.parse.urlsplit(url);
    path = parts.path or "/";
    if parts.query { path = path + "?" + parts.query; }
    timeout_s = max(timeout_ms, 1) / 1000.0;
    conn: any = None;
    if parts.scheme == "https" {
        conn = http.client.HTTPSConnection(parts.hostname, parts.port, timeout=timeout_s, context=ssl.create_default_context());
    } else {
        conn = http.client.HTTPConnection(parts.hostname, parts.port, timeout=timeout_s);
    }
    def kill {
        try {
            sock = conn.sock;
            if sock is not None { sock.shutdown(socket.SHUT_RDWR); }
        } except Exception {
        }
    }
    remove = signal.on_abort(kill);
    try {
        signal.throw_if_aborted();
        conn.request("POST", path, body=body, headers=headers);
        resp = conn.getresponse();
    } except AbortError as e {
        remove();
        conn.close();
        raise e;
    } except socket.timeout {
        remove();
        conn.close();
        if signal.aborted { raise AbortError("This operation was aborted"); }
        raise _idle_timeout();
    } except Exception as e {
        remove();
        conn.close();
        if signal.aborted { raise AbortError("This operation was aborted"); }
        raise Exception("fetch failed " + str(e));
    }
    return {"conn": conn, "resp": resp, "remove": remove};
}

def _read_chunk(handle: dict[str, any], signal: any) -> bytes {
    try {
        chunk = handle["resp"].read1(65536);
    } except socket.timeout {
        if signal.aborted { raise AbortError("This operation was aborted"); }
        raise _idle_timeout();
    } except Exception as e {
        if signal.aborted { raise AbortError("This operation was aborted"); }
        raise Exception("terminated " + str(e));
    }
    if signal.aborted { raise AbortError("This operation was aborted"); }
    return chunk;
}

def _read_all(handle: dict[str, any], signal: any) -> bytes {
    out: list[bytes] = [];
    while True {
        chunk = _read_chunk(handle, signal);
        if not chunk { break; }
        out.append(chunk);
    }
    return b"".join(out);
}

def _release(handle: dict[str, any]) {
    try { handle["remove"](); } except Exception { }
    try { handle["conn"].close(); } except Exception { }
}

def _get(value: any, key: str) -> any {
    return value.get(key) if isinstance(value, dict) else None;
}

def _coalesce(a: any, b: any) -> any {
    return a if a is not None else b;
}

def _report_key(rt: dict[str, any], rejected: bool) {
    # Node owns the shared key-rejection registry (key-rejections.ts); only
    # the key's fingerprint crosses the bridge.
    key = rt["options"]["api_key"];
    if not key { return; }
    _bridge("key_verdict", {
        "url": rt["options"]["api_url"],
        "fingerprint": key_fingerprint(key),
        "rejected": rejected,
    });
}

# ── one completion request ─────────────────────────────────────────────────

def complete(
    rt: dict[str, any],
    messages: list[any],
    model: str,
    stream: bool,
    signal: any,
    on_delta: any = None,
    tools: any = None,
    on_usage: any = None
) -> dict[str, any] {
    o = rt["options"];
    tool_defs = tools if isinstance(tools, list) else [];
    body: dict[str, any] = o["request_body"](model, messages, stream);
    if tool_defs { body["tools"] = tool_defs; }
    headers = {"authorization": "Bearer " + o["api_key"], "content-type": "application/json"};
    handle = _http_post(o["api_url"] + "/chat/completions", headers, _compact(body).encode("utf-8"), signal, o["timeout_ms"]);
    try {
        resp = handle["resp"];
        status = resp.status;
        if status < 200 or status >= 300 {
            try {
                text = _read_all(handle, signal).decode("utf-8", errors="replace");
            } except AbortError as e {
                raise e;
            } except Exception {
                text = "";
            }
            if rejects_key(status, text) { _report_key(rt, True); }
            message = o["http_error_label"] + " HTTP " + str(status) + ((": " + text[0:200]) if text else "");
            if rejects_tools_parameter(status, text) { raise UnsupportedChatToolsError(message); }
            refusal = refused_tool_call(status, text);
            if refusal is not None { raise rejected_tool_call_error(message, refusal); }
            replayed = False;
            for turn_rec in messages {
                if "reasoning_content" in turn_rec { replayed = True; }
            }
            if replayed and rejects_reasoning_replay(status, text) { raise UnsupportedReasoningReplayError(message); }
            raise Exception(message);
        }
        _report_key(rt, False);
        content_type = resp.getheader("content-type") or "";
        if not stream or "application/json" in content_type {
            return _complete_json(rt, handle, model, signal, on_usage);
        }
        return _complete_stream(rt, handle, signal, on_delta);
    } finally {
        _release(handle);
    }
}

def _content_text(o: dict[str, any], content: any) -> str {
    fn = o.get("content_text");
    if fn is not None { return fn(content); }
    return content if isinstance(content, str) else "";
}

glob MESSAGE_KEYS: list[str] = ["content", "reasoning_content", "reasoning", "reasoning_details", "tool_calls", "function_call"];

def _complete_json(rt: dict[str, any], handle: dict[str, any], model: str, signal: any, on_usage: any) -> dict[str, any] {
    o = rt["options"];
    raw = _read_all(handle, signal);
    try {
        data = json.loads(raw.decode("utf-8", errors="replace"));
    } except Exception as e {
        raise Exception("provider returned invalid JSON: " + str(e));
    }
    if on_usage is not None {
        signal.throw_if_aborted();
        usage = _get(data, "usage");
        details = _get(usage, "prompt_tokens_details");
        reported = _get(data, "model");
        usage_report: dict[str, any] = {"model": reported if (isinstance(reported, str) and reported.strip()) else model};
        counts = [
            ["input", usage_count(_get(usage, "prompt_tokens"))],
            ["output", usage_count(_get(usage, "completion_tokens"))],
            ["cachedInput", usage_count(_get(details, "cached_tokens"))],
            ["costUsd", usage_count(_get(usage, "cost"))],
        ];
        for pair in counts {
            if pair[1] is not None { usage_report[pair[0]] = pair[1]; }
        }
        on_usage(usage_report);
    }
    body_error = completion_error(data, "completion error");
    if body_error is not None {
        failure: Exception = body_error;
        raise failure;
    }
    choices = _get(data, "choices");
    first = choices[0] if (isinstance(choices, list) and len(choices) > 0) else None;
    message = _get(first, "message");
    has_key = False;
    if isinstance(message, dict) {
        for k in MESSAGE_KEYS {
            if k in message { has_key = True; }
        }
    }
    if not has_key { raise ChatProtocolError("provider returned no completion message"); }
    if message.get("function_call") {
        raise ChatProtocolError("legacy function_call is unsupported; use structured tool_calls");
    }
    calls = new_tool_calls();
    calls.add(message.get("tool_calls"), False);
    details_acc = new_reasoning_details();
    details_acc.add(message.get("reasoning_details"));
    reasoning = _coalesce(message.get("reasoning_content"), message.get("reasoning"));
    finish_reason = _coalesce(_get(first, "finish_reason"), None);
    signal.throw_if_aborted();
    return {
        "text": _content_text(o, message.get("content")),
        "reasoning": reasoning if (o.get("reasoning") and isinstance(reasoning, str)) else "",
        "usage": usage_from(_get(data, "usage")),
        "toolCalls": calls.finish(finish_reason, False),
        "finishReason": finish_reason,
        "protocolReasoning": reasoning if isinstance(reasoning, str) else "",
        "protocolReasoningDetails": details_acc.blocks,
    };
}

def _complete_stream(rt: dict[str, any], handle: dict[str, any], signal: any, on_delta: any) -> dict[str, any] {
    o = rt["options"];
    st: dict[str, any] = {
        "text": "", "reasoning": "", "protocol": "", "usage": None,
        "finish": None, "malformed": False, "saw_choice": False,
    };
    calls = new_tool_calls();
    details = new_reasoning_details();

    def consume(line: str, at_eof: bool) -> bool {
        if not line.startswith("data:") { return False; }
        data = line[5:].strip();
        if data == "[DONE]" { return True; }
        try {
            chunk = json.loads(data);
        } except Exception {
            # A tail left when the socket closed is an INCOMPLETE frame, not
            # a bad one; only a newline-terminated frame that will not parse
            # means the provider sent something malformed.
            if not at_eof { st["malformed"] = True; }
            return False;
        }
        chunk_error = completion_error(chunk, "streaming completion error");
        if chunk_error is not None {
            failure: Exception = chunk_error;
            raise failure;
        }
        choice: any = None;
        rows = _get(chunk, "choices");
        if isinstance(rows, list) {
            for row in rows {
                if isinstance(row, dict) and ("index" not in row or row["index"] == 0) and not isinstance(row.get("index"), bool) {
                    choice = row;
                    break;
                }
            }
        }
        delta = _get(choice, "delta");
        if isinstance(delta, dict) { st["saw_choice"] = True; }
        if _get(delta, "function_call") {
            raise ChatProtocolError("legacy function_call is unsupported; use structured tool_calls");
        }
        calls.add(_get(delta, "tool_calls"), True);
        details.add(_get(delta, "reasoning_details"));
        fr = _get(choice, "finish_reason");
        if fr { st["finish"] = fr; }
        part = _coalesce(_get(delta, "reasoning_content"), _get(delta, "reasoning"));
        if isinstance(part, str) { st["protocol"] = st["protocol"] + part; }
        reasoning_delta = part if (o.get("reasoning") and isinstance(part, str)) else "";
        content_delta = _content_text(o, _get(delta, "content"));
        if reasoning_delta {
            st["reasoning"] = st["reasoning"] + reasoning_delta;
            if on_delta is not None { on_delta(reasoning_delta, "reasoning_text"); }
        }
        if content_delta {
            st["text"] = st["text"] + content_delta;
            if on_delta is not None { on_delta(content_delta, "assistant_text"); }
        }
        usage = _get(chunk, "usage");
        if isinstance(usage, dict) { st["usage"] = usage_from(usage); }
        return False;
    }

    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace");
    buffer = "";
    done = False;
    while not done {
        chunk_bytes = _read_chunk(handle, signal);
        if not chunk_bytes {
            buffer = buffer + decoder.decode(b"", final=True);
            tail = buffer.strip();
            if tail and tail != "data: [DONE]" { consume(tail, True); }
            # MiniMax's api.minimax.io/v1 closes the connection after the
            # finish_reason chunk and never sends `[DONE]`.
            if tail == "data: [DONE]" or st["finish"] { break; }
            if not st["saw_choice"] {
                body: any = None;
                try {
                    body = json.loads(buffer);
                } except Exception {
                    body = None;
                }
                body_error = completion_error(body, "completion error") if body is not None else None;
                if body_error is not None {
                    failure: Exception = body_error;
                    raise failure;
                }
            }
            raise ChatProtocolError("Stream ended before completion");
        }
        buffer = buffer + decoder.decode(chunk_bytes);
        if len(buffer) > STREAM_BUFFER_CHARS {
            raise ChatProtocolError("provider stream frame exceeded the size limit");
        }
        while True {
            nl = buffer.find("\n");
            if nl < 0 { break; }
            line = buffer[0:nl].strip();
            buffer = buffer[nl + 1:];
            if consume(line, False) {
                done = True;
                break;
            }
        }
    }
    signal.throw_if_aborted();
    if not st["saw_choice"] { raise ChatProtocolError("provider returned no streaming completion choice"); }
    return {
        "text": st["text"], "reasoning": st["reasoning"], "usage": st["usage"],
        "toolCalls": calls.finish(st["finish"], st["malformed"]),
        "finishReason": st["finish"], "protocolReasoning": st["protocol"],
        "protocolReasoningDetails": details.blocks,
    };
}

# ── runtime ────────────────────────────────────────────────────────────────

def _rt(inst: dict[str, any]) -> dict[str, any] {
    return inst["chat_runtime"];
}

def _base(thread_id: str, turn_id: str) -> dict[str, any] {
    return {"threadId": thread_id, "turnId": turn_id};
}

def _emit(inst: dict[str, any], thread_id: str, turn_id: str, fields: dict[str, any]) {
    event = _base(thread_id, turn_id);
    event.update(fields);
    emit_event(inst, event);
}

def _default_model(rt: dict[str, any], turn: dict[str, any]) -> str {
    model = turn.get("model");
    if isinstance(model, str) and model { return model; }
    hinted = turn.get("defaultModel");
    if isinstance(hinted, str) and hinted { return hinted; }
    return rt["options"]["default_model"]();
}

def _sees_images(rt: dict[str, any], model: str) -> bool {
    fn = rt["options"].get("image_input");
    return True if fn is None else bool(fn(model));
}

def messages_for(rt: dict[str, any], turn: dict[str, any], model: str) -> list[any] {
    # The system message is the head of the resent prefix, so only the stable
    # half belongs there; the volatile half rides the newest user message,
    # every turn (the request is rebuilt from the stored transcript).
    o = rt["options"];
    halves = prompt_halves(turn);
    note = volatile_context_note(halves["volatile"], False) if halves["stable"] is not None else "";
    text: str = turn["text"] if isinstance(turn.get("text"), str) else "";
    user_text: str = with_context_note(note, text) if note else text;
    system = halves["stable"] if halves["stable"] is not None else turn.get("system");
    out: list[any] = [];
    if system { out.append({"role": "system", "content": system}); }
    transcript = turn.get("transcript");
    if isinstance(transcript, list) {
        for m in transcript {
            out.append({"role": m.get("role"), "content": m.get("text")});
        }
    }
    content: any = user_text;
    if o.get("computer_use") {
        if _sees_images(rt, model) {
            content = chat_user_content(turn, user_text);
        } elif isinstance(turn.get("images"), list) and len(turn["images"]) > 0 {
            content = user_text + "\n\n" + TEXT_ONLY_ATTACHMENT_NOTE;
        }
    }
    out.append({"role": "user", "content": content});
    return out;
}

def _turn_secrets(rt: dict[str, any], turn: dict[str, any]) -> list[str] {
    secrets: list[str] = [];
    if rt["options"]["api_key"] { secrets.append(rt["options"]["api_key"]); }
    integrations = turn.get("integrations");
    if not isinstance(integrations, dict) { return secrets; }
    for integration in integrations.values() {
        if not isinstance(integration, dict) { continue; }
        specs: list[any] = [integration] if "command" in integration else list(integration.values());
        for spec in specs {
            env = _get(spec, "env");
            if not isinstance(env, dict) { continue; }
            for (k, v) in env.items() {
                if SECRET_ENV_KEY_RE.search(k) is not None and isinstance(v, str) and v { secrets.append(v); }
            }
        }
    }
    return secrets;
}

def _map_strings(value: any, fn: any) -> any {
    if isinstance(value, str) { return fn(value); }
    if isinstance(value, list) { return [_map_strings(v, fn) for v in value]; }
    if isinstance(value, dict) {
        out: dict[str, any] = {};
        for (k, v) in value.items() { out[k] = _map_strings(v, fn); }
        return out;
    }
    return value;
}

def _err_text(e: Exception) -> str {
    text = str(e);
    return text if text else type(e).__name__;
}

def _interruptible_delay(ms: float, signal: any) {
    ev = threading.Event();
    remove = signal.on_abort(ev.set);
    if not signal.aborted { ev.wait(max(ms, 1) / 1000.0); }
    remove();
}

def send_turn(inst: dict[str, any], turn: dict[str, any]) -> str {
    rt = _rt(inst);
    o = rt["options"];
    if not o["api_key"] { raise Exception(o["missing_key_error"]); }
    thread_id = turn["threadId"];
    rt["lock"].acquire();
    busy = thread_id in rt["active"];
    rt["lock"].release();
    if busy { raise Exception("a turn is already running on this thread"); }
    integrations: dict[str, any] = turn["integrations"] if isinstance(turn.get("integrations"), dict) else {};
    if o.get("computer_use") and (turn.get("images") or integrations.get("localComputer") or integrations.get("browser")) {
        assert_image_transport(o["api_url"]);
    }
    turn_id = str(uuid.uuid4());
    model = _default_model(rt, turn);
    messages = messages_for(rt, turn, model);
    retain_images = chat_image_budget();
    for message in messages { retain_images(message.get("content")); }
    signal = new_signal();
    hooks: dict[str, any] = {};
    def open_card(ask: dict[str, any]) {
        _emit(inst, thread_id, turn_id, {"type": "request.opened", "requestType": "permission",
            "requestId": ask["id"], "tool": ask["tool"], "summary": ask["summary"], "allowSession": False});
    }
    def resolved_card(ask: dict[str, any], allowed: bool, source: str) {
        _emit(inst, thread_id, turn_id, {"type": "request.resolved", "requestId": ask["id"],
            "behavior": "allow" if allowed else "deny", "source": source});
    }
    def open_question(ask: dict[str, any], questions: list[any]) {
        ev: dict[str, any] = {"type": "request.opened", "requestType": "question",
            "requestId": ask["id"], "tool": ask["tool"], "summary": ask["summary"], "questions": questions};
        choices = question_choices(questions);
        if choices { ev["choices"] = choices; }
        _emit(inst, thread_id, turn_id, ev);
    }
    def resolved_question(ask: dict[str, any], answered: bool, source: str) {
        _emit(inst, thread_id, turn_id, {"type": "request.resolved", "requestId": ask["id"],
            "behavior": "answer" if answered else "deny", "source": source});
    }
    hooks.update({"open": open_card, "resolved": resolved_card, "open_question": open_question, "resolved_question": resolved_question});
    approval = new_approval(signal, hooks, rt["approval_timeout_ms"]);
    turn_rec: dict[str, any] = {"signal": signal, "turn_id": turn_id, "done": threading.Event(), "approval": approval, "asides": []};
    rt["lock"].acquire();
    rt["active"][thread_id] = turn_rec;
    rt["lock"].release();
    inst["live"][thread_id] = {"turn_id": turn_id};
    _emit(inst, thread_id, turn_id, {"type": "turn.started"});
    _emit(inst, thread_id, turn_id, {"type": "session.started", "sessionId": None, "model": model});
    threading.Thread(target=_run_turn, args=(inst, turn, turn_rec, messages, model, retain_images), daemon=True).start();
    return turn_id;
}

def _run_turn(
    inst: dict[str, any],
    turn: dict[str, any],
    turn_rec: dict[str, any],
    messages: list[any],
    model: str,
    retain_images: any
) {
    rt = _rt(inst);
    o = rt["options"];
    thread_id = turn["threadId"];
    turn_id = turn_rec["turn_id"];
    signal = turn_rec["signal"];
    approval = turn_rec["approval"];
    secrets = _turn_secrets(rt, turn);
    source = o["native_log"]["source"];

    def emit(fields: dict[str, any]) { _emit(inst, thread_id, turn_id, fields); }
    def safe_text(text: str) -> str {
        safe = text;
        for secret in secrets {
            if secret { safe = safe.replace(secret, "[redacted]"); }
        }
        return redact_secrets_in_text(safe);
    }
    def preview(value: any) -> any {
        return tool_detail_preview(_map_strings(json.loads(_compact(value)), safe_text));
    }
    def native(direction: str, msg: any) {
        append_native(thread_id, direction, source, _map_strings(json.loads(_compact(msg)), safe_text));
    }

    st: dict[str, any] = {
        "tools": None, "usage": {"input": 0, "output": 0}, "has_usage": False, "ok": False,
        "stop_reason": None, "failure": None, "tool_failed": False, "nudged": False,
    };
    denials: list[str] = [];
    seen_calls: dict[str, bool] = {};
    try {
        parsed = parse_tool_scope(turn.get("toolScope"));
        if not parsed["ok"] { raise Exception(parsed["error"]); }
        scope = parsed["scope"];
        tools = mount_chat_tools(
            None if o.get("tools") is False else turn.get("integrations"),
            signal, bool(o.get("computer_use")), scope, turn.get("mcpCallTimeoutMs"),
        );
        st["tools"] = tools;
        question_allowed = o.get("tools") is not False and allows_tool(scope, "native", ASK_USER_TOOL);
        optional_question_only = question_allowed and len(tools.definitions) == 0;
        # ask_user is how a chat-completions engine reaches a person. An MCP
        # server that squats the name cannot shadow it (dispatch intercepts
        # the name first), but the list never advertises two.
        squatted = False;
        for d in tools.definitions {
            if d["function"]["name"] == ASK_USER_TOOL { squatted = True; }
        }
        if question_allowed and not squatted { tools.definitions.append(ASK_USER_TOOL_DEFINITION); }
        round = 0;
        while round < MAX_CHAT_ROUNDS {
            signal.throw_if_aborted();
            # Drain parked mid-turn input before the next request: the last
            # round's tool results are complete, so the aside lands on a
            # consistent array (never inside a tool batch).
            rt["lock"].acquire();
            parked = list(turn_rec["asides"]);
            turn_rec["asides"].clear();
            rt["lock"].release();
            if parked { messages.append({"role": "user", "content": "\n\n".join(parked)}); }
            native("out", o["native_log"]["outgoing"](turn, messages, model, tools.definitions));
            attempt = 0;
            completion: dict[str, any] = {};
            while True {
                flags: dict[str, any] = {"streamed": False, "answer_streamed": False};
                pending: dict[str, str] = {"assistant_text": "", "reasoning_text": ""};
                def delta(text: str, stream_kind: str, flush: bool = False) {
                    combined = pending[stream_kind] + text;
                    # Mask complete matches before holding a suffix, so a key
                    # like "abab" is never split at its own repeated prefix.
                    for secret in secrets {
                        if secret { combined = combined.replace(secret, "[redacted]"); }
                    }
                    hold = 0;
                    # A credential can straddle chunks: hold any suffix that
                    # could be its prefix until the next chunk decides it.
                    if not flush {
                        for secret in secrets {
                            length = min(len(secret) - 1, len(combined));
                            while length > hold {
                                if combined.endswith(secret[0:length]) {
                                    hold = length;
                                    break;
                                }
                                length -= 1;
                            }
                        }
                    }
                    pending[stream_kind] = combined[len(combined) - hold:] if hold else "";
                    visible = safe_text(combined[0:len(combined) - hold] if hold else combined);
                    if visible { emit({"type": "content.delta", "streamKind": stream_kind, "delta": visible}); }
                }
                def on_delta(text: str, stream_kind: str) {
                    flags["streamed"] = True;
                    if stream_kind == "assistant_text" { flags["answer_streamed"] = True; }
                    delta(text, stream_kind);
                }
                try {
                    completion = complete(rt, messages, model, True, signal, on_delta, tools.definitions);
                    delta("", "assistant_text", True);
                    delta("", "reasoning_text", True);
                    break;
                } except Exception as error {
                    verdict = classify_error(_err_text(error));
                    # A schema rejection of the echoed reasoning executed
                    # nothing upstream; the stripped resend cannot loop.
                    if isinstance(error, UnsupportedReasoningReplayError) and not flags["streamed"] and not signal.aborted {
                        rt["reasoning_replay_rejected"][model] = True;
                        for m in messages { m.pop("reasoning_content", None); }
                        continue;
                    }
                    # A refused tool call ran nothing, so the same request
                    # goes again — not once answer text streamed (the live
                    # bubble would join attempts). Each refusal is logged.
                    if isinstance(error, RejectedToolCallError) {
                        native("in", {"refused": "tool_use_failed", "attempt": attempt + 1, "error": getattr(error, "refusal", None)});
                        if not flags["answer_streamed"] and not signal.aborted and attempt < RETRY_MAX_ATTEMPTS - 1 {
                            attempt += 1;
                            emit({"type": "turn.retrying", "attempt": attempt, "delayMs": 0, "reason": "tool_use_failed"});
                            continue;
                        }
                        if not signal.aborted {
                            raise ChatProtocolError(refused_tool_call_failure(error, len(seen_calls) > 0));
                        }
                    }
                    # Only our optional question changed a previously plain
                    # request; never downgrade mounted tools, streamed output
                    # or a handled call.
                    if (
                        optional_question_only and round == 0 and not flags["streamed"] and not seen_calls
                        and not signal.aborted and isinstance(error, UnsupportedChatToolsError)
                        and verdict["reason"] == "invalid_request"
                    ) {
                        optional_question_only = False;
                        tools.definitions.clear();
                        continue;
                    }
                    # Once a call has been handled, never replay it.
                    if (
                        o.get("retry_scale") is None or signal.aborted or flags["streamed"] or seen_calls
                        or isinstance(error, ChatProtocolError) or not verdict["transient"]
                        or attempt >= RETRY_MAX_ATTEMPTS - 1
                    ) {
                        raise error;
                    }
                    delay_ms = compute_backoff(attempt);
                    attempt += 1;
                    emit({"type": "turn.retrying", "attempt": attempt, "delayMs": delay_ms, "reason": verdict["reason"]});
                    _interruptible_delay(delay_ms * o["retry_scale"], signal);
                    signal.throw_if_aborted();
                }
            }
            native("in", o["native_log"]["incoming"](completion));
            if completion["usage"] is not None {
                st["usage"]["input"] = st["usage"]["input"] + completion["usage"]["input"];
                st["usage"]["output"] = st["usage"]["output"] + completion["usage"]["output"];
                st["has_usage"] = True;
                emit({"type": "thread.token-usage.updated", "input": st["usage"]["input"], "output": st["usage"]["output"]});
            }
            # Reasoning on a tool-call round belongs to the protocol.
            reply = completion["text"];
            if not reply.strip() {
                reply = "" if completion["toolCalls"] else completion["reasoning"];
            }
            if reply.strip() { emit({"type": "item.completed", "itemType": "assistant_text", "text": safe_text(reply)}); }
            signal.throw_if_aborted();
            if not completion["toolCalls"] {
                if not reply.strip() { raise ChatProtocolError("provider returned an empty response"); }
                fr = completion["finishReason"];
                if fr and fr != "stop" {
                    raise ChatProtocolError("provider did not finish the response (" + str(fr) + ")");
                }
                if o.get("nudge_announced_action") and not st["nudged"] and tools.definitions and announces_action(completion["text"]) {
                    st["nudged"] = True;
                    messages.append({"role": "assistant", "content": completion["text"]});
                    messages.append({"role": "user", "content": NUDGE_ANNOUNCED_ACTION});
                    round += 1;
                    continue;
                }
                if st["tool_failed"] {
                    # A failed or denied tool op ends the turn: the final
                    # answer is not an execution receipt.
                    st["stop_reason"] = "tool_error";
                    raise ChatProtocolError("One or more tool operations failed or were denied. See the tool results; the final response is not an execution receipt.");
                }
                st["ok"] = True;
                break;
            }
            if not tools.definitions {
                raise ChatProtocolError("provider returned tool calls, but no tools are available for this turn");
            }
            # Validate IDs for the entire batch before executing any of it.
            for call in completion["toolCalls"] {
                if call["id"] in seen_calls {
                    raise ChatProtocolError("provider reused a tool-call ID; refusing to repeat an operation");
                }
                seen_calls[call["id"]] = True;
            }
            # The whole batch is refused before any of it runs.
            if len(seen_calls) > MAX_TURN_TOOL_CALLS {
                raise ChatProtocolError(stopped_after(str(MAX_TURN_TOOL_CALLS) + " tool calls"));
            }
            assistant: dict[str, any] = {"role": "assistant", "content": completion["text"] or None, "tool_calls": completion["toolCalls"]};
            if completion["protocolReasoning"] and model not in rt["reasoning_replay_rejected"] {
                assistant[o.get("reasoning_replay_field") or "reasoning_content"] = completion["protocolReasoning"];
            }
            if completion["protocolReasoningDetails"] {
                assistant["reasoning_details"] = completion["protocolReasoningDetails"];
            }
            messages.append(assistant);
            screenshot_parts: list[any] = [];
            for call in completion["toolCalls"] {
                signal.throw_if_aborted();
                result: dict[str, any] = {};
                started = False;
                fatal: any = None;
                name = call["function"]["name"];
                try {
                    try {
                        args = json.loads(call["function"]["arguments"]);
                    } except Exception {
                        raise ChatProtocolError("tool arguments are not complete JSON");
                    }
                    if not isinstance(args, dict) { raise ChatProtocolError("tool arguments must be a JSON object"); }
                    input_preview = preview(args);
                    started_event: dict[str, any] = {"type": "item.started", "itemType": "tool", "itemId": call["id"], "title": name};
                    if input_preview { started_event["input"] = input_preview; }
                    if name == ASK_USER_TOOL {
                        if not question_allowed or not allows_tool(scope, "native", ASK_USER_TOOL) {
                            raise Exception("Tool selection excludes this tool");
                        }
                        # A question is the person's card, not a permission:
                        # handled before the gate, so Full access never
                        # auto-runs it and Ask never renders Allow/Deny.
                        questions = parse_ask_questions(args);
                        signal.throw_if_aborted();
                        emit(started_event);
                        started = True;
                        if questions is None {
                            denials.append(ASK_USER_TOOL);
                            result = {"ok": False, "text": "The ask_user arguments are malformed: pass a JSON object with a questions array of one to six questions, each with a question string and at most twelve options carrying a label. Ask again with valid arguments."};
                        } else {
                            # The tool result is the card's Q:/A: reply verbatim.
                            answer = approval.question(ASK_USER_TOOL, ask_question_summary(questions), questions);
                            signal.throw_if_aborted();
                            if answer is None {
                                denials.append(ASK_USER_TOOL);
                                result = {"ok": False, "text": "The person did not answer this question. Do not guess an answer; ask again later or proceed without it."};
                            } else {
                                result = {"ok": True, "text": answer};
                            }
                        }
                    } else {
                        tools.validate(name, args);
                        # Full access is the person's explicit grant to answer
                        # every prompt; this runtime has no provider reviewer,
                        # so it is honoured here.
                        allowed = turn.get("approvalMode") == "full" or approval.ask(name, input_preview or "This tool has no arguments.");
                        signal.throw_if_aborted();
                        emit(started_event);
                        started = True;
                        if allowed {
                            result = tools.execute(name, args, signal);
                            if result.get("images") and not _sees_images(rt, model) {
                                result = {"ok": result["ok"], "text": result["text"] + "\n" + TEXT_ONLY_SCREENSHOT_NOTE};
                            }
                            if result.get("images") {
                                try {
                                    assert_image_transport(o["api_url"]);
                                    retain_images(result["images"]);
                                } except Exception as image_error {
                                    raise ChatToolSessionError(_err_text(image_error));
                                }
                            }
                        } else {
                            denials.append(name);
                            result = {"ok": False, "text": "Permission denied or expired; the tool was not executed."};
                        }
                    }
                } except Exception as error {
                    if isinstance(error, ChatToolSessionError) { fatal = error; }
                    if signal.aborted {
                        result = {"ok": False, "text": "Tool interrupted; an operation already dispatched may have taken effect. Verify its state before retrying."};
                    } else {
                        result = {"ok": False, "text": safe_text(_err_text(error))[0:2000]};
                    }
                }
                if not started {
                    emit({"type": "item.started", "itemType": "tool", "itemId": call["id"], "title": name});
                }
                text = safe_text(result["text"]);
                output = preview({"ok": result["ok"], "result": text});
                emit({"type": "item.completed", "itemType": "tool", "itemId": call["id"], "ok": result["ok"], "output": output});
                if not result["ok"] { st["tool_failed"] = True; }
                messages.append({"role": "tool", "tool_call_id": call["id"], "content": _compact({"ok": result["ok"], "result": text})});
                screenshot_parts.extend(chat_tool_images(call["id"], result.get("images")));
                signal.throw_if_aborted();
                if fatal is not None {
                    fatal_error: Exception = fatal;
                    raise fatal_error;
                }
            }
            if screenshot_parts { messages.append({"role": "user", "content": screenshot_parts}); }
            round += 1;
        }
        if not st["ok"] { raise ChatProtocolError(stopped_after(str(MAX_CHAT_ROUNDS) + " steps")); }
    } except Exception as error {
        st["stop_reason"] = "interrupted" if signal.aborted else (st["stop_reason"] or "error");
        st["failure"] = safe_text(_err_text(error))[0:2000];
    } finally {
        approval.close();
        cleanup_failed = False;
        if st["tools"] is not None {
            try {
                st["tools"].close();
            } except Exception {
                st["ok"] = False;
                st["stop_reason"] = "error";
                cleanup_failed = True;
                st["failure"] = "Tool processes could not be stopped; their execution state is uncertain.";
            }
        }
        if signal.aborted {
            st["ok"] = False;
            st["stop_reason"] = "interrupted";
        }
        if st["failure"] and (not signal.aborted or cleanup_failed) {
            emit({"type": "runtime.error", "message": st["failure"], "terminal": not signal.aborted});
        }
        # Automatic continuity: a resumable terminal (the step cap) persists
        # a handoff and raises cap.exhausted.
        if not st["ok"] and not signal.aborted {
            continuable = classify_continuable(st["stop_reason"], st["failure"]);
            if continuable {
                handoff = write_turn_handoff({
                    "threadId": thread_id, "turnId": turn_id, "model": model,
                    "usage": st["usage"], "hasUsage": st["has_usage"], "failure": st["failure"],
                    "toolCalls": len(seen_calls), "messages": messages,
                });
                if handoff { emit({"type": "cap.exhausted", "handoffPath": handoff, "reason": continuable}); }
            }
        }
        rt["lock"].acquire();
        if rt["active"].get(thread_id) is turn_rec { rt["active"].pop(thread_id, None); }
        rt["lock"].release();
        live = inst["live"].get(thread_id);
        if live is not None and live.get("turn_id") == turn_id { inst["live"].pop(thread_id, None); }
        completed: dict[str, any] = {"type": "turn.completed", "ok": st["ok"], "stopReason": st["stop_reason"], "cost": None};
        if st["has_usage"] and (o.get("include_usage_in_completed") or len(seen_calls) > 0) {
            completed["usage"] = st["usage"];
        }
        if denials { completed["denials"] = denials; }
        emit(completed);
        turn_rec["done"].set();
    }
}

# ── adapter ops ────────────────────────────────────────────────────────────

def interrupt_turn(inst: dict[str, any], thread_id: any, turn_id: any) {
    rt = _rt(inst);
    rt["lock"].acquire();
    turn_rec = rt["active"].get(thread_id);
    rt["lock"].release();
    if turn_rec is None or (turn_id and turn_rec["turn_id"] != turn_id) { return; }
    turn_rec["signal"].abort();
    turn_rec["done"].wait(INTERRUPT_WAIT_S);
}

def respond(inst: dict[str, any], thread_id: any, request_id: any, decision: dict[str, any]) -> str {
    rt = _rt(inst);
    rt["lock"].acquire();
    turn_rec = rt["active"].get(thread_id);
    rt["lock"].release();
    if turn_rec is None { return "unavailable"; }
    return turn_rec["approval"].answer(request_id, decision.get("behavior"), decision.get("message"));
}

def steer(inst: dict[str, any], thread_id: any, text: str) -> str {
    # Parking the words in the live turn's turn_rec IS delivery into the loop;
    # a missing turn is the only refusal.
    rt = _rt(inst);
    rt["lock"].acquire();
    turn_rec = rt["active"].get(thread_id);
    if turn_rec is not None { turn_rec["asides"].append(text); }
    rt["lock"].release();
    return "refused" if turn_rec is None else "steered";
}

def stop_all(inst: dict[str, any]) {
    rt = _rt(inst);
    rt["lock"].acquire();
    entries = list(rt["active"].values());
    rt["lock"].release();
    for turn_rec in entries { turn_rec["signal"].abort(); }
    for turn_rec in entries { turn_rec["done"].wait(INTERRUPT_WAIT_S); }
}

def generate_text(inst: dict[str, any], prompt: str, options: dict[str, any]) -> dict[str, any] {
    # Returns {text} on success, {failure} on error, plus the usage usage_report
    # when the provider billed one: node's onUsage callback cannot cross the
    # op queue, so the shim replays it from this dict.
    rt = _rt(inst);
    o = rt["options"];
    gen = o.get("generate_model");
    model = gen() if gen is not None else "";
    if not model {
        hinted = options.get("defaultModel");
        model = hinted if (isinstance(hinted, str) and hinted) else o["default_model"]();
    }
    reports: list[any] = [];
    out: dict[str, any] = {};
    try {
        c = complete(rt, [{"role": "user", "content": prompt}], model, False, new_signal(), None, [], reports.append);
        if c["toolCalls"] { raise ChatProtocolError("provider returned tool calls to a text-only helper"); }
        out["text"] = c["text"] if c["text"].strip() else c["reasoning"];
    } except Exception as e {
        out["failure"] = _err_text(e);
    }
    if reports { out["usage"] = reports[0]; }
    return out;
}

# ── runtime factory ────────────────────────────────────────────────────────

def create_openai_chat_runtime(inst: dict[str, any], options: dict[str, any]) {
    # options: driver_kind, api_key, api_url, request_body(model, messages,
    # stream), http_error_label, missing_key_error, timeout_ms,
    # native_log{source, outgoing, incoming}, default_model(); optional:
    # generate_model, reasoning, reasoning_replay_field, content_text,
    # include_usage_in_completed, retry_scale, tools, computer_use,
    # image_input, nudge_announced_action.
    inst["chat_runtime"] = {
        "options": options,
        "active": {},
        "reasoning_replay_rejected": {},
        "lock": threading.Lock(),
        "approval_timeout_ms": APPROVAL_TIMEOUT_MS,
    };
}

def chat_runtime_impl(create_fn: any) -> dict[str, any] {
    # The drivers.jac impl table every chat-completions kind registers.
    def dispose(inst: dict[str, any]) { stop_all(inst); }
    return {
        "create": create_fn,
        "send_turn": send_turn,
        "interrupt_turn": interrupt_turn,
        "respond": respond,
        "steer": steer,
        "stop_all": stop_all,
        "dispose": dispose,
        "generate_text": generate_text,
    };
}

# ── openai-compat (server/drivers/openai-compat.ts) ────────────────────────

glob OPENAI_COMPAT_KIND: str = "openai-compat";
glob DEFAULT_KEY_ENV: str = "OPENAI_COMPAT_API_KEY";
glob OWN_KEY_ENVS: list[str] = ["OMB_OPENAI_API_KEY", "OMB_OPENROUTER_API_KEY"];
glob DEFAULT_IDLE_TIMEOUT_MS: int = 180000;
glob DEFAULT_COMPAT_MODEL: str = "meta-llama/llama-3.3-70b-instruct";
glob DEFAULT_OPENAI_MODEL: str = "gpt-5";

def openai_compat_idle_timeout_ms() -> int {
    raw = os.environ.get("OPENMAUS_OPENAI_COMPAT_IDLE_TIMEOUT_MS");
    if not raw { return DEFAULT_IDLE_TIMEOUT_MS; }
    try {
        value = float(raw);
    } except Exception {
        return DEFAULT_IDLE_TIMEOUT_MS;
    }
    if value.is_integer() and value >= 1000 and value <= 2147483647 { return int(value); }
    return DEFAULT_IDLE_TIMEOUT_MS;
}

def is_openrouter_url(url: str) -> bool {
    try {
        host = (urllib.parse.urlsplit(url).hostname or "").lower();
    } except Exception {
        return False;
    }
    return host == "openrouter.ai" or host.endswith(".openrouter.ai");
}

def _first_defined(values: list[any]) -> any {
    # The `??` chain: "" stops it, None does not.
    for v in values {
        if v is not None { return v; }
    }
    return None;
}

def openai_compat_options(inst: dict[str, any]) -> dict[str, any] {
    config = inst["config"];
    env = inst["environment"];
    url = str(config.get("url") or "https://openrouter.ai/api/v1").rstrip("/");
    key_env = config.get("apiKeyEnv") if (isinstance(config.get("apiKeyEnv"), str) and config.get("apiKeyEnv")) else DEFAULT_KEY_ENV;
    own_variable = key_env != DEFAULT_KEY_ENV;
    configured_key = config.get("key") if (isinstance(config.get("key"), str) and config.get("key")) else None;
    api_key = _first_defined([
        configured_key,
        env.get(key_env),
        None if own_variable else env.get(DEFAULT_KEY_ENV),
        os.environ.get(key_env),
        None if own_variable else os.environ.get(DEFAULT_KEY_ENV),
        "",
    ]);
    missing = "No API key — open Settings → API keys.";
    if own_variable and key_env not in OWN_KEY_ENVS {
        missing = "no API key — set " + key_env + " or add it to the instance config";
    }
    model_pin = config.get("model") if (isinstance(config.get("model"), str) and config.get("model")) else None;
    managed = config.get("managedModels") if isinstance(config.get("managedModels"), list) else None;
    seeded = DEFAULT_OPENAI_MODEL if config.get("catalog") == "openai" else DEFAULT_COMPAT_MODEL;
    provider = config.get("provider") if (isinstance(config.get("provider"), str) and config.get("provider")) else None;
    def default_model() -> str {
        if managed { return managed[0]; }
        return model_pin or seeded;
    }
    def request_body(model: str, messages: list[any], stream: bool) -> dict[str, any] {
        body: dict[str, any] = {"model": model, "messages": messages, "stream": stream};
        if stream { body["stream_options"] = {"include_usage": True}; }
        if provider and is_openrouter_url(url) {
            body["provider"] = {"order": [provider], "allow_fallbacks": False};
        }
        return body;
    }
    def outgoing(turn: any, messages: list[any], model: str, tools: list[any]) -> dict[str, any] {
        # Tool names answer "did the harness send them?" — the proxy hop
        # after this point is what drops tools silently.
        return {"model": model, "messageCount": len(messages), "tools": [t["function"]["name"] for t in tools]};
    }
    def incoming(c: dict[str, any]) -> dict[str, any] {
        return {"textLength": _js_len(c["text"]), "reasoningLength": _js_len(c["reasoning"]), "usage": c["usage"]};
    }
    return {
        "driver_kind": OPENAI_COMPAT_KIND,
        "api_key": api_key,
        "api_url": url,
        "tools": config.get("tools") if isinstance(config.get("tools"), bool) else None,
        "computer_use": True,
        "default_model": default_model,
        "request_body": request_body,
        "http_error_label": "upstream",
        "missing_key_error": missing,
        "unavailable_reason": missing,
        "timeout_ms": openai_compat_idle_timeout_ms(),
        "reasoning": True,
        "billing": "metered",
        "include_usage_in_completed": True,
        "native_log": {"source": "openai-compat.chat.completions", "outgoing": outgoing, "incoming": incoming},
    };
}

def _openai_compat_create(inst: dict[str, any]) {
    create_openai_chat_runtime(inst, openai_compat_options(inst));
}

with entry {
    driver_register_kind(OPENAI_COMPAT_KIND, chat_runtime_impl(_openai_compat_create));
}
