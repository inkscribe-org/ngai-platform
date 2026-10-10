"""Connected apps (Composio) on Jac - phase 4.

Faithful port of server/composio.ts (Sessions, managed broker, MCP relay,
connection inventory, auth links, marketplace catalog, grant validation,
connector tool inventory), server/connector-verdict.ts (the call-time
grants verdict), the harness half of server/connector-advertisement.ts
(the bridge env serializers) and server/connector-scope-hint.ts.

Node keeps: the stdio MCP bridge process (connector-proxy.ts, spawned by
provider CLIs - a transport, like phase 3's permission-proxy) with its
bridge-side tools/list filter, the relay endpoint's orchestration (turn
authority, audit rows, the outbound gate), and a sync mirror of the
connection mode for call sites that cannot await.

Every TS option/global the module reached for is a hook in `_cx["hooks"]`:

  fetch   -> outbound HTTP (urllib, proxies ignored like node fetch)
  persist -> node bridge op `composio_persist` (cfg.composio ids + saveConfig)
  warn    -> stderr (node relays it as a `[jac]` console line)
  uuid    -> randomUUID

The managed broker credential lives in node (the desktop parent sends it
there); every op carries it as `managed` so a respawned harness never
forgets it. Outbound bases stay env-overridable (OMB_COMPOSIO_API,
OMB_COMPOSIO_TOOLKITS_API, OMB_COMPOSIO_BROKER_URL/TOKEN) and are read per
call, exactly like the TS module; the harness inherits node's env.
"""

import os;
import re;
import sys;
import json;
import math;
import time;
import uuid;
import base64;
import socket;
import hashlib;
import functools;
import threading;
import urllib.request;
import urllib.error;
import urllib.parse;
import concurrent.futures;

import from jsutil { js_stringify, js_number }
import from routines { _bridge }

glob DEFAULT_BACKEND_ORIGIN: str = "https://backend.composio.dev";
glob MAX_AUTH_CONFIG_PAGES: int = 20;
glob MAX_CONNECTED_ACCOUNT_PAGES: int = 100;
glob MAX_TRACKED_TRANSPORT_SESSIONS: int = 512;
glob MAX_RELAY_BYTES: int = 20 * 1024 * 1024;
glob CONNECTOR_TOOLS_CACHE_MS: int = 60000;
glob CONNECTOR_SERVICE_SLUGS_CACHE_MS: int = 60000;
glob CATALOG_CACHE_MS: int = 600000;
glob TOOL_DESCRIPTION_MAX: int = 240;
glob TOOLS_LIST_PAGES_MAX: int = 10;
glob MAX_RELAY_TARGETS: int = 256;
glob RELAY_TARGET_TTL_MS: int = 15 * 60000;

glob MULTI_ACCOUNT_MAX: int = 5;

# shared/wire.ts
glob CONNECTOR_SLUG_PATTERN: str = "[a-z0-9][a-z0-9_-]{0,80}";
glob CONNECTOR_TOOL_NAME_PATTERN: str = "[A-Z][A-Z0-9_]{0,127}";

# connector-advertisement.ts (harness side)
glob CONNECTOR_ALLOWED_TOOLS_ENV: str = "OMB_CONNECTOR_ALLOWED_TOOLS";
glob CONNECTOR_SERVICE_SLUGS_ENV: str = "OMB_CONNECTOR_SERVICE_SLUGS";
glob CONNECTOR_ALLOWED_TOOLS_MAX_BYTES: int = 32 * 1024;
glob CONNECTOR_SERVICE_SLUGS_MAX_BYTES: int = 32 * 1024;

# connector-verdict.ts
glob COMPOSIO_MULTI_EXECUTE_TOOL: str = "COMPOSIO_MULTI_EXECUTE_TOOL";

glob MANAGED_BROKER_TOKEN: str = "[0-9a-f]{64}";
glob ACCOUNT_ID: str = "[A-Za-z0-9][A-Za-z0-9_-]{0,127}";
glob NEEDS_AUTH_CONFIG: str = "does not manage auth|auth[_ ]?config";
glob SCOPE_ERROR: str = "ACCESS_TOKEN_SCOPE_INSUFFICIENT|insufficient authentication scopes|insufficientPermissions";
glob LOOPBACK_HOSTS: list[str] = ["localhost", "127.0.0.1", "[::1]"];
glob MANAGED_CUSTOM_AUTH_TOOLKITS: list[str] = ["twitter", "x"];
glob UNSET: str = "\u0000unset";

# Curated fallback - the services agentcal's connectors page ships plus the
# long marketplace tail. Logos resolve client-side: logo -> favicon(domain)
# -> monogram.
glob CURATED: list[dict[str, any]] = [
    {"slug": "slack", "label": "Slack", "blurb": "Post updates and read channels", "domain": "slack.com", "logo": None},
    {"slug": "github", "label": "GitHub", "blurb": "Issues, pull requests, and code", "domain": "github.com", "logo": None},
    {"slug": "gmail", "label": "Gmail", "blurb": "Read and send email", "domain": "gmail.com", "logo": None},
    {"slug": "googlecalendar", "label": "Google Calendar", "blurb": "Read and create events", "domain": "calendar.google.com", "logo": None},
    {"slug": "googlesheets", "label": "Google Sheets", "blurb": "Read and update spreadsheets", "domain": "sheets.google.com", "logo": None},
    {"slug": "googledocs", "label": "Google Docs", "blurb": "Read and write documents", "domain": "docs.google.com", "logo": None},
    {"slug": "googledrive", "label": "Google Drive", "blurb": "Browse and manage files", "domain": "drive.google.com", "logo": None},
    {"slug": "notion", "label": "Notion", "blurb": "Pages and databases", "domain": "notion.so", "logo": None},
    {"slug": "linear", "label": "Linear", "blurb": "Issues and project tracking", "domain": "linear.app", "logo": None},
    {"slug": "sentry", "label": "Sentry", "blurb": "Errors and alerts", "domain": "sentry.io", "logo": None},
    {"slug": "posthog", "label": "PostHog", "blurb": "Analytics, feature flags, experiments", "domain": "posthog.com", "logo": None},
    {"slug": "discord", "label": "Discord", "blurb": "Messages and channels", "domain": "discord.com", "logo": None},
    {"slug": "twitter", "label": "X (Twitter)", "blurb": "Post and read on X", "domain": "x.com", "logo": None},
    {"slug": "reddit", "label": "Reddit", "blurb": "Browse and post", "domain": "reddit.com", "logo": None},
    {"slug": "zapier", "label": "Zapier", "blurb": "Connect 9,000+ apps", "domain": "zapier.com", "logo": None},
    {"slug": "hubspot", "label": "HubSpot", "blurb": "CRM search & updates", "domain": "hubspot.com", "logo": None},
    {"slug": "salesforce", "label": "Salesforce", "blurb": "CRM records and reports", "domain": "salesforce.com", "logo": None},
    {"slug": "jira", "label": "Jira", "blurb": "Issues and sprints", "domain": "atlassian.com", "logo": None},
    {"slug": "asana", "label": "Asana", "blurb": "Tasks and projects", "domain": "asana.com", "logo": None},
    {"slug": "trello", "label": "Trello", "blurb": "Boards and cards", "domain": "trello.com", "logo": None},
    {"slug": "dropbox", "label": "Dropbox", "blurb": "Files and folders", "domain": "dropbox.com", "logo": None},
    {"slug": "airtable", "label": "Airtable", "blurb": "Bases and records", "domain": "airtable.com", "logo": None},
    {"slug": "figma", "label": "Figma", "blurb": "Files and comments", "domain": "figma.com", "logo": None},
    {"slug": "stripe", "label": "Stripe", "blurb": "Payments and customers", "domain": "stripe.com", "logo": None},
];

glob _cx: dict[str, any] = {};

def _reset {
    _cx.update({
        # undefined (never set) / None (explicitly cleared) / {url, token}
        "managed": UNSET,
        # transport session id -> backend identity, oldest first
        "transport": {},
        # Session ids this boot already tried to upgrade once
        "multi_attempted": set(),
        "auth_attempted": set(),
        "tools_cache": None,
        "tools_inflight": None,
        "slugs_cache": None,
        "slugs_inflight": None,
        "catalog_cache": None,
        # handle -> prepared relay target (the beforeSend seam, see relay_*)
        "relay_targets": {},
        "lock": threading.RLock(),
        "now_ms": None,
        "hooks": _default_hooks(),
    });
}

class ConnectorError(Exception) {
    # Error carrying an HTTP status (JS `Object.assign(new Error, {status})`).
}

def _fail(status: int, message: str) {
    err = ConnectorError(message);
    setattr(err, "status", status);
    raise err;
}

def _error(message: str) {
    raise Exception(message);
}

def _status_of(e: Exception) -> int {
    s = getattr(e, "status", None);
    if isinstance(s, int) and not isinstance(s, bool) { return s; }
    return 500;
}

def _now -> int {
    v = _cx.get("now_ms");
    if v is not None { return int(v); }
    return int(time.time() * 1000);
}

def _hook(name: str) -> any {
    return _cx["hooks"].get(name);
}

# ── JS-faithful string helpers ────────────────────────────────────────────

glob JS_WS: str = "[\t\n\u000b\u000c\r    -     　﻿]";

def _trim(s: str) -> str {
    return re.sub("^" + JS_WS + "+|" + JS_WS + "+$", "", s);
}

def _js_len(s: str) -> int {
    n = 0;
    for c in s {
        n += 2 if ord(c) > 65535 else 1;
    }
    return n;
}

def _fullmatch(pattern: str, s: any, flags: int = 0) -> bool {
    if not isinstance(s, str) { return False; }
    return re.fullmatch(pattern, s, flags) is not None;
}

# String.prototype.localeCompare (ICU root) for the ASCII slugs and tool
# names this module sorts: punctuation < digits < letters, case-insensitive
# first, lowercase before uppercase on a tie.
glob _COLLATION: str = " _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789abcdefghijklmnopqrstuvwxyz";

def _primary(c: str) -> int {
    i = _COLLATION.find(c.lower());
    return i if i >= 0 else 1000 + ord(c);
}

def _locale_cmp(a: str, b: str) -> int {
    pa = [_primary(c) for c in a];
    pb = [_primary(c) for c in b];
    if pa != pb { return -1 if pa < pb else 1; }
    ta = [1 if c.isupper() else 0 for c in a];
    tb = [1 if c.isupper() else 0 for c in b];
    if ta != tb { return -1 if ta < tb else 1; }
    return 0;
}

def _locale_sorted(items: list[any], key: any) -> list[any] {
    def _cmp(x: any, y: any) -> int { return _locale_cmp(key(x), key(y)); }
    return sorted(items, key=functools.cmp_to_key(_cmp));
}

# String(value) for JSON values.
def _js_string_of(v: any) -> str {
    if v is None { return "null"; }
    if isinstance(v, bool) { return "true" if v else "false"; }
    if isinstance(v, (int, float)) { return js_number(v); }
    if isinstance(v, str) { return v; }
    if isinstance(v, list) {
        return ",".join([_join_part(x) for x in v]);
    }
    return "[object Object]";
}

def _nz(v: any, d: any) -> any {
    # `v ?? d`
    if v is None { return d; }
    return v;
}

def _join_part(x: any) -> str {
    if x is None { return ""; }
    return _js_string_of(x);
}

def _of_total(total: any) -> str {
    if total is None { return ""; }
    return " of ~" + js_number(total);
}

def _prop(o: any, key: str) -> any {
    if isinstance(o, dict) { return o.get(key); }
    return None;
}

def _is_obj(v: any) -> bool { return isinstance(v, dict); }

# encodeURIComponent
def _enc(s: str) -> str {
    return urllib.parse.quote(s, safe="!~*'()");
}

# URLSearchParams serialization (application/x-www-form-urlencoded).
def _form_enc(s: str) -> str {
    out: list[str] = [];
    for b in s.encode("utf-8") {
        c = chr(b);
        if (c.isascii() and c.isalnum()) or c in "*-._" {
            out.append(c);
        } elif c == " " {
            out.append("+");
        } else {
            out.append("%" + format(b, "02X"));
        }
    }
    return "".join(out);
}

