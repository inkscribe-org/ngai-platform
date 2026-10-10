"""TeamComputers port - named team computer ownership on Jac (phase 4).

Faithful port of server/team-computers.ts. team-computers.json keeps the
same bytes (compact JSON.stringify, mode 0600, tmp + rename) and the same
fail-closed load: invalid, foreign or unsafe restored state is never
silently reset to an empty pool - every read answers 503 instead.

The registry is a graph: a TeamRegistry node owns TeamComputer nodes over
`Registered` edges (file order), and a team assignment is an `AssignedTo`
edge from a computer to its TeamSection node, so "this team's computer" is
a traversal `[section <-:AssignedTo:<-]`, and one-computer-per-team is the
in-degree of a section.

One server writer owns the data directory. Identity is persisted before any
provider call, so failed/retried creates keep the same Boat journal key.
"""

import os;
import re;
import json;
import math;
import stat;
import time;
import uuid;
import threading;

import from db { DATA_DIR }
import from jsutil { js_stringify }

glob MAX_COMPUTERS: int = 100;
glob MAX_FILE_BYTES: int = 100000;
glob _UUID: any = re.compile("^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}|00000000-0000-0000-0000-000000000000|ffffffff-ffff-ffff-ffff-ffffffffffff)$");
glob _JS_SPACE: str = "\t\n\u000b\u000c\r                  　﻿";

node TeamRegistry {}

node TeamComputer {
    has id: str,
        name: str,
        created_at: any = 0,
        problem: (str | None) = None;
}

node TeamSection {
    has name: str;
}

edge Registered: any --> any {}
edge AssignedTo: any --> any {}

glob _tc: dict[str, any] = {};
glob _tc_lock: any = threading.RLock();

class TeamComputerError(Exception) {
    # Error carrying an HTTP status (JS `Object.assign(new Error, {status})`).
}

def _fail(status: int, message: str) {
    err = TeamComputerError(message);
    setattr(err, "status", status);
    raise err;
}

def _status_of(e: Exception) -> int {
    s = getattr(e, "status", None);
    return s if isinstance(s, int) and not isinstance(s, bool) else 500;
}

def _reset {
    with _tc_lock {
        _tc.update({
            "file": None,
            "environment_id": None,
            "loaded": False,
            "problem": None,
            "registry": TeamRegistry(),
            "now_ms": None,
        });
    }
}

def _now -> int {
    v = _tc.get("now_ms");
    if v is not None {
        return int(v);
    }
    return int(time.time() * 1000);
}

# ── JS / zod semantics ─────────────────────────────────────────────────────

def _js_trim(s: str) -> str {
    return s.strip(_JS_SPACE);
}

def _js_len(s: str) -> int {
    return len(s.encode("utf-16-le", errors="surrogatepass")) // 2;
}

def _js_slice(s: str, n: int) -> str {
    units = s.encode("utf-16-le", errors="surrogatepass");
    if len(units) <= n * 2 {
        return s;
    }
    return units[:n * 2].decode("utf-16-le", errors="surrogatepass");
}

def _is_number(v: any) -> bool {
    return isinstance(v, (int, float)) and not isinstance(v, bool);
}

def _finite_nonneg(v: any) -> bool {
    if not _is_number(v) {
        return False;
    }
    return math.isfinite(v) and v >= 0;
}

def _is_uuid(v: any) -> bool {
    return isinstance(v, str) and _UUID.match(v) is not None;
}

# teamComputerCreate.shape.name: trim, 1..60 UTF-16 units, no C0/DEL.
def _parse_name(v: any) -> str {
    if not isinstance(v, str) {
        raise ValueError("name: Invalid input: expected string");
    }
    s = _js_trim(v);
    if _js_len(s) < 1 {
        raise ValueError("name: Too small: expected string to have >=1 characters");
    }
    if _js_len(s) > 60 {
        raise ValueError("name: Too big: expected string to have <=60 characters");
    }
    for ch in s {
        if ord(ch) < 32 or ord(ch) == 127 {
            raise ValueError("name: Invalid input");
        }
    }
    return s;
}

# entrySchema.shape.section: trim, max 60, nullable.
def _parse_section(v: any) -> any {
    if v is None {
        return None;
    }
    if not isinstance(v, str) {
        raise ValueError("section: Invalid input: expected string, received " + _js_type(v));
    }
    s = _js_trim(v);
    if _js_len(s) > 60 {
        raise ValueError("section: Too big: expected string to have <=60 characters");
    }
    return s;
}

