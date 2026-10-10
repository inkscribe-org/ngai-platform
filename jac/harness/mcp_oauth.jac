"""McpOAuthManager port - OAuth sign-in for URL MCP servers on Jac (phase 4).

Faithful port of server/mcp-oauth.ts, mcp-oauth-store.ts and
mcp-oauth-discovery.ts. Discover the authorization server from the MCP
server's 401 (RFC 9728 -> RFC 8414 / OpenID), sign in as the app the person
registered for the server or else register a public client, run PKCE through
the person's browser with a loopback callback (or a URL pasted from another
computer), then keep the tokens fresh. Engines never see any of this: node
hands them an ordinary Authorization header.

mcp-oauth.json keeps the TS store's shape byte-for-byte (zod's schema key
order, unknown keys stripped, JSON.stringify(_, null, 2), mode 0600) and is
read through on every call, as before: another process may have changed it.

Concurrency. The TS manager leaned on promise sharing; here every op runs on
its own jac worker thread (node calls these ops off the serialized routine
queue, so a slow authorization server never stalls the scheduler). One
RLock guards flows / starting / refreshing and each store read-modify-write;
network calls happen outside it. Concurrent starts of the same flow wait on
the first one's Event; concurrent refreshes share one token request.

Hooks (`_mo["hooks"]`, swapped wholesale by tests):
  clients(name, url)   -> node bridge `mcp_oauth_client` (the app registered
                          in config.json; its secret is never copied here)
  owner_live(owner)    -> node bridge `mcp_owner_live` (session liveness)
  emit(payload)        -> routines' emit bridge op; node's sync mirror of
                          {name: {url, auth}} applies `mcp.oauth` frames.
"""

import os;
import re;
import json;
import time;
import uuid;
import hmac;
import base64;
import socket;
import hashlib;
import secrets;
import datetime;
import tempfile;
import threading;
import urllib.error;
import urllib.parse;
import urllib.request;
import from http.server { BaseHTTPRequestHandler, ThreadingHTTPServer }

import from db { DATA_DIR }
import from routines { _js_pretty, _bridge, _emit }

glob DEFAULT_LIFETIME_MS: int = 300000;
# Refresh a token this close to expiry, so a turn never starts on one that
# lapses mid-way.
glob REFRESH_MARGIN_MS: int = 120000;
glob REQUEST_TIMEOUT_S: float = 10.0;
glob FETCH_TIMEOUT_S: float = 5.0;
glob MAX_METADATA_BYTES: int = 65536;
glob MAX_RESPONSE_BYTES: int = 1048576;
glob CALLBACK_PATH: str = "/mcp-oauth/callback";
# complete()'s answer for a flow that ended while its code was spent.
glob DISCARDED: str = "discarded";
glob LOOPBACK_HOSTS: list[str] = ["127.0.0.1", "localhost", "[::1]"];
glob REDIRECT_STATUSES: list[int] = [301, 302, 303, 307, 308];

glob _LOCK: any = threading.RLock();
glob _mo: dict[str, any] = {};

def _reset -> None {
    _mo.update({
        "file": None,
        "lifetime_ms": DEFAULT_LIFETIME_MS,
        "flows": {},
        "starting": {},
        "refreshing": {},
        "hooks": _default_hooks(),
    });
}

# ── errors ─────────────────────────────────────────────────────────────────

class McpOAuthError(Exception) {
    # code: "not-oauth" | "no-registration" | "port-busy"; answered as 400.
}

class McpSignInError(Exception) {
    # status: 400 | 404 | 409.
}

class FetchError(Exception) {
    # A request that never produced a usable response (fetch rejecting).
}

def _oauth_error(code: str, message: str) -> Exception {
    err = McpOAuthError(message);
    setattr(err, "code", code);
    setattr(err, "status", 400);
    return err;
}

def _sign_in_error(status: int, message: str) -> Exception {
    err = McpSignInError(message);
    setattr(err, "status", status);
    return err;
}

# ── default hooks (production wiring) ──────────────────────────────────────

def _hook_clients(name: str, url: str) -> any {
    res = _bridge("mcp_oauth_client", {"name": name, "url": url});
    c = res.get("client");
    return c if isinstance(c, dict) else None;
}

def _hook_owner_live(owner: str) -> bool {
    # Fail closed: only an explicit `live: true` keeps a flow going.
    res = _bridge("mcp_owner_live", {"owner": owner});
    return res.get("live") is True;
}

def _default_hooks -> dict[str, any] {
    return {"clients": _hook_clients, "owner_live": _hook_owner_live, "emit": _emit};
}

def _clients(name: str, url: str) -> any {
    fn = _mo["hooks"].get("clients");
    if fn is None { return None; }
    c = fn(name, url);
    return c if isinstance(c, dict) else None;
}

def _owner_live(owner: str) -> bool {
    fn = _mo["hooks"].get("owner_live");
    if fn is None { return True; }
    return fn(owner) is True;
}

def _emit_frame(payload: dict[str, any]) {
    fn = _mo["hooks"].get("emit");
    if fn is not None { fn(payload); }
}

# ── small JS-compatible helpers ────────────────────────────────────────────

def _now_ms -> int {
    return int(time.time() * 1000);
}

def _iso(ms: int) -> str {
    d = datetime.datetime.fromtimestamp(ms // 1000, datetime.timezone.utc);
    return d.strftime("%Y-%m-%dT%H:%M:%S") + "." + str(ms % 1000).zfill(3) + "Z";
}

def _parse_iso_ms(value: str) -> int {
    d = datetime.datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc);
    return int(d.timestamp()) * 1000 + int(value[20:23]);
}

def _b64url(raw: bytes) -> str {
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=");
}

def _is_number(v: any) -> bool {
    if isinstance(v, bool) { return False; }
    if isinstance(v, int) { return True; }
    return isinstance(v, float) and v == v and v not in (float("inf"), float("-inf"));
}

def _is_str_list(v: any) -> bool {
    return isinstance(v, list) and all([isinstance(x, str) for x in v]);
}

# application/x-www-form-urlencoded as URLSearchParams writes it: alnum and
# *-._ stay, space is +, everything else is %XX of its UTF-8 bytes.
def _form_enc(s: str) -> str {
    return urllib.parse.quote_plus(s, safe="*").replace("~", "%7E");
}

def _www_form(pairs: list[any]) -> str {
    return "&".join([_form_enc(p[0]) + "=" + _form_enc(p[1]) for p in pairs]);
}

def _qs_parse(query: any) -> list[any] {
    if not query { return []; }
    return [[p[0], p[1]] for p in urllib.parse.parse_qsl(query, keep_blank_values=True)];
}

def _qs_all(pairs: list[any], key: str) -> list[str] {
    return [p[1] for p in pairs if p[0] == key];
}

def _qs_get(pairs: list[any], key: str) -> any {
    for p in pairs {
        if p[0] == key { return p[1]; }
    }
    return None;
}

