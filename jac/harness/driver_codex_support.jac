"""Pure helpers for the Codex driver port (server/drivers/codex.ts and its
support modules: codex-instructions, codex-mcp-names, codex-tool-surface,
codex-catalog's decodeCodexSelection, local-inject's codexLocalProviderArgs,
prompt-split's note helpers, permission-command, shared/ask-question's
protocol helpers, mcp-gate-config's per-mount gate, native.ts's tee).

No process or thread ownership here: that lives in driver_codex.jac. The
shared Claude helpers (tool scope, redaction, previews, retry policy) are
imported from driver_claude_support rather than duplicated."""

import os;
import re;
import json;
import time;
import hashlib;

import from driver_claude_support {
    parse_tool_scope, remote_mcp_spec, spill_dir, node_exec_path, resolve_proxy,
    redact_secrets, server_root, _parse_one_question,
}

# ── JSON / paths ───────────────────────────────────────────────────────────

# JSON.stringify: compact separators, non-ASCII kept verbatim. Argv and
# receipt digests depend on byte-identical output.
def js(value: any) -> str {
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False);
}

# DATA_DIR resolved per call (config.ts reads OMB_DATA_DIR once at boot; the
# harness inherits the same variable from the node parent).
def data_dir() -> str {
    configured = os.environ.get("OMB_DATA_DIR");
    if configured { return configured; }
    return os.path.join(os.path.expanduser("~"), ".openmausbot");
}

def iso_now() -> str {
    now = time.time();
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + f".{int(now * 1000) % 1000:03d}Z";
}

def sha256_hex(value: str) -> str {
    return hashlib.sha256(value.encode("utf-8")).hexdigest();
}

# Number(env ?? fallback) || fallback, floored at 1 (the FAKE_CODEX_* knobs).
def env_ms(name: str, fallback: float) -> float {
    raw = os.environ.get(name);
    if raw is None { return fallback; }
    try {
        value = float(raw);
    } except Exception {
        return fallback;
    }
    if value != value or value == 0 { return fallback; }
    return max(1.0, value);
}

def env_scale(name: str) -> float {
    raw = os.environ.get(name);
    if raw is None { return 1.0; }
    try {
        value = float(raw);
    } except Exception {
        return 1.0;
    }
    if value != value { return 1.0; }
    return value;
}

def server_version() -> str {
    from_env = (os.environ.get("OMB_APP_VERSION") or "").strip();
    if from_env { return from_env; }
    try {
        f = open(os.path.join(server_root(), "..", "package.json"), "r", encoding="utf-8");
        try {
            pkg = json.loads(f.read());
        } finally {
            f.close();
        }
        version = pkg.get("version") if isinstance(pkg, dict) else None;
        if isinstance(version, str) and version { return version; }
    } except Exception {
    }
    return "unknown";
}

# ── errors ─────────────────────────────────────────────────────────────────

glob DRIVER_KIND: str = "codex";

def codex_user_error(value: str, chatgpt_plan: bool) -> str {
    if chatgpt_plan and "subscription_sharing_usage_limit_exceeded" in value {
        return "subscription_sharing_usage_limit_exceeded: Your ChatGPT plan usage limit was reached. Manage usage in ChatGPT Settings, or explicitly choose another provider.";
    }
    if "provider_not_configured" in value {
        if chatgpt_plan {
            return "provider_not_configured: ChatGPT has not enabled this model for the selected account. Refresh models or reconnect ChatGPT plan in Settings. API billing will not be used.";
        }
        return "provider_not_configured: This Codex account cannot use the selected route. For the new ChatGPT plan models, choose ChatGPT plan in Settings → Engines and Continue with ChatGPT, then select a model from that account.";
    }
    return value[0:400];
}

# CodexRpcError: a RuntimeError tagged with the JSON-RPC error code.
def rpc_error(error: any) -> any {
    message: any = None;
    code: any = None;
    if isinstance(error, dict) {
        message = error.get("message");
        code = error.get("code");
    }
    if not isinstance(message, str) { message = js(error); }
    err = RuntimeError(message);
    setattr(err, "codex_rpc", True);
    setattr(err, "rpc_code", code);
    return err;
}

def is_rpc_error(err: any) -> bool {
    return getattr(err, "codex_rpc", False) is True;
}

def error_message(err: any) -> str {
    if isinstance(err, BaseException) {
        if len(err.args) == 1 and isinstance(err.args[0], str) { return err.args[0]; }
        return str(err);
    }
    return str(err);
}

# Codex's local thread/resume rejection, verified with an empty native home.
# A generic 404, auth error, timeout or prose mentioning a missing thread is
# not evidence that the native history was lost. Unknown versions fail closed.
def missing_native_codex_thread(err: any, cursor: str) -> bool {
    return is_rpc_error(err) and getattr(err, "rpc_code", None) == -32600 and error_message(err) == "no rollout found for thread id " + cursor;
}

# ── provider routing args ──────────────────────────────────────────────────