def _js_type(v: any) -> str {
    if isinstance(v, bool) { return "boolean"; }
    if _is_number(v) { return "number"; }
    if isinstance(v, list) { return "array"; }
    if isinstance(v, dict) { return "object"; }
    return "undefined";
}

# entrySchema (strict): id, name, section, createdAt, problem?
def _parse_entry(raw: any) -> dict[str, any] {
    if not isinstance(raw, dict) {
        raise ValueError("Invalid input: expected object");
    }
    for k in raw.keys() {
        if k not in ("id", "name", "section", "createdAt", "problem") {
            raise ValueError(f'Unrecognized key: "{k}"');
        }
    }
    if not _is_uuid(raw.get("id")) {
        raise ValueError("id: Invalid UUID");
    }
    name = _parse_name(raw.get("name"));
    if "section" not in raw {
        raise ValueError("section: Invalid input: expected string, received undefined");
    }
    section = _parse_section(raw["section"]);
    created: any = raw.get("createdAt");
    if not _finite_nonneg(created) {
        raise ValueError("createdAt: Invalid input: expected number");
    }
    out: dict[str, any] = {"id": raw["id"], "name": name, "section": section, "createdAt": created};
    if "problem" in raw and raw["problem"] is not None {
        p = raw["problem"];
        if not isinstance(p, str) or _js_len(p) > 500 {
            raise ValueError("problem: Invalid input");
        }
        out["problem"] = p;
    }
    return out;
}

def _parse_file(raw: any) -> list[any] {
    if not isinstance(raw, dict) {
        raise ValueError("Invalid input: expected object");
    }
    for k in raw.keys() {
        if k not in ("version", "environmentId", "computers") {
            raise ValueError(f'Unrecognized key: "{k}"');
        }
    }
    if raw.get("version") != 1 or isinstance(raw.get("version"), bool) {
        raise ValueError("version: Invalid input: expected 1");
    }
    if not _is_uuid(raw.get("environmentId")) {
        raise ValueError("environmentId: Invalid UUID");
    }
    computers = raw.get("computers");
    if not isinstance(computers, list) {
        raise ValueError("computers: Invalid input: expected array");
    }
    if len(computers) > MAX_COMPUTERS {
        raise ValueError("computers: Too big: expected array to have <=100 items");
    }
    return [_parse_entry(rec) for rec in computers];
}

# ── graph ──────────────────────────────────────────────────────────────────

def _computers -> list[any] {
    return [_tc["registry"] ->:Registered:->][?:TeamComputer];
}

def _computer(wanted: str) -> any {
    hits = [_tc["registry"] ->:Registered:->][?:TeamComputer][?id == wanted];
    return hits[0] if hits else None;
}

def _section_of(c: any) -> any {
    hits = [c ->:AssignedTo:->][?:TeamSection];
    return hits[0].name if hits else None;
}

def _registry -> TeamRegistry {
    return _tc["registry"];
}

def _section_node(wanted: str) -> TeamSection {
    reg = _registry();
    hits = [reg ->:Registered:->][?:TeamSection][?name == wanted];
    if hits {
        return hits[0];
    }
    s = TeamSection(name=wanted);
    reg +>:Registered:+> s;
    return s;
}

def _set_section(c: TeamComputer, section: any) {
    for old in [c ->:AssignedTo:->][?:TeamSection] {
        c del ->:AssignedTo:-> old;
    }
    if section is not None {
        c +>:AssignedTo:+> _section_node(section);
    }
}

def _as_record(c: any) -> dict[str, any] {
    out: dict[str, any] = {"id": c.id, "name": c.name, "section": _section_of(c), "createdAt": c.created_at};
    if c.problem is not None {
        out["problem"] = c.problem;
    }
    return out;
}

def _rebuild(entries: list[any]) {
    reg = TeamRegistry();
    _tc["registry"] = reg;
    for rec in entries {
        c = TeamComputer(id=rec["id"], name=rec["name"], created_at=rec["createdAt"], problem=rec.get("problem"));
        reg +>:Registered:+> c;
        _set_section(c, rec["section"]);
    }
}

# ── load / save ────────────────────────────────────────────────────────────

def _file_path -> str {
    f = _tc.get("file");
    if f is None {
        f = os.path.join(DATA_DIR, "team-computers.json");
        _tc.update({"file": f});
    }
    return f;
}

