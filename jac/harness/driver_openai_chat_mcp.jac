"""Per-turn MCP transport for the shared chat-completions runtime — the Jac
port of server/drivers/chat-mcp-tools.ts and chat-images.ts.

Approval is owned by the caller; only registered, schema-validated calls
reach this file. Each mounted server is a stdio child in its own process
group (remote http/sse servers ride the node mcp-remote-proxy as a stdio
facade, exactly as mcpStdioServer does), spoken to over newline-delimited
JSON-RPC. Cancellation is an AbortSignal-shaped object so the runtime's
"abort closes execution authority" rule reads the same as the TS code."""

import os;
import re;
import json;
import time;
import base64;
import threading;
import subprocess;
import urllib.parse;

import from driver_claude_support {
    parse_tool_scope, allows_tool, can_use_mcp_server, augmented_path,
    CONTROL_PLANE_ENV, CONTROL_PLANE_ENV_PREFIX, remote_mcp_spec,
    node_exec_path, resolve_proxy, NODE_ENV_FLAG,
}
import from driver_claude { _kill_cli_tree }
import from driver_openai_chat_protocol { ChatToolSessionError }
import from driver_openai_chat_schema { compile_tool_schema }

glob STARTUP_MS: int = 8000;
# Historic per-call ceiling for a bot's MCP tools; a turn can override it
# with turn.mcpCallTimeoutMs (server config `mcp.callTimeoutMinutes`).
glob DEFAULT_CALL_MS: int = 600000;
glob FRAME_BYTES: int = 2097152;
glob IMAGE_FRAME_BYTES: int = 33554432;
glob OUTPUT_BYTES: int = 51200;
glob TOOL_COUNT: int = 128;
glob MAX_PAGES: int = 100;
glob SCHEMA_BYTES: int = 65536;
glob CATALOG_BYTES: int = 1048576;
glob MAX_FRAMES: int = 10000;
glob MAX_SERVERS: int = 32;
glob KILL_GRACE_MS: float = 5000.0;

# ── abort signals (the AbortController/AbortSignal pair) ───────────────────

class AbortError(Exception) {
}

obj AbortSignal {
    # One-shot: abort() runs each listener once, in registration order.
    # A listener added after the abort never fires (DOM semantics).
    has aborted: bool = False,
        listeners: list[any] = [],
        lock: any = None;

    def abort {
        self.lock.acquire();
        if self.aborted {
            self.lock.release();
            return;
        }
        self.aborted = True;
        fns = list(self.listeners);
        self.listeners.clear();
        self.lock.release();
        for fn in fns {
            try {
                fn();
            } except Exception {
            }
        }
    }

    def on_abort(fn: any) -> any {
        # Returns the remover (removeEventListener).
        self.lock.acquire();
        if not self.aborted { self.listeners.append(fn); }
        self.lock.release();
        def remove {
            self.lock.acquire();
            if fn in self.listeners { self.listeners.remove(fn); }
            self.lock.release();
        }
        return remove;
    }

    def throw_if_aborted {
        if self.aborted { raise AbortError("This operation was aborted"); }
    }
}

def new_signal() -> AbortSignal {
    return AbortSignal(aborted=False, listeners=[], lock=threading.Lock());
}

def any_signal(signals: list[any]) -> AbortSignal {
    # AbortSignal.any: aborted as soon as any source is.
    out = new_signal();
    for s in signals {
        if s.aborted {
            out.abort();
            return out;
        }
    }
    for s in signals {
        s.on_abort(out.abort);
    }
    return out;
}

def _aborted() -> Exception {
    return Exception("MCP operation cancelled");
}