def chatgpt_plan_codex_args() -> list[any] {
    return [
        "-c", 'model_provider="openai_chatgpt_plan"',
        "-c", 'model_providers.openai_chatgpt_plan.name="ChatGPT plan"',
        "-c", 'model_providers.openai_chatgpt_plan.base_url="https://api.openai.com/v1"',
        "-c", 'model_providers.openai_chatgpt_plan.env_key="OPENMAUSBOT_CHATGPT_TOKEN"',
        "-c", 'model_providers.openai_chatgpt_plan.wire_api="responses"',
        "-c", "model_providers.openai_chatgpt_plan.requires_openai_auth=false",
        "-c", "model_providers.openai_chatgpt_plan.supports_websockets=false",
        "-c", 'cli_auth_credentials_store="ephemeral"',
        "-c", "features.tool_search=false",
        "-c", "shell_environment_policy.ignore_default_excludes=false",
        "-c", 'shell_environment_policy.exclude=["OPENMAUSBOT_CHATGPT_TOKEN"]',
    ];
}

def managed_codex_args(managed: dict[str, any]) -> list[any] {
    # Credential stays in the instance environment, never argv or config.toml.
    return [
        "-c", 'model_provider="openmaus_company"',
        "-c", 'model_providers.openmaus_company.name="Company"',
        "-c", "model_providers.openmaus_company.base_url=" + js(managed.get("url")),
        "-c", 'model_providers.openmaus_company.env_key="OPENMAUSBOT_COMPANY_API_KEY"',
        "-c", 'model_providers.openmaus_company.wire_api="responses"',
        "-c", "model_providers.openmaus_company.requires_openai_auth=false",
        "-c", 'cli_auth_credentials_store="ephemeral"',
        "-c", "shell_environment_policy.ignore_default_excludes=false",
    ];
}

# codex-tool-surface.ts: OpenMausBot owns computer selection; the desktop
# browser/computer tools stay off in the child (native search untouched).
def codex_tool_surface_args() -> list[any] {
    return [
        "-c", "features.browser_use=false",
        "-c", "features.browser_use_external=false",
        "-c", "features.computer_use=false",
        "-c", 'plugins={ "browser@openai-bundled" = { enabled = false }, "computer-use@openai-bundled" = { enabled = false }, "unified-computer-use@openai-bundled" = { enabled = false } }',
    ];
}

# What a guest-driven turn's app-server starts with: the shell, unified exec
# and image reads off (codex-cli 0.159.0 `features`), web search too.
glob GUEST_CONFINED_CODEX_ARGS: list[any] = [
    "-c", "features.shell_tool=false", "-c", "features.unified_exec=false", "-c", "features.view_image=false", "-c", 'web_search="disabled"',
];

glob CODEX_SELECTION_SEP: str = "::";
glob CODEX_MODEL_ID_RE: any = re.compile(r"^[\w][\w./:+-]*$", re.ASCII);
glob OFFICIAL_CODEX_PROVIDER: str = "openai";

# codex-catalog.ts decodeCodexSelection: picker ids encode provider::model.
def decode_codex_selection(id: any) -> dict[str, any] {
    if not id { return {"model": None, "modelProvider": None}; }
    sep = id.find(CODEX_SELECTION_SEP);
    if sep > 0 {
        return {"model": id[sep + len(CODEX_SELECTION_SEP):], "modelProvider": id[0:sep]};
    }
    provider: any = None;
    if CODEX_MODEL_ID_RE.match(id) { provider = OFFICIAL_CODEX_PROVIDER; }
    return {"model": id, "modelProvider": provider};
}

# local-inject.ts
glob CODEX_LOCAL_HOSTS: dict[str, any] = {
    "omlx": {"id": "omlx", "label": "oMLX", "baseUrl": "http://127.0.0.1:8080/v1", "apiKey": "omlx"},
    "ollama": {"id": "ollama", "label": "Ollama", "baseUrl": "http://127.0.0.1:11434/v1", "apiKey": "ollama"},
    "local_ollama": {"id": "local_ollama", "label": "Ollama", "baseUrl": "http://127.0.0.1:11434/v1", "apiKey": "ollama"},
    "exo": {"id": "exo", "label": "EXO", "baseUrl": "http://127.0.0.1:52415/v1", "apiKey": "exo"},
    "lmstudio": {"id": "lmstudio", "label": "LM Studio", "baseUrl": "http://127.0.0.1:1234/v1", "apiKey": "lm-studio"},
    "unsloth": {"id": "unsloth", "label": "Unsloth", "baseUrl": "http://127.0.0.1:8888/v1", "apiKeyEnv": "UNSLOTH_STUDIO_AUTH_TOKEN"},
    "unsloth_api": {"id": "unsloth_api", "label": "Unsloth", "baseUrl": "http://127.0.0.1:8888/v1", "apiKeyEnv": "UNSLOTH_STUDIO_AUTH_TOKEN"},
};
glob CODEX_RESERVED_PROVIDERS: list[any] = ["openai", "ollama", "lmstudio"];

def _decode_inject_id(id: any) -> any {
    if not id { return None; }
    sep = id.find("::");
    if sep <= 0 { return None; }
    host = id[0:sep];
    model = id[sep + 2:];
    if host not in CODEX_LOCAL_HOSTS or not CODEX_MODEL_ID_RE.match(model) { return None; }
    return {"host": host, "model": model};
}

