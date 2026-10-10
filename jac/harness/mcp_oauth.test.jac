"""Ported invariants from server/mcp-oauth.test.ts, mcp-oauth-store.test.ts
and mcp-oauth-discovery.test.ts.

Annexes mcp_oauth.jac (no self-import). server/testing/fake-oauth-server.ts
and fake-http-mcp-server.ts are re-done here as tiny threaded http.server
fakes with the same options; the browser is a urllib opener (following the
approval redirect, or not, to read the callback URL to paste). Promise.all
races become threads; the TS barriers (beforeRegister / beforeToken) are
threading.Events.
"""

import os;
import json;
import stat;
import time;
import shutil;
import socket;
import base64;
import hashlib;
import secrets;
import tempfile;
import threading;
import urllib.error;
import urllib.parse;
import urllib.request;
import http.client;
import from http.server { BaseHTTPRequestHandler, ThreadingHTTPServer }

glob T: dict[str, any] = {};
glob _BROWSER: any = urllib.request.build_opener(urllib.request.ProxyHandler({}));

# ── fakes ──────────────────────────────────────────────────────────────────

def _serve(handler_attrs: dict[str, any]) -> any {
    def _quiet(h: any, *args: any) {
        return;
    }
    attrs = dict(handler_attrs);
    attrs["log_message"] = _quiet;
    handler = type("FakeHandler", (BaseHTTPRequestHandler, ), attrs);
    srv = ThreadingHTTPServer(("127.0.0.1", 0), handler);
    srv.daemon_threads = True;
    threading.Thread(target=srv.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start();
    return srv;
}

def _reply(h: any, code: int, body: any, headers: any = None) {
    data = b"";
    if body is not None { data = json.dumps(body).encode("utf-8"); }
    h.send_response(code);
    if body is not None { h.send_header("content-type", "application/json"); }
    for (k, v) in (headers or {}).items() { h.send_header(k, v); }
    h.send_header("Content-Length", str(len(data)));
    h.send_header("Connection", "close");
    h.end_headers();
    h.wfile.write(data);
    h.close_connection = True;
}

def _read_body(h: any) -> str {
    n = int(h.headers.get("Content-Length") or "0");
    return h.rfile.read(n).decode("utf-8") if n > 0 else "";
}

def _decode_form(v: str) -> str {
    return urllib.parse.unquote(v.replace("+", " "));
}

def _start_fake_oauth(options: dict[str, any]) -> dict[str, any] {
    fake: dict[str, any] = {
        "options": options, "codes": {}, "access": set(), "refresh": set(), "clients": set(),
        "counts": {"register": 0, "token": 0, "refresh": 0, "revoke": 0},
        "client_auths": [], "last_authorize": None, "issuer": "",
    };
    pre: dict[str, any] = options.get("pre_registered") or {};

    # The client a token request authenticates as, or None when its secret is
    # missing or wrong (RFC 6749 §2.3: one method per request).
    def _authenticate(h: any, form: dict[str, any]) -> any {
        header = h.headers.get("Authorization") or "";
        auth: dict[str, any] = {};
        secret: any = None;
        if header.startswith("Basic ") {
            decoded = base64.b64decode(header[6:]).decode("utf-8");
            parts = decoded.split(":");
            if "client_secret" in form { return None; }
            auth = {"method": "basic", "clientId": _decode_form(parts[0])};
            secret = _decode_form(parts[1] if len(parts) > 1 else "");
        } elif "client_secret" in form {
            auth = {"method": "post", "clientId": form.get("client_id", "")};
            secret = form["client_secret"];
        } else {
            auth = {"method": "none", "clientId": form.get("client_id", "")};
        }
        fake["client_auths"].append(auth);
        cid = auth["clientId"];
        if cid in pre {
            want = pre[cid];
            if want is None { return cid if secret is None else None; }
            return cid if secret == want else None;
        }
        return cid if cid in fake["clients"] and secret is None else None;
    }

    def _issue -> dict[str, any] {
        token = "at_" + secrets.token_hex(12);
        refresh_token = "rt_" + secrets.token_hex(12);
        fake["access"].add(token);
        fake["refresh"].add(refresh_token);
        expires = options.get("expires_in");
        if expires is None { expires = 3600; }
        return {"access_token": token, "token_type": "Bearer", "expires_in": expires, "refresh_token": refresh_token, "scope": "mcp"};
    }
    fake["mint"] = _issue;

    def _get(h: any) {
        u = urllib.parse.urlsplit(h.path);
        issuer = fake["issuer"];
        if u.path.startswith("/.well-known/oauth-protected-resource") {
            _reply(h, 200, {"resource": issuer + "/mcp", "authorization_servers": [issuer], "scopes_supported": ["mcp"]});
            return;
        }
        if u.path == "/.well-known/oauth-authorization-server" {
            meta: dict[str, any] = {
                "issuer": options.get("claim_issuer") or issuer,
                "authorization_endpoint": issuer + "/authorize",
                "token_endpoint": issuer + "/token",
            };
            if not options.get("no_registration") { meta["registration_endpoint"] = issuer + "/register"; }
            meta["revocation_endpoint"] = issuer + "/revoke";
            meta["code_challenge_methods_supported"] = ["S256"];
            if options.get("token_auth_methods") { meta["token_endpoint_auth_methods_supported"] = options["token_auth_methods"]; }
            _reply(h, 200, meta);
            return;
        }
        if u.path == "/authorize" {
            q = dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True));
            fake["last_authorize"] = q;
            ru = urllib.parse.urlsplit(q.get("redirect_uri", ""));
            back = urllib.parse.parse_qsl(ru.query, keep_blank_values=True);
            back.append(("state", q.get("state", "")));
            cid = q.get("client_id", "");
            if cid not in fake["clients"] and cid not in pre {
                back.append(("error", "unauthorized_client"));
            } elif options.get("deny") {
                back.append(("error", "access_denied"));
            } else {
                code = "code_" + secrets.token_hex(8);
                fake["codes"][code] = {"challenge": q.get("code_challenge", ""), "clientId": cid, "redirectUri": q.get("redirect_uri", "")};
                back.append(("code", code));
            }
            loc = urllib.parse.urlunsplit((ru.scheme, ru.netloc, ru.path, urllib.parse.urlencode(back), ""));
            _reply(h, 302, None, {"location": loc});
            return;
        }
        _reply(h, 404, None);
    }

    def _post(h: any) {
        u = urllib.parse.urlsplit(h.path);
        raw = _read_body(h);
        if u.path == "/register" {
            fake["counts"]["register"] += 1;
            hook = options.get("before_register");
            if hook is not None { hook(); }
            body = json.loads(raw);
            cid = "client_" + str(fake["counts"]["register"]);
            fake["clients"].add(cid);
            _reply(h, 201, {"client_id": cid, "redirect_uris": body.get("redirect_uris")});
            return;
        }
        form = dict(urllib.parse.parse_qsl(raw, keep_blank_values=True));
        if u.path == "/token" {
            if options.get("token_delay_ms") { time.sleep(options["token_delay_ms"] / 1000.0); }
            client = _authenticate(h, form);
            if client is None {
                _reply(h, 401, {"error": "invalid_client"});
                return;
            }
            if form.get("grant_type") == "authorization_code" {
                fake["counts"]["token"] += 1;
                hook = options.get("before_token");
                if hook is not None { hook(); }
                issued = fake["codes"].pop(form.get("code", ""), None);
                verifier = form.get("code_verifier", "");
                challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).decode("ascii").rstrip("=");
                good = issued is not None and issued["clientId"] == client and issued["redirectUri"] == form.get("redirect_uri") and challenge == issued["challenge"];
                if good { _reply(h, 200, _issue()); } else { _reply(h, 400, {"error": "invalid_grant"}); }
                return;
            }
            if form.get("grant_type") == "refresh_token" {
                fake["counts"]["refresh"] += 1;
                if options.get("refresh_delay_ms") { time.sleep(options["refresh_delay_ms"] / 1000.0); }
                if options.get("refresh_status") {
                    _reply(h, options["refresh_status"], {"error": "slow_down"});
                    return;
                }
                token = form.get("refresh_token", "");
                if options.get("reject_refresh") or token not in fake["refresh"] {
                    _reply(h, 400, {"error": "invalid_grant"});
                    return;
                }
                fake["refresh"].discard(token);
                _reply(h, 200, _issue());
                return;
            }
            _reply(h, 400, {"error": "unsupported_grant_type"});
            return;
        }
        if u.path == "/revoke" {
            fake["counts"]["revoke"] += 1;
            if _authenticate(h, form) is None {
                _reply(h, 401, {"error": "invalid_client"});
                return;
            }
            fake["access"].discard(form.get("token", ""));
            fake["refresh"].discard(form.get("token", ""));
            _reply(h, 200, None);
            return;
        }
        _reply(h, 404, None);
    }

    srv = _serve({"do_GET": _get, "do_POST": _post});
    issuer = "http://127.0.0.1:" + str(srv.server_address[1]);
    fake.update({
        "server": srv,
        "issuer": issuer,
        "challenge": "Bearer resource_metadata=\"" + issuer + "/.well-known/oauth-protected-resource\"",
    });
    return fake;
}

