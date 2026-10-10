"""Bot + group/thread registry — port of server/store.ts.

bots.json holds bot records (including the thread→instance binding and
per-instance resume cursors); groups.json holds room records. Transcripts
live in the message-db layer (jac/harness/messages.jac — already ported,
imported here, NOT re-ported). This file owns:

  - DATA_DIR/bots.json and DATA_DIR/groups.json read+write. The on-disk
    bytes are produced by a JSON.stringify(value, null, 2)-faithful
    printer (js_pretty) over jsutil's byte-exact primitives, written via
    atomic.ts's temp+fsync+rename at mode 0o600; a byte-identical write is
    skipped (writeFileAtomicIfChanged).
  - Store methods managing bots, groups/rooms, thread metadata (titles,
    branches via thread_state + message-db delegation), and the pure
    helpers they need (title helpers, mention resolution, approval-mode,
    tool-scope, avatar clamps, soul-hash, connectorTools validation,
    secret redaction for bot-authored transcript entries).

JavaScript undefined has no Python value: it is modelled by the module
sentinel UNDEF. Assignment of undefined is serialized as an absent key, so
_js_set/_assign delete the key on UNDEF. `in` checks map
Object.hasOwnProperty / `!== undefined` lookups exactly where the TS
source relies on presence vs. absence; .get(...) is used where `?.`
short-circuits on null/undefined alike.

Bot→thread membership is materialized in the OSP graph as
Bot -Contains-> Thread edges (graph.jac), mirroring the bot↔thread
relations TS keeps inside BotRecord. Graph maintenance is best-effort and
never affects the durable registries.
"""

import os;
import sys;
import re;
import json;
import math;
import time;
import uuid;
import shutil;
import random;
import hashlib;
import stat as statmod;
import unicodedata;

import from copy { deepcopy }
import from db { DATA_DIR }
import from jsutil { js_string, js_stringify }
# JS undefined, JSON.stringify(_, null, 2), server/atomic.ts and
# shared/redact.ts (re-exported under their port names).
import from common {
    UNDEF,
    js_pretty as _js_pretty,
    write_file_atomic,
    redact_mask as mask,
    redact_secrets_in_text,
}
import from messages {
    read_thread, read_thread_tail, append_message, update_message,
    insert_message, set_active_leaf, import_thread, delete_thread,
    latest_message_ats, working_goal_run_messages, with_command_receipt
}
import from graph { bot_node, thread_node, Thread, Contains }
import from emoji_rgi { RGI_HEX, SINGLES_HEX }


# ── JS interop ──────────────────────────────────────────────────────────

# UNDEF (common): the JavaScript `undefined` sentinel, distinct from None.
glob _emoji_state: dict[str, any] = {"rgi": None, "singles": None};

# JS strips its own whitespace set in trim() and matches it in \s.
glob _JS_WS: str = (
    "\t\n\x0b\x0c\r \xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005"
    "\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"
);
glob _JS_S_CLASS: str = (
    "[\t\n\x0b\x0c\r \xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]"
);


def _js_len(text: str) -> int {
    # JS string length counts UTF-16 code units, not code points.
    return len(text.encode("utf-16-le", "surrogatepass")) // 2;
}


def _js_trim(text: any) -> str {
    return text.strip(_JS_WS);
}


def _js_slice_16(text: str, start: int, end: (int | None) = None) -> str {
    # JS .slice counts UTF-16 code units.
    units = text.encode("utf-16-le", "surrogatepass");
    if end is None {
        end = len(units) // 2;
    }
    return units[start * 2 : end * 2].decode("utf-16-le", "surrogatepass");
}


def _now_ms() -> int {
    return int(time.time() * 1000);
}


def _is_num(value: any) -> bool {
    # z.number()/typeof x === "number": bools are not numbers.
    return isinstance(value, (int, float)) and not isinstance(value, bool);
}


def _finite(value: any) -> bool {
    return _is_num(value) and math.isfinite(value);
}


def _js_round(value: float) -> float {
    # Math.round rounds half toward +Infinity; Python's round is banker's.
    return math.floor(value + 0.5);
}


def _js_set(target: dict[str, any], key: str, value: any) -> None {
    # obj.key = value, including value === undefined: the key remains an
    # own property, and _js_pretty drops it like JSON.stringify.
    target[key] = value;
}


def _assign(target: dict[str, any], source: dict[str, any]) -> None {
    # Object.assign(target, source), own enumerable keys in order.
    for (k, v) in source.items() {
        target[k] = v;
    }
}


def _js_strict_eq(a: any, b: any) -> bool {
    # JS === : objects compare by identity, no cross-type coercion,
    # true !== 1, undefined only === undefined.
    if a is UNDEF or b is UNDEF {
        return a is UNDEF and b is UNDEF;
    }
    if isinstance(a, (dict, list)) or isinstance(b, (dict, list)) {
        return a is b;
    }
    if type(a) is not type(b) {
        return False;
    }
    return a == b;
}


def _reject_const(x: any) -> any {
    raise ValueError(x);
}


def _json_loads(text: str) -> any {
    # JSON.parse rejects NaN/Infinity literals; Python's accepts them.
    return json.loads(text, parse_constant=_reject_const);
}


def _call_method(target: any, name: str, args: list[any]) -> any {
    # Duck-typed `obj?.name(...)` for optional collaborator parameters
    # (TeamComputers) passed by future callers.
    if target is None {
        return None;
    }
    fn = target.get(name) if isinstance(target, dict) else getattr(target, name, None);
    if callable(fn) {
        return fn(*args);
    }
    return None;
}


# ── atomic.ts (write_file_atomic lives in common) ───────────────────────

def _holds_exactly(path: str, data: str, mode: (int | None)) -> bool {
    # True only when `path` is already exactly `data`: a regular file,
    # owned by this user, with permissions no broader than `mode`. Any
    # doubt answers false so the caller falls back to a full write.
    fd: any = None;
    try {
        if sys.platform == "win32" {
            st0 = os.lstat(path);
            if not statmod.S_ISREG(st0.st_mode) {
                return False;
            }
            fd = os.open(path, os.O_RDONLY);
        } else {
            fd = os.open(
                path,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | os.O_NONBLOCK
            );
        }
        st = os.fstat(fd);
        payload = data.encode("utf-8");
        if not statmod.S_ISREG(st.st_mode) or st.st_size != len(payload) {
            return False;
        }
        uid: any = None;
        try {
            uid = os.getuid();
        } except Exception {
            uid = None;
        }
        if uid is not None and st.st_uid != uid {
            return False;
        }
        # Windows reports 0o666 for any writable file; its mode bits mean nothing.
        if mode is not None and sys.platform != "win32" and ((st.st_mode & 0o777 & ~mode) != 0) {
            return False;
        }
        chunks: list[any] = [];
        while True {
            chunk = os.read(fd, 65536);
            if not chunk {
                break;
            }
            chunks.append(chunk);
        }
        return b"".join(chunks) == payload;
    } except Exception {
        return False;
    } finally {
        if fd is not None {
            try {
                os.close(fd);
            } except Exception {
            }
        }
    }
}


def write_file_atomic_if_changed(path: str, data: str, mode: (int | None) = None, durable: bool = True) -> bool {
    # writeFileAtomic for saves that often repeat what the file already
    # holds. Returns whether it wrote.
    if _holds_exactly(path, data, mode) {
        return False;
    }
    write_file_atomic(path, data, mode=mode, durable=durable);
    return True;
}


# ── registry files ──────────────────────────────────────────────────────

glob BOTS_FILE: str = os.path.join(DATA_DIR, "bots.json"),
    GROUPS_FILE: str = os.path.join(DATA_DIR, "groups.json"),
    # Written once the copies older builds made of a bot's model on its
    # threads are cleared, so that cleanup runs once per data directory.
    THREAD_MODEL_COPIES_CLEARED: str = os.path.join(DATA_DIR, "thread-model-copies-cleared"),
    EVENTS_DIR: str = os.path.join(DATA_DIR, "events"),
    NATIVE_DIR: str = os.path.join(DATA_DIR, "native"),
    WORKSPACES_DIR: str = os.path.join(DATA_DIR, "workspaces"),
    BOTS_DIR: str = os.path.join(DATA_DIR, "bots"),
    SOUL_FILE: str = "SOUL.md",
    SECTION_CONTEXTS_FILE: str = os.path.join(DATA_DIR, "section-contexts.json"),
    PUBLISHED_TEAMS_FILE: str = os.path.join(DATA_DIR, "published-teams.json"),
    SECTION_CONTEXT_MAX_BYTES: int = 24000;


def tighten_registry_file(file: str) -> None {
    # The registries carry souls, project paths and per-bot settings, so
    # they are owner-only. Best effort: failing to tighten must never
    # stop the fleet from loading. Windows has no POSIX mode bits.
    if sys.platform == "win32" {
        return;
    }
    try {
        if (os.stat(file).st_mode & 0o077) != 0 {
            os.chmod(file, 0o600);
        }
    } except Exception {
        # absent, or not ours to change
    }
}


def messages_file(thread_id: str) -> str {
    return os.path.join(DATA_DIR, f"messages-{thread_id}.json");
}


def workspace_dir(bot_id: str) -> str {
    return os.path.join(WORKSPACES_DIR, bot_id);
}


# ── bot-folder.ts (soul hash + SOUL.md mirror) ─────────────────────────

def bot_folder(bot_id: str) -> str {
    return os.path.join(BOTS_DIR, bot_id);
}


def soul_file(bot_id: str) -> str {
    return os.path.join(bot_folder(bot_id), SOUL_FILE);
}


def soul_hash(soul: str) -> str {
    return hashlib.sha256(soul.encode("utf-8")).hexdigest();
}


def write_soul_mirror(bot_id: any, soul: any) -> None {
    os.makedirs(bot_folder(bot_id), mode=0o700, exist_ok=True);
    write_file_atomic(soul_file(bot_id), soul, mode=0o600);
}


def remove_bot_folder(bot_id: str) -> None {
    try {
        shutil.rmtree(bot_folder(bot_id), ignore_errors=True);
    } except Exception {
    }
}


# ── small leaf deps ────────────────────────────────────────────────────

def new_id() -> str {
    # crypto.randomUUID()
    return str(uuid.uuid4());
}


def peer_allow_key(action: str, target_id: str) -> str {
    return f"{action}:{target_id}";
}


glob _NAMES: list[any] = [
    "Scout", "Pixel", "Atlas", "Nova", "Juno", "Koda", "Miso", "Mochi",
    "Biscuit", "Pepper", "Clover", "Ember", "Willow", "Comet", "Orbit", "Echo",
    "Indigo", "Sage", "Zephyr", "Poppy", "Maple", "Cosmo", "Luna", "Otto",
    "Ivy", "Finch", "Wren", "Basil", "Hazel", "Nimbus", "Onyx", "Pearl",
    "Quill", "Rocket", "Sunny", "Tango", "Vega", "Waffle", "Ziggy", "Noodle",
    "Pickle", "Churro", "Panko", "Dumpling", "Pesto", "Olive", "Cocoa", "Taffy",
    "Bramble", "Fig", "Juniper", "Moss", "Pebble", "Rio", "Skye", "Tuli",
    "Ursa", "Yuki", "Zuko", "Momo", "Kiwi", "Plum", "Sprout", "Turnip",
];


def pick_bot_name(taken: list[any]) -> str {
    used = set(n.strip().lower() for n in taken);
    free = [n for n in _NAMES if n.lower() not in used];
    if free {
        return free[math.floor(random.random() * len(free))];
    }
    # pool exhausted — number a random base name
    base = _NAMES[math.floor(random.random() * len(_NAMES))];
    i = 2;
    while True {
        if f"{base.lower()} {i}" not in used {
            return f"{base} {i}";
        }
        i += 1;
    }
}


# ── shared/mention-boundary.ts ─────────────────────────────────────────

glob _OPENING_MENTION_BOUNDARY: str = (
    "(*_~[{'\"\u2018\u201c\u3008\u300a\u300c\u300e\u3010\uff08"
);


def is_mention_boundary(text: str, at: int) -> bool {
    # Whether an at-sign starts a standalone mention at this offset.
    if at == 0 {
        return True;
    }
    before = text[at - 1];
    return before.isspace() or before in _OPENING_MENTION_BOUNDARY;
}


def is_mention_name_continuation(value: (str | None)) -> bool {
    # A matched name must not be the prefix of a longer Unicode word.
    # JS /^[\p{L}\p{N}\p{M}_]/u on the first UTF-16 unit: an astral
    # character exposes a lone surrogate, which is not L/N/M.
    if value is None or value == "" {
        return False;
    }
    ch = value[0];
    if len(ch.encode("utf-16-le", "surrogatepass")) > 2 {
        return False;
    }
    return ch == "_" or unicodedata.category(ch)[:1] in ("L", "N", "M");
}


# ── shared/bot-avatar.ts ───────────────────────────────────────────────

glob BOT_AVATAR_CROPS: list[any] = ["mascot", "circle", "rounded", "square"],
    AVATAR_ZOOM_MIN: float = 1.0,
    AVATAR_ZOOM_MAX: float = 3.0,
    AVATAR_FOCUS_CENTER: float = 0.5,
    _BOT_AVATAR_URL: any = re.compile(r"^/api/attachments/[A-Za-z0-9-]+\.(?:png|jpg|gif|webp)\Z");


def clamp_avatar_zoom(value: any) -> float {
    parsed = value if _is_num(value) else float("nan");
    if not math.isfinite(parsed) {
        return AVATAR_ZOOM_MIN;
    }
    clamped = min(AVATAR_ZOOM_MAX, max(AVATAR_ZOOM_MIN, float(parsed)));
    return _js_round(clamped * 100) / 100;
}


def clamp_avatar_focus(value: any) -> float {
    parsed = value if _is_num(value) else float("nan");
    if not math.isfinite(parsed) {
        return AVATAR_FOCUS_CENTER;
    }
    clamped = min(1.0, max(0.0, float(parsed)));
    return _js_round(clamped * 1000) / 1000;
}


def bot_avatar_profile(value: dict[str, any]) -> dict[str, any] {
    # Runtime-safe defaults for untrusted persisted/SSE profile data.
    crop = value.get("avatarCrop");
    profile = {"avatarCrop": crop if isinstance(crop, str) and crop in BOT_AVATAR_CROPS else "mascot"};
    url = value.get("avatarUrl");
    if isinstance(url, str) and _BOT_AVATAR_URL.match(url) {
        profile["avatarUrl"] = url;
    }
    return profile;
}


# ── shared/approval-mode.ts ────────────────────────────────────────────

glob APPROVAL_MODES: list[any] = ["ask", "edits", "auto", "full", "custom"];


def supports_approval_mode(driver_kind: (str | None), mode: str) -> bool {
    if mode == "custom" {
        return driver_kind == "codex";
    }
    if mode == "edits" {
        return (driver_kind if driver_kind is not None else "") in [
            "claudeAgent", "grokAgent", "antigravityAgent", "qwenAgent", "geminiAgent"
        ];
    }
    if mode != "full" {
        return True;
    }
    return (driver_kind if driver_kind is not None else "") in [
        "codex", "claudeAgent", "antigravityAgent", "cursorAgent", "grokAgent", "opencodeGo",
        "qwenAgent", "geminiAgent", "openai-compat", "grok", "minimax", "mistral", "cerebras"
    ];
}


def model_switch_needs_ask(mode: str, from_driver: (str | None), to_driver: (str | None)) -> bool {
    return not supports_approval_mode(to_driver, mode) or (
        (mode == "full" or mode == "custom") and from_driver != to_driver
    );
}


def is_approval_mode(value: any) -> bool {
    return isinstance(value, str) and value in APPROVAL_MODES;
}


def approval_mode_for(bot: any) -> str {
    # Resolve the durable mode without turning the legacy Auto bit into
    # Full access.
    grant = bot.get("approvalGrant");
    other_thread = (
        isinstance(grant, dict)
        and "threadOnly" in grant and grant["threadOnly"] is True
        and "threadId" in grant and isinstance(grant["threadId"], str)
        and isinstance(bot.get("threadId"), str)
        and grant["threadId"] != bot["threadId"]
    );
    if not _js_falsy(grant) and not other_thread {
        return "ask";
    }
    if is_approval_mode(bot.get("approvalMode")) {
        return bot["approvalMode"];
    }
    return "auto" if bot.get("autoApprove") is True else "ask";
}


# ── shared/thread-model.ts ─────────────────────────────────────────────

def same_model_selection(a: any, b: any) -> bool {
    # The same engine, model, effort and variant. `!a` in JS — undefined
    # and null alike — falls through to a === b.
    if a is UNDEF or a is None or b is UNDEF or b is None {
        return (a is UNDEF or a is None) and (b is UNDEF or b is None);
    }
    if not isinstance(a, dict) or not isinstance(b, dict) {
        return False;
    }
    return (
        _js_strict_eq(a.get("instanceId", UNDEF), b.get("instanceId", UNDEF))
        and _js_strict_eq(a.get("model", UNDEF), b.get("model", UNDEF))
        and _js_strict_eq(a.get("effort", UNDEF), b.get("effort", UNDEF))
        and _js_strict_eq(a.get("variant", UNDEF), b.get("variant", UNDEF))
    );
}


# ── shared/tool-scope.ts ───────────────────────────────────────────────

glob _SERVER_NAME: any = re.compile(r"^[a-z][a-z0-9_-]{0,31}\Z", re.ASCII),
    _CONTROL_CHARACTER: any = re.compile(r"[\x00-\x1f\x7f]", re.ASCII),
    MAX_SELECTORS: int = 256,
    MAX_SELECTOR_LENGTH: int = 1024;


def _valid_tool_name(name: any) -> bool {
    return (
        isinstance(name, str) and len(_js_trim(name)) > 0
        and _js_len(name) <= MAX_SELECTOR_LENGTH
        and not _CONTROL_CHARACTER.search(name)
        and "*" not in name
    );
}


def selector_identity(selector: str) -> (dict[str, any] | None) {
    if _js_len(selector) > MAX_SELECTOR_LENGTH or _CONTROL_CHARACTER.search(selector) {
        return None;
    }
    if selector.startswith("native:") {
        name = selector[7:];
        if name == "*" or _valid_tool_name(name) {
            return {"kind": "native", "name": name};
        }
    } elif selector.startswith("mcp:") {
        separator = selector.find(":", 4);
        if separator < 0 {
            return None;
        }
        server = selector[4:separator];
        name = selector[separator + 1:];
        if _SERVER_NAME.match(server) and (name == "*" or _valid_tool_name(name)) {
            return {"kind": "mcp", "server": server, "name": name};
        }
    }
    return None;
}


