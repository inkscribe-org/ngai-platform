"""Ported invariants from server/composio.test.ts, composio-availability.test.ts,
connector-verdict.test.ts, connector-scope-hint.test.ts and the harness half
of connector-advertisement.test.ts.

Annexes connectors.jac (no self-import). The TS suite's loopback Composio
stub becomes a fake `fetch` hook routing on (method, url) over a per-test
state dict `S`; `calls` records every request exactly like the stub did.
Interceptors model the TS tests' fetch spies on app.composio.dev.
"""

import os;
import re;
import json;
import time;
import base64;
import threading;
import urllib.parse;

glob ORIGIN: str = "http://127.0.0.1:9876";
glob S: dict[str, any] = {};

def _json_res(status: int, body: any, headers: any = None) -> dict[str, any] {
    h: dict[str, any] = {"content-type": "application/json"};
    if isinstance(headers, dict) { h.update(headers); }
    return {"status": status, "headers": h, "body": json.dumps(body).encode("utf-8")};
}

def _qp(query: str) -> dict[str, any] {
    return dict(urllib.parse.parse_qsl(query, keep_blank_values=True));
}

glob CATALOG_KEYS: list[str] = [
    "ak_catalog_pages", "ak_catalog_partial", "ak_catalog_stuck", "ak_catalog_page_stuck",
    "ak_catalog_exhausted", "ak_catalog_stalled_total", "ak_catalog_end_short", "ak_catalog_http_no_total",
];

def _broker_route(method: str, path: str, q: dict[str, any], body: any, headers: dict[str, any]) -> dict[str, any] {
    token = re.sub("^Bearer ", "", str(headers.get("authorization", "")));
    # c/d/e/f back the cache-identity tests; b stays invalid.
    if not re.fullmatch("[acdef]{64}", token) { return _json_res(401, {"error": "invalid broker token"}); }
    if method == "GET" and path == "/broker/v1/connectors" {
        services: dict[str, any] = {};
        for slug in [s for s in q.get("services", "").split(",") if s] {
            services[slug] = {"connected": slug == "github", "status": "ACTIVE" if slug == "github" else "not_connected"};
        }
        return _json_res(200, {"services": services});
    }
    if method == "GET" and path == "/broker/v1/connectors/connected" {
        b = S["broker_connected"];
        if b is None { b = {"services": {"github": {"connected": True, "status": "ACTIVE"}}}; }
        return _json_res(200, b);
    }
    if method == "POST" and path.endswith("/authorize") {
        return _json_res(200, {"url": "https://connect.composio.dev/managed"});
    }
    if method == "DELETE" and path.startswith("/broker/v1/connectors/") { return _json_res(200, {"removed": 1}); }
    if method == "GET" and path == "/broker/v1/catalog" {
        c = S["broker_catalog"];
        if c is None { c = {"items": [{"slug": "github", "name": "GitHub"}]}; }
        return _json_res(200, c);
    }
    if method == "POST" and path == "/broker/v1/mcp" {
        rpc = body.get("method") if isinstance(body, dict) else None;
        if S["broker_tools"] is not None and rpc == "initialize" {
            if S["init_delay"] { time.sleep(S["init_delay"]); }
            return _json_res(200, {"jsonrpc": "2.0", "id": body["id"], "result": {
                "protocolVersion": "2025-03-26", "capabilities": {}, "serverInfo": {"name": "composio-stub", "version": "1"},
            }}, {"mcp-session-id": "mcp_grants"});
        }
        if S["broker_tools"] is not None and rpc == "tools/list" {
            if S["broker_tools_fail"] { return _json_res(500, {"error": {"message": "tools list unavailable"}}); }
            return _json_res(200, {"jsonrpc": "2.0", "id": body["id"], "result": {"tools": S["broker_tools"]}});
        }
        return _json_res(200, {"source": "broker"}, {"mcp-session-id": "mcp_broker"});
    }
    return _json_res(404, {"error": "unknown broker route"});
}

def _catalog_route(api_key: str, q: dict[str, any]) -> dict[str, any] {
    cur = q.get("cursor");
    if api_key == "ak_catalog_stuck" {
        return _json_res(200, {"items": [{"slug": "gmail", "name": "Gmail"}], "next_cursor": "catalog-page-2"});
    }
    if api_key == "ak_catalog_page_stuck" {
        n = int((cur or "catalog-page-1").split("-")[-1]);
        return _json_res(200, {"items": [{"slug": "gmail", "name": "Gmail"}], "next_cursor": "catalog-page-" + str(n + 1), "current_page": 1, "total_pages": 4});
    }
    if api_key == "ak_catalog_exhausted" {
        if cur == "catalog-page-2" {
            return _json_res(200, {"items": [{"slug": "deepgram", "name": "Deepgram"}], "next_cursor": "catalog-page-3", "current_page": 2, "total_pages": 2});
        }
        return _json_res(200, {"items": [{"slug": "gmail", "name": "Gmail"}], "next_cursor": "catalog-page-2", "current_page": 1, "total_pages": 2});
    }
    if api_key == "ak_catalog_stalled_total" {
        return _json_res(200, {"items": [{"slug": "gmail", "name": "Gmail"}], "current_page": 1, "total_pages": 4, "total_items": 1540});
    }
    if api_key == "ak_catalog_end_short" {
        return _json_res(200, {"items": [{"slug": "gmail", "name": "Gmail"}], "current_page": 1, "total_pages": 4});
    }
    head = [{"slug": "gmail", "name": "Gmail"}, {"slug": "bland_ai", "name": "Bland AI"}, {"slug": "currencyscoop", "name": "CurrencyScoop"}];
    if api_key == "ak_catalog_http_no_total" {
        if cur == "catalog-page-2" { return _json_res(502, {"error": "catalog page unavailable"}); }
        return _json_res(200, {"items": head, "next_cursor": "catalog-page-2"});
    }
    if cur == "catalog-page-2" {
        if api_key == "ak_catalog_partial" { return _json_res(502, {"error": "catalog page unavailable"}); }
        return _json_res(200, {"items": [{"slug": "deepgram", "name": "Deepgram"}, {"slug": "zoom", "name": "Zoom"}], "current_page": 2, "total_pages": 2, "total_items": 5});
    }
    return _json_res(200, {"items": head, "next_cursor": "catalog-page-2", "current_page": 1, "total_pages": 2, "total_items": 5});
}

def _project_route(method: str, path: str, q: dict[str, any], body: any, api_key: str) -> dict[str, any] {
    if api_key not in (["ak_test", "ak_catalog_a", "ak_catalog_b"] + CATALOG_KEYS) {
        return _json_res(401, {"error": {"message": "invalid project key"}});
    }
    if method == "POST" and path == "/api/v3.1/tool_router/session" {
        S["session_auth_configs"] = body.get("auth_configs") or {};
        return _json_res(201, {
            "session_id": "trs_test",
            "mcp": {"type": "http", "url": "https://app.composio.dev/tool_router/v3/trs_test/mcp"},
            "config": {"user_id": body["user_id"], "multi_account": body["multi_account"], "auth_configs": S["session_auth_configs"]},
        });
    }
    if method == "GET" and path == "/api/v3/toolkits" and api_key in CATALOG_KEYS { return _catalog_route(api_key, q); }
    if method == "GET" and path == "/api/v3/toolkits" {
        if api_key == "ak_catalog_a" { return _json_res(200, {"items": [{"slug": "notion", "name": "Catalog A"}]}); }
        if api_key == "ak_catalog_b" { return _json_res(200, {"items": [{"slug": "linear", "name": "Catalog B"}]}); }
        return _json_res(200, {"items": [{"slug": "x", "name": "X (Twitter)"}, {"slug": "github", "name": "GitHub"}]});
    }
    if method == "GET" and path == "/api/v3.1/tool_router/session/trs_test" {
        return _json_res(200, {
            "session_id": "trs_test",
            "mcp": {"type": "http", "url": "https://app.composio.dev/tool_router/v3/trs_test/mcp"},
            "config": {
                "user_id": "openmausbot_existing",
                "multi_account": {"enable": True, "max_accounts_per_toolkit": 5, "require_explicit_selection": True},
                "auth_configs": S["session_auth_configs"],
            },
        });
    }
    if method == "GET" and path == "/api/v3.1/auth_configs" { return _json_res(200, {"items": S["custom_auth_configs"]}); }
    if method == "GET" and path == "/api/v3.1/tool_router/session/trs_legacy" {
        return _json_res(200, {
            "session_id": "trs_legacy",
            "mcp": {"type": "http", "url": "https://app.composio.dev/tool_router/v3/trs_legacy/mcp"},
            "config": {"user_id": "openmausbot_legacy"},
        });
    }
    if method == "GET" and path.endswith("/toolkits") {
        if q.get("cursor") == "toolkits-page-2" {
            return _json_res(200, {"items": [
                {"slug": "publicsearch", "is_no_auth": True},
                {"slug": "selectedonly", "connected_account": {"id": "ca_session_only", "status": "ACTIVE"}},
            ]});
        }
        page: dict[str, any] = {"items": [
            {"slug": "github", "connected_account": {"id": "ca_github", "status": "ACTIVE"}},
            {"slug": "gmail", "is_no_auth": True},
            {"slug": "slack"},
            {"slug": "unconnected", "connected_account": None},
        ]};
        if "toolkits" not in q { page["next_cursor"] = "toolkits-page-2"; }
        return _json_res(200, page);
    }
    if method == "GET" and path == "/api/v3.1/connected_accounts" {
        if S["accounts_unavailable"] { return _json_res(403, {"error": "connected-account read not granted"}); }
        if S["accounts_malformed"] { return _json_res(200, {"items": {}}); }
        if S["accounts_empty"] { return _json_res(200, {"items": []}); }
        if S["accounts_override"] is not None { return _json_res(200, {"items": S["accounts_override"]}); }
        if q.get("cursor") == "accounts-page-2" {
            return _json_res(200, {"items": [
                {"id": "ca_toolkit_41", "alias": "overflow", "toolkit": {"slug": "toolkit_41"}, "status": "ACTIVE", "updated_at": "2026-08-17T10:00:00Z"},
            ]});
        }
        return _json_res(200, {"items": [
            {"id": "ca_github_work", "alias": "work", "toolkit": {"slug": "github"}, "status": "ACTIVE", "updated_at": "2026-08-17T08:00:00Z"},
            {"id": "ca_github_personal", "alias": "personal", "toolkit": {"slug": "github"}, "status": "ACTIVE", "updated_at": "2026-08-17T09:00:00Z"},
            {"id": "ca_notion", "alias": "team", "toolkit": {"slug": "notion"}, "status": "INITIATED", "updated_at": "2026-08-17T08:01:00Z"},
            {"id": "ca_linear", "toolkit": {"slug": "linear"}, "status": "EXPIRED", "updated_at": "2026-08-17T08:02:00Z"},
        ], "next_cursor": "accounts-page-2"});
    }
    if method == "POST" and path.endswith("/link") {
        # twitter has no Composio-managed auth: the link only works when the
        # Session was created with the project's own config for it.
        if body["toolkit"] == "twitter" and not S["session_auth_configs"].get("twitter") {
            return _json_res(400, {"error": {"message":
                "Composio does not manage auth for toolkit twitter and no auth config without required fields is available. "
                + "Please create an auth config manually or specify one in auth_config_override."}});
        }
        return _json_res(201, {"redirect_url": "https://connect.composio.dev/link/" + body["toolkit"]});
    }
    if method == "DELETE" and path.startswith("/api/v3.1/connected_accounts/ca_") { return _json_res(200, {"success": True}); }
    return _json_res(404, {"error": "not found"});
}