def _params(pairs: list[any]) -> str {
    return "&".join([_form_enc(p[0]) + "=" + _form_enc(p[1]) for p in pairs]);
}

# ── WHATWG URL (the slice of `new URL` this module relies on) ─────────────

glob SPECIAL_PORTS: dict[str, str] = {"http:": "80", "https:": "443", "ws:": "80", "wss:": "443", "ftp:": "21"};

def _js_url(value: any) -> dict[str, any] {
    if not isinstance(value, str) { raise TypeError("Invalid URL"); }
    raw = re.sub("[\t\n\r]", "", re.sub("^[\u0000- ]+|[\u0000- ]+$", "", value));
    m = re.match("^([A-Za-z][A-Za-z0-9+.-]*):", raw);
    if m is None { raise TypeError("Invalid URL"); }
    protocol = m.group(1).lower() + ":";
    if protocol not in SPECIAL_PORTS and protocol != "file:" {
        return {
            "protocol": protocol, "username": "", "password": "", "hostname": "", "port": "",
            "pathname": raw[len(m.group(0)):], "search": "", "hash": "", "origin": "null", "href": raw,
        };
    }
    try {
        parts = urllib.parse.urlsplit(raw.replace("\\", "/"));
        host = parts.hostname or "";
        port_num = parts.port;
    } except ValueError {
        raise TypeError("Invalid URL");
    }
    if protocol != "file:" and not host { raise TypeError("Invalid URL"); }
    if ":" in host { host = "[" + host + "]"; }
    port = str(_nz(port_num, ""));
    if SPECIAL_PORTS.get(protocol) == port { port = ""; }
    netloc = parts.netloc;
    userinfo = netloc.rpartition("@")[0] if "@" in netloc else "";
    username = userinfo.partition(":")[0];
    password = userinfo.partition(":")[2];
    pathname = parts.path or "/";
    search = ("?" + parts.query) if parts.query else "";
    hash = ("#" + parts.fragment) if parts.fragment else "";
    hostport = host + ((":" + port) if port else "");
    origin = (protocol + "//" + hostport) if protocol != "file:" else "null";
    auth = "";
    if username or password {
        auth = username + ((":" + password) if password else "") + "@";
    }
    return {
        "protocol": protocol, "username": username, "password": password, "hostname": host,
        "port": port, "pathname": pathname, "search": search, "hash": hash, "origin": origin,
        "href": protocol + "//" + auth + hostport + pathname + search + hash,
    };
}

# ── zod-shaped response validation (stripping unknown keys) ───────────────
# Spec forms: "str" "str1" (min 1) "bool" "num" "any" ("enum", [..])
# ("opt", spec) ("null", spec) ("obj", [(key, spec), ...]) ("arr", spec)
# ("rec", spec). Optional means "absent"; JSON null is not undefined.

def _js_type(v: any) -> str {
    if v is None { return "null"; }
    if isinstance(v, bool) { return "boolean"; }
    if isinstance(v, (int, float)) { return "number"; }
    if isinstance(v, str) { return "string"; }
    if isinstance(v, list) { return "array"; }
    return "object";
}

def _zod_fail(path: list[any], message: str) {
    issue = {"path": path, "message": message};
    raise ValueError(json.dumps([issue], indent=2));
}

def _parse(spec: any, v: any, path: list[any]) -> any {
    if isinstance(spec, str) {
        if spec == "any" { return v; }
        if spec == "str" or spec == "str1" {
            if not isinstance(v, str) { _zod_fail(path, "Invalid input: expected string, received " + _js_type(v)); }
            if spec == "str1" and len(v) < 1 { _zod_fail(path, "Too small: expected string to have >=1 characters"); }
            return v;
        }
        if spec == "bool" {
            if not isinstance(v, bool) { _zod_fail(path, "Invalid input: expected boolean, received " + _js_type(v)); }
            return v;
        }
        if spec == "num" {
            if isinstance(v, bool) or not isinstance(v, (int, float)) {
                _zod_fail(path, "Invalid input: expected number, received " + _js_type(v));
            }
            return v;
        }
    }
    kind = spec[0];
    if kind == "null" {
        if v is None { return None; }
        return _parse(spec[1], v, path);
    }
    if kind == "enum" {
        if v not in spec[1] {
            _zod_fail(path, "Invalid option: expected one of " + "|".join([js_stringify(x) for x in spec[1]]));
        }
        return v;
    }
    if kind == "arr" {
        if not isinstance(v, list) { _zod_fail(path, "Invalid input: expected array, received " + _js_type(v)); }
        return [_parse(spec[1], item, path + [i]) for (i, item) in enumerate(v)];
    }
    if kind == "rec" {
        if not isinstance(v, dict) { _zod_fail(path, "Invalid input: expected record, received " + _js_type(v)); }
        rec: dict[str, any] = {};
        for (k, item) in v.items() { rec[k] = _parse(spec[1], item, path + [k]); }
        return rec;
    }
    if kind == "obj" {
        if not isinstance(v, dict) { _zod_fail(path, "Invalid input: expected object, received " + _js_type(v)); }
        out: dict[str, any] = {};
        for field in spec[1] {
            key = field[0];
            fspec = field[1];
            optional = not isinstance(fspec, str) and fspec[0] == "opt";
            if optional {
                if key not in v { continue; }
                out[key] = _parse(fspec[1], v[key], path + [key]);
            } else {
                out[key] = _parse(fspec, v.get(key), path + [key]) if key in v else _parse_missing(fspec, path + [key]);
            }
        }
        return out;
    }
    raise TypeError("bad schema");
}

def _parse_missing(spec: any, path: list[any]) -> any {
    expected = spec if isinstance(spec, str) else spec[0];
    names = {"str": "string", "str1": "string", "bool": "boolean", "num": "number", "arr": "array", "obj": "object", "rec": "record"};
    _zod_fail(path, "Invalid input: expected " + names.get(expected, "value") + ", received undefined");
    return None;
}

def _o(fields: list[any]) -> any { return ("obj", fields); }
def _opt(spec: any) -> any { return ("opt", spec); }
def _nul(spec: any) -> any { return ("null", spec); }

glob SESSION_SCHEMA: any = _o([
    ("session_id", "str1"),
    ("mcp", _o([("type", ("enum", ["http", "sse"])), ("url", "str1")])),
    ("config", _opt(_o([
        ("user_id", _opt("str")),
        ("multi_account", _opt(_o([
            ("enable", _opt("bool")),
            ("max_accounts_per_toolkit", _opt("num")),
            ("require_explicit_selection", _opt("bool")),
        ]))),
        ("auth_configs", _opt(("rec", "str"))),
    ]))),
]);

glob AUTH_CONFIGS_PAGE_SCHEMA: any = _o([
    ("items", _opt(("arr", _o([
        ("id", _opt("str")),
        ("status", _opt(_nul("str"))),
        ("is_composio_managed", _opt("bool")),
        ("is_enabled_for_tool_router", _opt(_nul("bool"))),
        ("last_updated_at", _opt(_nul("str"))),
        ("toolkit", _opt(_o([("slug", _opt("str"))]))),
    ])))),
    ("next_cursor", _opt(_nul("str"))),
]);

glob CONNECTED_ACCOUNTS_PAGE_SCHEMA: any = _o([
    ("items", ("arr", _o([
        ("id", _opt("str")),
        ("alias", _opt(_nul("str"))),
        ("status", _opt("str")),
        ("updated_at", _opt("str")),
        ("toolkit", _opt(_o([("slug", _opt("str"))]))),
    ]))),
    ("next_cursor", _opt(_nul("str"))),
]);

glob TOOLKIT_PAGE_SCHEMA: any = _o([
    ("items", _opt(("arr", _o([
        ("slug", _opt("str")),
        ("is_no_auth", _opt("bool")),
        ("connected_account", _opt(_nul(_o([("id", _opt("str")), ("status", _opt("str"))])))),
    ])))),
    ("next_cursor", _opt(_nul("str"))),
]);

glob CONNECTOR_SERVICES_SCHEMA: any = _o([
    ("services", _opt(("rec", _o([
        ("connected", "bool"),
        ("pending", _opt("bool")),
        ("status", _opt("str")),
        ("accounts", _opt(("arr", _o([("id", "str"), ("alias", _opt("str")), ("status", "str")])))),
    ])))),
]);

glob REMOVAL_SCHEMA: any = _o([("removed", "num")]);
glob AUTH_URL_SCHEMA: any = _o([("url", _opt("str"))]);
glob LINK_SCHEMA: any = _o([("redirect_url", _opt("str"))]);

# ── default hooks (production wiring) ──────────────────────────────────────

glob _OPENER: any = urllib.request.build_opener(urllib.request.ProxyHandler({}));

# fetch(): {status, headers (lowercase keys), body (bytes)}. Bodies past the
# relay cap are cut at cap+1 bytes so the caller's size check still trips.
def _default_fetch(method: str, url: str, headers: dict[str, any], body: any, timeout_ms: int) -> dict[str, any] {
    data: any = body.encode("utf-8") if isinstance(body, str) else body;
    req = urllib.request.Request(url, data=data, headers=headers, method=method);
    resp: any = None;
    try {
        resp = _OPENER.open(req, timeout=timeout_ms / 1000.0);
    } except urllib.error.HTTPError as e {
        resp = e;
    } except (socket.timeout, TimeoutError) {
        raise Exception("The operation was aborted due to timeout");
    } except Exception as e {
        raise Exception("fetch failed: " + str(getattr(e, "reason", e)));
    }
    hdrs: dict[str, any] = {};
    raw: any = b"";
    try {
        for (k, v) in resp.headers.items() { hdrs[k.lower()] = v; }
        raw = resp.read(MAX_RELAY_BYTES + 1);
    } except (socket.timeout, TimeoutError) {
        raise Exception("The operation was aborted due to timeout");
    } finally {
        resp.close();
    }
    status = getattr(resp, "status", None) or getattr(resp, "code", 0);
    return {"status": int(status), "headers": hdrs, "body": raw};
}

def _default_persist(user_id: str, session_id: str) {
    _bridge("composio_persist", {"user_id": user_id, "session_id": session_id});
}

def _default_warn(message: str) {
    print(message, file=sys.stderr, flush=True);
}

def _default_uuid -> str {
    return str(uuid.uuid4());
}

def _default_hooks -> dict[str, any] {
    return {"fetch": _default_fetch, "persist": _default_persist, "warn": _default_warn, "uuid": _default_uuid};
}

def _fetch(method: str, url: str, headers: dict[str, any], body: any, timeout_ms: int) -> dict[str, any] {
    return _hook("fetch")(method, url, headers, body, timeout_ms);
}

def _ok(res: dict[str, any]) -> bool {
    return 200 <= res["status"] and res["status"] <= 299;
}

def _text(res: dict[str, any]) -> str {
    b = res.get("body") or b"";
    return b.decode("utf-8", errors="replace") if isinstance(b, (bytes, bytearray)) else str(b);
}

def _json(res: dict[str, any]) -> any {
    return json.loads(_text(res));
}

def _warn(message: str) {
    _hook("warn")(message);
}

def _uuid -> str {
    return _hook("uuid")();
}

# ── bases and broker access ────────────────────────────────────────────────

def _api_base -> str {
    v = os.environ.get("OMB_COMPOSIO_API");
    if v is None { v = DEFAULT_BACKEND_ORIGIN + "/api/v3.1"; }
    return re.sub("/$", "", v);
}

def _toolkit_base -> str {
    v = os.environ.get("OMB_COMPOSIO_TOOLKITS_API");
    if v is None { v = DEFAULT_BACKEND_ORIGIN + "/api/v3"; }
    return re.sub("/$", "", v);
}

def normalize_managed_broker_url(value: str) -> str {
    url = _js_url(value);
    if url["username"] or url["password"] or url["search"] or url["hash"] {
        _error("The connected-apps service URL must not include credentials, a query, or a fragment");
    }
    loopback = url["hostname"] in LOOPBACK_HOSTS;
    if url["protocol"] != "https:" and not (url["protocol"] == "http:" and loopback) {
        _error("The connected-apps service must use HTTPS");
    }
    return url["origin"] + re.sub("/+$", "", url["pathname"]);
}