def _first_unsloth_token(row: any) -> any {
    if not isinstance(row, dict) { return None; }
    for bucket in [row.get("minted"), row.get("saved")] {
        if isinstance(bucket, str) and bucket { return bucket; }
        if isinstance(bucket, list) {
            for value in bucket {
                if isinstance(value, str) and value { return value; }
            }
        }
    }
    api_key = row.get("api_key");
    if isinstance(api_key, str) and api_key { return api_key; }
    return None;
}

def _read_unsloth_key(env: dict[str, any]) -> any {
    home = env.get("HOME") or env.get("USERPROFILE") or os.path.expanduser("~");
    try {
        f = open(os.path.join(home, ".unsloth", "studio", "auth", "agent_api_key.json"), "r", encoding="utf-8");
        try {
            raw = json.loads(f.read());
        } finally {
            f.close();
        }
    } except Exception {
        return None;
    }
    if not isinstance(raw, dict) { return None; }
    servers = raw.get("servers");
    if isinstance(servers, dict) {
        for url in ["http://127.0.0.1:8888", "http://localhost:8888"] {
            token = _first_unsloth_token(servers.get(url));
            if token { return token; }
        }
        for row in servers.values() {
            token = _first_unsloth_token(row);
            if token { return token; }
        }
    }
    api_key = raw.get("api_key");
    if isinstance(api_key, str) and api_key { return api_key; }
    return None;
}

def _host_api_key(host: dict[str, any], env: dict[str, any]) -> str {
    key_env = host.get("apiKeyEnv");
    if key_env and env.get(key_env) { return env[key_env]; }
    if host.get("apiKey") { return host["apiKey"]; }
    if host["id"] == "unsloth" or host["id"] == "unsloth_api" {
        from_file = _read_unsloth_key(env);
        if from_file { return from_file; }
    }
    return "local";
}

# Configure a custom local provider on the app-server without rewriting the
# user's config.toml. The secret rides in the child env; argv names the key.
def codex_local_provider_args(env: dict[str, any], model_id: any) -> list[any] {
    inject = _decode_inject_id(model_id);
    if inject is None or inject["host"] in CODEX_RESERVED_PROVIDERS { return []; }
    host = CODEX_LOCAL_HOSTS.get(inject["host"]);
    if host is None { return []; }
    env_key = "OPENMAUSBOT_LOCAL_" + re.sub(r"[^A-Z0-9]+", "_", host["id"].upper()) + "_API_KEY";
    env[env_key] = _host_api_key(host, env);
    return [
        "-c", "model_providers." + host["id"] + ".name=" + js(host["label"]),
        "-c", "model_providers." + host["id"] + ".base_url=" + js(host["baseUrl"]),
        "-c", "model_providers." + host["id"] + ".env_key=" + js(env_key),
    ];
}

# ── MCP mounting ───────────────────────────────────────────────────────────

# A TOML inline table for a `-c key=value` override; JSON string quoting is
# valid TOML basic-string quoting.
def toml_inline_table(entries: dict[str, any]) -> str {
    parts: list[str] = [];
    for (key, value) in entries.items() {
        parts.append(js(key) + " = " + js(value));
    }
    return "{ " + ", ".join(parts) + " }";
}

def is_harness_owned_mcp_env_name(name: str) -> bool {
    return name == "ELECTRON_RUN_AS_NODE" or name.startswith("OMB_") or name.startswith("OGB_");
}

def mount_mcp_server(app_server_args: list[any], env: dict[str, any], name: str, server: dict[str, any], pre_approved: bool = True) {
    prefix = "mcp_servers." + name;
    if "url" in server {
        # A remote server: codex connects itself. Header values are
        # credentials and travel like env values — argv names variables only.
        app_server_args.extend(["-c", prefix + ".url=" + js(server["url"])]);
        stem = "OMB_MCP_HEADER_" + re.sub(r"[^A-Z0-9]", "_", name.upper());
        variables: dict[str, any] = {};
        headers: any = server.get("headers") if isinstance(server.get("headers"), dict) else {};
        index = 0;
        for (header, value) in headers.items() {
            bearer = re.match(r"^Bearer\s+(\S+)$", value, re.I) if header.lower() == "authorization" else None;
            if bearer is not None {
                env[stem + "_BEARER"] = bearer.group(1);
                app_server_args.extend(["-c", prefix + ".bearer_token_env_var=" + js(stem + "_BEARER")]);
            } else {
                variable = stem + "_" + str(index);
                env[variable] = value;
                variables[header] = variable;
            }
            index += 1;
        }
        if variables {
            app_server_args.extend(["-c", prefix + ".env_http_headers=" + toml_inline_table(variables)]);
        }
    } else {
        server_env: any = server.get("env") if isinstance(server.get("env"), dict) else {};
        for (key, value) in server_env.items() { env[key] = value; }
        app_server_args.extend([
            "-c", prefix + ".command=" + js(server.get("command")),
            "-c", prefix + ".args=" + js(server.get("args") or []),
            # Values stay in the child environment; argv names only.
            "-c", prefix + ".env_vars=" + js(list(server_env.keys())),
        ]);
    }
    # Harness-owned servers are pre-quieted; a user-configured server keeps
    # codex's on-request policy so its tool calls become approval cards.
    if pre_approved {
        app_server_args.extend(["-c", prefix + '.default_tools_approval_mode="auto"']);
    }
}