def _is_valid(fake: dict[str, any], authorization: any) -> bool {
    return isinstance(authorization, str) and authorization.startswith("Bearer ") and authorization[7:] in fake["access"];
}

def _start_fake_mcp(oauth: any) -> dict[str, any] {
    mcp: dict[str, any] = {"seen": []};
    def _post(h: any) {
        raw = _read_body(h);
        mcp["seen"].append(dict(h.headers));
        if oauth is not None and not _is_valid(oauth, h.headers.get("Authorization")) {
            _reply(h, 401, {"error": "unauthorized"}, {"www-authenticate": oauth["challenge"]});
            return;
        }
        frame = json.loads(raw or "{}");
        _reply(h, 200, {"jsonrpc": "2.0", "id": frame.get("id"), "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}}}, {"mcp-session-id": "fake-session"});
    }
    def _get(h: any) {
        _reply(h, 404, None);
    }
    srv = _serve({"do_GET": _get, "do_POST": _post});
    mcp.update({"server": srv, "url": "http://127.0.0.1:" + str(srv.server_address[1]) + "/mcp"});
    return mcp;
}

def _close(srv: any) {
    try {
        srv.shutdown();
        srv.server_close();
    } except Exception { }
}

# ── harness ────────────────────────────────────────────────────────────────

def _teardown {
    if _mo.get("flows") is not None { dispose(); }
    for key in ["mcp", "oauth", "extra"] {
        fake = T.get(key);
        if fake is not None { _close(fake["server"]); }
        T[key] = None;
    }
    d = T.get("dir");
    if d { shutil.rmtree(d, ignore_errors=True); }
}

def _fresh_manager(lifetime_ms: int = 0) {
    def _clients_hook(name: str, url: str) -> any {
        mcp = T.get("mcp");
        if name == "docs" and mcp is not None and url == mcp["url"] { return T.get("registered"); }
        return None;
    }
    def _live_hook(owner: str) -> bool {
        return T["live"](owner);
    }
    def _emit_hook(payload: dict[str, any]) { T["emitted"].append(payload); }
    _reset();
    _mo.update({
        "file": T["file"],
        "hooks": {"clients": _clients_hook, "owner_live": _live_hook, "emit": _emit_hook},
    });
    if lifetime_ms > 0 { _mo.update({"lifetime_ms": lifetime_ms}); }
}

def _always_live(owner: str) -> bool { return True; }

def _setup(options: any = None, lifetime_ms: int = 0) -> dict[str, any] {
    _teardown();
    d = tempfile.mkdtemp(prefix="mcp-oauth-");
    T.update({
        "dir": d, "file": os.path.join(d, "mcp-oauth.json"), "registered": None,
        "live": _always_live, "emitted": [],
    });
    oauth = _start_fake_oauth(options or {});
    T["oauth"] = oauth;
    T["mcp"] = _start_fake_mcp(oauth);
    _fresh_manager(lifetime_ms);
    return T;
}

def _mcp_url -> str { return T["mcp"]["url"]; }
def _counts -> dict[str, any] { return T["oauth"]["counts"]; }

# What the person's browser does: open the link, follow the approval
# redirect back to the loopback callback. Raises when nothing listens.
def _approve(st: dict[str, any]) -> dict[str, any] {
    try {
        resp = _BROWSER.open(st["authorizationUrl"], timeout=10);
        return {"status": resp.status, "text": resp.read().decode("utf-8")};
    } except urllib.error.HTTPError as e {
        return {"status": e.code, "text": e.read().decode("utf-8")};
    }
}

def _get_status(url: str) -> int {
    try {
        resp = _BROWSER.open(url, timeout=10);
        return resp.status;
    } except urllib.error.HTTPError as e {
        return e.code;
    }
}

# The approval's Location header: the URL a person pastes from elsewhere.
def _redirect(st: dict[str, any]) -> any {
    conn_url = urllib.parse.urlsplit(st["authorizationUrl"]);
    c = http.client.HTTPConnection(conn_url.hostname, conn_url.port, timeout=10);
    c.request("GET", conn_url.path + "?" + conn_url.query);
    r = c.getresponse();
    loc = r.getheader("location");
    c.close();
    return loc;
}

def _settled(name: str, flow_id: str) -> dict[str, any] {
    for i in range(200) {
        st = status(name, flow_id);
        if st is not None and st["phase"] != "waiting" { return st; }
        time.sleep(0.02);
    }
    raise Exception("sign-in never settled");
}

def _sign_in(owner: str = "loopback") -> dict[str, any] {
    started = start("docs", _mcp_url(), None, owner);
    _approve(started);
    return _settled("docs", started["flowId"]);
}

def _raised(fn: any) -> any {
    try {
        fn();
    } except Exception as e {
        return e;
    }
    return None;
}

def _status_of_error(e: any) -> any {
    return getattr(e, "status", None);
}

def _in_thread(fn: any) -> dict[str, any] {
    box: dict[str, any] = {"result": None, "error": None};
    def _run {
        try {
            box["result"] = fn();
        } except Exception as e {
            box["error"] = e;
        }
    }
    t = threading.Thread(target=_run, daemon=True);
    box["thread"] = t;
    t.start();
    return box;
}

def _join(box: dict[str, any]) -> dict[str, any] {
    box["thread"].join(20);
    return box;
}

def _poll(fn: any, want: any) -> bool {
    for i in range(200) {
        if fn() == want { return True; }
        time.sleep(0.02);
    }
    return False;
}

# ── store (mcp-oauth-store.test.ts) ────────────────────────────────────────

glob URL_A: str = "https://mcp.example.com/mcp";

def _store_only -> str {
    _teardown();
    d = tempfile.mkdtemp(prefix="mcp-oauth-store-");
    T.update({"dir": d, "file": os.path.join(d, "mcp-oauth.json"), "live": _always_live, "emitted": [], "registered": None});
    _fresh_manager();
    return T["file"];
}

test "store writes an owner-only file and reads a record back" {
    file = _store_only();
    store_put("docs", {"url": URL_A, "state": "signed-in", "clientId": "c1", "tokens": {"access": "at", "refresh": "rt", "expiresAt": 5}});
    if os.name != "nt" { assert stat.S_IMODE(os.stat(file).st_mode) == 0o600; }
    _fresh_manager();
    assert store_get("docs", URL_A) == {"url": URL_A, "state": "signed-in", "clientId": "c1", "tokens": {"access": "at", "refresh": "rt", "expiresAt": 5}};
}

test "store does not hand a record to a different URL" {
    _store_only();
    store_put("docs", {"url": URL_A, "state": "signed-in", "tokens": {"access": "at"}});
    assert store_get("docs", "https://evil.example.com/mcp") is None;
}

test "store deletes a record" {
    _store_only();
    store_put("docs", {"url": URL_A, "state": "needs-sign-in"});
    store_delete("docs");
    assert store_get("docs", URL_A) is None;
}

test "store reads a corrupt file as empty and leaves it until the next write" {
    file = _store_only();
    with open(file, "w") as f { f.write("{not json"); }
    assert store_get("docs", URL_A) is None;
    with open(file) as f { assert f.read() == "{not json"; }
    store_put("docs", {"url": URL_A, "state": "needs-sign-in"});
    assert store_get("docs", URL_A)["state"] == "needs-sign-in";
}

test "store writes zod's key order and strips unknown keys, byte-for-byte" {
    file = _store_only();
    with open(file, "w") as f {
        f.write(json.dumps({"extra": 1, "servers": {"docs": {"tokens": {"scope": "s", "access": "a", "x": 1}, "state": "signed-in", "zz": 1, "url": URL_A}}}));
    }
    store_put("other", {"url": "https://o.example/mcp", "state": "needs-sign-in"});
    with open(file) as f { text = f.read(); }
    assert text == "{\n  \"servers\": {\n    \"docs\": {\n      \"url\": \"https://mcp.example.com/mcp\",\n      \"state\": \"signed-in\",\n      \"tokens\": {\n        \"access\": \"a\",\n        \"scope\": \"s\"\n      }\n    },\n    \"other\": {\n      \"url\": \"https://o.example/mcp\",\n      \"state\": \"needs-sign-in\"\n    }\n  }\n}";
    # one invalid record empties the whole file, like zod's safeParse
    with open(file, "w") as f { f.write(json.dumps({"servers": {"a": {"url": "u", "state": "x"}}})); }
    assert mo_states() == {};
}

test "store changes reach node's mirror as mcp.oauth frames" {
    _store_only();
    store_put("docs", {"url": URL_A, "state": "signed-in", "tokens": {"access": "at"}});
    mark_needs_sign_in("docs", URL_A);
    store_delete("docs");
    store_delete("docs");
    assert T["emitted"] == [
        {"kind": "mcp.oauth", "name": "docs", "url": URL_A, "auth": "signed-in"},
        {"kind": "mcp.oauth", "name": "docs", "url": URL_A, "auth": "needs-sign-in"},
        {"kind": "mcp.oauth", "name": "docs", "url": None, "auth": "none"},
    ];
}

# ── discovery (mcp-oauth-discovery.test.ts) ────────────────────────────────

glob AS: dict[str, any] = {
    "issuer": "https://auth.example.com",
    "authorization_endpoint": "https://auth.example.com/authorize",
    "token_endpoint": "https://auth.example.com/token",
    "registration_endpoint": "https://auth.example.com/register",
    "revocation_endpoint": "https://auth.example.com/revoke",
    "code_challenge_methods_supported": ["S256"],
};

def _with(base: dict[str, any], extra: dict[str, any]) -> dict[str, any] {
    out = dict(base);
    out.update(extra);
    return out;
}

# A fetch that answers JSON for known URLs and 404 for everything else, and
# records what was asked.
def _stub_fetch(routes: dict[str, any]) -> dict[str, any] {
    asked: list[str] = [];
    def _impl(url: str) -> dict[str, any] {
        asked.append(url);
        if url not in routes { return {"status": 404, "text": "not found"}; }
        return {"status": 200, "text": json.dumps(routes[url])};
    }
    return {"impl": _impl, "asked": asked};
}

test "resourceMetadataUrl reads resource_metadata from a Bearer challenge" {
    assert resource_metadata_url("Bearer error=\"invalid_token\", resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\"") == "https://mcp.example.com/.well-known/oauth-protected-resource";
}

test "resourceMetadataUrl returns null without the parameter" {
    assert resource_metadata_url("Bearer realm=\"x\"") is None;
    assert resource_metadata_url(None) is None;
}

test "discover follows the header hint to the authorization server" {
    s = _stub_fetch({
        "https://mcp.example.com/prm": {"resource": "https://mcp.example.com/mcp", "authorization_servers": ["https://auth.example.com"], "scopes_supported": ["read", "write"]},
        "https://auth.example.com/.well-known/oauth-authorization-server": AS,
    });
    meta = discover_mcp_auth("https://mcp.example.com/mcp", "Bearer resource_metadata=\"https://mcp.example.com/prm\"", None, s["impl"]);
    assert meta == {
        "issuer": "https://auth.example.com",
        "authorizationEndpoint": "https://auth.example.com/authorize",
        "tokenEndpoint": "https://auth.example.com/token",
        "registrationEndpoint": "https://auth.example.com/register",
        "revocationEndpoint": "https://auth.example.com/revoke",
        "scopes": ["read", "write"],
        "resource": "https://mcp.example.com/mcp",
    };
    assert list(meta.keys()) == ["issuer", "authorizationEndpoint", "tokenEndpoint", "registrationEndpoint", "revocationEndpoint", "scopes", "resource"];
}

test "discover falls back to the well-known protected-resource path, then the origin" {
    s = _stub_fetch({
        "https://mcp.example.com/.well-known/oauth-protected-resource": {"authorization_servers": ["https://auth.example.com"]},
        "https://auth.example.com/.well-known/oauth-authorization-server": AS,
    });
    meta = discover_mcp_auth("https://mcp.example.com/mcp", None, None, s["impl"]);
    assert meta["issuer"] == "https://auth.example.com";
    assert s["asked"][0] == "https://mcp.example.com/.well-known/oauth-protected-resource/mcp";
}

test "discover treats the MCP origin as the authorization server when there is no resource metadata" {
    s = _stub_fetch({
        "https://mcp.example.com/.well-known/openid-configuration": _with(AS, {"issuer": "https://mcp.example.com"}),
    });
    meta = discover_mcp_auth("https://mcp.example.com/mcp", None, None, s["impl"]);
    assert meta["issuer"] == "https://mcp.example.com";
}

test "discover refuses an authorization server without PKCE S256" {
    s = _stub_fetch({
        "https://mcp.example.com/.well-known/oauth-protected-resource": {"authorization_servers": ["https://auth.example.com"]},
        "https://auth.example.com/.well-known/oauth-authorization-server": _with(AS, {"code_challenge_methods_supported": ["plain"]}),
    });
    assert discover_mcp_auth("https://mcp.example.com/mcp", None, None, s["impl"]) is None;
}

test "discover refuses plain-http endpoints on a non-loopback host" {
    s = _stub_fetch({
        "https://mcp.example.com/.well-known/oauth-protected-resource": {"authorization_servers": ["http://auth.example.com"]},
    });
    assert discover_mcp_auth("https://mcp.example.com/mcp", None, None, s["impl"]) is None;
}

test "discover returns null when nothing answers" {
    s = _stub_fetch({});
    assert discover_mcp_auth("https://mcp.example.com/mcp", None, None, s["impl"]) is None;
}

test "isAllowedAuthUrl allows https anywhere and http only on loopback" {
    assert is_allowed_auth_url("https://auth.example.com/x");
    assert is_allowed_auth_url("http://127.0.0.1:5000/x");
    assert is_allowed_auth_url("http://localhost:5000/x");
    assert not is_allowed_auth_url("http://auth.example.com/x");
    assert not is_allowed_auth_url("https://user:pw@auth.example.com/x");
    assert not is_allowed_auth_url("javascript:alert(1)");
}

test "redirect URI port matches the TS FNV-1a over UTF-16 units" {
    # vectors computed with the deleted TS preferredPort (node)
    assert preferred_port("https://mcp.example.com/mcp") == 25934;
    assert preferred_port("http://127.0.0.1:4321/mcp?v=2") == 30995;
    assert preferred_port("https://ü.example/😀") == 20690;
    assert mcp_oauth_redirect_uri("https://mcp.example.com/mcp") == "http://127.0.0.1:25934/mcp-oauth/callback";
    assert _form_enc("s3cret:with/odd+chars ~*") == "s3cret%3Awith%2Fodd%2Bchars+%7E*";
}

# ── sign-in (mcp-oauth.test.ts) ────────────────────────────────────────────

test "signs in through the browser and returns a working token" {
    _setup();
    assert auth_state("docs", _mcp_url()) == "none";
    started = start("docs", _mcp_url());
    assert started["phase"] == "waiting";
    link = urllib.parse.urlsplit(started["authorizationUrl"]);
    q = dict(urllib.parse.parse_qsl(link.query));
    assert link.scheme + "://" + link.netloc + link.path == T["oauth"]["issuer"] + "/authorize";
    assert q["code_challenge_method"] == "S256";
    assert q["resource"] == _mcp_url();
    assert q["redirect_uri"].startswith("http://127.0.0.1:") and q["redirect_uri"].endswith("/mcp-oauth/callback");
    page = _approve(started);
    assert page["status"] == 200;
    assert "Signed in" in page["text"];
    assert _settled("docs", started["flowId"])["phase"] == "succeeded";
    assert auth_state("docs", _mcp_url()) == "signed-in";
    token = access_token("docs", _mcp_url());
    assert _is_valid(T["oauth"], "Bearer " + token);
    _teardown();
}

test "reuses the waiting flow when sign-in is started twice" {
    _setup();
    def _go -> any { return start("docs", _mcp_url()); }
    a = _in_thread(_go);
    b = _in_thread(_go);
    _join(a);
    _join(b);
    assert a["result"]["flowId"] == b["result"]["flowId"];
    assert _counts()["register"] == 1;
    _teardown();
}

test "rejects a callback with the wrong state and keeps waiting" {
    _setup();
    started = start("docs", _mcp_url());
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(started["authorizationUrl"]).query));
    forged = q["redirect_uri"] + "?" + urllib.parse.urlencode({"state": "forged", "code": "stolen"});
    assert _get_status(forged) == 400;
    assert status("docs", started["flowId"])["phase"] == "waiting";
    _teardown();
}