def apply_managed_broker_message(message: any) -> bool {
    if not isinstance(message, dict) { return False; }
    if message.get("type") != "openmausbot:managed-composio" or "access" not in message { return False; }
    set_managed_broker_access(message["access"]);
    return True;
}

# z.object({url: z.string().url(), token: z.string().regex(..)}).strict()
def _validate_access(access: any) -> dict[str, any] {
    if not isinstance(access, dict) { _zod_fail([], "Invalid input: expected object, received " + _js_type(access)); }
    extra = [k for k in access.keys() if k not in ["url", "token"]];
    if extra { _zod_fail([], "Unrecognized key: " + js_stringify(extra[0])); }
    url = access.get("url");
    if not isinstance(url, str) { _zod_fail(["url"], "Invalid input: expected string, received " + _js_type(url)); }
    try {
        _js_url(url);
    } except TypeError {
        _zod_fail(["url"], "Invalid URL");
    }
    token = access.get("token");
    if not isinstance(token, str) { _zod_fail(["token"], "Invalid input: expected string, received " + _js_type(token)); }
    if not _fullmatch(MANAGED_BROKER_TOKEN, token) { _zod_fail(["token"], "Invalid string: must match pattern /^[0-9a-f]{64}$/"); }
    return {"url": url, "token": token};
}

def set_managed_broker_access(access: any) {
    if access is None {
        _cx.update({"managed": None});
        return;
    }
    parsed = _validate_access(access);
    _cx.update({"managed": {"url": normalize_managed_broker_url(parsed["url"]), "token": parsed["token"]}});
}

def _env_broker_access -> any {
    url = (os.environ.get("OMB_COMPOSIO_BROKER_URL") or "").strip();
    token = (os.environ.get("OMB_COMPOSIO_BROKER_TOKEN") or "").strip();
    if not url or not token { return None; }
    if not _fullmatch(MANAGED_BROKER_TOKEN, token) { _error("The connected-apps service token is invalid"); }
    return {"url": normalize_managed_broker_url(url), "token": token};
}

def broker_access -> any {
    m = _cx["managed"];
    if not (isinstance(m, str) and m == UNSET) { return m; }
    return _env_broker_access();
}

# A user-owned project is an explicit choice and must win over the packaged
# app's managed broker. An empty key means that choice was cleared.
def project_api_key(cfg: any) -> any {
    composio = _prop(cfg, "composio");
    key = _prop(composio, "apiKey");
    if not isinstance(key, str) { return None; }
    trimmed = _trim(key);
    return trimmed if trimmed else None;
}

# Composio's toolkit slug is `twitter`; keep accepting the old `x` alias.
def canonical_toolkit_slug(slug: str) -> str {
    normalized = _trim(slug).lower();
    return "twitter" if normalized == "x" else normalized;
}

def backend_fingerprint(kind: str, endpoint: str, credential: str) -> str {
    h = hashlib.sha256();
    h.update(kind.encode("utf-8"));
    h.update(b"\x00");
    h.update(endpoint.encode("utf-8"));
    h.update(b"\x00");
    h.update(credential.encode("utf-8"));
    return h.hexdigest();
}

def _remember_transport_session(session_id: str, identity: str) {
    with _cx["lock"] {
        t = _cx["transport"];
        t.pop(session_id, None);
        t[session_id] = identity;
        while len(t) > MAX_TRACKED_TRANSPORT_SESSIONS {
            t.pop(next(iter(t)));
        }
    }
}

def _canonical_service_record(services: dict[str, any]) -> dict[str, any] {
    out: dict[str, any] = {};
    for (slug, state) in services.items() { out[canonical_toolkit_slug(slug)] = state; }
    return out;
}

def _requested_service_record(services: dict[str, any], requested: list[str]) -> dict[str, any] {
    canonical = _canonical_service_record(services);
    out: dict[str, any] = {};
    for slug in requested {
        state = canonical.get(canonical_toolkit_slug(slug));
        if state is not None { out[slug] = state; }
    }
    return out;
}

def connection_mode(cfg: any) -> str {
    if project_api_key(cfg) { return "self-hosted"; }
    if broker_access() { return "managed"; }
    return "unavailable";
}

def configured(cfg: any) -> bool {
    return connection_mode(cfg) != "unavailable";
}

def connector_availability(cfg: any, store_state: any) -> str {
    if configured(cfg) { return "configured"; }
    return "unreadable" if store_state == "unavailable" else "unconfigured";
}

def connector_setup(cfg: any, desktop_managed: bool) -> str {
    if configured(cfg) { return "ready"; }
    return "service-unavailable" if desktop_managed else "needs-setup";
}

# shared/connector-availability.ts
def managed_connector_unavailable_reason(mode: str, slug: str) -> any {
    if mode != "managed" or _trim(slug).lower() not in MANAGED_CUSTOM_AUTH_TOOLKITS { return None; }
    return "Twitter/X needs your own X Developer app and Composio auth config. Use self-hosted connected apps for now.";
}

def _broker_request(path: str, method: str = "GET", body: any = None, timeout_ms: int = 30000) -> dict[str, any] {
    broker = broker_access();
    if not broker { _error("The connected-apps service is unavailable"); }
    headers: dict[str, any] = {"authorization": "Bearer " + broker["token"]};
    if body { headers["content-type"] = "application/json"; }
    return _fetch(method, broker["url"] + path, headers, body, timeout_ms);
}

def _project_headers(api_key: str, as_json: bool = False) -> dict[str, any] {
    headers: dict[str, any] = {"x-api-key": api_key};
    if as_json { headers["content-type"] = "application/json"; }
    return headers;
}

def _response_error(res: dict[str, any], fallback: str) -> str {
    raw = _text(res);
    body: any = None;
    try {
        body = json.loads(raw);
    } except Exception {
        return _trim(raw)[:300] or fallback;
    }
    value: any = _prop(body, "message");
    if value is None {
        err = _prop(body, "error");
        value = _prop(err, "message");
        if value is None { value = err; }
    }
    if value is None { value = fallback; }
    return _js_string_of(value);
}

def _throw_broker_error(res: dict[str, any], fallback: str) {
    s = res["status"];
    status = s if (s >= 400 and s < 500) else 502;
    _fail(status, _response_error(res, fallback));
}

def _trusted_auth_url(value: any, slug: str) -> str {
    if not value { _error("Connected-apps service returned no authorization link for " + slug); }
    url = _js_url(value);
    host = url["hostname"];
    if url["protocol"] != "https:" or (host != "composio.dev" and not host.endswith(".composio.dev")) {
        _error("Connected-apps service returned an untrusted authorization link");
    }
    return url["href"];
}

# Composio's own hosts are always trusted. A backend the operator pointed the
# app at explicitly (OMB_COMPOSIO_API - a dev or test stub) may hand back a
# Session on its own origin; any other host is refused.
def trusted_session_mcp_url(value: str) -> bool {
    mcp: any = None;
    try {
        mcp = _js_url(value);
    } except TypeError {
        return False;
    }
    host = mcp["hostname"];
    if mcp["protocol"] == "https:" and (host == "composio.dev" or host.endswith(".composio.dev")) { return True; }
    if mcp["protocol"] != "https:" and not (mcp["protocol"] == "http:" and host in LOOPBACK_HOSTS) { return False; }
    override_api = os.environ.get("OMB_COMPOSIO_API");
    if not override_api { return False; }
    try {
        return _js_url(override_api)["origin"] == mcp["origin"];
    } except TypeError {
        return False;
    }
}

def _parse_session_response(session: dict[str, any]) -> dict[str, any] {
    mcp = _js_url(session["mcp"]["url"]);
    if not trusted_session_mcp_url(session["mcp"]["url"]) {
        _error("Composio returned an untrusted Session MCP URL");
    }
    out = dict(session);
    m = dict(session["mcp"]);
    m["url"] = mcp["href"];
    out["mcp"] = m;
    return out;
}

def _session_config(session: any) -> dict[str, any] {
    c = _prop(session, "config");
    return c if isinstance(c, dict) else {};
}

# Only `enable` gates reuse: the cap and selection flags are what we ASK for.
def _supports_multi_account(session: dict[str, any]) -> bool {
    return _prop(_session_config(session).get("multi_account"), "enable") is True;
}

def _printable_alias(value: str) -> bool {
    n = _js_len(value);
    if n < 1 or n > 64 { return False; }
    for c in value {
        cp = ord(c);
        if cp < 32 or cp == 127 { return False; }
    }
    return True;
}

def normalize_account_alias(value: any) -> any {
    if value is None or (isinstance(value, str) and value == "") { return None; }
    if not isinstance(value, str) { _fail(400, "Account alias must be text"); }
    alias = _trim(value);
    if not _printable_alias(alias) { _fail(400, "Account alias must be 1-64 printable characters"); }
    return alias;
}

def _valid_account_id(value: any) -> bool {
    return isinstance(value, str) and len(value) > 0 and _fullmatch(ACCOUNT_ID, value);
}

# ── project Sessions ───────────────────────────────────────────────────────

def _get_project_session(api_key: str, session_id: str) -> any {
    res = _fetch("GET", _api_base() + "/tool_router/session/" + _enc(session_id), _project_headers(api_key), None, 15000);
    if res["status"] == 404 { return None; }
    if not _ok(res) { _error(_response_error(res, "Composio session: HTTP " + str(res["status"]))); }
    return _parse_session_response(_parse(SESSION_SCHEMA, _json(res), []));
}

# The project's own (non-Composio-managed) auth configs, one per toolkit.
# Disabled configs and ones switched off for Sessions are skipped; when a
# toolkit has several, the most recently updated wins.
def list_custom_auth_configs(api_key: str) -> dict[str, any] {
    chosen: dict[str, any] = {};
    cursor: any = None;
    for page in range(MAX_AUTH_CONFIG_PAGES) {
        pairs: list[any] = [("is_composio_managed", "false"), ("limit", "100")];
        if cursor { pairs.append(("cursor", cursor)); }
        res = _fetch("GET", _api_base() + "/auth_configs?" + _params(pairs), _project_headers(api_key), None, 15000);
        if not _ok(res) { _error(_response_error(res, "Composio auth configs: HTTP " + str(res["status"]))); }
        body = _parse(AUTH_CONFIGS_PAGE_SCHEMA, _json(res), []);
        for item in (body.get("items") or []) {
            tk_slug = _prop(item.get("toolkit"), "slug");
            slug = canonical_toolkit_slug(tk_slug) if tk_slug else "";
            if not slug or not item.get("id") or item.get("is_composio_managed") is True { continue; }
            if item.get("is_enabled_for_tool_router") is False { continue; }
            status = item.get("status");
            if status and _fullmatch("disabled|inactive|expired|deleted", status, re.I) { continue; }
            updated = item.get("last_updated_at");
            if updated is None { updated = ""; }
            current = chosen.get(slug);
            if current is None or updated > current["updated"] {
                chosen[slug] = {"id": item["id"], "updated": updated};
            }
        }
        nxt = body.get("next_cursor");
        if not nxt or nxt == cursor { break; }
        cursor = nxt;
    }
    out: dict[str, any] = {};
    for slug in _locale_sorted(list(chosen.keys()), str) { out[slug] = chosen[slug]["id"]; }
    return out;
}

def _session_covers_auth_configs(session: dict[str, any], wanted: dict[str, any]) -> bool {
    have = _session_config(session).get("auth_configs") or {};
    have_lower: dict[str, any] = {};
    for (slug, id) in have.items() { have_lower[canonical_toolkit_slug(slug)] = id; }
    for (slug, id) in wanted.items() {
        if have_lower.get(slug) != id { return False; }
    }
    return True;
}

def _auth_configs_key(session_id: str, wanted: dict[str, any]) -> str {
    return session_id + ":" + js_stringify(wanted);
}

def _multi_account_config -> dict[str, any] {
    return {"enable": True, "max_accounts_per_toolkit": MULTI_ACCOUNT_MAX, "require_explicit_selection": True};
}

