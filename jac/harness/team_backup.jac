"""Portable team backups on Jac (phase 4).

Faithful port of server/team-backup.ts (createTeamBackup / importTeamBackup)
and of shared/team-backup.ts's parseTeamBackup (zod 4 first-issue messages,
shape-ordered output, unknown keys stripped). The Store is still node's:

  export  - node gathers a raw snapshot (bots, groups, per-thread messages and
            active leaf, raw memory texts) and passes it as op args; this
            module does messageText/history/responder fixups, routine
            filtering (routines.jac, in-process), memory redaction, schema
            validation and the 50 MB limit.
  import  - this module parses, plans and orchestrates; every store mutation
            is one `team_store` bridge op ({call, args}) answered by a sync
            Store call node-side. Imported routines are created/rolled back
            in-process through routines.jac (always enabled:false).

Hooks (`_tb["hooks"]`) let tests swap the store bridge, routines and clock.
"""

import os;
import re;
import time;
import uuid;

import from jsutil { js_stringify, js_number }
import from routines {
    _bridge,
    _ensure_booted,
    _list_routines,
    _create as _routines_create,
    _remove as _routines_remove,
    redact_secrets_in_text,
}

glob MAX_TEAM_BACKUP_BYTES: int = 50 * 1024 * 1024;

glob _tb: dict[str, any] = {};

class TeamBackupError(Exception) {
    # Error carrying an HTTP status (JS `Object.assign(new Error, {status})`).
}

def _fail(status: int, message: str) {
    err = TeamBackupError(message);
    setattr(err, "status", status);
    raise err;
}

def _status_of(e: Exception) -> int {
    s = getattr(e, "status", None);
    return s if isinstance(s, int) and not isinstance(s, bool) else 500;
}

# ── hooks ─────────────────────────────────────────────────────────────────

def _hook_store(call: str, args: dict[str, any]) -> any {
    res = _bridge("team_store", {"call": call, "args": args});
    if res.get("ok") is False {
        raise Exception(str(res.get("error") or "team store call failed"));
    }
    return res.get("result");
}

def _hook_routines_list -> list[any] {
    _ensure_booted();
    return _list_routines();
}

def _hook_routine_create(input: dict[str, any]) -> dict[str, any] {
    _ensure_booted();
    return _routines_create(input, None);
}

def _hook_routine_remove(rid: str) -> bool {
    _ensure_booted();
    return _routines_remove(rid, None);
}

def _hook_now -> int {
    return int(time.time() * 1000);
}

def _hook_new_id -> str {
    return str(uuid.uuid4());
}

def _default_hooks -> dict[str, any] {
    return {
        "store": _hook_store,
        "routines_list": _hook_routines_list,
        "routine_create": _hook_routine_create,
        "routine_remove": _hook_routine_remove,
        "now": _hook_now,
        "new_id": _hook_new_id,
    };
}

def _reset -> None {
    _tb.update({"hooks": _default_hooks()});
}

def _hook(name: str) -> any {
    return _tb["hooks"][name];
}

def _store(call: str, args: dict[str, any]) -> any {
    return _hook("store")(call, args);
}

def _new_id -> str {
    return _hook("new_id")();
}

# ── JS-semantics helpers ──────────────────────────────────────────────────

glob _MISSING: any = object();
glob _JS_WS: str = "\t\n\u000b\u000c\r                  　﻿";

def _js_trim(s: str) -> str {
    return s.strip(_JS_WS);
}

def _js_trim_end(s: str) -> str {
    return s.rstrip(_JS_WS);
}

def _u16(s: str) -> bytes {
    return s.encode("utf-16-le", "surrogatepass");
}

def _js_len(s: str) -> int {
    return len(_u16(s)) // 2;
}

def _js_slice(s: str, start: int, end: int) -> str {
    b = _u16(s);
    return b[start * 2:end * 2].decode("utf-16-le", "surrogatepass");
}

def _js_type(v: any) -> str {
    if v is _MISSING { return "undefined"; }
    if v is None { return "null"; }
    if isinstance(v, bool) { return "boolean"; }
    if isinstance(v, int) or isinstance(v, float) { return "number"; }
    if isinstance(v, str) { return "string"; }
    if isinstance(v, list) { return "array"; }
    if isinstance(v, dict) { return "object"; }
    return "unknown";
}

def _is_num(v: any) -> bool {
    return (isinstance(v, int) or isinstance(v, float)) and not isinstance(v, bool);
}

# `${value}` in a JS template literal.
def _tpl(rec: dict[str, any], key: str) -> str {
    if key not in rec { return "undefined"; }
    v = rec[key];
    if v is None { return "null"; }
    if isinstance(v, bool) { return "true" if v else "false"; }
    if _is_num(v) { return js_number(v); }
    if isinstance(v, str) { return v; }
    return "[object Object]" if isinstance(v, dict) else ",".join([str(x) for x in v]);
}

def _truthy(v: any) -> bool {
    if v is None or v is False or v is _MISSING { return False; }
    if isinstance(v, str) { return len(v) > 0; }
    if _is_num(v) { return v != 0; }
    return True;
}

def _rec(v: any) -> dict[str, any] {
    return v if isinstance(v, dict) else {};
}

# ── parseTeamBackup (shared/team-backup.ts) ───────────────────────────────

def _issue(path: list[any], message: str) {
    label = ".".join([str(p) for p in path]) or "file";
    _fail(400, f"Invalid backup: {label}: {message}");
}

def _expected(path: list[any], want: str, v: any) {
    _issue(path, f"Invalid input: expected {want}, received {_js_type(v)}");
}

def _p_str(v: any, path: list[any], minl: int = -1, maxl: int = -1, trim: bool = False, pattern: any = None, src: str = "") -> str {
    if not isinstance(v, str) { _expected(path, "string", v); }
    s = _js_trim(v) if trim else v;
    if pattern is not None and not pattern.search(s) {
        _issue(path, f"Invalid string: must match pattern {src}");
    }
    n = _js_len(s);
    if minl >= 0 and n < minl { _issue(path, f"Too small: expected string to have >={minl} characters"); }
    if maxl >= 0 and n > maxl { _issue(path, f"Too big: expected string to have <={maxl} characters"); }
    return s;
}

