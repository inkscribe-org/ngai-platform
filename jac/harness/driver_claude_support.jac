"""Pure helpers for the Claude driver port (server/drivers/claude.ts and its
support modules). No side effects at import: everything here is a function or
a constant. Process/thread ownership lives in driver_claude.jac, the per-turn
permission broker in driver_claude_broker.jac."""

import os;
import re;
import json;
import time;
import hashlib;
import urllib.request;
import urllib.error;

import from db { DATA_DIR }

# ── ids / time ─────────────────────────────────────────────────────────────

def new_uuid() -> str {
    import uuid;
    return str(uuid.uuid4());
}

def now_ms() -> int {
    return int(time.time() * 1000);
}

# ── CLI version floors (claude.ts CLAUDE_FLAG_FLOORS) ──────────────────────
# Verified against the published binaries: an unknown flag is a hard argument
# error, so each flag is only passed to a CLI known to accept it.

glob CLAUDE_FLAG_FLOORS: dict[str, any] = {
    "--strict-mcp-config": [1, 0, 60],
    "--setting-sources": [1, 0, 122],
    "--autocompact": [2, 1, 122],
    "--system-prompt-snapshot": [2, 1, 267],
    "--restricted": [2, 1, 257],
};
glob CLAUDE_REPLAY_FLOOR: list[any] = [2, 1, 282];

def parse_version_triple(value: str) -> any {
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", value or "");
    if m is None { return None; }
    return [int(m.group(1)), int(m.group(2)), int(m.group(3))];
}

def version_at_least(installed: list[any], floor: list[any]) -> bool {
    i = 0;
    while i < 3 {
        if installed[i] != floor[i] { return installed[i] > floor[i]; }
        i += 1;
    }
    return True;
}

# A version that could not be parsed counts as current: every CLI that
# predates a floor prints a plain "x.y.z (Claude Code)", so an unreadable
# version is far more likely a newer wrapper than an old build.
def claude_cli_supports(version: any, flag: str) -> bool {
    if version is None { return True; }
    floor = CLAUDE_FLAG_FLOORS.get(flag);
    if floor is None { return True; }
    return version_at_least(version, floor);
}

# ── autocompact window (claude.ts autoCompactWindow) ───────────────────────

glob DEFAULT_AUTOCOMPACT_TOKENS: int = 200000;

def auto_compact_window(env: dict[str, any]) -> any {
    raw = (env.get("OMB_CLAUDE_AUTOCOMPACT") or "").strip().lower();
    if raw == "off" { return None; }
    if raw == "auto" { return "auto"; }
    if raw {
        try {
            parsed: any = float(raw);
        } except Exception {
            parsed = None;
        }
    } else {
        parsed = float(DEFAULT_AUTOCOMPACT_TOKENS);
    }
    if parsed is None or parsed != parsed or parsed <= 0 {
        return str(DEFAULT_AUTOCOMPACT_TOKENS);
    }
    return str(min(1000000, max(100000, int(parsed))));
}

# ── model catalog + local injects (local-inject.ts) ────────────────────────

glob STATIC_CLAUDE_MODEL_IDS: list[any] = [
    "claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5",
    "claude-sonnet-5-5", "claude-sonnet-5", "claude-haiku-4-5",
];
glob CLAUDE_MODEL_ID_RE: any = re.compile(r"^[a-z0-9][a-z0-9._:/-]*$", re.I);
glob OFFICIAL_CLAUDE_ID_RE: any = re.compile(r"^claude-[a-z0-9.-]+$");

glob LOCAL_HOSTS: dict[str, any] = {
    "omlx": {"label": "oMLX", "base_url": "http://127.0.0.1:8080/v1", "api_key": "omlx"},
    "ollama": {"label": "Ollama", "base_url": "http://127.0.0.1:11434/v1", "api_key": "ollama"},
    "local_ollama": {"label": "Ollama", "base_url": "http://127.0.0.1:11434/v1", "api_key": "ollama"},
    "exo": {"label": "EXO", "base_url": "http://127.0.0.1:52415/v1", "api_key": "exo"},
    "lmstudio": {"label": "LM Studio", "base_url": "http://127.0.0.1:1234/v1", "api_key": "lm-studio"},
    "unsloth": {"label": "Unsloth", "base_url": "http://127.0.0.1:8888/v1", "api_key_env": "UNSLOTH_STUDIO_AUTH_TOKEN"},
    "unsloth_api": {"label": "Unsloth", "base_url": "http://127.0.0.1:8888/v1", "api_key_env": "UNSLOTH_STUDIO_AUTH_TOKEN"},
};
glob INJECT_SEP: str = "::";
glob INJECT_MODEL_ID_RE: any = re.compile(r"^\w[\w./:+-]*$");

def decode_inject_id(id: any) -> any {
    if not id { return None; }
    sep = id.find(INJECT_SEP);
    if sep <= 0 { return None; }
    host = id[0:sep];
    model = id[sep + len(INJECT_SEP):];
    if host not in LOCAL_HOSTS or not INJECT_MODEL_ID_RE.match(model) { return None; }
    return {"host": host, "model": model};
}

def anthropic_base_url(host: dict[str, any]) -> str {
    return re.sub(r"/v1/?$", "", host["base_url"]);
}

def host_api_key(host: dict[str, any], env: dict[str, any]) -> str {
    key_env = host.get("api_key_env");
    if key_env and env.get(key_env) { return env[key_env]; }
    if host.get("api_key") { return host["api_key"]; }
    return "local";
}

def resolve_inject_id(model: str, extras: list[any]) -> any {
    if not model { return model; }
    if decode_inject_id(model) is not None { return model; }
    matches: list[any] = [];
    for row in extras {
        if row.get("id") == model or row.get("model") == model { matches.append(row); }
    }
    chosen: any = None;
    for row in matches {
        if row.get("loaded") { chosen = row; break; }
    }
    if chosen is None and matches { chosen = matches[0]; }
    if chosen is None { return model; }
    return chosen["id"];
}

def _ids_from_models_payload(payload: any) -> list[str] {
    records: list[any] = [];
    if isinstance(payload, list) {
        records = payload;
    } elif isinstance(payload, dict) {
        if isinstance(payload.get("data"), list) { records = payload["data"]; }
        elif isinstance(payload.get("models"), list) { records = payload["models"]; }
    }
    out: list[str] = [];
    for record in records {
        if isinstance(record, str) {
            if INJECT_MODEL_ID_RE.match(record) { out.append(record); }
            continue;
        }
        if not isinstance(record, dict) { continue; }
        id = record.get("id");
        if not isinstance(id, str) { id = record.get("name"); }
        if not isinstance(id, str) or not INJECT_MODEL_ID_RE.match(id) { continue; }
        low = id.lower();
        if "embed" in low or "bge-" in low or "nomic" in low { continue; }
        out.append(id);
    }
    return out;
}

def _loaded_probe_url(host: dict[str, any]) -> any {
    origin = anthropic_base_url(host);
    if host["id"] == "omlx" { return origin + "/v1/models/status"; }
    if host["id"] == "ollama" or host["id"] == "local_ollama" { return origin + "/api/ps"; }
    if host["id"] == "lmstudio" { return origin + "/api/v0/models"; }
    return None;
}

def _timed_json(url: str, host: dict[str, any], env: dict[str, any]) -> any {
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + host_api_key(host, env)});
    try {
        resp = urllib.request.urlopen(req, timeout=1.2);
        try {
            return json.loads(resp.read().decode("utf-8"));
        } finally {
            resp.close();
        }
    } except Exception {
        return None;
    }
}