# Validate a project key and return one reusable Session for this install.
def prepare_project_session(api_key: str, current: any = None, known_auth_configs: any = None) -> dict[str, any] {
    trimmed = _trim(api_key);
    if not trimmed { _error("Enter a Composio project API key"); }
    if not trimmed.startswith("ak_") { _error("Composio project API keys start with ak_"); }
    cur: dict[str, any] = current if isinstance(current, dict) else {};

    # The project's own auth configs must be named at creation - a Session
    # cannot be edited later - so they are read first (issue #509).
    auth_configs: any = known_auth_configs;
    if auth_configs is None {
        try {
            auth_configs = list_custom_auth_configs(trimmed);
        } except Exception {
            auth_configs = {};
        }
    }
    prior_user_id: any = cur.get("userId");
    if trimmed == cur.get("apiKey") and cur.get("sessionId") {
        existing = _get_project_session(trimmed, cur["sessionId"]);
        if existing is not None and _supports_multi_account(existing) and (
            _session_covers_auth_configs(existing, auth_configs)
            or _auth_configs_key(existing["session_id"], auth_configs) in _cx["auth_attempted"]
        ) {
            uid: any = _session_config(existing).get("user_id");
            if uid is None { uid = cur.get("userId"); }
            if uid is None { uid = "openmausbot_" + _uuid(); }
            return {"apiKey": trimmed, "userId": uid, "sessionId": existing["session_id"]};
        }
        # Connections belong to the Composio user, not the Session: recreate
        # old single-account Sessions with the same user ID.
        if existing is not None and _session_config(existing).get("user_id") is not None {
            prior_user_id = _session_config(existing)["user_id"];
        }
    }

    user_id: any = prior_user_id;
    if user_id is None { user_id = "openmausbot_" + _uuid(); }
    request: dict[str, any] = {
        "user_id": user_id,
        "manage_connections": {"enable": True, "enable_wait_for_connections": True, "enable_connection_removal": True},
        "multi_account": _multi_account_config(),
    };
    if len(auth_configs) > 0 { request["auth_configs"] = auth_configs; }
    res = _fetch("POST", _api_base() + "/tool_router/session", _project_headers(trimmed, True), js_stringify(request), 30000);
    if not _ok(res) { _error(_response_error(res, "Composio rejected this key (HTTP " + str(res["status"]) + ")")); }
    session = _parse_session_response(_parse(SESSION_SCHEMA, _json(res), []));
    # If Composio does not echo the configs back, remember this attempt so the
    # creation happens once.
    _cx["auth_attempted"].add(_auth_configs_key(session["session_id"], auth_configs));
    return {"apiKey": trimmed, "userId": user_id, "sessionId": session["session_id"]};
}

def _composio_of(cfg: any) -> any {
    c = _prop(cfg, "composio");
    return c if isinstance(c, dict) else None;
}

def _adopt_session_ids(cfg: any, prepared: dict[str, any]) {
    _cx["multi_attempted"].add(prepared["sessionId"]);
    composio = _composio_of(cfg);
    composio["userId"] = prepared["userId"];
    composio["sessionId"] = prepared["sessionId"];
    _hook("persist")(prepared["userId"], prepared["sessionId"]);
}

def _ensure_project_session(cfg: any) -> dict[str, any] {
    composio = _composio_of(cfg);
    api_key = project_api_key(cfg);
    if composio is None or not api_key { _error("No Composio project key configured"); }
    if composio.get("sessionId") {
        existing = _get_project_session(api_key, composio["sessionId"]);
        if existing is not None and (_supports_multi_account(existing) or existing["session_id"] in _cx["multi_attempted"]) {
            return existing;
        }
    }
    # A missing/deleted session is recreated and its non-secret identifiers
    # are persisted so an edited config does not recreate it every launch.
    prepared = prepare_project_session(api_key, composio);
    _adopt_session_ids(cfg, prepared);
    created = _get_project_session(api_key, prepared["sessionId"]);
    if created is None { _error("Composio Session disappeared after creation"); }
    return created;
}

# Replace the current Session with a freshly created one - the only way to
# pick up an auth config added after the Session was made. The Composio user
# id is kept, so every existing connection survives.
def _recreate_project_session(cfg: any, user_id: str, auth_configs: dict[str, any]) -> dict[str, any] {
    composio = _composio_of(cfg);
    api_key = project_api_key(cfg);
    if composio is None or not api_key { _error("No Composio project key configured"); }
    prepared = prepare_project_session(api_key, {"apiKey": api_key, "userId": user_id}, auth_configs);
    _adopt_session_ids(cfg, prepared);
    created = _get_project_session(api_key, prepared["sessionId"]);
    if created is None { _error("Composio Session disappeared after creation"); }
    return created;
}

def _session_user_id(session: dict[str, any], cfg: any) -> any {
    uid = _session_config(session).get("user_id");
    if uid is None { uid = _prop(_composio_of(cfg), "userId"); }
    return uid;
}

# ── bridge env (connector-advertisement.ts, harness side) ──────────────────

def serialize_connector_allowed_tools(grants: dict[str, any]) -> dict[str, any] {
    env = js_stringify(grants);
    if len(env.encode("utf-8")) > CONNECTOR_ALLOWED_TOOLS_MAX_BYTES { return {"oversized": True}; }
    return {"env": env, "oversized": False};
}

def serialize_connector_service_slugs(slugs: list[any]) -> dict[str, any] {
    unique: list[str] = [];
    for slug in slugs {
        if _fullmatch(CONNECTOR_SLUG_PATTERN, slug) and slug not in unique { unique.append(slug); }
    }
    if not unique { return {"oversized": False}; }
    env = js_stringify(unique);
    if len(env.encode("utf-8")) > CONNECTOR_SERVICE_SLUGS_MAX_BYTES { return {"oversized": True}; }
    return {"env": env, "oversized": False};
}

# context: {harnessUrl, commsToken, botId, threadId, connectorTools?}; an
# absent (or null) connectorTools is the legacy all-tools bot.
def mcp_integration(cfg: any, context: dict[str, any], command: str, args: list[any]) -> any {
    if not configured(cfg) { return None; }
    tools = context.get("connectorTools");
    allowlist: any = None;
    if tools is not None { allowlist = serialize_connector_allowed_tools(tools); }
    if allowlist is not None and allowlist["oversized"] {
        _warn(
            "[composio] connector allowlist for bot " + str(context.get("botId")) + " exceeds "
            + str(CONNECTOR_ALLOWED_TOOLS_MAX_BYTES) + " bytes;"
            + " tools/list stays unfiltered and grants are enforced per call"
        );
    }
    service_slugs: any = None;
    if tools is not None { service_slugs = serialize_connector_service_slugs(connected_service_slugs(cfg)); }
    if service_slugs is not None and service_slugs["oversized"] {
        _warn(
            "[composio] connector service slugs for bot " + str(context.get("botId")) + " exceed "
            + str(CONNECTOR_SERVICE_SLUGS_MAX_BYTES) + " bytes;"
            + " tools/list falls back to plain-prefix resolution"
        );
    }
    harness = context["harnessUrl"];
    token = context["commsToken"];
    env: dict[str, any] = {
        "ELECTRON_RUN_AS_NODE": "1",
        # The provider-facing bridge receives only this boot's loopback token;
        # project/broker credentials stay harness-side.
        "OMB_CONNECTOR_UPSTREAM_URL": harness + "/api/internal/connectors/mcp",
        "OMB_CONNECTOR_UPSTREAM_HEADERS": js_stringify({"authorization": "Bearer " + token}),
        "OMB_HARNESS_URL": harness,
        "OMB_CONNECTOR_TOKEN": token,
        "OMB_BOT_ID": context["botId"],
        "OMB_THREAD_ID": context["threadId"],
    };
    if allowlist is not None and allowlist.get("env") { env[CONNECTOR_ALLOWED_TOOLS_ENV] = allowlist["env"]; }
    if service_slugs is not None and service_slugs.get("env") { env[CONNECTOR_SERVICE_SLUGS_ENV] = service_slugs["env"]; }
    return {"command": command, "args": args, "env": env};
}

# ── MCP relay ─────────────────────────────────────────────────────────────
# relayMcp(cfg, payload, transportSessionId, beforeSend) is split at the
# beforeSend seam: prepare (Session discovery, may await the network), then
# the caller's checks, then dispatch. Node runs beforeSend between the two
# ops; in-module callers (the tool inventory) use relay_mcp directly.

def relay_prepare(cfg: any, transport_session_id: any) -> dict[str, any] {
    api_key = project_api_key(cfg);
    headers: dict[str, any] = {"content-type": "application/json", "accept": "application/json, text/event-stream"};
    url = "";
    identity = "";
    if api_key {
        session = _ensure_project_session(cfg);
        url = session["mcp"]["url"];
        headers["x-api-key"] = api_key;
        identity = backend_fingerprint("project-mcp", url, api_key);
    } else {
        broker = broker_access();
        if not broker { _error("Connected apps are unavailable"); }
        url = broker["url"] + "/v1/mcp";
        headers["authorization"] = "Bearer " + broker["token"];
        identity = backend_fingerprint("managed-mcp", url, broker["token"]);
    }
    known: any = None;
    if transport_session_id {
        with _cx["lock"] { known = _cx["transport"].get(transport_session_id); }
    }
    forwarded: any = transport_session_id if (transport_session_id and known == identity) else None;
    if forwarded { headers["mcp-session-id"] = forwarded; }
    return {"url": url, "headers": headers, "identity": identity, "forwarded": forwarded};
}

def relay_dispatch(target: dict[str, any], payload: any) -> dict[str, any] {
    response = _fetch("POST", target["url"], target["headers"], js_stringify(payload), 10 * 60000);
    rh = response["headers"];
    declared = _js_to_number(rh.get("content-length") if "content-length" in rh else "0", True);
    if declared > MAX_RELAY_BYTES { _error("Connected-app response exceeded 20 MB"); }
    body = response.get("body") or b"";
    if len(body) > MAX_RELAY_BYTES { _error("Connected-app response exceeded 20 MB"); }
    if target["forwarded"] { _remember_transport_session(target["forwarded"], target["identity"]); }
    nxt = rh.get("mcp-session-id");
    if nxt { _remember_transport_session(nxt, target["identity"]); }
    ctype = rh.get("content-type");
    return {
        "status": response["status"],
        "bytes": body,
        "content_type": _nz(ctype, "application/json"),
        "transport_session_id": nxt,
    };
}

def relay_mcp(cfg: any, payload: any, transport_session_id: any = None, before_send: any = None) -> dict[str, any] {
    target = relay_prepare(cfg, transport_session_id);
    # Session discovery can await network I/O; turn authority and mutable
    # permissions are checked after it, immediately before dispatch.
    if before_send is not None { before_send(); }
    return relay_dispatch(target, payload);
}

def _stash_relay_target(target: dict[str, any]) -> str {
    handle = str(uuid.uuid4());
    with _cx["lock"] {
        targets = _cx["relay_targets"];
        cutoff = _now() - RELAY_TARGET_TTL_MS;
        for key in list(targets.keys()) {
            if targets[key]["at"] < cutoff { targets.pop(key); }
        }
        while len(targets) >= MAX_RELAY_TARGETS { targets.pop(next(iter(targets))); }
        targets[handle] = {"at": _now(), "target": target};
    }
    return handle;
}

def _take_relay_target(handle: str) -> dict[str, any] {
    stashed: any = None;
    with _cx["lock"] { stashed = _cx["relay_targets"].pop(handle, None); }
    if stashed is None { _fail(409, "The connected-app relay target expired; retry the call"); }
    return stashed["target"];
}

# Number(x) for header/JSON values; `present` false is `undefined` (NaN).
def _js_to_number(v: any, present: bool) -> float {
    if not present { return float("nan"); }
    if v is None { return 0.0; }
    if isinstance(v, bool) { return 1.0 if v else 0.0; }
    if isinstance(v, (int, float)) { return float(v); }
    if isinstance(v, str) {
        s = _trim(v);
        if s == "" { return 0.0; }
        if re.fullmatch("[+-]?(Infinity|(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?)", s) {
            return float(s.replace("Infinity", "inf"));
        }
        if re.fullmatch("0[xX][0-9a-fA-F]+", s) { return float(int(s, 16)); }
        if re.fullmatch("0[oO][0-7]+", s) { return float(int(s[2:], 8)); }
        if re.fullmatch("0[bB][01]+", s) { return float(int(s[2:], 2)); }
        return float("nan");
    }
    if isinstance(v, list) {
        if len(v) == 0 { return 0.0; }
        if len(v) == 1 { return _js_to_number(_join_part(v[0]), True); }
    }
    return float("nan");
}