# codex-mcp-names.ts
glob _TOML_MCP_HEADER: any = re.compile(
    r"""^[ \t]*\[[ \t]*mcp_servers[ \t]*\.[ \t]*(?:"((?:[^"\\]|\\.)*)"|'([^']*)'|([A-Za-z0-9_-]+))[ \t]*[.\]]""",
    re.M
);

def mcp_server_names_in_toml(toml: str) -> list[any] {
    names: list[any] = [];
    for m in _TOML_MCP_HEADER.finditer(toml) {
        name: any = None;
        if m.group(1) is not None {
            name = re.sub(r"\\(.)", r"\1", m.group(1));
        } elif m.group(2) is not None {
            name = m.group(2);
        } else {
            name = m.group(3);
        }
        if name and name not in names { names.append(name); }
    }
    return names;
}

def codex_config_mcp_server_names(env: dict[str, any]) -> list[any] {
    codex_home = env.get("CODEX_HOME") or os.path.join(env.get("HOME") or env.get("USERPROFILE") or os.path.expanduser("~"), ".codex");
    try {
        f = open(os.path.join(codex_home, "config.toml"), "r", encoding="utf-8");
        try {
            return mcp_server_names_in_toml(f.read());
        } finally {
            f.close();
        }
    } except Exception {
        return [];
    }
}

def mounted_mcp_server_name(name: str, taken: list[any]) -> str {
    if name not in taken { return name; }
    candidate = name + "_openmausbot";
    i = 2;
    while candidate in taken {
        candidate = name + "_openmausbot" + str(i);
        i += 1;
    }
    return candidate;
}

# mcp-gate-config.ts gateServer with the codex options: a per-mount private
# config env name (one app-server child env serves every mount) and the
# node flag env. budget is always 0 for codex, so only a scope wraps.
glob GATE_CONFIG_ENV_RE: any = re.compile(r"^OMB_GATE_CONFIG_[a-f0-9]{64}$");

def codex_mcp_stdio_server(server: any, node_env: dict[str, any]) -> any {
    if not isinstance(server, dict) { return None; }
    command = server.get("command");
    if isinstance(command, str) and command { return server; }
    remote = remote_mcp_spec(server);
    if remote is None { return None; }
    env: dict[str, any] = dict(node_env);
    env["OMB_REMOTE_MCP_SERVER"] = js(remote);
    return {"command": node_exec_path(), "args": [resolve_proxy("mcp-remote-proxy")], "env": env};
}

def codex_gate_server(name: str, server: any, thread_id: str, budget: int, tool_scope: any, node_env: dict[str, any], config_env_name: any) -> any {
    parsed = parse_tool_scope(tool_scope);
    if not parsed["ok"] { raise RuntimeError(parsed["error"]); }
    scoped = parsed["scope"] is not None;
    if budget <= 0 and not scoped { return None; }
    if not scoped and remote_mcp_spec(server) is not None { return None; }
    spec = codex_mcp_stdio_server(server, node_env);
    if spec is None {
        if scoped { raise RuntimeError("Tool selection requires a supported MCP server."); }
        return None;
    }
    gate_env: dict[str, any] = {
        "OMB_GATE_NAME": name,
        "OMB_GATE_UPSTREAM": js({"command": spec.get("command"), "args": spec.get("args") or [], "env": spec.get("env") or {}}),
        "OMB_GATE_SPILL_DIR": spill_dir(thread_id),
        "OMB_GATE_BUDGET": str(budget),
    };
    if scoped { gate_env["OMB_GATE_TOOL_SCOPE"] = js(parsed["scope"]); }
    if config_env_name and (not scoped or not GATE_CONFIG_ENV_RE.match(config_env_name)) {
        raise RuntimeError("Invalid private MCP gate configuration.");
    }
    args: list[any] = [resolve_proxy("mcp-gate")];
    out_env: dict[str, any] = dict(node_env);
    if config_env_name {
        args.extend(["--config-env", config_env_name]);
        out_env[config_env_name] = js(gate_env);
    } else {
        out_env.update(gate_env);
    }
    return {"command": node_exec_path(), "args": args, "env": out_env};
}

# ── approvals ──────────────────────────────────────────────────────────────

def plain_record(value: any) -> any {
    return value if isinstance(value, dict) else None;
}

def contains_control_character(value: str) -> bool {
    for ch in value {
        code = ord(ch);
        if code <= 31 or code == 127 { return True; }
    }
    return False;
}

def bounded_label(value: any) -> any {
    if not isinstance(value, str) { return None; }
    label = value.strip();
    if label and len(label) <= 160 and not contains_control_character(label) { return label; }
    return None;
}

def ordinary_approval_value(value: str) -> bool {
    normalized = value.strip().lower();
    if re.search(r"session|always|permanent|forever|persistent", normalized) { return False; }
    return normalized == "once" or re.match(r"^(?:accept|approve|allow)(?:ed|[-_]?once)?$", normalized) is not None;
}

# RequestPermissionProfile uses null for permission families that were not
# requested; GrantedPermissionProfile requires those keys to be absent.
def granted_permissions(raw: any) -> dict[str, any] {
    if not isinstance(raw, dict) { return {}; }
    out: dict[str, any] = {};
    for (key, value) in raw.items() {
        if value is not None { out[key] = value; }
    }
    return out;
}