# Live models from the same local hosts the sidecar probed. A host that does
# not answer yields nothing; the probe never fails a turn.
def probe_local_injects(env: dict[str, any]) -> list[any] {
    seen: dict[str, bool] = {};
    hosts: list[any] = [];
    for (id, host) in LOCAL_HOSTS.items() {
        row = dict(host);
        row["id"] = id;
        key = row["base_url"].rstrip("/");
        if key in seen { continue; }
        seen[key] = True;
        hosts.append(row);
    }
    found: list[any] = [];
    for host in hosts {
        base = host["base_url"].rstrip("/");
        catalog = _timed_json(base + "/models", host, env);
        extra_url = _loaded_probe_url(host);
        extra = _timed_json(extra_url, host, env) if extra_url else None;
        ids: list[str] = [];
        if catalog is not None { ids.extend(_ids_from_models_payload(catalog)); }
        if extra is not None { ids.extend(_ids_from_models_payload(extra)); }
        uniq: dict[str, bool] = {};
        for id in ids { uniq[id] = True; }
        for id in uniq {
            found.append({
                "id": host["id"] + INJECT_SEP + id,
                "host": host["id"],
                "model": id,
                "label": id + " (" + host["label"] + ")",
            });
        }
    }
    return found;
}

def resolve_claude_turn_model(model: any, env: dict[str, any]) -> any {
    if not model { return model; }
    if decode_inject_id(model) is not None { return model; }
    if model in STATIC_CLAUDE_MODEL_IDS { return model; }
    return resolve_inject_id(model, probe_local_injects(env));
}

def apply_claude_inject(env: dict[str, any], model: any) -> dict[str, any] {
    # Point Claude Code at an injected local host instead of Anthropic cloud.
    inject = decode_inject_id(model);
    if inject is None { return {"model": model if model is not None else None, "injected": False}; }
    host = LOCAL_HOSTS.get(inject["host"]);
    if host is None { return {"model": model, "injected": False}; }
    key = host_api_key(host, env);
    env["ANTHROPIC_BASE_URL"] = anthropic_base_url(host);
    env["ANTHROPIC_AUTH_TOKEN"] = key;
    env["ANTHROPIC_API_KEY"] = key;
    env["ANTHROPIC_MODEL"] = inject["model"];
    return {"model": inject["model"], "injected": True};
}

# ── env hygiene (claudeEnvironment, config.ts) ─────────────────────────────

glob CLAUDE_ACCOUNT_ENV_KEYS: list[any] = [
    "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES",
    "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
];

glob WORKSPACE_CREDENTIAL_ENV: list[any] = [
    "XAI_API_KEY", "MISTRAL_API_KEY", "CEREBRAS_API_KEY", "OMB_ANTHROPIC_API_KEY",
    "OMB_ANTHROPIC_API_URL", "OMB_HOSTED_MODEL_TOKEN", "OMB_HOSTED_MODELS",
    "OPENAI_COMPAT_API_KEY", "OPENAI_COMPAT_URL", "OMB_OPENAI_API_KEY",
    "OMB_OPENROUTER_API_KEY", "BOX_TOKEN", "OPENCODE_API_KEY", "OMB_TTS_KEY",
    "OMB_FISH_AUDIO_API_KEY", "OMB_JEV_API_KEY", "OMB_OPENAI_IMAGE_KEY",
    "OMB_CUSTOM_IMAGE_KEY", "OMB_OPENAI_LIVE_KEY", "COMPOSIO_API_KEY",
    "OMB_COMPOSIO_BROKER_TOKEN", "OMB_CLOUD_BOAT_TOKEN", "OMB_CLOUD_VOICE_TOKEN",
    "OMB_CLOUD_DECIDER_TOKEN", "OMB_BROWSER_CONNECTION", "OMB_USER_DATA",
];
glob CONTROL_PLANE_ENV: list[any] = ["OMB_LICENSE_KEY", "OMB_INSTALLATION_CREDENTIAL"];
glob CONTROL_PLANE_ENV_PREFIX: str = "OMB_CLOUD_";

def strip_workspace_credential_env(env: dict[str, any]) {
    for key in WORKSPACE_CREDENTIAL_ENV {
        env.pop(key, None);
    }
    for key in list(env.keys()) {
        name = key.upper();
        if name.startswith(CONTROL_PLANE_ENV_PREFIX) or name in CONTROL_PLANE_ENV {
            env.pop(key, None);
        }
    }
}

def user_home(env: dict[str, any]) -> str {
    return env.get("HOME") or env.get("USERPROFILE") or os.path.expanduser("~");
}

def resolve_claude_config_dir(config_dir: any, env: dict[str, any]) -> str {
    home = user_home(env);
    configured = (config_dir or "").strip() or (env.get("CLAUDE_CONFIG_DIR") or "").strip() or os.path.join(home, ".claude");
    if configured == "~" {
        expanded = home;
    } elif configured.startswith("~/") {
        expanded = os.path.join(home, configured[2:]);
    } else {
        expanded = configured;
    }
    if not os.path.isabs(expanded) or re.search(r"[\x00-\x1f\x7f]", expanded) {
        raise RuntimeError("claude: configDir must be an absolute path or start with ~/");
    }
    return os.path.normpath(expanded);
}

def inherits_user_config(env: dict[str, any]) -> bool {
    return env.get("OMB_CLAUDE_INHERIT_USER_CONFIG") == "1";
}

def read_claude_auth_settings(env: dict[str, any], instance_environment: dict[str, any]) -> dict[str, any] {
    # Retain the selected CLI account's authentication without importing its
    # hooks, permissions, MCP servers or personal instructions.
    for key in CLAUDE_ACCOUNT_ENV_KEYS {
        if instance_environment.get(key) { return {}; }
    }
    try {
        path = os.path.join(resolve_claude_config_dir(None, env), "settings.json");
        f = open(path, "r", encoding="utf-8");
        try {
            settings = json.loads(f.read());
        } finally {
            f.close();
        }
    } except Exception {
        return {};
    }
    if not isinstance(settings, dict) { return {}; }
    nested = settings.get("env");
    auth_env: dict[str, any] = {};
    if isinstance(nested, dict) {
        for key in CLAUDE_ACCOUNT_ENV_KEYS {
            if key.endswith("_FILE_DESCRIPTOR") { continue; }
            value = nested.get(key);
            if isinstance(value, str) { auth_env[key] = value; }
        }
    }
    out: dict[str, any] = {};
    if auth_env { out["env"] = auth_env; }
    helper = settings.get("apiKeyHelper");
    if isinstance(helper, str) and helper.strip() { out["apiKeyHelper"] = helper; }
    return out;
}

# PATH augmentation for the spawned CLI (env-path.ts, POSIX half): the
# inherited PATH plus the well-known install locations that exist here. The
# login-shell probe stays node-side — it is a best-effort background refill.
def _known_dirs(home: str, sealed: bool) -> list[str] {
    dirs = [
        os.path.join(home, ".local", "bin"),
        os.path.join(home, ".npm-global", "bin"),
        os.path.join(home, ".kimi-code", "bin"),
        os.path.join(home, ".grok", "bin"),
        os.path.join(home, ".opencode", "bin"),
        os.path.join(home, ".claude", "local"),
    ];
    if not sealed {
        dirs.extend(["/opt/homebrew/bin", "/usr/local/bin"]);
    }
    dirs.extend([
        os.path.join(home, ".volta", "bin"),
        os.path.join(home, ".bun", "bin"),
        os.path.join(home, ".asdf", "shims"),
        os.path.join(home, ".local", "share", "mise", "shims"),
        os.path.join(home, ".deno", "bin"),
        os.path.join(home, "bin"),
    ]);
    try {
        base = os.path.join(home, ".nvm", "versions", "node");
        versions = [v for v in os.listdir(base) if v.startswith("v")];
        versions.sort(reverse=True);
        for v in versions {
            dirs.append(os.path.join(base, v, "bin"));
        }
    } except Exception {
    }
    return dirs;
}