def _finite(n: float) -> bool {
    return not math.isnan(n) and not math.isinf(n);
}

# ── connection inventory ───────────────────────────────────────────────────

def _list_connected_accounts(api_key: str, user_id: str, slugs: list[str]) -> list[any] {
    accounts: list[any] = [];
    seen: set[str] = set();
    cursor: any = None;
    # Five accounts per toolkit can exceed one provider page; follow the cursor.
    for page in range(MAX_CONNECTED_ACCOUNT_PAGES) {
        pairs: list[any] = [("limit", "50"), ("user_ids", user_id), ("order_by", "updated_at"), ("order_direction", "desc")];
        if slugs { pairs.append(("toolkit_slugs", ",".join(slugs))); }
        if cursor { pairs.append(("cursor", cursor)); }
        res = _fetch("GET", _api_base() + "/connected_accounts?" + _params(pairs), _project_headers(api_key), None, 15000);
        if not _ok(res) { _error(_response_error(res, "Composio accounts: HTTP " + str(res["status"]))); }
        body = _parse(CONNECTED_ACCOUNTS_PAGE_SCHEMA, _json(res), []);
        accounts.extend(body["items"]);
        nxt = body.get("next_cursor") or None;
        if not nxt or nxt in seen { return accounts; }
        seen.add(nxt);
        cursor = nxt;
    }
    _error("Composio account inventory exceeded the pagination safety limit");
    return accounts;
}

def _list_session_toolkits(api_key: str, session_id: str) -> list[any] {
    toolkits: list[any] = [];
    seen: set[str] = set();
    cursor: any = None;
    for page in range(MAX_CONNECTED_ACCOUNT_PAGES) {
        # The unfiltered endpoint is the whole marketplace; only the user's
        # connected toolkits matter here.
        pairs: list[any] = [("limit", "50"), ("is_connected", "true")];
        if cursor { pairs.append(("cursor", cursor)); }
        res = _fetch(
            "GET", _api_base() + "/tool_router/session/" + _enc(session_id) + "/toolkits?" + _params(pairs),
            _project_headers(api_key), None, 15000
        );
        if not _ok(res) { _error(_response_error(res, "Composio toolkits: HTTP " + str(res["status"]))); }
        body = _parse(TOOLKIT_PAGE_SCHEMA, _json(res), []);
        toolkits.extend(body.get("items") or []);
        nxt = body.get("next_cursor") or None;
        if not nxt or nxt in seen { return toolkits; }
        seen.add(nxt);
        cursor = nxt;
    }
    _error("Composio toolkit inventory exceeded the pagination safety limit");
    return toolkits;
}

def _list_connected_accounts_or_empty(api_key: str, user_id: str, slugs: list[str]) -> list[any] {
    try {
        return _list_connected_accounts(api_key, user_id, slugs);
    } except Exception {
        return [];
    }
}

def _summarize_accounts(accounts: list[any], slugs: list[str]) -> dict[str, any] {
    requested = set([canonical_toolkit_slug(s) for s in slugs]);
    by_slug: dict[str, any] = {};
    for account in accounts {
        tk_slug = _prop(account.get("toolkit"), "slug");
        slug = canonical_toolkit_slug(tk_slug) if tk_slug else "";
        if not slug or (len(requested) > 0 and slug not in requested) or not _valid_account_id(account.get("id")) { continue; }
        raw_alias = account.get("alias");
        alias = _trim(raw_alias) if isinstance(raw_alias, str) else "";
        updated = account.get("updated_at");
        summary: dict[str, any] = {
            "id": account["id"],
            "status": account.get("status") or "UNKNOWN",
            "updatedAt": _nz(updated, ""),
        };
        if _printable_alias(alias) { summary["alias"] = alias; }
        if slug not in by_slug { by_slug[slug] = []; }
        by_slug[slug].append(summary);
    }
    for slug in list(by_slug.keys()) {
        def _desc(x: any, y: any) -> int { return _locale_cmp(y["updatedAt"], x["updatedAt"]); }
        by_slug[slug] = sorted(by_slug[slug], key=functools.cmp_to_key(_desc));
    }
    return by_slug;
}

def _public_account(account: dict[str, any]) -> dict[str, any] {
    out: dict[str, any] = {"id": account["id"], "status": account["status"]};
    if account.get("alias") { out["alias"] = account["alias"]; }
    return out;
}

glob ACTIVE_RE: str = "active";
glob PENDING_RE: str = "initiated|initializing|pending";

def _service_state_from_accounts(accounts: list[any]) -> dict[str, any] {
    active: any = None;
    pending: any = None;
    for a in accounts {
        if active is None and _fullmatch(ACTIVE_RE, a["status"], re.I) { active = a; }
        if pending is None and _fullmatch(PENDING_RE, a["status"], re.I) { pending = a; }
    }
    selected: any = active;
    if selected is None { selected = pending; }
    if selected is None and len(accounts) > 0 { selected = accounts[0]; }
    status: any = _prop(selected, "status");
    return {
        "connected": active is not None,
        "pending": pending is not None,
        "status": _nz(status, "not_connected"),
        "accounts": [_public_account(a) for a in accounts],
    };
}

def _selected_account(item: any) -> dict[str, any] {
    # (selected, selectedId) for a toolkit row's connected_account
    selected = _prop(item, "connected_account");
    sid = _prop(selected, "id");
    return {"selected": selected, "id": sid if _valid_account_id(sid) else None};
}

def _all_service_states(accounts_by_slug: dict[str, any], toolkits: list[any]) -> dict[str, any] {
    services: dict[str, any] = {};
    for (slug, accounts) in accounts_by_slug.items() { services[slug] = _service_state_from_accounts(accounts); }
    for toolkit in toolkits {
        tk = toolkit.get("slug");
        slug = canonical_toolkit_slug(tk) if tk else "";
        sel = _selected_account(toolkit);
        selected = sel["selected"];
        selected_id = sel["id"];
        no_auth = toolkit.get("is_no_auth");
        if not slug or (not no_auth and not selected_id) { continue; }
        accounts = list(accounts_by_slug.get(slug) or []);
        if selected_id and not any([a["id"] == selected_id for a in accounts]) {
            st = _prop(selected, "status");
            accounts.append({"id": selected_id, "status": _nz(st, "ACTIVE")});
        }
        account_state = _service_state_from_accounts(accounts);
        status: any = "ACTIVE";
        if not no_auth {
            status = _prop(selected, "status");
            if status is None { status = account_state["status"]; }
        }
        services[slug] = {
            "connected": no_auth is True or account_state["connected"] or _fullmatch(ACTIVE_RE, status, re.I),
            "pending": account_state["pending"] or _fullmatch(PENDING_RE, status, re.I),
            "status": status,
            "accounts": account_state["accounts"],
        };
    }
    return services;
}

# Enumerate the user's complete connected-account inventory without
# depending on marketplace ordering or catalog pagination.
def connected_services(cfg: any) -> dict[str, any] {
    api_key = project_api_key(cfg);
    if not api_key {
        res = _broker_request("/v1/connectors/connected");
        if not _ok(res) { _throw_broker_error(res, "Connected apps: HTTP " + str(res["status"])); }
        body = _parse(CONNECTOR_SERVICES_SCHEMA, _json(res), []);
        services = _canonical_service_record(body.get("services") or {});
        out: dict[str, any] = {};
        for (slug, state) in services.items() {
            pending = state.get("pending");
            status = state.get("status");
            if status is None { status = "ACTIVE" if state["connected"] else "not_connected"; }
            accounts = state.get("accounts");
            out[slug] = {
                "connected": state["connected"],
                "pending": _nz(pending, False),
                "status": status,
                "accounts": _nz(accounts, []),
            };
        }
        return out;
    }
    session = _ensure_project_session(cfg);
    user_id = _session_user_id(session, cfg);
    if not user_id { _error("Composio Session returned no user ID"); }
    toolkits = _list_session_toolkits(api_key, session["session_id"]);
    # Scoped project keys can grant Session reads without the raw
    # connected-account list; the Session still proves which toolkits belong
    # to this installation.
    accounts = _list_connected_accounts_or_empty(api_key, user_id, []);
    return _all_service_states(_summarize_accounts(accounts, []), toolkits);
}

def _connected_services_or_none(cfg: any) -> any {
    try {
        return connected_services(cfg);
    } except Exception {
        return None;
    }
}

# Semantic validation for a connectorTools patch (issue #1737). Returns the
# rejection message or None; only the connection-dependent and catalog
# checks fail open.
def validate_connector_grants(cfg: any, grants: dict[str, any]) -> any {
    connected = _connected_services_or_none(cfg);
    candidates: list[str] = list(_nz(connected, {}).keys());
    for (slug, grant) in grants.items() {
        tools = _prop(grant, "tools");
        if tools == "*" { continue; }
        misplaced: list[str] = [];
        for tool in (tools if isinstance(tools, list) else []) {
            owner = service_slug_for_candidates(tool, candidates);
            if owner is None { owner = service_slug_for(tool); }
            if owner != slug { misplaced.append(tool); }
        }
        if misplaced {
            return "connectorTools." + slug + ".tools names tools that belong to another service: " + ", ".join(misplaced);
        }
    }
    if connected is None { return None; }
    unconnected = [slug for slug in grants.keys() if not _prop(connected.get(slug), "connected")];
    if unconnected {
        return "connectorTools names services that are not connected: " + ", ".join(unconnected);
    }
    catalog = list_toolkits(cfg);
    # "curated" means the marketplace was unreachable; a walk that never
    # reached its natural end served only part of it.
    pagination = catalog.get("pagination");
    if catalog["source"] != "api" or not _prop(pagination, "complete") { return None; }
    known = set([card["slug"].lower() for card in catalog["cards"]]);
    unknown = [slug for slug in grants.keys() if slug not in known];
    if unknown {
        return "connectorTools names services missing from the connected-apps catalog: " + ", ".join(unknown);
    }
    return None;
}

# ── connector tool inventory (the grant editor) ────────────────────────────

# Which backend an inventory walk belongs to, mirroring the relay's own
# credential fingerprint.
def _connector_tools_identity(cfg: any) -> str {
    api_key = project_api_key(cfg);
    if api_key { return backend_fingerprint("project-tools", _api_base(), api_key); }
    broker = broker_access();
    if broker { return backend_fingerprint("managed-tools", broker["url"], broker["token"]); }
    return "none";
}

# Shared walk: a fresh cache hit returns at once; a walk already running for
# the same backend is joined; otherwise this caller runs it. `force` skips
# the settled cache but still joins a running walk.
def _shared_walk(cache_key: str, inflight_key: str, identity: str, max_age: int, force: bool, walk: any) -> any {
    owner = False;
    fut: any = None;
    with _cx["lock"] {
        cache = _cx[cache_key];
        if not force and cache is not None and cache["identity"] == identity and _now() - cache["at"] < max_age {
            return cache["value"];
        }
        running = _cx[inflight_key];
        if running is not None and running["identity"] == identity {
            fut = running["future"];
        } else {
            fut = concurrent.futures.Future();
            _cx[inflight_key] = {"identity": identity, "future": fut};
            owner = True;
        }
    }
    if not owner { return fut.result(); }
    try {
        value = walk();
        fut.set_result(value);
        return value;
    } except Exception as e {
        fut.set_exception(e);
        raise e;
    } finally {
        with _cx["lock"] {
            running = _cx[inflight_key];
            if running is not None and running["future"] is fut { _cx[inflight_key] = None; }
        }
    }
}

def list_connector_tools(cfg: any, force: bool = False) -> dict[str, any] {
    identity = _connector_tools_identity(cfg);
    def _walk -> dict[str, any] {
        services = _collect_connector_tools(cfg);
        with _cx["lock"] {
            _cx["tools_cache"] = {"at": _now(), "identity": identity, "value": services};
        }
        return services;
    }
    return _shared_walk("tools_cache", "tools_inflight", identity, CONNECTOR_TOOLS_CACHE_MS, force, _walk);
}