def _fake_fetch(method: str, url: str, headers: dict[str, any], body: any, timeout_ms: int) -> dict[str, any] {
    parts = urllib.parse.urlsplit(url);
    parsed: any = json.loads(body) if body else None;
    lower: dict[str, any] = {};
    for (k, v) in headers.items() { lower[k.lower()] = v; }
    S["calls"].append({
        "method": method, "url": url, "path": parts.path, "query": ("?" + parts.query) if parts.query else "",
        "body": parsed, "apiKey": str(lower.get("x-api-key", "")), "transportSessionId": str(lower.get("mcp-session-id", "")),
    });
    intercept = S["intercept"];
    if intercept is not None and url.startswith("https://app.composio.dev/tool_router/") {
        return intercept(url, lower);
    }
    if not url.startswith(ORIGIN) { raise Exception("fetch failed: unexpected host " + url); }
    q = _qp(parts.query);
    if parts.path.startswith("/broker/") { return _broker_route(method, parts.path, q, parsed, lower); }
    return _project_route(method, parts.path, q, parsed, str(lower.get("x-api-key", "")));
}

def _setup -> dict[str, any] {
    S.clear();
    S.update({
        "calls": [], "intercept": None, "warnings": [], "persisted": [],
        "accounts_malformed": False, "accounts_unavailable": False, "accounts_empty": False, "accounts_override": None,
        "broker_tools": None, "broker_tools_fail": False, "broker_connected": None, "broker_catalog": None,
        "custom_auth_configs": [], "session_auth_configs": {}, "init_delay": 0,
    });
    def _warn(message: str) { S["warnings"].append(message); }
    def _persist(user_id: str, session_id: str) { S["persisted"].append({"userId": user_id, "sessionId": session_id}); }
    _reset();
    _cx.update({"hooks": {"fetch": _fake_fetch, "persist": _persist, "warn": _warn, "uuid": _default_uuid}});
    os.environ["OMB_COMPOSIO_API"] = ORIGIN + "/api/v3.1";
    os.environ["OMB_COMPOSIO_TOOLKITS_API"] = ORIGIN + "/api/v3";
    os.environ.pop("OMB_COMPOSIO_BROKER_URL", None);
    os.environ.pop("OMB_COMPOSIO_BROKER_TOKEN", None);
    return S;
}

def _since(n: int) -> list[any] { return S["calls"][n:]; }

def _broker(token_char: str) {
    set_managed_broker_access({"url": ORIGIN + "/broker", "token": token_char * 64});
}

def _cfg -> dict[str, any] {
    return {"composio": {"apiKey": "ak_test", "userId": "openmausbot_existing", "sessionId": "trs_test"}};
}

def _throws(fn: any, pattern: str, status: any = None) {
    try {
        fn();
    } except Exception as e {
        assert re.search(pattern, str(e), re.I), "error " + json.dumps(str(e)) + " does not match " + json.dumps(pattern);
        if status is not None {
            assert getattr(e, "status", None) == status, "status " + str(getattr(e, "status", None));
        }
        return;
    }
    raise Exception("expected an exception matching " + pattern);
}

def _project_intercept(session_header: str, seen: list[any]) -> any {
    def _handler(url: str, headers: dict[str, any]) -> dict[str, any] {
        seen.append({"url": url, "apiKey": headers.get("x-api-key"), "session": headers.get("mcp-session-id", "")});
        return _json_res(200, {"source": "project"}, {"mcp-session-id": session_header});
    }
    return _handler;
}

def _decode(b: bytes) -> any { return json.loads(b.decode("utf-8")); }

# ── Composio Sessions ─────────────────────────────────────────────────────

test "only sends Session MCP credentials over HTTPS or loopback HTTP" {
    _setup();
    os.environ["OMB_COMPOSIO_API"] = "http://remote.example.test/api";
    assert trusted_session_mcp_url("http://remote.example.test/mcp") is False;
    os.environ["OMB_COMPOSIO_API"] = "ftp://remote.example.test/api";
    assert trusted_session_mcp_url("ftp://remote.example.test/mcp") is False;
    os.environ["OMB_COMPOSIO_API"] = "http://127.0.0.1:9876/api";
    assert trusted_session_mcp_url("http://127.0.0.1:9876/mcp") is True;
    assert trusted_session_mcp_url("https://app.composio.dev/mcp") is True;
}

test "rejects broker URL components and invalid tokens from the environment" {
    _setup();
    os.environ["OMB_COMPOSIO_BROKER_TOKEN"] = "a" * 64;
    for url in ["https://user:secret@broker.example/root", "https://broker.example/root?redirect=evil", "https://broker.example/root#fragment"] {
        os.environ["OMB_COMPOSIO_BROKER_URL"] = url;
        def _mode { connection_mode({}); }
        _throws(_mode, "must not include");
    }
    os.environ["OMB_COMPOSIO_BROKER_URL"] = "http://[::1]:3210/root/";
    assert connection_mode({}) == "managed";
    assert broker_access()["url"] == "http://[::1]:3210/root";
    os.environ["OMB_COMPOSIO_BROKER_TOKEN"] = "short";
    def _mode2 { connection_mode({}); }
    _throws(_mode2, "token is invalid");
    state = connectors_state();
    assert state["env_broker"] is False and "token is invalid" in state["env_error"];
}

test "accepts a private desktop credential update and rejects unsafe broker URLs" {
    _setup();
    set_managed_broker_access({"url": "http://127.0.0.1:3210/", "token": "a" * 64});
    assert connection_mode({}) == "managed";
    set_managed_broker_access({"url": "http://[::1]:3210/", "token": "a" * 64});
    assert connection_mode({}) == "managed";
    def _plain { set_managed_broker_access({"url": "http://broker.example", "token": "a" * 64}); }
    _throws(_plain, "HTTPS");
    for url in ["https://user:secret@broker.example/root", "https://broker.example/root?redirect=evil", "https://broker.example/root#fragment"] {
        def _bad { set_managed_broker_access({"url": url, "token": "a" * 64}); }
        _throws(_bad, "must not include");
    }
    def _short { set_managed_broker_access({"url": "https://broker.example", "token": "short"}); }
    _throws(_short, "");
    def _extra { set_managed_broker_access({"url": "https://broker.example", "token": "a" * 64, "x": 1}); }
    _throws(_extra, "Unrecognized key");
    set_managed_broker_access(None);
    assert connection_mode({}) == "unavailable";
}

test "ignores credential sync without access and clears only on explicit null" {
    _setup();
    set_managed_broker_access({"url": "http://127.0.0.1:3210/", "token": "a" * 64});
    assert apply_managed_broker_message({"type": "openmausbot:managed-composio"}) is False;
    assert connection_mode({}) == "managed";
    assert apply_managed_broker_message({"type": "openmausbot:managed-composio", "access": None}) is True;
    assert connection_mode({}) == "unavailable";
}