def additional_permission_summary(permissions: any, reason: any) -> str {
    exact = js(granted_permissions(permissions));
    prefix = "";
    if isinstance(reason, str) and reason.strip() { prefix = reason.strip() + " — "; }
    return prefix + "Requested permissions: " + exact;
}

# Recognize only schema-backed app-access approvals. Arbitrary MCP forms
# remain user input and are declined; Full access never fabricates them.
def mcp_app_approval_form(params: any) -> any {
    request = plain_record(params);
    if request is None or request.get("mode") != "form" { return None; }
    metadata = plain_record(request.get("_meta"));
    target = plain_record(metadata.get("target")) if metadata is not None else None;
    tool_params = plain_record(metadata.get("tool_params")) if metadata is not None else None;
    message = bounded_label(request.get("message")) or "App access requested";
    candidates: list[any] = [];
    if metadata is not None {
        candidates.extend([metadata.get("app_name"), metadata.get("appName"), metadata.get("app")]);
    } else {
        candidates.extend([None, None, None]);
    }
    if target is not None { candidates.extend([target.get("app"), target.get("name")]); }
    if tool_params is not None { candidates.extend([tool_params.get("app_name"), tool_params.get("app")]); }
    if metadata is not None { candidates.extend([metadata.get("connector_name"), metadata.get("connectorName")]); }
    app_name: any = None;
    for candidate in candidates {
        label = bounded_label(candidate);
        if label { app_name = label; break; }
    }
    if not app_name {
        m = re.match(r"^Allow ChatGPT to use (.+?)\?$", message, re.I);
        if m is not None { app_name = m.group(1).strip(); }
    }
    # The application identity is the second half of the discriminator.
    if not app_name { return None; }
    schema = plain_record(request.get("requestedSchema"));
    properties = plain_record(schema.get("properties")) if schema is not None else None;
    required = schema.get("required") if schema is not None else None;
    if properties is None or not isinstance(required, list) or len(required) == 0 or len(required) > 8 { return None; }
    for key in required {
        if not isinstance(key, str) or len(key) == 0 or len(key) > 100 { return None; }
    }
    content: dict[str, any] = {};
    for key in required {
        field = plain_record(properties.get(key));
        if field is None { return None; }
        enum_values: list[any] = [];
        if isinstance(field.get("enum"), list) {
            enum_values = [v for v in field["enum"] if isinstance(v, str)];
        }
        one_of_values: list[any] = [];
        if isinstance(field.get("oneOf"), list) {
            for option in field["oneOf"] {
                rec = plain_record(option);
                value = bounded_label(rec.get("const")) if rec is not None else None;
                if value { one_of_values.append(value); }
            }
        }
        chosen: any = None;
        for value in one_of_values + enum_values {
            if ordinary_approval_value(value) { chosen = value; break; }
        }
        if chosen is None { return None; }
        content[key] = chosen;
    }
    tool = bounded_label(app_name) or bounded_label(request.get("serverName")) or "app_access";
    return {"tool": tool, "summary": message, "allowResult": {"action": "accept", "content": content}};
}

# Whether the effective config (config/read) shows the shell turned off.
def codex_shell_disabled(config: any) -> bool {
    rec = plain_record(config);
    features = plain_record(rec.get("features")) if rec is not None else None;
    if features is None { return False; }
    return features.get("shell_tool") is False and features.get("unified_exec") is False and features.get("view_image") is False;
}

# Ask and Edits both run Codex's workspace-write sandbox with the person as
# reviewer; Full is never+danger-full-access. Kept explicit on start, resume
# and every turn so a mode switch cannot leave a permissive sandbox stuck.
def named_approval_params(mode: str) -> dict[str, any] {
    if mode == "full" {
        return {
            "thread": {"approvalPolicy": "never", "approvalsReviewer": "user", "sandbox": "danger-full-access"},
            "turn": {"approvalPolicy": "never", "approvalsReviewer": "user", "sandboxPolicy": {"type": "dangerFullAccess"}},
        };
    }
    reviewer = "auto_review" if mode == "auto" else "user";
    return {
        "thread": {"approvalPolicy": "on-request", "approvalsReviewer": reviewer, "sandbox": "workspace-write"},
        "turn": {"approvalPolicy": "on-request", "approvalsReviewer": reviewer, "sandboxPolicy": {"type": "workspaceWrite"}},
    };
}

# Keep the turn on the complete sandbox resolved by native start/resume.
def with_resolved_sandbox(params: dict[str, any], session: any) -> dict[str, any] {
    requested = plain_record(params["turn"].get("sandboxPolicy"));
    # Named permission profiles own their policy; do not mix both selectors.
    if requested is None { return params; }
    rec = plain_record(session);
    sandbox = plain_record(rec.get("sandbox")) if rec is not None else None;
    if sandbox is None or not isinstance(sandbox.get("type"), str) {
        raise RuntimeError("Codex did not return its resolved sandbox policy. Update Codex, then retry; the turn was not started because its permissions could not be verified.");
    }
    if sandbox["type"] != requested.get("type") {
        raise RuntimeError("Codex did not apply the requested sandbox mode; cannot safely start the turn.");
    }
    out = dict(params);
    turn = dict(params["turn"]);
    turn["sandboxPolicy"] = sandbox;
    out["turn"] = turn;
    return out;
}