# The service slugs grant enforcement resolves tool-name prefixes against.
# Cached 60s per backend; an unreachable inventory reads as [] without
# caching the failure.
def connected_service_slugs(cfg: any) -> list[str] {
    identity = _connector_tools_identity(cfg);
    def _walk -> list[str] {
        services = _connected_services_or_none(cfg);
        if services is None { return []; }
        slugs = list(services.keys());
        with _cx["lock"] {
            _cx["slugs_cache"] = {"at": _now(), "identity": identity, "value": slugs};
        }
        return slugs;
    }
    return _shared_walk("slugs_cache", "slugs_inflight", identity, CONNECTOR_SERVICE_SLUGS_CACHE_MS, False, _walk);
}

def _connector_tool_listing(tool: any) -> any {
    if not isinstance(tool, dict) { return None; }
    name: any = tool.get("name");
    if not _fullmatch(CONNECTOR_TOOL_NAME_PATTERN, name) { return None; }
    if name.startswith("COMPOSIO_") { return None; }
    if name.endswith("_MANAGE_CONNECTIONS") or name.endswith("_WAIT_FOR_CONNECTIONS") { return None; }
    description = tool.get("description");
    trimmed = _trim(re.sub("\\s+", " ", description))[:TOOL_DESCRIPTION_MAX] if isinstance(description, str) else "";
    if trimmed { return {"name": name, "description": trimmed}; }
    return {"name": name};
}

# One JSON-RPC response frame from a JSON or SSE body: SSE data lines are
# tried in order and the frame carrying the request id wins.
def parse_mcp_response(text: str, id: any) -> any {
    trimmed = _trim(text);
    if not trimmed { return None; }
    if trimmed.startswith("{") {
        parsed = json.loads(trimmed);
        return parsed if isinstance(parsed, dict) else None;
    }
    frames: list[any] = [];
    for line in re.split("\r?\n", trimmed) {
        if not line.startswith("data:") { continue; }
        data = _trim(line[5:]);
        if not data or data == "[DONE]" { continue; }
        try {
            frame = json.loads(data);
            if isinstance(frame, dict) { frames.append(frame); }
        } except Exception {
            continue;
        }
    }
    for frame in reversed(frames) {
        if "id" in frame and _same_id(frame["id"], id) { return frame; }
    }
    return frames[-1] if frames else None;
}

def _same_id(a: any, b: any) -> bool {
    if isinstance(a, bool) or isinstance(b, bool) { return a is b; }
    return type(a) == type(b) and a == b;
}

def _response_error_from_bytes(status: int, body: any) -> str {
    try {
        parsed = json.loads(body.decode("utf-8", errors="replace"));
        message = _prop(parsed, "error");
        if isinstance(message, dict) {
            text = message.get("message");
            if isinstance(text, str) and text { return text; }
        }
        if isinstance(message, str) and message { return message; }
    } except Exception {
        # fall through to the generic status line
        message = None;
    }
    return "Composio tools/list: HTTP " + str(status);
}

def _collect_connector_tools(cfg: any) -> dict[str, any] {
    # Connected services are the real slugs, so they resolve underscored
    # services (bland_ai) the plain split would file under "bland".
    connected = _connected_services_or_none(cfg);
    candidates: list[str] = list(_nz(connected, {}).keys());
    initialize = relay_mcp(cfg, {
        "jsonrpc": "2.0",
        "id": "omb-grants-initialize",
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "openmausbot-grant-editor", "version": "1"},
        },
    });
    if initialize["status"] != 200 { _error(_response_error_from_bytes(initialize["status"], initialize["bytes"])); }
    transport_session_id = initialize["transport_session_id"];
    # Streamable-HTTP servers expect the handshake notification first; it
    # carries no response, so failures are not fatal.
    notified: any = None;
    try {
        notified = relay_mcp(cfg, {"jsonrpc": "2.0", "method": "notifications/initialized"}, transport_session_id);
    } except Exception {
        notified = None;
    }
    grouped: dict[str, any] = {};
    cursor: any = None;
    for page in range(TOOLS_LIST_PAGES_MAX) {
        params: dict[str, any] = {"cursor": cursor} if cursor else {};
        listed = relay_mcp(cfg, {"jsonrpc": "2.0", "id": "omb-grants-tools", "method": "tools/list", "params": params}, transport_session_id);
        if listed["status"] != 200 { _error(_response_error_from_bytes(listed["status"], listed["bytes"])); }
        frame = parse_mcp_response(listed["bytes"].decode("utf-8", errors="replace"), "omb-grants-tools");
        err = frame.get("error") if isinstance(frame, dict) else None;
        error = err.get("message") if isinstance(err, dict) else None;
        if isinstance(error, str) and error { _error(error); }
        result: any = frame.get("result") if isinstance(frame, dict) else None;
        tools: any = result.get("tools") if isinstance(result, dict) else None;
        if result is None or not isinstance(tools, list) {
            _error("Composio returned a tools/list response without a tools array");
        }
        for tool in tools {
            listing = _connector_tool_listing(tool);
            if listing is None { continue; }
            slug = service_slug_for_candidates(listing["name"], candidates);
            if slug is None { slug = service_slug_for(listing["name"]); }
            if not slug { continue; }
            if slug not in grouped { grouped[slug] = []; }
            if not any([existing["name"] == listing["name"] for existing in grouped[slug]]) {
                grouped[slug].append(listing);
            }
        }
        nc = result.get("nextCursor");
        cursor = nc if (isinstance(nc, str) and nc) else None;
        if not cursor { break; }
    }
    out: dict[str, any] = {};
    for slug in _locale_sorted(list(grouped.keys()), str) {
        def _name(x: any) -> str { return x["name"]; }
        out[slug] = _locale_sorted(grouped[slug], _name);
    }
    return out;
}

# ── status, disconnect, authorize ──────────────────────────────────────────

def connection_status(cfg: any, slugs: list[str]) -> dict[str, any] {
    canonical_slugs: list[str] = [];
    for s in slugs {
        c = canonical_toolkit_slug(s);
        if c not in canonical_slugs { canonical_slugs.append(c); }
    }
    api_key = project_api_key(cfg);
    if not api_key {
        res = _broker_request("/v1/connectors?" + _params([("services", ",".join(canonical_slugs))]));
        if not _ok(res) { _throw_broker_error(res, "Connected apps: HTTP " + str(res["status"])); }
        body = _parse(CONNECTOR_SERVICES_SCHEMA, _json(res), []);
        return _requested_service_record(body.get("services") or {}, slugs);
    }
    session = _ensure_project_session(cfg);
    pairs: list[any] = [("limit", "50")];
    if canonical_slugs { pairs.append(("toolkits", ",".join(canonical_slugs))); }
    user_id = _session_user_id(session, cfg);
    res = _fetch(
        "GET", _api_base() + "/tool_router/session/" + _enc(session["session_id"]) + "/toolkits?" + _params(pairs),
        _project_headers(api_key), None, 15000
    );
    # Session toolkits only include an account once it is usable; read the
    # account lifecycle too so the UI can tell a waiting OAuth flow from an
    # expired one. Scoped keys may omit that permission: additive only.
    accounts: list[any] = _list_connected_accounts_or_empty(api_key, user_id, canonical_slugs) if user_id else [];
    if not _ok(res) { _error(_response_error(res, "Composio toolkits: HTTP " + str(res["status"]))); }
    body = _parse(TOOLKIT_PAGE_SCHEMA, _json(res), []);
    by_slug: dict[str, any] = {};
    for item in (body.get("items") or []) {
        if item.get("slug") { by_slug[canonical_toolkit_slug(item["slug"])] = item; }
    }
    accounts_by_slug = _summarize_accounts(accounts, canonical_slugs);
    out: dict[str, any] = {};
    for slug in slugs {
        canonical_slug = canonical_toolkit_slug(slug);
        item = by_slug.get(canonical_slug);
        service_accounts = accounts_by_slug.get(canonical_slug) or [];
        # Mirror _all_service_states: synthesize the Session-selected account
        # so a status poll never wipes the row the inventory renders.
        sel = _selected_account(item);
        selected = sel["selected"];
        selected_id = sel["id"];
        with_selected = service_accounts;
        if selected_id and not any([a["id"] == selected_id for a in service_accounts]) {
            st = _prop(selected, "status");
            with_selected = service_accounts + [{"id": selected_id, "status": _nz(st, "ACTIVE")}];
        }
        account_state = _service_state_from_accounts(with_selected);
        state: any = _prop(_prop(item, "connected_account"), "status");
        if state is None { state = "ACTIVE" if _prop(item, "is_no_auth") else account_state["status"]; }
        out[slug] = {
            "connected": _prop(item, "is_no_auth") is True or account_state["connected"] or _fullmatch(ACTIVE_RE, state, re.I),
            "pending": account_state["pending"] or _fullmatch(PENDING_RE, state, re.I),
            "status": state,
            "accounts": account_state["accounts"],
        };
    }
    return out;
}

def _removal(res: dict[str, any]) -> dict[str, any] {
    return _parse(REMOVAL_SCHEMA, _json(res), []);
}

# Backward-compatible service disconnect: removes the Session-selected account.
def remove_service(cfg: any, slug: str) -> dict[str, any] {
    toolkit = canonical_toolkit_slug(slug);
    api_key = project_api_key(cfg);
    if not api_key {
        res = _broker_request("/v1/connectors/" + _enc(toolkit), "DELETE");
        if not _ok(res) { _throw_broker_error(res, "Connected apps: HTTP " + str(res["status"])); }
        return _removal(res);
    }
    session = _ensure_project_session(cfg);
    listed = _fetch(
        "GET", _api_base() + "/tool_router/session/" + _enc(session["session_id"]) + "/toolkits?"
        + _params([("limit", "50"), ("toolkits", toolkit)]),
        _project_headers(api_key), None, 15000
    );
    if not _ok(listed) { _error(_response_error(listed, "Composio toolkits: HTTP " + str(listed["status"]))); }
    body = _parse(TOOLKIT_PAGE_SCHEMA, _json(listed), []);
    id: any = None;
    for item in (body.get("items") or []) {
        if item.get("slug") and canonical_toolkit_slug(item["slug"]) == toolkit {
            id = _prop(item.get("connected_account"), "id");
            break;
        }
    }
    if not id { return {"removed": 0}; }
    removed = _fetch(
        "DELETE", _api_base() + "/connected_accounts/" + _enc(id) + "?revoke_on_delete=true",
        _project_headers(api_key), None, 30000
    );
    if not _ok(removed) { _error(_response_error(removed, "Composio disconnect: HTTP " + str(removed["status"]))); }
    return {"removed": 1};
}

def _account_on(account: dict[str, any], toolkit: str) -> bool {
    tk = account.get("toolkit");
    return isinstance(tk, dict) and "slug" in tk and canonical_toolkit_slug(tk["slug"]) == toolkit;
}

# Disconnect exactly one account after proving it belongs to this user/toolkit.
def remove_account(cfg: any, slug: str, account_id: any) -> dict[str, any] {
    if not _valid_account_id(account_id) { _fail(400, "Invalid connected-account ID"); }
    toolkit = canonical_toolkit_slug(slug);
    api_key = project_api_key(cfg);
    if not api_key {
        res = _broker_request("/v1/connectors/" + _enc(toolkit) + "/accounts/" + _enc(account_id), "DELETE");
        if not _ok(res) { _throw_broker_error(res, "Connected apps: HTTP " + str(res["status"])); }
        return _removal(res);
    }
    session = _ensure_project_session(cfg);
    user_id = _session_user_id(session, cfg);
    if not user_id { _error("Composio Session has no user ID"); }
    accounts = _list_connected_accounts(api_key, user_id, [toolkit]);
    owned = any([a.get("id") == account_id and _account_on(a, toolkit) for a in accounts]);
    if not owned { return {"removed": 0}; }
    removed = _fetch(
        "DELETE", _api_base() + "/connected_accounts/" + _enc(account_id) + "?revoke_on_delete=true",
        _project_headers(api_key), None, 30000
    );
    if not _ok(removed) { _error(_response_error(removed, "Composio disconnect: HTTP " + str(removed["status"]))); }
    return {"removed": 1};
}