glob _AUGMENTED_PATH_CACHE: dict[str, any] = {"path": None};

def augmented_path(env: dict[str, any]) -> str {
    cached = _AUGMENTED_PATH_CACHE["path"];
    if cached is not None { return cached; }
    parts: list[str] = [];
    sealed = env.get("OMB_TEST_SEALED_PATH") == "1";
    extra = env.get("OMB_EXTRA_PATH");
    if extra { parts.extend([p for p in extra.split(os.path.pathsep) if p]); }
    if env.get("PATH") { parts.extend([p for p in env["PATH"].split(os.path.pathsep) if p]); }
    for d in _known_dirs(user_home(env), sealed) {
        if os.path.isdir(d) { parts.append(d); }
    }
    uniq: dict[str, bool] = {};
    out: list[str] = [];
    for p in parts {
        if p in uniq { continue; }
        uniq[p] = True;
        out.append(p);
    }
    merged = os.path.pathsep.join(out);
    _AUGMENTED_PATH_CACHE["path"] = merged;
    return merged;
}

# ── process paths (proxy-paths.ts) ─────────────────────────────────────────

def server_root() -> str {
    # The node server's directory: two levels above this harness dir in the
    # repo (jac/harness → repo → server). The node side spawns the harness
    # with cwd set to the harness dir, so the cwd fallback covers a jaclang
    # runtime that does not surface __file__.
    bases: list[any] = [];
    try {
        bases.append(os.path.dirname(os.path.abspath(__file__)));
    } except Exception {
    }
    bases.append(os.getcwd());
    for base_dir in bases {
        if os.path.isfile(os.path.join(base_dir, "proxy-paths.ts")) { return base_dir; }
        cand = os.path.normpath(os.path.join(base_dir, "..", "..", "server"));
        if os.path.isfile(os.path.join(cand, "proxy-paths.ts")) or os.path.isfile(os.path.join(cand, "index.ts")) {
            return cand;
        }
    }
    return os.path.normpath(os.path.join(os.getcwd(), "..", "..", "server"));
}

def resolve_proxy(relative: str) -> str {
    # .ts in dev, the compiled sibling once packaged.
    source = os.path.join(server_root(), relative + ".ts");
    if os.path.isfile(source) { return source; }
    return os.path.join(server_root(), relative + ".js");
}

glob _NODE_EXE_CACHE: dict[str, any] = {"path": None};

def node_exec_path() -> str {
    # The node binary that runs the server's own spawned helpers (the
    # permission proxy, the MCP gate, the dweb proxy). The harness inherits
    # the server's environment, whose PATH carries node; resolve once.
    cached = _NODE_EXE_CACHE["path"];
    if cached is not None { return cached; }
    candidates = ["node", "node.exe"];
    for d in augmented_path(dict(os.environ)).split(os.path.pathsep) {
        if not d { continue; }
        for name in candidates {
            p = os.path.join(d, name);
            if os.path.isfile(p) {
                _NODE_EXE_CACHE["path"] = p;
                return p;
            }
        }
    }
    which: any = None;
    try {
        import shutil;
        which = shutil.which("node");
    } except Exception {
        which = None;
    }
    path = which or "node";
    _NODE_EXE_CACHE["path"] = path;
    return path;
}

# in the packaged app process.execPath is the Electron binary — this env
# makes it behave as plain node for the spawned MCP proxies (harmless in dev)
glob NODE_ENV_FLAG: dict[str, any] = {"ELECTRON_RUN_AS_NODE": "1"};

# ── guest confinement ──────────────────────────────────────────────────────

glob GUEST_CLAUDE_TOOLS: list[any] = ["Read", "Grep", "Glob", "Edit", "Write", "WebSearch"];
glob GUEST_FORBIDDEN_TOOLS: dict[str, bool] = {
    "Bash": True, "PowerShell": True, "WebFetch": True, "BashOutput": True,
    "KillShell": True, "KillBash": True, "NotebookEdit": True, "Task": True, "Agent": True,
};
glob GUEST_CLAUDE_PERMISSIONS: dict[str, any] = {
    "blockReadsOutsideWorkingDirectories": True,
    "deny": ["Bash", "PowerShell", "WebFetch", "Read(//proc/**)"],
};

def with_why(refusal: str, why: any) -> str {
    return refusal + " " + why if why else refusal;
}

# ── tool scope (shared/tool-scope.ts) ──────────────────────────────────────

glob TOOL_SCOPE_SERVER_NAME_RE: any = re.compile(r"^[a-z][a-z0-9_-]{0,31}$");
glob TOOL_SCOPE_CONTROL_RE: any = re.compile(r"[\x00-\x1f\x7f]");
glob MAX_SELECTORS: int = 256;
glob MAX_SELECTOR_LENGTH: int = 1024;

def _valid_name(name: any) -> bool {
    return isinstance(name, str) and name.strip() != "" and len(name) <= MAX_SELECTOR_LENGTH and not TOOL_SCOPE_CONTROL_RE.search(name) and "*" not in name;
}

def _selector_identity(selector: str) -> any {
    # "native:name" | "native:*" | "mcp:server:name" | "mcp:server:*".
    # A bare word is not an identity: selectors are fully qualified.
    if len(selector) > MAX_SELECTOR_LENGTH or TOOL_SCOPE_CONTROL_RE.search(selector) { return None; }
    if selector.startswith("native:") {
        name = selector[len("native:"):];
        if name == "*" or _valid_name(name) { return {"kind": "native", "name": name}; }
        return None;
    }
    if selector.startswith("mcp:") {
        sep = selector.find(":", 4);
        if sep < 0 { return None; }
        server = selector[4:sep];
        name = selector[sep + 1:];
        if TOOL_SCOPE_SERVER_NAME_RE.match(server) and (name == "*" or _valid_name(name)) {
            return {"kind": "mcp", "server": server, "name": name};
        }
        return None;
    }
    return None;
}

def parse_tool_scope(value: any) -> dict[str, any] {
    # {ok: True, scope: dict|None} or {ok: False, error: str}
    if value is None { return {"ok": True, "scope": None}; }
    if not isinstance(value, dict) { return {"ok": False, "error": "Tool selection must contain only valid allow and deny lists."}; }
    scope: dict[str, any] = {};
    for key in value.keys() {
        if key != "allow" and key != "deny" {
            return {"ok": False, "error": "Tool selection must contain only valid allow and deny lists."};
        }
        listing = value[key];
        if not isinstance(listing, list) or len(listing) > MAX_SELECTORS {
            return {"ok": False, "error": "Tool selection must contain only valid allow and deny lists."};
        }
        cleaned: list[any] = [];
        for sel in listing {
            # The identity parse is the authority: a malformed selector never
            # inherits the catalog.
            if not isinstance(sel, str) or _selector_identity(sel) is None {
                return {"ok": False, "error": "Tool selection must contain only valid allow and deny lists."};
            }
            if sel not in cleaned { cleaned.append(sel); }
        }
        scope[key] = cleaned;
    }
    return {"ok": True, "scope": scope};
}