def _qs_has(pairs: list[any], key: str) -> bool {
    return _qs_get(pairs, key) is not None;
}

# URLSearchParams.set: replace the first value, drop the rest, else append.
def _qs_set(pairs: list[any], key: str, value: str) -> list[any] {
    out: list[any] = [];
    done = False;
    for p in pairs {
        if p[0] == key {
            if not done {
                out.append([key, value]);
                done = True;
            }
        } else {
            out.append(p);
        }
    }
    if not done { out.append([key, value]); }
    return out;
}

# ── WHATWG-shaped URL parsing (the subset `new URL` decides here) ──────────

glob _SCHEME_RE: any = re.compile(r"^([A-Za-z][A-Za-z0-9+.\-]*):(.*)$", re.S);
glob _DEFAULT_PORTS: dict[str, str] = {"http": "80", "https": "443"};
glob _FORBIDDEN_HOST: str = " #%/:<>?@[\\]^|";

def _parse_url(value: any) -> any {
    # None where `new URL(value)` would throw; else the parts `href`,
    # `origin`, `pathname`, `username`, `hash`... are built from.
    if not isinstance(value, str) { return None; }
    s = value.strip("".join([chr(c) for c in range(33)]));
    s = s.replace("\t", "").replace("\n", "").replace("\r", "");
    m = _SCHEME_RE.match(s);
    if m is None { return None; }
    scheme = m.group(1).lower();
    rest = m.group(2);
    if scheme not in _DEFAULT_PORTS {
        return {"scheme": scheme, "special": False, "username": "", "password": "", "host": "",
                "port": "", "path": rest, "query": None, "fragment": None};
    }
    fragment: any = None;
    at = rest.find("#");
    if at >= 0 {
        fragment = rest[at + 1:];
        rest = rest[:at];
    }
    query: any = None;
    at = rest.find("?");
    if at >= 0 {
        query = rest[at + 1:];
        rest = rest[:at];
    }
    rest = rest.replace("\\", "/").lstrip("/");
    at = rest.find("/");
    authority = rest;
    path = "/";
    if at >= 0 {
        authority = rest[:at];
        path = rest[at:];
    }
    username = "";
    password = "";
    at = authority.rfind("@");
    if at >= 0 {
        userinfo = authority[:at];
        authority = authority[at + 1:];
        colon = userinfo.find(":");
        if colon >= 0 {
            username = userinfo[:colon];
            password = userinfo[colon + 1:];
        } else {
            username = userinfo;
        }
    }
    host = authority;
    port = "";
    if authority.startswith("[") {
        close = authority.find("]");
        if close < 0 { return None; }
        host = authority[:close + 1];
        tail = authority[close + 1:];
        if tail {
            if not tail.startswith(":") { return None; }
            port = tail[1:];
        }
    } else {
        colon = authority.find(":");
        if colon >= 0 {
            host = authority[:colon];
            port = authority[colon + 1:];
        }
        if any([c in _FORBIDDEN_HOST for c in host]) { return None; }
    }
    if not host { return None; }
    if port {
        if not port.isdigit() or int(port) > 65535 { return None; }
        port = str(int(port));
        if port == _DEFAULT_PORTS[scheme] { port = ""; }
    }
    return {"scheme": scheme, "special": True, "username": username, "password": password,
            "host": host.lower(), "port": port, "path": path, "query": query, "fragment": fragment};
}

def _url_host(u: dict[str, any]) -> str {
    return u["host"] + (":" + u["port"] if u["port"] else "");
}

def _url_origin(u: dict[str, any]) -> str {
    if not u["special"] { return "null"; }
    return u["scheme"] + "://" + _url_host(u);
}

def _url_href(u: dict[str, any]) -> str {
    if not u["special"] { return u["scheme"] + ":" + u["path"]; }
    auth = "";
    if u["username"] or u["password"] {
        auth = u["username"] + (":" + u["password"] if u["password"] else "") + "@";
    }
    out = u["scheme"] + "://" + auth + _url_host(u) + u["path"];
    if u["query"] is not None { out += "?" + u["query"]; }
    if u["fragment"] is not None { out += "#" + u["fragment"]; }
    return out;
}

# ── HTTP client (fetch with redirect: "error", no proxy) ───────────────────

def _no_redirect(h: any, req: any, fp: any, code: any, msg: any, hdrs: any, newurl: any) -> any {
    return None;
}

glob _NO_REDIRECT: any = type("_NoRedirect", (urllib.request.HTTPRedirectHandler, ), {"redirect_request": _no_redirect});
glob _OPENER: any = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NO_REDIRECT);

def _fetch_failed(e: any) -> Exception {
    if isinstance(e, (socket.timeout, TimeoutError)) {
        return FetchError("The operation was aborted due to timeout");
    }
    reason = getattr(e, "reason", None);
    if isinstance(reason, (socket.timeout, TimeoutError)) {
        return FetchError("The operation was aborted due to timeout");
    }
    return FetchError("fetch failed");
}

def _http(method: str, url: str, headers: dict[str, any], body: any, timeout_s: float, max_bytes: int) -> dict[str, any] {
    # {status, headers, text}; raises FetchError where fetch() would reject.
    req = urllib.request.Request(url, data=body, headers=headers, method=method);
    resp: any = None;
    try {
        resp = _OPENER.open(req, timeout=timeout_s);
    } except urllib.error.HTTPError as e {
        resp = e;
    } except Exception as e {
        raise _fetch_failed(e);
    }
    try {
        status = getattr(resp, "status", None) or resp.code;
        if status in REDIRECT_STATUSES { raise FetchError("fetch failed"); }
        raw = b"";
        if max_bytes > 0 { raw = resp.read(max_bytes + 1); }
        return {"status": status, "headers": resp.headers, "text": raw.decode("utf-8", errors="replace")};
    } except FetchError as e {
        raise e;
    } except Exception as e {
        raise _fetch_failed(e);
    } finally {
        try { resp.close(); } except Exception { }
    }
}

def _ok(status: int) -> bool {
    return status >= 200 and status < 300;
}

def _json_object(text: str) -> dict[str, any] {
    try {
        parsed = json.loads(text);
    } except Exception {
        return {};
    }
    return parsed if isinstance(parsed, dict) else {};
}

# ── discovery (mcp-oauth-discovery.ts) ─────────────────────────────────────

# https anywhere; http only to this machine (local test servers).
def is_allowed_auth_url(value: any) -> bool {
    u = _parse_url(value);
    if u is None { return False; }
    if u["username"] or u["password"] { return False; }
    if u["scheme"] == "https" { return True; }
    return u["scheme"] == "http" and u["host"] in LOOPBACK_HOSTS;
}

glob _RESOURCE_METADATA_RE: any = re.compile(r"resource_metadata\s*=\s*(?:\"([^\"]*)\"|([^\s,]+))", re.I);