def effective_approval_policy(value: any) -> any {
    if value == "untrusted" or value == "on-request" or value == "never" { return value; }
    rec = plain_record(value);
    granular = plain_record(rec.get("granular")) if rec is not None else None;
    if granular is not None and isinstance(granular.get("mcp_elicitations"), bool) and isinstance(granular.get("rules"), bool) and isinstance(granular.get("sandbox_approval"), bool) and (granular.get("request_permissions") is None or isinstance(granular.get("request_permissions"), bool)) and (granular.get("skill_approval") is None or isinstance(granular.get("skill_approval"), bool)) {
        out: dict[str, any] = {
            "mcp_elicitations": granular["mcp_elicitations"],
            "rules": granular["rules"],
            "sandbox_approval": granular["sandbox_approval"],
        };
        if isinstance(granular.get("request_permissions"), bool) { out["request_permissions"] = granular["request_permissions"]; }
        if isinstance(granular.get("skill_approval"), bool) { out["skill_approval"] = granular["skill_approval"]; }
        return {"granular": out};
    }
    return "on-request";
}

def effective_approvals_reviewer(value: any) -> str {
    if value == "auto_review" or value == "guardian_subagent" { return value; }
    return "user";
}

def legacy_custom_approval_params(config: dict[str, any]) -> dict[str, any] {
    approval_policy = effective_approval_policy(config.get("approval_policy"));
    approvals_reviewer = effective_approvals_reviewer(config.get("approvals_reviewer"));
    mode = config.get("sandbox_mode");
    sandbox = mode if mode in ["workspace-write", "danger-full-access", "read-only"] else "read-only";
    sandbox_policy: dict[str, any] = {};
    if sandbox == "danger-full-access" {
        sandbox_policy = {"type": "dangerFullAccess"};
    } elif sandbox == "read-only" {
        sandbox_policy = {"type": "readOnly"};
    } else {
        workspace: any = config.get("sandbox_workspace_write") if isinstance(config.get("sandbox_workspace_write"), dict) else {};
        sandbox_policy = {"type": "workspaceWrite"};
        if isinstance(workspace.get("writable_roots"), list) { sandbox_policy["writableRoots"] = workspace["writable_roots"]; }
        if isinstance(workspace.get("network_access"), bool) { sandbox_policy["networkAccess"] = workspace["network_access"]; }
        if isinstance(workspace.get("exclude_slash_tmp"), bool) { sandbox_policy["excludeSlashTmp"] = workspace["exclude_slash_tmp"]; }
        if isinstance(workspace.get("exclude_tmpdir_env_var"), bool) { sandbox_policy["excludeTmpdirEnvVar"] = workspace["exclude_tmpdir_env_var"]; }
    }
    return {
        "thread": {"approvalPolicy": approval_policy, "approvalsReviewer": approvals_reviewer, "sandbox": sandbox},
        "turn": {"approvalPolicy": approval_policy, "approvalsReviewer": approvals_reviewer, "sandboxPolicy": sandbox_policy},
    };
}

def configured_permission_profile(config: dict[str, any]) -> any {
    raw = config.get("default_permissions");
    if not isinstance(raw, str) { return None; }
    profile = raw.strip();
    if not profile or len(profile) > 240 or contains_control_character(profile) { return None; }
    return profile;
}

def custom_approval_params(raw: any) -> dict[str, any] {
    config = raw if isinstance(raw, dict) else {};
    fallback = legacy_custom_approval_params(config);
    permissions = configured_permission_profile(config);
    if not permissions { return fallback; }
    approval_policy = effective_approval_policy(config.get("approval_policy"));
    approvals_reviewer = effective_approvals_reviewer(config.get("approvals_reviewer"));
    # Codex 0.151 profiles define the sandbox, but approval policy remains
    # independent: reassert both so a resumed Full thread cannot keep never.
    return {
        "thread": {"permissions": permissions, "approvalPolicy": approval_policy, "approvalsReviewer": approvals_reviewer},
        "turn": {"permissions": permissions, "approvalPolicy": approval_policy, "approvalsReviewer": approvals_reviewer},
        "fallback": fallback,
    };
}

def permission_profile_unsupported(err: any) -> bool {
    return re.search(
        r"(?:experimental api|invalid params|unknown field|unknown.*permissions|permissions.*(?:unsupported|sandbox)|cannot.*permissions)",
        error_message(err), re.I
    ) is not None;
}

# permission-command.ts: approval identity preserves every command byte.
def permission_command(command: any, cwd: any) -> any {
    if not isinstance(command, str) or not command.strip() or "\x00" in command { return None; }
    if not isinstance(cwd, str) or not os.path.isabs(cwd) or "\x00" in cwd { return None; }
    return {"command": command, "cwd": cwd};
}

def permission_launch_cwd(cwd: str) -> any {
    try {
        if not os.path.exists(cwd) { return None; }
        return os.path.realpath(cwd);
    } except Exception {
        return None;
    }
}

# ── native diagnostic tee (native.ts + codex sanitizers) ───────────────────