def _matches(selector: str, kind: str, name: str, server: any) -> bool {
    selected = _selector_identity(selector);
    if selected is None or selected["kind"] != kind { return False; }
    if kind == "mcp" and server is not None and selected["server"] != server { return False; }
    return selected["name"] == "*" or selected["name"] == name;
}

def _permits(scope: any, kind: str, name: str, server: any) -> bool {
    if not _valid_name(name) or (kind == "mcp" and not TOOL_SCOPE_SERVER_NAME_RE.match(server or "")) { return False; }
    allow = scope.get("allow") if isinstance(scope, dict) else None;
    deny = scope.get("deny") if isinstance(scope, dict) else None;
    if allow is not None {
        hit = False;
        for selector in allow {
            if _matches(selector, kind, name, server) { hit = True; break; }
        }
        if not hit { return False; }
    }
    if deny is not None {
        for selector in deny {
            if _matches(selector, kind, name, server) { return False; }
        }
    }
    return True;
}

def allows_tool(scope: any, kind: str, name: str, server: any = None) -> bool {
    parsed = parse_tool_scope(scope);
    if not parsed["ok"] { return False; }
    return _permits(parsed["scope"], kind, name, server);
}

def narrows_native_tools(value: any) -> bool {
    parsed = parse_tool_scope(value);
    if not parsed["ok"] { return True; }
    scope = parsed["scope"];
    if scope is None { return False; }
    if scope.get("allow") is not None and "native:*" not in scope["allow"] { return True; }
    deny = scope.get("deny");
    if deny {
        for selector in deny {
            if isinstance(selector, str) and selector.startswith("native:") { return True; }
        }
    }
    return False;
}

def can_use_mcp_server(scope: any, server: str, names: any = None) -> bool {
    parsed = parse_tool_scope(scope);
    if not parsed["ok"] or not TOOL_SCOPE_SERVER_NAME_RE.match(server) { return False; }
    if names is not None {
        for name in names {
            if _permits(parsed["scope"], "mcp", name, server) { return True; }
        }
        return False;
    }
    s = parsed["scope"];
    if s is not None and s.get("deny") is not None and ("mcp:" + server + ":*") in s["deny"] { return False; }
    if s is None or s.get("allow") is None { return True; }
    for selector in s["allow"] {
        selected = _selector_identity(selector);
        if selected is None or selected["kind"] != "mcp" or selected["server"] != server { continue; }
        if selected["name"] == "*" { return True; }
        if _permits(s, "mcp", selected["name"], server) { return True; }
    }
    return False;
}

def assert_tool_scope_supported(engine: str, value: any) -> any {
    # Native contracts and app-supplied MCP gates are separate capabilities;
    # claudeAgent (and every other MCP-gated engine) accepts only MCP scopes.
    parsed = parse_tool_scope(value);
    if not parsed["ok"] { raise RuntimeError(parsed["error"]); }
    if parsed["scope"] is not None and narrows_native_tools(parsed["scope"]) {
        raise RuntimeError(engine + ": native tool selection is not supported by this engine. Keep native:* in the selection or choose a supported engine.");
    }
    return parsed["scope"];
}

# ── MCP gate (mcp-gate-config.ts) ──────────────────────────────────────────

def remote_mcp_spec(value: any) -> any {
    # {type: "http"|"sse", url, headers} with all-string headers.
    if not isinstance(value, dict) { return None; }
    if value.get("type") != "http" and value.get("type") != "sse" { return None; }
    url = value.get("url");
    if not isinstance(url, str) { return None; }
    if not (url.startswith("http://") or url.startswith("https://")) { return None; }
    headers = value.get("headers");
    if headers is None { headers = {}; }
    if not isinstance(headers, dict) { return None; }
    for v in headers.values() {
        if not isinstance(v, str) { return None; }
    }
    if "@" in url.split("//", 1)[-1].split("/", 1)[0] { return None; }
    return {"type": value["type"], "url": url, "headers": headers};
}

def result_budget(env: dict[str, any]) -> int {
    raw = env.get("OMB_MCP_RESULT_BUDGET");
    if raw is None or raw == "" { return 24000; }
    try {
        parsed = float(raw);
    } except Exception {
        return 24000;
    }
    if parsed >= 0 and parsed == parsed { return int(parsed); }
    return 24000;
}

def spill_dir(thread_id: str) -> str {
    safe = re.sub(r"[^A-Za-z0-9_-]", "-", thread_id)[0:80] or "thread";
    return os.path.join(DATA_DIR, "tool-results", safe);
}

def mcp_stdio_server(server: any) -> any {
    if not isinstance(server, dict) { return None; }
    command = server.get("command");
    if isinstance(command, str) and command { return server; }
    return None;
}

def gate_server(name: str, server: any, thread_id: str, budget: int, tool_scope: any) -> any {
    # The gated stdio form of one bot-owned server, or None to mount it
    # unchanged. The upstream spec travels in the gate's env, i.e. inside the
    # same 0600 MCP config file that keeps credentials off argv.
    parsed = parse_tool_scope(tool_scope);
    if not parsed["ok"] { raise RuntimeError(parsed["error"]); }
    scoped = parsed["scope"] is not None;
    if budget <= 0 and not scoped { return None; }
    if not scoped and remote_mcp_spec(server) is not None { return None; }
    spec = mcp_stdio_server(server);
    if spec is None {
        if scoped { raise RuntimeError("Tool selection requires a supported MCP server."); }
        return None;
    }
    env: dict[str, any] = {
        "OMB_GATE_NAME": name,
        "OMB_GATE_UPSTREAM": json.dumps({"command": spec.get("command"), "args": spec.get("args") or [], "env": spec.get("env") or {}}),
        "OMB_GATE_SPILL_DIR": spill_dir(thread_id),
        "OMB_GATE_BUDGET": str(budget),
    };
    if scoped {
        env["OMB_GATE_TOOL_SCOPE"] = json.dumps(parsed["scope"]);
    }
    return {
        "command": node_exec_path(),
        "args": [resolve_proxy("mcp-gate")],
        "env": env,
    };
}

# ── structured questions (shared/ask-question.ts) ──────────────────────────

glob ASK_USER_QUESTION_TOOL: str = "AskUserQuestion";
glob MAX_QUESTIONS: int = 6;
glob MAX_OPTIONS: int = 12;
glob MAX_QUESTION_TEXT: int = 8000;
glob MAX_LABEL: int = 120;
glob MAX_DESCRIPTION: int = 400;
glob MAX_CHOICES: int = 5;

def _bound_text(value: any, limit: int) -> any {
    if not isinstance(value, str) { return None; }
    trimmed = value.strip();
    if not trimmed { return None; }
    return trimmed[0:limit].strip();
}

def _is_record(value: any) -> bool {
    return isinstance(value, dict);
}

def _parse_question_option(value: any) -> any {
    if isinstance(value, str) {
        label = _bound_text(value, MAX_LABEL);
        return {"label": label} if label else None;
    }
    if not _is_record(value) { return None; }
    label = _bound_text(value.get("label"), MAX_LABEL);
    if not label { return None; }
    description = _bound_text(value.get("description"), MAX_DESCRIPTION);
    if description { return {"label": label, "description": description}; }
    return {"label": label};
}