# The `resource_metadata` parameter of a `WWW-Authenticate: Bearer ...` challenge.
def resource_metadata_url(www_authenticate: any) -> any {
    if not www_authenticate { return None; }
    m = _RESOURCE_METADATA_RE.search(www_authenticate);
    if m is None { return None; }
    v = m.group(1);
    if v is None { v = m.group(2); }
    return v if v else None;
}

def _remaining(deadline: any) -> float {
    if deadline is None { return FETCH_TIMEOUT_S; }
    return min(FETCH_TIMEOUT_S, deadline - time.monotonic());
}

def _get_json(url: str, deadline: any, fetch: any) -> any {
    if not is_allowed_auth_url(url) { return None; }
    try {
        r: any = None;
        if fetch is not None {
            r = fetch(url);
        } else {
            left = _remaining(deadline);
            if left <= 0 { return None; }
            r = _http("GET", url, {"accept": "application/json"}, None, left, MAX_METADATA_BYTES);
        }
        if not _ok(r["status"]) { return None; }
        text = r["text"];
        if len(text) > MAX_METADATA_BYTES { return None; }
        parsed = json.loads(text);
        return parsed if isinstance(parsed, dict) else None;
    } except Exception {
        return None;
    }
}

def _protected_resource(target: dict[str, any], hint: any, deadline: any, fetch: any) -> any {
    path = "" if target["path"] == "/" else target["path"];
    origin = _url_origin(target);
    candidates: list[str] = [];
    if hint { candidates.append(hint); }
    candidates.append(origin + "/.well-known/oauth-protected-resource" + path);
    candidates.append(origin + "/.well-known/oauth-protected-resource");
    seen: list[str] = [];
    for c in candidates {
        if c in seen { continue; }
        seen.append(c);
        doc = _get_json(c, deadline, fetch);
        if doc is not None { return doc; }
    }
    return None;
}

def _authorization_server(issuer: str, deadline: any, fetch: any) -> any {
    base = re.sub(r"/+$", "", issuer);
    u = _parse_url(base);
    if u is None { raise Exception("Invalid URL"); }
    suffix = "" if u["path"] == "/" else u["path"];
    origin = _url_origin(u);
    candidates = [
        origin + "/.well-known/oauth-authorization-server" + suffix,
        origin + "/.well-known/openid-configuration" + suffix,
    ];
    if suffix { candidates.append(base + "/.well-known/openid-configuration"); }
    for c in candidates {
        doc = _get_json(c, deadline, fetch);
        if doc is not None { return doc; }
    }
    return None;
}

def _optional_endpoint(v: any) -> any {
    return v if isinstance(v, str) and is_allowed_auth_url(v) else None;
}

# The sign-in endpoints for an MCP server, or None when it does not describe
# a usable OAuth sign-in (no metadata, no PKCE S256, or an endpoint that is
# not https). `timeout_s` bounds the whole discovery (the probe's 5 s);
# `fetch(url) -> {status, text}` replaces the network in tests.
def discover_mcp_auth(mcp_url: any, www_authenticate: any, timeout_s: any = None, fetch: any = None) -> any {
    target = _parse_url(mcp_url);
    if target is None { return None; }
    deadline: any = None;
    if timeout_s is not None { deadline = time.monotonic() + timeout_s; }
    resource = _protected_resource(target, resource_metadata_url(www_authenticate), deadline, fetch);
    servers: any = None;
    if resource is not None and _is_str_list(resource.get("authorization_servers")) {
        servers = resource["authorization_servers"];
    }
    issuer = servers[0] if servers else _url_origin(target);
    if not is_allowed_auth_url(issuer) { return None; }
    metadata = _authorization_server(issuer, deadline, fetch);
    if metadata is None { return None; }

    authorization_endpoint = metadata.get("authorization_endpoint");
    token_endpoint = metadata.get("token_endpoint");
    if not isinstance(authorization_endpoint, str) or not is_allowed_auth_url(authorization_endpoint) { return None; }
    if not isinstance(token_endpoint, str) or not is_allowed_auth_url(token_endpoint) { return None; }
    methods = metadata.get("code_challenge_methods_supported");
    if not _is_str_list(methods) or "S256" not in methods { return None; }

    # RFC 8414 §3.3: the metadata must be for the issuer it was fetched for.
    claimed = metadata.get("issuer");
    if isinstance(claimed, str) and re.sub(r"/+$", "", claimed) != re.sub(r"/+$", "", issuer) { return None; }
    registration_endpoint = _optional_endpoint(metadata.get("registration_endpoint"));
    revocation_endpoint = _optional_endpoint(metadata.get("revocation_endpoint"));
    scopes: any = None;
    if resource is not None and _is_str_list(resource.get("scopes_supported")) { scopes = resource["scopes_supported"]; }
    auth_methods: any = None;
    if _is_str_list(metadata.get("token_endpoint_auth_methods_supported")) {
        auth_methods = metadata["token_endpoint_auth_methods_supported"];
    }
    target["fragment"] = None;
    meta: dict[str, any] = {
        "issuer": issuer,
        "authorizationEndpoint": authorization_endpoint,
        "tokenEndpoint": token_endpoint,
    };
    if registration_endpoint { meta["registrationEndpoint"] = registration_endpoint; }
    if revocation_endpoint { meta["revocationEndpoint"] = revocation_endpoint; }
    if scopes { meta["scopes"] = scopes; }
    if auth_methods { meta["tokenEndpointAuthMethods"] = auth_methods; }
    meta["resource"] = _url_href(target);
    return meta;
}

# ── token store (mcp-oauth-store.ts) ───────────────────────────────────────

glob RECORD_STATES: list[str] = ["needs-sign-in", "signed-in"];
glob TOKEN_AUTHS: list[str] = ["client_secret_post", "client_secret_basic"];
glob RECORD_OPTIONAL_STRS: list[str] = ["issuer", "clientId"];
glob RECORD_TAIL_STRS: list[str] = ["redirectUri", "tokenEndpoint", "revocationEndpoint"];

def _store_file -> str {
    f = _mo.get("file");
    if f is None {
        f = os.path.join(DATA_DIR, "mcp-oauth.json");
        _mo.update({"file": f});
    }
    return f;
}

def _clean_tokens(v: any) -> any {
    if not isinstance(v, dict) { return None; }
    access = v.get("access");
    if not isinstance(access, str) or not access { return None; }
    out: dict[str, any] = {"access": access};
    if "refresh" in v {
        if not isinstance(v["refresh"], str) or not v["refresh"] { return None; }
        out["refresh"] = v["refresh"];
    }
    if "expiresAt" in v {
        if not _is_number(v["expiresAt"]) { return None; }
        out["expiresAt"] = v["expiresAt"];
    }
    if "scope" in v {
        if not isinstance(v["scope"], str) { return None; }
        out["scope"] = v["scope"];
    }
    return out;
}