# Keep native instructions and private host paths out of diagnostics.
def codex_native_log_message(message: any) -> any {
    if not isinstance(message, dict) { return message; }
    params = message.get("params");
    if not isinstance(params, dict) { return message; }
    method = message.get("method");
    if method == "thread/start" or method == "thread/resume" {
        out = dict(message);
        p = dict(params);
        p["developerInstructions"] = "[developer instructions omitted]";
        out["params"] = p;
        return out;
    }
    if method == "thread/inject_items" {
        out2 = dict(message);
        p2 = dict(params);
        p2["items"] = "[developer instruction update omitted]";
        out2["params"] = p2;
        return out2;
    }
    if method != "turn/start" { return message; }
    items = params.get("input");
    if not isinstance(items, list) { return message; }
    mapped: list[any] = [];
    for item in items {
        if isinstance(item, dict) and item.get("type") == "localImage" {
            row = dict(item);
            row["path"] = "[private attachment path omitted]";
            mapped.append(row);
        } else {
            mapped.append(item);
        }
    }
    out3 = dict(message);
    p3 = dict(params);
    p3["input"] = mapped;
    out3["params"] = p3;
    return out3;
}

# Sensitive request ids outlive the request, so a response arriving after
# its timeout is still omitted rather than becoming a secret-bearing orphan.
def codex_native_incoming_log_message(message: any, sensitive_ids: any) -> any {
    if isinstance(message, dict) and message.get("id") is not None and message.get("id") in sensitive_ids {
        out: dict[str, any] = {"jsonrpc": message.get("jsonrpc"), "id": message.get("id")};
        if "error" in message {
            out["error"] = "[config/read error omitted]";
        } else {
            out["result"] = "[effective config omitted]";
        }
        return out;
    }
    if isinstance(message, dict) and message.get("method") == "item/completed" and isinstance(message.get("params"), dict) and isinstance(message["params"].get("item"), dict) and message["params"]["item"].get("type") == "imageGeneration" {
        item = dict(message["params"]["item"]);
        raw = item.get("result");
        item["result"] = "[generated image omitted · " + str(len(raw if isinstance(raw, str) else ("" if raw is None else str(raw)))) + " base64 chars]";
        item.pop("savedPath", None);
        params = dict(message["params"]);
        params["item"] = item;
        out2 = dict(message);
        out2["params"] = params;
        return out2;
    }
    return message;
}

def append_native(thread_id: str, direction: str, source: str, msg: any) {
    # Never let logging break a run.
    try {
        native_dir = os.path.join(data_dir(), "native");
        os.makedirs(native_dir, exist_ok=True);
        path = os.path.join(native_dir, thread_id + ".ndjson");
        line = js({"at": iso_now(), "dir": direction, "source": source, "msg": redact_secrets(msg)}) + "\n";
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600);
        try {
            os.write(fd, line.encode("utf-8"));
        } finally {
            os.close(fd);
        }
    } except Exception {
    }
}

# ── developer instructions (codex-instructions.ts) ─────────────────────────

glob _FINGERPRINT_RE: any = re.compile(r"^[0-9a-f]{64}$");

def _parse_receipt(raw: any) -> any {
    if not raw { return None; }
    trimmed = raw.strip();
    if _FINGERPRINT_RE.match(trimmed) { return {"instructions": trimmed}; }
    try {
        parsed = json.loads(trimmed);
    } except Exception {
        return None;
    }
    if isinstance(parsed, dict) and isinstance(parsed.get("instructions"), str) and _FINGERPRINT_RE.match(parsed["instructions"]) {
        out: dict[str, any] = {"instructions": parsed["instructions"]};
        if isinstance(parsed.get("volatile"), str) and _FINGERPRINT_RE.match(parsed["volatile"]) {
            out["volatile"] = parsed["volatile"];
        }
        return out;
    }
    return None;
}

def _write_file_atomic(path: str, contents: str) {
    tmp = path + "." + str(os.getpid()) + "." + str(int(time.time() * 1000)) + ".tmp";
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600);
    try {
        os.write(fd, contents.encode("utf-8"));
    } finally {
        os.close(fd);
    }
    os.replace(tmp, path);
}

# Preserve native configured rules when overriding Codex's developer slot.
def codex_developer_instructions(config: any, bot_instructions: str) -> str {
    if not isinstance(config, dict) {
        raise RuntimeError("Codex returned no effective configuration; cannot safely update bot instructions.");
    }
    configured = config.get("developer_instructions");
    if configured is not None and not isinstance(configured, str) {
        raise RuntimeError("Codex returned invalid developer instructions; cannot safely update bot instructions.");
    }
    # Native rules previously outranked the bot's prefix: keep them last.
    if configured {
        lead: str = bot_instructions or "No OpenMausBot bot-specific instructions remain.";
        return lead + "\n\n" + str(configured);
    }
    return bot_instructions;
}