def _p_num(v: any, path: list[any], integer: bool = False, lo: any = None, lo_excl: bool = False, hi: any = None) -> any {
    if not _is_num(v) { _expected(path, "number", v); }
    if integer and not (isinstance(v, int) or v.is_integer()) {
        _issue(path, "Invalid input: expected int, received number");
    }
    if lo is not None {
        if lo_excl and not v > lo { _issue(path, f"Too small: expected number to be >{lo}"); }
        if not lo_excl and v < lo { _issue(path, f"Too small: expected number to be >={lo}"); }
    }
    if hi is not None and v > hi { _issue(path, f"Too big: expected number to be <={hi}"); }
    return v;
}

def _p_bool(v: any, path: list[any]) -> bool {
    if not isinstance(v, bool) { _expected(path, "boolean", v); }
    return v;
}

def _p_true(v: any, path: list[any]) -> bool {
    if v is not True { _issue(path, "Invalid input: expected true"); }
    return True;
}

def _p_enum(v: any, path: list[any], opts: list[str]) -> str {
    if not isinstance(v, str) or v not in opts {
        _issue(path, "Invalid option: expected one of " + "|".join([js_stringify(o) for o in opts]));
    }
    return v;
}

def _p_obj(v: any, path: list[any]) -> dict[str, any] {
    if not isinstance(v, dict) { _expected(path, "object", v); }
    return v;
}

def _p_arr(v: any, path: list[any], item: any, minn: int = -1, maxn: int = -1) -> list[any] {
    if not isinstance(v, list) { _expected(path, "array", v); }
    out = [];
    i = 0;
    for x in v {
        out.append(item(x, path + [i]));
        i += 1;
    }
    if minn >= 0 and len(v) < minn { _issue(path, f"Too small: expected array to have >={minn} items"); }
    if maxn >= 0 and len(v) > maxn { _issue(path, f"Too big: expected array to have <={maxn} items"); }
    return out;
}

def _get(v: dict[str, any], k: str) -> any {
    return v[k] if k in v else _MISSING;
}

# Optional key: absent stays absent; present (even null) must parse.
def _opt(out: dict[str, any], v: dict[str, any], k: str, fn: any, path: list[any]) {
    if k in v { out[k] = fn(v[k], path + [k]); }
}

glob _KEY_MAX: int = 200;
glob COLORS: list[str] = ["green", "blue", "red", "orange", "purple", "cyan", "pink", "yellow", "teal", "coral"];
glob _TOPIC_RE: any = re.compile(r"^[\w][\w .-]{0,199}\.md$", re.ASCII);
glob _LOG_RE: any = re.compile(r"^\d{4}-\d{2}-\d{2}\.md$", re.ASCII);
glob _TIME_RE: any = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$", re.ASCII);
glob _SLUG_RE: any = re.compile(r"^[a-z0-9][a-z0-9_-]{0,80}$");
glob _TOOL_RE: any = re.compile(r"^[A-Z][A-Z0-9_]{0,127}$");
glob _SERVER_RE: any = re.compile(r"^[a-z][a-z0-9_-]{0,31}$");
glob _CONTROL_RE: any = re.compile(r"[\x00-\x1f\x7f]");

def _key(v: any, path: list[any]) -> str { return _p_str(v, path, 1, _KEY_MAX); }
def _name(v: any, path: list[any]) -> str { return _p_str(v, path, 1, 200, True); }
def _ts(v: any, path: list[any]) -> any { return _p_num(v, path, False, 0); }
def _nullable_key(v: any, path: list[any]) -> any {
    if v is None { return None; }
    return _key(v, path);
}

def _p_message(v: any, path: list[any]) -> dict[str, any] {
    _p_obj(v, path);
    out: dict[str, any] = {};
    out["id"] = _key(_get(v, "id"), path + ["id"]);
    out["role"] = _p_enum(_get(v, "role"), path + ["role"], ["bot", "user"]);
    out["text"] = _p_str(_get(v, "text"), path + ["text"], -1, 2000000);
    out["at"] = _ts(_get(v, "at"), path + ["at"]);
    out["parentId"] = _nullable_key(_get(v, "parentId"), path + ["parentId"]);
    _opt(out, v, "replyToId", _key, path);
    def _from(x: any, p: list[any]) -> dict[str, any] {
        _p_obj(x, p);
        return {
            "botId": _key(_get(x, "botId"), p + ["botId"]),
            "name": _name(_get(x, "name"), p + ["name"]),
            "color": _p_str(_get(x, "color"), p + ["color"], -1, 40),
        };
    }
    _opt(out, v, "from", _from, path);
    def _peer(x: any, p: list[any]) -> dict[str, any] {
        _p_obj(x, p);
        o: dict[str, any] = {};
        _opt(o, x, "unattended", _p_bool, p);
        return o;
    }
    _opt(out, v, "peerPost", _peer, path);
    return out;
}

def _p_task(v: any, path: list[any]) -> dict[str, any] {
    _p_obj(v, path);
    out: dict[str, any] = {};
    out["key"] = _key(_get(v, "key"), path + ["key"]);
    out["title"] = _p_str(_get(v, "title"), path + ["title"], -1, 2000);
    out["createdAt"] = _ts(_get(v, "createdAt"), path + ["createdAt"]);
    _opt(out, v, "titleFromFirstMessage", _p_true, path);
    def _opened(x: any, p: list[any]) -> dict[str, any] {
        _p_obj(x, p);
        o: dict[str, any] = {
            "botId": _key(_get(x, "botId"), p + ["botId"]),
            "name": _name(_get(x, "name"), p + ["name"]),
            "at": _ts(_get(x, "at"), p + ["at"]),
        };
        def _kind(k: any, kp: list[any]) -> str { return _p_enum(k, kp, ["pair", "work"]); }
        _opt(o, x, "kind", _kind, p);
        return o;
    }
    _opt(out, v, "openedBy", _opened, path);
    def _closed(x: any, p: list[any]) -> dict[str, any] {
        _p_obj(x, p);
        return {
            "botId": _key(_get(x, "botId"), p + ["botId"]),
            "name": _name(_get(x, "name"), p + ["name"]),
            "at": _ts(_get(x, "at"), p + ["at"]),
        };
    }
    _opt(out, v, "closedBy", _closed, path);
    _opt(out, v, "pinned", _p_true, path);
    def _ttm(x: any, p: list[any]) -> any { return _p_num(x, p, True, 1, False, 1440); }
    _opt(out, v, "turnTimeoutMinutes", _ttm, path);
    out["activeLeafId"] = _nullable_key(_get(v, "activeLeafId"), path + ["activeLeafId"]);
    out["messages"] = _p_arr(_get(v, "messages"), path + ["messages"], _p_message, -1, 100000);
    return out;
}