# zod's recordSchema: schema key order, unknown keys stripped, None on any
# invalid field (a record is all or nothing, like safeParse).
def _clean_record(v: any) -> any {
    if not isinstance(v, dict) { return None; }
    if not isinstance(v.get("url"), str) { return None; }
    if v.get("state") not in RECORD_STATES { return None; }
    out: dict[str, any] = {"url": v["url"], "state": v["state"]};
    for key in RECORD_OPTIONAL_STRS {
        if key in v {
            if not isinstance(v[key], str) { return None; }
            out[key] = v[key];
        }
    }
    if "tokenAuth" in v {
        if v["tokenAuth"] not in TOKEN_AUTHS { return None; }
        out["tokenAuth"] = v["tokenAuth"];
    }
    for key in RECORD_TAIL_STRS {
        if key in v {
            if not isinstance(v[key], str) { return None; }
            out[key] = v[key];
        }
    }
    if "tokens" in v {
        tokens = _clean_tokens(v["tokens"]);
        if tokens is None { return None; }
        out["tokens"] = tokens;
    }
    return out;
}

# Read through on every call: the file is small, and another process (the
# config CLI, a second window's server) may have changed it.
def _store_read -> dict[str, any] {
    try {
        with open(_store_file(), "r", encoding="utf-8") as f {
            raw = json.loads(f.read());
        }
    } except Exception {
        return {"servers": {}};
    }
    if not isinstance(raw, dict) { return {"servers": {}}; }
    if "servers" not in raw { return {"servers": {}}; }
    servers = raw["servers"];
    if not isinstance(servers, dict) { return {"servers": {}}; }
    cleaned: dict[str, any] = {};
    for (name, rec) in servers.items() {
        c = _clean_record(rec);
        if c is None { return {"servers": {}}; }
        cleaned[name] = c;
    }
    return {"servers": cleaned};
}

def _store_write(data: dict[str, any]) {
    file = _store_file();
    payload = _js_pretty(data);
    dirn = os.path.dirname(file) or ".";
    os.makedirs(dirn, exist_ok=True);
    mk = tempfile.mkstemp(prefix=".mcp-oauth-", dir=dirn);
    tmp = mk[1];
    try {
        with os.fdopen(mk[0], "w", encoding="utf-8") as f {
            f.write(payload);
            f.flush();
            os.fsync(f.fileno());
        }
        os.chmod(tmp, 0o600);
        os.replace(tmp, file);
    } except Exception {
        try { os.unlink(tmp); } except Exception { }
        raise;
    }
}

def _auth_of(rec: dict[str, any]) -> str {
    return "signed-in" if rec.get("state") == "signed-in" and rec.get("tokens") else "needs-sign-in";
}

# The record for this server, only while it is still for this URL.
def store_get(name: str, url: str) -> any {
    rec = _store_read()["servers"].get(name);
    if rec is not None and rec["url"] == url { return rec; }
    return None;
}

def store_put(name: str, record: dict[str, any]) {
    cleaned = _clean_record(record);
    if cleaned is None { raise Exception("Invalid MCP sign-in record."); }
    with _LOCK {
        data = _store_read();
        data["servers"][name] = cleaned;
        _store_write(data);
        _emit_frame({"kind": "mcp.oauth", "name": name, "url": cleaned["url"], "auth": _auth_of(cleaned)});
    }
}

def store_delete(name: str) {
    with _LOCK {
        data = _store_read();
        if name not in data["servers"] { return; }
        del data["servers"][name];
        _store_write(data);
        _emit_frame({"kind": "mcp.oauth", "name": name, "url": None, "auth": "none"});
    }
}

# Every record's {url, auth}, for node's synchronous mirror.
def mo_states -> dict[str, any] {
    out: dict[str, any] = {};
    for (name, rec) in _store_read()["servers"].items() {
        out[name] = {"url": rec["url"], "auth": _auth_of(rec)};
    }
    return out;
}

# ── manager (mcp-oauth.ts) ─────────────────────────────────────────────────

# A port derived from the server URL: the same redirect URI on every attempt,
# so a registered client can be reused. FNV-1a over the first UTF-16 unit of
# each code point, exactly as the TS `for (const char of url)` loop.
def preferred_port(url: str) -> int {
    h = 0x811c9dc5;
    for ch in url {
        cp = ord(ch);
        unit = cp;
        if cp >= 0x10000 { unit = 0xD800 + ((cp - 0x10000) >> 10); }
        h = h ^ unit;
        h = (h * 0x01000193) & 0xffffffff;
    }
    return 20000 + (h % 20000);
}

# The redirect URI a sign-in for this server uses, to register with an app
# made in advance for it.
def mcp_oauth_redirect_uri(url: str) -> str {
    return "http://127.0.0.1:" + str(preferred_port(url)) + CALLBACK_PATH;
}

# RFC 8414 §2: an absent list means client_secret_basic.
def _token_auth_method(meta: dict[str, any], secret: any) -> str {
    if not secret { return "none"; }
    supported = meta.get("tokenEndpointAuthMethods");
    if not supported or "client_secret_basic" in supported or "client_secret_post" not in supported {
        return "client_secret_basic";
    }
    return "client_secret_post";
}

def _same_secret(actual: str, expected: str) -> bool {
    a = actual.encode("utf-8");
    b = expected.encode("utf-8");
    return len(a) == len(b) and hmac.compare_digest(a, b);
}

def _post_form(url: str, form: list[any], client: any) -> dict[str, any] {
    headers: dict[str, any] = {"content-type": "application/x-www-form-urlencoded", "accept": "application/json"};
    fields = list(form);
    if client is not None and client["method"] == "client_secret_basic" and client.get("secret") {
        # RFC 6749 §2.3.1: Basic credentials are form-encoded first.
        pair = _form_enc(client["id"]) + ":" + _form_enc(client["secret"]);
        headers["authorization"] = "Basic " + base64.b64encode(pair.encode("utf-8")).decode("ascii");
    } elif client is not None {
        fields.append(["client_id", client["id"]]);
        if client["method"] == "client_secret_post" and client.get("secret") {
            fields.append(["client_secret", client["secret"]]);
        }
    }
    r = _http("POST", url, headers, _www_form(fields).encode("utf-8"), REQUEST_TIMEOUT_S, MAX_RESPONSE_BYTES);
    # an empty or non-JSON body is judged by its status alone
    return {"status": r["status"], "body": _json_object(r["text"])};
}

def _tokens_from(body: dict[str, any], previous: any = None) -> any {
    access = body.get("access_token");
    if not isinstance(access, str) or not access { return None; }
    refresh: any = None;
    if isinstance(body.get("refresh_token"), str) and body["refresh_token"] {
        refresh = body["refresh_token"];
    } elif previous is not None {
        refresh = previous.get("refresh");
    }
    out: dict[str, any] = {"access": access};
    if refresh { out["refresh"] = refresh; }
    exp: any = body.get("expires_in");
    if _is_number(exp) and exp > 0 { out["expiresAt"] = _now_ms() + exp * 1000; }
    if isinstance(body.get("scope"), str) { out["scope"] = body["scope"]; }
    return out;
}