def _parse_one_question(value: any) -> any {
    if not _is_record(value) { return None; }
    question = _bound_text(value.get("question"), MAX_QUESTION_TEXT);
    if not question { return None; }
    options: list[any] = [];
    seen: dict[str, bool] = {};
    raw_options = value.get("options");
    if isinstance(raw_options, list) {
        for raw in raw_options {
            option = _parse_question_option(raw);
            if option is None or option["label"] in seen { continue; }
            seen[option["label"]] = True;
            options.append(option);
            if len(options) == MAX_OPTIONS { break; }
        }
    }
    out: dict[str, any] = {"question": question, "options": options};
    header = _bound_text(value.get("header"), MAX_LABEL);
    if header { out["header"] = header; }
    if value.get("multiSelect") is True { out["multiSelect"] = True; }
    return out;
}

def parse_ask_questions(input: any) -> any {
    if not _is_record(input) or not isinstance(input.get("questions"), list) { return None; }
    questions: list[any] = [];
    for raw in input["questions"] {
        q = _parse_one_question(raw);
        if q is None { continue; }
        questions.append(q);
        if len(questions) == MAX_QUESTIONS { break; }
    }
    return questions if questions else None;
}

def ask_question_summary(questions: list[any]) -> str {
    first = questions[0]["question"] if questions else "";
    rest = len(questions) - 1;
    if rest > 0 {
        return first + " (+" + str(rest) + " more question" + ("s" if rest > 1 else "") + ")";
    }
    return first;
}

def parse_choices(input: any, limit: int = MAX_CHOICES) -> any {
    if not isinstance(input, list) { return None; }
    choices: list[any] = [];
    seen: dict[str, bool] = {};
    for raw in input {
        label = None;
        if isinstance(raw, str) { label = _bound_text(raw, MAX_LABEL); }
        elif _is_record(raw) { label = _bound_text(raw.get("label"), MAX_LABEL); }
        if not label or label in seen { continue; }
        seen[label] = True;
        choices.append(label);
        if len(choices) == limit { break; }
    }
    return choices if choices else None;
}

def question_choices(questions: list[any]) -> any {
    if len(questions) != 1 { return None; }
    only = questions[0];
    if only.get("multiSelect") or len(only["options"]) < 2 { return None; }
    return [option["label"] for option in only["options"]];
}

# ── summaries (tool-summary.ts + redact) ───────────────────────────────────

glob REDACTION_MARKER_RE: any = re.compile(r"^«redacted \d+ chars»$");

def redact_mask(value: str) -> str {
    if REDACTION_MARKER_RE.match(value) { return value; }
    return "«redacted " + str(len(value)) + " chars»";
}