def _p_owner(v: any, path: list[any], out: dict[str, any]) {
    out["key"] = _key(_get(v, "key"), path + ["key"]);
    out["name"] = _name(_get(v, "name"), path + ["name"]);
    def _section(x: any, p: list[any]) -> str { return _p_str(x, p, -1, 200); }
    _opt(out, v, "section", _section, path);
    out["activeTask"] = _key(_get(v, "activeTask"), path + ["activeTask"]);
    out["tasks"] = _p_arr(_get(v, "tasks"), path + ["tasks"], _p_task, 1, 10000);
}

def _p_playbook(v: any, path: list[any]) -> dict[str, any] {
    _p_obj(v, path);
    def _trigger(x: any, p: list[any]) -> str { return _p_str(x, p, -1, 2000); }
    return {
        "key": _key(_get(v, "key"), path + ["key"]),
        "name": _name(_get(v, "name"), path + ["name"]),
        "summary": _p_str(_get(v, "summary"), path + ["summary"], -1, 24000),
        "triggers": _p_arr(_get(v, "triggers"), path + ["triggers"], _trigger, -1, 100),
        "instructions": _p_str(_get(v, "instructions"), path + ["instructions"], -1, 200000),
    };
}

def _p_memory(v: any, path: list[any]) -> dict[str, any] {
    _p_obj(v, path);
    def _topic(x: any, p: list[any]) -> dict[str, any] {
        _p_obj(x, p);
        return {
            "name": _p_str(_get(x, "name"), p + ["name"], -1, -1, False, _TOPIC_RE, "/^[\\w][\\w .-]{0,199}\\.md$/"),
            "text": _p_str(_get(x, "text"), p + ["text"], -1, 2000000),
        };
    }
    def _log(x: any, p: list[any]) -> dict[str, any] {
        _p_obj(x, p);
        return {
            "name": _p_str(_get(x, "name"), p + ["name"], -1, -1, False, _LOG_RE, "/^\\d{4}-\\d{2}-\\d{2}\\.md$/"),
            "text": _p_str(_get(x, "text"), p + ["text"], -1, 2000000),
        };
    }
    return {
        "file": _p_str(_get(v, "file"), path + ["file"], -1, 2000000),
        "topics": _p_arr(_get(v, "topics"), path + ["topics"], _topic, -1, 1000),
        "logs": _p_arr(_get(v, "logs"), path + ["logs"], _log, -1, 10000),
    };
}

def _p_connector_tools(v: any, path: list[any]) -> dict[str, any] {
    _p_obj(v, path);
    out: dict[str, any] = {};
    for (slug, grant) in v.items() {
        p = path + [slug];
        if not _SLUG_RE.search(slug) { _issue(p, "Invalid key in record"); }
        _p_obj(grant, p);
        tools = _get(grant, "tools");
        tp = p + ["tools"];
        if tools == "*" {
            out[slug] = {"tools": "*"};
        } elif isinstance(tools, list) {
            def _tool(x: any, xp: list[any]) -> str {
                return _p_str(x, xp, -1, -1, False, _TOOL_RE, "/^[A-Z][A-Z0-9_]{0,127}$/");
            }
            out[slug] = {"tools": _p_arr(tools, tp, _tool, 1, 500)};
        } else {
            _issue(tp, "Invalid input");
        }
    }
    return out;
}

# shared/tool-scope.ts parseToolScope / selectorIdentity / validName.
def _valid_tool_name(name: any) -> bool {
    return isinstance(name, str) and len(_js_trim(name)) > 0 and _js_len(name) <= 1024
        and not _CONTROL_RE.search(name) and "*" not in name;
}

def _selector_ok(selector: str) -> bool {
    if _js_len(selector) > 1024 or _CONTROL_RE.search(selector) { return False; }
    if selector.startswith("native:") {
        name = selector[7:];
        return name == "*" or _valid_tool_name(name);
    }
    if selector.startswith("mcp:") {
        sep = selector.find(":", 4);
        if sep < 0 { return False; }
        server = selector[4:sep];
        name = selector[sep + 1:];
        return bool(_SERVER_RE.search(server)) and (name == "*" or _valid_tool_name(name));
    }
    return False;
}

def parse_tool_scope(value: any) -> any {
    # Returns the normalized scope, or _MISSING when invalid.
    if not isinstance(value, dict) { return _MISSING; }
    scope: dict[str, any] = {};
    for (k, lst) in value.items() {
        if k != "allow" and k != "deny" { return _MISSING; }
        if not isinstance(lst, list) or len(lst) > 256 { return _MISSING; }
        for item in lst {
            if not isinstance(item, str) or not _selector_ok(item) { return _MISSING; }
        }
        seen: list[str] = [];
        for item in lst {
            if item not in seen { seen.append(item); }
        }
        scope[k] = seen;
    }
    return scope;
}

def _p_tool_scope(v: any, path: list[any]) -> dict[str, any] {
    scope = parse_tool_scope(v);
    if scope is _MISSING { _issue(path, "Invalid tool selection"); }
    return scope;
}

def _p_soul(v: any, path: list[any]) -> str {
    if not isinstance(v, str) { _expected(path, "string", v); }
    if len(v.encode("utf-8", "surrogatepass")) > 24000 {
        _issue(path, "standing instructions must be at most 24000 bytes");
    }
    return v;
}