# How to authenticate as the client a record was signed in with; None when
# its app (or the app's secret) is no longer configured.
def _record_client(name: str, record: dict[str, any]) -> any {
    if not record.get("clientId") { return None; }
    if not record.get("tokenAuth") { return {"id": record["clientId"], "method": "none"}; }
    configured = _clients(name, record["url"]);
    if configured is not None and configured.get("clientId") == record["clientId"] and configured.get("clientSecret") {
        return {"id": record["clientId"], "secret": configured["clientSecret"], "method": record["tokenAuth"]};
    }
    return None;
}

def auth_state(name: str, url: str) -> str {
    rec = store_get(name, url);
    if rec is None { return "none"; }
    return _auth_of(rec);
}

# The server answered 401 asking for OAuth: stop mounting it and show Sign
# in. Any tokens it had are no longer accepted, so they go.
def mark_needs_sign_in(name: str, url: str) {
    with _LOCK {
        rec = store_get(name, url);
        nxt: dict[str, any] = dict(rec) if rec is not None else {"url": url};
        nxt.pop("tokens", None);
        nxt["url"] = url;
        nxt["state"] = "needs-sign-in";
        store_put(name, nxt);
    }
}

def _copy_status(fl: dict[str, any]) -> dict[str, any] {
    return dict(fl["status"]);
}

def _close_listener(fl: dict[str, any]) {
    with _LOCK {
        if fl.get("closed") { return; }
        fl["closed"] = True;
    }
    srv = fl["server"];
    try {
        if fl.get("serving") { srv.shutdown(); }
        srv.server_close();
    } except Exception { }
}

def _finish(fl: dict[str, any], phase: str, message: any = None) {
    with _LOCK {
        if fl["status"]["phase"] != "waiting" { return; }
        t = fl.get("expiry");
        if t is not None { t.cancel(); }
        st = dict(fl["status"]);
        st["phase"] = phase;
        st["authorizationUrl"] = None;
        if message { st["message"] = message; }
        fl["status"] = st;
    }
    _close_listener(fl);
}

def start(name: str, url: str, www_authenticate: any = None, owner: str = "loopback") -> dict[str, any] {
    mine: any = None;
    wait_on: any = None;
    with _LOCK {
        current = _mo["flows"].get(name);
        if current is not None and current["status"]["phase"] == "waiting" and not _owner_live(current["owner"]) {
            _finish(current, "cancelled", "Your session ended. Start again.");
        }
        if current is not None and current["status"]["phase"] == "waiting" {
            if current["owner"] != owner {
                raise _sign_in_error(409, "A sign-in is already in progress in another browser.");
            }
            if current["url"] == url { return _copy_status(current); }
        }
        pending = _mo["starting"].get(name);
        if pending is not None {
            if pending["owner"] != owner or pending["url"] != url or pending["cancelled"] {
                raise _sign_in_error(409, "A sign-in is still starting. Try again shortly.");
            }
            wait_on = pending;
        } else {
            mine = {"owner": owner, "url": url, "cancelled": False, "done": threading.Event(), "result": None, "error": None};
            _mo["starting"][name] = mine;
        }
    }
    if wait_on is not None {
        wait_on["done"].wait();
        failed: (Exception | None) = wait_on["error"];
        if failed is not None { raise failed; }
        return wait_on["result"];
    }
    try {
        result = _begin(name, url, mine, www_authenticate);
        mine["result"] = result;
        return result;
    } except Exception as e {
        mine["error"] = e;
        raise e;
    } finally {
        with _LOCK {
            if _mo["starting"].get(name) is mine { _mo["starting"].pop(name, None); }
        }
        mine["done"].set();
    }
}

def status(name: str, flow_id: str, owner: str = "loopback") -> any {
    with _LOCK {
        fl = _mo["flows"].get(name);
        if fl is not None and fl["owner"] == owner and fl["status"]["flowId"] == flow_id {
            return _copy_status(fl);
        }
        return None;
    }
}

def cancel_flow(name: str, owner: str, flow_id: any = None) {
    with _LOCK {
        fl = _mo["flows"].get(name);
        if fl is None or fl["owner"] != owner or (flow_id and fl["status"]["flowId"] != flow_id) {
            raise _sign_in_error(404, "This sign-in is no longer available in this browser. Start again.");
        }
    }
    _finish(fl, "cancelled", "Sign-in cancelled.");
}

def cancel(name: str) {
    with _LOCK {
        pending = _mo["starting"].get(name);
        if pending is not None { pending["cancelled"] = True; }
        fl = _mo["flows"].get(name);
    }
    if fl is not None { _finish(fl, "cancelled", "Sign-in cancelled."); }
}

def revoke_owner(owner: str) {
    with _LOCK {
        for pending in _mo["starting"].values() {
            if pending["owner"] == owner { pending["cancelled"] = True; }
        }
        mine = [fl for fl in _mo["flows"].values() if fl["owner"] == owner];
    }
    for fl in mine { _finish(fl, "cancelled", "Sign-in cancelled because your session ended."); }
}

# Parse the pasted URL locally; never request a user-supplied address.
def complete_callback(name: str, flow_id: str, callback_url: any, owner: str = "loopback") -> dict[str, any] {
    with _LOCK {
        fl = _mo["flows"].get(name);
        if fl is None or fl["owner"] != owner or fl["status"]["flowId"] != flow_id {
            raise _sign_in_error(404, "This sign-in is no longer available in this browser. Start again.");
        }
    }
    callback: any = None;
    if isinstance(callback_url, str) and len(callback_url) <= 16384 { callback = _parse_url(callback_url); }
    if callback is None {
        raise _sign_in_error(400, "Paste the complete redirect URL from your browser's address bar.");
    }
    _accept_callback(fl, callback);
    return _copy_status(fl);
}

# Revoke with the server when it offers that (best effort), then forget.
def sign_out(name: str, url: str) {
    cancel(name);
    rec = store_get(name, url);
    token: any = None;
    if rec is not None and rec.get("tokens") {
        token = rec["tokens"].get("refresh") or rec["tokens"]["access"];
    }
    if rec is not None and rec.get("revocationEndpoint") and token {
        try {
            _post_form(rec["revocationEndpoint"], [["token", token]], _record_client(name, rec));
        } except Exception { }
    }
    store_delete(name);
}

# Drop everything for a server that was removed or pointed elsewhere.
def forget(name: str) {
    cancel(name);
    with _LOCK { _mo["flows"].pop(name, None); }
    store_delete(name);
}