def _byte_len(value: any) -> int {
    return len(json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8"));
}

# ── images (chat-images.ts) ────────────────────────────────────────────────

glob IMAGE_BYTES: int = 20971520;
glob IMAGE_MIME: list[str] = ["image/png", "image/jpeg", "image/webp", "image/gif"];
glob CHAT_IMAGE_BUDGET: int = 33554432;
glob BASE64_RE: any = re.compile(r"^[A-Za-z0-9+/]*={0,2}\Z");

def chat_image_budget() -> any {
    # Bound retained base64 before JSON serialization or another model call.
    used: dict[str, int] = {"n": 0};
    def retain(parts: any) {
        if not isinstance(parts, list) { return; }
        added = 0;
        for part in parts {
            if isinstance(part, dict) and part.get("type") == "image_url" {
                added += len(part["image_url"]["url"]);
            }
        }
        if used["n"] + added > CHAT_IMAGE_BUDGET {
            raise Exception("Turn image budget exceeded (32 MiB encoded); screenshot cannot be retained. An operation may already have taken effect; inspect its state before retrying.");
        }
        used["n"] = used["n"] + added;
    }
    return retain;
}

def assert_image_transport(url: str) {
    endpoint = urllib.parse.urlsplit(url);
    host = (endpoint.hostname or "").lower();
    loopback = host == "localhost" or host == "::1" or re.match(r"^127(?:\.\d{1,3}){3}\Z", host) is not None;
    if endpoint.scheme != "https" and not (endpoint.scheme == "http" and loopback) {
        raise Exception("Images and computer tools require HTTPS for remote API endpoints; HTTP is supported only on loopback.");
    }
}

def chat_image(item: dict[str, any]) -> dict[str, any] {
    mime = item.get("mimeType");
    data = item.get("data");
    if (
        not isinstance(mime, str) or mime not in IMAGE_MIME or not isinstance(data, str)
        or not data or len(data) > ((IMAGE_BYTES + 2) // 3) * 4 or len(data) % 4
        or BASE64_RE.match(data) is None
    ) {
        raise Exception("Invalid or oversized MCP image");
    }
    try {
        raw = base64.b64decode(data, validate=True);
    } except Exception {
        raise Exception("Image bytes do not match the declared MIME type");
    }
    matches = False;
    if mime == "image/png" {
        matches = len(raw) >= 33 and raw[0:8] == bytes.fromhex("89504e470d0a1a0a") and raw[12:16] == b"IHDR";
    } elif mime == "image/jpeg" {
        matches = len(raw) >= 4 and raw[0] == 0xff and raw[1] == 0xd8 and raw[2] == 0xff;
    } elif mime == "image/gif" {
        matches = len(raw) >= 13 and raw[0:6] in (b"GIF87a", b"GIF89a");
    } else {
        matches = len(raw) >= 16 and raw[0:4] == b"RIFF" and raw[8:12] == b"WEBP";
    }
    if len(raw) > IMAGE_BYTES or base64.b64encode(raw).decode("ascii") != data or not matches {
        raise Exception("Image bytes do not match the declared MIME type");
    }
    return {"type": "image_url", "image_url": {"url": "data:" + mime + ";base64," + data}};
}

def chat_user_content(turn: dict[str, any], text: str) -> any {
    images = turn.get("images");
    if not isinstance(images, list) or not images { return text; }
    budget = chat_image_budget();
    parts: list[any] = [{"type": "text", "text": text}];
    for image in images {
        path = image.get("path") if isinstance(image, dict) else None;
        if not isinstance(path, str) { raise Exception("Image exceeds 20 MB"); }
        if os.stat(path).st_size > IMAGE_BYTES { raise Exception("Image exceeds 20 MB"); }
        with open(path, "rb") as fh {
            encoded = base64.b64encode(fh.read()).decode("ascii");
        }
        part = chat_image({"mimeType": image.get("mime"), "data": encoded});
        budget([part]);
        parts.append(part);
    }
    return parts;
}

def chat_tool_images(call_id: str, images: any) -> list[any] {
    if not images { return []; }
    out: list[any] = [{"type": "text", "text": "Screenshot result from tool call " + call_id + ":"}];
    out.extend(images);
    return out;
}

# ── environment ────────────────────────────────────────────────────────────

def chat_mcp_environment(server_env: dict[str, any]) -> dict[str, str] {
    # These servers are a chat-runtime bot's tools: the operator's
    # control-plane secrets never ride along. What the server entry itself
    # names is a deliberate grant and is applied last.
    env: dict[str, str] = dict(os.environ);
    env["PATH"] = augmented_path(dict(os.environ));
    for key in list(env.keys()) {
        name = key.upper();
        if name.startswith(CONTROL_PLANE_ENV_PREFIX) or name in CONTROL_PLANE_ENV {
            env.pop(key, None);
        }
    }
    for (k, v) in server_env.items() {
        if isinstance(v, str) { env[k] = v; }
    }
    return env;
}

def mcp_stdio_server(server: any) -> any {
    # A stdio descriptor as-is; a remote http/sse spec through the node
    # mcp-remote-proxy (mcpStdioServer with nodeEnv ELECTRON_RUN_AS_NODE).
    if not isinstance(server, dict) { return None; }
    command = server.get("command");
    if isinstance(command, str) and command { return server; }
    remote = remote_mcp_spec(server);
    if remote is None { return None; }
    env: dict[str, any] = dict(NODE_ENV_FLAG);
    env["OMB_REMOTE_MCP_SERVER"] = json.dumps(remote, separators=(",", ":"));
    return {"command": node_exec_path(), "args": [resolve_proxy("mcp-remote-proxy")], "env": env};
}

# ── one stdio client ───────────────────────────────────────────────────────

obj ChatMcpClient {
    has frame_bytes: int = FRAME_BYTES,
        proc: any = None,
        session: dict[str, any] = {},
        buffer: bytes = b"",
        next_id: int = 1,
        frames: int = 0,
        closed: bool = False,
        close_state: dict[str, any] = {},
        pending: dict[int, any] = {},
        lock: any = None,
        wlock: any = None;

    def start(server: dict[str, any]) {
        args: list[str] = [server["command"]];
        for a in server.get("args") or [] { args.append(str(a)); }
        try {
            self.proc = subprocess.Popen(
                args,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=chat_mcp_environment(server.get("env") or {}),
                start_new_session=(os.name != "nt"),
            );
        } except Exception {
            raise Exception("MCP server could not start; check its command and installation");
        }
        self.session = {
            "proc": self.proc,
            "kill_state": {"lock": threading.Lock(), "running": False, "result": None, "event": threading.Event()},
        };
        threading.Thread(target=self._pump_stdout, daemon=True).start();
        threading.Thread(target=self._drain_stderr, daemon=True).start();
    }

    def _drain_stderr {
        # Stderr may contain credentials; drain without recording it.
        try {
            while True {
                chunk = self.proc.stderr.read1(65536);
                if not chunk { break; }
            }
        } except Exception {
        }
    }

    def _pump_stdout {
        out = self.proc.stdout;
        while True {
            try {
                chunk = out.read1(65536);
            } except Exception {
                chunk = b"";
            }
            if not chunk { break; }
            self._on_data(chunk);
        }
        self.fail(Exception("MCP server exited before the session closed"));
    }

    def fail(error: Exception) {
        self.lock.acquire();
        if self.closed {
            self.lock.release();
            return;
        }
        self.closed = True;
        slots = list(self.pending.values());
        self.pending.clear();
        self.lock.release();
        for slot in slots { _finish_slot(slot, error, None); }
        # Rejection is captured; mount/execute await close and surface it.
        threading.Thread(target=self._close_quietly, daemon=True).start();
    }

    def _close_quietly {
        try { self.close(); } except Exception { }
    }

    def close {
        self.lock.acquire();
        st = self.close_state;
        first = not st.get("started", False);
        if first {
            st["started"] = True;
            st["event"] = threading.Event();
            st["error"] = None;
        }
        self.closed = True;
        slots = list(self.pending.values());
        self.pending.clear();
        self.buffer = b"";
        self.lock.release();
        for slot in slots { _finish_slot(slot, Exception("MCP session closed"), None); }
        if first {
            stopped = False;
            if self.proc is not None {
                try {
                    self.proc.stdin.close();
                } except Exception {
                }
                stopped = _kill_cli_tree(self.session, KILL_GRACE_MS);
            } else {
                stopped = True;
            }
            if not stopped {
                st["error"] = "MCP server shutdown could not be confirmed; execution outcome may be uncertain";
            }
            st["event"].set();
        } else {
            st["event"].wait(KILL_GRACE_MS / 1000.0 + 5.0);
        }
        if st["error"] is not None { raise Exception(st["error"]); }
    }

    def write(frame: any) {
        if self.closed or self.proc is None or self.proc.stdin is None or self.proc.stdin.closed {
            raise Exception("MCP session closed");
        }
        encoded = (json.dumps(frame, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8");
        if len(encoded) > self.frame_bytes { raise Exception("MCP request exceeds the frame limit"); }
        self.wlock.acquire();
        try {
            self.proc.stdin.write(encoded);
            self.proc.stdin.flush();
        } except Exception {
            self.wlock.release();
            self.fail(Exception("MCP server input closed"));
            raise Exception("MCP session closed");
        }
        self.wlock.release();
    }

    def _on_data(chunk: bytes) {
        if self.closed { return; }
        self.buffer = self.buffer + chunk;
        while True {
            nl = self.buffer.find(b"\n");
            if nl < 0 { break; }
            line = self.buffer[0:nl];
            self.buffer = self.buffer[nl + 1:];
            self.frames += 1;
            if self.frames > MAX_FRAMES {
                self.fail(Exception("MCP session exceeded the response frame count limit"));
                return;
            }
            if len(line) > self.frame_bytes {
                self.fail(Exception("MCP response exceeds the frame limit"));
                return;
            }
            text = line.decode("utf-8", errors="replace");
            if not text.strip() { continue; }
            try {
                message = json.loads(text);
            } except Exception {
                self.fail(Exception("MCP server returned invalid JSON"));
                return;
            }
            if not isinstance(message, dict) or message.get("jsonrpc") != "2.0" {
                self.fail(Exception("MCP server returned an invalid RPC envelope"));
                return;
            }
            if isinstance(message.get("method"), str) {
                mid = message.get("id");
                if (isinstance(mid, (int, float)) and not isinstance(mid, bool)) or isinstance(mid, str) {
                    try {
                        self.write({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Client method not supported"}});
                    } except Exception {
                        self.fail(Exception("MCP server input closed"));
                        return;
                    }
                }
                continue;
            }
            mid = message.get("id");
            if isinstance(mid, bool) or not isinstance(mid, (int, float)) {
                self.fail(Exception("MCP server returned an invalid response ID"));
                return;
            }
            self.lock.acquire();
            slot = self.pending.pop(int(mid), None) if float(mid).is_integer() else None;
            self.lock.release();
            if slot is None { continue; }
            if "error" in message {
                _finish_slot(slot, Exception("MCP request failed; inspect the configured integration"), None);
            } elif "result" not in message {
                _finish_slot(slot, Exception("MCP response has no result"), None);
            } else {
                _finish_slot(slot, None, message["result"]);
            }
        }
        if len(self.buffer) > self.frame_bytes {
            self.fail(Exception("MCP response exceeds the frame limit"));
        }
    }

    def call(method: str, params: any, signal: any, timeout_ms: float) -> any {
        if signal.aborted {
            self.close();
            raise _aborted();
        }
        if self.closed { raise Exception("MCP session closed"); }
        self.lock.acquire();
        rid = self.next_id;
        self.next_id = rid + 1;
        slot: dict[str, any] = {"event": threading.Event(), "done": False, "error": None, "value": None, "lock": threading.Lock()};
        self.pending[rid] = slot;
        self.lock.release();
        def cancel {
            try {
                self.write({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": rid, "reason": "Cancelled"}});
            } except Exception {
            }
            _finish_slot(slot, _aborted(), None);
        }
        remove = signal.on_abort(cancel);
        try {
            self.write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params});
        } except Exception {
            _finish_slot(slot, Exception("MCP request could not be sent"), None);
        }
        if not slot["event"].wait(max(timeout_ms, 1) / 1000.0) {
            _finish_slot(slot, Exception("MCP request timed out; execution outcome may be uncertain"), None);
        }
        remove();
        self.lock.acquire();
        self.pending.pop(rid, None);
        self.lock.release();
        if slot["error"] is not None {
            self.close();
            failure: Exception = slot["error"];
            raise failure;
        }
        return slot["value"];
    }

    def list_tools(signal: any, keep_tool: any) -> list[any] {
        deadline = time.monotonic() + STARTUP_MS / 1000.0;
        def remaining() -> float {
            left = deadline - time.monotonic();
            if left <= 0 { raise Exception("MCP startup timed out"); }
            return left * 1000.0;
        }
        initialized = self.call("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "openmausbot-chat", "version": "1"},
        }, signal, remaining());
        if not isinstance(initialized, dict) { raise Exception("MCP initialization returned an invalid result"); }
        if signal.aborted { raise _aborted(); }
        self.write({"jsonrpc": "2.0", "method": "notifications/initialized"});
        tools: list[any] = [];
        cursors: dict[str, bool] = {};
        cursor: any = None;
        for page in range(MAX_PAGES) {
            result = self.call("tools/list", {"cursor": cursor} if cursor else {}, signal, remaining());
            if not isinstance(result, dict) or not isinstance(result.get("tools"), list) {
                raise Exception("MCP tools/list returned an invalid result");
            }
            for tool in result["tools"] {
                if keep_tool(tool) { tools.append(tool); }
            }
            if len(tools) > TOOL_COUNT { raise Exception("MCP tool count exceeds the 128-tool limit"); }
            if "nextCursor" not in result { return tools; }
            nc = result["nextCursor"];
            if not isinstance(nc, str) or not nc or nc in cursors {
                raise Exception("MCP tools/list returned an invalid pagination cursor");
            }
            cursors[nc] = True;
            cursor = nc;
        }
        raise Exception("MCP tools/list exceeded the pagination limit");
    }
}

def _finish_slot(slot: dict[str, any], error: any, value: any) {
    slot["lock"].acquire();
    if slot["done"] {
        slot["lock"].release();
        return;
    }
    slot["done"] = True;
    slot["error"] = error;
    slot["value"] = value;
    slot["lock"].release();
    slot["event"].set();
}

def new_mcp_client(server: dict[str, any], computer_use: bool) -> ChatMcpClient {
    client = ChatMcpClient(
        frame_bytes=IMAGE_FRAME_BYTES if computer_use else FRAME_BYTES,
        proc=None, session={}, buffer=b"", next_id=1, frames=0, closed=False,
        close_state={}, pending={}, lock=threading.Lock(), wlock=threading.Lock(),
    );
    client.start(server);
    return client;
}

# ── result shaping ─────────────────────────────────────────────────────────

def bounded_text(value: str) -> str {
    raw = value.encode("utf-8");
    if len(raw) <= OUTPUT_BYTES { return value; }
    end = OUTPUT_BYTES;
    while (raw[end] & 0xc0) == 0x80 { end -= 1; }
    return raw[0:end].decode("utf-8") + "\n[MCP result truncated at 50KB; request less output.]";
}

# Optional fields a tool documents as "omit to use the default", where a
# blank string is an error instead. Smaller models fill optional fields with
# "" rather than leaving them out; dropping the blank restores the call.
glob BUILT_IN_BROWSER_BLANK_MEANS_OMITTED: dict[str, list[str]] = {
    "agent_browser_read": ["url"],
};

def _omit_blank_defaults(built_in_browser: bool, tool: str, args: any) {
    if not built_in_browser or not isinstance(args, dict) { return; }
    for field in BUILT_IN_BROWSER_BLANK_MEANS_OMITTED.get(tool, []) {
        value = args.get(field);
        if isinstance(value, str) and not value.strip() { args.pop(field, None); }
    }
}

def _alias(server: str, name: str) -> str {
    base = re.sub(r"[^a-z0-9_]+", "_", (server + "_" + name).lower());
    base = re.sub(r"^_+|_+$", "", base)[0:64];
    return base or "mcp_tool";
}

# ── session ────────────────────────────────────────────────────────────────

obj ChatToolSession {
    has definitions: list[any] = [],
        registered: dict[str, any] = {},
        clients: list[any] = [],
        scope: any = None,
        signal: any = None,
        computer_use: bool = False,
        call_timeout_ms: float = 600000.0,
        closed: bool = False,
        close_state: dict[str, any] = {},
        remove_cancel: any = None,
        lock: any = None;

    def _close_quietly_session {
        try { self.close(); } except Exception { }
    }

    def close {
        self.lock.acquire();
        st = self.close_state;
        first = not st.get("started", False);
        if first {
            st["started"] = True;
            st["event"] = threading.Event();
            st["error"] = None;
        }
        self.closed = True;
        clients = list(self.clients);
        self.lock.release();
        if first {
            if self.remove_cancel is not None { self.remove_cancel(); }
            results: list[any] = [];
            def stop_one(c: any) {
                try {
                    c.close();
                } except Exception {
                    results.append(False);
                }
            }
            threads: list[any] = [];
            for c in clients {
                t = threading.Thread(target=stop_one, args=(c,), daemon=True);
                t.start();
                threads.append(t);
            }
            for t in threads { t.join(KILL_GRACE_MS / 1000.0 + 10.0); }
            if False in results {
                st["error"] = "MCP server shutdown could not be confirmed; execution outcome may be uncertain";
            }
            st["event"].set();
        } else {
            st["event"].wait(KILL_GRACE_MS / 1000.0 + 15.0);
        }
        if st["error"] is not None { raise ChatToolSessionError(st["error"]); }
    }

    def validate(name: str, args: any) {
        if self.closed or self.signal.aborted { raise ChatToolSessionError("MCP session closed"); }
        tool = self.registered.get(name);
        if tool is None { raise Exception("The requested tool was not advertised for this turn"); }
        if self.scope is not None and not allows_tool(self.scope, "mcp", tool["name"], tool["server"]) {
            raise Exception("Tool selection excludes this tool");
        }
        _omit_blank_defaults(tool["built_in_browser"], tool["name"], args);
        if not isinstance(args, dict) or not tool["schema"](args) {
            raise Exception("Tool arguments do not match the advertised input schema; use its required fields and types");
        }
    }

    def execute(name: str, args: dict[str, any], call_signal: any) -> dict[str, any] {
        self.validate(name, args);
        if call_signal.aborted {
            self.close();
            raise _aborted();
        }
        tool = self.registered[name];
        try {
            result = tool["client"].call(
                "tools/call", {"name": tool["name"], "arguments": args},
                any_signal([self.signal, call_signal]), self.call_timeout_ms,
            );
            if self.signal.aborted or call_signal.aborted { raise _aborted(); }
            if (
                not isinstance(result, dict) or not isinstance(result.get("content"), list)
                or ("isError" in result and not isinstance(result["isError"], bool))
            ) {
                raise Exception("MCP tool returned an invalid result; execution outcome may be uncertain");
            }
            parts: list[str] = [];
            images: list[any] = [];
            unsupported = 0;
            for item in result["content"] {
                if not isinstance(item, dict) or not isinstance(item.get("type"), str) or (item["type"] == "text" and not isinstance(item.get("text"), str)) {
                    raise Exception("MCP tool returned invalid content; execution outcome may be uncertain");
                }
                if item["type"] == "text" {
                    parts.append(item["text"]);
                } elif self.computer_use and item["type"] == "image" {
                    images.append(chat_image(item));
                } else {
                    unsupported += 1;
                }
            }
            if "structuredContent" in result {
                parts.append(json.dumps(result["structuredContent"], separators=(",", ":"), ensure_ascii=False));
            }
            if unsupported {
                parts.insert(0, "[" + str(unsupported) + " unsupported MCP content item(s) omitted. The operation may have taken effect, but its full result cannot be represented; inspect its state before retrying.]");
            }
            joined = "\n".join(parts);
            if not joined { joined = "Screenshot captured." if images else "(empty result)"; }
            out: dict[str, any] = {"text": bounded_text(joined), "ok": result.get("isError") is not True and unsupported == 0};
            if images { out["images"] = images; }
            return out;
        } except Exception as e {
            self.close();
            raise ChatToolSessionError(str(e) or "MCP transport failed; execution outcome may be uncertain");
        }
    }
}

def mount_chat_tools(
    integrations: any,
    signal: any,
    computer_use: bool = False,
    tool_scope: any = None,
    call_timeout_ms: any = None
) -> ChatToolSession {
    parsed = parse_tool_scope(tool_scope);
    if not parsed["ok"] { raise Exception(parsed["error"]); }
    scope = parsed["scope"];
    timeout_ms = float(call_timeout_ms) if (isinstance(call_timeout_ms, (int, float)) and not isinstance(call_timeout_ms, bool) and call_timeout_ms > 0) else float(DEFAULT_CALL_MS);
    ints = integrations if isinstance(integrations, dict) else {};
    def eligible(server: str) -> bool {
        return scope is None or can_use_mcp_server(scope, server);
    }
    servers: list[any] = [];   # [name, descriptor, built_in_browser]
    if computer_use and isinstance(ints.get("localComputer"), dict) and eligible("computer") {
        servers.append(["computer", ints["localComputer"], False]);
    }
    if computer_use and isinstance(ints.get("browser"), dict) and eligible("browser") {
        servers.append(["browser", ints["browser"], True]);
    }
    if isinstance(ints.get("agents"), dict) and eligible("agents") {
        servers.append(["agents", ints["agents"], False]);
    }
    if isinstance(ints.get("composio"), dict) and eligible("composio") {
        servers.append(["composio", ints["composio"], False]);
    }
    custom = ints.get("custom");
    if isinstance(custom, dict) {
        for (name, server) in custom.items() {
            if not eligible(name) { continue; }
            stdio = mcp_stdio_server(server);
            if stdio is None { raise Exception("MCP server configuration is invalid"); }
            servers.append([name, {"command": stdio["command"], "args": stdio.get("args") or [], "env": stdio.get("env") or {}}, False]);
        }
    }
    if len(servers) > MAX_SERVERS { raise Exception("MCP server count exceeds the 32-server limit"); }
    session = ChatToolSession(
        definitions=[], registered={}, clients=[], scope=scope, signal=signal,
        computer_use=computer_use, call_timeout_ms=timeout_ms, closed=False,
        close_state={}, remove_cancel=None, lock=threading.Lock(),
    );
    def cancel {
        threading.Thread(target=session._close_quietly_session, daemon=True).start();
    }
    session.remove_cancel = signal.on_abort(cancel);
    try {
        if signal.aborted { raise _aborted(); }
        # Start independent servers concurrently; consume results in config
        # order so names and collision suffixes stay stable across timings.
        outcomes: list[any] = [None] * len(servers);
        def mount_one(i: int) {
            spec_row = servers[i];
            try {
                if signal.aborted or session.closed { raise _aborted(); }
                client = new_mcp_client(spec_row[1], computer_use);
                session.lock.acquire();
                session.clients.append(client);
                late = session.closed;
                session.lock.release();
                if late {
                    client._close_quietly();
                    raise _aborted();
                }
                server_name = spec_row[0];
                def keep_tool(tool: any) -> bool {
                    if scope is None { return True; }
                    return isinstance(tool, dict) and isinstance(tool.get("name"), str) and allows_tool(scope, "mcp", tool["name"], server_name);
                }
                tools = client.list_tools(signal, keep_tool);
                outcomes[i] = {"ok": True, "client": client, "tools": tools};
            } except Exception as e {
                outcomes[i] = {"ok": False, "error": e};
            }
        }
        threads: list[any] = [];
        for i in range(len(servers)) {
            t = threading.Thread(target=mount_one, args=(i,), daemon=True);
            t.start();
            threads.append(t);
        }
        for t in threads { t.join(); }
        for i in range(len(servers)) {
            outcome = outcomes[i];
            if not outcome["ok"] {
                mount_error: Exception = outcome["error"];
                raise mount_error;
            }
            server = servers[i][0];
            built_in_browser = servers[i][2];
            original: dict[str, bool] = {};
            for tool in outcome["tools"] {
                if not isinstance(tool, dict) or not isinstance(tool.get("name"), str) or not tool["name"].strip() or tool["name"] in original {
                    raise Exception("MCP server advertised an invalid or duplicate tool name");
                }
                original[tool["name"]] = True;
                if len(session.definitions) >= TOOL_COUNT { raise Exception("MCP tool count exceeds the 128-tool limit"); }
                input_schema = tool.get("inputSchema");
                if not isinstance(input_schema, dict) or input_schema.get("type") != "object" {
                    raise Exception("MCP tools require an object input schema");
                }
                if _byte_len(input_schema) > SCHEMA_BYTES { raise Exception("MCP tool schema exceeds the 64KB limit"); }
                validator = compile_tool_schema(input_schema);
                parameters = dict(input_schema);
                constraints: dict[str, any] = {};
                if computer_use {
                    for key in ["anyOf", "oneOf", "allOf", "not"] {
                        if key in parameters {
                            constraints[key] = parameters.pop(key);
                        }
                    }
                }
                description = tool["description"] if isinstance(tool.get("description"), str) else "Configured MCP tool";
                if constraints {
                    description = description + " Additional argument constraints (validated before execution): " + json.dumps(constraints, separators=(",", ":"), ensure_ascii=False);
                }
                base = _alias(server, tool["name"]);
                name = base;
                index = 2;
                while name in session.registered {
                    suffix = "_" + str(index);
                    name = base[0:64 - len(suffix)] + suffix;
                    index += 1;
                }
                session.registered[name] = {
                    "client": outcome["client"], "server": server, "built_in_browser": built_in_browser,
                    "name": tool["name"], "schema": validator,
                };
                session.definitions.append({"type": "function", "function": {"name": name, "description": description, "parameters": parameters}});
                if _byte_len(session.definitions) > CATALOG_BYTES { raise Exception("MCP tool catalog exceeds the 1MB limit"); }
            }
        }
        if signal.aborted or session.closed { raise _aborted(); }
    } except Exception as e {
        session.close();
        raise e;
    }
    return session;
}