def _p_bot(v: any, path: list[any]) -> dict[str, any] {
    _p_obj(v, path);
    out: dict[str, any] = {};
    _p_owner(v, path, out);
    out["title"] = _p_str(_get(v, "title"), path + ["title"], -1, 2000);
    out["description"] = _p_str(_get(v, "description"), path + ["description"], -1, 200000);
    _opt(out, v, "soul", _p_soul, path);
    out["color"] = _p_enum(_get(v, "color"), path + ["color"], COLORS);
    def _expr(x: any, p: list[any]) -> str { return _p_str(x, p, -1, 80); }
    def _body(x: any, p: list[any]) -> str { return _p_str(x, p, -1, 40); }
    _opt(out, v, "mascotExpression", _expr, path);
    _opt(out, v, "mascotBody", _body, path);
    out["chiefOfStaff"] = _p_bool(_get(v, "chiefOfStaff"), path + ["chiefOfStaff"]);
    out["hidden"] = _p_bool(_get(v, "hidden"), path + ["hidden"]);
    out["playbooks"] = _p_arr(_get(v, "playbooks"), path + ["playbooks"], _p_playbook, -1, 200);
    _opt(out, v, "connectorTools", _p_connector_tools, path);
    _opt(out, v, "toolScope", _p_tool_scope, path);
    _opt(out, v, "memory", _p_memory, path);
    return out;
}

# knownRoomResponder: an unknown responder kind from a newer release
# restores as the first member as lead; malformed values still fail.
def _known_room_responder(value: any) -> any {
    if not isinstance(value, dict) { return value; }
    resp = value.get("defaultResponder");
    kind = resp.get("kind") if isinstance(resp, dict) and _truthy(resp) else None;
    if not isinstance(kind, str) or kind in ["member", "everyone", "mentions", "auto"] { return value; }
    members = value.get("memberIds");
    first = members[0] if isinstance(members, list) and len(members) > 0 and isinstance(members[0], str) else None;
    fixed = dict(value);
    fixed["defaultResponder"] = {"kind": "member", "botId": first} if first is not None else {"kind": "mentions"};
    return fixed;
}

def _p_responder(v: any, path: list[any]) -> dict[str, any] {
    _p_obj(v, path);
    kind = _get(v, "kind");
    if kind not in ["member", "everyone", "mentions", "auto"] {
        _issue(path + ["kind"], "Invalid discriminator value. Expected 'member' | 'everyone' | 'mentions' | 'auto'");
    }
    out: dict[str, any] = {"kind": kind};
    if kind == "member" { out["botId"] = _key(_get(v, "botId"), path + ["botId"]); }
    if kind == "auto" { _opt(out, v, "fallbackBotId", _key, path); }
    return out;
}

def _p_group(raw: any, path: list[any]) -> dict[str, any] {
    v = _known_room_responder(raw);
    _p_obj(v, path);
    out: dict[str, any] = {};
    _p_owner(v, path, out);
    out["memberIds"] = _p_arr(_get(v, "memberIds"), path + ["memberIds"], _key, -1, 200);
    out["dm"] = _p_bool(_get(v, "dm"), path + ["dm"]);
    out["bulletin"] = _p_str(_get(v, "bulletin"), path + ["bulletin"], -1, 200000);
    out["defaultResponder"] = _p_responder(_get(v, "defaultResponder"), path + ["defaultResponder"]);
    return out;
}

def _p_schedule(v: any, path: list[any]) -> dict[str, any] {
    _p_obj(v, path);
    kind = _get(v, "type");
    if kind not in ["once", "daily", "interval"] {
        _issue(path + ["type"], "Invalid discriminator value. Expected 'once' | 'daily' | 'interval'");
    }
    if kind == "once" { return {"type": "once", "at": _ts(_get(v, "at"), path + ["at"])}; }
    if kind == "daily" {
        def _day(x: any, p: list[any]) -> any { return _p_num(x, p, True, 0, False, 6); }
        return {
            "type": "daily",
            "time": _p_str(_get(v, "time"), path + ["time"], -1, -1, False, _TIME_RE, "/^([01]\\d|2[0-3]):[0-5]\\d$/"),
            "weekdays": _p_arr(_get(v, "weekdays"), path + ["weekdays"], _day, 1, 7),
        };
    }
    return {
        "type": "interval",
        "everyMinutes": _p_num(_get(v, "everyMinutes"), path + ["everyMinutes"], True, 5, False, 1440),
        "anchorAt": _p_num(_get(v, "anchorAt"), path + ["anchorAt"], True, 0, False, 8640000000000000),
    };
}

def _p_routine(v: any, path: list[any]) -> dict[str, any] {
    _p_obj(v, path);
    out: dict[str, any] = {};
    out["name"] = _name(_get(v, "name"), path + ["name"]);
    out["prompt"] = _p_str(_get(v, "prompt"), path + ["prompt"], 1, 200000, True);
    out["target"] = _p_enum(_get(v, "target"), path + ["target"], ["bot", "room-goal"]);
    out["botId"] = _key(_get(v, "botId"), path + ["botId"]);
    _opt(out, v, "groupId", _key, path);
    out["runOn"] = _p_enum(_get(v, "runOn"), path + ["runOn"], ["maus", "cloud"]);
    out["schedule"] = _p_schedule(_get(v, "schedule"), path + ["schedule"]);
    out["durationMinutes"] = _p_num(_get(v, "durationMinutes"), path + ["durationMinutes"], False, 0, True);
    def _timeout(x: any, p: list[any]) -> any { return _p_num(x, p, True, 5, False, 240); }
    _opt(out, v, "timeoutMinutes", _timeout, path);
    return out;
}