test "expires a sign-in nobody finishes and closes its listener" {
    _setup(None, 100);
    started = start("docs", _mcp_url());
    assert _settled("docs", started["flowId"])["phase"] == "expired";
    def _go { _approve(started); }
    assert _raised(_go) is not None;
    _teardown();
}

test "reports a denied sign-in" {
    _setup({"deny": True});
    started = start("docs", _mcp_url());
    _approve(started);
    st = _settled("docs", started["flowId"]);
    assert st["phase"] == "failed";
    assert "not approved" in st["message"];
    assert auth_state("docs", _mcp_url()) == "none";
    _teardown();
}

test "explains a server that offers no client registration" {
    _setup({"no_registration": True});
    def _go { start("docs", _mcp_url()); }
    e = _raised(_go);
    assert getattr(e, "code", None) == "no-registration";
    _teardown();
}

test "refuses a server that does not use OAuth" {
    _setup();
    open_mcp = _start_fake_mcp(None);
    T["extra"] = open_mcp;
    def _go { start("open", open_mcp["url"]); }
    e = _raised(_go);
    assert isinstance(e, McpOAuthError);
    assert getattr(e, "code", None) == "not-oauth";
    _teardown();
}

# ── tokens ─────────────────────────────────────────────────────────────────

def _signed_in(options: any = None) {
    _setup(options);
    _sign_in();
}