# Returns {deliver_volatile, had_volatile, commit_volatile (callable|None)}.
# request_fn(method, params) performs a blocking JSON-RPC request.
def sync_codex_instructions(
    key: str,
    native_thread_id: str,
    instructions: str,
    volatile: str,
    resumed: bool,
    request_fn: any,
    mention_turn: bool
) -> dict[str, any] {
    directory = os.path.join(data_dir(), "codex-instructions");
    path = os.path.join(directory, sha256_hex(js([key, native_thread_id])) + ".sha256");
    fingerprint = sha256_hex(instructions);
    volatile_fingerprint = sha256_hex(volatile);
    previous: any = None;
    try {
        f = open(path, "r", encoding="utf-8");
        try {
            previous = _parse_receipt(f.read());
        } finally {
            f.close();
        }
    } except FileNotFoundError {
        previous = None;
    }
    prev_instructions = previous.get("instructions") if previous is not None else None;
    prev_volatile = previous.get("volatile") if previous is not None else None;
    if resumed and prev_instructions != fingerprint {
        # thread/resume overrides apply only after compaction; append a
        # developer update ONLY on change, and persist the receipt after the
        # inject is acknowledged. Unknown-method errors must fail.
        try {
            request_fn("thread/inject_items", {
                "threadId": native_thread_id,
                "items": [{
                    "type": "message",
                    "role": "developer",
                    "content": [{
                        "type": "input_text",
                        "text": "The following replaces the previous developer instruction block supplied by OpenMausBot, including its native configured rules and bot-specific instructions. Other Codex instructions and permissions still apply.\n\n" + (instructions or "No OpenMausBot bot-specific instructions remain."),
                    }],
                }],
            });
        } except Exception as e {
            if re.search(r"method not found|unknown method", error_message(e), re.I) {
                raise RuntimeError("This Codex version cannot update bot instructions in a resumed session. Update Codex and retry: " + error_message(e));
            }
            raise e;
        }
    }
    # A mention describes the turn it rides: deliver it on every tagged turn.
    deliver_volatile = (not resumed) or prev_volatile != volatile_fingerprint or mention_turn;
    had_volatile = isinstance(prev_volatile, str) and prev_volatile != sha256_hex("");
    if (not resumed) or prev_instructions != fingerprint {
        os.makedirs(directory, exist_ok=True);
        _write_file_atomic(path, js({"instructions": fingerprint}));
    }
    commit_volatile: any = None;
    if not (prev_instructions == fingerprint and prev_volatile == volatile_fingerprint) {
        def commit() {
            os.makedirs(directory, exist_ok=True);
            _write_file_atomic(path, js({"instructions": fingerprint, "volatile": volatile_fingerprint}));
        }
        commit_volatile = commit;
    }
    return {"deliver_volatile": deliver_volatile, "had_volatile": had_volatile, "commit_volatile": commit_volatile};
}

# prompt-split.ts
glob VOLATILE_CONTEXT_NOTE_PREFIX: str = "Context from OpenMausBot updated since this conversation started; it replaces any earlier copy:";
glob VOLATILE_CONTEXT_CLEARED_NOTE: str = "The OpenMausBot context notes from earlier in this conversation have been cleared; the standing instructions still apply.";

def volatile_context_note(volatile: str, had_volatile: bool) -> str {
    text = volatile.strip();
    if text { return VOLATILE_CONTEXT_NOTE_PREFIX + "\n\n" + text; }
    return VOLATILE_CONTEXT_CLEARED_NOTE if had_volatile else "";
}

def with_context_note(note: str, text: str) -> str {
    if not note { return text; }
    return note + "\n\n" + text if text else note;
}

# ── protocol questions (shared/ask-question.ts) ────────────────────────────

glob MAX_PROTOCOL_QUESTIONS: int = 6;
glob MAX_QUESTION_ID: int = 200;
glob _QA_BLOCK_RE: any = re.compile(r"(?:^|\n\n)Q: ([\s\S]+?)\nA: ([\s\S]*?)(?=\n\nQ: |\Z)");

def _js_trim(value: str) -> str {
    return value.strip(" \t\n\r\x0b\x0c ﻿  ");
}

# Entries carry their own string ids (requestUserInput); a duplicate id fails
# the whole request; nothing answerable parses to None.
def parse_protocol_ask_questions(entries: any) -> any {
    if not isinstance(entries, list) { return None; }
    parsed: list[any] = [];
    seen_ids: dict[str, bool] = {};
    for raw in entries {
        if not isinstance(raw, dict) { continue; }
        question = _parse_one_question(raw);
        id = raw.get("id");
        if question is None or not isinstance(id, str) or not id.strip() or len(id) > MAX_QUESTION_ID { continue; }
        if id in seen_ids { return None; }
        seen_ids[id] = True;
        parsed.append({"id": id, "question": question});
        if len(parsed) == MAX_PROTOCOL_QUESTIONS { break; }
    }
    return parsed if parsed else None;
}

def question_answers_by_id(message: str, questions: list[any]) -> dict[str, any] {
    answers: dict[str, any] = {};
    id_by_text: dict[str, any] = {};
    ambiguous: dict[str, bool] = {};
    for pair in questions {
        text = pair["question"]["question"];
        if text in id_by_text {
            ambiguous[text] = True;
            continue;
        }
        id_by_text[text] = pair["id"];
    }
    saw_block = False;
    for m in _QA_BLOCK_RE.finditer(message) {
        saw_block = True;
        asked = _js_trim(m.group(1));
        if asked in ambiguous { continue; }
        id = id_by_text.get(asked);
        answer = _js_trim(m.group(2));
        if id and answer { answers[id] = answer; }
    }
    if answers { return answers; }
    if saw_block { return {}; }
    flat = _js_trim(message);
    if len(questions) == 1 and flat { return {questions[0]["id"]: flat}; }
    return {};
}