# A usable access token for this server at this URL, refreshed when it is
# close to expiry; None when the server needs a (new) sign-in.
def access_token(name: str, url: str) -> any {
    mine: any = None;
    wait_on: any = None;
    rec: any = None;
    with _LOCK {
        rec = store_get(name, url);
        if rec is None or rec["state"] != "signed-in" or not rec.get("tokens") { return None; }
        tokens = rec["tokens"];
        exp = tokens.get("expiresAt");
        if not exp or exp > _now_ms() + REFRESH_MARGIN_MS { return tokens["access"]; }
        pending = _mo["refreshing"].get(name);
        if pending is not None {
            wait_on = pending;
        } else {
            mine = {"done": threading.Event(), "result": None};
            _mo["refreshing"][name] = mine;
        }
    }
    if wait_on is not None {
        wait_on["done"].wait();
        return wait_on["result"];
    }
    try {
        result = _refresh(name, rec);
        mine["result"] = result;
        return result;
    } finally {
        with _LOCK {
            if _mo["refreshing"].get(name) is mine { _mo["refreshing"].pop(name, None); }
        }
        mine["done"].set();
    }
}

def dispose {
    with _LOCK {
        for pending in _mo["starting"].values() { pending["cancelled"] = True; }
        flows = list(_mo["flows"].values());
    }
    for fl in flows { _finish(fl, "cancelled", "Sign-in cancelled."); }
    with _LOCK { _mo["flows"].clear(); }
}

def _refresh(name: str, record: dict[str, any]) -> any {
    tokens = record["tokens"];
    exp = tokens.get("expiresAt");
    still_valid = exp is not None and exp > _now_ms();
    client = _record_client(name, record);
    if not tokens.get("refresh") or not record.get("tokenEndpoint") or client is None {
        if still_valid { return tokens["access"]; }
        mark_needs_sign_in(name, record["url"]);
        return None;
    }
    answer: any = None;
    try {
        answer = _post_form(record["tokenEndpoint"], [
            ["grant_type", "refresh_token"],
            ["refresh_token", tokens["refresh"]],
            ["resource", record["url"]],
        ], client);
    } except Exception {
        # offline or the server is down: keep what still works, retry next turn
        return tokens["access"] if still_valid else None;
    }
    nxt: any = None;
    if _ok(answer["status"]) { nxt = _tokens_from(answer["body"], tokens); }
    if nxt is None {
        # Only a refused grant or client means the sign-in is over; a rate
        # limit, a proxy page or an outage keeps what still works.
        err = answer["body"].get("error");
        dead = answer["status"] in (400, 401) and err in ("invalid_grant", "invalid_client");
        if not dead { return tokens["access"] if still_valid else None; }
        mark_needs_sign_in(name, record["url"]);
        return None;
    }
    with _LOCK {
        # the entry may have been removed or re-pointed while this was in flight
        if store_get(name, record["url"]) is None { return None; }
        updated = dict(record);
        updated["state"] = "signed-in";
        updated["tokens"] = nxt;
        store_put(name, updated);
    }
    return nxt["access"];
}

# The WWW-Authenticate challenge of an unauthenticated request, if any.
def _challenge(url: str) -> any {
    try {
        body = json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "OpenMausBot", "version": "1"}},
        }, separators=(",", ":")).encode("utf-8");
        r = _http("POST", url, {"content-type": "application/json", "accept": "application/json, text/event-stream"}, body, REQUEST_TIMEOUT_S, 0);
        if r["status"] != 401 { return None; }
        values = r["headers"].get_all("www-authenticate");
        return ", ".join(values) if values else None;
    } except Exception {
        return None;
    }
}

# A fresh public client per sign-in. Sign-ins are rare, and a cached id goes
# stale when an authorization server prunes idle clients.
def _register(meta: dict[str, any], redirect_uri: str) -> str {
    if not meta.get("registrationEndpoint") {
        raise _oauth_error("no-registration", "This server only signs in apps registered with it in advance. Edit the server and add that app's client ID under Sign-in app.");
    }
    body = json.dumps({
        "client_name": "OpenMausBot",
        "redirect_uris": [redirect_uri],
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
    }, separators=(",", ":")).encode("utf-8");
    r = _http("POST", meta["registrationEndpoint"], {"content-type": "application/json", "accept": "application/json"}, body, REQUEST_TIMEOUT_S, MAX_RESPONSE_BYTES);
    client_id = _json_object(r["text"]).get("client_id");
    if not _ok(r["status"]) or not isinstance(client_id, str) or not client_id {
        raise Exception("This server would not register OpenMausBot for sign-in. Try again later.");
    }
    return client_id;
}

def _listen(port: int, handler: any) -> any {
    cls = type("McpOAuthListener", (ThreadingHTTPServer, ), {
        "daemon_threads": True,
        # Windows lets SO_REUSEADDR take over a bound port; elsewhere it only
        # skips TIME_WAIT, as node's own listen() does.
        "allow_reuse_address": os.name != "nt",
    });
    return cls(("127.0.0.1", port), handler);
}

def _make_handler(holder: dict[str, any]) -> any {
    def _handle(h: any) {
        fl = holder.get("flow");
        if fl is None {
            _respond(h, 400, "Invalid sign-in callback. Return to OpenMausBot and try again.");
            return;
        }
        _serve_callback(fl, h);
    }
    def _quiet(h: any, *args: any) {
        return;
    }
    return type("McpOAuthCallback", (BaseHTTPRequestHandler, ), {
        "do_GET": _handle, "do_POST": _handle, "do_PUT": _handle, "do_DELETE": _handle,
        "do_PATCH": _handle, "do_HEAD": _handle, "do_OPTIONS": _handle,
        "log_message": _quiet, "timeout": 10, "protocol_version": "HTTP/1.1",
    });
}