test "an op carries node's broker credential so a respawned harness keeps it" {
    _setup();
    managed = {"access": {"url": ORIGIN + "/broker", "token": "a" * 64}};
    res = connectors_connection_status({"composio": None}, ["github"], managed);
    assert res["services"]["github"]["connected"] is True;
    # explicit null clears; an absent `managed` leaves the module state alone
    assert connectors_connected_services({}, {"access": None})["error"] == "The connected-apps service is unavailable";
    assert connectors_set_broker_access({"url": "http://127.0.0.1:3210/", "token": "a" * 64})["access"]["url"] == "http://127.0.0.1:3210";
    bad = connectors_set_broker_access({"url": "http://broker.example", "token": "a" * 64});
    assert bad["ok"] is False and bad["status"] == 500 and "HTTPS" in bad["error"];
}

test "does not reuse a self-hosted catalog after the project key changes" {
    _setup();
    first = list_toolkits({"composio": {"apiKey": "ak_catalog_a"}});
    second = list_toolkits({"composio": {"apiKey": "ak_catalog_b"}});
    assert [(c["slug"], c["label"]) for c in first["cards"]] == [("notion", "Catalog A")];
    assert [(c["slug"], c["label"]) for c in second["cards"]] == [("linear", "Catalog B")];
    assert [c["apiKey"] for c in S["calls"] if c["path"] == "/api/v3/toolkits"] == ["ak_catalog_a", "ak_catalog_b"];
}

test "pages the marketplace catalog past the first page" {
    _setup();
    out = list_toolkits({"composio": {"apiKey": "ak_catalog_pages"}});
    assert [c["slug"] for c in out["cards"]] == ["gmail", "bland_ai", "currencyscoop", "deepgram", "zoom"];
    assert out["pagination"] == {"items": 5, "totalItems": 5, "stalled": False, "complete": True};
    pages = [c for c in S["calls"] if c["path"] == "/api/v3/toolkits"];
    assert len(pages) == 2;
    assert "cursor=" not in pages[0]["query"];
    assert "cursor=catalog-page-2" in pages[1]["query"];
}

test "keeps the catalog pages already read when a later page fails" {
    _setup();
    out = list_toolkits({"composio": {"apiKey": "ak_catalog_partial"}});
    assert out["source"] == "api";
    assert [c["slug"] for c in out["cards"]] == ["gmail", "bland_ai", "currencyscoop"];
    assert out["pagination"] == {"items": 3, "totalItems": 5, "stalled": True, "complete": False, "reason": "http-error"};
}

test "stops paging a catalog endpoint that replays the same cursor" {
    _setup();
    out = list_toolkits({"composio": {"apiKey": "ak_catalog_stuck"}});
    assert [c["slug"] for c in out["cards"]] == ["gmail"];
    assert len([c for c in S["calls"] if c["path"] == "/api/v3/toolkits"]) == 2;
}

test "stops cleanly when replayed pages hide behind rotating cursors" {
    _setup();
    out = list_toolkits({"composio": {"apiKey": "ak_catalog_page_stuck"}});
    assert [c["slug"] for c in out["cards"]] == ["gmail"];
    assert out["pagination"] == {"items": 1, "stalled": True, "complete": False, "reason": "page-stuck"};
    assert len([c for c in S["calls"] if c["path"] == "/api/v3/toolkits"]) == 2;
}

test "reports a partial catalog when upstream stops offering cursors before its own total" {
    _setup();
    out = list_toolkits({"composio": {"apiKey": "ak_catalog_stalled_total"}});
    assert out["pagination"] == {"items": 1, "totalItems": 1540, "stalled": True, "complete": False, "reason": "end"};
    assert any(["partial marketplace" in w for w in S["warnings"]]);
    assert any(["of ~1540" in w for w in S["warnings"]]);
}

test "flags a partial catalog that ends early with only page counts to reveal it" {
    _setup();
    out = list_toolkits({"composio": {"apiKey": "ak_catalog_end_short"}});
    assert out["pagination"] == {"items": 1, "stalled": True, "complete": False, "reason": "end"};
    assert any(["partial marketplace" in w for w in S["warnings"]]);
}

test "keeps pagination with the cached catalog" {
    _setup();
    first = list_toolkits({"composio": {"apiKey": "ak_catalog_stalled_total"}});
    before = len(S["calls"]);
    second = list_toolkits({"composio": {"apiKey": "ak_catalog_stalled_total"}});
    assert second["pagination"] == first["pagination"];
    assert len(_since(before)) == 0;
}

test "marks a catalog that lost a page incomplete even with no totals to compare" {
    _setup();
    out = list_toolkits({"composio": {"apiKey": "ak_catalog_http_no_total"}});
    assert out["pagination"] == {"items": 3, "stalled": False, "complete": False};
}

test "stops at the reported last page even when a cursor is still offered" {
    _setup();
    out = list_toolkits({"composio": {"apiKey": "ak_catalog_exhausted"}});
    assert [c["slug"] for c in out["cards"]] == ["gmail", "deepgram"];
    assert len([c for c in S["calls"] if c["path"] == "/api/v3/toolkits"]) == 2;
}

test "falls back to the curated catalog when the backend cannot be read" {
    _setup();
    out = list_toolkits({"composio": {"apiKey": "ak_unknown"}});
    assert out["source"] == "curated" and "pagination" not in out;
    assert len(out["cards"]) == 24 and out["cards"][0]["slug"] == "slack";
    assert curated_slugs()[12] == "twitter";
}

test "drops a managed MCP session when routing switches to a user project" {
    _setup();
    _broker("a");
    seen: list[any] = [];
    S["intercept"] = _project_intercept("mcp_project_after_managed", seen);
    managed = relay_mcp({}, {"jsonrpc": "2.0", "id": 101, "method": "tools/list"});
    assert managed["transport_session_id"] == "mcp_broker";
    relay_mcp({}, {"jsonrpc": "2.0", "id": 105, "method": "tools/list"}, managed["transport_session_id"]);
    hits = [c for c in S["calls"] if c["path"] == "/broker/v1/mcp" and isinstance(c["body"], dict) and c["body"].get("id") == 105];
    assert hits[-1]["transportSessionId"] == "mcp_broker";
    project = relay_mcp(_cfg(), {"jsonrpc": "2.0", "id": 102, "method": "tools/list"}, managed["transport_session_id"]);
    assert project["transport_session_id"] == "mcp_project_after_managed";
    assert [s["session"] for s in seen] == [""];
}

test "drops a project MCP session when routing switches to the managed broker" {
    _setup();
    _broker("a");
    seen: list[any] = [];
    S["intercept"] = _project_intercept("mcp_project_before_managed", seen);
    project = relay_mcp(_cfg(), {"jsonrpc": "2.0", "id": 103, "method": "tools/list"});
    assert project["transport_session_id"] == "mcp_project_before_managed";
    relay_mcp({}, {"jsonrpc": "2.0", "id": 104, "method": "tools/list"}, project["transport_session_id"]);
    hits = [c for c in S["calls"] if c["path"] == "/broker/v1/mcp" and isinstance(c["body"], dict) and c["body"].get("id") == 104];
    assert hits[-1]["transportSessionId"] == "";
}