# Mint a browser auth link for one service. Returns {url} or raises.
def authorize_service(cfg: any, slug: str, requested_alias: any = None) -> dict[str, any] {
    alias: any = normalize_account_alias(requested_alias);
    toolkit = canonical_toolkit_slug(slug);
    unavailable = managed_connector_unavailable_reason(connection_mode(cfg), toolkit);
    if unavailable { _fail(409, unavailable); }
    api_key = project_api_key(cfg);
    if not api_key {
        body_text: any = js_stringify({"alias": alias}) if alias else None;
        res = _broker_request("/v1/connectors/" + _enc(toolkit) + "/authorize", "POST", body_text);
        if not _ok(res) { _throw_broker_error(res, "Connected apps: HTTP " + str(res["status"])); }
        body = _parse(AUTH_URL_SCHEMA, _json(res), []);
        return {"url": _trusted_auth_url(body.get("url"), toolkit)};
    }
    session = _ensure_project_session(cfg);
    user_id = _session_user_id(session, cfg);
    if not user_id { _error("Composio Session has no user ID"); }
    # A scoped key may be denied account listing - authorization must still
    # work, so the alias guardrails degrade to first-account behavior.
    accounts = _list_connected_accounts_or_empty(api_key, user_id, [toolkit]);
    service_accounts = [a for a in accounts if _account_on(a, toolkit)];
    usable = [a for a in service_accounts if _fullmatch("active|initiated|initializing|pending", a.get("status") or "", re.I)];
    if len(usable) >= MULTI_ACCOUNT_MAX {
        _fail(409, toolkit + " already has the maximum of " + str(MULTI_ACCOUNT_MAX) + " accounts");
    }
    if len(service_accounts) > 0 and not alias {
        if all([_fullmatch("initializing|initiated|expired", a.get("status") or "", re.I) for a in service_accounts]) {
            # Retry without replacing a named account or revoking a former
            # grant: EXPIRED can be an abandoned flow or an expired credential.
            alias = "omb-retry-" + _uuid();
        } else {
            _fail(400, "Add an account alias so the existing connection is not replaced");
        }
    }
    if alias {
        for a in service_accounts {
            existing = a.get("alias");
            if isinstance(existing, str) and _trim(existing).lower() == alias.lower() {
                _fail(409, "Account alias \"" + alias + "\" is already in use for " + toolkit);
            }
        }
    }
    link_request: dict[str, any] = {"toolkit": toolkit};
    if alias { link_request["alias"] = alias; }
    def _link(session_id: str) -> dict[str, any] {
        return _fetch(
            "POST", _api_base() + "/tool_router/session/" + _enc(session_id) + "/link",
            _project_headers(api_key, True), js_stringify(link_request), 30000
        );
    }
    res = _link(session["session_id"]);
    if not _ok(res) {
        message = _response_error(res, "Composio authorization: HTTP " + str(res["status"]));
        if re.search(NEEDS_AUTH_CONFIG, message, re.I) is None { _error(message); }
        # The toolkit needs one of the project's own auth configs, which a
        # Session names only at creation: rebuild it once and retry, or say
        # what to create instead of echoing Composio's override hint.
        auth_configs = list_custom_auth_configs(api_key);
        covered = any([canonical_toolkit_slug(key) == toolkit for key in auth_configs.keys()]);
        if not covered {
            _fail(400,
                toolkit + " has no Composio-managed sign-in. In your Composio project, create an auth config for \"" + toolkit + "\" "
                + "(Auth Configs → Create) with your own app credentials, then click Connect again."
            );
        }
        fresh = _recreate_project_session(cfg, user_id, auth_configs);
        res = _link(fresh["session_id"]);
        if not _ok(res) { _error(_response_error(res, "Composio authorization: HTTP " + str(res["status"]))); }
    }
    body = _parse(LINK_SCHEMA, _json(res), []);
    return {"url": _trusted_auth_url(body.get("redirect_url"), toolkit)};
}

# ── marketplace catalog ────────────────────────────────────────────────────

def _catalog_page(cursor: any, backend_key: any) -> dict[str, any] {
    if backend_key {
        pairs: list[any] = [("limit", "500"), ("sort_by", "usage")];
        if cursor { pairs.append(("cursor", cursor)); }
        return _fetch("GET", _toolkit_base() + "/toolkits?" + _params(pairs), {"x-api-key": backend_key}, None, 15000);
    }
    path = ("/v1/catalog?cursor=" + _enc(cursor)) if cursor else "/v1/catalog";
    return _broker_request(path, "GET", None, 15000);
}

def _card_from(t: any) -> dict[str, any] {
    if not isinstance(t, dict) { raise TypeError("catalog item is not an object"); }
    raw_slug: any = t.get("slug");
    if raw_slug is None { raw_slug = t.get("key"); }
    if raw_slug is None { raw_slug = t.get("name"); }
    if raw_slug is None { raw_slug = ""; }
    label: any = t.get("name");
    if label is None { label = t.get("slug"); }
    if label is None { label = ""; }
    meta = t.get("meta");
    blurb: any = _prop(meta, "description");
    if blurb is None { blurb = t.get("description"); }
    if blurb is None { blurb = ""; }
    if not isinstance(blurb, str) { raise TypeError("blurb.slice is not a function"); }
    logo: any = _prop(meta, "logo");
    if logo is None { logo = t.get("logo"); }
    return {
        "slug": canonical_toolkit_slug(_js_string_of(raw_slug)),
        "label": label,
        "blurb": blurb[:90],
        "logo": logo,
        "noAuth": t.get("no_auth") is True,
        "domain": None,
    };
}

# Marketplace catalog: the v3 toolkits API (cached 10 min per backend), or
# the curated list when it cannot be read.
def list_toolkits(cfg: any) -> dict[str, any] {
    backend_key = project_api_key(cfg);
    broker: any = None if backend_key else broker_access();
    identity: any = None;
    if backend_key {
        identity = backend_fingerprint("project-catalog", _toolkit_base(), backend_key);
    } elif broker {
        identity = backend_fingerprint("managed-catalog", broker["url"], broker["token"]);
    }
    cache = _cx["catalog_cache"];
    if identity and cache is not None and cache["identity"] == identity and _now() - cache["at"] < CATALOG_CACHE_MS {
        return {"cards": cache["cards"], "source": "api", "pagination": cache["pagination"]};
    }
    if backend_key or broker {
        walked: any = None;
        try {
            walked = _walk_catalog(identity, backend_key);
        } except Exception {
            # fall through to curated
            walked = None;
        }
        if walked is not None { return walked; }
    }
    return {"cards": CURATED, "source": "curated"};
}

def _walk_catalog(identity: any, backend_key: any) -> any {
    # The marketplace runs well past a thousand toolkits and is cursor-
    # paginated; keep pages already collected if a later one fails.
    items: list[any] = [];
    seen: set[str] = set();
    cursor: any = None;
    last_page: any = None;
    total_items: any = None;
    total_pages: any = None;
    stop = "limit";
    for page in range(MAX_CONNECTED_ACCOUNT_PAGES) {
        res = _catalog_page(cursor, backend_key);
        if not _ok(res) {
            stop = "http-error";
            break;
        }
        body = _json(res);
        if body is None { raise TypeError("Cannot read properties of null (reading 'items')"); }
        page_items: any = [];
        if isinstance(body, dict) {
            page_items = body.get("items");
            if page_items is None { page_items = body.get("data"); }
            if page_items is None { page_items = []; }
        }
        if not isinstance(page_items, list) {
            stop = "bad-page";
            break;
        }
        items.extend(page_items);
        rec: dict[str, any] = body if isinstance(body, dict) else {};
        page_total_items = _js_to_number(rec.get("total_items"), "total_items" in rec);
        if _finite(page_total_items) and page_total_items > 0 { total_items = page_total_items; }
        # Trust page movement: once current_page stops advancing, the
        # catalog is stuck (a broker replaying pages behind fresh cursors).
        reported_page = _js_to_number(rec.get("current_page"), "current_page" in rec);
        if _finite(reported_page) {
            if last_page is not None and reported_page <= last_page {
                stop = "page-stuck";
                break;
            }
            last_page = reported_page;
        }
        page_total_pages = _js_to_number(rec.get("total_pages"), "total_pages" in rec);
        if _finite(page_total_pages) and page_total_pages > 0 { total_pages = page_total_pages; }
        if last_page is not None and _finite(page_total_pages) and page_total_pages > 0 and last_page >= page_total_pages {
            stop = "total-reached";
            break;
        }
        raw_next = rec.get("next_cursor");
        nxt = _trim(raw_next) if isinstance(raw_next, str) else "";
        if not nxt {
            stop = "end";
            break;
        }
        if nxt in seen {
            stop = "cursor-repeated";
            break;
        }
        seen.add(nxt);
        cursor = nxt;
    }
    if not items { raise Exception("empty catalog"); }
    cards = [_card_from(t) for t in items];
    unique: list[any] = [];
    seen_slugs: set[str] = set();
    for card in cards {
        if card["slug"] and card["slug"] not in seen_slugs {
            seen_slugs.add(card["slug"]);
            unique.append(card);
        }
    }
    short_of_total = total_items is not None and len(unique) < total_items;
    # Trust reported page counts even when the walk ends "cleanly".
    stopped_early = last_page is not None and total_pages is not None and last_page < total_pages;
    stalled = short_of_total or stopped_early;
    complete = (stop == "end" or stop == "total-reached") and not stalled;
    pagination: dict[str, any] = {"items": len(unique), "stalled": stalled, "complete": complete};
    if total_items is not None { pagination["totalItems"] = _num_out(total_items); }
    if stalled {
        pagination["reason"] = stop;
        _warn(
            "[composio] marketplace catalog paging stopped early (" + stop + ") after " + str(len(unique)) + " toolkits"
            + _of_total(total_items)
            + "; serving a partial marketplace"
        );
    }
    with _cx["lock"] {
        _cx["catalog_cache"] = {"at": _now(), "cards": unique, "identity": identity, "pagination": pagination};
    }
    return {"cards": unique, "source": "api", "pagination": pagination};
}

def _num_out(n: float) -> any {
    return int(n) if float(n).is_integer() else n;
}

def toolkit_card(cfg: any, slug: str) -> dict[str, any] {
    normalized = canonical_toolkit_slug(slug);
    cards = list_toolkits(cfg)["cards"];
    for card in cards {
        if card["slug"].lower() == normalized { return card; }
    }
    for card in CURATED {
        if card["slug"] == normalized { return card; }
    }
    def _upper(m: any) -> str { return m.group(0).upper(); }
    label = re.sub("\\b\\w", _upper, re.sub("[-_]+", " ", normalized), flags=re.ASCII);
    return {"slug": normalized, "label": label, "blurb": "Connect this app so your bot can continue", "logo": None, "domain": None};
}

def curated_slugs -> list[str] {
    return [c["slug"] for c in CURATED];
}

# ── the grants verdict (connector-verdict.ts) ──────────────────────────────

# GMAIL_SEND_EMAIL -> gmail; a name with no underscore names no service.
def service_slug_for(tool: str) -> any {
    underscore = tool.find("_");
    if underscore <= 0 { return None; }
    return tool[:underscore].lower();
}

# The longest known slug whose upper-snake form prefixes the name (bland_ai
# over bland); None leaves the caller's plain-split fallback.
def service_slug_for_candidates(tool: str, candidates: list[any]) -> any {
    best: any = None;
    for candidate in candidates {
        if tool.startswith(candidate.upper() + "_") and (best is None or len(candidate) > len(best)) {
            best = candidate;
        }
    }
    return best;
}

# Classify one relayed JSON-RPC frame: passthrough / tools / unrecognized.
def connector_call_from_frame(payload: any) -> dict[str, any] {
    if not isinstance(payload, dict) { return {"kind": "passthrough"}; }
    if payload.get("method") != "tools/call" { return {"kind": "passthrough"}; }
    params = payload.get("params");
    if not isinstance(params, dict) {
        return {"kind": "unrecognized", "invoked": "tools/call", "reason": "the call carried no params object"};
    }
    name = params.get("name");
    if not isinstance(name, str) or not name {
        return {"kind": "unrecognized", "invoked": "tools/call", "reason": "the call named no tool"};
    }
    if name == COMPOSIO_MULTI_EXECUTE_TOOL { return _multi_execute_call(name, params.get("arguments")); }
    # Platform meta-tools are not connected-app tools.
    if name.startswith("COMPOSIO_") { return {"kind": "passthrough"}; }
    # Per-service connection cards keep their card flow in any spelling.
    if name.endswith("_MANAGE_CONNECTIONS") or name.endswith("_WAIT_FOR_CONNECTIONS") { return {"kind": "passthrough"}; }
    if not _fullmatch(CONNECTOR_TOOL_NAME_PATTERN, name) {
        return {"kind": "unrecognized", "invoked": name, "reason": "the tool name is not a Composio tool name"};
    }
    return {"kind": "tools", "invoked": name, "names": [name]};
}