def _p_backup(v: any) -> dict[str, any] {
    _p_obj(v, []);
    out: dict[str, any] = {};
    if _get(v, "format") != "openmaus.backup" { _issue(["format"], "Invalid input: expected \"openmaus.backup\""); }
    out["format"] = "openmaus.backup";
    ver = _get(v, "version");
    if not _is_num(ver) or ver != 1 { _issue(["version"], "Invalid input: expected 1"); }
    out["version"] = 1;
    out["name"] = _name(_get(v, "name"), ["name"]);
    out["exportedAt"] = _ts(_get(v, "exportedAt"), ["exportedAt"]);
    def _warning(x: any, p: list[any]) -> str { return _p_str(x, p, -1, 2000); }
    out["warnings"] = _p_arr(v["warnings"], ["warnings"], _warning, -1, 4000) if "warnings" in v else [];
    out["bots"] = _p_arr(_get(v, "bots"), ["bots"], _p_bot, 1, 200);
    out["groups"] = _p_arr(_get(v, "groups"), ["groups"], _p_group, -1, 2000);
    out["routines"] = _p_arr(_get(v, "routines"), ["routines"], _p_routine, -1, 2000);
    return out;
}

def _invalid(message: str) {
    _fail(400, "Invalid backup: " + message);
}

def _unique(keys: list[any], label: str) -> set[any] {
    s = set(keys);
    if len(s) != len(keys) { _invalid(f"duplicate {label}"); }
    return s;
}

# Validate the whole reference graph before an import can write anything.
def parse_team_backup(input: any) -> dict[str, any] {
    backup = _p_backup(input);
    bots = _unique([b["key"] for b in backup["bots"]], "bot key");
    groups = _unique([g["key"] for g in backup["groups"]], "room key");
    chiefs: set[str] = set();
    for bot in backup["bots"] {
        if not bot["chiefOfStaff"] { continue; }
        section = _js_trim(bot["section"]) if "section" in bot else "";
        if section in chiefs or bot["hidden"] {
            _invalid("a section must have at most one visible Chief of Staff");
        }
        chiefs.add(section);
    }
    for group in backup["groups"] {
        if any([mid not in bots for mid in group["memberIds"]]) { _invalid("unknown room member"); }
        _unique(group["memberIds"], "room member");
        resp = group["defaultResponder"];
        lead: any = None;
        if resp["kind"] == "member" { lead = resp["botId"]; }
        if resp["kind"] == "auto" { lead = resp.get("fallbackBotId"); }
        if lead is not None and lead not in group["memberIds"] {
            _invalid("room responder is not a member");
        }
        if group["dm"] and (len(group["memberIds"]) != 2 or len(group["tasks"]) != 1) {
            _invalid("invalid direct-message room");
        }
    }
    for routine in backup["routines"] {
        if routine["botId"] not in bots { _invalid("unknown routine bot"); }
        if routine["target"] == "room-goal" {
            if routine["runOn"] != "maus" { _invalid("room goals must run on this computer"); }
            gid = routine.get("groupId") or "";
            found: any = None;
            for candidate in backup["groups"] {
                if candidate["key"] == routine.get("groupId") { found = candidate; break; }
            }
            if gid not in groups or found is None or found["dm"] or routine["botId"] not in found["memberIds"] {
                _invalid("unknown routine room or coordinator");
            }
        }
    }
    for item in backup["bots"] + backup["groups"] {
        tasks = _unique([t["key"] for t in item["tasks"]], "task key");
        if item["activeTask"] not in tasks { _invalid("unknown active task"); }
        for task in item["tasks"] {
            messages = _unique([m["id"] for m in task["messages"]], "message key");
            seen: set[str] = set();
            for message in task["messages"] {
                # Parents must precede children: rejects cycles and dangling branches.
                if message["parentId"] is not None and message["parentId"] not in seen {
                    _invalid("invalid conversation branch");
                }
                if _truthy(message.get("replyToId")) and message["replyToId"] not in messages {
                    _invalid("unknown reply");
                }
                seen.add(message["id"]);
            }
            if task["activeLeafId"] is not None and task["activeLeafId"] not in messages {
                _invalid("unknown conversation head");
            }
        }
    }
    return backup;
}

# ── export ────────────────────────────────────────────────────────────────

# A bot's memory as it travels, scrubbed on the way out. Absent when the bot
# has none. `raw` is node's {file, topics:[{name,text|null}], logs:[...]}.
def _memory_for(raw: any) -> any {
    r = _rec(raw);
    file = redact_secrets_in_text(r.get("file") or "");
    topics = [];
    for topic in (r.get("topics") or []) {
        if topic.get("text") is None { continue; }
        topics.append({"name": topic["name"], "text": redact_secrets_in_text(topic["text"])});
    }
    logs = [];
    for log in (r.get("logs") or []) {
        if log.get("text") is None { continue; }
        logs.append({"name": log["name"], "text": redact_secrets_in_text(log["text"])});
    }
    if not file and not topics and not logs { return None; }
    return {"file": file, "topics": topics, "logs": logs};
}

# Readable history without executable cards, queue entries, approvals, local
# paths or provider session handles.
def message_text(message: dict[str, any]) -> str {
    parts: list[any] = [message.get("text") or ""];
    card: any = message.get("card");
    if _truthy(card) {
        parts.append(card.get("title"));
        parts.append(card.get("subtitle"));
        for option in (card.get("options") or []) { parts.append(option); }
        parts.append(card.get("answered") or "");
    }
    tool: any = message.get("tool");
    if _truthy(tool) {
        failed = ": failed" if tool.get("ok") is False else "";
        parts.append(f"[{_tpl(tool, 'name')}{failed}]");
    }
    if message.get("kind") == "connector" { parts.append("[Connection card — reconnect in Settings]"); }
    if message.get("kind") == "secret" { parts.append("[Secret request — not restored]"); }
    run: any = message.get("routineRun");
    if _truthy(run) {
        parts.append(f"[Routine: {_tpl(run, 'routineName')} — {_tpl(run, 'status')}]");
        parts.append(run.get("summary") or "");
        parts.append(run.get("error") or "");
    }
    goal: any = message.get("goalRun");
    if _truthy(goal) {
        parts.append(f"[Room goal: {_tpl(goal, 'status')}]");
        parts.append(goal.get("goal"));
        parts.append(goal.get("detail") or "");
    }
    attachments = message.get("attachments");
    if message.get("kind") == "screen" or (isinstance(attachments, list) and len(attachments) > 0) {
        parts.append("[Image or attachment — file not included in this backup]");
    }
    return "\n".join([p if isinstance(p, str) else str(p) for p in parts if _truthy(p)]);
}