def _begin(name: str, url: str, starting: dict[str, any], www_authenticate: any) -> dict[str, any] {
    with _LOCK { previous = _mo["flows"].get(name); }
    if previous is not None { _finish(previous, "cancelled", "Sign-in cancelled."); }
    challenge = www_authenticate;
    if challenge is None { challenge = _challenge(url); }
    meta = discover_mcp_auth(url, challenge);
    if meta is None {
        raise _oauth_error("not-oauth", "This server does not offer an OAuth sign-in. Add its token as a header instead.");
    }
    registered = _clients(name, url);

    holder: dict[str, any] = {"flow": None};
    handler = _make_handler(holder);
    port = preferred_port(url);
    srv: any = None;
    try {
        srv = _listen(port, handler);
    } except Exception {
        # An app registered in advance was given this exact redirect URI.
        if registered is not None {
            raise _oauth_error("port-busy", "Port " + str(port) + " on this computer is in use, and sign-ins for this server's app return there. Close what is using it and try again.");
        }
        srv = _listen(0, handler);
    }
    try {
        redirect_uri = "http://127.0.0.1:" + str(srv.server_address[1]) + CALLBACK_PATH;
        client: dict[str, any] = {};
        if registered is not None {
            client = {"id": registered.get("clientId")};
            if registered.get("clientSecret") { client["secret"] = registered["clientSecret"]; }
            client["method"] = _token_auth_method(meta, registered.get("clientSecret"));
        } else {
            client = {"id": _register(meta, redirect_uri), "method": "none"};
        }
        scopes = meta.get("scopes");
        if registered is not None and registered.get("scopes") { scopes = registered["scopes"]; }
        if starting["cancelled"] or not _owner_live(starting["owner"]) {
            raise _sign_in_error(409, "Sign-in cancelled because the session or server changed.");
        }
        state = _b64url(secrets.token_bytes(32));
        verifier = _b64url(secrets.token_bytes(32));
        authorize = _parse_url(meta["authorizationEndpoint"]);
        pairs = _qs_parse(authorize["query"]);
        pairs = _qs_set(pairs, "response_type", "code");
        pairs = _qs_set(pairs, "client_id", client["id"]);
        pairs = _qs_set(pairs, "redirect_uri", redirect_uri);
        pairs = _qs_set(pairs, "state", state);
        pairs = _qs_set(pairs, "code_challenge", _b64url(hashlib.sha256(verifier.encode("ascii")).digest()));
        pairs = _qs_set(pairs, "code_challenge_method", "S256");
        pairs = _qs_set(pairs, "resource", meta["resource"]);
        if scopes { pairs = _qs_set(pairs, "scope", " ".join(scopes)); }
        authorize["query"] = _www_form(pairs);

        lifetime_ms = int(_mo["lifetime_ms"]);
        st: dict[str, any] = {
            "phase": "waiting",
            "flowId": str(uuid.uuid4()),
            "authorizationUrl": _url_href(authorize),
            "expiresAt": _iso(_now_ms() + lifetime_ms),
        };
        fl: dict[str, any] = {
            "owner": starting["owner"], "name": name, "url": url, "status": st, "state": state,
            "verifier": verifier, "redirect_uri": redirect_uri, "client": client, "meta": meta,
            "server": srv, "consumed": False, "expiry": None, "serving": False, "closed": False,
        };
        def _expire {
            _finish(fl, "expired", "Sign-in expired. Start again.");
        }
        timer = threading.Timer(lifetime_ms / 1000.0, _expire);
        timer.daemon = True;
        fl["expiry"] = timer;
        holder["flow"] = fl;
        with _LOCK {
            _mo["flows"][name] = fl;
            fl["serving"] = True;
        }
        threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start();
        timer.start();
        return dict(st);
    } except Exception as e {
        if holder["flow"] is None {
            try { srv.server_close(); } except Exception { }
        }
        raise e;
    }
}

def _respond(h: any, code: int, text: str) {
    data = text.encode("utf-8");
    h.send_response(code);
    h.send_header("Cache-Control", "no-store");
    h.send_header("Content-Type", "text/plain; charset=utf-8");
    h.send_header("Referrer-Policy", "no-referrer");
    # A kept-alive browser connection would carry the next sign-in's
    # callback to this listener after it has closed to new connections.
    h.send_header("Connection", "close");
    h.send_header("Content-Length", str(len(data)));
    h.end_headers();
    if h.command != "HEAD" { h.wfile.write(data); }
    h.close_connection = True;
}

def _serve_callback(fl: dict[str, any], h: any) {
    expected = _parse_url(fl["redirect_uri"]);
    callback: any = None;
    path = h.path;
    if h.headers.get("Host") == _url_host(expected) and isinstance(path, str) and path.startswith("/") {
        callback = _parse_url(_url_origin(expected) + path);
    }
    if callback is None {
        _respond(h, 400, "Invalid sign-in callback. Return to OpenMausBot and try again.");
        return;
    }
    try {
        if h.command != "GET" { raise _sign_in_error(400, "Invalid sign-in callback."); }
        _accept_callback(fl, callback);
        if fl["status"]["phase"] == "failed" {
            _respond(h, 400, str(fl["status"].get("message")) + " You can close this tab.");
        } else {
            _respond(h, 200, "Signed in. You can close this tab and return to OpenMausBot.");
        }
    } except McpSignInError as e {
        _respond(h, getattr(e, "status", 400), "Invalid or expired sign-in. Return to OpenMausBot and try again.");
    } except Exception {
        _respond(h, 400, "Invalid or expired sign-in. Return to OpenMausBot and try again.");
    }
}

def _callback_matches(fl: dict[str, any], callback: dict[str, any], params: list[any]) -> bool {
    expected = _parse_url(fl["redirect_uri"]);
    if _url_origin(callback) != _url_origin(expected) or callback["path"] != expected["path"] { return False; }
    if callback["username"] or callback["password"] or callback["fragment"] { return False; }
    for p in params {
        if len(_qs_all(params, p[0])) != 1 { return False; }
    }
    state = _qs_get(params, "state");
    if not _same_secret(state if state is not None else "", fl["state"]) { return False; }
    if _qs_has(params, "iss") and _qs_get(params, "iss") != fl["meta"]["issuer"] { return False; }
    code = _qs_get(params, "code");
    error = _qs_get(params, "error");
    granted = bool(code) and not _qs_has(params, "error") and len(code) <= 4096;
    refused = bool(error) and not _qs_has(params, "code");
    return granted or refused;
}

# Both the listener and authenticated paste-back use the same one-shot checks.
def _accept_callback(fl: dict[str, any], callback: dict[str, any]) {
    params = _qs_parse(callback["query"]);
    with _LOCK {
        if not _owner_live(fl["owner"]) { _finish(fl, "cancelled", "Your session ended. Start again."); }
        if fl["status"]["phase"] == "waiting" and not fl["consumed"] and _now_ms() >= _parse_iso_ms(fl["status"]["expiresAt"]) {
            _finish(fl, "expired", "Sign-in expired. Start again.");
        }
        if fl["consumed"] or fl["status"]["phase"] != "waiting" or _mo["flows"].get(fl["name"]) is not fl {
            raise _sign_in_error(409, "This sign-in has ended or is already being completed. Start again if needed.");
        }
        if not _callback_matches(fl, callback, params) {
            raise _sign_in_error(400, "This redirect URL does not belong to the current sign-in. Copy the complete URL and try again.");
        }
        fl["consumed"] = True;
        if fl["expiry"] is not None { fl["expiry"].cancel(); }
    }
    failure = _complete(fl, params);
    if failure == DISCARDED { raise _sign_in_error(409, "This sign-in was cancelled. Start again."); }
    if failure is not None { _finish(fl, "failed", failure); }
}

def _revoke_quietly(endpoint: str, token: str, client: any) {
    def _go {
        try { _post_form(endpoint, [["token", token]], client); } except Exception { }
    }
    threading.Thread(target=_go, daemon=True).start();
}