# The constructor's load: identity of the workspace is node's ENVIRONMENT_ID.
def tc_load(environment_id: str) {
    with _tc_lock {
        file = _file_path();
        _tc.update({"environment_id": environment_id, "loaded": True, "problem": None});
        _rebuild([]);
        try {
            if not os.path.exists(file) {
                return;
            }
            st = os.lstat(file);
            if not stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode) or st.st_size > MAX_FILE_BYTES {
                raise ValueError("unsafe registry file");
            }
            with open(file, "r", encoding="utf-8") as fh {
                text = fh.read();
            }
            raw: any = None;
            try {
                raw = json.loads(text);
            } except json.JSONDecodeError as e {
                raise ValueError(f"JSON parse error: {e.msg}");
            }
            saved = _parse_file(raw);
            if raw["environmentId"] != environment_id {
                raise ValueError("registry belongs to another workspace; its computers were not transferred");
            }
            ids = [rec["id"] for rec in saved];
            if len(set(ids)) != len(ids) {
                raise ValueError("duplicate computer identity");
            }
            sections = [rec["section"] for rec in saved if rec["section"] is not None];
            if len(set(sections)) != len(sections) {
                raise ValueError("a team has more than one computer");
            }
            _rebuild(saved);
        } except Exception as e {
            _tc.update({"problem": f"Team computer registry could not be loaded: {e}"});
        }
    }
}

# Every op names the workspace it expects; a respawned harness reloads.
def _ensure(environment_id: any) {
    if not isinstance(environment_id, str) or not environment_id {
        _fail(400, "environmentId is required");
    }
    if not _tc["loaded"] or _tc["environment_id"] != environment_id {
        tc_load(environment_id);
    }
}

def _save(entries: list[any]) {
    file = _file_path();
    body = js_stringify({"version": 1, "environmentId": _tc["environment_id"], "computers": entries});
    d = os.path.dirname(file) or ".";
    os.makedirs(d, exist_ok=True);
    tmp = f"{file}.{os.getpid()}.{uuid.uuid4().hex}.tmp";
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600);
    try {
        with os.fdopen(fd, "w", encoding="utf-8") as fh {
            fh.write(body);
        }
        os.chmod(tmp, 0o600);
        os.replace(tmp, file);
    } except Exception as e {
        try { os.unlink(tmp); } except Exception { }
        raise e;
    }
    _rebuild(entries);
}

# ── TeamComputers ──────────────────────────────────────────────────────────

def tc_list -> list[any] {
    with _tc_lock {
        if _tc["problem"] {
            _fail(503, _tc["problem"]);
        }
        return [_as_record(c) for c in _computers()];
    }
}

def tc_get(id: str) -> any {
    for rec in tc_list() {
        if rec["id"] == id {
            return rec;
        }
    }
    return None;
}

def tc_for_section(section: any) -> any {
    want = "";
    if isinstance(section, str) {
        want = _js_trim(section);
    }
    with _tc_lock {
        tc_list();
        sec = [_tc["registry"] ->:Registered:->][?:TeamSection][?name == want];
        if not sec {
            return None;
        }
        owners = [sec[0] <-:AssignedTo:<-][?:TeamComputer];
        return _as_record(owners[0]) if owners else None;
    }
}

# Explicit destinations are permissions, not suggestions. Only Auto inherits.
# (`computer: null` is still an explicit choice, as `null !== undefined`.)
def tc_for_bot(bot: dict[str, any]) -> any {
    if "computer" in bot or bot.get("cloudBackend") == "vps" {
        return None;
    }
    return tc_for_section(bot.get("section"));
}

def tc_create(name: str, id: any = None) -> dict[str, any] {
    with _tc_lock {
        if not isinstance(id, str) {
            id = str(uuid.uuid4());
        }
        entries = tc_list();
        for existing in entries {
            if existing["id"] == id {
                if existing["name"] != name {
                    _fail(409, "This creation id already names a different computer");
                }
                return existing;
            }
        }
        if len(entries) >= MAX_COMPUTERS {
            _fail(409, "This workspace has reached its team computer limit");
        }
        rec = _parse_entry_or_400({"id": id, "name": name, "section": None, "createdAt": _now()});
        _save(entries + [rec]);
        return dict(rec);
    }
}