test "refreshes a token about to expire, once for concurrent callers" {
    _signed_in({"expires_in": 60, "refresh_delay_ms": 150});
    def _go -> any { return access_token("docs", _mcp_url()); }
    a = _in_thread(_go);
    b = _in_thread(_go);
    _join(a);
    _join(b);
    assert _counts()["refresh"] == 1;
    assert a["result"] == b["result"];
    assert _is_valid(T["oauth"], "Bearer " + a["result"]);
    _teardown();
}

test "does not refresh a token with time left" {
    _signed_in({"expires_in": 3600});
    access_token("docs", _mcp_url());
    assert _counts()["refresh"] == 0;
    _teardown();
}

test "marks the server as needing sign-in when refresh is refused" {
    _signed_in({"expires_in": 60, "reject_refresh": True});
    assert access_token("docs", _mcp_url()) is None;
    assert auth_state("docs", _mcp_url()) == "needs-sign-in";
    _teardown();
}

test "never hands a token to a different URL" {
    _signed_in();
    assert access_token("docs", "https://elsewhere.example.com/mcp") is None;
    assert auth_state("docs", "https://elsewhere.example.com/mcp") == "none";
    _teardown();
}

test "signs out: revokes and forgets" {
    _signed_in();
    sign_out("docs", _mcp_url());
    assert _counts()["revoke"] > 0;
    assert auth_state("docs", _mcp_url()) == "none";
    assert access_token("docs", _mcp_url()) is None;
    _teardown();
}