def _multi_execute_call(invoked: str, args: any) -> dict[str, any] {
    if not isinstance(args, dict) {
        return {"kind": "unrecognized", "invoked": invoked, "reason": "the arguments were not an object"};
    }
    tools = args.get("tools");
    single = args.get("tool_slug");
    if isinstance(tools, list) {
        if len(tools) == 0 { return {"kind": "unrecognized", "invoked": invoked, "reason": "the tools list was empty"}; }
        names: list[str] = [];
        for item in tools {
            slug = item.get("tool_slug") if isinstance(item, dict) else None;
            if not isinstance(slug, str) or not slug {
                return {"kind": "unrecognized", "invoked": invoked, "reason": "an entry in the tools list named no tool_slug"};
            }
            names.append(slug);
        }
        return {"kind": "tools", "invoked": invoked, "names": names};
    }
    if isinstance(single, str) and single { return {"kind": "tools", "invoked": invoked, "names": [single]}; }
    return {"kind": "unrecognized", "invoked": invoked, "reason": "the arguments named no tools to execute"};
}

# Judge distinct target names against a bot's grants. `legacy` is the bot
# with no grants record (passes everything); an explicit record - including
# the empty one - allows only what it names.
def evaluate_connector_tools(names: list[any], grants: any, legacy: bool, candidates: list[any]) -> dict[str, any] {
    if legacy { return {"allowed": True, "legacy": True, "denials": [], "rule": "composio"}; }
    record: dict[str, any] = grants if isinstance(grants, dict) else {};
    denials: list[any] = [];
    rule = "";
    seen: list[str] = [];
    for tool in names {
        if tool in seen { continue; }
        seen.append(tool);
        service = service_slug_for_candidates(tool, candidates);
        if service is None { service = service_slug_for(tool); }
        grant: any = record.get(service) if (service is not None and service in record) else None;
        tools = _prop(grant, "tools");
        if grant is not None and (tools == "*" or (isinstance(tools, list) and tool in tools)) {
            if not rule { rule = "connectorTools." + service; }
            continue;
        }
        denials.append({"tool": tool, "service": service, "onGrantedService": grant is not None});
    }
    return {"allowed": len(denials) == 0, "legacy": False, "denials": denials, "rule": rule};
}

# Safe to hand to the model: names the refused tool and who can change it,
# never what the bot could have called instead.
def connector_refusal_text(denials: list[any]) -> str {
    named = ", ".join(["\"" + d["tool"] + "\"" for d in denials]);
    one = len(denials) == 1;
    return " ".join([
        named + " " + ("is" if one else "are") + " not granted to this bot.",
        "This call was not performed.",
        "Ask the person to grant " + ("it" if one else "these tools") + " in OpenMausBot if they want " + ("it" if one else "them") + " run.",
    ]);
}

def connector_unrecognized_text(invoked: str, reason: str) -> str {
    return " ".join([
        "A " + invoked + " call arrived in a shape OpenMausBot could not read (" + reason + "), so it was not performed.",
        "Send a well-formed call that names the tools to execute.",
        "Ask the person to grant any tool this bot needs.",
    ]);
}

# ── missing-OAuth-scope note (connector-scope-hint.ts, MOCA-273) ───────────

def _required_scope(slug: str) -> any {
    if not slug.startswith("GMAIL_") { return None; }
    if re.search("FORWARD|SEND_AS|DELEGATE", slug) { return "https://www.googleapis.com/auth/gmail.settings.sharing"; }
    if re.search("FILTER|VACATION|AUTO_REPLY|IMAP|POP|LANGUAGE", slug) { return "https://www.googleapis.com/auth/gmail.settings.basic"; }
    return None;
}

def _app_name(slug: str) -> str {
    toolkit = slug.split("_")[0];
    if toolkit == "GMAIL" { return "Gmail"; }
    if toolkit.startswith("GOOGLE") { return "Google"; }
    return toolkit[:1] + toolkit[1:].lower();
}

def scope_hint(slugs: list[any]) -> str {
    slug = "";
    for candidate in slugs {
        if _required_scope(candidate) {
            slug = candidate;
            break;
        }
    }
    if not slug and len(slugs) > 0 { slug = slugs[0]; }
    app = _app_name(slug) if slug else "This app";
    scope = _required_scope(slug) if slug else None;
    permission = ("the " + scope + " permission") if scope else "the permission this action needs";
    return (
        "OpenMausBot note: " + app + " refused this because the connected account has not granted " + permission + ". "
        + "Reconnecting will not add it: the default Composio connection never asks for it. "
        + "To allow it, the person creates their own " + app + " auth config in their Composio project that includes " + permission + ", "
        + "then reconnects " + app + " under Connected apps; OpenMausBot uses that config automatically. "
        + "Tell the person this. Do not retry this call."
    );
}

def _annotate_frame(frame: any, slugs: list[any]) -> bool {
    result = _prop(frame, "result");
    if not isinstance(result, dict) or not isinstance(result.get("content"), list) { return False; }
    refused = False;
    for item in result["content"] {
        text = _prop(item, "text");
        if isinstance(text, str) and re.search(SCOPE_ERROR, text, re.I) { refused = True; }
    }
    if not refused { return False; }
    result["content"].append({"type": "text", "text": scope_hint(slugs)});
    return True;
}

# The relayed MCP response, with the note added when a tool call came back
# refused for a missing OAuth permission; anything else byte for byte.
def with_scope_hint(body: bytes, content_type: str, slugs: list[any]) -> bytes {
    text = body.decode("utf-8", errors="replace");
    if re.search(SCOPE_ERROR, text, re.I) is None { return body; }
    try {
        if re.search("text/event-stream", content_type, re.I) {
            changed = False;
            lines: list[str] = [];
            for line in text.split("\n") {
                if not line.startswith("data:") {
                    lines.append(line);
                    continue;
                }
                frame = json.loads(line[5:]);
                if not _annotate_frame(frame, slugs) {
                    lines.append(line);
                    continue;
                }
                changed = True;
                lines.append("data: " + js_stringify(frame));
            }
            return "\n".join(lines).encode("utf-8") if changed else body;
        }
        frame = json.loads(text);
        return js_stringify(frame).encode("utf-8") if _annotate_frame(frame, slugs) else body;
    } except Exception {
        return body;
    }
}

# ── HTTP surface (re-bound onto harness.jac as connectors_*) ────────────────

def _guard(omb_token: any) -> any {
    want = os.environ.get("OMB_JAC_TOKEN");
    if want and omb_token != want {
        return {"ok": False, "status": 403, "error": "unauthorized"};
    }
    return None;
}

# Every op that reads the backend carries node's managed-broker credential
# ({"access": null | {url, token}}; absent = never set), so a respawned
# harness never serves without it.
def _apply_managed(managed: any) {
    if isinstance(managed, dict) and "access" in managed { set_managed_broker_access(managed["access"]); }
}

def _invoke(omb_token: any, managed: any, fn: any) -> any {
    g = _guard(omb_token);
    if g is not None { return g; }
    try {
        _apply_managed(managed);
        return fn();
    } except Exception as e {
        return {"ok": False, "status": _status_of(e), "error": str(e)};
    }
}

# Optional kwargs: the fused jacup binary binds the stringified default when
# a request omits one, so every optional arg is type-checked before use (and
# the node facade always sends every kwarg explicitly).
def _cfg_arg(cfg: any) -> dict[str, any] {
    if not isinstance(cfg, dict) { return {"composio": None}; }
    composio = cfg.get("composio");
    return {"composio": dict(composio) if isinstance(composio, dict) else None};
}

def _str_list(v: any) -> list[str] {
    if not isinstance(v, list) { return []; }
    return [x for x in v if isinstance(x, str)];
}

def:pub connectors_state(omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        try {
            return {"env_broker": _env_broker_access() is not None, "env_error": None};
        } except Exception as e {
            return {"env_broker": False, "env_error": str(e)};
        }
    }
    return _invoke(omb_token, None, _go);
}

def:pub connectors_set_broker_access(access: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        set_managed_broker_access(access if isinstance(access, dict) else None);
        return {"access": _cx["managed"]};
    }
    return _invoke(omb_token, None, _go);
}

def:pub connectors_prepare_project_session(api_key: any = None, current: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return prepare_project_session(api_key if isinstance(api_key, str) else "", current if isinstance(current, dict) else None);
    }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_mcp_integration(cfg: any = None, context: any = None, command: any = None, args: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        ctx: dict[str, any] = context if isinstance(context, dict) else {};
        return {"integration": mcp_integration(_cfg_arg(cfg), ctx, str(command), _str_list(args))};
    }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_relay_target(cfg: any = None, transport_session_id: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        tsid: any = transport_session_id if isinstance(transport_session_id, str) else None;
        return {"handle": _stash_relay_target(relay_prepare(_cfg_arg(cfg), tsid))};
    }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_relay_send(handle: any = None, payload: any = None, scope_hint_slugs: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        out = relay_dispatch(_take_relay_target(str(handle)), payload);
        body = with_scope_hint(out["bytes"], out["content_type"], _str_list(scope_hint_slugs));
        return {
            "status": out["status"],
            "body_b64": base64.b64encode(body).decode("ascii"),
            "content_type": out["content_type"],
            "transport_session_id": out["transport_session_id"],
        };
    }
    return _invoke(omb_token, None, _go);
}

def:pub connectors_connected_services(cfg: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"services": connected_services(_cfg_arg(cfg))}; }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_connected_service_slugs(cfg: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"slugs": connected_service_slugs(_cfg_arg(cfg))}; }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_validate_grants(cfg: any = None, grants: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return {"error": validate_connector_grants(_cfg_arg(cfg), grants if isinstance(grants, dict) else {})};
    }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_list_tools(cfg: any = None, force: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"services": list_connector_tools(_cfg_arg(cfg), force is True)}; }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_connection_status(cfg: any = None, slugs: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        wanted = _str_list(slugs) if isinstance(slugs, list) else curated_slugs();
        return {"services": connection_status(_cfg_arg(cfg), wanted)};
    }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_remove_service(cfg: any = None, slug: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return remove_service(_cfg_arg(cfg), str(slug)); }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_remove_account(cfg: any = None, slug: any = None, account_id: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return remove_account(_cfg_arg(cfg), str(slug), account_id); }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_authorize(cfg: any = None, slug: any = None, alias: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return authorize_service(_cfg_arg(cfg), str(slug), alias); }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_list_toolkits(cfg: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return list_toolkits(_cfg_arg(cfg)); }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_toolkit_card(cfg: any = None, slug: any = None, managed: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"card": toolkit_card(_cfg_arg(cfg), str(slug))}; }
    return _invoke(omb_token, managed, _go);
}

def:pub connectors_normalize_alias(value: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"alias": normalize_account_alias(value)}; }
    return _invoke(omb_token, None, _go);
}

def:pub connectors_classify_call(frame: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        call = connector_call_from_frame(frame);
        refusal: any = None;
        if call["kind"] == "unrecognized" { refusal = connector_unrecognized_text(call["invoked"], call["reason"]); }
        return {"call": call, "refusal": refusal};
    }
    return _invoke(omb_token, None, _go);
}

def:pub connectors_evaluate(names: any = None, grants: any = None, legacy: any = None, candidates: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        verdict = evaluate_connector_tools(_str_list(names), grants, legacy is True, _str_list(candidates));
        verdict["refusal"] = None if verdict["allowed"] else connector_refusal_text(verdict["denials"]);
        return verdict;
    }
    return _invoke(omb_token, None, _go);
}

with entry {
    _reset();
}