glob SECRET_KEY_PATTERNS: list[any] = [
    re.compile(r"\bom[dg]_[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])"),
    re.compile(r"\bsk-(?:ant-|proj-|live-|test-)?[A-Za-z0-9_-]{16,}"),
    re.compile(r"\bxai-[A-Za-z0-9_-]{20,}"),
    re.compile(r"\bgsk_[A-Za-z0-9]{40,}"),
    re.compile(r"\bcsk-[A-Za-z0-9]{32,}"),
    re.compile(r"\bhf_[A-Za-z0-9]{30,}"),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{20,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}"),
    re.compile(r"\bnpm_[A-Za-z0-9]{20,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
];
glob SECRET_BEARER_RE: any = re.compile(r"(\bBearer\s+)([A-Za-z0-9._~+/=-]{12,})");
glob SECRET_PEM_RE: any = re.compile(r"(-----BEGIN [A-Z ]*PRIVATE KEY-----)([\s\S]*?)(-----END [A-Z ]*PRIVATE KEY-----)");
glob SECRET_KEY_VALUE_RE: any = re.compile(
    r"\b((?:[A-Za-z0-9_-]*_)?(?:api[_-]?key|apikey|secret|token|password|passwd|authorization|auth[_-]?token|access[_-]?key|private[_-]?key)s?)([\"']?\s*[=:]\s*)([\"']?)([A-Za-z0-9._~+/=-]{8,})\3", re.I);
glob SECRET_KEY_SUFFIX_RE: any = re.compile(r"\b([A-Za-z][A-Za-z0-9_-]*[_-]key)s?(=)([\"']?)([A-Za-z0-9._~+/=-]+)\3");
glob SECRET_FLAG_RE: any = re.compile(
    r"(--(?:token|password|passwd|api-key|apikey|secret|access-key|auth-token)(?:=|\s+))([\"']?)(?!-)([A-Za-z0-9._~+/=-]+)\2");
glob SECRET_URL_USERINFO_RE: any = re.compile(r"(\b[a-z][a-z0-9+.-]*://[^\s/:@'\":]+:)([^\s/@'\"«»]+)(@)");

def _mask_match(m: any) -> str {
    return redact_mask(m.group(0));
}

def _sub_pem(m: any) -> str {
    return m.group(1) + "\n" + redact_mask(m.group(2).strip()) + "\n" + m.group(3);
}

def _sub_bearer(m: any) -> str {
    return m.group(1) + redact_mask(m.group(2));
}

def _sub_key_value(m: any) -> str {
    return m.group(1) + m.group(2) + m.group(3) + redact_mask(m.group(4)) + m.group(3);
}

def _sub_flag(m: any) -> str {
    return m.group(1) + m.group(2) + redact_mask(m.group(3)) + m.group(2);
}

def _sub_userinfo(m: any) -> str {
    return m.group(1) + redact_mask(m.group(2)) + m.group(3);
}

def redact_secrets_in_text(text: str) -> str {
    if not text or len(text) < 8 { return text; }
    out = SECRET_PEM_RE.sub(_sub_pem, text);
    for pat in SECRET_KEY_PATTERNS {
        out = pat.sub(_mask_match, out);
    }
    out = SECRET_BEARER_RE.sub(_sub_bearer, out);
    out = SECRET_KEY_VALUE_RE.sub(_sub_key_value, out);
    out = SECRET_KEY_SUFFIX_RE.sub(_sub_key_value, out);
    out = SECRET_FLAG_RE.sub(_sub_flag, out);
    out = SECRET_URL_USERINFO_RE.sub(_sub_userinfo, out);
    return out;
}

glob SUMMARY_LIMIT: int = 200;

def _summary_cut(text: str, limit: int) -> str {
    return redact_secrets_in_text(text).strip()[0:limit];
}

def command_summary(input: any) -> any {
    if not _is_record(input) { return None; }
    command = input.get("command");
    if not isinstance(command, str) { return None; }
    return _summary_cut(re.sub(r"\s*[\r\n]+\s*", " ", command), SUMMARY_LIMIT);
}

def ask_input_summary(input: any) -> any {
    # The permission card's subtitle: question, else command, else URL, else
    # the arguments as JSON. Undefined when there is nothing to say.
    if not _is_record(input) { return None; }
    q = input.get("question");
    if isinstance(q, str) { return _summary_cut(q, MAX_QUESTION_TEXT); }
    command = input.get("command");
    if isinstance(command, str) { return _summary_cut(command, SUMMARY_LIMIT); }
    url = input.get("url");
    if isinstance(url, str) { return _summary_cut(url, SUMMARY_LIMIT); }
    text = json.dumps(input);
    if text == "{}" { return None; }
    return _summary_cut(text, SUMMARY_LIMIT);
}

# ── retry policy (drivers/retry.ts) ────────────────────────────────────────

glob RETRY_MAX_ATTEMPTS: int = 3;
glob BACKOFF_BASE_MS: list[any] = [1000, 3000, 8000];

def is_provider_safety_block(message: str) -> bool {
    return re.search(
        r"\bblocked by (?:our|the provider['’]s) safety systems\b|\bsafety monitoring\b.{0,100}\b(?:paused|ended|blocked)\b|\b(?:safety_check_failed|safety_policy_violation)\b",
        message, re.I) is not None;
}

glob TRANSIENT_PATTERNS: list[any] = [
    (re.compile(r"\b(?:429|rate.?limit|too many requests)\b", re.I), "rate_limited"),
    (re.compile(r"\boverloaded\b|\bcapacity\b", re.I), "overloaded"),
    (re.compile(r"\b5\d{2}\b|\binternal server error\b|\bbad gateway\b|\bservice unavailable\b", re.I), "server_error"),
    (re.compile(r"\b(?:econnreset|econnrefused|epipe|etimedout|eai_again|connection reset|connection refused|socket hang up|network error|fetch failed)\b", re.I), "connection_reset"),
    (re.compile(r"\btimeout(ed)?\b|\btimed? out\b", re.I), "timeout"),
];
glob TERMINAL_PATTERNS: list[any] = [
    (re.compile(r"\b(?:40[13]|unauthorized|forbidden|invalid api key|missing bearer|authentication required|not logged in|logged out)\b", re.I), "auth"),
    (re.compile(r"\busage limit\b|\bhit your (?:usage )?limit\b|\b(?:weekly|daily|monthly|subscription|usage) limit reached\b|\bout of credits\b", re.I), "quota"),
    (re.compile(r"\b402\b|\bquota\b|\bbilling\b|\bsubscription\b", re.I), "quota"),
    (re.compile(r"\bmodel not found\b|\bunknown model\b|\bdoes not exist for model\b|\bunsupported model\b", re.I), "unknown_model"),
    (re.compile(r"\b400\b|\b422\b|\binvalid request\b|\bmalformed\b|\bunexpected status\b", re.I), "invalid_request"),
    (re.compile(r"\b404\b|\bno such thread\b|\bthread gone\b", re.I), "not_found"),
    (re.compile(r"\b(?:interrupted|cancelled by user)\b", re.I), "interrupted"),
];

def classify_error(text: str, exit_code: any = "__none__") -> dict[str, any] {
    # Classify a failure message (optionally a CLI exit) into retry-worthy
    # vs terminal. A nonzero exit with no matching text is terminal.
    if is_provider_safety_block(text) { return {"transient": False, "reason": "provider_safety"}; }
    if exit_code != "__none__" and exit_code is not None and exit_code < 0 {
        return {"transient": False, "reason": "interrupted"};
    }
    for (pat, reason) in TERMINAL_PATTERNS {
        if pat.search(text) { return {"transient": False, "reason": reason}; }
    }
    for (pat, reason) in TRANSIENT_PATTERNS {
        if pat.search(text) { return {"transient": True, "reason": reason}; }
    }
    if exit_code != "__none__" { return {"transient": False, "reason": "terminal_exit"}; }
    return {"transient": False, "reason": "unknown"};
}

def compute_backoff(attempt: int) -> int {
    import random;
    idx = attempt;
    if idx < 0 { idx = 0; }
    if idx > len(BACKOFF_BASE_MS) - 1 { idx = len(BACKOFF_BASE_MS) - 1; }
    base = BACKOFF_BASE_MS[idx];
    jitter = base * 0.25;
    return int(round(base - jitter + random.random() * jitter * 2));
}

# ── session idle policy (drivers/session-idle.ts) ──────────────────────────

glob DEFAULT_IDLE_MS: int = 600000;
glob MINIMUM_IDLE_MS: int = 10000;
glob MAX_TIMER_MS: int = 2147483647;

def _usable_ms(raw: any) -> any {
    try {
        value = float(raw);
    } except Exception {
        return None;
    }
    if value > 0 and value <= MAX_TIMER_MS { return value; }
    return None;
}

def session_idle_policy(prefix: str, env: dict[str, any]) -> dict[str, any] {
    own_min = env.get("OMB_" + prefix + "_SESSION_IDLE_MIN_MS");
    global_min = env.get("OMB_SESSION_IDLE_MIN_MS");
    minimum: any = MINIMUM_IDLE_MS;
    picked: any = None;
    if own_min is not None {
        picked = _usable_ms(own_min);
    } else {
        picked = _usable_ms(global_min);
    }
    if picked is not None and picked > minimum { minimum = int(picked); }
    own_ms = env.get("OMB_" + prefix + "_SESSION_IDLE_MS");
    configured: any = None;
    if own_ms is not None {
        configured = _usable_ms(own_ms);
    } else {
        configured = _usable_ms(env.get("OMB_SESSION_IDLE_MS"));
    }
    if configured is None { configured = DEFAULT_IDLE_MS; }
    idle = int(configured);
    if idle < minimum { idle = minimum; }
    return {"idle_ms": idle, "minimum_ms": minimum};
}

# ── cost accounting (claude.ts) ────────────────────────────────────────────

def turn_cost_from_running_total(total: any, previous: any) -> any {
    if total is None { return None; }
    if previous is None or total < previous { return total; }
    return float(round(total - previous, 10));
}

def claude_cost_snapshot(total: any, model_usage: any) -> any {
    if not isinstance(total, (int, float)) or isinstance(total, bool) { return None; }
    models: dict[str, any] = {};
    if isinstance(model_usage, dict) {
        for (model, raw) in model_usage.items() {
            if not isinstance(raw, dict) { continue; }
            models[model] = [
                raw.get("inputTokens") if isinstance(raw.get("inputTokens"), (int, float)) and not isinstance(raw.get("inputTokens"), bool) else 0,
                raw.get("cacheReadInputTokens") if isinstance(raw.get("cacheReadInputTokens"), (int, float)) and not isinstance(raw.get("cacheReadInputTokens"), bool) else 0,
                raw.get("cacheCreationInputTokens") if isinstance(raw.get("cacheCreationInputTokens"), (int, float)) and not isinstance(raw.get("cacheCreationInputTokens"), bool) else 0,
                raw.get("outputTokens") if isinstance(raw.get("outputTokens"), (int, float)) and not isinstance(raw.get("outputTokens"), bool) else 0,
            ];
        }
    }
    return {"total": total, "models": models};
}

def restored_cost_base(earlier: list[any], current: dict[str, any], usage: list[any]) -> any {
    # The running total a resumed session already carried before this
    # process's first turn; the latest state inside the new counts wins.
    turn = usage;
    nothing: dict[str, any] = {"total": 0, "models": {}};
    exact: any = None;
    inside: any = 0;
    states: list[any] = [nothing];
    states.extend(earlier);
    for state in states {
        within = True;
        for (model, counts) in state["models"].items() {
            cur = current["models"].get(model);
            i = 0;
            while i < 4 {
                if counts[i] > (cur[i] if cur is not None else 0) { within = False; break; }
                i += 1;
            }
            if not within { break; }
        }
        if not within { continue; }
        inside = state["total"];
        growth: list[any] = [];
        for (model, counts) in current["models"].items() {
            prev = state["models"].get(model);
            row: list[any] = [];
            i = 0;
            while i < 4 {
                row.append(counts[i] - (prev[i] if prev is not None else 0));
                i += 1;
            }
            growth.append(row);
        }
        summed: list[any] = [];
        i = 0;
        while i < 4 {
            total = 0;
            for counts in growth { total += counts[i]; }
            summed.append(total);
            i += 1;
        }
        def _is_turn(counts: list[any]) -> bool {
            i = 0;
            while i < 4 {
                if counts[i] != turn[i] { return False; }
                i += 1;
            }
            return True;
        }
        hit = False;
        for counts in growth {
            if _is_turn(counts) { hit = True; break; }
        }
        if hit or _is_turn(summed) { exact = state["total"]; }
    }
    return exact if exact is not None else inside;
}

glob COST_HISTORY_FILE: str = os.path.join(DATA_DIR, "claude-cost-history.json");
glob COST_HISTORY_SESSIONS: int = 100;
glob COST_HISTORY_STATES: int = 8;

def _cost_snapshot_ok(value: any) -> bool {
    if not isinstance(value, dict) { return False; }
    total = value.get("total");
    models = value.get("models");
    if not isinstance(total, (int, float)) or isinstance(total, bool) { return False; }
    if not isinstance(models, dict) { return False; }
    for counts in models.values() {
        if not isinstance(counts, list) or len(counts) != 4 { return False; }
        for n in counts {
            if not isinstance(n, (int, float)) or isinstance(n, bool) { return False; }
        }
    }
    return True;
}

def read_cost_history() -> dict[str, any] {
    try {
        f = open(COST_HISTORY_FILE, "r", encoding="utf-8");
        try {
            parsed = json.loads(f.read());
        } finally {
            f.close();
        }
    } except Exception {
        return {};
    }
    if not isinstance(parsed, dict) { return {}; }
    out: dict[str, any] = {};
    for (id, states) in parsed.items() {
        if not isinstance(states, list) { continue; }
        out[id] = [s for s in states if _cost_snapshot_ok(s)];
    }
    return out;
}

def record_cost_state(session_id: str, state: dict[str, any]) {
    history = read_cost_history();
    states: list[any] = list(history.get(session_id) or []);
    states.append(state);
    if len(states) > COST_HISTORY_STATES { states = states[len(states) - COST_HISTORY_STATES:]; }
    history.pop(session_id, None);
    history[session_id] = states;
    ids = list(history.keys());
    drop = len(ids) - COST_HISTORY_SESSIONS;
    if drop > 0 {
        for id in ids[0:drop] {
            history.pop(id, None);
        }
    }
    try {
        os.makedirs(os.path.dirname(COST_HISTORY_FILE), exist_ok=True);
        f = open(COST_HISTORY_FILE, "w", encoding="utf-8");
        try {
            f.write(json.dumps(history));
        } finally {
            f.close();
        }
        try {
            os.chmod(COST_HISTORY_FILE, 0o600);
        } except Exception {
        }
    } except Exception {
    }
}

def sum_native_turn_results(earlier: any, latest: dict[str, any]) -> dict[str, any] {
    # One logical turn made of several native turns: any failed half fails
    # it, the last stop reason stands, usage adds up, cost is the latest.
    if earlier is None { return latest; }
    out: dict[str, any] = {
        "ok": bool(earlier.get("ok")) and bool(latest.get("ok")),
        "stopReason": latest.get("stopReason") if latest.get("stopReason") is not None else earlier.get("stopReason"),
        "cost": latest.get("cost") if latest.get("cost") is not None else earlier.get("cost"),
    };
    eu = earlier.get("usage");
    lu = latest.get("usage");
    if eu is not None and lu is not None {
        usage: dict[str, any] = {"input": eu.get("input", 0) + lu.get("input", 0), "output": eu.get("output", 0) + lu.get("output", 0)};
        if eu.get("cachedInput") is not None or lu.get("cachedInput") is not None {
            usage["cachedInput"] = (eu.get("cachedInput") or 0) + (lu.get("cachedInput") or 0);
        }
        out["usage"] = usage;
    } elif lu is not None {
        out["usage"] = lu;
    } elif eu is not None {
        out["usage"] = eu;
    }
    return out;
}

# ── resume recovery (server/resume-recovery.ts) ────────────────────────────

def classify_resume_failure(attempted: bool, rejected: bool, prompt_submitted: bool, produced_output: bool) -> str {
    if produced_output or prompt_submitted { return "after-accept"; }
    if attempted and rejected { return "before-accept"; }
    return "unknown";
}

def may_replay(failure: str) -> bool {
    return failure == "before-accept";
}

def recovery_prompt_for(recovery_text: any, current_text: str, failure: str) -> dict[str, any] {
    if not may_replay(failure) { return {"text": current_text, "replayed": False}; }
    replay = recovery_text.strip() if isinstance(recovery_text, str) else "";
    if not replay or replay == current_text.strip() {
        return {"text": current_text, "replayed": False};
    }
    return {"text": recovery_text, "replayed": True};
}

# ── frame classification (claude.ts) ───────────────────────────────────────

def claude_auth_failure(frame: dict[str, any], text: str) -> bool {
    if frame.get("is_api_error_message") is not True and not isinstance(frame.get("error"), str) { return False; }
    if frame.get("error") == "authentication_failed" { return True; }
    verdict = classify_error(text);
    return verdict["reason"] == "auth";
}

def claude_version_too_old(frame: dict[str, any], text: str) -> bool {
    if frame.get("is_api_error_message") is not True and not isinstance(frame.get("error"), str) { return False; }
    return re.search(r"\bClaude Code v?\d+(?:\.\d+)+ does not support this model\b", text, re.I) is not None;
}

def first_text(content: any) -> str {
    if isinstance(content, str) { return content; }
    if isinstance(content, list) {
        parts: list[str] = [];
        for b in content {
            if isinstance(b, dict) and b.get("type") == "text" and b.get("text") {
                parts.append(b["text"]);
            }
        }
        return "".join(parts);
    }
    return "";
}

# ── user messages (claude.ts) ──────────────────────────────────────────────

def with_volatile_note(text: str, volatile: str) -> str {
    if volatile.strip() {
        body = "This part of your instructions changed since this session started. It replaces the earlier copy:\n\n" + volatile.strip();
    } else {
        body = "The notes that were in your instructions when this session started have been cleared.";
    }
    note = "<system-reminder>\n" + body + "\n</system-reminder>";
    return note + "\n\n" + text if text else note;
}

def claude_user_message(text: str, images: any) -> dict[str, any] {
    if not images {
        return {"type": "user", "message": {"role": "user", "content": text}};
    }
    content: list[any] = [];
    for image in images {
        data = "";
        try {
            f = open(image.get("path"), "rb");
            try {
                import base64;
                data = base64.b64encode(f.read()).decode("ascii");
            } finally {
                f.close();
            }
        } except Exception {
            data = "";
        }
        content.append({"type": "image", "source": {"type": "base64", "media_type": image.get("mime"), "data": data}});
    }
    if text { content.append({"type": "text", "text": text}); }
    return {"type": "user", "message": {"role": "user", "content": content}};
}

def diagnostic_user_message(message: dict[str, any]) -> dict[str, any] {
    # Keep an image block's shape and size for debugging, never its bytes.
    content = message.get("message", {}).get("content");
    if not isinstance(content, list) { return message; }
    new_content: list[any] = [];
    for block in content {
        if isinstance(block, dict) and block.get("type") == "image" and isinstance(block.get("source"), dict) and isinstance(block["source"].get("data"), str) {
            source = dict(block["source"]);
            source["data"] = "[image data: " + str(len(block["source"]["data"])) + " base64 chars]";
            nb = dict(block);
            nb["source"] = source;
            new_content.append(nb);
        } else {
            new_content.append(block);
        }
    }
    out = dict(message);
    inner = dict(message.get("message", {}));
    inner["content"] = new_content;
    out["message"] = inner;
    return out;
}

def extract_mcp_images(content: any) -> list[any] {
    arr: any = None;
    if isinstance(content, list) {
        arr = content;
    } elif isinstance(content, dict) and isinstance(content.get("content"), list) {
        arr = content["content"];
    }
    out: list[any] = [];
    if arr is None { return out; }
    for c in arr {
        if not isinstance(c, dict) { continue; }
        if c.get("type") == "image" and isinstance(c.get("data"), str) and isinstance(c.get("mimeType"), str) {
            out.append({"data": c["data"], "mimeType": c["mimeType"]});
            continue;
        }
        source = c.get("source") if c.get("type") == "image" else None;
        if isinstance(source, dict) and source.get("type") == "base64" and isinstance(source.get("media_type"), str) and isinstance(source.get("data"), str) {
            out.append({"data": source["data"], "mimeType": source["media_type"]});
        }
    }
    return out;
}

# ── hooks + broker sockets (claude.ts) ─────────────────────────────────────

def hook_token_file(thread_id: str, bot_id: any) -> str {
    digest = hashlib.sha256(((bot_id or "") + "\x00" + thread_id).encode("utf-8")).hexdigest()[0:24];
    return os.path.join(DATA_DIR, "hook-tokens", digest + ".token");
}

def _shell_quote(path: str) -> str {
    return "'" + path.replace("'", "'\\''") + "'";
}

def claude_hook_settings(helper_path: str, node_path: str) -> dict[str, any] {
    # One command per observed event; the string is a shell line, so both
    # paths are quoted. Windows paths ride env variables instead.
    command = _shell_quote(node_path) + " " + _shell_quote(helper_path);
    hook_entry: list[any] = [{"matcher": "", "hooks": [{"type": "command", "command": command, "timeout": 5}]}];
    return {"PostToolUse": hook_entry, "PreCompact": hook_entry, "SessionStart": hook_entry, "Stop": hook_entry};
}

def permission_socket_path(thread_id: str, bot_id: any) -> str {
    # Half the tag is a digest of the FULL id (and bot), so distinct threads
    # get distinct sockets; the readable prefix keeps it recognisable.
    key = (bot_id + "\x00" + thread_id) if bot_id else thread_id;
    prefix = re.sub(r"[^\w-]", "", thread_id)[0:4];
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()[0:4];
    return os.path.join(DATA_DIR, "perm-" + prefix + digest + ".sock");
}

def broker_socket_candidates(thread_id: str, bot_id: any) -> list[any] {
    base = permission_socket_path(thread_id, bot_id);
    scope = hashlib.sha256((DATA_DIR + "\x00" + str(os.getpid()) + "\x00" + (bot_id or "") + "\x00" + thread_id).encode("utf-8")).hexdigest()[0:16];
    import tempfile;
    return [base, os.path.join(tempfile.gettempdir(), "omb-perm-" + scope + ".sock")];
}

def project_mcp_servers(cwd: str) -> dict[str, any] {
    # MCP servers the bot's own project declares in <cwd>/.mcp.json, forwarded
    # verbatim; a malformed file is ignored rather than failing the turn.
    try {
        f = open(os.path.join(cwd, ".mcp.json"), "r", encoding="utf-8");
        try {
            parsed = json.loads(f.read());
        } finally {
            f.close();
        }
    } except Exception {
        return {};
    }
    if not isinstance(parsed, dict) { return {}; }
    servers = parsed.get("mcpServers");
    if not isinstance(servers, dict) { return {}; }
    out: dict[str, any] = {};
    for (name, server) in servers.items() {
        if isinstance(server, dict) { out[name] = server; }
    }
    return out;
}

# ── deep redaction + tool detail preview (server/redact.ts, tool-summary) ──

def _is_secret_name(name: str) -> bool {
    lower = name.lower();
    if lower == "omb_gate_upstream" or lower == "omb_remote_mcp_server" { return True; }
    if "token" in lower or "secret" in lower or "password" in lower or "passwd" in lower or "apikey" in lower or "api_key" in lower or "authorization" in lower or "auth_token" in lower {
        return True;
    }
    return re.search(r"(^|[_.-])keys?$", lower) is not None;
}

def redact_secrets(value: any, depth: int = 0) -> any {
    # Deep copy with credential VALUES replaced (shape kept, values lost).
    if isinstance(value, str) { return redact_secrets_in_text(value); }
    if depth > 12 or value is None or not isinstance(value, (dict, list)) { return value; }
    if isinstance(value, list) {
        out: list[any] = [];
        for item in value {
            if isinstance(item, dict) and isinstance(item.get("name"), str) and isinstance(item.get("value"), str) {
                row = dict(item);
                if _is_secret_name(item["name"]) {
                    row["value"] = redact_mask(item["value"]);
                } else {
                    row["value"] = redact_secrets_in_text(item["value"]);
                }
                out.append(row);
            } else {
                out.append(redact_secrets(item, depth + 1));
            }
        }
        return out;
    }
    out_d: dict[str, any] = {};
    for (key, child) in value.items() {
        if isinstance(child, str) and _is_secret_name(key) {
            out_d[key] = redact_mask(child);
            continue;
        }
        out_d[key] = redact_secrets(child, depth + 1);
    }
    return out_d;
}

glob PREVIEW_BUDGET: int = 200;
glob PREVIEW_TEXT_BUDGET: int = 256000;
glob PREVIEW_LIMIT: int = 6000;

def tool_detail_preview(value: any) -> any {
    # Display-only excerpt, never the raw protocol payload. Bound traversal,
    # omit binary bodies, redact, then truncate.
    if value is None { return None; }
    budget: dict[str, any] = {"n": PREVIEW_BUDGET, "text": PREVIEW_TEXT_BUDGET};

    def bounded(item: any, depth: int = 0) -> any {
        budget["n"] -= 1;
        if budget["n"] < 0 or depth > 6 { return "[additional data omitted]"; }
        if isinstance(item, str) {
            if len(item) > budget["text"] { return "[large content omitted]"; }
            if re.match(r"^data:[^,\s]+;base64,", item, re.I) { return "[binary content omitted]"; }
            # MCP frequently puts JSON inside text content: recover its field
            # names so short credentials get the same masking.
            if re.match(r"^\s*[[{]", item) {
                try {
                    return bounded(json.loads(item), depth + 1);
                } except Exception {
                }
            }
            budget["text"] -= len(item);
            return item;
        }
        if item is None or not isinstance(item, (dict, list)) { return item; }
        if isinstance(item, list) {
            out_l: list[any] = [];
            for child in item[0:40] {
                out_l.append(bounded(child, depth + 1));
            }
            if len(item) > 40 { out_l.append("[additional items omitted]"); }
            return out_l;
        }
        result: dict[str, any] = {};
        entries = list(item.items());
        for pair in entries[0:40] {
            key = pair[0];
            child = pair[1];
            if re.search(r"token|secret|password|passwd|cookie|authorization|api.?key|(^|[_.-])keys?$", key, re.I) {
                result[key] = "[redacted]";
            } elif re.match(r"^(data|base64|blob)$", key, re.I) and isinstance(child, str) {
                result[key] = "[binary content omitted]";
            } else {
                result[key] = bounded(child, depth + 1);
            }
        }
        if len(entries) > 40 { result["…"] = "[additional fields omitted]"; }
        return result;
    }

    safe = redact_secrets(bounded(value, 0));
    text = safe if isinstance(safe, str) else json.dumps(safe, indent=2);
    if not text.strip() or text == "{}" or text == "[]" { return None; }
    if len(text) > PREVIEW_LIMIT { return text[0:PREVIEW_LIMIT] + "\n[… preview shortened]"; }
    return text;
}