test "remembers a server that needs sign-in until it is forgotten" {
    _setup();
    mark_needs_sign_in("docs", _mcp_url());
    assert auth_state("docs", _mcp_url()) == "needs-sign-in";
    forget("docs");
    assert auth_state("docs", _mcp_url()) == "none";
    _teardown();
}

# ── turn servers ───────────────────────────────────────────────────────────

glob STDIO: dict[str, any] = {"command": "npx", "args": ["notes"], "env": {}};

test "leaves out a URL server that needs sign-in, keeps the rest" {
    _setup();
    mark_needs_sign_in("docs", _mcp_url());
    servers = {"docs": {"type": "http", "url": _mcp_url(), "headers": {}}, "notes": STDIO};
    assert without_pending_sign_in(servers) == {"notes": STDIO};
    _teardown();
}

test "sends a signed-in server its bearer token in place of any Authorization header" {
    _setup();
    _sign_in();
    servers = {
        "docs": {"type": "http", "url": _mcp_url(), "headers": {"authorization": "Bearer stale", "X-Org": "acme"}},
        "plain": {"type": "http", "url": "https://plain.example.com/mcp", "headers": {"Authorization": "Bearer mine"}},
        "notes": STDIO,
    };
    out = with_mcp_sign_in(servers);
    token = access_token("docs", _mcp_url());
    assert out["docs"] == {"type": "http", "url": _mcp_url(), "headers": {"X-Org": "acme", "Authorization": "Bearer " + token}};
    assert list(out["docs"]["headers"].keys()) == ["X-Org", "Authorization"];
    assert out["plain"] == servers["plain"];
    assert out["notes"] == STDIO;
    assert servers["docs"]["headers"]["authorization"] == "Bearer stale";
    _teardown();
}