def tc_assign(id: str, section: any) -> dict[str, any] {
    with _tc_lock {
        try {
            section = _parse_section(section);
        } except ValueError as e {
            _fail(400, str(e));
        }
        rec = tc_get(id);
        if rec is None {
            _fail(404, "No such team computer");
        }
        if rec["section"] is not None and section is not None and section != rec["section"] {
            _fail(409, "Unassign this computer before moving it to another team");
        }
        if section is not None {
            for other in tc_list() {
                if other["id"] != id and other["section"] == section {
                    _fail(409, "This team already has a computer; unassign it first");
                }
            }
        }
        return _patch(id, {"section": section});
    }
}

def tc_set_problem(id: str, problem: any) -> dict[str, any] {
    p: any = None;
    if isinstance(problem, str) {
        p = _js_slice(problem, 500);
    }
    return _patch(id, {"problem": p});
}

# Relabel an existing team's assignment; this never changes its computer.
def tc_rename_section(from_name: str, to_name: str) -> bool {
    with _tc_lock {
        rec = tc_for_section(from_name);
        if rec is None or from_name == to_name {
            return False;
        }
        if tc_for_section(to_name) is not None {
            _fail(409, "This team already has a computer");
        }
        _patch(rec["id"], {"section": to_name});
        return True;
    }
}

def _parse_entry_or_400(raw: dict[str, any]) -> dict[str, any] {
    try {
        return _parse_entry(raw);
    } except ValueError as e {
        _fail(400, str(e));
    }
    return {};
}

def _patch(id: str, patch: dict[str, any]) -> dict[str, any] {
    with _tc_lock {
        entries = tc_list();
        found = None;
        for candidate in entries {
            if candidate["id"] == id {
                found = candidate;
            }
        }
        if found is None {
            _fail(404, "No such team computer");
        }
        merged = dict(found);
        merged.update(patch);
        nxt = _parse_entry_or_400(merged);
        _save([nxt if candidate["id"] == id else candidate for candidate in entries]);
        return dict(nxt);
    }
}

# What node's mirror holds: the records, or the load problem.
def _view -> dict[str, any] {
    with _tc_lock {
        if _tc["problem"] {
            return {"computers": [], "problem": _tc["problem"]};
        }
        return {"computers": [_as_record(c) for c in _computers()], "problem": None};
    }
}

# ── HTTP surface (re-bound onto harness.jac as team_computer_*) ─────────────

def _guard(omb_token: any) -> any {
    want = os.environ.get("OMB_JAC_TOKEN");
    if want and omb_token != want {
        return {"ok": False, "status": 403, "error": "unauthorized"};
    }
    return None;
}

def _invoke(omb_token: any, environment_id: any, fn: any) -> any {
    g = _guard(omb_token);
    if g is not None { return g; }
    try {
        _ensure(environment_id);
        return fn();
    } except Exception as e {
        return {"ok": False, "status": _status_of(e), "error": str(e)};
    }
}

def _str_arg(v: any, what: str) -> str {
    if not isinstance(v, str) {
        _fail(400, f"{what} is required");
    }
    return v;
}

def:pub team_computer_load(environment_id: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        tc_load(environment_id);
        return _view();
    }
    return _invoke(omb_token, environment_id, _go);
}

def:pub team_computer_list(environment_id: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return _view(); }
    return _invoke(omb_token, environment_id, _go);
}

def:pub team_computer_create(environment_id: any = None, name: any = None, id: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        cid: any = id if isinstance(id, str) and id else None;
        return {"computer": tc_create(_str_arg(name, "name"), cid), "view": _view()};
    }
    return _invoke(omb_token, environment_id, _go);
}

def:pub team_computer_assign(environment_id: any = None, id: any = None, section: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return {"computer": tc_assign(_str_arg(id, "id"), section), "view": _view()};
    }
    return _invoke(omb_token, environment_id, _go);
}

def:pub team_computer_set_problem(environment_id: any = None, id: any = None, problem: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return {"computer": tc_set_problem(_str_arg(id, "id"), problem), "view": _view()};
    }
    return _invoke(omb_token, environment_id, _go);
}

def:pub team_computer_rename_section(environment_id: any = None, from_name: any = None, to_name: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        changed = tc_rename_section(_str_arg(from_name, "from"), _str_arg(to_name, "to"));
        return {"changed": changed, "view": _view()};
    }
    return _invoke(omb_token, environment_id, _go);
}

with entry {
    _reset();
}