test "uses a user-owned project for every connector operation even when the managed broker is available" {
    _setup();
    cfg = _cfg();
    _broker("a");
    seen: list[any] = [];
    S["intercept"] = _project_intercept("mcp_project", seen);
    before = len(S["calls"]);
    assert connection_mode(cfg) == "self-hosted";
    catalog = list_toolkits(cfg);
    assert catalog["source"] == "api" and [c["slug"] for c in catalog["cards"]] == ["twitter", "github"];
    assert connected_services(cfg)["github"]["connected"] is True;
    assert connection_status(cfg, ["slack"])["slack"]["connected"] is False;
    assert authorize_service(cfg, "slack") == {"url": "https://connect.composio.dev/link/slack"};
    assert remove_account(cfg, "github", "ca_github_personal") == {"removed": 1};
    assert remove_service(cfg, "github") == {"removed": 1};
    relayed = relay_mcp(cfg, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"});
    assert _decode(relayed["bytes"]) == {"source": "project"};
    assert relayed["transport_session_id"] == "mcp_project";
    assert [(s["url"], s["apiKey"]) for s in seen] == [("https://app.composio.dev/tool_router/v3/trs_test/mcp", "ak_test")];
    since = _since(before);
    assert any([c["path"] == "/api/v3.1/tool_router/session/trs_test" for c in since]);
    assert not any([c["path"].startswith("/broker/") for c in since]);
}

test "accepts the legacy x alias but authorizes Composio's twitter toolkit" {
    _setup();
    cfg = _cfg();
    S["session_auth_configs"] = {"twitter": "ac_twitter"};
    _broker("a");
    assert authorize_service(cfg, "x") == {"url": "https://connect.composio.dev/link/twitter"};
    assert connection_status(cfg, ["x"])["x"]["connected"] is False;
    assert remove_service(cfg, "x") == {"removed": 0};
    assert any([c["slug"] == "twitter" for c in list_toolkits(cfg)["cards"]]);
    links = [c for c in S["calls"] if c["method"] == "POST" and c["path"].endswith("/link")];
    assert links[-1]["body"] == {"toolkit": "twitter"};
    assert any(["toolkits=twitter" in c["query"] for c in S["calls"]]);
    assert not any([c["path"].startswith("/broker/") for c in S["calls"]]);
}

test "falls back to the managed broker immediately after the project key is cleared" {
    _setup();
    cfg = {"composio": {"apiKey": ""}};
    _broker("a");
    assert connection_mode(cfg) == "managed";
    assert connection_status(cfg, ["github"])["github"]["connected"] is True;
    assert authorize_service(cfg, "github") == {"url": "https://connect.composio.dev/managed"};
    catalog = list_toolkits(cfg);
    assert catalog["source"] == "api" and catalog["cards"][0]["slug"] == "github";
    relayed = relay_mcp(cfg, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"});
    assert _decode(relayed["bytes"]) == {"source": "broker"};
    assert [c["method"] + " " + c["path"] for c in S["calls"] if c["path"].startswith("/broker/")] == [
        "GET /broker/v1/connectors",
        "POST /broker/v1/connectors/github/authorize",
        "GET /broker/v1/catalog",
        "POST /broker/v1/mcp",
    ];
}

test "maps broker refusals onto a client status and keeps 5xx as a gateway error" {
    _setup();
    _broker("b");
    def _denied { connection_status({}, ["github"]); }
    _throws(_denied, "^invalid broker token$", 401);
}

test "accepts only project API keys" {
    _setup();
    def _old { prepare_project_session("old_key"); }
    _throws(_old, "start with ak_");
    def _wrong { prepare_project_session("ak_wrong"); }
    _throws(_wrong, "invalid project key");
    def _blank { prepare_project_session("   "); }
    _throws(_blank, "Enter a Composio project API key");
}

test "creates one stable per-installation session and reuses it" {
    _setup();
    created = prepare_project_session("ak_test", {"userId": "openmausbot_existing"});
    assert created == {"apiKey": "ak_test", "userId": "openmausbot_existing", "sessionId": "trs_test"};
    posts = [c for c in S["calls"] if c["method"] == "POST" and c["path"].endswith("/session")];
    assert posts[-1]["body"] == {
        "user_id": "openmausbot_existing",
        "manage_connections": {"enable": True, "enable_wait_for_connections": True, "enable_connection_removal": True},
        "multi_account": {"enable": True, "max_accounts_per_toolkit": 5, "require_explicit_selection": True},
    };
    reused = prepare_project_session("ak_test", created);
    assert reused == {"apiKey": "ak_test", "userId": "openmausbot_existing", "sessionId": "trs_test"};
    assert len([c for c in S["calls"] if c["method"] == "POST" and c["path"].endswith("/session")]) == 1;
}

test "recreates a legacy Session with the same Composio user ID" {
    _setup();
    upgraded = prepare_project_session("ak_test", {"apiKey": "ak_test", "userId": "stale-local-user-id", "sessionId": "trs_legacy"});
    assert upgraded == {"apiKey": "ak_test", "userId": "openmausbot_legacy", "sessionId": "trs_test"};
    posts = [c for c in S["calls"] if c["method"] == "POST" and c["path"].endswith("/session")];
    assert posts[-1]["body"]["user_id"] == "openmausbot_legacy";
    assert posts[-1]["body"]["multi_account"] == {"enable": True, "max_accounts_per_toolkit": 5, "require_explicit_selection": True};
}

test "names the project's own auth configs at creation and rebuilds a Session that predates them" {
    _setup();
    S["custom_auth_configs"] = [
        {"id": "ac_twitter_old", "toolkit": {"slug": "twitter"}, "is_composio_managed": False, "status": "ENABLED", "last_updated_at": "2026-08-20T00:00:00Z"},
        # newest wins, and the slug is matched case-insensitively
        {"id": "ac_twitter", "toolkit": {"slug": "TWITTER"}, "is_composio_managed": False, "status": "ENABLED", "last_updated_at": "2026-08-25T00:00:00Z"},
        # Composio-managed, disabled, and switched-off-for-Sessions configs are not the user's choice
        {"id": "ac_github_managed", "toolkit": {"slug": "github"}, "is_composio_managed": True, "status": "ENABLED"},
        {"id": "ac_slack_disabled", "toolkit": {"slug": "slack"}, "is_composio_managed": False, "status": "DISABLED"},
        {"id": "ac_notion_off", "toolkit": {"slug": "notion"}, "is_composio_managed": False, "is_enabled_for_tool_router": False},
    ];
    current = {"apiKey": "ak_test", "userId": "openmausbot_existing", "sessionId": "trs_test"};
    assert prepare_project_session("ak_test", current) == current;
    creates = [c for c in S["calls"] if c["method"] == "POST" and c["path"].endswith("/session")];
    assert len(creates) == 1;
    assert creates[0]["body"]["user_id"] == "openmausbot_existing";
    assert creates[0]["body"]["auth_configs"] == {"twitter": "ac_twitter"};
    # the rebuilt Session now covers the configs, so the next check reuses it
    after = len(S["calls"]);
    prepare_project_session("ak_test", current);
    assert not any([c["method"] == "POST" and c["path"].endswith("/session") for c in _since(after)]);
}

test "rebuilds the Session and retries when a toolkit needs the project's own auth config" {
    _setup();
    S["custom_auth_configs"] = [{"id": "ac_twitter", "toolkit": {"slug": "twitter"}, "is_composio_managed": False, "status": "ENABLED"}];
    # The live Session is authoritative: a stale local user ID must never
    # move the rebuilt Session away from the existing connected accounts.
    cfg = {"composio": {"apiKey": "ak_test", "userId": "stale-local-user", "sessionId": "trs_test"}};
    assert authorize_service(cfg, "twitter") == {"url": "https://connect.composio.dev/link/twitter"};
    assert len([c for c in S["calls"] if c["method"] == "POST" and c["path"].endswith("/link")]) == 2;
    posts = [c for c in S["calls"] if c["method"] == "POST" and c["path"].endswith("/session")];
    assert posts[-1]["body"]["user_id"] == "openmausbot_existing";
    assert posts[-1]["body"]["auth_configs"] == {"twitter": "ac_twitter"};
    assert cfg["composio"]["userId"] == "openmausbot_existing" and cfg["composio"]["sessionId"] == "trs_test";
    assert S["persisted"] == [{"userId": "openmausbot_existing", "sessionId": "trs_test"}];
}

test "says what to create when the project has no auth config for the toolkit" {
    _setup();
    cfg = _cfg();
    def _tw { authorize_service(cfg, "twitter"); }
    _throws(_tw, "create an auth config for \"twitter\"", 400);
    assert not any([c["method"] == "POST" and c["path"].endswith("/session") for c in S["calls"]]);
    assert cfg["composio"]["userId"] == "openmausbot_existing" and S["persisted"] == [];
    assert authorize_service(cfg, "github", "personal-three") == {"url": "https://connect.composio.dev/link/github"};
}

test "does not offer Twitter through the official managed broker without an owned OAuth app" {
    _setup();
    set_managed_broker_access({"url": "https://broker.openmausbot.test", "token": "a" * 64});
    def _tw { authorize_service({}, "twitter"); }
    _throws(_tw, "X Developer app", 409);
    def _x { authorize_service({}, "x"); }
    _throws(_x, "self-hosted connected apps", 409);
    assert S["calls"] == [];
}

test "validates account aliases before sending them upstream" {
    _setup();
    assert normalize_account_alias("  personal gmail  ") == "personal gmail";
    assert normalize_account_alias(None) is None and normalize_account_alias("") is None;
    def _nl { normalize_account_alias("bad\nalias"); }
    _throws(_nl, "printable", 400);
    def _long { normalize_account_alias("x" * 65); }
    _throws(_long, "1-64", 400);
    def _num { normalize_account_alias(42); }
    _throws(_num, "must be text", 400);
    # UTF-16 length, like zod's max(64): 32 astral characters fit, 33 do not
    assert normalize_account_alias("\U0001F600" * 32) == "\U0001F600" * 32;
    def _astral { normalize_account_alias("\U0001F600" * 33); }
    _throws(_astral, "1-64");
}

test "mounts the Session MCP endpoint with the project key header" {
    _setup();
    out = mcp_integration(_cfg(), {"harnessUrl": "http://127.0.0.1:8799", "commsToken": "secret", "botId": "bot-1", "threadId": "thread-1"}, "/usr/bin/node", ["/srv/connector-proxy.ts"]);
    assert out["command"] == "/usr/bin/node" and "connector-proxy" in out["args"][0];
    assert out["env"] == {
        "ELECTRON_RUN_AS_NODE": "1",
        "OMB_CONNECTOR_UPSTREAM_URL": "http://127.0.0.1:8799/api/internal/connectors/mcp",
        "OMB_CONNECTOR_UPSTREAM_HEADERS": "{\"authorization\":\"Bearer secret\"}",
        "OMB_HARNESS_URL": "http://127.0.0.1:8799",
        "OMB_CONNECTOR_TOKEN": "secret",
        "OMB_BOT_ID": "bot-1",
        "OMB_THREAD_ID": "thread-1",
    };
    # a server with no connection service mounts nothing
    assert mcp_integration({}, {"harnessUrl": "h", "commsToken": "t", "botId": "b", "threadId": "t"}, "n", []) is None;
}

test "passes a bot's connector grants to the bridge as an env allowlist" {
    _setup();
    grants = {"gmail": {"tools": ["GMAIL_SEND_EMAIL"]}, "slack": {"tools": "*"}};
    out = mcp_integration(_cfg(), {"harnessUrl": "http://127.0.0.1:8799", "commsToken": "secret", "botId": "bot-1", "threadId": "thread-1", "connectorTools": grants}, "n", ["p"]);
    assert out["env"][CONNECTOR_ALLOWED_TOOLS_ENV] == "{\"gmail\":{\"tools\":[\"GMAIL_SEND_EMAIL\"]},\"slack\":{\"tools\":\"*\"}}";
}

test "omits the allowlist for legacy bots and for oversized grants, warning once" {
    _setup();
    ctx = {"harnessUrl": "http://127.0.0.1:8799", "commsToken": "secret", "botId": "bot-1", "threadId": "thread-1"};
    legacy = mcp_integration(_cfg(), ctx, "n", ["connector-proxy"]);
    assert CONNECTOR_ALLOWED_TOOLS_ENV not in legacy["env"];
    assert S["warnings"] == [];
    names = ["GMAIL_TOOL_" + str(i).zfill(3) + "_WITH_" + "A_LONG_DESCRIPTOR_" * 6 for i in range(500)];
    big = dict(ctx);
    big["connectorTools"] = {"gmail": {"tools": names}};
    oversized = mcp_integration(_cfg(), big, "n", ["connector-proxy"]);
    assert "connector-proxy" in oversized["args"][0];
    assert CONNECTOR_ALLOWED_TOOLS_ENV not in oversized["env"];
    assert len(S["warnings"]) == 1 and "exceeds 32768 bytes" in S["warnings"][0];
}

test "passes the connected-service slugs to the bridge alongside the allowlist" {
    _setup();
    _broker("f");
    S["broker_connected"] = {"services": {
        "bland_ai": {"connected": True, "status": "ACTIVE"},
        "bland": {"connected": True, "status": "ACTIVE"},
        "github": {"connected": True, "status": "ACTIVE"},
    }};
    out = mcp_integration({}, {"harnessUrl": "h", "commsToken": "s", "botId": "bot-1", "threadId": "t", "connectorTools": {"bland": {"tools": "*"}}}, "n", []);
    slugs = json.loads(out["env"][CONNECTOR_SERVICE_SLUGS_ENV]);
    assert "bland_ai" in slugs and "bland" in slugs;
}

test "reads an unreachable connection inventory as no service slugs" {
    _setup();
    assert connected_service_slugs({}) == [];
    # the failure is not cached: a reachable backend answers on the next call
    _broker("a");
    assert connected_service_slugs({}) == ["github"];
}

test "validates grant patches against connected services and the catalog" {
    _setup();
    cfg = _cfg();
    assert validate_connector_grants(cfg, {"github": {"tools": ["GITHUB_CREATE_ISSUE"]}}) is None;
    assert validate_connector_grants(cfg, {"github": {"tools": "*"}}) is None;
    assert re.search("not connected: slack", validate_connector_grants(cfg, {"slack": {"tools": ["SLACK_POST_MESSAGE"]}}));
    assert re.search("another service: SLACK_POST_MESSAGE", validate_connector_grants(cfg, {"gmail": {"tools": ["SLACK_POST_MESSAGE"]}}));
    assert re.search("missing from the connected-apps catalog: gmail", validate_connector_grants(cfg, {"gmail": {"tools": ["GMAIL_SEND_EMAIL"]}}));
}

test "never blocks a grant patch when the connection inventory is unreachable, but still checks prefixes" {
    _setup();
    assert validate_connector_grants({}, {"anything": {"tools": ["ANYTHING_DO_IT"]}}) is None;
    assert re.search("another service", validate_connector_grants({}, {"gmail": {"tools": ["SLACK_POST_MESSAGE"]}}));
    _broker("a");
    assert validate_connector_grants({}, {"github": {"tools": ["GITHUB_CREATE_ISSUE"]}}) is None;
    assert re.search("not connected: gmail", validate_connector_grants({}, {"gmail": {"tools": ["GMAIL_SEND_EMAIL"]}}));
}

test "accepts an underscored service's own tool names in its grant" {
    _setup();
    _broker("f");
    S["broker_connected"] = {"services": {
        "bland_ai": {"connected": True, "status": "ACTIVE"},
        "bland": {"connected": True, "status": "ACTIVE"},
        "github": {"connected": True, "status": "ACTIVE"},
    }};
    S["broker_catalog"] = {"items": [{"slug": "github", "name": "GitHub"}, {"slug": "bland_ai", "name": "Bland AI"}, {"slug": "bland", "name": "Bland"}]};
    assert validate_connector_grants({}, {"bland_ai": {"tools": ["BLAND_AI_MAKE_CALL"]}}) is None;
    assert re.search("another service: BLAND_AI_MAKE_CALL", validate_connector_grants({}, {"bland": {"tools": ["BLAND_AI_MAKE_CALL"]}}));
}

test "does not reject grants against a catalog walk that never finished" {
    _setup();
    cfg = {"composio": {"apiKey": "ak_catalog_http_no_total", "userId": "openmausbot_existing", "sessionId": "trs_test"}};
    assert validate_connector_grants(cfg, {"github": {"tools": ["GITHUB_CREATE_ISSUE"]}}) is None;
}

test "reports connection state, creates auth links and revokes disconnects" {
    _setup();
    cfg = _cfg();
    assert connection_status(cfg, ["github", "gmail", "slack", "notion", "linear"]) == {
        "github": {
            "connected": True, "pending": False, "status": "ACTIVE",
            "accounts": [
                {"id": "ca_github_personal", "status": "ACTIVE", "alias": "personal"},
                {"id": "ca_github_work", "status": "ACTIVE", "alias": "work"},
                # the Session-selected account is synthesized when the raw list omits it
                {"id": "ca_github", "status": "ACTIVE"},
            ],
        },
        "gmail": {"connected": True, "pending": False, "status": "ACTIVE", "accounts": []},
        "slack": {"connected": False, "pending": False, "status": "not_connected", "accounts": []},
        "notion": {"connected": False, "pending": True, "status": "INITIATED", "accounts": [{"id": "ca_notion", "status": "INITIATED", "alias": "team"}]},
        "linear": {"connected": False, "pending": False, "status": "EXPIRED", "accounts": [{"id": "ca_linear", "status": "EXPIRED"}]},
    };
    def _no_alias { authorize_service(cfg, "github"); }
    _throws(_no_alias, "alias.*not replaced", 400);
    def _taken { authorize_service(cfg, "github", "work"); }
    _throws(_taken, "already in use", 409);
    assert authorize_service(cfg, "github", "personal-two") == {"url": "https://connect.composio.dev/link/github"};
    links = [c for c in S["calls"] if c["method"] == "POST" and c["path"].endswith("/link")];
    assert links[-1]["body"] == {"toolkit": "github", "alias": "personal-two"};
    assert remove_account(cfg, "github", "ca_github_personal") == {"removed": 1};
    assert remove_account(cfg, "github", "ca_other_user") == {"removed": 0};
    def _bad_id { remove_account(cfg, "github", "../other"); }
    _throws(_bad_id, "invalid connected-account ID", 400);
    assert remove_service(cfg, "github") == {"removed": 1};
    assert any([c["method"] == "DELETE" and c["path"].endswith("/connected_accounts/ca_github") and c["query"] == "?revoke_on_delete=true" for c in S["calls"]]);
}

test "enumerates connected services independently of catalog position" {
    _setup();
    services = connected_services(_cfg());
    assert services["toolkit_41"] == {"connected": True, "pending": False, "status": "ACTIVE", "accounts": [{"id": "ca_toolkit_41", "status": "ACTIVE", "alias": "overflow"}]};
    assert services["github"]["accounts"] == [
        {"id": "ca_github_personal", "status": "ACTIVE", "alias": "personal"},
        {"id": "ca_github_work", "status": "ACTIVE", "alias": "work"},
        {"id": "ca_github", "status": "ACTIVE"},
    ];
    assert services["publicsearch"] == {"connected": True, "pending": False, "status": "ACTIVE", "accounts": []};
    assert services["selectedonly"] == {"connected": True, "pending": False, "status": "ACTIVE", "accounts": [{"id": "ca_session_only", "status": "ACTIVE"}]};
    inventory = [c for c in S["calls"] if c["path"].endswith("/connected_accounts")];
    assert len(inventory) == 2;
    assert "toolkit_slugs=" not in inventory[0]["query"];
    assert "cursor=accounts-page-2" in inventory[1]["query"];
    toolkits = [c for c in S["calls"] if c["path"].endswith("/toolkits")];
    assert len(toolkits) == 2;
    assert "is_connected=true" in toolkits[0]["query"];
    assert "cursor=toolkits-page-2" in toolkits[1]["query"];
}

test "falls back to complete Session toolkit state without connected-account read permission" {
    _setup();
    S["accounts_unavailable"] = True;
    services = connected_services(_cfg());
    assert services["github"]["connected"] is True and services["github"]["status"] == "ACTIVE";
    assert services["github"]["accounts"] == [{"id": "ca_github", "status": "ACTIVE"}];
    assert services["gmail"]["accounts"] == [] and services["gmail"]["connected"] is True;
    assert services["publicsearch"]["connected"] is True;
    assert services["selectedonly"]["accounts"] == [{"id": "ca_session_only", "status": "ACTIVE"}];
}

test "falls back to session toolkit state when connected-account items is malformed" {
    _setup();
    S["accounts_malformed"] = True;
    assert connection_status(_cfg(), ["github", "slack"]) == {
        "github": {"connected": True, "pending": False, "status": "ACTIVE", "accounts": [{"id": "ca_github", "status": "ACTIVE"}]},
        "slack": {"connected": False, "pending": False, "status": "not_connected", "accounts": []},
    };
}

test "uses the provided alias for the first account authorization" {
    _setup();
    S["accounts_empty"] = True;
    cfg = _cfg();
    slack = connection_status(cfg, ["slack"])["slack"];
    assert slack["connected"] is False and slack["pending"] is False and slack["accounts"] == [];
    before = len(S["calls"]);
    assert authorize_service(cfg, "slack", "team") == {"url": "https://connect.composio.dev/link/slack"};
    links = [c for c in _since(before) if c["method"] == "POST" and c["path"].endswith("/link")];
    assert len(links) == 1 and links[0]["body"] == {"toolkit": "slack", "alias": "team"};
}

test "retries unfinished or expired flows with fresh aliases without replacing or deleting accounts" {
    _setup();
    cfg = {"composio": {"apiKey": "ak_test", "userId": "stale-local-user", "sessionId": "trs_test"}};
    for status in ["INITIALIZING", "INITIATED", "EXPIRED"] {
        S["accounts_override"] = [
            {"id": "ca_unfinished", "alias": "personal", "status": status, "toolkit": {"slug": "slack"}},
            {"id": "ca_expired", "status": "expired", "toolkit": {"slug": "SLACK"}},
            {"id": "ca_other_toolkit", "status": "ACTIVE", "toolkit": {"slug": "github"}},
        ];
        before = len(S["calls"]);
        assert authorize_service(cfg, "SLACK") == {"url": "https://connect.composio.dev/link/slack"};
        assert authorize_service(cfg, "slack") == {"url": "https://connect.composio.dev/link/slack"};
        since = _since(before);
        links = [c for c in since if c["method"] == "POST" and c["path"].endswith("/link")];
        assert len(links) == 2;
        for link in links {
            assert link["body"]["toolkit"] == "slack";
            assert re.fullmatch("omb-retry-[0-9a-f-]{36}", link["body"]["alias"]);
        }
        assert links[0]["body"]["alias"] != links[1]["body"]["alias"];
        assert all([_qp(c["query"][1:]).get("user_ids") == "openmausbot_existing" for c in since if c["path"].endswith("/connected_accounts")]);
        assert not any([c["method"] in ["DELETE", "PATCH"] for c in since]);
        assert S["accounts_override"][0]["alias"] == "personal";
    }
}

test "preserves explicit aliases and requires one when any existing account is not a retryable flow" {
    _setup();
    cfg = _cfg();
    for status in ["ACTIVE", "INACTIVE", "FAILED", "REVOKED", "PENDING", "FUTURE_STATUS", None] {
        row: dict[str, any] = {"id": "ca_existing", "alias": "Personal", "toolkit": {"slug": "slack"}};
        if status is not None { row["status"] = status; }
        S["accounts_override"] = [row];
        before = len(S["calls"]);
        def _plain { authorize_service(cfg, "slack"); }
        _throws(_plain, "alias.*not replaced");
        S["accounts_override"].append({"id": "ca_unfinished", "status": "INITIALIZING", "toolkit": {"slug": "slack"}});
        _throws(_plain, "alias.*not replaced");
        def _dupe { authorize_service(cfg, "slack", "personal"); }
        _throws(_dupe, "already in use");
        assert not any([c["method"] == "POST" and c["path"].endswith("/link") for c in _since(before)]);
    }
    S["accounts_override"] = [{"id": "ca_expired", "alias": "Personal", "status": "EXPIRED", "toolkit": {"slug": "slack"}}];
    def _dupe2 { authorize_service(cfg, "slack", "personal"); }
    _throws(_dupe2, "already in use");
    assert authorize_service(cfg, "slack", "  team  ") == {"url": "https://connect.composio.dev/link/slack"};
    links = [c for c in S["calls"] if c["method"] == "POST" and c["path"].endswith("/link")];
    assert links[-1]["body"] == {"toolkit": "slack", "alias": "team"};
}

test "does not bypass the account cap when retrying pending connections" {
    _setup();
    cfg = _cfg();
    S["accounts_override"] = [{"id": "ca_pending_" + str(i), "status": "INITIALIZING", "toolkit": {"slug": "slack"}} for i in range(5)];
    def _a { authorize_service(cfg, "slack"); }
    _throws(_a, "maximum of 5 accounts", 409);
    def _b { authorize_service(cfg, "slack", "team"); }
    _throws(_b, "maximum of 5 accounts", 409);
    assert not any([c["method"] == "POST" and c["path"].endswith("/link") for c in S["calls"]]);
}

test "persists a recreated Session's ids when the saved one is gone" {
    _setup();
    cfg = {"composio": {"apiKey": "ak_test", "userId": "openmausbot_existing", "sessionId": "trs_deleted"}};
    connected_services(cfg);
    assert cfg["composio"]["sessionId"] == "trs_test";
    assert S["persisted"] == [{"userId": "openmausbot_existing", "sessionId": "trs_test"}];
}

# ── connector tool inventory ──────────────────────────────────────────────

def _initialize_calls -> int {
    return len([c for c in S["calls"] if c["path"].endswith("/v1/mcp") and isinstance(c["body"], dict) and c["body"].get("method") == "initialize"]);
}

test "groups an underscored service under its own slug using the connected services" {
    _setup();
    _broker("c");
    S["broker_connected"] = {"services": {"bland_ai": {"connected": True, "status": "ACTIVE"}, "github": {"connected": True, "status": "ACTIVE"}}};
    S["broker_tools"] = [{"name": "BLAND_AI_MAKE_CALL", "description": "place a call"}, {"name": "GITHUB_CREATE_ISSUE", "description": "open an issue"}];
    assert list_connector_tools({}) == {
        "bland_ai": [{"name": "BLAND_AI_MAKE_CALL", "description": "place a call"}],
        "github": [{"name": "GITHUB_CREATE_ISSUE", "description": "open an issue"}],
    };
}

test "re-walks after a backend switch instead of serving the cached inventory" {
    _setup();
    _broker("d");
    S["broker_tools"] = [{"name": "GITHUB_CREATE_ISSUE"}];
    assert list_connector_tools({}) == {"github": [{"name": "GITHUB_CREATE_ISSUE"}]};
    _broker("e");
    S["broker_tools"] = [{"name": "SLACK_POST_MESSAGE"}];
    before = _initialize_calls();
    assert list_connector_tools({}) == {"slack": [{"name": "SLACK_POST_MESSAGE"}]};
    assert _initialize_calls() == before + 1;
    # inside the window the same backend is served from cache
    assert list_connector_tools({}) == {"slack": [{"name": "SLACK_POST_MESSAGE"}]};
    assert _initialize_calls() == before + 1;
    list_connector_tools({}, True);
    assert _initialize_calls() == before + 2;
}

test "shares one in-flight walk between concurrent callers" {
    _setup();
    _broker("a");
    S["broker_tools"] = [{"name": "GITHUB_CREATE_ISSUE"}, {"name": "GITHUB_LIST_REPOS"}];
    S["init_delay"] = 0.3;
    before = _initialize_calls();
    results: list[any] = [None, None];
    def _run(i: int) { results[i] = list_connector_tools({}); }
    threads = [threading.Thread(target=_run, args=(i,)) for i in range(2)];
    for t in threads { t.start(); }
    for t in threads { t.join(); }
    assert results[0] == results[1] and results[0] is not None;
    assert _initialize_calls() == before + 1;
}

test "normalizes listings: drops meta and connection tools, dedupes, trims and sorts" {
    _setup();
    _broker("a");
    S["broker_tools"] = [
        {"name": "GMAIL_SEND_EMAIL", "description": "Send  an email"},
        {"name": "GMAIL_SEND_EMAIL", "description": "duplicate listing"},
        {"name": "GMAIL_FETCH_EMAILS", "description": "Fetch emails"},
        {"name": "SLACK_POST_MESSAGE", "description": "a" * 300},
        {"name": "COMPOSIO_SEARCH_TOOLS", "description": "meta"},
        {"name": "GMAIL_MANAGE_CONNECTIONS", "description": "flow"},
        {"name": "gmail_send_email", "description": "bad case"},
        {"name": "PLATFORM", "description": "no service"},
    ];
    out = list_connector_tools({});
    assert list(out.keys()) == ["gmail", "slack"];
    assert out["gmail"] == [{"name": "GMAIL_FETCH_EMAILS", "description": "Fetch emails"}, {"name": "GMAIL_SEND_EMAIL", "description": "Send an email"}];
    assert len(out["slack"][0]["description"]) == 240;
}

test "surfaces a tools/list failure with the upstream's own message" {
    _setup();
    _broker("a");
    S["broker_tools"] = [{"name": "GITHUB_CREATE_ISSUE"}];
    S["broker_tools_fail"] = True;
    def _walk { list_connector_tools({}); }
    _throws(_walk, "^tools list unavailable$");
}

# ── node seam: relay split, envelopes ─────────────────────────────────────

test "relays through the target/send seam with the scope note applied" {
    _setup();
    managed = {"access": {"url": ORIGIN + "/broker", "token": "a" * 64}};
    target = connectors_relay_target({}, None, managed);
    sent = connectors_relay_send(target["handle"], {"jsonrpc": "2.0", "id": 7, "method": "tools/list"}, []);
    assert sent["status"] == 200 and sent["transport_session_id"] == "mcp_broker";
    assert json.loads(base64.b64decode(sent["body_b64"])) == {"source": "broker"};
    # a handle is single-use
    again = connectors_relay_send(target["handle"], {}, []);
    assert again["ok"] is False and again["status"] == 409;
    # the first relay remembered mcp_broker, so the next target forwards it
    second = connectors_relay_target({}, "mcp_broker", managed);
    connectors_relay_send(second["handle"], {"jsonrpc": "2.0", "id": 8, "method": "tools/list"}, []);
    assert S["calls"][-1]["transportSessionId"] == "mcp_broker";
}

test "refuses a relayed response past 20 MB" {
    _setup();
    _broker("a");
    def _huge(url: str, headers: dict[str, any]) -> dict[str, any] {
        return {"status": 200, "headers": {"content-length": str(21 * 1024 * 1024)}, "body": b"{}"};
    }
    target = relay_prepare({}, None);
    target["url"] = "https://app.composio.dev/tool_router/huge";
    S["intercept"] = _huge;
    def _go { relay_dispatch(target, {}); }
    _throws(_go, "exceeded 20 MB");
}

test "classify and evaluate ops carry the refusal text" {
    _setup();
    c = connectors_classify_call({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "COMPOSIO_MULTI_EXECUTE_TOOL", "arguments": {"tools": []}}});
    assert c["call"]["kind"] == "unrecognized" and "the tools list was empty" in c["refusal"];
    legacy = connectors_evaluate(["GMAIL_SEND_EMAIL"], None, True, []);
    assert legacy["allowed"] is True and legacy["legacy"] is True and legacy["refusal"] is None;
    denied = connectors_evaluate(["GMAIL_SEND_EMAIL"], {}, False, []);
    assert denied["allowed"] is False and "\"GMAIL_SEND_EMAIL\" is not granted" in denied["refusal"];
}

test "the HTTP surface refuses a wrong shared secret" {
    _setup();
    os.environ["OMB_JAC_TOKEN"] = "expected-token";
    try {
        assert connectors_normalize_alias("x", "wrong") == {"ok": False, "status": 403, "error": "unauthorized"};
        assert connectors_normalize_alias(" x ", "expected-token") == {"alias": "x"};
        bad = connectors_normalize_alias("bad\nalias", "expected-token");
        assert bad["ok"] is False and bad["status"] == 400;
    } finally {
        os.environ.pop("OMB_JAC_TOKEN", None);
    }
}

# ── availability (composio-availability.test.ts) ──────────────────────────

test "connectorAvailability: configured, unconfigured, unreadable" {
    _setup();
    assert connector_availability({"composio": {"apiKey": "ak_live"}}, None) == "configured";
    assert connector_availability({}, None) == "unconfigured";
    assert connector_availability({"composio": {"apiKey": ""}}, "ok") == "unconfigured";
    assert connector_availability({}, "unavailable") == "unreadable";
    # a working key wins over a store that failed earlier in the launch
    assert connector_availability({"composio": {"apiKey": "ak_live"}}, "unavailable") == "configured";
}

test "connectorSetup: ready, needs-setup, service-unavailable only in the desktop app" {
    _setup();
    assert connector_setup({"composio": {"apiKey": "ak_live"}}, False) == "ready";
    assert connector_setup({"composio": {"apiKey": "ak_live"}}, True) == "ready";
    assert connector_setup({}, False) == "needs-setup";
    assert connector_setup({"composio": {"apiKey": ""}}, False) == "needs-setup";
    assert connector_setup({}, True) == "service-unavailable";
}

# ── the grants verdict (connector-verdict.test.ts) ────────────────────────

def _tools_call(name: str, args: any) -> dict[str, any] {
    return {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": name, "arguments": args}};
}

def _multi(args: any) -> dict[str, any] { return _tools_call(COMPOSIO_MULTI_EXECUTE_TOOL, args); }

test "connectorCallFromFrame passes non-tool traffic and meta-tools through untouched" {
    p = {"kind": "passthrough"};
    assert connector_call_from_frame({"jsonrpc": "2.0", "id": 1, "method": "initialize"}) == p;
    assert connector_call_from_frame({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}) == p;
    assert connector_call_from_frame(None) == p;
    assert connector_call_from_frame("notifications/initialized") == p;
    assert connector_call_from_frame(_tools_call("COMPOSIO_SEARCH_TOOLS", {"query": "gmail"})) == p;
    assert connector_call_from_frame(_tools_call("COMPOSIO_GET_TOOL_SCHEMAS", {"tools": ["GMAIL_SEND_EMAIL"]})) == p;
    assert connector_call_from_frame(_tools_call("GMAIL_MANAGE_CONNECTIONS", {})) == p;
    assert connector_call_from_frame(_tools_call("SLACK_WAIT_FOR_CONNECTIONS", {})) == p;
}

test "connectorCallFromFrame reads a direct per-toolkit call" {
    assert connector_call_from_frame(_tools_call("GMAIL_SEND_EMAIL", {"to": "a@b.c"})) == {"kind": "tools", "invoked": "GMAIL_SEND_EMAIL", "names": ["GMAIL_SEND_EMAIL"]};
}

test "connectorCallFromFrame reads every target from MULTI_EXECUTE, single and batched" {
    assert connector_call_from_frame(_multi({
        "tools": [{"tool_slug": "GMAIL_SEND_EMAIL", "arguments": {}}, {"tool_slug": "SLACK_POST_MESSAGE", "arguments": {}}],
        "sync_response_to_workbench": False,
    })) == {"kind": "tools", "invoked": COMPOSIO_MULTI_EXECUTE_TOOL, "names": ["GMAIL_SEND_EMAIL", "SLACK_POST_MESSAGE"]};
    assert connector_call_from_frame(_multi({"tools": [{"tool_slug": "GMAIL_SEND_EMAIL", "arguments": {}}], "sync_response_to_workbench": False}))
        == {"kind": "tools", "invoked": COMPOSIO_MULTI_EXECUTE_TOOL, "names": ["GMAIL_SEND_EMAIL"]};
    assert connector_call_from_frame(_multi({"tool_slug": "GMAIL_SEND_EMAIL", "arguments": {}}))
        == {"kind": "tools", "invoked": COMPOSIO_MULTI_EXECUTE_TOOL, "names": ["GMAIL_SEND_EMAIL"]};
}

test "connectorCallFromFrame denies unrecognized shapes by default" {
    for args in [{"sync_response_to_workbench": False}, {"tools": "GMAIL_SEND_EMAIL"}, {"tools": []}, {"tools": [{"arguments": {}}]}, {"tools": [{"tool_slug": 42, "arguments": {}}]}, "send the email", None] {
        assert connector_call_from_frame(_multi(args))["kind"] == "unrecognized";
    }
    assert connector_call_from_frame(_tools_call("gmail_send_email", {}))["kind"] == "unrecognized";
    assert connector_call_from_frame({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {}})["kind"] == "unrecognized";
    assert connector_call_from_frame({"jsonrpc": "2.0", "id": 4, "method": "tools/call"})["kind"] == "unrecognized";
}

test "serviceSlugFor maps a tool name to its service slug" {
    assert service_slug_for("GMAIL_SEND_EMAIL") == "gmail";
    assert service_slug_for("SLACK_POST_MESSAGE") == "slack";
    assert service_slug_for("GMAIL") is None;
    assert service_slug_for("_SEND") is None;
}

test "serviceSlugForCandidates prefers the longest whole-segment slug" {
    assert service_slug_for_candidates("BLAND_AI_MAKE_CALL", ["bland", "bland_ai"]) == "bland_ai";
    assert service_slug_for_candidates("GITHUB_CREATE_ISSUE", ["git", "github"]) == "github";
    assert service_slug_for_candidates("GITHUB_CREATE_ISSUE", ["git"]) is None;
    assert service_slug_for_candidates("BLAND_AI_MAKE_CALL", ["gmail", "slack"]) is None;
    assert service_slug_for_candidates("GMAIL_SEND_EMAIL", []) is None;
}

test "evaluateConnectorTools: legacy, empty, inherited keys, exact lists, stars" {
    assert evaluate_connector_tools(["GMAIL_SEND_EMAIL", "SLACK_POST_MESSAGE"], None, True, []) == {"allowed": True, "legacy": True, "denials": [], "rule": "composio"};
    empty = evaluate_connector_tools(["GMAIL_SEND_EMAIL"], {}, False, []);
    assert empty["allowed"] is False and empty["denials"] == [{"tool": "GMAIL_SEND_EMAIL", "service": "gmail", "onGrantedService": False}];
    inherited = evaluate_connector_tools(["CONSTRUCTOR_X", "TOSTRING_Y"], {}, False, []);
    assert inherited["denials"] == [
        {"tool": "CONSTRUCTOR_X", "service": "constructor", "onGrantedService": False},
        {"tool": "TOSTRING_Y", "service": "tostring", "onGrantedService": False},
    ];
    grants = {"gmail": {"tools": ["GMAIL_SEND_EMAIL"]}};
    ok = evaluate_connector_tools(["GMAIL_SEND_EMAIL"], grants, False, []);
    assert ok["allowed"] is True and ok["rule"] == "connectorTools.gmail";
    assert evaluate_connector_tools(["GMAIL_FETCH_EMAILS"], grants, False, [])["denials"] == [{"tool": "GMAIL_FETCH_EMAILS", "service": "gmail", "onGrantedService": True}];
    assert evaluate_connector_tools(["SLACK_POST_MESSAGE"], grants, False, [])["denials"] == [{"tool": "SLACK_POST_MESSAGE", "service": "slack", "onGrantedService": False}];
    star = {"gmail": {"tools": "*"}};
    assert evaluate_connector_tools(["GMAIL_SEND_EMAIL", "GMAIL_FETCH_EMAILS"], star, False, [])["allowed"] is True;
    assert evaluate_connector_tools(["SLACK_POST_MESSAGE"], star, False, [])["allowed"] is False;
    # a grant whose tools is a string is never a substring match
    assert evaluate_connector_tools(["GMAIL_SEND"], {"gmail": {"tools": "GMAIL_SEND_EMAIL"}}, False, [])["allowed"] is False;
}

test "evaluateConnectorTools keeps underscored services under their own grant" {
    grants = {"bland": {"tools": "*"}, "bland_ai": {"tools": ["BLAND_AI_MAKE_CALL"]}};
    v = evaluate_connector_tools(["BLAND_AI_MAKE_CALL"], grants, False, ["bland", "bland_ai"]);
    assert v["allowed"] is True and v["rule"] == "connectorTools.bland_ai";
    assert evaluate_connector_tools(["BLAND_AI_SEND_SMS"], grants, False, ["bland", "bland_ai"])["denials"] == [{"tool": "BLAND_AI_SEND_SMS", "service": "bland_ai", "onGrantedService": True}];
    assert evaluate_connector_tools(["BLAND_AI_MAKE_CALL"], {"bland": {"tools": "*"}}, False, ["bland_ai"])["denials"] == [{"tool": "BLAND_AI_MAKE_CALL", "service": "bland_ai", "onGrantedService": False}];
}

test "evaluateConnectorTools denies a serviceless name and judges a batch once per distinct tool" {
    v = evaluate_connector_tools(["GMAIL_SEND_EMAIL", "GMAIL_SEND_EMAIL", "GMAIL"], {"gmail": {"tools": "*"}}, False, []);
    assert v["allowed"] is False and v["denials"] == [{"tool": "GMAIL", "service": None, "onGrantedService": False}];
}

test "refusal text names the refused tools and the person, never the grants" {
    grants = {"gmail": {"tools": "*"}, "slack": {"tools": ["SLACK_POST_MESSAGE"]}};
    text = connector_refusal_text(evaluate_connector_tools(["SLACK_CREATE_CHANNEL"], grants, False, [])["denials"]);
    assert "SLACK_CREATE_CHANNEL" in text and "Ask the person" in text;
    assert "SLACK_POST_MESSAGE" not in text and "GMAIL" not in text;
    assert text == "\"SLACK_CREATE_CHANNEL\" is not granted to this bot. This call was not performed. Ask the person to grant it in OpenMausBot if they want it run.";
    batch = connector_refusal_text([
        {"tool": "SLACK_CREATE_CHANNEL", "service": "slack", "onGrantedService": True},
        {"tool": "NOTION_CREATE_PAGE", "service": "notion", "onGrantedService": False},
    ]);
    assert "SLACK_CREATE_CHANNEL" in batch and "NOTION_CREATE_PAGE" in batch and "are not granted" in batch;
    unread = connector_unrecognized_text(COMPOSIO_MULTI_EXECUTE_TOOL, "the tools list was empty");
    assert COMPOSIO_MULTI_EXECUTE_TOOL in unread and "the tools list was empty" in unread and "Ask the person" in unread;
}

# ── bridge env serialization (connector-advertisement.test.ts) ────────────

test "serializes a grants record for the bridge and flags one past the 32 KB cap" {
    record = {"gmail": {"tools": ["GMAIL_SEND_EMAIL", "GMAIL_GET_EMAIL"]}, "slack": {"tools": "*"}};
    out = serialize_connector_allowed_tools(record);
    assert out["oversized"] is False and json.loads(out["env"]) == record;
    names = ["GMAIL_TOOL_" + str(i).zfill(3) + "_WITH_" + "A_LONG_DESCRIPTOR_" * 6 for i in range(500)];
    big = serialize_connector_allowed_tools({"gmail": {"tools": names}});
    assert big == {"oversized": True};
    assert len(json.dumps({"gmail": {"tools": names}}, separators=(",", ":")).encode("utf-8")) > CONNECTOR_ALLOWED_TOOLS_MAX_BYTES;
}

test "serializes service slugs deduped, dropping non-slugs" {
    assert serialize_connector_service_slugs([]) == {"oversized": False};
    assert serialize_connector_service_slugs(["Bad Slug", 5]) == {"oversized": False};
    assert serialize_connector_service_slugs(["bland_ai", "bland", "bland_ai", "Bad Slug"]) == {"env": "[\"bland_ai\",\"bland\"]", "oversized": False};
}

# ── scope hint (connector-scope-hint.test.ts) ─────────────────────────────

glob REFUSED: dict[str, any] = {
    "jsonrpc": "2.0", "id": 7,
    "result": {
        "content": [{"type": "text", "text": "403 Forbidden: Request had insufficient authentication scopes. ACCESS_TOKEN_SCOPE_INSUFFICIENT"}],
        "isError": True,
    },
};

def _enc_json(v: any) -> bytes { return json.dumps(v).encode("utf-8"); }

test "adds the fix to a refused Gmail filter call and keeps Google's error" {
    out = json.loads(with_scope_hint(_enc_json(REFUSED), "application/json", ["GMAIL_CREATE_FILTER"]).decode("utf-8"));
    assert out["result"]["content"][0] == REFUSED["result"]["content"][0];
    assert out["result"]["isError"] is True;
    assert "https://www.googleapis.com/auth/gmail.settings.basic" in out["result"]["content"][1]["text"];
    assert "Do not retry" in out["result"]["content"][1]["text"];
}

test "names the sharing scope for forwarding and send-as tools" {
    assert "gmail.settings.sharing" in scope_hint(["GMAIL_ADD_FORWARDING_ADDRESS"]);
    assert "gmail.settings.sharing" in scope_hint(["GMAIL_CREATE_SEND_AS_ALIAS"]);
}

test "explains a refusal from another app without naming a scope it cannot know" {
    hint = scope_hint(["GOOGLECALENDAR_CREATE_EVENT"]);
    assert "Google refused this" in hint and "the permission this action needs" in hint;
    assert scope_hint([]).startswith("OpenMausBot note: This app refused this");
}

test "annotates a streamed (SSE) response" {
    body = "event: message\ndata: " + json.dumps(REFUSED) + "\n\n";
    out = with_scope_hint(body.encode("utf-8"), "text/event-stream", ["GMAIL_CREATE_FILTER"]).decode("utf-8");
    data = [l for l in out.split("\n") if l.startswith("data:")][0];
    assert len(json.loads(data[5:])["result"]["content"]) == 2;
    assert out.startswith("event: message\n");
}

test "returns every other response byte for byte" {
    ok = _enc_json({"jsonrpc": "2.0", "id": 1, "result": {"content": [{"type": "text", "text": "relay-ok"}]}});
    assert with_scope_hint(ok, "application/json", ["GMAIL_SEND_EMAIL"]) is ok;
    unreadable = b"ACCESS_TOKEN_SCOPE_INSUFFICIENT but not JSON";
    assert with_scope_hint(unreadable, "application/json", ["GMAIL_CREATE_FILTER"]) is unreadable;
}

# ── JS-faithful helpers ───────────────────────────────────────────────────

test "URL, query and collation helpers match the WHATWG / ICU behavior the TS relied on" {
    assert _js_url("https://App.Composio.dev:443")["href"] == "https://app.composio.dev/";
    assert _js_url("http://[::1]:3210/root/")["hostname"] == "[::1]";
    assert _js_url("http://127.0.0.1:80/x")["origin"] == "http://127.0.0.1";
    _throws(_bad_url, "Invalid URL");
    assert _params([("services", "github,slack"), ("q", "a b~*")]) == "services=github%2Cslack&q=a+b%7E*";
    assert _enc("a/b c") == "a%2Fb%20c";
    assert _locale_sorted(["a-b", "a_b", "a1", "ab", "aB", "Ab", "a b"], str) == ["a b", "a_b", "a-b", "a1", "ab", "aB", "Ab"];
    assert _trim("﻿ x  ") == "x";
}

def _bad_url { _js_url("not a url"); }