test "drops a signed-in server whose token cannot be refreshed" {
    _setup({"expires_in": 60, "reject_refresh": True});
    _sign_in();
    out = with_mcp_sign_in({"docs": {"type": "http", "url": _mcp_url(), "headers": {}}});
    assert out == {};
    _teardown();
}

# ── review fixes ───────────────────────────────────────────────────────────

test "keeps no tokens when the server is removed while the code is being exchanged" {
    _setup({"token_delay_ms": 150});
    started = start("docs", _mcp_url());
    def _go -> any { return _approve(started); }
    browser = _in_thread(_go);
    time.sleep(0.05);
    forget("docs");
    _join(browser);
    time.sleep(0.05);
    assert auth_state("docs", _mcp_url()) == "none";
    _teardown();
}

test "keeps no tokens when sign-in is cancelled while the code is being exchanged" {
    _setup({"token_delay_ms": 150});
    started = start("docs", _mcp_url());
    def _go -> any { return _approve(started); }
    browser = _in_thread(_go);
    time.sleep(0.05);
    cancel("docs");
    _join(browser);
    assert status("docs", started["flowId"])["phase"] == "cancelled";
    assert auth_state("docs", _mcp_url()) == "none";
    _teardown();
}

test "does not expire a sign-in whose code is already being exchanged" {
    _setup({"token_delay_ms": 200}, 100);
    started = start("docs", _mcp_url());
    _approve(started);
    assert _settled("docs", started["flowId"])["phase"] == "succeeded";
    assert auth_state("docs", _mcp_url()) == "signed-in";
    _teardown();
}

test "stays signed in when a refresh fails for a reason other than a dead grant" {
    _setup({"expires_in": 60, "refresh_status": 429});
    _sign_in();
    token = access_token("docs", _mcp_url());
    assert _is_valid(T["oauth"], "Bearer " + token);
    assert auth_state("docs", _mcp_url()) == "signed-in";
    _teardown();
}

test "registers a fresh client for every sign-in" {
    _setup();
    _sign_in();
    _sign_in();
    assert _counts()["register"] == 2;
    _teardown();
}

test "refuses metadata that claims another issuer" {
    _setup({"claim_issuer": "https://someone-else.example.com"});
    def _go { start("docs", _mcp_url()); }
    assert getattr(_raised(_go), "code", None) == "not-oauth";
    _teardown();
}

# ── a sign-in app registered in advance ────────────────────────────────────

test "signs in as a public app on a server without registration, with its own scopes" {
    _setup({"no_registration": True, "pre_registered": {"entra-app": None}});
    T["registered"] = {"clientId": "entra-app", "scopes": ["api://mcp/read", "offline_access"]};
    started = start("docs", _mcp_url());
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(started["authorizationUrl"]).query));
    assert q["client_id"] == "entra-app";
    assert q["scope"] == "api://mcp/read offline_access";
    assert q["redirect_uri"] == mcp_oauth_redirect_uri(_mcp_url());
    _approve(started);
    assert _settled("docs", started["flowId"])["phase"] == "succeeded";
    assert _counts()["register"] == 0;
    assert T["oauth"]["client_auths"] == [{"method": "none", "clientId": "entra-app"}];
    assert _is_valid(T["oauth"], "Bearer " + access_token("docs", _mcp_url()));
    _teardown();
}

test "uses the app in place of registration even when the server offers it" {
    _setup({"pre_registered": {"mine": None}});
    T["registered"] = {"clientId": "mine"};
    assert _sign_in()["phase"] == "succeeded";
    assert _counts()["register"] == 0;
    # no scopes of its own: the server's advertised ones
    assert T["oauth"]["last_authorize"]["scope"] == "mcp";
    _teardown();
}

test "proves a secret with HTTP Basic by default, on sign-in, refresh and sign-out, and never stores it" {
    secret = "s3cret:with/odd+chars";
    _setup({"no_registration": True, "expires_in": 60, "pre_registered": {"corp": secret}});
    T["registered"] = {"clientId": "corp", "clientSecret": secret};
    assert _sign_in()["phase"] == "succeeded";
    token = access_token("docs", _mcp_url());
    assert _counts()["refresh"] == 1;
    assert _is_valid(T["oauth"], "Bearer " + token);
    sign_out("docs", _mcp_url());
    assert _counts()["revoke"] == 1;
    basic = {"method": "basic", "clientId": "corp"};
    assert T["oauth"]["client_auths"] == [basic, basic, basic];
    assert "client_secret" not in T["oauth"]["last_authorize"];
    _teardown();
}