# Spend the code; the error message on failure, None on success (the flow
# is finished as succeeded under the same lock that stored its tokens).
def _complete(fl: dict[str, any], params: list[any]) -> any {
    if _qs_has(params, "error") { return "Sign-in was not approved."; }
    code = _qs_get(params, "code");
    if not code or len(code) > 4096 { return "The sign-in did not return a code. Start again."; }
    meta = fl["meta"];
    try {
        answer = _post_form(meta["tokenEndpoint"], [
            ["grant_type", "authorization_code"],
            ["code", code],
            ["redirect_uri", fl["redirect_uri"]],
            ["code_verifier", fl["verifier"]],
            ["resource", meta["resource"]],
        ], fl["client"]);
        tokens: any = None;
        if _ok(answer["status"]) { tokens = _tokens_from(answer["body"]); }
        if tokens is None { return "The server did not accept this sign-in. Start again."; }
        discard = False;
        with _LOCK {
            # Cancelled, signed out or removed while the code was being
            # spent: hand the tokens back rather than resurrect a sign-in.
            if not _owner_live(fl["owner"]) { _finish(fl, "cancelled", "Your session ended. Start again."); }
            if _mo["flows"].get(fl["name"]) is not fl or fl["status"]["phase"] != "waiting" {
                discard = True;
            } else {
                rec: dict[str, any] = {
                    "url": fl["url"],
                    "state": "signed-in",
                    "issuer": meta["issuer"],
                    "clientId": fl["client"]["id"],
                };
                if fl["client"]["method"] != "none" { rec["tokenAuth"] = fl["client"]["method"]; }
                rec["redirectUri"] = fl["redirect_uri"];
                rec["tokenEndpoint"] = meta["tokenEndpoint"];
                if meta.get("revocationEndpoint") { rec["revocationEndpoint"] = meta["revocationEndpoint"]; }
                rec["tokens"] = tokens;
                store_put(fl["name"], rec);
                _finish(fl, "succeeded");
            }
        }
        if discard {
            if meta.get("revocationEndpoint") {
                _revoke_quietly(meta["revocationEndpoint"], tokens.get("refresh") or tokens["access"], fl["client"]);
            }
            return DISCARDED;
        }
        return None;
    } except Exception {
        return "Could not reach the sign-in server. Start again.";
    }
}

# ── turn servers ───────────────────────────────────────────────────────────

def _is_url_server(server: any) -> bool {
    return isinstance(server, dict) and "url" in server;
}

# The servers a turn may mount: a URL server waiting for sign-in would only
# answer 401 mid-turn, so it stays out until someone signs in.
def without_pending_sign_in(servers: dict[str, any]) -> dict[str, any] {
    out: dict[str, any] = {};
    for (name, server) in servers.items() {
        if _is_url_server(server) and auth_state(name, server["url"]) == "needs-sign-in" { continue; }
        out[name] = server;
    }
    return out;
}

# Give each signed-in URL server a fresh bearer token, replacing any
# Authorization header it was configured with. A server whose token can no
# longer be had is left out. The input is not modified.
def with_mcp_sign_in(servers: dict[str, any]) -> dict[str, any] {
    out: dict[str, any] = {};
    for (name, server) in without_pending_sign_in(servers).items() {
        if not _is_url_server(server) or auth_state(name, server["url"]) != "signed-in" {
            out[name] = server;
            continue;
        }
        token = access_token(name, server["url"]);
        if not token { continue; }
        headers: dict[str, any] = {};
        for (key, value) in (server.get("headers") or {}).items() {
            if key.lower() != "authorization" { headers[key] = value; }
        }
        headers["Authorization"] = "Bearer " + token;
        updated = dict(server);
        updated["headers"] = headers;
        out[name] = updated;
    }
    return out;
}

# ── HTTP surface (re-bound onto harness.jac as mcp_oauth_*) ────────────────
# node calls these off the serialized routine queue (server/jac-mcp-oauth.ts),
# so they may run concurrently; everything above is lock-guarded.

def _guard(omb_token: any) -> any {
    want = os.environ.get("OMB_JAC_TOKEN");
    if want and omb_token != want {
        return {"ok": False, "status": 403, "error": "unauthorized"};
    }
    return None;
}

def _invoke(omb_token: any, fn: any, fallback_status: int = 500) -> any {
    g = _guard(omb_token);
    if g is not None { return g; }
    try {
        return fn();
    } except Exception as e {
        st = getattr(e, "status", None);
        if not isinstance(st, int) or isinstance(st, bool) { st = fallback_status; }
        out: dict[str, any] = {"ok": False, "status": st, "error": str(e)};
        code = getattr(e, "code", None);
        if isinstance(code, str) { out["code"] = code; }
        return out;
    }
}

# Optional kwargs: the fused jacup binary binds the stringified default when
# a request omits one, so every optional arg is type-checked before use (the
# facade always sends every key).
def _opt_str(v: any) -> any {
    return v if isinstance(v, str) else None;
}

def _owner_arg(v: any) -> str {
    return v if isinstance(v, str) and v else "loopback";
}

def:pub mcp_oauth_states(omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"states": mo_states()}; }
    return _invoke(omb_token, _go);
}

def:pub mcp_oauth_start(name: str, url: str, owner: any = None, www_authenticate: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return {"auth": start(name, url, _opt_str(www_authenticate), _owner_arg(owner))};
    }
    return _invoke(omb_token, _go, 502);
}

def:pub mcp_oauth_status(name: str, flow_id: str, owner: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"auth": status(name, flow_id, _owner_arg(owner))}; }
    return _invoke(omb_token, _go);
}

def:pub mcp_oauth_cancel_flow(name: str, owner: any = None, flow_id: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        cancel_flow(name, _owner_arg(owner), _opt_str(flow_id));
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

def:pub mcp_oauth_complete(name: str, flow_id: str, callback_url: any = None, owner: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return {"auth": complete_callback(name, flow_id, callback_url, _owner_arg(owner))};
    }
    return _invoke(omb_token, _go);
}

def:pub mcp_oauth_revoke_owner(owner: str, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        revoke_owner(owner);
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

def:pub mcp_oauth_sign_out(name: str, url: str, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        sign_out(name, url);
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

def:pub mcp_oauth_forget(name: str, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        forget(name);
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

def:pub mcp_oauth_mark_needs_sign_in(name: str, url: str, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        mark_needs_sign_in(name, url);
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

def:pub mcp_oauth_with_sign_in(servers: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return {"servers": with_mcp_sign_in(servers if isinstance(servers, dict) else {})};
    }
    return _invoke(omb_token, _go);
}

def:pub mcp_oauth_discover(url: str, www_authenticate: any = None, timeout_ms: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        limit: any = None;
        if _is_number(timeout_ms) and timeout_ms > 0 { limit = timeout_ms / 1000.0; }
        return {"meta": discover_mcp_auth(url, _opt_str(www_authenticate), limit)};
    }
    return _invoke(omb_token, _go);
}

def:pub mcp_oauth_dispose(omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        dispose();
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

with entry {
    _reset();
}