def parse_tool_scope(value: any) -> dict[str, any] {
    # Undefined inherits the existing catalog. A present invalid value never does.
    if value is UNDEF {
        return {"ok": True, "scope": UNDEF};
    }
    invalid = {"ok": False, "error": "Tool selection must contain only valid allow and deny lists."};
    if not isinstance(value, dict) {
        return invalid;
    }
    scope: dict[str, any] = {};
    for key in list(value.keys()) {
        if key != "allow" and key != "deny" {
            return invalid;
        }
        lst = value[key];
        if not isinstance(lst, list) or len(lst) > MAX_SELECTORS {
            return invalid;
        }
        for `entry in lst {
            if not isinstance(`entry, str) or selector_identity(`entry) is None {
                return invalid;
            }
        }
        scope[key] = list(dict.fromkeys(lst));
    }
    return {"ok": True, "scope": scope};
}


def _selector_matches(selector: str, tool: dict[str, any]) -> bool {
    selected = selector_identity(selector);
    return (
        selected is not None
        and selected["kind"] == tool["kind"]
        and (
            selected["kind"] != "mcp"
            or (tool["kind"] == "mcp" and selected["server"] == tool["server"])
        )
        and (selected["name"] == "*" or selected["name"] == tool["name"])
    );
}


def _scope_permits(scope: any, tool: dict[str, any]) -> bool {
    if not _valid_tool_name(tool.get("name")) or (
        tool["kind"] == "mcp" and not _SERVER_NAME.match(tool.get("server") or "")
    ) {
        return False;
    }
    if scope is None {
        scope = None;
    }
    allow = scope.get("allow") if isinstance(scope, dict) else None;
    deny = scope.get("deny") if isinstance(scope, dict) else None;
    allowed = allow is None or any(_selector_matches(s, tool) for s in allow);
    denied = deny is not None and any(_selector_matches(s, tool) for s in deny);
    return allowed and not denied;
}


def tool_scope_widens(previous: any, next_: any) -> bool {
    # Compare the selector partitions, including a tool/server outside
    # all exact names.
    before = parse_tool_scope(previous);
    after = parse_tool_scope(next_);
    if not after["ok"] {
        return False;
    }
    namespaces: dict[str, any] = {"native": set()};
    scopes = [
        before["scope"] if before["ok"] else None,
        after["scope"],
    ];
    for scope in scopes {
        if not isinstance(scope, dict) {
            continue;
        }
        for selector in list(scope.get("allow") or []) + list(scope.get("deny") or []) {
            tool = selector_identity(selector);
            namespace = "native" if tool["kind"] == "native" else f"mcp:{tool['server']}";
            if namespace not in namespaces {
                namespaces[namespace] = set();
            }
            if tool["name"] != "*" {
                namespaces[namespace].add(tool["name"]);
            }
        }
    }
    server = "unlisted";
    i = 0;
    while f"mcp:{server}" in namespaces {
        i += 1;
        server = f"unlisted{i}";
    }
    namespaces[f"mcp:{server}"] = set();
    for (namespace, names) in namespaces.items() {
        other = "__unlisted_tool__";
        i = 0;
        while other in names {
            i += 1;
            other = f"__unlisted_tool_{i}__";
        }
        names.add(other);
        for name in names {
            tool = (
                {"kind": "native", "name": name}
                if namespace == "native"
                else {"kind": "mcp", "server": namespace[4:], "name": name}
            );
            if _scope_permits(after["scope"], tool) and (
                not before["ok"] or not _scope_permits(before["scope"], tool)
            ) {
                return True;
            }
        }
    }
    return False;
}


# ── section-context.ts + published-teams.ts ────────────────────────────

def section_context_key(section: any) -> str {
    return _js_trim(section) if isinstance(section, str) and _js_trim(section) else "";
}


def _section_empty_file() -> dict[str, any] {
    return {"version": 1, "sections": [], "contexts": {}};
}


def _load_section_file(for_write: bool = False) -> dict[str, any] {
    if not os.path.exists(SECTION_CONTEXTS_FILE) {
        return _section_empty_file();
    }
    try {
        with open(SECTION_CONTEXTS_FILE, "r", encoding="utf-8") as f {
            input_ = _json_loads(f.read());
        }
        # Envelope: {version: 1, sections?: string[], contexts: record}.
        sections_field = input_.get("sections") if isinstance(input_, dict) else None;
        contexts_field = input_.get("contexts") if isinstance(input_, dict) else None;
        valid = (
            isinstance(input_, dict)
            and _is_num(input_.get("version")) and input_.get("version") == 1
            and isinstance(contexts_field, dict)
            and (
                "sections" not in input_
                or (isinstance(sections_field, list) and all(isinstance(s, str) for s in sections_field))
            )
        );
        if not valid {
            raise RuntimeError("Invalid team instructions file");
        }
        # Read own entries after validating the envelope: record parsers
        # can omit labels such as __proto__, which are ordinary team
        # names here. Validate each value again before putting it into
        # the dictionary.
        contexts: dict[str, any] = {};
        cf: any = contexts_field;
        for (key, value) in cf.items() {
            ok = (
                isinstance(value, dict)
                and isinstance(value.get("text"), str)
                and _finite(value.get("updatedAt"))
            );
            if not ok {
                continue;
            }
            if len(value["text"].encode("utf-8")) > SECTION_CONTEXT_MAX_BYTES {
                continue;
            }
            contexts[section_context_key(key)] = {"text": value["text"], "updatedAt": value["updatedAt"]};
        }
        raw = list(sections_field or []) + list(contexts.keys());
        sections = list(dict.fromkeys(s for s in (section_context_key(x) for x in raw) if s));
        return {"version": 1, "sections": sections, "contexts": contexts};
    } except Exception {
        if for_write {
            raise RuntimeError(
                "Saved teams and shared instructions could not be read; the existing file was left unchanged"
            );
        }
        return _section_empty_file();
    }
}


def _save_section_file(data: dict[str, any]) -> None {
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True);
    write_file_atomic(SECTION_CONTEXTS_FILE, _js_pretty(data), mode=0o600);
}


def read_sections() -> list[any] {
    return _load_section_file()["sections"];
}


def ensure_sections(names: list[any]) -> bool {
    # Remember legacy labels and newly created teams without changing
    # membership.
    data = _load_section_file(True);
    extra = [section_context_key(n) for n in names];
    extra = [s for s in extra if s];
    sections = list(dict.fromkeys(list(data["sections"]) + extra));
    if len(sections) == len(data["sections"]) {
        return False;
    }
    out = dict(data);
    out["sections"] = sections;
    _save_section_file(out);
    return True;
}


def _load_published_teams() -> dict[str, any] {
    teams: dict[str, any] = {};
    if not os.path.exists(PUBLISHED_TEAMS_FILE) {
        return teams;
    }
    try {
        with open(PUBLISHED_TEAMS_FILE, "r", encoding="utf-8") as f {
            file = _json_loads(f.read());
        }
        if not (
            isinstance(file, dict)
            and _is_num(file.get("version")) and file.get("version") == 1
            and isinstance(file.get("teams"), dict)
        ) {
            raise RuntimeError("Invalid published teams file");
        }
        # Own entries only: a team may be called anything, including __proto__.
        for (section, value) in file["teams"].items() {
            ok = (
                isinstance(value, dict)
                and isinstance(value.get("packageId"), str) and value["packageId"]
                and isinstance(value.get("lastRelease"), str) and value["lastRelease"]
            );
            if not ok {
                continue;
            }
            # keys defaults to {bots:{},rooms:{},routines:{}} only when absent.
            keys = (
                value["keys"]
                if "keys" in value
                else {"bots": {}, "rooms": {}, "routines": {}}
            );
            keys_ok = (
                isinstance(keys, dict)
                and all(isinstance(keys.get(part), dict) for part in ("bots", "rooms", "routines"))
                and all(
                    all(isinstance(v, str) for v in keys[part].values())
                    for part in ("bots", "rooms", "routines")
                )
            );
            if not keys_ok {
                continue;
            }
            teams[section] = {
                "packageId": value["packageId"],
                "lastRelease": value["lastRelease"],
                "keys": {
                    "bots": dict(keys["bots"]),
                    "rooms": dict(keys["rooms"]),
                    "routines": dict(keys["routines"]),
                },
            };
        }
    } except Exception {
        # An unreadable record only costs key stability on the next
        # export, which then derives keys from names as a first export does.
    }
    return teams;
}


def _save_published_teams(teams: dict[str, any]) -> None {
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True);
    write_file_atomic(
        PUBLISHED_TEAMS_FILE,
        _js_pretty({"version": 1, "teams": teams}),
        mode=0o600
    );
}


def rename_published_team(name: str, next_name: (str | None)) -> None {
    # Follow a team rename; null forgets the team (it was deleted).
    teams = _load_published_teams();
    team_entry = teams.get(name);
    if team_entry is None or name == next_name {
        return;
    }
    teams.pop(name, None);
    if next_name is not None {
        teams[next_name] = team_entry;
    }
    _save_published_teams(teams);
}


def _change_empty_section_file(name: str, next_name: (str | None)) -> None {
    # The caller checks that no bots or group chats still use this identity.
    data = _load_section_file(True);
    if name not in data["sections"] {
        raise RuntimeError("No such team");
    }
    index = data["sections"].index(name);
    if next_name is not None and next_name != name and next_name in data["sections"] {
        raise RuntimeError("A team with that name already exists");
    }
    if next_name == name {
        return;
    }
    if next_name is None {
        data["sections"].pop(index);
    } else {
        data["sections"][index] = next_name;
    }
    context = data["contexts"].get(name);
    data["contexts"].pop(name, None);
    if next_name is not None and context is not None {
        data["contexts"][next_name] = context;
    }
    _save_section_file(data);
    # Every team rename and removal funnels through here, so the team's
    # published package id and keys follow it.
    try {
        rename_published_team(name, next_name);
    } except Exception as error {
        print(
            f"[teams] Could not move the shared-package record for this team: {error}",
            file=sys.stderr
        );
    }
}


# ── config.ts: browser profile id aliases (#567 migration) ─────────────

glob _BROWSER_PROFILE_ID: any = re.compile(r"^[a-z0-9_-]{1,40}\Z", re.ASCII),
    _LEGACY_BROWSER_PROFILE_ID: any = re.compile(r"^[A-Za-z0-9_-]{1,40}\Z", re.ASCII);


def _valid_legacy_profile(p: any) -> bool {
    return (
        isinstance(p, dict)
        and isinstance(p.get("id"), str)
        and _LEGACY_BROWSER_PROFILE_ID.match(p["id"])
        and p["id"] != "guest"
        and isinstance(p.get("name"), str)
        and 1 <= _js_len(_js_trim(p["name"])) <= 40
        and _js_trim(p["name"]) == p["name"]
        and (
            "partitionId" not in p
            or (
                isinstance(p["partitionId"], str)
                and _LEGACY_BROWSER_PROFILE_ID.match(p["partitionId"])
                and p["partitionId"] != "guest"
            )
        )
    );
}


def _suffixed_browser_profile_id(base: str, unavailable: any) -> str {
    suffix = 2;
    while True {
        ending = f"-{suffix}";
        candidate = _js_slice_16(base, 0, 40 - len(ending)) + ending;
        if candidate != "guest" and candidate not in unavailable {
            return candidate;
        }
        suffix += 1;
    }
}


def _migrate_stored_browser_profiles(profiles: list[any]) -> dict[str, any] {
    # Port of config.ts migrateStoredBrowserProfiles; only `aliases` is
    # used by the store.
    requested_partitions = [p.get("partitionId") if p.get("partitionId") is not None else p["id"] for p in profiles];
    raw_bases = [p["id"].lower() for p in profiles];

    canonical_ids: list[any] = [None for _p in profiles];
    used = set();
    base_owner: dict[str, any] = {};
    for (index, base) in enumerate(raw_bases) {
        if base == "guest" {
            continue;
        }
        current = base_owner.get(base);
        if current is None or (profiles[index]["id"] == base and profiles[current]["id"] != base) {
            base_owner[base] = index;
        }
    }
    for (base, index) in base_owner.items() {
        canonical_ids[index] = base;
        used.add(base);
    }
    reserved = set(["guest"]) | set(raw_bases) | set(p.lower() for p in requested_partitions);
    for (index, base) in enumerate(raw_bases) {
        if canonical_ids[index] is not None {
            continue;
        }
        id_: any = _suffixed_browser_profile_id(base, reserved | used);
        canonical_ids[index] = id_;
        used.add(id_);
    }

    partition_winner: dict[str, any] = {};
    def winner_score(c: int, folded: str) -> int {
        return 1 if canonical_ids[c] == folded else 0;
    }
    for (index, partition_id) in enumerate(requested_partitions) {
        folded = partition_id.lower();
        current = partition_winner.get(folded);
        if current is None {
            partition_winner[folded] = index;
            continue;
        }
        if winner_score(index, folded) > winner_score(current, folded) {
            partition_winner[folded] = index;
        }
    }

    effective_partitions = [
        requested_partitions[i]
        if partition_winner.get(requested_partitions[i].lower()) == i
        else canonical_ids[i]
        for i in range(len(profiles))
    ];

    conflicting_id_owners = set();
    for (owner, id_) in enumerate(canonical_ids) {
        for (partition_owner, partition_id) in enumerate(effective_partitions) {
            if partition_owner != owner and partition_id.lower() == id_ {
                conflicting_id_owners.add(owner);
            }
        }
    }
    unavailable = reserved | used;
    for owner in conflicting_id_owners {
        id_ = _suffixed_browser_profile_id(raw_bases[owner], unavailable);
        canonical_ids[owner] = id_;
        unavailable.add(id_);
    }
    if conflicting_id_owners {
        effective_partitions = [
            requested_partitions[i]
            if partition_winner.get(requested_partitions[i].lower()) == i
            else canonical_ids[i]
            for i in range(len(profiles))
        ];
    }

    aliases: dict[str, any] = {};
    for (index, profile) in enumerate(profiles) {
        if profile["id"] not in aliases {
            aliases[profile["id"]] = canonical_ids[index];
        }
    }
    return {"aliases": aliases};
}


def load_browser_profile_id_aliases() -> dict[str, any] {
    # Exact old→canonical profile ids from #567's persisted config.
    try {
        with open(os.path.join(DATA_DIR, "config.json"), "r", encoding="utf-8") as f {
            document = _json_loads(f.read());
        }
        if not isinstance(document, dict) {
            return {};
        }
        profiles = document.get("browserProfiles");
        if profiles is None {
            return {};
        }
        if not isinstance(profiles, list) or len(profiles) > 20 {
            return {};
        }
        if not all(_valid_legacy_profile(p) for p in profiles) {
            return {};
        }
        return _migrate_stored_browser_profiles(profiles)["aliases"];
    } except Exception {
        return {};
    }
}


# ── commands.ts ────────────────────────────────────────────────────────

def run_command(command: dict[str, any], apply: any, now_ms: (int | None) = None) -> any {
    # Apply `apply` once for this (kind, key); a repeat returns the
    # stored result without calling `apply`.
    def produce -> str {
        result = apply();
        return js_stringify(result if result is not None else None);
    }
    receipt = with_command_receipt(
        command["kind"],
        command["key"],
        produce,
        now_ms if now_ms is not None else _now_ms()
    );
    return _json_loads(receipt["result"]);
}


# ── isProjectEmoji ─────────────────────────────────────────────────────

def _emoji_rgi() -> frozenset {
    s = _emoji_state.get("rgi");
    if s is None {
        s = frozenset(RGI_HEX.splitlines());
        _emoji_state["rgi"] = s;
    }
    return s;
}


def _emoji_singles() -> frozenset {
    s = _emoji_state.get("singles");
    if s is None {
        out = set();
        for part in SINGLES_HEX.split(",") {
            if "-" in part {
                (a, b) = part.split("-", 1);
                for cp in range(int(a, 16), int(b, 16) + 1) {
                    out.add(cp);
                }
            } else {
                out.add(int(part, 16));
            }
        }
        s = frozenset(out);
        _emoji_state["singles"] = s;
    }
    return s;
}


def is_project_emoji(value: any) -> bool {
    # Unicode's complete emoji sequences include flags, skin tones and
    # ZWJ combinations. Also allow unqualified single symbols, but not
    # standalone components such as a digit, skin tone or regional
    # indicator. Equivalent to store.ts's
    #   ^(?!\p{Emoji_Component}$)(?:\p{RGI_Emoji}|[\p{Emoji}--\p{Emoji_Component}])$
    # over an embedded set generated through Node's own regex.
    if not isinstance(value, str) or not value or _js_len(value) > 64 {
        return False;
    }
    if len(value) == 1 {
        return ord(value) in _emoji_singles();
    }
    return value in _emoji_rgi();
}


# ── titles ─────────────────────────────────────────────────────────────

glob UNTITLED_TASK: str = "New task",
    UNTITLED_THREAD: str = "New thread",
    TASK_TITLE_MAX: int = 80;


def thread_title_from(title: (str | None) = None) -> str {
    if title is None {
        return UNTITLED_THREAD;
    }
    trimmed = _js_slice_16(_js_trim(title), 0, TASK_TITLE_MAX);
    return trimmed if trimmed else UNTITLED_THREAD;
}


def title_from_message(text: str) -> str {
    # A task's name, taken from the first thing you asked it to do.
    line = _js_trim(_js_trim(text).split("\n")[0]);
    if _js_len(line) > 48 {
        return _js_slice_16(line, 0, 47) + "…";
    }
    return line if line else UNTITLED_TASK;
}


glob _TITLE_DECORATION_1: any = re.compile(r"^[#*\-\u2022]+", re.ASCII),
    _TITLE_QUOTES_L: any = re.compile(r"^[\"'\u201c\u201d\u2018\u2019\u0060]+", re.ASCII),
    _TITLE_QUOTES_R: any = re.compile(r"[\"'\u201c\u201d\u2018\u2019\u0060]+\Z", re.ASCII),
    _TITLE_TAIL_MARKS: any = re.compile(r"[#*]+\Z", re.ASCII),
    _TITLE_TAIL_DOTS: any = re.compile(r"[.\u3002]+\Z", re.ASCII),
    _TITLE_WS: any = re.compile(_JS_S_CLASS + r"+");


def title_from_llm(raw: str) -> (str | None) {
    # One usable line out of a model's title reply, or null.
    line = _js_trim(raw).split("\n")[0];
    line = _TITLE_DECORATION_1.sub("", line);
    line = _TITLE_QUOTES_L.sub("", line);
    line = _TITLE_QUOTES_R.sub("", line);
    # decoration the quotes were hiding
    line = _TITLE_DECORATION_1.sub("", line);
    line = _TITLE_TAIL_MARKS.sub("", line);
    line = _TITLE_TAIL_DOTS.sub("", line);
    line = _TITLE_WS.sub(" ", line);
    line = _js_trim(line);
    return line if 1 <= _js_len(line) <= 48 else None;
}


# ── connectorTools validation ──────────────────────────────────────────

glob CONNECTOR_SLUGS_MAX: int = 64,
    CONNECTOR_TOOLS_PER_SERVICE_MAX: int = 500,
    _CONNECTOR_SLUG: any = re.compile(r"^[a-z0-9][a-z0-9_-]{0,80}\Z", re.ASCII),
    _CONNECTOR_TOOL_NAME: any = re.compile(r"^[A-Z][A-Z0-9_]{0,127}\Z", re.ASCII);


def parse_connector_tools(value: any) -> dict[str, any] {
    # Validate and normalize a connectorTools value at the one boundary
    # every writer shares (patchBot). Returns a canonical copy.
    if not isinstance(value, dict) {
        return {"ok": False, "error": "connectorTools must be an object of service slugs to tool grants"};
    }
    entries = list(value.items());
    if len(entries) > CONNECTOR_SLUGS_MAX {
        return {"ok": False, "error": f"connectorTools may name at most {CONNECTOR_SLUGS_MAX} services"};
    }
    grants: dict[str, any] = {};
    for (slug, grant) in entries {
        if not isinstance(slug, str) or not _CONNECTOR_SLUG.match(slug) {
            return {"ok": False, "error": f"connectorTools service slugs must be lowercase slugs (got \"{slug}\")"};
        }
        if not isinstance(grant, dict) {
            return {
                "ok": False,
                "error": f"connectorTools.{slug} must be a grant like {{ tools: \"*\" }} or {{ tools: [\"TOOL_NAME\"] }}"
            };
        }
        keys = list(grant.keys());
        if len(keys) != 1 or keys[0] != "tools" {
            return {"ok": False, "error": f"connectorTools.{slug} accepts only a tools field"};
        }
        tools = grant["tools"];
        if tools == "*" and isinstance(tools, str) {
            grants[slug] = {"tools": "*"};
            continue;
        }
        if not isinstance(tools, list) or len(tools) == 0 {
            return {
                "ok": False,
                "error": f"connectorTools.{slug}.tools must be \"*\" or a non-empty list of tool names (use {{}} to grant no tools)"
            };
        }
        if len(tools) > CONNECTOR_TOOLS_PER_SERVICE_MAX {
            return {
                "ok": False,
                "error": f"connectorTools.{slug}.tools may list at most {CONNECTOR_TOOLS_PER_SERVICE_MAX} tools"
            };
        }
        names: list[any] = [];
        for tool in tools {
            if not isinstance(tool, str) or not _CONNECTOR_TOOL_NAME.match(tool) {
                return {
                    "ok": False,
                    "error": f"connectorTools.{slug}.tools names must be Composio tool names like GMAIL_SEND_EMAIL"
                };
            }
            if tool not in names {
                names.append(tool);
            }
        }
        grants[slug] = {"tools": names};
    }
    return {"ok": True, "grants": grants};
}


# ── pure helpers ───────────────────────────────────────────────────────

glob COLORS: list[any] = [
    "green", "blue", "red", "orange", "purple", "cyan", "pink", "yellow", "teal", "coral"
],
    ACTIVITY_BUSY: any = frozenset({"working", "waiting-on-you", "no-signal"}),
    ASK_NOW: dict[str, any] = {"approvalMode": "ask", "autoApprove": False, "alwaysAllow": []},
    TASK_PATCH_FIELDS: list[any] = [
        "title", "projectId", "modelSelection", "approvalMode", "autoApprove", "alwaysAllow",
        "unread", "rewound", "archivedAt", "pinned", "pinnedMessageId", "resumeCursors",
        "lastInstanceId", "cwd", "routineRunId", "surface", "surfaceSource", "snoozedUntil",
        "appliedCompactionId", "contextFloor", "lastContextModel",
    ],
    _TASK_PRIVATE_KEYS: any = frozenset({
        "resumeCursors", "lastInstanceId", "handedMessages", "appliedCompactionId",
        "contextFloor", "lastContextModel", "surfaceSource",
    });


def section_key(section: any) -> str {
    return _js_trim(section) if isinstance(section, str) and _js_trim(section) else "";
}


def to_wire_task(task: dict[str, any], bot_model: dict[str, any]) -> dict[str, any] {
    # The typed wire projection for one task.
    surface_source = task.get("surfaceSource");
    stored = {k: v for (k, v) in task.items() if k not in _TASK_PRIVATE_KEYS};
    ms = task.get("modelSelection", UNDEF);
    if ms is None or ms is UNDEF {
        ms = bot_model;
    }
    wire = dict(stored);
    wire["modelSelection"] = deepcopy(ms);
    wire["followsBotModel"] = not _has(task, "modelSelection");
    # Who pinned stays private. A client learns only whether the pin is
    # the machine's own record.
    if surface_source == "auto" and "surface" in wire {
        out = dict(wire);
        out["surfaceAuto"] = True;
        return out;
    }
    return wire;
}


def persisted_pin(task: dict[str, any]) -> dict[str, any] {
    # Only `true` is a pin. false/undefined must not land in bots.json
    # or groups.json.
    if task.get("pinned") is True {
        return task;
    }
    if "pinned" not in task {
        return task;
    }
    out = dict(task);
    out.pop("pinned", None);
    return out;
}


def task_counts_as_bot_unread(task: dict[str, any]) -> bool {
    # A hidden routine execution is not a conversation the person can open.
    return bool(task.get("unread")) and not task.get("routineRunId");
}


def mentioned_bots(text: str, peers: list[any]) -> list[any] {
    # Resolve @mentions in a message against a bot roster: `@` must
    # start a word, the name must end on a word boundary, names match
    # case-insensitively, longest name wins, hidden bots skipped,
    # results deduped. Callers pre-filter the sender out of `peers`.
    candidates = [
        p for p in peers
        if not p.get("hidden") and _js_trim(p.get("name") if isinstance(p.get("name"), str) else "")
    ];
    def _name_len_desc(p: any) -> int {
        return 0 - _js_len(p["name"]);
    }
    candidates = sorted(candidates, key=_name_len_desc);
    lower = text.lower();
    found: list[any] = [];
    at = -1;
    while True {
        at = lower.find("@", at + 1);
        if at == -1 {
            break;
        }
        if not is_mention_boundary(text, at) {
            continue;
        }
        rest = lower[at + 1:];
        hit = None;
        for p in candidates {
            name = p["name"].lower();
            if not rest.startswith(name) {
                continue;
            }
            after = rest[len(name):];
            if not is_mention_name_continuation(after if after != "" else None) {
                hit = p;
                break;
            }
        }
        if hit is not None and not any(f is hit for f in found) {
            found.append(hit);
        }
    }
    return found;
}


def normalize_group_default_responder(value: any, member_ids: any, dm: bool = False) -> dict[str, any] {
    # Normalize persisted or API-provided routing. Old rooms did not
    # have this field; giving them their first member as lead fixes the
    # old silent-send behavior.
    if dm {
        return {"kind": "mentions"};
    }
    if isinstance(value, dict) {
        kind = value.get("kind");
        if kind == "everyone" {
            return {"kind": "everyone"};
        }
        if kind == "mentions" {
            return {"kind": "mentions"};
        }
        if kind == "auto" {
            # A fallback who left the room reverts to "the first member".
            fb = value.get("fallbackBotId");
            if isinstance(fb, str) and fb in member_ids {
                return {"kind": "auto", "fallbackBotId": fb};
            }
            return {"kind": "auto"};
        }
        if kind == "member" and isinstance(value.get("botId"), str) and value["botId"] in member_ids {
            return {"kind": "member", "botId": value["botId"]};
        }
    }
    if len(member_ids) == 0 {
        return {"kind": "mentions"};
    }
    return {"kind": "member", "botId": member_ids[0]};
}


def room_responders(text: str, members: list[any], default_responder: dict[str, any]) -> list[any] {
    # Resolve the bots invoked by a human room message. Explicit targets
    # win; otherwise the room policy chooses.
    available = [m for m in members if not m.get("hidden")];
    everyone = "everyone";
    at = text.find("@");
    while at != -1 {
        candidate = text[at + 1 : at + 1 + len(everyone)];
        if (
            is_mention_boundary(text, at)
            and candidate.lower() == everyone
            and not is_mention_name_continuation(
                text[at + 1 + len(everyone):] or None
            )
        ) {
            return available;
        }
        at = text.find("@", at + 1);
    }
    mentioned = mentioned_bots(text, available);
    if mentioned {
        return mentioned;
    }
    if default_responder.get("kind") == "everyone" {
        return available;
    }
    if default_responder.get("kind") == "member" {
        for member in available {
            if member.get("id") == default_responder.get("botId") {
                return [member];
            }
        }
        return [];
    }
    # Auto without a decision is lead mode: its fallback member, else
    # the first active member.
    if default_responder.get("kind") == "auto" {
        fallback = None;
        for member in available {
            if member.get("id") == default_responder.get("fallbackBotId") {
                fallback = member;
                break;
            }
        }
        if fallback is None and available {
            fallback = available[0];
        }
        return [fallback] if fallback is not None else [];
    }
    return [];
}


def redact_bot_authored(message: dict[str, any]) -> dict[str, any] {
    # Everything the BOT authored is scrubbed of content-shaped secrets
    # before it is stored. What the user typed is theirs and stays.
    if message.get("role") != "bot" {
        return message;
    }
    out = dict(message);
    if isinstance(out.get("text"), str) {
        out["text"] = redact_secrets_in_text(out["text"]);
    }
    if isinstance(out.get("compaction"), dict) {
        comp = out["compaction"];
        nxt = dict(comp);
        _js_set(nxt, "summary", redact_secrets_in_text(comp.get("summary")));
        out["compaction"] = nxt;
    }
    tool = out.get("tool");
    if isinstance(tool, dict) and tool.get("name") {
        nxt = dict(tool);
        nxt["name"] = redact_secrets_in_text(nxt["name"]);
        if nxt.get("summary") {
            nxt["summary"] = redact_secrets_in_text(nxt["summary"]);
        }
        out["tool"] = nxt;
    }
    if isinstance(out.get("routineRun"), dict) {
        rr = dict(out["routineRun"]);
        rr["routineName"] = redact_secrets_in_text(rr.get("routineName"));
        if rr.get("summary") {
            rr["summary"] = redact_secrets_in_text(rr["summary"]);
        }
        if rr.get("error") {
            rr["error"] = redact_secrets_in_text(rr["error"]);
        }
        out["routineRun"] = rr;
    }
    if isinstance(out.get("goalRun"), dict) {
        gr = out["goalRun"];
        nxt = dict(gr);
        _js_set(nxt, "goal", redact_secrets_in_text(gr.get("goal")));
        _js_set(nxt, "coordinatorName", redact_secrets_in_text(gr.get("coordinatorName")));
        detail = gr.get("detail");
        _js_set(nxt, "detail", redact_secrets_in_text(detail) if detail else UNDEF);
        out["goalRun"] = nxt;
    }
    if isinstance(out.get("card"), dict) {
        card = dict(out["card"]);
        card["title"] = redact_secrets_in_text(card.get("title"));
        if isinstance(card.get("subtitle"), str) {
            card["subtitle"] = redact_secrets_in_text(card["subtitle"]);
        }
        if isinstance(card.get("summary"), str) {
            card["summary"] = redact_secrets_in_text(card["summary"]);
        }
        if isinstance(card.get("held"), str) {
            card["held"] = redact_secrets_in_text(card["held"]);
        }
        if isinstance(card.get("answeredText"), str) {
            card["answeredText"] = redact_secrets_in_text(card["answeredText"]);
        }
        allow = card.get("commandAllowlist");
        if isinstance(allow, dict) and (
            redact_secrets_in_text(allow.get("command")) != allow.get("command")
            or redact_secrets_in_text(allow.get("cwd")) != allow.get("cwd")
        ) {
            card.pop("commandAllowlist", None);
        }
        # Bot-authored question text sits behind the subtitle the same
        # way a routine's instructions do.
        if isinstance(card.get("questionRequest"), dict) {
            qr = dict(card["questionRequest"]);
            questions = [];
            for question in (qr.get("questions") or []) {
                q2 = dict(question);
                _js_set(q2, "question", redact_secrets_in_text(question.get("question")));
                if question.get("header") {
                    q2["header"] = redact_secrets_in_text(question["header"]);
                }
                options = [];
                for option in (question.get("options") or []) {
                    o2 = dict(option);
                    _js_set(o2, "label", redact_secrets_in_text(option.get("label")));
                    if option.get("description") {
                        o2["description"] = redact_secrets_in_text(option["description"]);
                    }
                    options.append(o2);
                }
                q2["options"] = options;
                questions.append(q2);
            }
            qr["questions"] = questions;
            card["questionRequest"] = qr;
        }
        # Routine definitions are executable bot-authored text stored
        # behind the visible summary.
        if isinstance(card.get("routineRequest"), dict) {
            rrq = card["routineRequest"];
            operation = rrq.get("operation") if isinstance(rrq.get("operation"), dict) else None;
            if operation is not None and operation.get("action") == "create" {
                routine = dict(operation.get("routine") or {});
                routine["name"] = redact_secrets_in_text(routine.get("name"));
                routine["instructions"] = redact_secrets_in_text(routine.get("instructions"));
                op2 = dict(operation);
                op2["routine"] = routine;
                nxt = dict(rrq);
                nxt["operation"] = op2;
                card["routineRequest"] = nxt;
            } elif operation is not None and operation.get("action") == "update" {
                changes = dict(operation.get("changes") or {});
                if isinstance(changes.get("name"), str) {
                    changes["name"] = redact_secrets_in_text(changes["name"]);
                }
                if isinstance(changes.get("instructions"), str) {
                    changes["instructions"] = redact_secrets_in_text(changes["instructions"]);
                }
                op2 = dict(operation);
                op2["changes"] = changes;
                nxt = dict(rrq);
                nxt["operation"] = op2;
                card["routineRequest"] = nxt;
            } else {
                nxt = dict(rrq);
                if operation is not None {
                    nxt["operation"] = dict(operation);
                }
                card["routineRequest"] = nxt;
            }
        }
        if isinstance(card.get("skillRequest"), dict) {
            sr = card["skillRequest"];
            original_preview = sr.get("preview", UNDEF);
            preview = UNDEF if original_preview is UNDEF else redact_secrets_in_text(original_preview);
            # Keep the digest binding only when this store-wide pass is a
            # no-op and the supplied digest already matches the persisted
            # preview.
            preview_sha256 = (
                hashlib.sha256(preview.encode("utf-8")).hexdigest()
                if preview is not UNDEF and isinstance(preview, str) and preview == original_preview
                else UNDEF
            );
            sha256 = sr.get("sha256", UNDEF);
            if not (sha256 is not UNDEF and sha256 == preview_sha256) {
                sha256 = UNDEF;
            }
            nxt = dict(sr);
            _js_set(nxt, "gist", redact_secrets_in_text(sr.get("gist")));
            source = sr.get("source", UNDEF);
            _js_set(nxt, "source", UNDEF if source is UNDEF else redact_secrets_in_text(source));
            _js_set(nxt, "preview", preview);
            _js_set(nxt, "sha256", sha256);
            warnings = sr.get("warnings");
            nxt["warnings"] = [redact_secrets_in_text(w) for w in (warnings or [])];
            card["skillRequest"] = nxt;
        }
        # A profile proposal's before/after text (and its reason) is
        # hidden under the card's visible summary.
        if isinstance(card.get("profileRequest"), dict) {
            pr = card["profileRequest"];
            def scrub_changes(changes: any) -> dict[str, any] {
                o = dict(changes) if isinstance(changes, dict) else {};
                if isinstance(changes, dict) {
                    for (key, value) in changes.items() {
                        if isinstance(value, str) {
                            o[key] = redact_secrets_in_text(value);
                        }
                    }
                }
                return o;
            }
            nxt = dict(pr);
            _js_set(nxt, "targetName", redact_secrets_in_text(pr.get("targetName")));
            _js_set(nxt, "reason", redact_secrets_in_text(pr.get("reason")));
            nxt["before"] = scrub_changes(pr.get("before"));
            nxt["changes"] = scrub_changes(pr.get("changes"));
            card["profileRequest"] = nxt;
        }
        out["card"] = card;
    }
    if isinstance(out.get("connector"), dict) {
        conn = out["connector"];
        nxt = dict(conn);
        _js_set(nxt, "label", redact_secrets_in_text(conn.get("label")));
        _js_set(nxt, "description", redact_secrets_in_text(conn.get("description")));
        err = conn.get("error");
        _js_set(nxt, "error", redact_secrets_in_text(err) if err else UNDEF);
        out["connector"] = nxt;
    }
    if isinstance(out.get("secret"), dict) {
        sec = out["secret"];
        nxt = dict(sec);
        _js_set(nxt, "label", redact_secrets_in_text(sec.get("label")));
        _js_set(nxt, "description", redact_secrets_in_text(sec.get("description")));
        err = sec.get("error");
        _js_set(nxt, "error", redact_secrets_in_text(err) if err else UNDEF);
        out["secret"] = nxt;
    }
    return out;
}


# ── graph wiring ───────────────────────────────────────────────────────

def _wire_bot_threads(bot: dict[str, any]) -> None {
    # Materialize bot→thread membership as Bot -Contains-> Thread edges.
    # Best-effort: the registries on disk are the source of truth; a
    # graph failure never affects them.
    try {
        bot_id = bot.get("id");
        if not bot_id {
            return;
        }
        bnode = bot_node(bot_id);
        wanted = set();
        if bot.get("threadId") {
            wanted.add(bot["threadId"]);
        }
        for t in (bot.get("tasks") or []) {
            if isinstance(t, dict) and t.get("threadId") {
                wanted.add(t["threadId"]);
            }
        }
        have = set();
        for t in [bnode ->:Contains:->][?:Thread] {
            have.add(t.thread_id);
        }
        for tid in wanted {
            if tid not in have {
                bnode +>:Contains:+> thread_node(tid);
            }
        }
    } except Exception {
    }
}


def _unwire_bot_threads(bot_id: str) -> None {
    try {
        bnode = bot_node(bot_id);
        for e in [bnode ->:Contains:->] {
            del e;
        }
    } except Exception {
    }
}


def _identity_selection(selection: any) -> any {
    return selection;
}


def _no_driver(instance_id: any) -> (str | None) {
    return None;
}


def _js_falsy(v: any) -> bool {
    # JS truthiness for values where Python and JS disagree: {} and []
    # are TRUTHY in JS. Falsy: undefined, null, false, 0, NaN, "".
    if v is UNDEF or v is None or v is False {
        return True;
    }
    if _is_num(v) {
        return v == 0 or v != v;
    }
    if isinstance(v, str) {
        return v == "";
    }
    return False;
}

def _has(d: dict[str, any], k: str) -> bool {
    # `d.k !== undefined` — present and not the undefined sentinel.
    return k in d and d[k] is not UNDEF;
}


def _nn(a: any, b: any) -> any {
    # JS `a ?? b`: fall back on null AND undefined.
    return a if a is not None and a is not UNDEF else b;
}


def _js_gt(a: any, b: any) -> bool {
    # JS `a > b` where a is a stored number and b may be absent/null/NaN:
    # undefined → NaN → false; null → 0; non-number → NaN → false.
    if b is UNDEF or b is None {
        if b is UNDEF {
            return False;
        }
        b = 0;
    }
    if not _is_num(b) or not _is_num(a) {
        return False;
    }
    if a != a or b != b {
        return False;
    }
    return a > b;
}


glob REMOVED_COMPUTER_DRIVER: str = "boxAgent";


# ── Store ───────────────────────────────────────────────────────────────
# bots/groups are JSON-shaped dicts (BotRecord/GroupRecord). threads maps
# threadId -> {"messages": [...], "activeLeafId": str|None} (ThreadState).

class Store {
    def __init__(
        self: any,
        default_selection: any,
        complete_new_bot_selection: any = None,
        driver_kind_of: any = None
    ) {
        self.bots = [];
        self.groups = [];
        self.threads = {};
        self.default_selection = default_selection;
        self.complete_new_bot_selection = (
            complete_new_bot_selection
            if complete_new_bot_selection is not None
            else _identity_selection
        );
        self.driver_kind_of = (
            driver_kind_of if driver_kind_of is not None else _no_driver
        );
        self.listeners = [];
        # A broken team registry must not prevent loading independent chat data.
        self.registering_initial_sections = True;
        self.legacy_activities = {};

        os.makedirs(DATA_DIR, exist_ok=True);
        tighten_registry_file(BOTS_FILE);
        tighten_registry_file(GROUPS_FILE);
        # Whether the bot list is the real one: room repair trusts it to
        # say which members no longer exist; an unreadable file must never
        # read as "every member was deleted".
        bots_loaded = False;
        try {
            with open(BOTS_FILE, "r", encoding="utf-8") as f {
                self.bots = _json_loads(f.read());
            }
            bots_loaded = isinstance(self.bots, list);
        } except Exception {
            self.bots = [];
        }
        try {
            with open(GROUPS_FILE, "r", encoding="utf-8") as f {
                self.groups = _json_loads(f.read());
            }
        } except Exception {
            self.groups = [];
        }
        self._remember_sections(
            [r.get("section") for r in list(self.bots) + list(self.groups)]
        );
        # busy never survives a restart — no turn does either. Rooms saved
        # before default responders existed adopt their first member as lead.
        bots_migrated = False;
        browser_profile_aliases = load_browser_profile_id_aliases();
        chief_sections_seen = set();
        groups_migrated = False;
        for b in self.bots {
            if not isinstance(b, dict) {
                continue;
            }
            # transient state never survives a restart — and if a previous
            # process died mid-turn, bots.json still says busy/working;
            # persist the reset so the next load does not read it again
            if b.get("busy") or ("activity" in b and b["activity"] != "idle") {
                bots_migrated = True;
            }
            b["busy"] = False;
            b["activity"] = "idle";
            if not isinstance(b.get("soul"), str) {
                b["soul"] = "";
                bots_migrated = True;
            }
            if b.get("soulHash") != soul_hash(b["soul"]) {
                b["soulHash"] = soul_hash(b["soul"]);
                bots_migrated = True;
            }
            # Existing bots predate their folders. Create missing mirrors
            # before their first history write, preserving edits on disk.
            if not os.path.exists(soul_file(b["id"])) {
                try {
                    write_soul_mirror(b["id"], b["soul"]);
                } except Exception as e {
                    print(
                        f"[bot-folder] could not create SOUL.md for {b['id']}: {e}",
                        file=sys.stderr
                    );
                }
            }
            if b.get("browserProfile") {
                browser_profile = browser_profile_aliases.get(b["browserProfile"]);
                if browser_profile is not None and browser_profile != b["browserProfile"] {
                    b["browserProfile"] = browser_profile;
                    bots_migrated = True;
                }
            }
            if (
                "cloudBackend" in b
                and b["cloudBackend"] != "box"
                and b["cloudBackend"] != "vps"
            ) {
                del b["cloudBackend"];
                bots_migrated = True;
            }
            if (
                "autoStartVps" in b
                and b["autoStartVps"] is not True
                and b["autoStartVps"] is not False
            ) {
                del b["autoStartVps"];
                bots_migrated = True;
            }
            managed = b.get("managedSections");
            if "managedSections" in b and (
                not b.get("chiefOfStaff")
                or not isinstance(managed, list)
                or len(managed) > 100
                or any(not isinstance(s, str) or _js_len(s) > 60 for s in managed)
            ) {
                del b["managedSections"];
                bots_migrated = True;
            }
            if "approvalMode" in b and not is_approval_mode(b["approvalMode"]) {
                del b["approvalMode"];
                bots_migrated = True;
            }
            # A trusted elevation is a prepare/confirm/activate commit. If
            # the process died before activation, the durable marker
            # survives beside the mode in the same atomic bots.json write.
            # Revoke it before any new work can start.
            if "approvalGrant" in b {
                grant = b["approvalGrant"];
                thread_only = (
                    isinstance(grant, dict) and grant.get("threadOnly") is True
                );
                if thread_only {
                    # A crash may land between saving the target and
                    # clearing its journal. Revoke that target only.
                    target = None;
                    for task in (b.get("tasks") or []) {
                        if isinstance(task, dict) and task.get("threadId") == grant.get("threadId") {
                            target = task;
                            break;
                        }
                    }
                    if target is not None {
                        target["approvalMode"] = "ask";
                        target["autoApprove"] = False;
                    }
                }
                if not thread_only {
                    b["approvalMode"] = "ask";
                    b["autoApprove"] = False;
                    for task in (b.get("tasks") or []) {
                        if isinstance(task, dict) and task.get("approvalMode") in ("full", "custom") {
                            task["approvalMode"] = "ask";
                            task["autoApprove"] = False;
                        }
                    }
                }
                del b["approvalGrant"];
                bots_migrated = True;
            }
            avatar = bot_avatar_profile(b);
            if "avatarUrl" in b and not _js_strict_eq(avatar.get("avatarUrl", UNDEF), b["avatarUrl"]) {
                del b["avatarUrl"];
                bots_migrated = True;
            }
            if "avatarCrop" in b and not _js_strict_eq(avatar.get("avatarCrop", UNDEF), b["avatarCrop"]) {
                del b["avatarCrop"];
                bots_migrated = True;
            }
            if "avatarZoom" in b {
                zoom = clamp_avatar_zoom(b["avatarZoom"]);
                if zoom == AVATAR_ZOOM_MIN {
                    del b["avatarZoom"];
                    bots_migrated = True;
                } elif not _js_strict_eq(b["avatarZoom"], zoom) {
                    b["avatarZoom"] = zoom;
                    bots_migrated = True;
                }
            }
            for key in ("avatarFocusX", "avatarFocusY") {
                if key not in b {
                    continue;
                }
                focus = clamp_avatar_focus(b[key]);
                if focus == AVATAR_FOCUS_CENTER {
                    del b[key];
                    bots_migrated = True;
                } elif not _js_strict_eq(b[key], focus) {
                    b[key] = focus;
                    bots_migrated = True;
                }
            }
        }
        for b in self.bots {
            if not isinstance(b, dict) or not b.get("chiefOfStaff") {
                continue;
            }
            key = section_key(b.get("section"));
            if key not in chief_sections_seen {
                chief_sections_seen.add(key);
                if b.get("hidden") {
                    b["hidden"] = False;
                    bots_migrated = True;
                }
                continue;
            }
            b["chiefOfStaff"] = False;
            b.pop("managedSections", None);
            bots_migrated = True;
        }
        # Peer grants originally used mutable display names
        # (ask_bot:@Helper). Convert only when exactly one bot has that
        # name; ambiguous legacy entries remain inert.
        for b in self.bots {
            if not isinstance(b, dict) or not b.get("alwaysAllow") {
                continue;
            }
            changed = False;
            migrated = [];
            for key in b["alwaysAllow"] {
                if not isinstance(key, str) {
                    migrated.append(key);
                    continue;
                }
                m = re.match(r"^(ask_bot|delegate_bot):@(.+)\Z", key, re.ASCII);
                if m is None {
                    migrated.append(key);
                    continue;
                }
                candidates = [c for c in self.bots if c.get("name") == m.group(2)];
                if len(candidates) != 1 {
                    migrated.append(key);
                    continue;
                }
                changed = True;
                migrated.append(peer_allow_key(m.group(1), candidates[0]["id"]));
            }
            if changed {
                b["alwaysAllow"] = list(dict.fromkeys(migrated));
                bots_migrated = True;
            }
        }
        bot_ids = set(b.get("id") for b in self.bots);
        for g in self.groups {
            if not isinstance(g, dict) {
                continue;
            }
            g["busyBotId"] = None;
            g.pop("turnStartedAt", None);
            member_ids = g.get("memberIds");
            # A deleted bot used to stay a member for good. Bot-to-bot
            # channels keep their pair; they are not edited as rooms.
            if (
                bots_loaded
                and not g.get("dm")
                and isinstance(member_ids, list)
                and any(i not in bot_ids for i in member_ids)
            ) {
                g["memberIds"] = [i for i in member_ids if i in bot_ids];
                groups_migrated = True;
            }
            normalized = normalize_group_default_responder(
                g.get("defaultResponder"),
                g.get("memberIds") if isinstance(g.get("memberIds"), list) else [],
                bool(g.get("dm"))
            );
            if js_stringify(normalized) != js_stringify(g.get("defaultResponder")) {
                groups_migrated = True;
            }
            g["defaultResponder"] = normalized;
            # Bot-to-bot channels intentionally remain one canonical thread.
            if g.get("dm") {
                if "tasks" in g {
                    del g["tasks"];
                    groups_migrated = True;
                }
                continue;
            }
            if not isinstance(g.get("tasks"), list) or len(g["tasks"]) == 0 {
                initial = {
                    "threadId": g.get("threadId"),
                    "title": self._first_user_line(g.get("threadId")) or UNTITLED_TASK,
                    "createdAt": g.get("createdAt", UNDEF),
                    "updatedAt": g.get("createdAt", UNDEF),
                };
                if "pinnedCwd" in g {
                    initial["pinnedCwd"] = g["pinnedCwd"];
                }
                if g.get("pinnedMessageId") {
                    initial["pinnedMessageId"] = g["pinnedMessageId"];
                }
                g["tasks"] = [initial];
                groups_migrated = True;
            }
            # Repair a malformed/stale active pointer conservatively. Every
            # task transcript is retained; the newest known task becomes active.
            active = None;
            for task in g["tasks"] {
                if task.get("threadId") == g.get("threadId") {
                    active = task;
                    break;
                }
            }
            if active is None {
                active = g["tasks"][0];
                g["threadId"] = active["threadId"];
                groups_migrated = True;
            }
            _js_set(g, "pinnedCwd", active.get("pinnedCwd", UNDEF));
            _js_set(g, "pinnedMessageId", active.get("pinnedMessageId", UNDEF));
        }
        if groups_migrated {
            self.save_groups();
        }
        # Older builds copied a bot's model onto every thread it made, so a
        # thread on exactly its bot's model is a copy, not a person's pick:
        # once per data directory it is cleared and the thread follows its bot.
        clear_model_copies = (
            not os.path.exists(THREAD_MODEL_COPIES_CLEARED)
            and (bots_loaded or not os.path.exists(BOTS_FILE))
        );
        # bots saved before tasks existed have one endless thread; adopt it
        # as their first task so nothing is lost and nothing special-cases it
        for b in self.bots {
            if not isinstance(b, dict) {
                continue;
            }
            # Folders are organizational only. Preserve threads' own models
            # while discarding the unshipped folder-default setting.
            projects = b.get("projects");
            if isinstance(projects, list) and any(
                isinstance(p, dict) and "modelSelection" in p for p in projects
            ) {
                mapped = [];
                for p in projects {
                    np = {"id": p.get("id"), "name": p.get("name")};
                    if is_project_emoji(p.get("emoji")) {
                        np["emoji"] = p["emoji"];
                    }
                    mapped.append(np);
                }
                b["projects"] = mapped;
                bots_migrated = True;
            }
            if not isinstance(b.get("tasks"), list) or len(b["tasks"]) == 0 {
                b["tasks"] = [{
                    "threadId": b.get("threadId"),
                    "title": self._first_user_line(b.get("threadId")) or UNTITLED_TASK,
                    "createdAt": b.get("createdAt", UNDEF),
                    "updatedAt": b.get("createdAt", UNDEF),
                    "resumeCursors": b["resumeCursors"] if b.get("resumeCursors") is not None else {},
                }];
                bots_migrated = True;
            }
            # Retain an old active transcript even if a stale tasks array
            # omitted it. Repairing the pointer by selecting another task
            # would hide it.
            active = None;
            for task in b["tasks"] {
                if not isinstance(task, dict) {
                    continue;
                }
                if task.get("threadId") == b.get("threadId") {
                    active = task;
                    break;
                }
            }
            if active is None {
                active = {
                    "threadId": b.get("threadId"),
                    "title": self._first_user_line(b.get("threadId")) or UNTITLED_TASK,
                    "createdAt": b.get("createdAt", UNDEF),
                    "updatedAt": b.get("createdAt", UNDEF),
                    "resumeCursors": b["resumeCursors"] if b.get("resumeCursors") is not None else {},
                };
                b["tasks"].insert(0, active);
                bots_migrated = True;
            }
            for task in b["tasks"] {
                if not isinstance(task, dict) {
                    continue;
                }
                if (
                    clear_model_copies
                    and _has(task, "modelSelection")
                    and same_model_selection(task["modelSelection"], b.get("modelSelection"))
                ) {
                    del task["modelSelection"];
                    bots_migrated = True;
                }
                if _js_falsy(task.get("resumeCursors", UNDEF)) {
                    task["resumeCursors"] = (
                        (b["resumeCursors"] if b.get("resumeCursors") is not None else {})
                        if task is active else {}
                    );
                    bots_migrated = True;
                }
                if "unread" not in task {
                    _js_set(task, "unread", (b.get("unread", UNDEF) if task is active else False));
                    bots_migrated = True;
                }
                # Older builds left a failed hidden run unread. Clear it
                # before the recompute below so the saved roster heals.
                if task.get("routineRunId") and task.get("unread") {
                    task["unread"] = False;
                    bots_migrated = True;
                }
                if task is active {
                    if "rewound" not in task and "rewound" in b {
                        task["rewound"] = b["rewound"];
                        bots_migrated = True;
                    }
                    if "pinnedMessageId" not in task and "pinnedMessageId" in b {
                        task["pinnedMessageId"] = b["pinnedMessageId"];
                        bots_migrated = True;
                    }
                }
                if "approvalMode" in task and not is_approval_mode(task["approvalMode"]) {
                    del task["approvalMode"];
                    bots_migrated = True;
                }
                if "busy" in task or "activity" in task or "turnStartedAt" in task {
                    bots_migrated = True;
                }
                task["busy"] = False;
                task["activity"] = "idle";
                _js_set(task, "turnStartedAt", UNDEF);
            }
            self._mirror_active_task(b, active);
            b["unread"] = any(task_counts_as_bot_unread(t) for t in b["tasks"]);
        }
        if bots_migrated {
            self.save_bots();
        }
        if clear_model_copies {
            write_file_atomic(
                THREAD_MODEL_COPIES_CLEARED,
                "Threads follow their bot's model; the copies older builds made are cleared.\n",
                mode=0o600
            );
        }
        # Search reads SQLite directly, so migrate every known legacy
        # transcript at startup rather than waiting until the user opens it.
        known: list[any] = [];
        for b in self.bots {
            if not isinstance(b, dict) {
                continue;
            }
            known.append(b.get("threadId"));
            for t in (b.get("tasks") or []) {
                known.append(t.get("threadId"));
            }
        }
        for g in self.groups {
            if not isinstance(g, dict) {
                continue;
            }
            known.append(g.get("threadId"));
            for t in (g.get("tasks") or []) {
                known.append(t.get("threadId"));
            }
        }
        for thread_id in list(dict.fromkeys(known)) {
            if not isinstance(thread_id, str) {
                continue;
            }
            legacy = messages_file(thread_id);
            if os.path.exists(legacy) {
                read_thread(thread_id, legacy);
            }
        }
        # After legacy transcripts are in SQLite, so the first boot sees
        # their newest message instead of stamping createdAt.
        self.repair_thread_updated_ats();
        # After the roster is loaded, so identity resolution sees which
        # opener ids are still live.
        self.repair_duplicate_pair_conversations();
        self.registering_initial_sections = False;
    }

    def _note_thread_activity(self: any, thread_id: str, at: any) -> None {
        # Advance a task's update stamp in memory only. Message writes must
        # not rewrite bots.json; the next snapshot and the startup repair
        # read this.
        if not _finite(at) {
            return;
        }
        for bot in self.bots {
            for task in (bot.get("tasks") or []) {
                if task.get("threadId") != thread_id {
                    continue;
                }
                current = task.get("updatedAt");
                base = 0 if current is None or current is UNDEF else (current if _is_num(current) else float("nan"));
                nxt = max(base, at);
                if task.get("updatedAt") != nxt {
                    task["updatedAt"] = nxt;
                }
            }
        }
        for group in self.groups {
            for task in (group.get("tasks") or []) {
                if task.get("threadId") != thread_id {
                    continue;
                }
                current = task.get("updatedAt");
                base = 0 if current is None or current is UNDEF else (current if _is_num(current) else float("nan"));
                nxt = max(base, at);
                if task.get("updatedAt") != nxt {
                    task["updatedAt"] = nxt;
                }
            }
        }
    }

    def repair_thread_updated_ats(self: any) -> None {
        # Fill missing stamps, and raise a stamp that is older than the
        # newest stored message. Never moves a stamp backwards.
        bot_tasks = [t for b in self.bots for t in (b.get("tasks") or [])];
        group_tasks = [t for g in self.groups for t in (g.get("tasks") or [])];
        latest = latest_message_ats([t.get("threadId") for t in bot_tasks + group_tasks]);
        bots_dirty = False;
        groups_dirty = False;
        def repair(task: dict[str, any]) -> bool {
            tid: any = task.get("threadId");
            from_messages = latest.get(tid);
            cur = task.get("updatedAt", UNDEF);
            if from_messages is not None and (cur is UNDEF or _js_gt(from_messages, cur)) {
                nxt = from_messages;
            } else {
                nxt = cur if cur is not UNDEF else task.get("createdAt", UNDEF);
            }
            if _js_strict_eq(cur, nxt) {
                return False;
            }
            _js_set(task, "updatedAt", nxt);
            return True;
        }
        for task in bot_tasks {
            if repair(task) {
                bots_dirty = True;
            }
        }
        for task in group_tasks {
            if repair(task) {
                groups_dirty = True;
            }
        }
        if bots_dirty {
            self.save_bots();
        }
        if groups_dirty {
            self.save_groups();
        }
    }

    def _opener_identity(self: any, opened_by: dict[str, any]) -> str {
        # Resolve the identity of a historical pair row, including a
        # sender recreated with the same unique name.
        if self.bot(opened_by.get("botId")) is not None {
            return opened_by["botId"];
        }
        named = [b for b in self.bots if b.get("name") == opened_by.get("name")];
        return named[0]["id"] if len(named) == 1 else opened_by["botId"];
    }

    def repair_duplicate_pair_conversations(self: any) -> None {
        # At most one live pair row per (recipient, sender identity);
        # collapse extras on load, keeping the first row in the task list.
        bots_dirty = False;
        for bot in self.bots {
            tasks = bot.get("tasks");
            if not isinstance(tasks, list) {
                continue;
            }
            pairs: dict[str, any] = {};
            for task in tasks {
                by_ = task.get("openedBy");
                if not isinstance(by_, dict) or by_.get("kind") != "pair" or task.get("closedBy") {
                    continue;
                }
                identity = self._opener_identity(by_);
                pairs.setdefault(identity, []).append(task);
            }
            for rows in pairs.values() {
                # Rows are in task-list order; keep the newest.
                for duplicate in rows[1:] {
                    by_ = duplicate["openedBy"];
                    identity = self._opener_identity(by_);
                    duplicate["openedBy"] = {k: v for (k, v) in by_.items() if k != "kind"};
                    named_bot = self.bot(identity);
                    name = named_bot.get("name") if named_bot is not None else None;
                    if name is None {
                        name = by_.get("name");
                    }
                    duplicate["closedBy"] = {
                        "botId": identity,
                        "name": name,
                        "at": _now_ms(),
                    };
                    bots_dirty = True;
                }
            }
        }
        if bots_dirty {
            self.save_bots();
        }
    }

    # Many saves repeat what is already on disk, so both registries skip a
    # byte-identical write. Events are still emitted by callers either way.
    def save_bots(self: any, bots: any = None, register_sections: bool = True) -> None {
        if bots is None or bots is UNDEF {
            bots = self.bots;
        }
        if register_sections {
            self._remember_sections(
                [r.get("section") for r in list(self.bots) + list(bots)]
            );
        }
        rows = [];
        for b in bots {
            row = {k: v for (k, v) in b.items() if k not in ("busy", "activity")};
            tasks = b.get("tasks", UNDEF);
            if tasks is None or tasks is UNDEF {
                row.pop("tasks", None);
            } else {
                row["tasks"] = [
                    persisted_pin({
                        k: v for (k, v) in t.items()
                        if k not in ("busy", "activity", "turnStartedAt")
                    })
                    for t in tasks
                ];
            }
            rows.append(row);
        }
        write_file_atomic_if_changed(BOTS_FILE, _js_pretty(rows), mode=0o600);
    }

    def save_groups(self: any, groups: any = None, register_sections: bool = True) -> None {
        if groups is None or groups is UNDEF {
            groups = self.groups;
        }
        if register_sections {
            self._remember_sections([g.get("section") for g in groups]);
        }
        rows = [];
        for g in groups {
            row = {k: v for (k, v) in g.items() if k not in ("busyBotId", "turnStartedAt")};
            tasks = g.get("tasks", UNDEF);
            if tasks is None or tasks is UNDEF {
                row.pop("tasks", None);
            } else {
                row["tasks"] = [persisted_pin(t) for t in tasks];
            }
            rows.append(row);
        }
        write_file_atomic_if_changed(GROUPS_FILE, _js_pretty(rows), mode=0o600);
    }

    def sections(self: any) -> list[any] {
        return read_sections();
    }

    def _remember_sections(self: any, names: list[any]) -> None {
        try {
            if ensure_sections(names) {
                self._emit({"type": "sections"});
            }
        } except Exception as e {
            if not self.registering_initial_sections {
                raise;
            }
            print(
                f"[teams] Startup could not register team names; saved teams and shared instructions were left unchanged: {e}",
                file=sys.stderr
            );
        }
    }

    def rename_section(self: any, name: str, next_name: str, computers: any = None) -> (str | None) {
        # Rename the same team, preserving its members and existing access grants.
        if not name or name not in self.sections() {
            return "No such team";
        }
        next_name = _js_trim(next_name);
        if (
            not next_name or _js_len(next_name) > 60
            or any(ord(ch) < 32 or ord(ch) == 127 for ch in next_name)
        ) {
            return "Team name must be 1 to 60 characters without control characters";
        }
        if name == next_name {
            return None;
        }
        if next_name in self.sections() or _call_method(computers, "forSection", [next_name]) {
            return "A team with that name already exists";
        }
        members = [b for b in self.bots if section_key(b.get("section")) == name];
        rooms = [g for g in self.groups if section_key(g.get("section")) == name];
        affected = [
            b for b in self.bots
            if any(m is b for m in members) or any(
                section_key(s) == name for s in (b.get("managedSections") or [])
            )
        ];
        if (
            any(b.get("busy") or any(t.get("busy") for t in (b.get("tasks") or [])) for b in affected)
            or any(g.get("busyBotId") for g in rooms)
        ) {
            return "Stop this team's active work before renaming the team";
        }
        # Keep the established empty-team lifecycle: old grants are revoked
        # when an empty identity is removed, so recreating it cannot
        # restore access.
        if not members and not rooms and not _call_method(computers, "forSection", [name]) {
            return self.change_empty_section(name, next_name);
        }
        next_bots = [];
        for bot in self.bots {
            nxt = dict(bot);
            if any(m is bot for m in members) {
                nxt["section"] = next_name;
            }
            if "managedSections" in bot and bot["managedSections"] is not None {
                nxt["managedSections"] = list(dict.fromkeys(
                    next_name if section_key(s) == name else s
                    for s in bot["managedSections"]
                ));
            }
            next_bots.append(nxt);
        }
        next_groups = [
            (dict(g, section=next_name) if any(r is g for r in rooms) else g)
            for g in self.groups
        ];
        computer_changed = False;
        try {
            # Register the new name only after saving the records;
            # otherwise the registry's duplicate-name check would reject
            # this same rename.
            self.save_bots(next_bots, False);
            self.save_groups(next_groups, False);
            computer_changed = bool(_call_method(computers, "renameSection", [name, next_name]));
            _change_empty_section_file(name, next_name);
        } except Exception {
            self.save_bots(self.bots, False);
            self.save_groups(self.groups, False);
            if computer_changed {
                _call_method(computers, "renameSection", [next_name, name]);
            }
            raise;
        }
        # Preserve identities held by the schedulers and other store consumers.
        for i in range(len(next_bots)) {
            _assign(self.bots[i], next_bots[i]);
        }
        for i in range(len(next_groups)) {
            _assign(self.groups[i], next_groups[i]);
        }
        for bot in affected {
            self._emit({"type": "bot", "botId": bot["id"]});
        }
        for room in rooms {
            self._emit({"type": "group", "groupId": room["id"]});
        }
        self._emit({"type": "sections"});
        return None;
    }

    def change_empty_section(self: any, name: str, next_name: any) -> (str | None) {
        # Empty-only changes cannot merge teams or silently change
        # anybody's access.
        if name not in self.sections() {
            return "No such team";
        }
        if any(section_key(r.get("section")) == name for r in list(self.bots) + list(self.groups)) {
            return "Move all bots (including archived bots) and group chats out of this team first";
        }
        if next_name is not None and next_name != name and next_name in self.sections() {
            return "A team with that name already exists";
        }
        if next_name == name {
            return None;
        }
        revoked = [
            b for b in self.bots
            if any(section_key(s) == name for s in (b.get("managedSections") or []))
        ];
        if revoked {
            grants = {
                b["id"]: [s for s in b["managedSections"] if section_key(s) != name]
                for b in revoked
            };
            # Revoke durably before freeing the name. If the registry
            # write then fails, authority stays narrowed.
            self.save_bots([
                (dict(b, managedSections=grants[b["id"]]) if b["id"] in grants else b)
                for b in self.bots
            ]);
            for bot in revoked {
                bot["managedSections"] = grants[bot["id"]];
            }
            for bot in revoked {
                self._emit({"type": "bot", "botId": bot["id"]});
            }
        }
        _change_empty_section_file(name, next_name);
        self._emit({"type": "sections"});
        return None;
    }

    def delete_section(self: any, name: str) -> (str | None) {
        # Remove the team, keeping its bots, rooms and conversations in General.
        if not name or name not in self.sections() {
            return "No such team";
        }
        members = [b for b in self.bots if section_key(b.get("section")) == name];
        rooms = [g for g in self.groups if section_key(g.get("section")) == name];
        if (
            any(b.get("busy") or any(t.get("busy") for t in (b.get("tasks") or [])) for b in members)
            or any(g.get("busyBotId") for g in rooms)
        ) {
            return "Stop this team's active work before deleting the team";
        }
        chiefs = [
            b for b in self.bots
            if b.get("chiefOfStaff")
            and (not section_key(b.get("section")) or section_key(b.get("section")) == name)
        ];
        if len(chiefs) > 1 {
            return "General already has a Chief of Staff. Move or change this team's Chief before deleting the team";
        }
        next_bots = [];
        for bot in self.bots {
            nxt = dict(bot);
            if section_key(bot.get("section")) == name {
                nxt["section"] = UNDEF;
            }
            if "managedSections" in bot and bot["managedSections"] is not None {
                nxt["managedSections"] = [
                    s for s in bot["managedSections"] if section_key(s) != name
                ];
            }
            next_bots.append(nxt);
        }
        next_groups = [
            (dict(g, section=UNDEF) if section_key(g.get("section")) == name else g)
            for g in self.groups
        ];
        try {
            self.save_bots(next_bots);
            self.save_groups(next_groups);
            _change_empty_section_file(name, None);
        } except Exception {
            self.save_bots();
            self.save_groups();
            raise;
        }
        for i in range(len(next_bots)) {
            _assign(self.bots[i], next_bots[i]);
        }
        for i in range(len(next_groups)) {
            _assign(self.groups[i], next_groups[i]);
        }
        for bot in self.bots {
            self._emit({"type": "bot", "botId": bot["id"]});
        }
        for group in rooms {
            self._emit({"type": "group", "groupId": group["id"]});
        }
        self._emit({"type": "sections"});
        return None;
    }

    # ── subscriptions ────────────────────────────────────────────────────

    def on_change(self: any, listener: any) -> any {
        # Listeners run after the write and after save; a throwing
        # listener never breaks the write.
        if not any(l is listener for l in self.listeners) {
            self.listeners.append(listener);
        }
        def unsub {
            for i in range(len(self.listeners) - 1, -1, -1) {
                if self.listeners[i] is listener {
                    self.listeners.pop(i);
                }
            }
        }
        return unsub;
    }

    def _emit(self: any, change: dict[str, any]) -> None {
        for listener in list(self.listeners) {
            try {
                listener(change);
            } except Exception as error {
                print(f"store: change listener threw {error}", file=sys.stderr);
            }
        }
    }

    # ── groups ───────────────────────────────────────────────────────────

    def group(self: any, id: (str | None)) -> (dict[str, any] | None) {
        for g in self.groups {
            if g.get("id") == id {
                return g;
            }
        }
        return None;
    }

    def group_by_thread(self: any, thread_id: str) -> (dict[str, any] | None) {
        for group in self.groups {
            if group.get("threadId") == thread_id or any(
                t.get("threadId") == thread_id for t in (group.get("tasks") or [])
            ) {
                return group;
            }
        }
        return None;
    }

    def create_group(
        self: any,
        name: str,
        member_ids: list[any],
        dm: bool = False,
        section: any = None,
        setup: any = None
    ) -> dict[str, any] {
        self._remember_sections([section]);
        thread_id = new_id();
        created_at = _now_ms();
        group = {
            "id": new_id(),
            "threadId": thread_id,
            "name": name,
            "memberIds": member_ids,
            "defaultResponder": (
                {"kind": "mentions"}
                if dm
                else normalize_group_default_responder(
                    setup.get("defaultResponder") if isinstance(setup, dict) else None,
                    member_ids,
                    False
                )
            ),
            "bulletin": setup.get("bulletin") if isinstance(setup, dict) and setup.get("bulletin") is not None else "",
            "unread": False,
            "createdAt": created_at,
            "busyBotId": None,
            "section": section,
        };
        if dm {
            group["dm"] = True;
        }
        if not dm {
            group["tasks"] = [{"threadId": thread_id, "title": UNTITLED_TASK, "createdAt": created_at, "updatedAt": created_at}];
            group["setupCompletedAt"] = created_at if isinstance(setup, dict) and setup.get("completed") else None;
            group["setupSkippedAt"] = None;
        }
        self.groups.insert(0, group);
        self.save_groups();
        self._emit({"type": "group", "groupId": group["id"]});
        return group;
    }

    def dm_group(self: any, a: str, b: str) -> (dict[str, any] | None) {
        # The bot⇄bot channel for a pair, if it exists (order-insensitive).
        for g in self.groups {
            if (
                g.get("dm") and len(g.get("memberIds") or []) == 2
                and a in g["memberIds"] and b in g["memberIds"]
            ) {
                return g;
            }
        }
        return None;
    }

    def patch_group(self: any, id: str, patch: dict[str, any]) -> (dict[str, any] | None) {
        group = self.group(id);
        if group is None {
            return None;
        }
        if "section" in patch {
            self._remember_sections([patch["section"]]);
        }
        previous_busy_bot_id = group.get("busyBotId");
        _assign(group, patch);
        # The group's elapsed readout counts the busy member's turn from
        # the claim time — derived, never patched directly.
        if "busyBotId" in patch {
            if patch["busyBotId"] and patch["busyBotId"] != previous_busy_bot_id {
                group["turnStartedAt"] = _now_ms();
            } elif not patch["busyBotId"] {
                group.pop("turnStartedAt", None);
            }
        }
        if "turnTimeoutMinutes" in patch and patch.get("turnTimeoutMinutes") is None {
            group.pop("turnTimeoutMinutes", None);
        }
        if not group.get("dm") and "pinnedMessageId" in patch {
            active = self.active_group_task(group["id"]);
            if active is not None {
                _js_set(active, "pinnedMessageId", patch["pinnedMessageId"]);
            }
        }
        group["defaultResponder"] = normalize_group_default_responder(
            group.get("defaultResponder"),
            group.get("memberIds") if isinstance(group.get("memberIds"), list) else [],
            bool(group.get("dm"))
        );
        self.save_groups();
        self._emit({"type": "group", "groupId": group["id"]});
        return group;
    }

    def _delete_thread_record(self: any, thread_id: str) -> None {
        # A thread's durable record: DB rows, legacy JSON leftovers, and
        # the per-thread event logs. Every delete path funnels here.
        self.threads.pop(thread_id, None);
        delete_thread(thread_id);
        for file in [
            messages_file(thread_id),
            messages_file(thread_id) + ".imported",
            os.path.join(EVENTS_DIR, f"{thread_id}.ndjson"),
            os.path.join(NATIVE_DIR, f"{thread_id}.ndjson"),
        ] {
            try {
                os.unlink(file);
            } except Exception {
            }
        }
        self._emit({"type": "thread.deleted", "threadId": thread_id});
    }

    def delete_group(self: any, id: str) -> bool {
        group = self.group(id);
        if group is None {
            return False;
        }
        self.groups = [g for g in self.groups if g.get("id") != id];
        self.save_groups();
        seen: list[any] = [group.get("threadId")];
        for t in (group.get("tasks") or []) {
            seen.append(t.get("threadId"));
        }
        for thread_id in list(dict.fromkeys(seen)) {
            if isinstance(thread_id, str) {
                self._delete_thread_record(thread_id);
            }
        }
        self._emit({"type": "group.deleted", "groupId": id});
        return True;
    }

    def reconcile_interrupted_group_goals(
        self: any,
        resolve: any = None,
        fallback_detail: str = "OpenMausBot restarted before this goal finished.",
        fallback_finished_at: any = None
    ) -> int {
        # A process restart cannot preserve an in-flight room orchestrator.
        # Close every durable working receipt before clients load it.
        if fallback_finished_at is None {
            fallback_finished_at = _now_ms();
        }
        owned_thread_ids = set();
        for group in self.groups {
            owned_thread_ids.add(group.get("threadId"));
            for task in (group.get("tasks") or []) {
                owned_thread_ids.add(task.get("threadId"));
            }
        }
        recovered = 0;
        for hit in working_goal_run_messages() {
            message = hit.get("message") or {};
            goal_run = message.get("goalRun");
            if hit.get("threadId") not in owned_thread_ids or not isinstance(goal_run, dict) {
                continue;
            }
            resolution = (
                resolve(goal_run.get("runId"), hit["threadId"])
                if callable(resolve)
                else None
            );
            if resolution is None {
                resolution = {
                    "status": "failed",
                    "detail": fallback_detail,
                    "finishedAt": fallback_finished_at,
                };
            }
            status = resolution.get("status");
            state = (
                "needs your input" if status == "needs-input"
                else "reached its turn limit" if status == "limit-reached"
                else status
            );
            nxt = dict(goal_run);
            nxt["status"] = status;
            nxt["detail"] = resolution.get("detail");
            nxt["finishedAt"] = resolution.get("finishedAt");
            self.patch_message(hit["threadId"], message["id"], {
                "text": f"Goal {state}: {resolution.get('detail')}",
                "goalRun": nxt,
            });
            recovered += 1;
        }
        return recovered;
    }

    # ── channel tasks ────────────────────────────────────────────────────

    def group_tasks(self: any, group_id: str) -> list[any] {
        group = self.group(group_id);
        if group is None or group.get("dm") {
            return [];
        }
        return group.get("tasks") or [];
    }

    def active_group_task(self: any, group_id: str) -> (dict[str, any] | None) {
        group = self.group(group_id);
        if group is None {
            return None;
        }
        for task in (group.get("tasks") or []) {
            if task.get("threadId") == group.get("threadId") {
                return task;
            }
        }
        return None;
    }

    def group_task_by_thread(self: any, group_id: str, thread_id: str) -> (dict[str, any] | None) {
        group = self.group(group_id);
        if group is None or group.get("dm") {
            return None;
        }
        for task in (group.get("tasks") or []) {
            if task.get("threadId") == thread_id {
                return task;
            }
        }
        return None;
    }

    def create_group_task(self: any, group_id: str, title: (str | None) = None, activate: bool = True) -> (dict[str, any] | None) {
        group = self.group(group_id);
        if group is None or group.get("dm") {
            return None;
        }
        created_at = _now_ms();
        trimmed = _js_slice_16(_js_trim(title), 0, 80) if isinstance(title, str) else "";
        task: dict[str, any] = {
            "threadId": new_id(),
            "title": trimmed if trimmed else UNTITLED_TASK,
            "createdAt": created_at,
            "updatedAt": created_at,
        };
        group["tasks"] = [task] + list(group.get("tasks") or []);
        if activate {
            group["threadId"] = task["threadId"];
            _js_set(group, "pinnedCwd", UNDEF);
            _js_set(group, "pinnedMessageId", UNDEF);
        }
        self.save_groups();
        self._emit({"type": "group", "groupId": group_id});
        return task;
    }

    def switch_group_task(self: any, group_id: str, thread_id: str) -> (dict[str, any] | None) {
        group = self.group(group_id);
        task = None;
        if group is not None {
            for candidate in (group.get("tasks") or []) {
                if candidate.get("threadId") == thread_id {
                    task = candidate;
                    break;
                }
            }
        }
        if group is None or task is None {
            return None;
        }
        grp: any = group;
        tk: any = task;
        if grp.get("dm") {
            return None;
        }
        grp["threadId"] = tk["threadId"];
        _js_set(grp, "pinnedCwd", tk.get("pinnedCwd", UNDEF));
        _js_set(grp, "pinnedMessageId", tk.get("pinnedMessageId", UNDEF));
        self.save_groups();
        self._emit({"type": "group", "groupId": group_id});
        return group;
    }

    def set_group_task_pinned(self: any, group_id: str, thread_id: str, pinned: bool) -> (dict[str, any] | None) {
        task = self.group_task_by_thread(group_id, thread_id);
        if task is None {
            return None;
        }
        if pinned {
            task["pinned"] = True;
        } else {
            task.pop("pinned", None);
        }
        self.save_groups();
        self._emit({"type": "group", "groupId": group_id});
        return task;
    }

    def set_group_task_turn_timeout(self: any, group_id: str, thread_id: str, minutes: any) -> (dict[str, any] | None) {
        # Null removes the conversation's own ceiling so the next turn
        # uses the global group limit.
        task = self.group_task_by_thread(group_id, thread_id);
        if task is None {
            return None;
        }
        if minutes is None {
            task.pop("turnTimeoutMinutes", None);
        } else {
            task["turnTimeoutMinutes"] = minutes;
        }
        self.save_groups();
        self._emit({"type": "group", "groupId": group_id});
        return task;
    }

    def rename_group_task(self: any, group_id: str, thread_id: str, title: str) -> (dict[str, any] | None) {
        task = self.group_task_by_thread(group_id, thread_id);
        if task is None {
            return None;
        }
        trimmed = _js_slice_16(_js_trim(title), 0, 80);
        task["title"] = trimmed if trimmed else UNTITLED_TASK;
        self.save_groups();
        self._emit({"type": "group", "groupId": group_id});
        return task;
    }

    def title_group_task_from_first_message(self: any, group_id: str, text: str, thread_id: (str | None) = None) -> (dict[str, any] | None) {
        # Name a channel task after its first message, once.
        task = self.group_task_by_thread(group_id, thread_id) if thread_id is not None else self.active_group_task(group_id);
        if task is None or task.get("titleFromFirstMessage") or task.get("title") != UNTITLED_TASK {
            return None;
        }
        task["title"] = title_from_message(text);
        task["titleFromFirstMessage"] = True;
        self.save_groups();
        self._emit({"type": "group", "groupId": group_id});
        return task;
    }

    def retitle_group_task(self: any, group_id: str, thread_id: str, machine_title: str, title: str) -> (dict[str, any] | None) {
        # Swap a machine-made first-message channel title for a generated
        # one, once: any rename by the person breaks the equality first.
        task = self.group_task_by_thread(group_id, thread_id);
        if task is None or task.get("title") != machine_title {
            return None;
        }
        return self.rename_group_task(group_id, thread_id, thread_title_from(title));
    }

    def delete_group_task(self: any, group_id: str, thread_id: str) -> (dict[str, any] | None) {
        group = self.group(group_id);
        tasks = group.get("tasks") if isinstance(group, dict) else None;
        if (
            group is None or group.get("dm") or not isinstance(tasks, list)
            or len(tasks) < 2
        ) {
            return None;
        }
        if not any(t.get("threadId") == thread_id for t in tasks) {
            return None;
        }
        group["tasks"] = [t for t in tasks if t.get("threadId") != thread_id];
        self._delete_thread_record(thread_id);
        if group.get("threadId") == thread_id {
            nxt = group["tasks"][0];
            group["threadId"] = nxt["threadId"];
            _js_set(group, "pinnedCwd", nxt.get("pinnedCwd", UNDEF));
            _js_set(group, "pinnedMessageId", nxt.get("pinnedMessageId", UNDEF));
        }
        self.save_groups();
        self._emit({"type": "group", "groupId": group_id});
        return group;
    }

    def toggle_reaction(self: any, thread_id: str, message_id: str, emoji: str, `by: str) -> (dict[str, any] | None) {
        # Toggle an emoji reaction on a message ("user" or a member botId).
        existing: any = None;
        for m in self.messages_for(thread_id) {
            if m.get("id") == message_id {
                existing = m;
                break;
            }
        }
        if existing is None {
            return None;
        }
        reactions = list(existing.get("reactions") or []);
        at = -1;
        for i in range(len(reactions)) {
            r = reactions[i];
            if r.get("emoji") == emoji and r.get("by") == `by {
                at = i;
                break;
            }
        }
        if at >= 0 {
            nxt = [r for (i, r) in enumerate(reactions) if i != at];
        } else {
            nxt = reactions + [{"emoji": emoji, "by": `by}];
        }
        return self.patch_message(thread_id, message_id, {"reactions": nxt if nxt else UNDEF});
    }

    # ── threads ──────────────────────────────────────────────────────────

    def _thread(self: any, thread_id: str) -> dict[str, any] {
        t = self.threads.get(thread_id);
        if t is not None {
            return t;
        }
        # SQLite is the source of truth; a thread with no rows imports its
        # legacy messages-<threadId>.json once, inside read_thread.
        return self._cache_thread(thread_id, read_thread(thread_id, messages_file(thread_id)));
    }

    def _cache_thread(self: any, thread_id: str, rows: dict[str, any]) -> dict[str, any] {
        # Finish hydrating a full set of thread rows into the cache: chain
        # any legacy rows' parentId in array order, default the active leaf
        # to the newest message, and store it.
        messages = rows["messages"];
        active_leaf_id = rows.get("activeLeafId");
        # legacy rows carry no parentId — chain them in array order
        prev = None;
        for m in messages {
            if "parentId" not in m or m["parentId"] is UNDEF {
                m["parentId"] = prev;
            }
            prev = m.get("id");
        }
        if not active_leaf_id {
            last_id = messages[-1].get("id") if messages else UNDEF;
            active_leaf_id = last_id if last_id is not None and last_id is not UNDEF else None;
        }
        t = {"messages": messages, "activeLeafId": active_leaf_id};
        self.threads[thread_id] = t;
        return t;
    }

    def messages_for(self: any, thread_id: str) -> list[any] {
        return self._thread(thread_id)["messages"];
    }

    def messages_tail(self: any, thread_id: str, limit: int) -> dict[str, any] {
        # A bounded page of a thread's newest messages. Reads just `limit`
        # rows at the SQL boundary unless the thread is already cached or
        # the bounded read comes back as the complete thread anyway.
        state = self.threads.get(thread_id);
        if state is None {
            tail = read_thread_tail(thread_id, messages_file(thread_id), limit);
            legacy_rows = (
                "hasMore" in tail
                and any("parentId" not in m or m.get("parentId") is UNDEF for m in tail["messages"])
            );
            if tail.get("hasMore") is not True or legacy_rows {
                state = self._cache_thread(
                    thread_id,
                    read_thread(thread_id, messages_file(thread_id)) if legacy_rows else tail
                );
            } else {
                leaf = tail.get("activeLeafId");
                if leaf is None or leaf is UNDEF {
                    last_id = tail["messages"][-1].get("id") if tail["messages"] else UNDEF;
                    leaf = last_id if last_id is not None and last_id is not UNDEF else None;
                }
                return {
                    "messages": tail["messages"],
                    "hasMore": tail["hasMore"],
                    "activeLeafId": leaf,
                };
            }
        }
        messages = state["messages"];
        start = max(0, len(messages) - limit);
        return {
            "messages": messages[start:],
            "hasMore": start > 0,
            "activeLeafId": state["activeLeafId"],
        };
    }

    def import_transcript(self: any, thread_id: str, messages: list[any], active_leaf_id: (str | None)) -> None {
        # Used only with newly allocated import threads.
        if self.messages_for(thread_id) {
            raise RuntimeError("Cannot import over an existing conversation");
        }
        import_thread(thread_id, messages, active_leaf_id);
        self.threads.pop(thread_id, None);
        newest = float("-inf");
        poisoned = False;
        for message in messages {
            at = message.get("at");
            if _is_num(at) {
                newest = max(newest, at);
            } else {
                poisoned = True;
            }
        }
        if not poisoned and math.isfinite(newest) {
            self._note_thread_activity(thread_id, newest);
        }
    }

    def active_leaf(self: any, thread_id: str) -> (str | None) {
        return self._thread(thread_id)["activeLeafId"];
    }

    def active_path(self: any, thread_id: str) -> list[any] {
        # The visible conversation: root → activeLeafId.
        t = self._thread(thread_id);
        by_id = {m.get("id"): m for m in t["messages"]};
        path = [];
        cur = by_id.get(t["activeLeafId"]) if t["activeLeafId"] else None;
        while cur is not None {
            path.append(cur);
            parent = cur.get("parentId");
            cur = by_id.get(parent) if parent is not None and parent is not UNDEF else None;
        }
        path.reverse();
        return path;
    }

    def mark_terminal_assistant_message(self: any, thread_id: str, turn_id: str) -> (dict[str, any] | None) {
        # Mark the last assistant text on the active branch as this turn's
        # final visible answer.
        path = self.active_path(thread_id);
        for i in range(len(path) - 1, -1, -1) {
            message = path[i];
            if (
                message.get("role") == "bot" and message.get("kind") == "text"
                and message.get("turnId") == turn_id
            ) {
                if message.get("turnTerminal") {
                    return message;
                }
                return self.patch_message(thread_id, message["id"], {"turnTerminal": True});
            }
        }
        return None;
    }

    def append_message(self: any, thread_id: any, message: dict[str, any], command: any = None) -> dict[str, any] {
        t = self._thread(thread_id);
        full: dict[str, any] = {"id": new_id(), "at": _now_ms(), "parentId": t["activeLeafId"]};
        _assign(full, redact_bot_authored(message));
        box = {"committed": None, "applied": False};
        def persist -> any {
            append_message(thread_id, full);
            box["applied"] = True;
            return full;
        }
        if command is not None {
            committed = run_command(command, persist);
            box["committed"] = committed;
        } else {
            persist();
            committed = full;
        }
        if command is not None and committed.get("id") != full["id"] {
            return committed;
        }
        # Only publish the committed write. A failed receipt must leave
        # both the in-memory branch and subscribers unchanged.
        t["messages"].append(full);
        t["activeLeafId"] = full["id"];
        if full.get("kind") == "screen" {
            for pruned in self._prune_screen_frames(t) {
                update_message(thread_id, pruned);
                self._emit({"type": "message.patch", "threadId": thread_id, "message": pruned});
            }
        }
        self._note_thread_activity(thread_id, full["at"]);
        self._emit({"type": "message", "threadId": thread_id, "message": full});
        # The first-run quiz is not a live ask. Talking past it hides it.
        if full.get("role") == "user" and full.get("kind") == "text" {
            self.dismiss_onboarding_card(thread_id);
        }
        return full;
    }

    def insert_message_after(self: any, thread_id: str, anchor_id: (str | None), message: dict[str, any]) -> dict[str, any] {
        # Insert a message into the active chain directly after
        # `anchorId` — the home for turn artifacts that finish AFTER the
        # world moved on.
        t = self._thread(thread_id);
        anchor_exists = anchor_id is not None and any(
            m.get("id") == anchor_id for m in t["messages"]
        );
        if not anchor_exists or t["activeLeafId"] == anchor_id {
            return self.append_message(thread_id, message);
        }
        full: dict[str, any] = {"id": new_id(), "at": _now_ms()};
        _assign(full, redact_bot_authored(message));
        full["parentId"] = anchor_id;
        children = [m for m in t["messages"] if m.get("parentId") == anchor_id];
        t["messages"].append(full);
        insert_message(thread_id, full);  # the leaf stays where it was, in SQLite too
        if full.get("kind") == "screen" {
            for pruned in self._prune_screen_frames(t) {
                update_message(thread_id, pruned);
                self._emit({"type": "message.patch", "threadId": thread_id, "message": pruned});
            }
        }
        self._note_thread_activity(thread_id, full["at"]);
        self._emit({"type": "message", "threadId": thread_id, "message": full});
        # announced after the insert so no client ever sees two siblings
        # claiming the same parent
        for child in children {
            self.patch_message(thread_id, child["id"], {"parentId": full["id"]});
        }
        return full;
    }

    def dismiss_onboarding_card(self: any, thread_id: str) -> (dict[str, any] | None) {
        # Hide the first-run quiz on this thread, if it is still open.
        t = self._thread(thread_id);
        card: any = None;
        for message in t["messages"] {
            mc = message.get("card");
            if (
                message.get("kind") == "options" and isinstance(mc, dict)
                and not mc.get("requestId") and not mc.get("dismissed")
            ) {
                card = message;
                break;
            }
        }
        if card is None or not isinstance(card.get("card"), dict) {
            return None;
        }
        nxt_card = dict(card["card"]);
        nxt_card["dismissed"] = True;
        return self.patch_message(thread_id, card["id"], {"card": nxt_card});
    }

    def _prune_screen_frames(self: any, t: dict[str, any], keep: int = 4) -> list[any] {
        # Screen frames are ~100-500KB of base64 each; the newest few keep
        # their pixels, older ones stay as placeholders. Returns the
        # messages whose pixels were dropped.
        pruned = [];
        seen = 0;
        messages = t["messages"];
        i = len(messages) - 1;
        while i >= 0 and seen < len(messages) {
            m = messages[i];
            i -= 1;
            if m.get("kind") != "screen" or not m.get("png") {
                continue;
            }
            seen += 1;
            if seen > keep {
                m["png"] = UNDEF;
                pruned.append(m);
            }
        }
        return pruned;
    }

    def branch_message(self: any, thread_id: str, source_id: str, text: str, send_id: (str | None) = None, sender: any = None) -> (dict[str, any] | None) {
        # Fork the conversation: a new user message that replaces
        # `sourceId` (same parent, new text) and becomes the active leaf.
        t = self._thread(thread_id);
        source: any = None;
        for m in t["messages"] {
            if m.get("id") == source_id {
                source = m;
                break;
            }
        }
        if source is None {
            return None;
        }
        full: dict[str, any] = {
            "id": new_id(),
            "at": _now_ms(),
            "role": "user",
            "kind": "text",
            "text": text,
            "parentId": source["parentId"] if source.get("parentId") is not None else None,
        };
        _js_set(full, "replyToId", source.get("replyToId", UNDEF));
        if send_id {
            full["sendId"] = send_id;
        }
        if sender is not None {
            full["sender"] = sender;
        }
        t["messages"].append(full);
        t["activeLeafId"] = full["id"];
        append_message(thread_id, full);
        self._note_thread_activity(thread_id, full["at"]);
        self._emit({"type": "message", "threadId": thread_id, "message": full});
        # The message frame alone leaves every client on the OLD branch:
        # say where the conversation now points, as setActiveLeaf does.
        self._emit({"type": "thread", "threadId": thread_id, "activeLeafId": full["id"]});
        return full;
    }

    def set_active_leaf(self: any, thread_id: str, message_id: str) -> (str | None) {
        # Point the visible conversation at the branch containing
        # `messageId`, descending to that branch's most recently active leaf.
        t = self._thread(thread_id);
        if not any(m.get("id") == message_id for m in t["messages"]) {
            return None;
        }
        cur = message_id;
        while True {
            children = [m for m in t["messages"] if m.get("parentId") == cur];
            if not children {
                break;
            }
            best = children[0];
            for c in children[1:] {
                if c.get("at") >= best.get("at") {
                    best = c;
                }
            }
            cur = best["id"];
        }
        t["activeLeafId"] = cur;
        set_active_leaf(thread_id, cur);
        self._emit({"type": "thread", "threadId": thread_id, "activeLeafId": cur});
        return cur;
    }

    def patch_message(self: any, thread_id: str, message_id: str, patch: dict[str, any], command: any = None) -> (dict[str, any] | None) {
        t = self._thread(thread_id);
        idx = -1;
        for i in range(len(t["messages"])) {
            if t["messages"][i].get("id") == message_id {
                idx = i;
                break;
            }
        }
        if idx == -1 {
            return None;
        }
        old = t["messages"][idx];
        nxt = dict(old);
        for (k, v) in patch.items() {
            if k == "card" {
                continue;
            }
            nxt[k] = v;
        }
        card = patch.get("card");
        if card is None or card is UNDEF {
            card = old.get("card");
        }
        if "card" in old or "card" in patch {
            nxt["card"] = card;
        }
        # SQLite is the durable source of truth. Persist before changing
        # memory so a failed write cannot make this process believe a card
        # was answered while a restart would still show it as pending.
        box = {"applied": False};
        def persist -> any {
            update_message(thread_id, nxt);
            box["applied"] = True;
            return nxt;
        }
        if command is not None {
            committed = run_command(command, persist);
        } else {
            committed = persist();
        }
        if not box["applied"] {
            return committed;
        }
        t["messages"][idx] = nxt;
        self._emit({"type": "message.patch", "threadId": thread_id, "message": nxt});
        return nxt;
    }

    # ── bots ─────────────────────────────────────────────────────────────

    def bot(self: any, id: any) -> (dict[str, any] | None) {
        for b in self.bots {
            if b.get("id") == id {
                return b;
            }
        }
        return None;
    }

    def bot_by_thread(self: any, thread_id: str) -> (dict[str, any] | None) {
        for b in self.bots {
            if b.get("threadId") == thread_id or any(
                t.get("threadId") == thread_id for t in (b.get("tasks") or [])
            ) {
                return b;
            }
        }
        return None;
    }

    def _new_bot_selection(self: any, requested: any = None) -> any {
        # The one place a new bot's selection is decided: the caller's
        # choice, or the workspace default, completed with the workspace's
        # new-bot defaults.
        sel = requested if requested is not None and requested is not UNDEF else self.default_selection();
        return self.complete_new_bot_selection(sel);
    }

    def create_bot(self: any, profile: any = None, opts: any = None) -> dict[str, any] {
        if profile is None {
            profile = {};
        }
        if opts is None {
            opts = {};
        }
        tool_scope = parse_tool_scope(profile.get("toolScope", UNDEF));
        if not tool_scope["ok"] {
            raise RuntimeError(tool_scope["error"]);
        }
        self._remember_sections([profile.get("section")]);
        name = (
            _js_trim(profile["name"])
            if isinstance(profile.get("name"), str) and _js_trim(profile["name"])
            else pick_bot_name([b.get("name") for b in self.bots])
        );
        section = section_key(profile.get("section"));
        bot: dict[str, any] = {
            "id": new_id(),
            "threadId": new_id(),
            "name": name,
            "title": profile.get("title") if profile.get("title") is not None else "",
            "description": profile.get("description") if profile.get("description") is not None else "",
            "soul": profile.get("soul") if profile.get("soul") is not None else "",
            "soulHash": soul_hash(profile.get("soul") if profile.get("soul") is not None else ""),
            "notifications": True,
            "color": profile.get("color") if profile.get("color") is not None else COLORS[len(self.bots) % len(COLORS)],
        };
        if profile.get("mascotExpression") {
            bot["mascotExpression"] = profile["mascotExpression"];
        }
        if profile.get("mascotBody") {
            bot["mascotBody"] = profile["mascotBody"];
        }
        # Restricted from its first frame: no one else is ever told it exists.
        if profile.get("visibility") and profile["visibility"] != "everyone" {
            bot["visibility"] = deepcopy(profile["visibility"]);
        }
        scope = tool_scope["scope"];
        if scope is not None and scope is not UNDEF {
            bot["toolScope"] = scope;
        }
        bot["unread"] = False;
        bot["modelSelection"] = self._new_bot_selection(profile.get("modelSelection"));
        bot["resumeCursors"] = {};
        bot["createdAt"] = _now_ms();
        if section {
            bot["section"] = section;
        }
        if profile.get("cwd") {
            bot["cwd"] = profile["cwd"];
        }
        bot["tasks"] = [{
            "threadId": bot["threadId"],
            "title": UNTITLED_THREAD,
            "createdAt": bot["createdAt"],
            "updatedAt": bot["createdAt"],
            "resumeCursors": {},
            "unread": False,
            "activity": "idle",
            "busy": False,
        }];
        # Persist the selection in the first record, before publishing the
        # bot or starting its greeting. An interrupted creation cannot
        # inherit tools.
        self.save_bots([bot] + list(self.bots));
        self.bots.insert(0, bot);
        _wire_bot_threads(bot);
        # The folder exists from the first moment, so the user can open
        # SOUL.md before the bot has said a word. The record is canonical.
        try {
            write_soul_mirror(bot["id"], _nn(bot.get("soul"), ""));
        } except Exception as e {
            print(f"[bot-folder] could not write SOUL.md mirror for {bot['id']}: {e}", file=sys.stderr);
        }
        # Announce the owner before its onboarding transcript. SSE clients
        # need the bot/thread mapping before they can place either message.
        self._emit({"type": "bot", "botId": bot["id"]});
        # Keep the greeting valid for configured bots and every engine.
        if opts.get("seedMessages") is not False {
            self.append_message(str(bot["threadId"]), {
                "role": "bot",
                "kind": "text",
                "text": f"Hi, I'm {name}. What would you like me to do?",
            });
        }
        return bot;
    }

    def apply_team_setup(self: any, request: dict[str, any]) -> dict[str, any] {
        # All setup fields and the Chief's receipt commit before publishing
        # any mutation. A new model moves the threads that follow the bot,
        # never a thread's own model.
        chief = self.bot(request["botId"]);
        if chief is None {
            raise RuntimeError("The requesting Chief no longer exists");
        }
        receipt = chief.get("lastTeamSetupReceipt");
        if isinstance(receipt, dict) and receipt.get("requestId") == request.get("requestId") {
            return receipt["result"];
        }
        managed_sections = list(dict.fromkeys(
            list(chief.get("managedSections") or []) + list(request.get("newTeams") or [])
        ));
        if (
            len(managed_sections) > 100
            or any(_js_trim(n) != n or _js_len(n) > 60 for n in managed_sections)
            or any(not n for n in (request.get("newTeams") or []))
            or ((request.get("newTeams") or []) and not chief.get("chiefOfStaff"))
        ) {
            raise RuntimeError("Invalid reviewed Chief team scope");
        }
        next_bots = list(self.bots);
        changed = [];
        for operation in request.get("operations") or [] {
            at = -1;
            for i in range(len(next_bots)) {
                if next_bots[i].get("id") == operation.get("botId") {
                    at = i;
                    break;
                }
            }
            fields = operation.get("fields") or {};
            if operation.get("action") == "create" {
                if at >= 0 or not operation.get("threadId") or not fields.get("name") or not fields.get("modelSelection") {
                    raise RuntimeError("Invalid new bot in team setup");
                }
                created_at = _now_ms();
                model_selection = self._new_bot_selection(fields.get("modelSelection"));
                nxt = {
                    "id": operation["botId"],
                    "threadId": operation["threadId"],
                    "name": fields["name"],
                    "title": "",
                    "description": "",
                    "soul": "",
                    "notifications": True,
                    "color": COLORS[len(next_bots) % len(COLORS)],
                    "unread": False,
                    "resumeCursors": {},
                    "createdAt": created_at,
                };
                _assign(nxt, fields);
                nxt["modelSelection"] = model_selection;
                nxt["approvalMode"] = "ask";
                nxt["autoApprove"] = False;
                nxt["composio"] = False;
                nxt["approvePeerComms"] = False;
                # A Chief's new teammate is seen by exactly the Chief's
                # audience.
                cv = chief.get("visibility", UNDEF);
                if not _js_falsy(cv) and cv != "everyone" {
                    nxt["visibility"] = deepcopy(cv);
                }
                nxt["tasks"] = [{
                    "threadId": operation["threadId"],
                    "title": UNTITLED_THREAD,
                    "createdAt": created_at,
                    "updatedAt": created_at,
                    "resumeCursors": {},
                    "approvalMode": "ask",
                    "autoApprove": False,
                    "unread": False,
                    "activity": "idle",
                    "busy": False,
                }];
                # "" is the private-workspace spelling on proposal; the
                # record stays clean with the field absent.
                if _js_falsy(nxt.get("cwd", UNDEF)) {
                    nxt.pop("cwd", None);
                }
                next_bots.insert(0, nxt);
            } else {
                if at < 0 {
                    raise RuntimeError("A setup target no longer exists");
                }
                previous = next_bots[at];
                nxt = dict(previous);
                _assign(nxt, fields);
                if not _js_falsy(fields.get("modelSelection", UNDEF)) {
                    nxt["tasks"] = self._with_default_model(previous, fields["modelSelection"]);
                }
                next_bots[at] = nxt;
            }
            if fields.get("chiefOfStaff") is False {
                nxt.pop("managedSections", None);
            }
            sk = section_key(nxt.get("section"));
            _js_set(nxt, "section", sk if sk else UNDEF);
            if "soul" in fields and fields["soul"] is not UNDEF {
                nxt["soulHash"] = soul_hash(fields["soul"]);
                nxt["soulDrift"] = False;
            }
            changed.append(nxt);
        }
        result = {
            "state": "applied",
            "newTeams": request.get("newTeams"),
            "bots": [
                {
                    "id": b["id"],
                    "name": b.get("name"),
                    "section": b.get("section", UNDEF),
                    "modelSelection": deepcopy(b.get("modelSelection")),
                    "chiefOfStaff": bool(b.get("chiefOfStaff")),
                    "action": "created" if request["operations"][i].get("action") == "create" else "updated",
                }
                for (i, b) in enumerate(changed)
            ],
        };
        chief_at = -1;
        for i in range(len(next_bots)) {
            if next_bots[i].get("id") == chief["id"] {
                chief_at = i;
                break;
            }
        }
        next_chief = dict(next_bots[chief_at]);
        next_chief["lastTeamSetupReceipt"] = {
            "requestId": request["requestId"],
            "result": result,
        };
        # Only the newly-created teams explicitly named in the human
        # review may extend this Chief's reach.
        if (request.get("newTeams") or []) and next_chief.get("chiefOfStaff") {
            next_chief["managedSections"] = managed_sections;
        }
        next_bots[chief_at] = next_chief;
        self.save_bots(next_bots);
        self.bots = next_bots;
        for bot in changed {
            try {
                write_soul_mirror(bot["id"], bot.get("soul") or "");
            } except Exception as error {
                print(
                    f"[bot-folder] could not refresh reviewed setup mirror for {bot['id']}: {error}",
                    file=sys.stderr
                );
            }
            self._emit({"type": "bot", "botId": bot["id"]});
        }
        self._emit({"type": "bot", "botId": chief["id"]});
        return result;
    }

    def _switch_needs_ask(self: any, bot_id: str, thread_id: str, from_sel: dict[str, any], to_sel: dict[str, any]) -> bool {
        # Moving this thread from one model to another takes its level
        # back to Ask where the new engine would have to confirm it.
        if _js_strict_eq(from_sel.get("instanceId"), to_sel.get("instanceId")) {
            return False;
        }
        thread = self.project_bot_for_task(bot_id, thread_id);
        return thread is not None and model_switch_needs_ask(
            approval_mode_for(thread),
            self.driver_kind_of(from_sel.get("instanceId")),
            self.driver_kind_of(to_sel.get("instanceId"))
        );
    }

    def _with_default_model(self: any, bot: dict[str, any], nxt: dict[str, any]) -> (list[any] | None) {
        # A bot's threads as a change of its model to `nxt` leaves them.
        tasks = bot.get("tasks");
        if not isinstance(tasks, list) {
            return None;
        }
        out = [];
        for task in tasks {
            merged = dict(task);
            merged["approvalMode"] = approval_mode_for(self.project_bot_for_task(bot["id"], task["threadId"]));
            aa = task.get("autoApprove");
            if aa is None or aa is UNDEF {
                aa = bot.get("autoApprove", UNDEF);
            }
            _js_set(merged, "autoApprove", aa);
            al = task.get("alwaysAllow");
            if al is None or al is UNDEF {
                al = _nn(bot.get("alwaysAllow", UNDEF), []);
            }
            _js_set(merged, "alwaysAllow", deepcopy(al));
            if not _has(task, "modelSelection") and self._switch_needs_ask(bot["id"], task["threadId"], bot["modelSelection"], nxt) {
                _assign(merged, deepcopy(ASK_NOW));
            }
            out.append(merged);
        }
        return out;
    }

    def apply_model_default(self: any, id: str, model_selection: dict[str, any]) -> (dict[str, any] | None) {
        # One reviewed default-model change (propose_model): every thread
        # that follows the bot moves to the new model.
        previous = self.bot(id);
        if previous is None {
            return None;
        }
        nxt = dict(previous);
        nxt["modelSelection"] = deepcopy(model_selection);
        _js_set(nxt, "tasks", self._with_default_model(previous, model_selection));
        self.save_bots([nxt if c is previous else c for c in self.bots]);
        self.bots = [nxt if c is previous else c for c in self.bots];
        self._emit({"type": "bot", "botId": id});
        return nxt;
    }

    def delete_bot(self: any, id: str, setup_request: any = None) -> bool {
        bot = self.bot(id);
        if bot is None {
            return False;
        }
        next_bots = [b for b in self.bots if b.get("id") != id];
        if setup_request is not None {
            chief = self.bot(setup_request.get("botId"));
            deletion = setup_request.get("deletion") if isinstance(setup_request.get("deletion"), dict) else None;
            if (
                chief is None or chief["id"] == id
                or (deletion or {}).get("botId") != id
            ) {
                raise RuntimeError("The reviewed deletion no longer has a valid owner");
            }
            receipt = {
                "requestId": setup_request.get("requestId"),
                "result": {
                    "state": "applied",
                    "newTeams": [],
                    "bots": [{
                        "id": bot["id"],
                        "name": bot.get("name"),
                        "action": "deleted",
                    }],
                },
            };
            replaced = [];
            for candidate in next_bots {
                if candidate.get("id") == chief["id"] {
                    nxt = dict(candidate);
                    nxt["lastTeamSetupReceipt"] = receipt;
                    replaced.append(nxt);
                } else {
                    replaced.append(candidate);
                }
            }
            next_bots = replaced;
        }
        # Persist removal and the review receipt before deleting
        # conversation or workspace data.
        self.save_bots(next_bots);
        self.bots = next_bots;
        self.legacy_activities.pop(id, None);
        # A deleted bot leaves every room it was in, and a room it led
        # falls back to its next member. Bot-to-bot channels keep their pair.
        rooms = [
            g for g in self.groups
            if not g.get("dm") and id in (g.get("memberIds") or [])
        ];
        for g in rooms {
            g["memberIds"] = [m for m in g["memberIds"] if m != id];
            if g.get("busyBotId") == id {
                g["busyBotId"] = None;
                g.pop("turnStartedAt", None);
            }
            g["defaultResponder"] = normalize_group_default_responder(
                g.get("defaultResponder"), g["memberIds"], False
            );
        }
        if rooms {
            # Bot removal is already durable. Finish erasing its data even
            # if this write fails; startup repair removes stale memberships.
            try {
                self.save_groups();
            } except Exception as error {
                print(f"store: room cleanup will retry on restart {error}", file=sys.stderr);
            }
        }
        # every task's transcript goes with the bot, not just the open one
        seen: list[any] = [bot.get("threadId")];
        for t in (bot.get("tasks") or []) {
            seen.append(t.get("threadId"));
        }
        for thread_id in list(dict.fromkeys(seen)) {
            if isinstance(thread_id, str) {
                self._delete_thread_record(thread_id);
            }
        }
        # the bot's workspace (files + memory) goes with it
        try {
            shutil.rmtree(workspace_dir(id), ignore_errors=True);
        } except Exception {
        }
        # Approval state deliberately lives outside the bot-writable
        # workspace; it still belongs to the bot.
        try {
            shutil.rmtree(os.path.join(DATA_DIR, "skill-state", id), ignore_errors=True);
        } except Exception {
        }
        remove_bot_folder(id);
        _unwire_bot_threads(id);
        self._emit({"type": "bot.deleted", "botId": id});
        for g in rooms {
            self._emit({"type": "group", "groupId": g["id"]});
        }
        return True;
    }

    def patch_bot(self: any, id: str, patch: dict[str, any]) -> (dict[str, any] | None) {
        bot = self.bot(id);
        if bot is None {
            return None;
        }
        # Grants are the one field whose shape every writer must share, so
        # the store normalizes them itself.
        if patch.get("connectorTools", UNDEF) is not UNDEF {
            parsed = parse_connector_tools(patch["connectorTools"]);
            if not parsed["ok"] {
                raise RuntimeError(parsed["error"]);
            }
            patch = dict(patch);
            patch["connectorTools"] = parsed["grants"];
        }
        if "toolScope" in patch {
            parsed = parse_tool_scope(patch["toolScope"]);
            if not parsed["ok"] {
                raise RuntimeError(parsed["error"]);
            }
            patch = dict(patch);
            patch["toolScope"] = parsed["scope"];
        }
        widening_tool_scope = "toolScope" in patch and tool_scope_widens(bot.get("toolScope"), patch["toolScope"]);
        next_tool_scope = patch.get("toolScope");
        if widening_tool_scope {
            patch = dict(patch);
            del patch["toolScope"];
        }
        # A new model moves the threads that follow the bot; one whose
        # level the new engine would have to confirm goes back to Ask.
        to_ask = [];
        if not _js_falsy(patch.get("modelSelection", UNDEF)) {
            for task in (bot.get("tasks") or []) {
                if "modelSelection" not in task and self._switch_needs_ask(id, task["threadId"], bot["modelSelection"], patch["modelSelection"]) {
                    to_ask.append(task);
                }
            }
        }
        # Runtime revocations must become effective in memory even when
        # disk is unavailable.
        _assign(bot, patch);
        for task in to_ask {
            _assign(task, deepcopy(ASK_NOW));
        }
        task = self.active_task(id);
        if task is not None {
            for key in ("resumeCursors", "rewound", "pinnedMessageId", "unread") {
                if key in patch {
                    _js_set(task, key, deepcopy(patch[key]));
                }
            }
            bot["unread"] = any(task_counts_as_bot_unread(t) for t in bot["tasks"]);
        }
        if widening_tool_scope {
            # New authority becomes live only after its durable save succeeds.
            saved = [];
            for candidate in self.bots {
                if candidate is bot {
                    nb = dict(bot);
                    _js_set(nb, "toolScope", next_tool_scope);
                    saved.append(nb);
                } else {
                    saved.append(candidate);
                }
            }
            self.save_bots(saved);
            _js_set(bot, "toolScope", next_tool_scope);
        } else {
            self.save_bots();
        }
        self._emit({"type": "bot", "botId": id});
        return bot;
    }

    def clear_voice_selections(self: any) -> list[any] {
        # Voice ids belong to one provider's catalog. Changing the
        # workspace provider invalidates every per-agent selection as one
        # durable mutation.
        changed = [
            b for b in self.bots
            if "voice" in b and b["voice"] is not UNDEF and b["voice"] != ""
        ];
        if not changed {
            return [];
        }
        next_bots = [];
        for bot in self.bots {
            if "voice" not in bot or bot["voice"] is UNDEF or bot["voice"] == "" {
                next_bots.append(bot);
            } else {
                nxt = dict(bot);
                nxt["voice"] = UNDEF;
                next_bots.append(nxt);
            }
        }
        self.save_bots(next_bots);
        for bot in changed {
            bot.pop("voice", None);
            self._emit({"type": "bot", "botId": bot["id"]});
        }
        return changed;
    }

    def patch_bot_profile(self: any, id: str, patch: dict[str, any]) -> (dict[str, any] | None) {
        # Commit a validated profile change before publishing its fields.
        # Unlike runtime revocation, a failed user edit must leave the old
        # profile intact.
        bot = self.bot(id);
        if bot is None {
            return None;
        }
        nxt = dict(bot);
        _assign(nxt, patch);
        if "soul" in patch and patch["soul"] is not UNDEF {
            nxt["soulHash"] = soul_hash(patch["soul"]);
            nxt["soulDrift"] = False;
        }
        # Persist all fields together before publishing anything to the
        # live record.
        saved = [nxt if c.get("id") == id else c for c in self.bots];
        self.save_bots(saved);
        _assign(bot, nxt);
        if "soul" in patch and patch["soul"] is not UNDEF {
            try {
                write_soul_mirror(id, patch["soul"]);
            } except Exception as e {
                print(f"[bot-folder] could not write SOUL.md mirror for {id}: {e}", file=sys.stderr);
            }
        }
        self._emit({"type": "bot", "botId": id});
        return bot;
    }

    def set_soul(self: any, id: str, soul: str) -> (dict[str, any] | None) {
        # The record is canonical; a failed mirror write is reported in
        # logs and can be retried by discarding drift.
        return self.patch_bot_profile(id, {"soul": soul});
    }

    def set_bots_section(self: any, bot_ids: list[any], section: str) -> dict[str, any] {
        # File visible bots into one sidebar section as a single durable
        # write.
        ids = list(dict.fromkeys(bot_ids));
        targets = [self.bot(i) for i in ids];
        if any(b is None or b.get("hidden") for b in targets) {
            return {"ok": False, "reason": "unavailable"};
        }
        target_section = section_key(section);
        destination_chief_ids = set(
            b["id"] for b in targets if isinstance(b, dict) and b.get("chiefOfStaff")
        ) | set(
            b["id"] for b in self.bots
            if b.get("chiefOfStaff") and section_key(b.get("section")) == target_section
        );
        if len(destination_chief_ids) > 1 {
            return {"ok": False, "reason": "chief-conflict"};
        }
        patches = {b["id"]: {"section": target_section if target_section else UNDEF} for b in targets};
        changed_ids = set();
        next_bots = [];
        for bot in self.bots {
            p = patches.get(bot.get("id"));
            if p is None {
                next_bots.append(bot);
                continue;
            }
            nxt = dict(bot);
            _assign(nxt, p);
            if js_stringify(nxt) != js_stringify(bot) {
                changed_ids.add(bot["id"]);
            }
            next_bots.append(nxt);
        }
        if changed_ids {
            self.save_bots(next_bots);
            for bot in self.bots {
                p = patches.get(bot.get("id"));
                if p is not None {
                    _assign(bot, p);
                }
            }
            for bot_id in changed_ids {
                self._emit({"type": "bot", "botId": bot_id});
            }
        }
        self._remember_sections([target_section]);
        return {"ok": True, "bots": [self.bot(i) for i in ids]};
    }

    def update_team_members(self: any, section: str, add_ids: list[any], remove_ids: list[any]) -> dict[str, any] {
        # Apply only the membership edits the user made, in one bots-file write.
        key = section_key(section);
        if not key or key not in self.sections() {
            return {"ok": False, "reason": "unavailable"};
        }
        adds = set(add_ids);
        removes = set(remove_ids);
        ids = adds | removes;
        for bid in ids {
            bot = self.bot(bid);
            if bot is None or bot.get("hidden") {
                return {"ok": False, "reason": "unavailable"};
            }
            if bid in adds and bid in removes {
                return {"ok": False, "reason": "membership-changed"};
            }
            if bid in removes and section_key(bot.get("section")) != key {
                return {"ok": False, "reason": "membership-changed"};
            }
        }
        next_bots = [];
        for bot in self.bots {
            if bot.get("id") in ids {
                nxt = dict(bot);
                _js_set(nxt, "section", key if bot["id"] in adds else UNDEF);
                next_bots.append(nxt);
            } else {
                next_bots.append(bot);
            }
        }
        for destination in (key, "") {
            if len([
                b for b in next_bots
                if b.get("chiefOfStaff") and section_key(b.get("section")) == destination
            ]) > 1 {
                return {"ok": False, "reason": "chief-conflict"};
            }
        }
        if ids {
            self.save_bots(next_bots);
            for i in range(len(next_bots)) {
                if next_bots[i].get("id") in ids {
                    _assign(self.bots[i], next_bots[i]);
                }
            }
            for bot_id in ids {
                self._emit({"type": "bot", "botId": bot_id});
            }
        }
        return {"ok": True, "bots": [b for b in self.bots if b.get("id") in ids]};
    }

    def set_activity(self: any, bot_id: str, activity: str) -> (dict[str, any] | None) {
        # Legacy bot/room activity occupies its own slot; direct
        # conversations use set_task_activity.
        bot = self.bot(bot_id);
        if bot is None {
            return None;
        }
        if _nn(self.legacy_activities.get(bot_id), "idle") == activity {
            return bot;
        }
        self.legacy_activities[bot_id] = activity;
        self._refresh_bot_activity(bot);
        self._emit({"type": "bot", "botId": bot_id});
        return bot;
    }

    def set_task_activity(self: any, bot_id: str, thread_id: str, activity: str) -> (dict[str, any] | None) {
        bot = self.bot(bot_id);
        task = self.task_by_thread(bot_id, thread_id);
        if bot is None or task is None {
            return None;
        }
        busy = activity in ACTIVITY_BUSY;
        if _nn(task.get("activity"), "idle") == activity and bool(task.get("busy")) == busy {
            return bot;
        }
        was_busy = bool(task.get("busy"));
        task["activity"] = activity;
        task["busy"] = busy;
        if busy and not was_busy {
            task["turnStartedAt"] = _now_ms();
        } elif not busy {
            task.pop("turnStartedAt", None);
        }
        # Reaching here means the thread just did something — exactly the
        # "activity" an until-activity snooze waits for.
        if _is_num(task.get("snoozedUntil")) and task["snoozedUntil"] == 0 {
            _js_set(task, "snoozedUntil", UNDEF);
            self.save_bots();
        }
        self._refresh_bot_activity(bot);
        self._emit({"type": "bot", "botId": bot_id});
        return bot;
    }

    def _refresh_bot_activity(self: any, bot: dict[str, any]) -> None {
        activities = [self.legacy_activities.get(bot["id"])] + [
            t.get("activity") for t in (bot.get("tasks") or [])
        ];
        chosen = "idle";
        for candidate in ("waiting-on-you", "no-signal", "working", "dead") {
            if candidate in activities {
                chosen = candidate;
                break;
            }
        }
        bot["activity"] = chosen;
        bot["busy"] = chosen in ACTIVITY_BUSY;
    }

    def set_chief_of_staff(self: any, id: (str | None), section: any = None) -> (list[any] | None) {
        # Elect one Chief of Staff in its section (or clear one section)
        # as one persisted change.
        selected = self.bot(id) if id else None;
        if id and selected is None {
            return None;
        }
        base = selected.get("section") if selected is not None else section;
        target_section = section_key(base);
        changed = [];
        for bot in self.bots {
            if section_key(bot.get("section")) != target_section {
                continue;
            }
            nxt = bot.get("id") == id;
            if bool(bot.get("chiefOfStaff")) == nxt and not (nxt and bot.get("hidden")) {
                continue;
            }
            if nxt {
                bot["chiefOfStaff"] = True;
                # A section's main contact must stay reachable in the sidebar.
                bot["hidden"] = False;
            } else {
                bot["chiefOfStaff"] = False;
                bot.pop("managedSections", None);
            }
            changed.append(bot);
        }
        if changed {
            self.save_bots();
        }
        for bot in changed {
            self._emit({"type": "bot", "botId": bot["id"]});
        }
        return changed;
    }

    def rename_instances(self: any, ids: dict[str, any]) -> int {
        # Moves every saved reference to an old id onto its replacement in
        # one save: model choices, native resume cursors and
        # handed-message records.
        def touches(record: any) -> bool {
            return isinstance(record, dict) and any(k in ids for k in record.keys());
        }
        def rename(record: dict[str, any]) -> dict[str, any] {
            nxt = {};
            for (key, value) in record.items() {
                target = ids.get(key);
                if target is None {
                    nxt[key] = value;
                } elif target not in record {
                    nxt[target] = value;
                }
            }
            return nxt;
        }
        changed = [];
        for bot in self.bots {
            dirty = False;
            ms = bot.get("modelSelection");
            if isinstance(ms, dict) {
                selected = ids.get(ms["instanceId"]);
                if selected is not None {
                    nxt = dict(ms);
                    nxt["instanceId"] = selected;
                    bot["modelSelection"] = nxt;
                    dirty = True;
                }
            }
            if touches(bot.get("resumeCursors")) {
                bot["resumeCursors"] = rename(bot["resumeCursors"]);
                dirty = True;
            }
            for task in (bot.get("tasks") or []) {
                tms = task.get("modelSelection");
                if isinstance(tms, dict) {
                    task_selected = ids.get(tms["instanceId"]);
                    if task_selected is not None {
                        nxt = dict(tms);
                        nxt["instanceId"] = task_selected;
                        task["modelSelection"] = nxt;
                        dirty = True;
                    }
                }
                if touches(task.get("resumeCursors")) {
                    task["resumeCursors"] = rename(task["resumeCursors"]);
                    dirty = True;
                }
                if isinstance(task.get("handedMessages"), dict) and touches(task["handedMessages"]) {
                    task["handedMessages"] = rename(task["handedMessages"]);
                    dirty = True;
                }
                last = task.get("lastInstanceId");
                if last is not None and last is not UNDEF and last in ids {
                    task["lastInstanceId"] = ids[last];
                    dirty = True;
                }
            }
            if dirty {
                changed.append(bot);
            }
        }
        if changed {
            self.save_bots();
        }
        for bot in changed {
            self._emit({"type": "bot", "botId": bot["id"]});
        }
        return len(changed);
    }

    def retire_instances(self: any, ids: any, replacement: dict[str, any], options: dict[str, any]) -> list[any] {
        # The removed Computer engine's saved choices move to `replacement`
        # in one save. Nothing changes in memory until the save succeeds.
        id_set = set(ids.keys()) if isinstance(ids, dict) else set(ids);
        def retired(selection: any) -> bool {
            return isinstance(selection, dict) and selection.get("instanceId") in id_set;
        }
        def without(record: dict[str, any]) -> dict[str, any] {
            return {k: v for (k, v) in record.items() if k not in id_set};
        }
        def touches(record: any) -> bool {
            return isinstance(record, dict) and any(k in id_set for k in record.keys());
        }
        def needs_ask(target: dict[str, any]) -> bool {
            return model_switch_needs_ask(
                approval_mode_for(target), REMOVED_COMPUTER_DRIVER, options.get("driverKind")
            );
        }
        ask_now = {"approvalMode": "ask", "autoApprove": False, "alwaysAllow": []};
        changes = [];
        moves = [];
        can_work_on_cloud = options.get("canWorkOnCloud");
        keep_cloud = options.get("keepCloud");
        for bot in self.bots {
            patch: dict[str, any] = {};
            bot_tasks = bot.get("tasks") if isinstance(bot.get("tasks"), list) else [];
            task_patches = [{} for _ in bot_tasks];
            bot_moved = retired(bot.get("modelSelection"));
            keeps_cloud = bool(can_work_on_cloud) and bool(
                keep_cloud(bot) if callable(keep_cloud) else False
            );
            bot_ask = False;
            if bot_moved {
                if not _has(bot, "computer") and keeps_cloud {
                    patch["computer"] = "cloud";
                }
                if needs_ask(bot) {
                    _assign(patch, deepcopy(ask_now));
                    bot_ask = True;
                }
                patch["modelSelection"] = deepcopy(replacement);
            }
            if isinstance(bot.get("fallback"), list) and any(retired(f) for f in bot["fallback"]) {
                kept = [c for c in bot["fallback"] if not retired(c)];
                _js_set(patch, "fallback", kept if kept else UNDEF);
            }
            if touches(bot.get("resumeCursors")) {
                patch["resumeCursors"] = without(bot["resumeCursors"]);
            }
            computer = patch.get("computer", UNDEF);
            if computer is UNDEF or computer is None {
                computer = bot.get("computer", UNDEF);
            }
            def cloud_after_move(pin: any, pin_source: any) -> dict[str, any] {
                place = pin if pin is not UNDEF and pin is not None else bot.get("computer", UNDEF);
                was_cloud = (
                    place == "cloud"
                    or (place is UNDEF and bool(keep_cloud(bot) if callable(keep_cloud) else False))
                );
                if not was_cloud or can_work_on_cloud {
                    return {"cloud": was_cloud, "noComputer": False};
                }
                person_pin = pin is not UNDEF and pin is not None and pin_source != "auto";
                still = pin if person_pin else bot.get("computer", UNDEF);
                return {
                    "cloud": False,
                    "noComputer": ("auto" if still != "cloud" else ("pin" if person_pin else "works-on")),
                };
            }
            for (index, task) in enumerate(bot_tasks) {
                task_patch = task_patches[index];
                # Read before anything changes: a conversation that
                # follows the bot's level has the bot's level here.
                before = self.project_bot_for_task(bot["id"], task["threadId"]);
                assert before is not None;
                if bot_ask {
                    _js_set(task_patch, "approvalMode", before.get("approvalMode", UNDEF));
                    _js_set(task_patch, "autoApprove", before.get("autoApprove", UNDEF));
                    _js_set(task_patch, "alwaysAllow", deepcopy(_nn(al, [])));
                }
                # The engine this conversation ran on: its own, else the bot's.
                moved = retired(task.get("modelSelection")) if not _js_falsy(task.get("modelSelection", UNDEF)) else bot_moved;
                if moved {
                    if (
                        not bot_moved and computer is UNDEF
                        and ("surface" not in task or task["surface"] is UNDEF)
                        and keeps_cloud
                    ) {
                        task_patch["surface"] = "cloud";
                        task_patch["surfaceSource"] = "auto";
                    }
                    # The machine's memory of where Auto landed.
                    if (
                        not can_work_on_cloud and task.get("surface") == "cloud"
                        and task.get("surfaceSource") == "auto"
                    ) {
                        _js_set(task_patch, "surface", UNDEF);
                        _js_set(task_patch, "surfaceSource", UNDEF);
                    }
                    ask = needs_ask(before);
                    if ask {
                        _assign(task_patch, deepcopy(ask_now));
                    }
                    if task.get("modelSelection") is not None and task.get("modelSelection") is not UNDEF {
                        task_patch["modelSelection"] = deepcopy(replacement);
                    }
                    scope = "bot" if bot_moved and task.get("threadId") == bot.get("threadId") else "conversation";
                    move = {"botId": bot["id"], "threadId": task["threadId"], "scope": scope};
                    cam = cloud_after_move(task.get("surface", UNDEF), task.get("surfaceSource", UNDEF));
                    move.update(cam);
                    move["askNow"] = ask or (scope == "bot" and bot_ask);
                    moves.append(move);
                } elif bot_moved and task.get("threadId") == bot.get("threadId") {
                    move = {"botId": bot["id"], "threadId": task["threadId"], "scope": "bot-only"};
                    move.update(cloud_after_move(UNDEF, UNDEF));
                    move["askNow"] = bot_ask;
                    moves.append(move);
                }
                if touches(task.get("resumeCursors")) {
                    task_patch["resumeCursors"] = without(task["resumeCursors"]);
                }
                if isinstance(task.get("handedMessages"), dict) and touches(task["handedMessages"]) {
                    task_patch["handedMessages"] = without(task["handedMessages"]);
                }
            }
            if patch or any(task_patches) {
                changes.append({"bot": bot, "patch": patch, "tasks": task_patches});
            }
        }
        if not changes {
            return moves;
        }
        next_by_id = {};
        for ch in changes {
            nb = dict(ch["bot"]);
            _assign(nb, ch["patch"]);
            bt = ch["bot"].get("tasks");
            if not isinstance(bt, list) {
                _js_set(nb, "tasks", UNDEF);
            } else {
                merged = [];
                for (i, t) in enumerate(bt) {
                    mt = dict(t);
                    _assign(mt, ch["tasks"][i]);
                    merged.append(mt);
                }
                _js_set(nb, "tasks", merged);
            }
            next_by_id[ch["bot"]["id"]] = nb;
        }
        self.save_bots([next_by_id.get(b.get("id"), b) for b in self.bots]);
        for ch in changes {
            bot = ch["bot"];
            bt = bot.get("tasks");
            if isinstance(bt, list) {
                for (index, task) in enumerate(bt) {
                    _assign(task, ch["tasks"][index]);
                }
            }
            _assign(bot, ch["patch"]);
            self._emit({"type": "bot", "botId": bot["id"]});
        }
        return moves;
    }

    def set_resume_cursor(self: any, bot_id: str, instance_id: str, cursor: any, thread_id: (str | None) = None) -> None {
        bot = self.bot(bot_id);
        if bot is None {
            return;
        }
        # the cursor belongs to the task that produced it, not to the bot
        task = self.task_by_thread(bot_id, thread_id) if thread_id is not None else self.active_task(bot_id);
        if task is not None {
            rc = task.get("resumeCursors");
            if isinstance(rc, dict) {
                rc[instance_id] = cursor;
            }
        }
        # The legacy mirror follows the task visible in chat, never a
        # detached routine task working in the background.
        if thread_id is None or bot.get("threadId") == thread_id {
            rc = bot.get("resumeCursors");
            if isinstance(rc, dict) {
                rc[instance_id] = cursor;
            }
        }
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
    }

    def mark_task_dispatched(self: any, bot_id: str, thread_id: str, instance_id: str) -> None {
        # Record which instance just took a turn on this task. Called at
        # dispatch, not at cursor time.
        task = self.task_by_thread(bot_id, thread_id);
        if task is None or task.get("lastInstanceId") == instance_id {
            return;
        }
        task["lastInstanceId"] = instance_id;
        self.save_bots();
    }

    def set_handed_messages(self: any, bot_id: str, thread_id: str, instance_id: str, state: dict[str, any]) -> None {
        task = self.task_by_thread(bot_id, thread_id);
        if task is None {
            return;
        }
        hm = task.get("handedMessages");
        cur = hm.get(instance_id, UNDEF) if isinstance(hm, dict) else UNDEF;
        if cur is not UNDEF and js_stringify(cur) == js_stringify(state) {
            return;
        }
        if cur is UNDEF and state is UNDEF {
            return;
        }
        # Other instances keep a record only while it still describes
        # their session.
        live = {};
        for (rid, record) in (hm.items() if isinstance(hm, dict) else [].__iter__()) {
            if rid == instance_id {
                continue;
            }
            rcv = task.get("resumeCursors");
            rc: dict[str, any] = rcv if isinstance(rcv, dict) else {};
            if isinstance(record, dict) and "session" in record and _js_strict_eq(record["session"], rc.get(rid, UNDEF)) {
                live[rid] = record;
            }
        }
        live[instance_id] = state;
        task["handedMessages"] = live;
        self.save_bots();
    }

    def add_task_usage(self: any, bot_id: str, thread_id: str, turn: dict[str, any]) -> (dict[str, any] | None) {
        # Bank one settled turn onto its task. Called once per
        # turn.completed.
        task = self.task_by_thread(bot_id, thread_id);
        if task is None {
            return None;
        }
        prev = {"input": 0, "output": 0, "costUsd": None, "turns": 0};
        if isinstance(task.get("usage"), dict) {
            _assign(prev, task["usage"]);
        }
        cost = turn.get("costUsd") if _finite(turn.get("costUsd")) else None;
        prev_cost = prev.get("costUsd") if _is_num(prev.get("costUsd")) else None;
        # providers occasionally report NaN or a negative on a partial
        # turn — never let that poison a running tally
        def clean(n: any) -> int {
            return max(0, math.trunc(n)) if _finite(n) else 0;
        }
        # the cached share exists on a record only once a driver has
        # reported it
        cached_known = _is_num(prev.get("cachedInput")) or _is_num(turn.get("cachedInput"));
        prev_input = clean(prev.get("input"));
        turn_input = clean(turn.get("input"));
        next_cached_input = (
            min(clean(prev.get("cachedInput")), prev_input)
            + min(clean(turn.get("cachedInput")), turn_input)
        );
        ctx_raw = turn.get("context");
        context: dict[str, any] = ctx_raw if isinstance(ctx_raw, dict) else {};
        context_tokens = clean(context.get("tokens"));
        context_window = clean(context.get("window"));
        usage: dict[str, any] = {
            "input": prev_input + turn_input,
            "output": prev.get("output", 0) + clean(turn.get("output")),
        };
        if cached_known {
            usage["cachedInput"] = next_cached_input;
        }
        usage["costUsd"] = prev_cost if cost is None else ((prev_cost if prev_cost is not None else 0) + cost);
        usage["turns"] = prev.get("turns", 0) + 1;
        last_turn: dict[str, any] = {
            "input": turn_input,
            "output": clean(turn.get("output")),
        };
        if _is_num(turn.get("cachedInput")) {
            last_turn["cachedInput"] = min(clean(turn["cachedInput"]), turn_input);
        }
        last_turn["costUsd"] = cost;
        usage["lastTurn"] = last_turn;
        # a turn that reported no context keeps the previous reading
        if context_tokens > 0 {
            ctx: dict[str, any] = {"tokens": context_tokens};
            if context_window > 0 {
                ctx["window"] = context_window;
            }
            usage["context"] = ctx;
        } elif prev.get("context") is not None {
            usage["context"] = prev["context"];
        }
        task["usage"] = usage;
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return usage;
    }

    def unpin_task_cwd(self: any, thread_id: str) -> bool {
        # Forget where a conversation works: its next turn pins it again.
        bot = self.bot_by_thread(thread_id);
        task = self.task_by_thread(bot["id"], thread_id) if bot is not None else None;
        if bot is None or task is None or not _has(task, "cwd") {
            return False;
        }
        task.pop("cwd", None);
        self.save_bots();
        self._emit({"type": "bot", "botId": bot["id"]});
        return True;
    }

    def pin_task_cwd(self: any, bot_id: str, thread_id: str, fallback_cwd: any = None, opts: any = None) -> (str | None) {
        # The folder a task's turn runs in. Pins on first call from the
        # bot's current folder — unless the task already has a session.
        if opts is None {
            opts = {};
        }
        bot = self.bot(bot_id);
        task = self.task_by_thread(bot_id, thread_id) if bot is not None else None;
        if bot is None or task is None {
            return None;
        }
        # Its own folder, never the bot's project folder, pinned when it
        # first runs. A conversation that already ran elsewhere keeps its pin.
        if opts.get("privateOnly") and "cwd" not in task or (opts.get("privateOnly") and task.get("cwd") is UNDEF) {
            task["cwd"] = fallback_cwd if fallback_cwd is not None and fallback_cwd is not UNDEF else None;
            self.save_bots();
            self._emit({"type": "bot", "botId": bot_id});
            return task["cwd"];
        }
        if opts.get("none") {
            if not (task.get("cwd") is None and "cwd" in task) {
                task["cwd"] = None;
                self.save_bots();
                self._emit({"type": "bot", "botId": bot_id});
            }
            return None;
        }
        if "cwd" not in task or task.get("cwd") is UNDEF {
            rc = task.get("resumeCursors");
            n_keys = len(rc) if isinstance(rc, dict) else 0;
            if n_keys == 0 {
                cwd = bot.get("cwd");
                if cwd is None or cwd is UNDEF {
                    cwd = fallback_cwd;
                }
                task["cwd"] = cwd if cwd is not None and cwd is not UNDEF else None;
            } else {
                task["cwd"] = None;
            }
            self.save_bots();
            self._emit({"type": "bot", "botId": bot_id});
        }
        return task.get("cwd") if task.get("cwd") is not UNDEF else None;
    }

    def pin_group_cwd(self: any, group_id: str, thread_id: (str | None) = None) -> (str | None) {
        # The folder a room's member turns run in. Pins on the first turn
        # that dispatches, from the room's `cwd` at that moment.
        group = self.group(group_id);
        if group is None {
            return None;
        }
        task = self.group_task_by_thread(group_id, thread_id) if thread_id is not None else self.active_group_task(group_id);
        # Direct-message channels retain the original single-thread contract.
        if task is None {
            if not group.get("dm") {
                return None;
            }
            if "pinnedCwd" not in group or group["pinnedCwd"] is UNDEF {
                gcwd = group.get("cwd");
                group["pinnedCwd"] = gcwd if gcwd is not None and gcwd is not UNDEF else None;
                self.save_groups();
                self._emit({"type": "group", "groupId": group["id"]});
            }
            return group.get("pinnedCwd") if group.get("pinnedCwd") is not UNDEF else None;
        }
        if "pinnedCwd" not in task or task["pinnedCwd"] is UNDEF {
            gcwd = group.get("cwd");
            task["pinnedCwd"] = gcwd if gcwd is not None and gcwd is not UNDEF else None;
            if group.get("threadId") == task.get("threadId") {
                group["pinnedCwd"] = task["pinnedCwd"];
            }
            self.save_groups();
            self._emit({"type": "group", "groupId": group["id"]});
        }
        return task.get("pinnedCwd") if task.get("pinnedCwd") is not UNDEF else None;
    }

    # ── tasks ─────────────────────────────────────────────────────────────

    def project(self: any, bot_id: str, project_id: any) -> (dict[str, any] | None) {
        bot = self.bot(bot_id);
        if bot is None {
            return None;
        }
        for project in (bot.get("projects") or []) {
            if project.get("id") == project_id {
                return project;
            }
        }
        return None;
    }

    def create_project(self: any, bot_id: str, name: str, emoji: any = None) -> (dict[str, any] | None) {
        bot = self.bot(bot_id);
        if (
            bot is None or not isinstance(name, str) or not _js_trim(name)
            or (emoji is not None and not is_project_emoji(emoji))
        ) {
            return None;
        }
        project = {
            "id": new_id(),
            "name": _js_slice_16(_js_trim(name), 0, 80),
        };
        if emoji is not None {
            project["emoji"] = emoji;
        }
        bot["projects"] = list(bot.get("projects") or []) + [project];
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return project;
    }

    def patch_project(self: any, bot_id: str, project_id: str, patch: dict[str, any]) -> (dict[str, any] | None) {
        project = self.project(bot_id, project_id);
        if (
            project is None
            or ("name" in patch and (not isinstance(patch["name"], str) or not _js_trim(patch["name"])))
            or ("emoji" in patch and patch["emoji"] is not None and not is_project_emoji(patch["emoji"]))
        ) {
            return None;
        }
        if "name" in patch {
            project["name"] = _js_slice_16(_js_trim(patch["name"]), 0, 80);
        }
        if "emoji" in patch and patch["emoji"] is None {
            project.pop("emoji", None);
        } elif "emoji" in patch {
            project["emoji"] = patch["emoji"];
        }
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return project;
    }

    def reorder_projects(self: any, bot_id: str, project_ids: list[any]) -> (list[any] | None) {
        # The stored array is the sidebar order; only a full owned
        # permutation is valid.
        bot = self.bot(bot_id);
        projects = bot.get("projects") if isinstance(bot, dict) else None;
        if projects is None {
            projects = [];
        }
        if (
            bot is None or len(project_ids) != len(projects)
            or len(set(project_ids)) != len(projects)
        ) {
            return None;
        }
        by_id = {p.get("id"): p for p in projects};
        if any(i not in by_id for i in project_ids) {
            return None;
        }
        bot["projects"] = [by_id[i] for i in project_ids];
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return bot["projects"];
    }

    def delete_project(self: any, bot_id: str, project_id: str) -> (dict[str, any] | None) {
        # Removing an organizational label never removes its conversations.
        bot = self.bot(bot_id);
        if bot is None or self.project(bot_id, project_id) is None {
            return None;
        }
        bot["projects"] = [p for p in bot["projects"] if p.get("id") != project_id];
        for task in (bot.get("tasks") or []) {
            if task.get("projectId") == project_id {
                task.pop("projectId", None);
            }
        }
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return bot;
    }

    def _first_user_line(self: any, thread_id: (str | None)) -> (str | None) {
        # The first thing the human asked in a thread — a task's natural name.
        if not isinstance(thread_id, str) {
            return None;
        }
        for m in self.messages_for(thread_id) {
            text = m.get("text");
            if (
                m.get("role") == "user" and m.get("kind") == "text"
                and isinstance(text, str) and _js_trim(text)
            ) {
                return title_from_message(text);
            }
        }
        return None;
    }

    def tasks(self: any, bot_id: str) -> list[any] {
        bot = self.bot(bot_id);
        if bot is None {
            return [];
        }
        tv = bot.get("tasks");
        return tv if isinstance(tv, list) else [];
    }

    def active_task(self: any, bot_id: str) -> (dict[str, any] | None) {
        bot = self.bot(bot_id);
        if bot is None {
            return None;
        }
        for t in (bot.get("tasks") or []) {
            if t.get("threadId") == bot.get("threadId") {
                return t;
            }
        }
        return None;
    }

    def task_by_thread(self: any, bot_id: any, thread_id: any) -> (dict[str, any] | None) {
        bot = self.bot(bot_id);
        if bot is None {
            return None;
        }
        for t in (bot.get("tasks") or []) {
            if t.get("threadId") == thread_id {
                return t;
            }
        }
        return None;
    }

    def work_thread(self: any, bot_id: str, from_bot_id: str, from_thread_id: str) -> (dict[str, any] | None) {
        # The thread `fromBotId` opened on this bot from its conversation
        # `fromThreadId` with coordinate_bots. A thread the person
        # archived is left alone.
        for t in self.tasks(bot_id) {
            by_ = t.get("openedBy");
            if (
                isinstance(by_, dict) and by_.get("kind") == "work"
                and by_.get("botId") == from_bot_id
                and by_.get("threadId") == from_thread_id
                and "archivedAt" not in t
            ) {
                return t;
            }
        }
        return None;
    }

    def project_bot_for_task(self: any, bot_id: str, thread_id: str) -> (dict[str, any] | None) {
        # A turn gets an independent snapshot without changing the
        # selected task or mutating the bot's defaults while another turn
        # is running.
        bot = self.bot(bot_id);
        task = self.task_by_thread(bot_id, thread_id);
        if bot is None or task is None {
            return None;
        }
        out = dict(bot);
        out["threadId"] = task["threadId"];
        grant = bot.get("approvalGrant");
        if (
            isinstance(grant, dict) and grant.get("threadOnly") is True
            and grant.get("threadId") != thread_id
        ) {
            out["approvalGrant"] = UNDEF;
        }
        ms = task.get("modelSelection");
        if ms is None or ms is UNDEF {
            ms = bot.get("modelSelection", UNDEF);
        }
        _js_set(out, "modelSelection", deepcopy(ms));
        _js_set(out, "resumeCursors", deepcopy(task.get("resumeCursors", UNDEF)));
        am = task.get("approvalMode");
        if am is None or am is UNDEF {
            if "autoApprove" in task and task["autoApprove"] is not None and task["autoApprove"] is not UNDEF {
                am = UNDEF;
            } else {
                am = bot.get("approvalMode", UNDEF);
            }
        }
        _js_set(out, "approvalMode", am);
        aa = task.get("autoApprove");
        if aa is None or aa is UNDEF {
            aa = bot.get("autoApprove", UNDEF);
        }
        _js_set(out, "autoApprove", aa);
        al = task.get("alwaysAllow");
        if al is None or al is UNDEF {
            al = bot.get("alwaysAllow", UNDEF);
        }
        _js_set(out, "alwaysAllow", deepcopy(al));
        out["unread"] = bool(task.get("unread"));
        _js_set(out, "rewound", task.get("rewound", UNDEF));
        _js_set(out, "pinnedMessageId", task.get("pinnedMessageId", UNDEF));
        act = task.get("activity");
        out["activity"] = act if act is not None and act is not UNDEF else "idle";
        out["busy"] = bool(task.get("busy"));
        return out;
    }

    def patch_task(self: any, bot_id: str, thread_id: str, patch: dict[str, any]) -> (dict[str, any] | None) {
        bot = self.bot(bot_id);
        task = self.task_by_thread(bot_id, thread_id);
        if bot is None or task is None {
            return None;
        }
        pid = patch.get("projectId", UNDEF);
        if pid is not UNDEF and self.project(bot_id, pid) is None {
            return None;
        }
        for key in TASK_PATCH_FIELDS {
            if key in patch {
                _js_set(task, key, deepcopy(patch[key]));
            }
        }
        # "Until new activity" ends the moment the thread has something
        # new for the person.
        if _is_num(task.get("snoozedUntil")) and task["snoozedUntil"] == 0 and patch.get("unread") is True {
            _js_set(task, "snoozedUntil", UNDEF);
        }
        if isinstance(patch.get("title"), str) {
            trimmed = _js_slice_16(_js_trim(patch["title"]), 0, 80);
            task["title"] = trimmed if trimmed else UNTITLED_THREAD;
        }
        if "pinned" in patch and task.get("pinned") is not True {
            task.pop("pinned", None);
        }
        # Still hidden: attention belongs on the source conversation.
        if task.get("routineRunId") {
            task["unread"] = False;
        }
        if bot.get("threadId") == thread_id {
            self._mirror_active_task(bot, task);
        }
        bot["unread"] = any(task_counts_as_bot_unread(t) for t in bot["tasks"]);
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return task;
    }

    def clear_auto_surface_pins(self: any, bot_id: str, destination: any) -> int {
        # A Works on change is the newest explicit choice, so this bot's
        # machine-recorded pins that now point somewhere else give way.
        bot = self.bot(bot_id);
        if bot is None or not isinstance(bot.get("tasks"), list) {
            return 0;
        }
        cleared = 0;
        for task in bot["tasks"] {
            if (
                "surface" not in task or task["surface"] is UNDEF
                or task.get("surfaceSource") != "auto"
                or task["surface"] == destination
            ) {
                continue;
            }
            _js_set(task, "surface", UNDEF);
            _js_set(task, "surfaceSource", UNDEF);
            cleared += 1;
        }
        if not cleared {
            return 0;
        }
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return cleared;
    }

    def switch_task_model(
        self: any,
        bot_id: str,
        thread_id: str,
        selection: dict[str, any],
        update_bot_default: bool,
        reset_approval_to_ask: bool,
        task_patch: any = None
    ) -> (dict[str, any] | None) {
        # A person picks a model in one thread, and with updateBotDefault
        # makes it the bot's model too. A thread on its bot's model
        # follows the bot: it keeps no model of its own.
        if task_patch is None {
            task_patch = {};
        }
        bot = self.bot(bot_id);
        task = self.task_by_thread(bot_id, thread_id);
        if bot is None or task is None {
            return None;
        }
        approval = deepcopy(ASK_NOW) if reset_approval_to_ask else {};
        baseline = selection if update_bot_default else bot.get("modelSelection");
        own_sel = UNDEF if same_model_selection(selection, baseline) else deepcopy(selection);
        next_task = dict(task);
        _assign(next_task, task_patch);
        _js_set(next_task, "modelSelection", own_sel);
        _assign(next_task, approval);
        if isinstance(task_patch.get("title"), str) {
            trimmed = _js_slice_16(_js_trim(task_patch["title"]), 0, 80);
            next_task["title"] = trimmed if trimmed else UNTITLED_THREAD;
        }
        next_task = persisted_pin(next_task);
        # A new bot model moves the threads that follow it
        # (withDefaultModel); every other thread keeps its model.
        others = (
            self._with_default_model(bot, selection) if update_bot_default else bot["tasks"]
        );
        next_tasks = [];
        for (index, candidate) in enumerate(bot["tasks"]) {
            next_tasks.append(next_task if candidate is task else others[index]);
        }
        bot_patch = {};
        if update_bot_default {
            bot_patch["modelSelection"] = deepcopy(selection);
            _assign(bot_patch, approval);
        }
        saved = [];
        for candidate in self.bots {
            if candidate is bot {
                nb = dict(bot);
                _assign(nb, bot_patch);
                _js_set(nb, "tasks", next_tasks);
                saved.append(nb);
            } else {
                saved.append(candidate);
            }
        }
        self.save_bots(saved);
        for (index, candidate) in enumerate(bot["tasks"]) {
            _assign(candidate, next_tasks[index]);
        }
        _assign(bot, bot_patch);
        self._emit({"type": "bot", "botId": bot_id});
        return task;
    }

    def follow_bot_model(self: any, bot_id: str, thread_ids: list[any], reset: any = None) -> list[any] {
        # These threads follow their bot's model again: each one's own
        # model is cleared. One write.
        bot = self.bot(bot_id);
        if bot is None or not isinstance(bot.get("tasks"), list) {
            return [];
        }
        listed = set(thread_ids);
        patches = [];
        for task in bot["tasks"] {
            ms = task.get("modelSelection");
            if task["threadId"] not in listed or ms is None or ms is UNDEF {
                patches.append(None);
                continue;
            }
            p = {};
            if callable(reset) {
                _assign(p, reset(ms, bot["modelSelection"]));
            }
            _js_set(p, "modelSelection", UNDEF);
            if self._switch_needs_ask(bot_id, task["threadId"], ms, bot["modelSelection"]) {
                _assign(p, deepcopy(ASK_NOW));
            }
            patches.append(p);
        }
        moved = [
            bot["tasks"][i]["threadId"]
            for i in range(len(bot["tasks"])) if patches[i] is not None
        ];
        if not moved {
            return [];
        }
        next_tasks = [];
        for (i, task) in enumerate(bot["tasks"]) {
            if patches[i] is not None {
                nt = dict(task);
                _assign(nt, patches[i]);
                next_tasks.append(nt);
            } else {
                next_tasks.append(task);
            }
        }
        self.save_bots([
            (dict(b, tasks=next_tasks) if b is bot else b) for b in self.bots
        ]);
        for (i, task) in enumerate(bot["tasks"]) {
            if patches[i] is not None {
                _assign(task, patches[i]);
            }
        }
        active: any = None;
        for task in bot["tasks"] {
            if task.get("threadId") == bot.get("threadId") {
                active = task;
                break;
            }
        }
        if active is not None {
            self._mirror_active_task(bot, active);
        }
        self._emit({"type": "bot", "botId": bot_id});
        return moved;
    }

    def set_all_thread_approval_mode(self: any, bot_id: str, mode: str) -> (dict[str, any] | None) {
        # One durable write: never leave only part of a bot's threads updated.
        bot = self.bot(bot_id);
        if bot is None {
            return None;
        }
        patch = {"approvalMode": mode, "autoApprove": False, "alwaysAllow": []};
        tasks = [];
        for t in (bot.get("tasks") or []) {
            nt = dict(t);
            _assign(nt, patch);
            tasks.append(nt);
        }
        nxt = dict(bot);
        _assign(nxt, patch);
        nxt["approvalGrant"] = UNDEF;
        nxt["tasks"] = tasks;
        self.save_bots([nxt if c is bot else c for c in self.bots]);
        bt = bot.get("tasks");
        if isinstance(bt, list) {
            for (index, task) in enumerate(bt) {
                _assign(task, tasks[index]);
            }
        }
        _assign(bot, patch);
        bot["approvalGrant"] = UNDEF;
        self._emit({"type": "bot", "botId": bot_id});
        return bot;
    }

    def refresh_task_permissions(self: any, bot_id: str, thread_id: str) -> (dict[str, any] | None) {
        # Copy this bot's saved approval level and standing approvals onto
        # one thread. A grant that has not committed yet is ignored.
        bot = self.bot(bot_id);
        task = self.task_by_thread(bot_id, thread_id);
        if bot is None or task is None {
            return None;
        }
        probe = dict(bot);
        probe["approvalGrant"] = UNDEF;
        mode = approval_mode_for(probe);
        always_allow = deepcopy(bot.get("alwaysAllow") if bot.get("alwaysAllow") is not None else []);
        auto_approve = mode == "auto";
        same_allow = js_stringify(task.get("alwaysAllow") if task.get("alwaysAllow") is not None else []) == js_stringify(always_allow);
        if task.get("approvalMode") == mode and task.get("autoApprove") == auto_approve and same_allow {
            return task;
        }
        return self.patch_task(bot_id, thread_id, {
            "approvalMode": mode,
            "autoApprove": auto_approve,
            "alwaysAllow": always_allow,
        });
    }

    def _mirror_active_task(self: any, bot: any, task: any) -> None {
        bot["threadId"] = task["threadId"];
        _js_set(bot, "resumeCursors", deepcopy(task.get("resumeCursors", UNDEF)));
        _js_set(bot, "rewound", task.get("rewound", UNDEF));
        _js_set(bot, "pinnedMessageId", task.get("pinnedMessageId", UNDEF));
    }

    def create_task(
        self: any,
        bot_id: str,
        title: (str | None) = None,
        activate: bool = True,
        project_id: (str | None) = None,
        opened_by: any = None,
        approval_mode: (str | None) = None,
        model_selection: any = None
    ) -> (dict[str, any] | None) {
        # A fresh context on the same bot: new thread, new session, same
        # persona/tools/computer. Becomes the active task.
        bot = self.bot(bot_id);
        if bot is None {
            return None;
        }
        if project_id is not None and self.project(bot_id, project_id) is None {
            return None;
        }
        created_at = _now_ms();
        task: dict[str, any] = {
            "threadId": new_id(),
            "title": thread_title_from(title),
            "createdAt": created_at,
            "updatedAt": created_at,
        };
        if project_id {
            task["projectId"] = project_id;
        }
        if opened_by is not None {
            task["openedBy"] = deepcopy(opened_by);
        }
        task["resumeCursors"] = {};
        if (
            model_selection is not None
            and not same_model_selection(model_selection, bot.get("modelSelection"))
        ) {
            task["modelSelection"] = deepcopy(model_selection);
        }
        task["approvalMode"] = approval_mode if approval_mode is not None else approval_mode_for(bot);
        task["autoApprove"] = False if approval_mode is not None else bool(bot.get("autoApprove"));
        task["alwaysAllow"] = [] if approval_mode is not None else list(bot.get("alwaysAllow") or []);
        task["unread"] = False;
        task["activity"] = "idle";
        task["busy"] = False;
        bot["tasks"] = [task] + list(bot.get("tasks") or []);
        if activate {
            self._mirror_active_task(bot, task);
        }
        self.save_bots();
        _wire_bot_threads(bot);
        self._emit({"type": "bot", "botId": bot_id});
        return task;
    }

    def set_task_opened_by(self: any, bot_id: str, thread_id: str, opened_by: dict[str, any]) -> (dict[str, any] | None) {
        # Attach (or complete) the opener record after the thread exists.
        bot = self.bot(bot_id);
        task = self.task_by_thread(bot_id, thread_id);
        if bot is None or task is None {
            return None;
        }
        task["openedBy"] = deepcopy(opened_by);
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return task;
    }

    def set_task_closed_by(self: any, bot_id: str, thread_id: str, closed_by: any) -> (dict[str, any] | None) {
        # Stamp or clear the closer record. `null` reopens: the next turn
        # in a closed thread calls this so the row comes back.
        bot = self.bot(bot_id);
        task = self.task_by_thread(bot_id, thread_id);
        if bot is None or task is None {
            return None;
        }
        if closed_by is not None and closed_by is not UNDEF {
            task["closedBy"] = deepcopy(closed_by);
        } elif "closedBy" not in task or task["closedBy"] is UNDEF {
            return task;
        } else {
            task.pop("closedBy", None);
        }
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return task;
    }

    def switch_task(self: any, bot_id: str, thread_id: str) -> (dict[str, any] | None) {
        bot = self.bot(bot_id);
        task = None;
        if bot is not None {
            for t in (bot.get("tasks") or []) {
                if t.get("threadId") == thread_id {
                    task = t;
                    break;
                }
            }
        }
        if bot is None or task is None {
            return None;
        }
        self._mirror_active_task(bot, task);
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return bot;
    }

    def rename_task(self: any, bot_id: str, thread_id: str, title: str) -> (dict[str, any] | None) {
        return self.patch_task(bot_id, thread_id, {"title": title});
    }

    def title_task_from_first_message(self: any, bot_id: str, text: str, thread_id: (str | None) = None) -> (dict[str, any] | None) {
        # Name a task after its first message, once. Returns the task it
        # named so a caller can later replace exactly that machine-made title.
        task = self.task_by_thread(bot_id, thread_id) if thread_id is not None else self.active_task(bot_id);
        if (
            task is None or task.get("titleFromFirstMessage")
            or (task.get("title") != UNTITLED_TASK and task.get("title") != UNTITLED_THREAD)
        ) {
            return None;
        }
        task["title"] = title_from_message(text);
        task["titleFromFirstMessage"] = True;
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return task;
    }

    def retitle_task(self: any, bot_id: str, thread_id: str, machine_title: str, title: str) -> (dict[str, any] | None) {
        # Swap a machine-made first-message title for a generated one,
        # once. Equality against the snippet is the whole contract.
        task = self.task_by_thread(bot_id, thread_id);
        if task is None or task.get("title") != machine_title {
            return None;
        }
        return self.rename_task(bot_id, thread_id, thread_title_from(title));
    }

    def delete_task(self: any, bot_id: str, thread_id: str) -> (dict[str, any] | None) {
        # Delete a task and its transcript, retaining generated project
        # files. When no visible tasks remain, replace it with a fresh
        # conversation.
        bot = self.bot(bot_id);
        if bot is None or _js_falsy(bot.get("tasks", UNDEF)) and not isinstance(bot.get("tasks"), list) {
            return None;
        }
        if not any(t.get("threadId") == thread_id for t in bot["tasks"]) {
            return None;
        }
        bot["tasks"] = [t for t in bot["tasks"] if t.get("threadId") != thread_id];
        visible: any = None;
        for task in bot["tasks"] {
            if not task.get("routineRunId") {
                visible = task;
                break;
            }
        }
        if visible is None {
            visible = self.create_task(bot_id, None, bot.get("threadId") == thread_id);
        }
        active_task = self.task_by_thread(bot_id, bot["threadId"]);
        if (
            bot.get("threadId") == thread_id
            or (active_task is not None and active_task.get("routineRunId"))
        ) {
            self._mirror_active_task(bot, visible);
        }
        self._delete_thread_record(thread_id);
        bot["unread"] = any(task_counts_as_bot_unread(t) for t in bot["tasks"]);
        self._refresh_bot_activity(bot);
        self.save_bots();
        self._emit({"type": "bot", "botId": bot_id});
        return bot;
    }

    def needs_seed(self: any) -> bool {
        return len(self.bots) == 0;
    }

    def seed_if_empty(self: any) -> None {
        # First-run seed: one bot so the app never opens empty.
        if not self.needs_seed() {
            return;
        }
        self.create_bot();
    }
}