test "sends the secret in the form when the server only takes that" {
    secret = "app-secret-never-stored";
    _setup({"no_registration": True, "pre_registered": {"corp": secret}, "token_auth_methods": ["client_secret_post"]});
    T["registered"] = {"clientId": "corp", "clientSecret": secret};
    assert _sign_in()["phase"] == "succeeded";
    assert T["oauth"]["client_auths"] == [{"method": "post", "clientId": "corp"}];
    with open(T["file"]) as f { stored = f.read(); }
    assert secret not in stored;
    rec = json.loads(stored)["servers"]["docs"];
    assert rec["clientId"] == "corp" and rec["tokenAuth"] == "client_secret_post";
    assert list(rec.keys()) == ["url", "state", "issuer", "clientId", "tokenAuth", "redirectUri", "tokenEndpoint", "revocationEndpoint", "tokens"];
    _teardown();
}

test "reports a refused secret as a failed sign-in" {
    _setup({"no_registration": True, "pre_registered": {"corp": "right"}});
    T["registered"] = {"clientId": "corp", "clientSecret": "wrong"};
    assert _sign_in()["phase"] == "failed";
    assert auth_state("docs", _mcp_url()) == "none";
    _teardown();
}

test "does not refresh with a secret once the app is no longer configured" {
    _setup({"no_registration": True, "expires_in": 60, "pre_registered": {"corp": "pw"}});
    T["registered"] = {"clientId": "corp", "clientSecret": "pw"};
    _sign_in();
    T["registered"] = {"clientId": "another-app", "clientSecret": "pw"};
    # still valid for a minute: kept, but nothing is sent on another app's behalf
    assert _is_valid(T["oauth"], "Bearer " + access_token("docs", _mcp_url()));
    assert _counts()["refresh"] == 0;
    _teardown();
}

test "explains a busy redirect port instead of moving to another one" {
    _setup({"no_registration": True, "pre_registered": {"corp": None}});
    T["registered"] = {"clientId": "corp"};
    blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM);
    try {
        blocker.bind(("127.0.0.1", preferred_port(_mcp_url())));
        blocker.listen(1);
    } except Exception { }
    try {
        def _go { start("docs", _mcp_url()); }
        assert getattr(_raised(_go), "code", None) == "port-busy";
    } finally {
        blocker.close();
    }
    _teardown();
}

# ── MCP sign-in from another computer ──────────────────────────────────────

test "completes a pre-registered none/basic/post app remotely and retains its refresh authentication" {
    for method in ["none", "basic", "post"] {
        secret: any = None;
        if method != "none" { secret = "private-client-secret"; }
        options: dict[str, any] = {"no_registration": True, "expires_in": 60, "pre_registered": {"corp": secret}};
        if method == "post" { options["token_auth_methods"] = ["client_secret_post"]; }
        _setup(options);
        reg: dict[str, any] = {"clientId": "corp", "scopes": ["mcp", "offline_access"]};
        if secret { reg["clientSecret"] = secret; }
        T["registered"] = reg;
        started = start("docs", _mcp_url(), None, "alice");
        callback = _redirect(started);
        def _bob { complete_callback("docs", started["flowId"], callback, "bob"); }
        assert _status_of_error(_raised(_bob)) == 404;
        assert complete_callback("docs", started["flowId"], callback, "alice")["phase"] == "succeeded";
        assert _counts()["register"] == 0;
        assert _is_valid(T["oauth"], "Bearer " + access_token("docs", _mcp_url()));
        assert _counts()["refresh"] == 1;
        sign_out("docs", _mcp_url());
        one = {"method": method, "clientId": "corp"};
        assert T["oauth"]["client_auths"] == [one, one, one];
        assert _counts()["revoke"] == 1;
    }
    _teardown();
}

test "completes a pasted redirect with PKCE, without visiting the loopback listener" {
    _setup();
    started = start("docs", _mcp_url(), None, "alice");
    callback = _redirect(started);
    result = complete_callback("docs", started["flowId"], callback, "alice");
    assert result["phase"] == "succeeded" and result["authorizationUrl"] is None;
    assert _is_valid(T["oauth"], "Bearer " + access_token("docs", _mcp_url()));
    def _again { complete_callback("docs", started["flowId"], callback, "alice"); }
    assert _status_of_error(_raised(_again)) == 409;
    assert _counts()["token"] == 1;
    _teardown();
}

test "isolates starts, status, cancellation and completion by owner" {
    entered = threading.Event();
    release = threading.Event();
    def _before_register {
        entered.set();
        release.wait(10);
    }
    _setup({"before_register": _before_register});
    def _alice -> any { return start("docs", _mcp_url(), None, "alice"); }
    starting = _in_thread(_alice);
    entered.wait(10);
    def _bob_start { start("docs", _mcp_url(), None, "bob"); }
    assert _status_of_error(_raised(_bob_start)) == 409;
    release.set();
    _join(starting);
    started = starting["result"];
    callback = _redirect(started);
    assert _status_of_error(_raised(_bob_start)) == 409;
    assert status("docs", started["flowId"], "bob") is None;
    def _bob_cancel { cancel_flow("docs", "bob", started["flowId"]); }
    assert _raised(_bob_cancel) is not None;
    def _bob_complete { complete_callback("docs", started["flowId"], callback, "bob"); }
    assert _status_of_error(_raised(_bob_complete)) == 404;
    assert _counts()["token"] == 0;
    assert complete_callback("docs", started["flowId"], callback, "alice")["phase"] == "succeeded";
    _teardown();
}