def _history(record: dict[str, any], threads: dict[str, any]) -> list[any] {
    tasks = record.get("tasks");
    if not isinstance(tasks, list) or len(tasks) == 0 {
        tasks = [{"threadId": record.get("threadId"), "title": "Conversation", "createdAt": record.get("createdAt")}];
    }
    out = [];
    for task in tasks {
        thread = _rec(threads.get(task.get("threadId")));
        item: dict[str, any] = {"key": task.get("threadId"), "title": task.get("title"), "createdAt": task.get("createdAt")};
        if task.get("titleFromFirstMessage") is True { item["titleFromFirstMessage"] = True; }
        opened = task.get("openedBy");
        if _truthy(opened) {
            o: dict[str, any] = {"botId": opened.get("botId"), "name": opened.get("name"), "at": opened.get("at")};
            if _truthy(opened.get("kind")) { o["kind"] = opened["kind"]; }
            item["openedBy"] = o;
        }
        closed = task.get("closedBy");
        if _truthy(closed) {
            item["closedBy"] = {"botId": closed.get("botId"), "name": closed.get("name"), "at": closed.get("at")};
        }
        if task.get("pinned") is True { item["pinned"] = True; }
        if _is_num(task.get("turnTimeoutMinutes")) { item["turnTimeoutMinutes"] = task["turnTimeoutMinutes"]; }
        item["activeLeafId"] = thread.get("activeLeaf");
        messages = [];
        for message in (thread.get("messages") or []) {
            m: dict[str, any] = {
                "id": message.get("id"), "role": message.get("role"), "text": message_text(message),
                "at": message.get("at"), "parentId": message.get("parentId"),
            };
            for k in ["replyToId", "from", "peerPost"] {
                if message.get(k) is not None { m[k] = message[k]; }
            }
            messages.append(m);
        }
        item["messages"] = messages;
        out.append(item);
    }
    return out;
}

def create_team_backup(snapshot: dict[str, any], name: str) -> dict[str, any] {
    bots_raw: list[any] = snapshot.get("bots") or [];
    groups_raw: list[any] = snapshot.get("groups") or [];
    threads: dict[str, any] = snapshot.get("threads") or {};
    memory: dict[str, any] = snapshot.get("memory") or {};
    bot_ids = set([b.get("id") for b in bots_raw]);
    warnings: list[str] = [];
    groups = [];
    for group in groups_raw {
        member_ids = [mid for mid in group.get("memberIds", []) if mid in bot_ids];
        if len(member_ids) != len(group.get("memberIds", [])) {
            warnings.append(f"Room “{_tpl(group, 'name')}” contains deleted bots. Its conversation is included with the remaining members.");
        }
        resp = _rec(group.get("defaultResponder"));
        responder: any = resp;
        if resp.get("kind") == "member" and resp.get("botId") not in member_ids {
            responder = {"kind": "mentions"};
        } elif resp.get("kind") == "auto" and _truthy(resp.get("fallbackBotId")) and resp.get("fallbackBotId") not in member_ids {
            responder = {"kind": "auto"};
        }
        tasks = _history(group, threads);
        if _truthy(group.get("dm")) and len(tasks) > 0 and _is_num(group.get("turnTimeoutMinutes")) {
            first = dict(tasks[0]);
            first["turnTimeoutMinutes"] = group["turnTimeoutMinutes"];
            tasks[0] = first;
        }
        g: dict[str, any] = {"key": group.get("id"), "name": group.get("name")};
        if group.get("section") is not None { g["section"] = group["section"]; }
        g.update({
            "dm": _truthy(group.get("dm")) and len(member_ids) == 2,
            "bulletin": group.get("bulletin"), "memberIds": member_ids,
            "defaultResponder": responder, "activeTask": group.get("threadId"), "tasks": tasks,
        });
        groups.append(g);
    }
    routines = [];
    for routine in _hook("routines_list")() {
        room: any = None;
        for g in groups {
            if g["key"] == routine.get("groupId") { room = g; break; }
        }
        valid = routine.get("botId") in bot_ids and (
            routine.get("target") != "room-goal"
            or (room is not None and not room["dm"] and routine.get("botId") in room["memberIds"])
        );
        if not valid {
            warnings.append(f"Routine “{_tpl(routine, 'name')}” is not included because its bot, room or coordinator was deleted.");
            continue;
        }
        r: dict[str, any] = {};
        for k in ["name", "prompt", "target", "botId", "groupId", "runOn", "schedule", "durationMinutes", "timeoutMinutes"] {
            if routine.get(k) is not None { r[k] = routine[k]; }
        }
        routines.append(r);
    }
    bots = [];
    for bot in bots_raw {
        b: dict[str, any] = {
            "key": bot.get("id"), "name": bot.get("name"), "title": bot.get("title"),
            "description": bot.get("description"),
        };
        for k in ["soul", "section"] {
            if bot.get(k) is not None { b[k] = bot[k]; }
        }
        b["color"] = bot.get("color");
        for k in ["mascotExpression", "mascotBody"] {
            if bot.get(k) is not None { b[k] = bot[k]; }
        }
        b["chiefOfStaff"] = _truthy(bot.get("chiefOfStaff"));
        b["hidden"] = _truthy(bot.get("hidden"));
        b["playbooks"] = bot.get("playbooks") if bot.get("playbooks") is not None else [];
        # Grants travel so the team's shape is not lost; import lands every
        # bot grant-less regardless.
        if _truthy(bot.get("connectorTools")) { b["connectorTools"] = bot["connectorTools"]; }
        if "toolScope" in bot and bot["toolScope"] is not None { b["toolScope"] = bot["toolScope"]; }
        mem = _memory_for(memory.get(bot.get("id")));
        if mem is not None { b["memory"] = mem; }
        b["activeTask"] = bot.get("threadId");
        b["tasks"] = _history(bot, threads);
        bots.append(b);
    }
    document = parse_team_backup({
        "format": "openmaus.backup", "version": 1, "name": name, "exportedAt": _hook("now")(),
        "warnings": warnings, "bots": bots, "groups": groups, "routines": routines,
    });
    # Never download a file our own importer cannot read; never truncate history.
    if len(js_stringify(document).encode("utf-8", "surrogatepass")) > MAX_TEAM_BACKUP_BYTES {
        _fail(400, "This backup exceeds the 50 MB portable-backup limit. Nothing was exported or changed.");
    }
    return document;
}