test "rejects malformed callbacks without spending the flow or requesting their addresses" {
    _setup();
    started = start("docs", _mcp_url());
    callback = _redirect(started);
    variants = [
        "not a URL", "x" * 16385,
        callback.replace("127.0.0.1", "attacker.example"),
        callback.replace("http:", "https:"),
        callback.replace("127.0.0.1", "user:pass@127.0.0.1"),
        callback.replace("/mcp-oauth/callback", "/other"),
        callback + "#fragment", callback + "&code=duplicate", callback + "&error=access_denied",
        callback + "&iss=https%3A%2F%2Fwrong.example",
    ];
    parts = urllib.parse.urlsplit(callback);
    q = [p for p in urllib.parse.parse_qsl(parts.query, keep_blank_values=True) if p[0] != "state"];
    q.append(("state", "wrong"));
    variants.append(urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, urllib.parse.urlencode(q), "")));
    variants.append(callback.replace(":" + str(parts.port) + "/", ":" + str(parts.port + 1) + "/"));
    for invalid in variants {
        def _go { complete_callback("docs", started["flowId"], invalid); }
        assert _status_of_error(_raised(_go)) == 400, invalid[:80];
        assert status("docs", started["flowId"])["phase"] == "waiting";
    }
    assert _counts()["token"] == 0;
    assert complete_callback("docs", started["flowId"], callback)["phase"] == "succeeded";
    _teardown();
}

test "reports a pasted provider denial without exposing its error description" {
    _setup({"deny": True});
    started = start("docs", _mcp_url());
    result = complete_callback("docs", started["flowId"], _redirect(started) + "&error_description=private");
    assert result["phase"] == "failed" and result["message"] == "Sign-in was not approved.";
    assert "private" not in json.dumps(result);
    assert _counts()["token"] == 0;
    _teardown();
}

test "rejects a pasted callback after cancel / revoke / forget / expire" {
    for action in ["cancel", "revoke", "forget", "expire"] {
        _setup(None, 100 if action == "expire" else 0);
        started = start("docs", _mcp_url());
        callback = _redirect(started);
        if action == "cancel" { cancel_flow("docs", "loopback", started["flowId"]); }
        if action == "revoke" { revoke_owner("loopback"); }
        if action == "forget" { forget("docs"); }
        if action == "expire" {
            def _phase -> any {
                st = status("docs", started["flowId"]);
                return st["phase"] if st is not None else None;
            }
            assert _poll(_phase, "expired");
        }
        def _go { complete_callback("docs", started["flowId"], callback); }
        assert _raised(_go) is not None, action;
        assert _counts()["token"] == 0;
        assert auth_state("docs", _mcp_url()) == "none";
    }
    _teardown();
}

test "checks session expiry even before its revocation event is delivered" {
    _setup();
    flag: dict[str, any] = {"live": True};
    def _live(owner: str) -> bool { return flag["live"]; }
    T["live"] = _live;
    started = start("docs", _mcp_url(), None, "alice");
    callback = _redirect(started);
    flag["live"] = False;
    def _go { complete_callback("docs", started["flowId"], callback, "alice"); }
    assert _status_of_error(_raised(_go)) == 409;
    assert _counts()["token"] == 0;
    _teardown();
}

test "releases a dead owner's waiting flow before accepting another admin's start" {
    _setup();
    flag: dict[str, any] = {"alice": True};
    def _live(owner: str) -> bool { return owner != "alice" or flag["alice"]; }
    T["live"] = _live;
    old = start("docs", _mcp_url(), None, "alice");
    flag["alice"] = False;
    current = start("docs", _mcp_url(), None, "bob");
    assert current["phase"] == "waiting";
    assert current["flowId"] != old["flowId"];
    assert status("docs", current["flowId"], "bob")["phase"] == "waiting";
    assert status("docs", old["flowId"], "alice") is None;
    _teardown();
}

test "does not let an old cancellation cancel a new attempt" {
    _setup();
    old = start("docs", _mcp_url());
    cancel("docs");
    current = start("docs", _mcp_url());
    def _go { cancel_flow("docs", "loopback", old["flowId"]); }
    assert _raised(_go) is not None;
    assert status("docs", current["flowId"])["phase"] == "waiting";
    _teardown();
}

test "revokes a start still waiting for registration" {
    entered = threading.Event();
    release = threading.Event();
    def _before_register {
        entered.set();
        release.wait(10);
    }
    _setup({"before_register": _before_register});
    def _alice -> any { return start("docs", _mcp_url(), None, "alice"); }
    starting = _in_thread(_alice);
    entered.wait(10);
    revoke_owner("alice");
    release.set();
    _join(starting);
    assert _status_of_error(starting["error"]) == 409;
    assert auth_state("docs", _mcp_url()) == "none";
    _teardown();
}

test "spends one code when pasted and listener callbacks race, and discards tokens on logout" {
    entered = threading.Event();
    release = threading.Event();
    def _before_token {
        entered.set();
        release.wait(10);
    }
    _setup({"before_token": _before_token});
    started = start("docs", _mcp_url(), None, "alice");
    callback = _redirect(started);
    def _complete -> any { return complete_callback("docs", started["flowId"], callback, "alice"); }
    completing = _in_thread(_complete);
    entered.wait(10);
    assert _get_status(callback) == 409;
    def _again { complete_callback("docs", started["flowId"], callback, "alice"); }
    assert _status_of_error(_raised(_again)) == 409;
    revoke_owner("alice");
    release.set();
    _join(completing);
    assert _status_of_error(completing["error"]) == 409;
    assert _counts()["token"] == 1;
    assert auth_state("docs", _mcp_url()) == "none";
    def _revokes -> any { return _counts()["revoke"]; }
    assert _poll(_revokes, 1);
    _teardown();
}

test "HTTP surface wraps sign-in errors with their status and code" {
    _setup({"no_registration": True});
    res = mcp_oauth_start("docs", _mcp_url(), "loopback", None);
    assert res["ok"] == False and res["status"] == 400 and res["code"] == "no-registration";
    res = mcp_oauth_status("docs", "nope", "loopback");
    assert res == {"auth": None};
    res = mcp_oauth_cancel_flow("docs", "loopback", None);
    assert res["status"] == 404;
    res = mcp_oauth_with_sign_in({"notes": STDIO});
    assert res == {"servers": {"notes": STDIO}};
    _teardown();
}