# ── import ────────────────────────────────────────────────────────────────

# shared/import-name.ts takeImportName (taken holds lowercased names).
def take_import_name(value: str, taken: set[str], max_length: int = 100) -> str {
    base = _js_slice(_js_trim(value), 0, max_length);
    candidate = base;
    n = 2;
    while candidate.lower() in taken {
        suffix = f" {n}";
        candidate = _js_trim_end(_js_slice(base, 0, max_length - _js_len(suffix))) + suffix;
        n += 1;
    }
    taken.add(candidate.lower());
    return candidate;
}

def _newest(task: dict[str, any]) -> any {
    newest = task["createdAt"];
    for message in task["messages"] {
        if message["at"] > newest { newest = message["at"]; }
    }
    return newest;
}

def _index_of_key(tasks: list[any], key: str) -> int {
    i = 0;
    for task in tasks {
        if task["key"] == key { return i; }
        i += 1;
    }
    return -1;
}

# Import is always additive. Rollback owns only the fresh records: node
# deletes every bot/room not in `existing` and empties the fresh sections.
def import_team_backup(input: any, selection: any, existing: dict[str, any], visibility: any = None) -> dict[str, any] {
    backup = parse_team_backup(input);
    created_bot_ids: list[str] = [];
    created_group_ids: list[str] = [];
    created_routines: list[any] = [];
    bot_ids: dict[str, str] = {};
    group_ids: dict[str, str] = {};
    ex_bots: list[any] = existing.get("bots") or [];
    ex_groups: list[any] = existing.get("groups") or [];
    taken_names: set[str] = set([_js_trim(b.get("name") or "").lower() for b in ex_bots]);
    taken_groups: set[str] = set([_js_trim(g.get("name") or "").lower() for g in ex_groups]);
    taken_sections: set[str] = set([s.lower() for s in (existing.get("sections") or [])]);
    for rec in ex_bots + ex_groups {
        taken_sections.add(_js_trim(rec.get("section") or "").lower());
    }
    sections: dict[str, str] = {};
    def section_for(section: any) -> str {
        k = _js_trim(section) if isinstance(section, str) else "";
        if k not in sections {
            trimmed = _js_trim(section) if isinstance(section, str) else "";
            sections[k] = take_import_name(trimmed or "Imported bots", taken_sections, 60);
        }
        return sections[k];
    }
    def restore(task: dict[str, any], thread_id: str) {
        ids: dict[str, str] = {};
        for message in task["messages"] { ids[message["id"]] = _new_id(); }
        messages = [];
        for message in task["messages"] {
            m: dict[str, any] = {
                "id": ids[message["id"]], "kind": "text", "role": message["role"],
                "text": message["text"], "at": message["at"],
                "parentId": ids[message["parentId"]] if message["parentId"] else None,
            };
            if _truthy(message.get("replyToId")) { m["replyToId"] = ids[message["replyToId"]]; }
            # Removed historical senders keep their name in the text, never a
            # link to an unrelated local bot with a colliding file key.
            sender = message.get("from");
            if sender is not None and sender["botId"] in bot_ids {
                f = dict(sender);
                f["botId"] = bot_ids[sender["botId"]];
                m["from"] = f;
            } elif sender is not None {
                m["text"] = f"{sender['name']}:\n{message['text']}";
            }
            if "peerPost" in message { m["peerPost"] = message["peerPost"]; }
            messages.append(m);
        }
        leaf = ids[task["activeLeafId"]] if task["activeLeafId"] else None;
        _store("importTranscript", {"threadId": thread_id, "messages": messages, "activeLeafId": leaf});
    }
    try {
        # Allocate all bot IDs before remapping any conversation participants.
        threads_of: dict[str, str] = {};
        for source in backup["bots"] {
            profile: dict[str, any] = {
                "name": take_import_name(source["name"], taken_names),
                "title": source["title"], "description": source["description"],
            };
            if "soul" in source { profile["soul"] = source["soul"]; }
            profile["color"] = source["color"];
            if "mascotExpression" in source { profile["mascotExpression"] = source["mascotExpression"]; }
            # node applies botMascotBody (shared/mascot-bodies.ts) to this.
            if "mascotBody" in source { profile["mascotBody"] = source["mascotBody"]; }
            profile["modelSelection"] = selection;
            profile["section"] = section_for(source.get("section"));
            if _truthy(visibility) { profile["visibility"] = visibility; }
            bot = _store("createBot", {"profile": profile});
            created_bot_ids.append(bot["id"]);
            bot_ids[source["key"]] = bot["id"];
            threads_of[bot["id"]] = bot["threadId"];
            patch: dict[str, any] = {
                "composio": False, "computer": "off", "browser": False, "approvalMode": "ask",
                "autoApprove": False, "connectorTools": {},
            };
            if "toolScope" in source { patch["toolScope"] = source["toolScope"]; }
            patch.update({"hidden": source["hidden"], "chiefOfStaff": source["chiefOfStaff"], "playbooks": source["playbooks"]});
            _store("patchBot", {"botId": bot["id"], "patch": patch});
            if "memory" in source { _store("restoreMemory", {"botId": bot["id"], "memory": source["memory"]}); }
        }
        for source in backup["bots"] {
            bid = bot_ids[source["key"]];
            tasks: list[any] = [];
            i = 0;
            for task in source["tasks"] {
                # Each imported thread follows the imported bot's model.
                record: dict[str, any] = {
                    "threadId": threads_of[bid] if i == 0 else _new_id(), "title": task["title"],
                    "createdAt": task["createdAt"], "resumeCursors": {}, "activity": "idle",
                    "busy": False, "unread": False,
                };
                if task.get("titleFromFirstMessage") { record["titleFromFirstMessage"] = True; }
                # Openers/closers remap to their imported twin; a stranger leaves no record.
                opened = task.get("openedBy");
                if opened is not None and opened["botId"] in bot_ids {
                    o: dict[str, any] = {"botId": bot_ids[opened["botId"]], "name": opened["name"], "at": opened["at"]};
                    if _truthy(opened.get("kind")) { o["kind"] = opened["kind"]; }
                    record["openedBy"] = o;
                }
                closed = task.get("closedBy");
                if closed is not None and closed["botId"] in bot_ids {
                    record["closedBy"] = {"botId": bot_ids[closed["botId"]], "name": closed["name"], "at": closed["at"]};
                }
                if task.get("pinned") is True { record["pinned"] = True; }
                record["updatedAt"] = _newest(task);
                tasks.append(record);
                i += 1;
            }
            # Own the task IDs before writing transcripts, so rollback also
            # removes partially imported history.
            active = tasks[_index_of_key(source["tasks"], source["activeTask"])]["threadId"];
            _store("patchBot", {"botId": bid, "patch": {"tasks": tasks, "threadId": active}});
            j = 0;
            for task in source["tasks"] {
                restore(task, tasks[j]["threadId"]);
                j += 1;
            }
        }
        for source in backup["groups"] {
            group = _store("createGroup", {
                "name": take_import_name(source["name"], taken_groups),
                "memberIds": [bot_ids[mid] for mid in source["memberIds"]],
                "dm": source["dm"], "section": section_for(source.get("section")),
            });
            created_group_ids.append(group["id"]);
            group_ids[source["key"]] = group["id"];
            resp = source["defaultResponder"];
            responder: any = resp;
            if resp["kind"] == "member" {
                responder = {"kind": "member", "botId": bot_ids[resp["botId"]]};
            } elif resp["kind"] == "auto" {
                responder = {"kind": "auto"};
                if _truthy(resp.get("fallbackBotId")) { responder["fallbackBotId"] = bot_ids[resp["fallbackBotId"]]; }
            }
            gpatch: dict[str, any] = {"bulletin": source["bulletin"], "setupCompletedAt": _hook("now")()};
            if source["dm"] and len(source["tasks"]) > 0 and source["tasks"][0].get("turnTimeoutMinutes") is not None {
                gpatch["turnTimeoutMinutes"] = source["tasks"][0]["turnTimeoutMinutes"];
            }
            gpatch["defaultResponder"] = responder;
            _store("patchGroup", {"groupId": group["id"], "patch": gpatch});
            # Existing room task APIs; direct-message rooms have exactly one.
            threads: list[str] = [];
            k = 0;
            for task in source["tasks"] {
                if k == 0 {
                    if not source["dm"] {
                        _store("renameGroupTask", {"groupId": group["id"], "threadId": group["threadId"], "title": task["title"]});
                    }
                    threads.append(group["threadId"]);
                } else {
                    threads.append(_store("createGroupTask", {"groupId": group["id"], "title": task["title"]})["threadId"]);
                }
                k += 1;
            }
            k = 0;
            for task in source["tasks"] {
                restore(task, threads[k]);
                k += 1;
            }
            if not source["dm"] {
                gtasks = [];
                k = 0;
                for task in source["tasks"] {
                    t: dict[str, any] = {"threadId": threads[k], "title": task["title"], "createdAt": task["createdAt"], "updatedAt": _newest(task)};
                    if task.get("pinned") is True { t["pinned"] = True; }
                    if task.get("titleFromFirstMessage") { t["titleFromFirstMessage"] = True; }
                    if task.get("turnTimeoutMinutes") is not None { t["turnTimeoutMinutes"] = task["turnTimeoutMinutes"]; }
                    gtasks.append(t);
                    k += 1;
                }
                _store("setGroupTasks", {
                    "groupId": group["id"], "tasks": gtasks,
                    "activeThreadId": threads[_index_of_key(source["tasks"], source["activeTask"])],
                });
            }
        }
        for source in backup["routines"] {
            rinput = dict(source);
            rinput["botId"] = bot_ids[source["botId"]];
            rinput.pop("groupId", None);
            if source["target"] == "room-goal" { rinput["groupId"] = group_ids[source["groupId"]]; }
            rinput["enabled"] = False;
            created_routines.append(_hook("routine_create")(rinput));
        }
        return {"name": backup["name"], "bot_ids": created_bot_ids, "group_ids": created_group_ids, "routines": created_routines};
    } except Exception as error {
        for routine in created_routines { _hook("routine_remove")(routine["id"]); }
        # createBot/createGroup can throw during persistence before returning;
        # node removes every record absent from `existing`, not just ours.
        _store("rollback", {
            "existingBotIds": [b.get("id") for b in ex_bots],
            "existingGroupIds": [g.get("id") for g in ex_groups],
            "sections": list(sections.values()),
        });
        raise error;
    }
}

# ── HTTP surface (re-bound onto harness.jac as team_backup_*) ─────────────

def _guard(omb_token: any) -> any {
    want = os.environ.get("OMB_JAC_TOKEN");
    if want and omb_token != want {
        return {"ok": False, "status": 403, "error": "unauthorized"};
    }
    return None;
}

def _invoke(omb_token: any, fn: any) -> any {
    g = _guard(omb_token);
    if g is not None { return g; }
    try {
        return fn();
    } except Exception as e {
        return {"ok": False, "status": _status_of(e), "error": str(e)};
    }
}

def:pub team_backup_create(snapshot: any = None, name: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return {"backup": create_team_backup(_rec(snapshot), name if isinstance(name, str) else "")};
    }
    return _invoke(omb_token, _go);
}

def:pub team_backup_import(input: any = None, selection: any = None, existing: any = None, visibility: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        vis = visibility if isinstance(visibility, dict) or (isinstance(visibility, str) and visibility != "None") else None;
        return {"imported": import_team_backup(input, selection if isinstance(selection, dict) else None, _rec(existing), vis)};
    }
    return _invoke(omb_token, _go);
}

def:pub team_backup_parse(input: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"backup": parse_team_backup(input)}; }
    return _invoke(omb_token, _go);
}

with entry {
    _reset();
}
