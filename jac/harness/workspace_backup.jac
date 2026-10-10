"""Workspace backups on Jac (phase 4) - port of server/workspace-backup.ts.

An encrypted filesystem snapshot, not an additive import. Same archive
format as the TS implementation (OMB-WORKSPACE-1 magic, scrypt N=2^17 key,
AES-256-GCM over an uncompressed tar of manifest.json + data/), so archives
made by either side restore on the other. The on-disk recovery protocol
(.backups/<job>, pending-restore.json, restore-journal.json, safety-<id>,
last-restore.json) is unchanged byte-for-byte in shape.

Node-side dependencies are hooks in `_wb["hooks"]`:

  config_policy(action, config, destination) -> config
      portableWorkspaceConfig / restoredWorkspaceConfig stay with node's
      config schema (server/workspace-backup-policy.ts). Production calls a
      per-op loopback callback URL the facade passes as `policy_url`
      (server/jac-workspace-backup.ts) - not the routine bridge, because a
      restore is applied at node boot, before node listens, and an export
      runs while node's maintenance gate refuses /api traffic.
  quiesce / reload
      Jac-owned files inside the workspace (routines.json, webhooks.json,
      the harness's own messages.db handle) are coordinated in-process:
      a snapshot or commit pauses the routine scheduler and waits out a
      running tick; an applied or rolled-back restore drops routines and
      webhooks module state so their next op re-reads the restored files,
      and closes this harness's message-db handle.

AES-GCM comes from the runtime's own OpenSSL via ctypes (the Python stdlib
has no AEAD); scrypt is hashlib's.
"""

import os;
import re;
import json;
import stat;
import time;
import uuid;
import shutil;
import ctypes;
import ctypes.util;
import hashlib;
import secrets;
import sqlite3;
import tarfile;
import datetime;
import threading;
import posixpath;
import urllib.parse;
import urllib.request;

import from db { DATA_DIR, close_db }
import from jsutil { js_stringify }
import from routines { _state as _routines_state, _reset_state as _routines_reset_state }
import from webhooks { _reset as _webhooks_reset }

glob MAX_WORKSPACE_BACKUP_BYTES: int = 10 * 1024 * 1024 * 1024;
glob MAX_WORKSPACE_BACKUP_FILES: int = 100000;
glob MAX_WORKSPACE_BACKUP_UPLOAD_BYTES: int = 10 * 1024 * 1024 * 1024 + 256 * 1024 * 1024;
glob MAX_METADATA_BYTES: int = 16 * 1024 * 1024;
glob MAX_CLIENT_STATE_BYTES: int = 2 * 1024 * 1024;
glob MAGIC: bytes = b"OMB-WORKSPACE-1\n";
glob HEADER_BYTES: int = 16 + 16 + 12;
glob TAG_BYTES: int = 16;
glob CHUNK: int = 1024 * 1024;
glob ID_RE: any = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z");

# server/workspace-backup.ts EXCLUDED - this module is authoritative; node
# keeps a copy in workspace-backup-policy.ts for cloud-move's size estimate.
glob EXCLUDED: list[str] = [
    ".backups", "tools", "cache", ".cache", "tmp", ".tmp", "dist-native", "tunnel-runtime",
    ".openmausbot-server-child", "environment-id", "sessions.json", "tunnel-account.json",
    "team-computers.json",
    "openmausbot-server.lease", "box-create-requests.lock", "messages.db-wal", "messages.db-shm",
    "decider-log",
    "cloud-owner.json",
];
glob EXCLUSION_NOTES: list[str] = [
    "Device pairing, server identity, live leases and runtime files (existing destination identities are preserved).",
    "Saved credentials, provider and MCP connections, managed provider login homes and browser login profiles are not transferred. Destination connections are preserved; reconnect on a new device.",
    "Downloaded tools and caches; these can be installed again.",
    "Installed dependency folders (node_modules) and symbolic links inside conversation work folders; reinstall or recreate them in the project.",
    "External project folders, CLI login homes, browser session homes, OS keychains, companion devices and other servers.",
    "VM/container disk layers and remote cloud data; durable files inside this workspace are included.",
];
glob RESTORE_WARNING: str = "Restoring pauses routines, webhooks and calendar calls, and does not resume pending delegations, queued chat messages or queued runs. Definitions and historical receipts are retained; review before enabling them again.";
# shared/workspace-backup-client.ts WORKSPACE_BACKUP_CLIENT_KEYS.
glob CLIENT_KEYS: list[str] = [
    "omb-drafts", "omb-draft-attachments", "omb-draft-send-ids", "omb-draft-channel-modes",
    "omb-skin", "omb-show-threads", "omb-show-run-card", "openmausbot.sidebarDensity",
    "openmausbot.sidebarCollapsedSections.v1", "openmausbot.sidebarSectionOrder.v1",
    "omb-analytics-opt-out", "openmausbot.remote-voice.v1",
];
glob MANIFEST_KEYS: list[str] = ["summary", "sourceDataDir", "clientState", "entries"];
glob SUMMARY_KEYS: list[str] = [
    "format", "version", "id", "createdAt", "appVersion", "files", "directories", "bytes",
    "bots", "groups", "threads", "messages", "exclusions", "warnings",
];
glob ENTRY_KEYS: list[str] = ["path", "type", "size", "mode", "sha256"];
glob COUNT_KEYS: list[str] = ["files", "directories", "bytes", "bots", "groups", "threads", "messages"];
glob PATH_KEYS: list[str] = [
    "cwd", "pinnedCwd", "workspace", "configDir", "profileDirectory", "agentDir", "dataDir",
    "home", "cli", "path", "filePath", "localPath",
];
glob AUTH_ENV_FIELDS: list[str] = [
    "HOME", "USERPROFILE", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "GROK_HOME", "KIMI_CODE_HOME",
    "HERMES_HOME", "FACTORY_HOME_OVERRIDE", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "LOCALAPPDATA",
];
glob MAX_SAFE_INTEGER: int = 9007199254740991;

glob _wb: dict[str, any] = {};
glob _tls: any = threading.local();

class BackupError(Exception) {
    # Error with an optional HTTP status (JS `Object.assign(new Error, {status})`).
}

def _fail(message: str, status: int = 400) {
    err = BackupError(message);
    setattr(err, "status", status);
    raise err;
}

def _status_of(e: Exception) -> int {
    s = getattr(e, "status", None);
    return s if isinstance(s, int) and not isinstance(s, bool) else 400;
}

# ── JS-faithful JSON ───────────────────────────────────────────────────────
# JSON.parse orders array-index keys ("0".."4294967294") first, ascending,
# then the rest in insertion order; JSON.stringify keeps that order. Python
# keeps pure insertion order, so a parse/serialize round trip would reorder.

glob _INDEX_KEY: any = re.compile(r"^(?:0|[1-9][0-9]*)\Z");

def _is_index_key(k: str) -> bool {
    return _INDEX_KEY.match(k) is not None and int(k) < 4294967295;
}

def _js_object(pairs: list[any]) -> dict[str, any] {
    merged: dict[str, any] = {};
    for pair in pairs {
        merged[pair[0]] = pair[1];
    }
    indices = sorted([k for k in merged.keys() if _is_index_key(k)], key=int);
    if not indices {
        return merged;
    }
    ordered: dict[str, any] = {};
    for k in indices { ordered[k] = merged[k]; }
    for (k, v) in merged.items() {
        if not _is_index_key(k) { ordered[k] = v; }
    }
    return ordered;
}

def _reject_constant(name: str) -> any {
    raise ValueError(f"Unexpected token {name} in JSON");
}

def _js_parse(text: str) -> any {
    return json.loads(text, object_pairs_hook=_js_object, parse_constant=_reject_constant);
}

def _js_number_ok(v: any) -> bool {
    return (isinstance(v, int) or isinstance(v, float)) and not isinstance(v, bool);
}

def _safe_int(v: any) -> bool {
    # Number.isSafeInteger
    if isinstance(v, bool) { return False; }
    if isinstance(v, int) { return -MAX_SAFE_INTEGER <= v and v <= MAX_SAFE_INTEGER; }
    if isinstance(v, float) {
        return v == v and v not in (float("inf"), float("-inf")) and v.is_integer() and abs(v) <= MAX_SAFE_INTEGER;
    }
    return False;
}

def _record(v: any) -> bool {
    return isinstance(v, dict);
}

def _utf8_len(text: str) -> int {
    return len(text.encode("utf-8", "surrogatepass"));
}

def _utf16_len(text: str) -> int {
    return len(text.encode("utf-16-le", "surrogatepass")) // 2;
}

def _iso_now -> str {
    now = datetime.datetime.now(datetime.timezone.utc);
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z";
}

def _date_parses(text: str) -> bool {
    # Date.parse finiteness for the ISO strings this format writes.
    try {
        datetime.datetime.fromisoformat(text.replace("Z", "+00:00") if text.endswith("Z") else text);
        return True;
    } except Exception {
        return False;
    }
}

# ── hooks ──────────────────────────────────────────────────────────────────

def _policy_url -> any {
    return getattr(_tls, "policy_url", None);
}

def _hook_config_policy(action: str, config: any, destination: any) -> any {
    url = _policy_url();
    if not url {
        _fail("Workspace configuration policy is unavailable; nothing was changed.", 503);
    }
    body = json.dumps({"op": "workspace_backup_config", "action": action, "config": config, "destination": destination}).encode("utf-8");
    headers = {"content-type": "application/json"};
    token = os.environ.get("OMB_JAC_TOKEN");
    if token { headers["x-omb-jac-token"] = token; }
    req = urllib.request.Request(url, data=body, headers=headers, method="POST");
    resp = urllib.request.urlopen(req, timeout=60);
    try {
        raw = resp.read().decode("utf-8");
    } finally {
        resp.close();
    }
    reply = _js_parse(raw) if raw else {};
    if not _record(reply) { _fail("Workspace configuration policy returned no answer."); }
    if isinstance(reply.get("error"), str) { _fail(reply["error"]); }
    if not _record(reply.get("config")) { _fail("Workspace configuration policy returned no configuration."); }
    return reply["config"];
}

def _hook_quiesce(data_dir: str) {
    # Snapshot/commit: stop the routine scheduler writing routines.json and
    # wait out a tick already running. Node's gate pauses it too (fire and
    # forget, ordered before this op on the op chain); this is the in-process
    # guarantee. Webhook writes only happen inside serialized ops.
    if os.path.abspath(data_dir) != os.path.abspath(DATA_DIR) { return; }
    _routines_state["paused"] = True;
    deadline = time.time() + 30;
    while _routines_state.get("ticking") and time.time() < deadline {
        time.sleep(0.05);
    }
}

def _hook_reload(data_dir: str) {
    # A restore (or its rollback) replaced routines.json, webhooks.json and
    # messages.db underneath this harness: drop module state so the next op
    # re-reads the files (node's routine_boot re-runs recovery), and close
    # the cached message-db handle.
    if os.path.abspath(data_dir) != os.path.abspath(DATA_DIR) { return; }
    _routines_reset_state();
    _webhooks_reset();
    try { close_db(); } except Exception { }
}

def _default_hooks -> dict[str, any] {
    return {"config_policy": _hook_config_policy, "quiesce": _hook_quiesce, "reload": _hook_reload};
}

def _reset_wb -> None {
    _wb.update({"hooks": _default_hooks()});
}

def _hook(name: str) -> any {
    return _wb["hooks"][name];
}

def _portable_config(value: any) -> any {
    if not _record(value) { _fail("Invalid workspace configuration in backup."); }
    return _hook("config_policy")("portable", value, None);
}

def _restored_config(portable: any, destination: any) -> any {
    if not _record(destination) { _fail("Invalid destination workspace configuration; connections were not changed."); }
    return _hook("config_policy")("restored", portable, destination);
}

# ── path policy (server/workspace-backup-policy.ts) ────────────────────────
# JS `$` (no m flag) is end-of-input: \Z here. `\d` is ASCII in JS.

glob _AUTH_TMP_ALLOW: any = re.compile(r"^command-allowlist\.json(?:\Z|\.[0-9]+\.[0-9a-f-]+\.tmp\Z)");
glob _AUTH_MCP: any = re.compile(r"^mcp-oauth\.json(?:\Z|\.[0-9]+\.[0-9a-f-]+\.tmp\Z)");
glob _AUTH_ROOTS: any = re.compile(r"^(?:(?:providers|caddy|chrome-profile|\.agent-browser)(?:/|\Z)|workspace-credentials\.json\Z|external-runtimes\.json\Z|browser-engine-key\Z)");
glob _AUTH_TMPS: any = re.compile(r"^(?:config\.json|webhooks\.json|workspace-credentials\.json|external-runtimes\.json|browser-engine-key|sessions\.json|tunnel-account\.json)\.[0-9]+(?:\.[0-9a-f-]+)?\.tmp\Z");
glob _AUTH_BROWSER: any = re.compile(r"^(?:vm-home|vm-homes/[^/]+)/\.browser-profiles(?:/|\Z)");
glob _ORG_LIBRARY: any = re.compile(r"^org-library/(?:catalog\.json(?:\.[0-9a-f-]{36}\.tmp)?\Z|blobs(?:/|\Z))");
glob _EPHEMERAL: any = re.compile(r"^(?:hook-tokens(?:/|\Z)|sessions\.json\.open\Z)");
glob _PERM_SOCK: any = re.compile(r"^perm-[A-Za-z0-9_-]+\.sock\Z");

def excluded_workspace_auth_path(path: str) -> bool {
    if _AUTH_TMP_ALLOW.search(path) or _AUTH_MCP.search(path) { return True; }
    return bool(_AUTH_ROOTS.search(path) or _AUTH_TMPS.search(path) or _AUTH_BROWSER.search(path));
}

def redownloaded_org_library_path(path: str) -> bool {
    return bool(_ORG_LIBRARY.search(path));
}

def ephemeral_workspace_token_path(path: str) -> bool {
    return bool(_EPHEMERAL.search(path));
}

def _excluded(name: str) -> bool {
    return (name in EXCLUDED or excluded_workspace_auth_path(name)
        or name.startswith("openmausbot-server.lease.") or name.startswith("box-create-requests.lock.")
        or bool(_PERM_SOCK.search(name)));
}

def _forbidden_archive_path(path: str) -> bool {
    folded = path.lower();
    return (_excluded(folded.split("/")[0]) or excluded_workspace_auth_path(folded)
        or (path != folded and folded in ["config.json", "webhooks.json"]));
}

def _preserved(name: str) -> bool {
    # Existing WAL/SHM belong to the old database and must move into safety,
    # never accompany a different restored main database.
    folded = name.lower();
    return _excluded(folded) and folded != "messages.db-wal" and folded != "messages.db-shm";
}

def _kept_in_place(name: str) -> bool {
    return _preserved(name) or name.lower() == "sessions.json.open";
}

def omitted_from_workspace_backup(path: str) -> bool {
    return (_excluded(path.split("/")[0]) or excluded_workspace_auth_path(path)
        or ephemeral_workspace_token_path(path) or redownloaded_org_library_path(path));
}

glob _RESERVED_PART: any = re.compile(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|\Z)", re.IGNORECASE);
glob _BAD_CHARS: any = re.compile(r"[\\\x00:]");

def _js_is_absolute(path: str) -> bool {
    if os.name == "nt" {
        return path.startswith("/") or path.startswith("\\") or bool(re.match(r"^[A-Za-z]:[\\/]", path));
    }
    return path.startswith("/");
}

def _valid_relative(path: str) -> bool {
    if not path or _utf16_len(path) > 4096 or _js_is_absolute(path) or _BAD_CHARS.search(path) {
        return False;
    }
    for part in path.split("/") {
        if not part or part == "." or part == ".." or part.endswith(".") or part.endswith(" ") {
            return False;
        }
        if _RESERVED_PART.search(part) { return False; }
    }
    return True;
}

# ── filesystem helpers ─────────────────────────────────────────────────────

def _entry_exists(path: str) -> bool {
    try {
        os.lstat(path);
        return True;
    } except FileNotFoundError {
        return False;
    }
}

def _is_real_dir(path: str) -> bool {
    st = os.lstat(path);
    return stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode);
}

def _folder(path: str) {
    os.makedirs(path, mode=0o700, exist_ok=True);
    if not _is_real_dir(path) {
        _fail("The backup directory must be a real directory, not a symbolic link.");
    }
    os.chmod(path, 0o700);
}

def _resolve(path: str) -> str {
    return os.path.abspath(path);
}

def _backup_root(data_dir: str) -> str {
    top = _resolve(data_dir);
    if top == os.path.splitdrive(top)[0] + os.sep {
        _fail("A filesystem root cannot be a workspace backup target.");
    }
    if not _is_real_dir(top) {
        _fail("The workspace data directory must not be a symbolic link.");
    }
    path = os.path.join(top, ".backups");
    _folder(path);
    return path;
}

def _job_path(data_dir: str, id: any) -> str {
    if not isinstance(id, str) or ID_RE.match(id) is None {
        _fail("Invalid workspace backup identifier.");
    }
    path = os.path.join(_backup_root(data_dir), id);
    if _entry_exists(path) and not _is_real_dir(path) {
        _fail("Unsafe workspace backup job directory.");
    }
    return path;
}

def _new_job(data_dir: str, id: any = None) -> dict[str, any] {
    job_id = id if isinstance(id, str) else str(uuid.uuid4());
    directory = _job_path(data_dir, job_id);
    os.mkdir(directory, 0o700);
    return {"id": job_id, "directory": directory};
}

def _read_private(path: str, limit: int, message: str) -> bytes {
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0));
    try {
        st = os.fstat(fd);
        if not stat.S_ISREG(st.st_mode) or st.st_size > limit { _fail(message); }
        chunks: list[bytes] = [];
        while True {
            part = os.read(fd, CHUNK);
            if not part { break; }
            chunks.append(part);
        }
        return b"".join(chunks);
    } finally {
        os.close(fd);
    }
}

def _private_json(path: str) -> any {
    raw = _read_private(path, MAX_METADATA_BYTES, "Workspace backup metadata is too large or is not a regular file.");
    return _js_parse(raw.decode("utf-8", "replace"));
}

def _write_file_atomic(path: str, data: bytes, mode: int) {
    # server/atomic.ts writeFileAtomic: sibling temp, fsync, rename.
    tmp = f"{path}.{os.getpid()}.{uuid.uuid4()}.tmp";
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode);
    try {
        try {
            view = memoryview(data);
            offset = 0;
            while offset < len(data) { offset += os.write(fd, view[offset:]); }
            os.fsync(fd);
        } finally {
            os.close(fd);
        }
        os.chmod(tmp, mode);
        os.replace(tmp, path);
    } except Exception {
        try { os.unlink(tmp); } except Exception { }
        raise;
    }
}

def _write_json(path: str, value: any) {
    text = js_stringify(value);
    data = text.encode("utf-8", "surrogatepass");
    if len(data) > MAX_METADATA_BYTES { _fail("Workspace backup metadata exceeds the size limit."); }
    _write_file_atomic(path, data, 0o600);
}

def _rm_tree(path: str) {
    if not _entry_exists(path) { return; }
    if _is_real_dir(path) {
        shutil.rmtree(path, ignore_errors=True);
    } else {
        try { os.unlink(path); } except Exception { }
    }
}

def _private_metadata(manifest: dict[str, any]) -> dict[str, any] {
    return {"summary": manifest["summary"], "clientState": manifest["clientState"]};
}

def _realpath(path: str) -> str {
    return os.path.realpath(path);
}

def _relative(base: str, target: str) -> str {
    return os.path.relpath(target, base);
}

def _home_of(environment: dict[str, any]) -> str {
    h = environment.get("HOME") or environment.get("USERPROFILE");
    return str(h) if h else os.path.expanduser("~");
}

def _assert_local_auth_outside_snapshot(data_dir: str) {
    config_path = os.path.join(data_dir, "config.json");
    config = _private_json(config_path) if os.path.exists(config_path) else {};
    instances = config["instances"] if _record(config) and _record(config.get("instances")) else {};
    def _probe(value: any, field: str, home: str) {
        if not isinstance(value, str) or not value.strip() { return; }
        text = value.strip();
        expanded = os.path.join(home, text[2:]) if (text.startswith("~/") or text.startswith("~\\")) else text;
        resolved = _resolve(expanded);
        exists = _entry_exists(resolved);
        base = _realpath(data_dir) if exists else _resolve(data_dir);
        target = _realpath(resolved) if exists else resolved;
        rel = _relative(base, target).replace("\\", "/");
        if rel == "." { rel = ""; }
        if rel == ".." or rel.startswith("../") or _js_is_absolute(rel) { return; }
        if rel and (_excluded(rel.split("/")[0]) or excluded_workspace_auth_path(rel)) { return; }
        _fail(f"Provider authentication storage ({field}) is inside backed-up workspace files. Move that login storage into the excluded providers folder or outside this workspace before backing up or restoring.");
    }
    base_env: dict[str, any] = dict(os.environ);
    environments: list[any] = [base_env];
    for instance in instances.values() {
        if not _record(instance) { continue; }
        merged = dict(base_env);
        if _record(instance.get("environment")) { merged.update(instance["environment"]); }
        environments.append(merged);
    }
    for environment in environments {
        home = _home_of(environment);
        for field in AUTH_ENV_FIELDS { _probe(environment.get(field), field, home); }
    }
    for instance in instances.values() {
        if not _record(instance) or instance.get("driver") != "claudeAgent" or not _record(instance.get("config")) { continue; }
        environment = dict(base_env);
        if _record(instance.get("environment")) { environment.update(instance["environment"]); }
        _probe(instance["config"].get("configDir"), "config.configDir", _home_of(environment));
    }
}

def _password_key(password: any, salt: bytes) -> bytes {
    if not isinstance(password, str) or _utf16_len(password) < 12 or _utf8_len(password) > 1024 {
        _fail("Use a backup password of at least 12 characters (at most 1024 bytes).");
    }
    return hashlib.scrypt(password.encode("utf-8", "surrogatepass"), salt=salt, n=131072, r=8, p=1, maxmem=256 * 1024 * 1024, dklen=32);
}

# ── AES-256-GCM over the runtime's OpenSSL ─────────────────────────────────
# python-build-standalone links OpenSSL into _hashlib and exports its EVP
# symbols; a system libcrypto is the fallback.

glob _ossl: dict[str, any] = {};
glob EVP_CTRL_GCM_SET_IVLEN: int = 9;
glob EVP_CTRL_GCM_GET_TAG: int = 16;
glob EVP_CTRL_GCM_SET_TAG: int = 17;

def _libcrypto -> any {
    lib: any = _ossl.get("lib");
    if lib is not None { return lib; }
    candidates: list[any] = [];
    try {
        import _hashlib;
        candidates.append(_hashlib.__file__);
    } except Exception { }
    for name in ["crypto", "libcrypto-3-x64", "libcrypto-3", "libcrypto"] {
        found = ctypes.util.find_library(name);
        if found { candidates.append(found); }
    }
    for path in candidates {
        try {
            cand = ctypes.CDLL(path);
            getattr(cand, "EVP_aes_256_gcm");
            getattr(cand, "EVP_CIPHER_CTX_ctrl");
            lib = cand;
            break;
        } except Exception { }
    }
    if lib is None { _fail("Encrypted workspace backups are unavailable: this runtime has no AES-GCM implementation.", 503); }
    lib.EVP_CIPHER_CTX_new.restype = ctypes.c_void_p;
    lib.EVP_CIPHER_CTX_new.argtypes = [];
    lib.EVP_CIPHER_CTX_free.argtypes = [ctypes.c_void_p];
    lib.EVP_aes_256_gcm.restype = ctypes.c_void_p;
    lib.EVP_aes_256_gcm.argtypes = [];
    for fn in ["EVP_EncryptInit_ex", "EVP_DecryptInit_ex"] {
        getattr(lib, fn).argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p];
    }
    for fn in ["EVP_EncryptUpdate", "EVP_DecryptUpdate"] {
        getattr(lib, fn).argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.c_char_p, ctypes.c_int];
    }
    for fn in ["EVP_EncryptFinal_ex", "EVP_DecryptFinal_ex"] {
        getattr(lib, fn).argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)];
    }
    lib.EVP_CIPHER_CTX_ctrl.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_void_p];
    _ossl["lib"] = lib;
    return lib;
}

obj Gcm {
    # One AES-256-GCM pass. `encrypt` selects direction; `aad` is the file
    # header, authenticated but not encrypted.
    has encrypt: bool,
        lib: any = None,
        ctx: any = None,
        buf: any = None,
        n: any = None;

    def start(key: bytes, iv: bytes, aad: bytes) {
        self.lib = _libcrypto();
        self.ctx = self.lib.EVP_CIPHER_CTX_new();
        if not self.ctx { _fail("Could not start the backup cipher."); }
        self.n = ctypes.c_int(0);
        self.buf = ctypes.create_string_buffer(CHUNK + 32);
        init = self.lib.EVP_EncryptInit_ex if self.encrypt else self.lib.EVP_DecryptInit_ex;
        ok = init(self.ctx, self.lib.EVP_aes_256_gcm(), None, None, None) == 1;
        ok = ok and self.lib.EVP_CIPHER_CTX_ctrl(self.ctx, EVP_CTRL_GCM_SET_IVLEN, len(iv), None) == 1;
        ok = ok and init(self.ctx, None, None, key, iv) == 1;
        if ok and aad {
            upd = self.lib.EVP_EncryptUpdate if self.encrypt else self.lib.EVP_DecryptUpdate;
            ok = upd(self.ctx, None, ctypes.byref(self.n), aad, len(aad)) == 1;
        }
        if not ok {
            self.close();
            _fail("Could not start the backup cipher.");
        }
    }

    def update(data: bytes) -> bytes {
        out: list[bytes] = [];
        upd = self.lib.EVP_EncryptUpdate if self.encrypt else self.lib.EVP_DecryptUpdate;
        offset = 0;
        while offset < len(data) {
            piece = data[offset:offset + CHUNK];
            offset += len(piece);
            if upd(self.ctx, self.buf, ctypes.byref(self.n), piece, len(piece)) != 1 {
                _fail("The backup cipher failed.");
            }
            out.append(self.buf.raw[0:self.n.value]);
        }
        return b"".join(out);
    }

    def finish_encrypt -> bytes {
        if self.lib.EVP_EncryptFinal_ex(self.ctx, self.buf, ctypes.byref(self.n)) != 1 { _fail("The backup cipher failed."); }
        tail = self.buf.raw[0:self.n.value];
        tag = ctypes.create_string_buffer(TAG_BYTES);
        if self.lib.EVP_CIPHER_CTX_ctrl(self.ctx, EVP_CTRL_GCM_GET_TAG, TAG_BYTES, tag) != 1 { _fail("The backup cipher failed."); }
        return tail + tag.raw;
    }

    def finish_decrypt(tag: bytes) -> bool {
        holder = ctypes.create_string_buffer(tag, TAG_BYTES);
        if self.lib.EVP_CIPHER_CTX_ctrl(self.ctx, EVP_CTRL_GCM_SET_TAG, TAG_BYTES, holder) != 1 { return False; }
        return self.lib.EVP_DecryptFinal_ex(self.ctx, self.buf, ctypes.byref(self.n)) == 1;
    }

    def close {
        if self.ctx {
            self.lib.EVP_CIPHER_CTX_free(self.ctx);
            self.ctx = None;
        }
    }
}

obj EncryptingSink {
    # File-like sink for tarfile's stream writer: every byte is encrypted on
    # its way to the archive file, so no plaintext tar ever lands on disk.
    has gcm: Gcm,
        fd: int;

    def write(data: any) -> int {
        chunk = bytes(data);
        _write_all(self.fd, self.gcm.update(chunk));
        return len(chunk);
    }

    def flush {
        return;
    }
}

# ── copying, hashing, counting ─────────────────────────────────────────────

def _write_all(fd: int, data: bytes) {
    view = memoryview(data);
    offset = 0;
    while offset < len(data) { offset += os.write(fd, view[offset:]); }
}

def _copy_regular(source: str, destination: str) -> dict[str, any] {
    # Open without following links and copy synchronously so this server
    # cannot interleave a mutation. External writers are detected where
    # stat permits.
    src = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0));
    out: any = None;
    try {
        before = os.fstat(src);
        if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_WORKSPACE_BACKUP_BYTES {
            _fail("A workspace file is not regular or exceeds the 10 GB backup limit.");
        }
        mode = 0o700 if before.st_mode & 0o100 else 0o600;
        out = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode);
        digest = hashlib.sha256();
        size = 0;
        while True {
            chunk = os.read(src, CHUNK);
            if not chunk { break; }
            size += len(chunk);
            if size > before.st_size { _fail("A workspace file changed during backup. Stop its writer and retry."); }
            digest.update(chunk);
            _write_all(out, chunk);
        }
        after = os.fstat(src);
        current = os.lstat(source);
        if (size != before.st_size or after.st_mtime_ns != before.st_mtime_ns or after.st_ctime_ns != before.st_ctime_ns
            or current.st_ino != before.st_ino or current.st_dev != before.st_dev or stat.S_ISLNK(current.st_mode)) {
            _fail("A workspace file changed during backup. Stop its writer and retry.");
        }
        os.fsync(out);
        return {"size": size, "mode": mode, "sha256": digest.hexdigest()};
    } finally {
        os.close(src);
        if out is not None { os.close(out); }
    }
}

def _hash_file(path: str) -> str {
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0));
    digest = hashlib.sha256();
    try {
        if not stat.S_ISREG(os.fstat(fd).st_mode) { _fail("The workspace archive contains an unsafe file."); }
        while True {
            chunk = os.read(fd, CHUNK);
            if not chunk { break; }
            digest.update(chunk);
        }
    } finally {
        os.close(fd);
    }
    return digest.hexdigest();
}

glob _ROSTER_ID: any = re.compile(r"^[A-Za-z0-9_-]{1,128}\Z");

def _roster_id(v: any) -> bool {
    return isinstance(v, str) and _ROSTER_ID.match(v) is not None;
}

def _count_json_array(path: str) -> int {
    if not os.path.exists(path) { return 0; }
    value = _private_json(path);
    if not isinstance(value, list) { _fail("A workspace roster is not a valid JSON array."); }
    ids: set[str] = set();
    for item in value {
        if not _record(item) or not _roster_id(item.get("id")) or item["id"] in ids {
            _fail("A workspace roster contains an invalid or duplicate identifier.");
        }
        ids.add(item["id"]);
        if "threadId" in item and not _roster_id(item["threadId"]) {
            _fail("A workspace roster contains an invalid thread identifier.");
        }
        if "tasks" in item {
            tasks = item["tasks"];
            good = isinstance(tasks, list);
            if good {
                for task in tasks {
                    if not _record(task) or not _roster_id(task.get("threadId")) { good = False; }
                }
            }
            if not good { _fail("A workspace roster contains invalid task records."); }
        }
    }
    return len(value);
}

def _sqlite_uri(path: str, mode: str) -> str {
    return "file:" + urllib.parse.quote(path) + "?mode=" + mode;
}

def _database_counts(path: str) -> dict[str, any] {
    if not os.path.exists(path) { return {"threads": 0, "messages": 0}; }
    con = sqlite3.connect(_sqlite_uri(path, "ro"), uri=True);
    try {
        rows = con.execute("PRAGMA quick_check").fetchall();
        if len(rows) != 1 or rows[0][0] != "ok" { _fail("The message database failed its integrity check."); }
        tables = con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('messages', 'thread_state')").fetchall();
        if len(tables) != 2 { _fail("The backup does not contain a supported message database."); }
        counts = con.execute("SELECT COUNT(*) AS messages, COUNT(DISTINCT thread_id) AS threads FROM messages").fetchone();
        return {"threads": int(counts[1]), "messages": int(counts[0])};
    } finally {
        con.close();
    }
}

# ── export ─────────────────────────────────────────────────────────────────

glob _SKILL_LINK: any = re.compile(r"^workspaces/[^/]+/\.(?:claude|agents|grok)/skills/[^/]+\Z");

def _tar_info(name: str, kind: bytes, size: int, mode: int, mtime: float) -> any {
    info = tarfile.TarInfo(name);
    info.type = kind;
    info.size = size;
    info.mode = mode;
    info.mtime = int(mtime);
    info.uid = 0;
    info.gid = 0;
    info.uname = "";
    info.gname = "";
    return info;
}

def _tar_add_tree(archive: any, base: str, rel: str) {
    full = os.path.join(base, rel);
    st = os.lstat(full);
    if stat.S_ISDIR(st.st_mode) {
        archive.addfile(_tar_info(rel, tarfile.DIRTYPE, 0, stat.S_IMODE(st.st_mode), st.st_mtime));
        for name in sorted(os.listdir(full)) {
            _tar_add_tree(archive, base, rel + "/" + name);
        }
        return;
    }
    if not stat.S_ISREG(st.st_mode) { _fail("The backup snapshot contains an unsupported entry."); }
    with open(full, "rb") as handle {
        archive.addfile(_tar_info(rel, tarfile.REGTYPE, st.st_size, stat.S_IMODE(st.st_mode), st.st_mtime), handle);
    }
}

def _snapshot_messages_db(source_db: str, target: str) {
    # The caller closed its message handle after flushing, while maintenance
    # remains held. The native backup includes any committed WAL records.
    src = sqlite3.connect(_sqlite_uri(source_db, "ro"), uri=True);
    try {
        dst = sqlite3.connect(target);
        try {
            src.backup(dst);
            dst.execute("PRAGMA journal_mode = DELETE");
        } finally {
            dst.close();
        }
    } finally {
        src.close();
    }
}

def wb_create(data_dir: str, options: dict[str, any], job_id: any = None) -> dict[str, any] {
    if "credentials" in options { _fail("Workspace backups do not transfer credentials."); }
    _assert_local_auth_outside_snapshot(data_dir);
    salt = secrets.token_bytes(16);
    key = _password_key(options.get("password"), salt);
    job = _new_job(data_dir, job_id);
    snapshot = os.path.join(job["directory"], "snapshot");
    _folder(os.path.join(snapshot, "data"));
    entries: list[any] = [];
    warnings: list[str] = [
        "Stop external editors and managed desktops before exporting; files written outside this server cannot be frozen by the backup gate.",
        "Conversation text and user files are not redacted and may contain secrets you pasted. Keep the encrypted backup private.",
        RESTORE_WARNING,
    ];
    tally: dict[str, int] = {"bytes": 0, "links": 0, "deps": 0, "work": 0};
    try {
        top = _realpath(data_dir);
        source_db = os.path.join(top, "messages.db");
        if os.path.exists(source_db) {
            if os.path.islink(source_db) { _fail("The message database must not be a symbolic link."); }
            _snapshot_messages_db(source_db, os.path.join(snapshot, "messages-snapshot.db"));
        }
        def _walk(directory: str, prefix: str) {
            for name in sorted(os.listdir(directory)) {
                if not prefix and _excluded(name) { continue; }
                path = f"{prefix}/{name}" if prefix else name;
                if excluded_workspace_auth_path(path) or ephemeral_workspace_token_path(path) or redownloaded_org_library_path(path) { continue; }
                # Reject noncanonical source spellings: a case-sensitive host
                # must not export auth paths active on Windows/Mac.
                if _forbidden_archive_path(path) { _fail("A workspace filename conflicts with a protected authentication or runtime path."); }
                if not _valid_relative(path) { _fail("A workspace filename cannot be safely restored on supported platforms."); }
                source = os.path.join(directory, name);
                st = os.lstat(source);
                is_link = stat.S_ISLNK(st.st_mode);
                # Installed dependencies come back from the project's lockfile.
                if name == "node_modules" and (stat.S_ISDIR(st.st_mode) or is_link) {
                    tally["deps"] += 1;
                    continue;
                }
                # A link in a conversation's work folder points at something
                # that is not this workspace's data: leave it out.
                if is_link and path.startswith("task-workspaces/") {
                    tally["work"] += 1;
                    continue;
                }
                if is_link {
                    target: str = "";
                    try {
                        target = os.path.realpath(source);
                        if not os.path.exists(target) { raise FileNotFoundError(target); }
                    } except Exception {
                        _fail(f"Cannot back up dangling symbolic link: {path}");
                    }
                    rel = _relative(top, target);
                    if rel == ".." or rel.startswith(".." + os.sep) or _js_is_absolute(rel) {
                        _fail(f"Cannot back up symbolic link outside the workspace: {path}");
                    }
                    # Only the app's disposable native-discovery links may be
                    # omitted; an arbitrary user link is user data.
                    if _SKILL_LINK.match(path) is None or not rel.replace("\\", "/").startswith(f"workspaces/{path.split('/')[1]}/skills/") {
                        _fail(f"Cannot back up user-created symbolic link; replace it with regular files first: {path}");
                    }
                    tally["links"] += 1;
                    continue;
                }
                if len(entries) >= MAX_WORKSPACE_BACKUP_FILES { _fail("The workspace exceeds the 100,000-entry backup limit."); }
                destination = os.path.join(snapshot, "data", path);
                if stat.S_ISDIR(st.st_mode) {
                    _folder(destination);
                    entries.append({"path": path, "type": "directory", "size": 0, "mode": 0o700});
                    _walk(source, path);
                } elif stat.S_ISREG(st.st_mode) {
                    copied: dict[str, any] = {};
                    if path == "config.json" or path == "webhooks.json" {
                        value = _private_json(source);
                        if path == "config.json" {
                            _write_json(destination, _portable_config(value));
                        } else {
                            if not _record(value) { _fail("Invalid webhook definitions in workspace backup."); }
                            if isinstance(value.get("webhooks"), list) {
                                for webhook in value["webhooks"] {
                                    if _record(webhook) { webhook.pop("secretHash", None); }
                                }
                            }
                            _write_json(destination, value);
                        }
                        copied = {"size": os.lstat(destination).st_size, "mode": 0o600, "sha256": _hash_file(destination)};
                    } else {
                        origin = os.path.join(snapshot, "messages-snapshot.db") if path == "messages.db" else source;
                        copied = _copy_regular(origin, destination);
                    }
                    tally["bytes"] += copied["size"];
                    if tally["bytes"] > MAX_WORKSPACE_BACKUP_BYTES { _fail("The workspace exceeds the 10 GB backup limit."); }
                    entries.append({"path": path, "type": "file", "size": copied["size"], "mode": copied["mode"], "sha256": copied["sha256"]});
                } else {
                    _fail(f"Cannot back up special or live runtime file: {path}");
                }
            }
        }
        _walk(top, "");
        if tally["links"] { warnings.append(f"{tally['links']} managed skill discovery link(s) were omitted and are recreated by the app."); }
        if tally["deps"] { warnings.append(f"{tally['deps']} installed dependency folder(s) (node_modules) were omitted; reinstall them in the project after restoring."); }
        if tally["work"] { warnings.append(f"{tally['work']} symbolic link(s) in conversation work folders were omitted; what they point to is outside this backup."); }
        counts = _database_counts(os.path.join(snapshot, "data", "messages.db"));
        app_version = options.get("appVersion");
        summary: dict[str, any] = {
            "format": "openmaus.workspace-backup", "version": 1, "id": job["id"], "createdAt": _iso_now(),
            "appVersion": app_version if isinstance(app_version, str) else "unknown",
            "files": len([e for e in entries if e["type"] == "file"]),
            "directories": len([e for e in entries if e["type"] == "directory"]),
            "bytes": tally["bytes"],
            "bots": _count_json_array(os.path.join(snapshot, "data", "bots.json")),
            "groups": _count_json_array(os.path.join(snapshot, "data", "groups.json")),
            "threads": counts["threads"], "messages": counts["messages"],
            "exclusions": list(EXCLUSION_NOTES), "warnings": warnings,
        };
        client_state = options.get("clientState");
        manifest = {
            "summary": summary, "sourceDataDir": _resolve(data_dir),
            "clientState": client_state if client_state is not None else {}, "entries": entries,
        };
        _write_json(os.path.join(snapshot, "manifest.json"), manifest);
        # Validate our own output: serialization must never silently discard
        # metadata or produce a backup the importer cannot read.
        validate_manifest(_private_json(os.path.join(snapshot, "manifest.json")));
        path = os.path.join(job["directory"], "workspace.ombbackup");
        iv = secrets.token_bytes(12);
        header = MAGIC + salt + iv;
        gcm = Gcm(encrypt=True);
        gcm.start(key, iv, header);
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600);
        try {
            _write_all(fd, header);
            sink: any = EncryptingSink(gcm=gcm, fd=fd);
            archive: any = tarfile.open(fileobj=sink, mode="w|", format=tarfile.PAX_FORMAT, bufsize=CHUNK);
            _tar_add_tree(archive, snapshot, "manifest.json");
            _tar_add_tree(archive, snapshot, "data");
            archive.close();
            _write_all(fd, gcm.finish_encrypt());
            os.fsync(fd);
        } finally {
            os.close(fd);
            gcm.close();
        }
        shutil.rmtree(snapshot, ignore_errors=True);
        return {"id": job["id"], "path": path, "summary": summary};
    } except Exception {
        shutil.rmtree(job["directory"], ignore_errors=True);
        raise;
    }
}

# ── manifest validation ────────────────────────────────────────────────────

def _win32_root(path: str) -> bool {
    return bool(re.match(r"^(?:[A-Za-z]:[\\/]?|[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+[\\/]?)\Z", path));
}

def _any_absolute(path: str) -> bool {
    # posix.isAbsolute || win32.isAbsolute
    return path.startswith("/") or path.startswith("\\") or bool(re.match(r"^[A-Za-z]:[\\/]", path));
}

def validate_manifest(value: any) -> dict[str, any] {
    bad = "Invalid or unsupported workspace backup metadata.";
    if not _record(value) or not _record(value.get("summary")) { _fail(bad); }
    summary = value["summary"];
    source = value.get("sourceDataDir");
    if (summary.get("format") != "openmaus.workspace-backup" or summary.get("version") != 1 or isinstance(summary.get("version"), bool)
        or not isinstance(summary.get("id"), str) or ID_RE.match(summary["id"]) is None
        or not isinstance(summary.get("createdAt"), str) or not _date_parses(summary["createdAt"])
        or not isinstance(summary.get("appVersion"), str)
        or not isinstance(source, str) or not _any_absolute(source)
        or _utf16_len(source) > 4096 or "\x00" in source
        or source == "/" or _win32_root(source)
        or any([part == "." or part == ".." for part in source.replace("\\", "/").split("/")])
        or any([k not in MANIFEST_KEYS for k in value.keys()])
        or any([k not in SUMMARY_KEYS for k in summary.keys()])
        or not _record(value.get("clientState"))
        or not all([isinstance(item, str) for item in value["clientState"].values()])
        or not isinstance(value.get("entries"), list)
        or len(value["entries"]) > MAX_WORKSPACE_BACKUP_FILES) {
        _fail(bad);
    }
    if (any([k not in CLIENT_KEYS for k in value["clientState"].keys()])
        or _utf8_len(js_stringify(value["clientState"])) > MAX_CLIENT_STATE_BYTES) {
        _fail("Invalid or oversized workspace client preferences.");
    }
    for k in COUNT_KEYS {
        if not _safe_int(summary.get(k)) or summary[k] < 0 { _fail("Invalid workspace backup summary."); }
    }
    for k in ["exclusions", "warnings"] {
        items = summary.get(k);
        if not isinstance(items, list) or not all([isinstance(item, str) for item in items]) { _fail("Invalid workspace backup summary."); }
    }
    names: dict[str, str] = {};
    total = 0;
    files = 0;
    for raw in value["entries"] {
        if (not _record(raw) or not isinstance(raw.get("path"), str) or not _valid_relative(raw["path"]) or _forbidden_archive_path(raw["path"])
            or any([k not in ENTRY_KEYS for k in raw.keys()])
            or raw.get("type") not in ["file", "directory"]
            or not _safe_int(raw.get("size")) or raw["size"] < 0
            or not _safe_int(raw.get("mode")) or raw["mode"] not in [0o600, 0o700]
            or raw["path"].lower() in names) {
            _fail("Unsafe or duplicate workspace backup entry.");
        }
        names[raw["path"].lower()] = str(raw["type"]);
        if raw["type"] == "file" {
            digest = raw.get("sha256");
            if not isinstance(digest, str) or re.match(r"^[0-9a-f]{64}\Z", digest) is None { _fail("A backup file has no valid checksum."); }
            total += int(raw["size"]);
            files += 1;
        } elif raw["size"] != 0 {
            _fail("A backup directory has an invalid size.");
        }
    }
    if total > MAX_WORKSPACE_BACKUP_BYTES or total != summary["bytes"] or files != summary["files"] or len(names) - files != summary["directories"] {
        _fail("Workspace backup contents do not match their summary or exceed the limit.");
    }
    for path in names.keys() {
        parts = path.split("/");
        for i in range(1, len(parts)) {
            if names.get("/".join(parts[0:i])) != "directory" { _fail("A backup entry has an unsafe parent."); }
        }
    }
    return value;
}

# ── import: authenticate, inspect, extract, validate ───────────────────────

def _decrypt_archive(input_path: str, plaintext: str, password: any) {
    fd = os.open(input_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0));
    gcm: any = None;
    try {
        st = os.fstat(fd);
        if not stat.S_ISREG(st.st_mode) or st.st_size < HEADER_BYTES + TAG_BYTES or st.st_size > MAX_WORKSPACE_BACKUP_UPLOAD_BYTES {
            _fail("Invalid or oversized workspace backup file.");
        }
        header = _pread(fd, HEADER_BYTES, 0);
        tag = _pread(fd, TAG_BYTES, st.st_size - TAG_BYTES);
        if len(header) != HEADER_BYTES or header[0:len(MAGIC)] != MAGIC or len(tag) != TAG_BYTES {
            _fail("This is not a supported encrypted workspace backup.");
        }
        key = _password_key(password, header[len(MAGIC):len(MAGIC) + 16]);
        gcm = Gcm(encrypt=False);
        gcm.start(key, header[len(MAGIC) + 16:], header);
        out = os.open(plaintext, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600);
        authentic = False;
        try {
            position = HEADER_BYTES;
            end = st.st_size - TAG_BYTES;
            while position < end {
                chunk = _pread(fd, min(CHUNK, end - position), position);
                if not chunk { break; }
                position += len(chunk);
                _write_all(out, gcm.update(chunk));
            }
            authentic = position == end and gcm.finish_decrypt(tag);
        } except BackupError {
            authentic = False;
        } finally {
            os.close(out);
        }
        if not authentic {
            _fail("The backup password is incorrect, or the backup file is damaged. Nothing was restored.");
        }
    } finally {
        if gcm is not None { gcm.close(); }
        os.close(fd);
    }
}

glob _TAR_KINDS: dict[bytes, str] = {tarfile.REGTYPE: "File", tarfile.AREGTYPE: "File", tarfile.DIRTYPE: "Directory"};

def _inspect_tar(path: str) -> dict[str, any] {
    with open(path, "rb") as handle {
        signature = handle.read(4);
    }
    # Uncompressed tar only: refuse gzip and zstd before any parser could
    # inflate an authenticated but malicious decompression bomb.
    if (len(signature) >= 2 and signature[0] == 0x1f and signature[1] == 0x8b) or signature == b"\x28\xb5\x2f\xfd" {
        _fail("Compressed payloads are not supported in this workspace backup version.");
    }
    entries: dict[str, any] = {};
    names: set[str] = set();
    state: dict[str, any] = {"bytes": 0, "problem": ""};
    unsafe = "The archive contains unsafe, duplicate or unsupported entries.";
    try {
        archive = tarfile.open(path, mode="r:");
        try {
            for member in archive {
                kind = _TAR_KINDS.get(member.type);
                name = member.name.rstrip("/") if kind == "Directory" else member.name;
                expected_root = name == "manifest.json" or name == "data" or name.startswith("data/");
                if ("\\" in member.name or not _valid_relative(name) or not expected_root or kind is None
                    or name.lower() in names or len(entries) >= MAX_WORKSPACE_BACKUP_FILES + 2
                    or member.size < 0 or (kind == "Directory" and member.size != 0)) {
                    if not state["problem"] { state["problem"] = unsafe; }
                    continue;
                }
                if name == "manifest.json" and (kind != "File" or member.size > MAX_METADATA_BYTES) {
                    if not state["problem"] { state["problem"] = "Invalid backup metadata file."; }
                }
                state["bytes"] += member.size;
                if state["bytes"] > MAX_WORKSPACE_BACKUP_BYTES + MAX_METADATA_BYTES {
                    if not state["problem"] { state["problem"] = "The archive exceeds the extracted size limit."; }
                }
                names.add(name.lower());
                entries[name] = {"type": kind, "size": member.size};
            }
        } finally {
            archive.close();
        }
    } except tarfile.TarError {
        if not state["problem"] { state["problem"] = unsafe; }
    }
    if state["problem"] { _fail(state["problem"]); }
    if (entries.get("data") or {}).get("type") != "Directory" or (entries.get("manifest.json") or {}).get("type") != "File" {
        _fail("The archive has no workspace data or manifest.");
    }
    for name in entries.keys() {
        parts = name.split("/");
        for i in range(1, len(parts)) {
            if (entries.get("/".join(parts[0:i])) or {}).get("type") != "Directory" { _fail("An archive entry has an unsafe parent."); }
        }
    }
    return entries;
}

def _extract_tar(path: str, target: str) {
    # Entries were inspected above: regular files and directories only, all
    # under manifest.json or data/, parents declared first or created here.
    archive = tarfile.open(path, mode="r:");
    try {
        for member in archive {
            name = member.name.rstrip("/");
            destination = os.path.join(target, name.replace("/", os.sep));
            if member.type == tarfile.DIRTYPE {
                os.makedirs(destination, mode=0o700, exist_ok=True);
                continue;
            }
            os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True);
            source: any = archive.extractfile(member);
            out = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600);
            try {
                while True {
                    chunk = source.read(CHUNK);
                    if not chunk { break; }
                    _write_all(out, chunk);
                }
            } finally {
                os.close(out);
                source.close();
            }
        }
    } finally {
        archive.close();
    }
}

def _validate_staged(directory: str, expected: any = None) -> dict[str, any] {
    manifest = validate_manifest(_private_json(os.path.join(directory, "manifest.json")));
    if expected is not None and len(expected) != len(manifest["entries"]) + 2 {
        _fail("Archive entries do not match the backup manifest.");
    }
    declared: set[str] = set([e["path"] for e in manifest["entries"]]);
    def _look(base: str, prefix: str) {
        for name in os.listdir(base) {
            path = f"{prefix}/{name}" if prefix else name;
            if path not in declared { _fail("Staged workspace contains files absent from its manifest."); }
            st = os.lstat(os.path.join(base, name));
            if stat.S_ISLNK(st.st_mode) { _fail("Staged workspace contains a symbolic link."); }
            if stat.S_ISDIR(st.st_mode) { _look(os.path.join(base, name), path); }
        }
    }
    _look(os.path.join(directory, "data"), "");
    for item in manifest["entries"] {
        path = os.path.join(directory, "data", item["path"].replace("/", os.sep));
        st = os.lstat(path);
        mismatch = stat.S_ISLNK(st.st_mode);
        if item["type"] == "file" {
            mismatch = mismatch or not stat.S_ISREG(st.st_mode) or st.st_size != item["size"];
        } else {
            mismatch = mismatch or not stat.S_ISDIR(st.st_mode);
        }
        if mismatch { _fail("Staged workspace files do not match the backup manifest."); }
        if expected is not None {
            archived = expected.get("data/" + item["path"]);
            want = "File" if item["type"] == "file" else "Directory";
            if archived is None or archived["type"] != want or archived["size"] != item["size"] {
                _fail("Archive contents do not match the backup manifest.");
            }
        }
        if item["type"] == "file" and _hash_file(path) != item["sha256"] { _fail("A workspace backup file failed its checksum."); }
        os.chmod(path, int(item["mode"]));
    }
    data = os.path.join(directory, "data");
    if _count_json_array(os.path.join(data, "bots.json")) != manifest["summary"]["bots"] or _count_json_array(os.path.join(data, "groups.json")) != manifest["summary"]["groups"] {
        _fail("The backup roster does not match its summary.");
    }
    if os.path.exists(os.path.join(data, "config.json")) {
        config = _private_json(os.path.join(data, "config.json"));
        if js_stringify(config) != js_stringify(_portable_config(config)) {
            _fail("Workspace backup contains non-portable connection settings.");
        }
    }
    if os.path.exists(os.path.join(data, "webhooks.json")) {
        value = _private_json(os.path.join(data, "webhooks.json"));
        leaked = False;
        if _record(value) and isinstance(value.get("webhooks"), list) {
            for webhook in value["webhooks"] {
                if _record(webhook) and "secretHash" in webhook { leaked = True; }
            }
        }
        if not _record(value) or leaked { _fail("Workspace backup contains webhook credentials."); }
    }
    counts = _database_counts(os.path.join(data, "messages.db"));
    if counts["messages"] != manifest["summary"]["messages"] or counts["threads"] != manifest["summary"]["threads"] {
        _fail("The message database does not match the backup summary.");
    }
    return manifest;
}

glob _SEMVER: any = re.compile(r"^([0-9]+)\.([0-9]+)\.([0-9]+)(?:[-+].*)?\Z", re.DOTALL);

def _semver(version: str) -> any {
    m = _SEMVER.match(version);
    return [int(m.group(1)), int(m.group(2)), int(m.group(3))] if m is not None else None;
}

def wb_stage(data_dir: str, archive_path: str, password: any, current_app_version: any = None) -> dict[str, any] {
    job = _new_job(data_dir);
    plaintext = os.path.join(job["directory"], "archive.tar");
    try {
        # No extraction, parser or metadata processing until GCM has
        # authenticated the complete encrypted file.
        _decrypt_archive(archive_path, plaintext, password);
        expected = _inspect_tar(plaintext);
        staged = os.path.join(job["directory"], "staged");
        _folder(staged);
        _extract_tar(plaintext, staged);
        manifest = _validate_staged(staged, expected);
        mine = _semver(manifest["summary"]["appVersion"]);
        current = _semver(current_app_version if isinstance(current_app_version, str) else "");
        if mine is not None and current is not None {
            for i in range(3) {
                if mine[i] > current[i] { _fail("This backup was made by a newer OpenMausBot version. Update the app before restoring it."); }
                if mine[i] < current[i] { break; }
            }
        }
        os.unlink(plaintext);
        _write_json(os.path.join(job["directory"], "ready.json"), {"id": job["id"], "summary": manifest["summary"]});
        return {"id": job["id"], "summary": manifest["summary"]};
    } except Exception {
        shutil.rmtree(job["directory"], ignore_errors=True);
        raise;
    }
}

def wb_read_staged(data_dir: str, id: any) -> dict[str, any] {
    directory = _job_path(data_dir, id);
    ready = _private_json(os.path.join(directory, "ready.json"));
    if not _record(ready) or ready.get("id") != id { _fail("This workspace backup is not ready to restore."); }
    manifest = validate_manifest(_private_json(os.path.join(directory, "staged", "manifest.json")));
    out: dict[str, any] = {"id": id};
    out.update(_private_metadata(manifest));
    return out;
}

def wb_commit(data_dir: str, id: any) -> dict[str, any] {
    top = _backup_root(data_dir);
    if os.path.exists(os.path.join(top, "pending-restore.json")) { _fail("A workspace restore is already waiting for restart."); }
    if os.path.exists(os.path.join(top, f"safety-{id}")) {
        _fail("This restore was already attempted. Preview the backup again to create a fresh restore attempt.");
    }
    metadata = wb_read_staged(data_dir, id);
    manifest = _validate_staged(os.path.join(_job_path(data_dir, id), "staged"));
    # Discover adaptation errors before persisting a restart request. A
    # broken legacy transcript or scheduler file must not trap later boots.
    _prepare_restore(data_dir, id, manifest);
    _write_json(os.path.join(top, "pending-restore.json"), {"id": id});
    return {"id": id, "restartRequired": True, "summary": metadata["summary"]};
}

def wb_read_pending(data_dir: str) -> any {
    top = _backup_root(data_dir);
    path = os.path.join(top, "pending-restore.json");
    if not os.path.exists(path) { return None; }
    pending = _private_json(path);
    if not _record(pending) or not isinstance(pending.get("id"), str) { _fail("Invalid pending workspace restore."); }
    return wb_read_staged(data_dir, pending["id"]);
}

# ── restore journal and rollback ───────────────────────────────────────────

def _read_journal(path: str) -> dict[str, any] {
    raw = _private_json(path);
    if (not _record(raw) or not isinstance(raw.get("id"), str) or ID_RE.match(raw["id"]) is None
        or raw.get("phase") not in ["applying", "committed", "rolled-back"]) {
        _fail("Invalid restore recovery journal. Original data was preserved; recovery needs attention.");
    }
    for k in ["existing", "incoming"] {
        names = raw.get(k);
        good = isinstance(names, list);
        if good {
            for name in names {
                if not isinstance(name, str) or not _valid_relative(name) or "/" in name or _preserved(name) { good = False; }
            }
            good = good and len(set(names)) == len(names);
        }
        if not good { _fail("Invalid restore recovery paths."); }
    }
    return raw;
}

def _rollback(data_dir: str, journal: dict[str, any]) {
    stage = os.path.join(_job_path(data_dir, journal["id"]), "apply", "data");
    saved = os.path.join(_backup_root(data_dir), f"safety-{journal['id']}", "data");
    # Existence on both sides resolves a crash between rename and journal
    # I/O. New data is moved back, never deleted; originals stay recoverable.
    for name in journal["incoming"] {
        live = os.path.join(data_dir, name);
        staged = os.path.join(stage, name);
        original_moved = name not in journal["existing"] or _entry_exists(os.path.join(saved, name));
        if original_moved and not _entry_exists(staged) and _entry_exists(live) { os.rename(live, staged); }
    }
    for name in journal["existing"] {
        original = os.path.join(saved, name);
        if not _entry_exists(original) { continue; }
        live = os.path.join(data_dir, name);
        if _entry_exists(live) { _fail("Restore rollback found conflicting files. Both copies are preserved for recovery."); }
        os.rename(original, live);
    }
    top = _backup_root(data_dir);
    previous_receipt = os.path.join(top, f"safety-{journal['id']}", "previous-restore.json");
    last = os.path.join(top, "last-restore.json");
    if os.path.exists(previous_receipt) {
        _write_json(last, _private_json(previous_receipt));
    } elif os.path.exists(last) {
        value = _private_json(last);
        if _record(value) and value.get("id") == journal["id"] { os.unlink(last); }
    }
}

def _pread(fd: int, size: int, offset: int) -> bytes {
    os.lseek(fd, offset, os.SEEK_SET);
    parts: list[bytes] = [];
    remaining = size;
    while remaining > 0 {
        chunk = os.read(fd, remaining);
        if not chunk { break; }
        parts.append(chunk);
        remaining -= len(chunk);
    }
    return b"".join(parts);
}

# ── transcript attachments (src/lib/composer-attachments.ts) ───────────────

glob _COMMONMARK_BLOCK_TAGS: str = "|".join([
    "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
    "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
    "footer", "form", "frame", "frameset", "h[1-6]", "head", "header", "hr", "html", "iframe", "legend",
    "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p",
    "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title",
    "tr", "track", "ul",
]);
glob _TYPE_1: any = re.compile(r"^ {0,3}<(script|pre|style|textarea)(?:[\t ]|>|\Z)", re.IGNORECASE);
glob _TYPE_6: any = re.compile(r"^ {0,3}</?(?:" + _COMMONMARK_BLOCK_TAGS + r")(?:[\t ]|/?>|\Z)", re.IGNORECASE);
glob _ATTR_NAME: str = r"[A-Za-z_:][A-Za-z0-9_.:-]*";
glob _ATTR_VALUE: str = "(?:[^\\s\"'=<>`]+|'[^']*'|\"[^\"]*\")";
glob _ATTRIBUTE: str = r"(?:[\t ]+" + _ATTR_NAME + r"(?:[\t ]*=[\t ]*" + _ATTR_VALUE + r")?)";
glob _TYPE_7: any = re.compile(r"^ {0,3}(?:<[A-Za-z][A-Za-z0-9-]*" + _ATTRIBUTE + r"*[\t ]*/?>|</[A-Za-z][A-Za-z0-9-]*[\t ]*>)[\t ]*\Z");
glob _ATTACHMENT_TAG: any = re.compile(r"^<attached-(image|file)[\t ]+path=\"([^\"\r\n]*)\"(?:[\t ]+name=\"([^\"\r\n]*)\")?[\t ]*/>[\t ]*\Z");
glob _PASTED_OPEN: any = re.compile(r"^ {0,3}<pasted-text(?:[\t ]+index=\"[0-9]+\")?[\t ]*>[\t ]*\Z", re.IGNORECASE);
glob _PASTED_CLOSE: any = re.compile(r"^[\t ]*</pasted-text>[\t ]*\Z", re.IGNORECASE);
glob _BLANK: any = re.compile(r"^[\t ]*\Z");
glob _ATTACHMENT_PATH_ATTR: any = re.compile(r"(<attached-(?:image|file)[\t ]+path=\")([^\"\r\n]*)(\")");
glob _ENTITY: any = re.compile(r"&(quot|lt|gt|amp);|&#(9|10|13);");

def escape_attribute(value: str) -> str {
    return (value.replace("&", "&amp;").replace("\"", "&quot;").replace("<", "&lt;").replace(">", "&gt;")
        .replace("\t", "&#9;").replace("\r", "&#13;").replace("\n", "&#10;"));
}

def _decode_entity(m: any) -> str {
    named = m.group(1);
    numeric = m.group(2);
    if numeric == "9" { return "\t"; }
    if numeric == "10" { return "\n"; }
    if numeric == "13" { return "\r"; }
    if named == "quot" { return "\""; }
    if named == "lt" { return "<"; }
    if named == "gt" { return ">"; }
    if named == "amp" { return "&"; }
    return m.group(0);
}

def _decode_attribute(value: str) -> str {
    return _ENTITY.sub(_decode_entity, value);
}

def _fence_marker(line: str) -> any {
    index = 0;
    while index < len(line) and index < 4 and line[index] == " " { index += 1; }
    if index > 3 or index >= len(line) { return None; }
    marker = line[index];
    if marker != "`" and marker != "~" { return None; }
    start = index;
    while index < len(line) and line[index] == marker { index += 1; }
    if index - start < 3 { return None; }
    return {"marker": marker, "length": index - start, "remainder": line[index:]};
}

def _block_starting(line: str) -> any {
    lower = line.lower();
    comment = lower.find("<!--");
    if comment >= 0 and lower.find("-->", comment + 4) < 0 { return {"kind": "untilToken", "token": "-->"}; }
    m = re.match(r"^ {0,3}(.*)\Z", line, re.DOTALL);
    if m is None { return None; }
    content = m.group(1);
    lower_content = content.lower();
    if re.match(r"^<pasted-text(?:[\t >]|\Z)", content, re.IGNORECASE) {
        return None if "</pasted-text>" in lower_content else {"kind": "untilToken", "token": "</pasted-text>"};
    }
    one = _TYPE_1.match(line);
    if one is not None {
        token = "</" + one.group(1).lower() + ">";
        return None if token in lower else {"kind": "untilToken", "token": token};
    }
    if lower_content.find("<?") == 0 {
        return None if lower_content.find("?>", 2) >= 0 else {"kind": "untilToken", "token": "?>"};
    }
    if lower_content.find("<![cdata[") == 0 {
        return None if lower_content.find("]]>", 9) >= 0 else {"kind": "untilToken", "token": "]]>"};
    }
    if re.match(r"^<![A-Za-z]", content) {
        return None if content.find(">", 2) >= 0 else {"kind": "untilToken", "token": ">"};
    }
    if _TYPE_6.search(line) or _TYPE_7.search(line) { return {"kind": "untilBlank"}; }
    return None;
}

def split_transcript_attachments(text: str, trim_display: bool = True, hide_paste_wrappers: bool = True) -> dict[str, any] {
    images: list[any] = [];
    files: list[any] = [];
    display: list[str] = [];
    fence: any = None;
    block: any = None;
    cursor = 0;
    while cursor < len(text) {
        newline = text.find("\n", cursor);
        line_end = newline if newline >= 0 else len(text);
        whole_end = newline + 1 if newline >= 0 else len(text);
        raw_line = text[cursor:line_end];
        line = raw_line[0:-1] if raw_line.endswith("\r") else raw_line;
        marker = _fence_marker(line);
        consumed = False;
        if fence is not None {
            if marker is not None and marker["marker"] == fence["marker"] and marker["length"] >= fence["length"] and _BLANK.match(marker["remainder"]) {
                fence = None;
            }
        } elif block is not None {
            if block["kind"] == "untilBlank" {
                if _BLANK.match(line) { block = None; }
            } elif block["token"] in line.lower() {
                if block.get("hidden") and _PASTED_CLOSE.match(line) { consumed = True; }
                block = None;
            }
        } elif marker is not None {
            fence = {"marker": marker["marker"], "length": marker["length"]};
        } else {
            tag = _ATTACHMENT_TAG.match(line);
            if tag is not None {
                path = _decode_attribute(tag.group(2));
                if path {
                    if tag.group(1) == "image" { images.append({"path": path}); }
                    else { files.append({"path": path}); }
                    consumed = True;
                }
            }
            if not consumed {
                block = _block_starting(line);
                if hide_paste_wrappers and block is not None and block["kind"] == "untilToken" and block["token"] == "</pasted-text>" and _PASTED_OPEN.match(line) {
                    block = {"kind": "untilToken", "token": "</pasted-text>", "hidden": True};
                    consumed = True;
                }
            }
        }
        if not consumed { display.append(text[cursor:whole_end]); }
        cursor = whole_end;
    }
    shown = "".join(display);
    return {"display": shown.strip() if trim_display else shown, "images": images, "files": files};
}

# ── top-level Markdown HTML (the mdast `fromMarkdown` query rebaseMessage
# makes): HTML flow blocks at the document's top level, and inline HTML
# that is a direct child of a top-level paragraph, starting at column 1.
# A CommonMark block scanner for exactly that question - containers
# (block quotes, lists) are tracked only to know what is NOT top level.

glob _THEMATIC: any = re.compile(r"^ {0,3}(?:(?:\*[\t ]*){3,}|(?:-[\t ]*){3,}|(?:_[\t ]*){3,})\Z");
glob _ATX: any = re.compile(r"^ {0,3}#{1,6}(?:[\t ]|\Z)");
glob _SETEXT: any = re.compile(r"^ {0,3}(?:=+|-+)[\t ]*\Z");
glob _BULLET: any = re.compile(r"^( {0,3})([-+*])([\t ]+|\Z)(.*)\Z", re.DOTALL);
glob _ORDERED: any = re.compile(r"^( {0,3})([0-9]{1,9})([.)])([\t ]+|\Z)(.*)\Z", re.DOTALL);
glob _QUOTE: any = re.compile(r"^ {0,3}>");

def _indent_of(line: str) -> int {
    col = 0;
    for ch in line {
        if ch == " " { col += 1; }
        elif ch == "\t" { col += 4 - (col % 4); }
        else { break; }
    }
    return col;
}

def _strip_columns(line: str, cols: int) -> str {
    col = 0;
    i = 0;
    while i < len(line) and col < cols {
        if line[i] == " " { col += 1; }
        elif line[i] == "\t" { col += 4 - (col % 4); }
        else { break; }
        i += 1;
    }
    return line[i:];
}

def _html_start(line: str, in_paragraph: bool) -> any {
    # CommonMark HTML block start conditions 1-7; 7 cannot interrupt a paragraph.
    if _indent_of(line) > 3 { return None; }
    content = line.lstrip(" ");
    lower = content.lower();
    one = _TYPE_1.match(line);
    if one is not None { return {"end": "</" + one.group(1).lower() + ">", "kind": 1}; }
    if lower.startswith("<!--") { return {"end": "-->", "kind": 2}; }
    if lower.startswith("<?") { return {"end": "?>", "kind": 3}; }
    if lower.startswith("<![cdata[") { return {"end": "]]>", "kind": 5}; }
    if re.match(r"^<![A-Za-z]", content) { return {"end": ">", "kind": 4}; }
    if _TYPE_6.search(line) { return {"end": None, "kind": 6}; }
    if not in_paragraph and _TYPE_7.search(line) { return {"end": None, "kind": 7}; }
    return None;
}

def _list_marker(line: str, in_paragraph: bool) -> any {
    b = _BULLET.match(line);
    if b is not None and not _THEMATIC.match(line) {
        rest = b.group(4);
        if in_paragraph and not rest.strip() { return None; }
        spaces = _indent_of(b.group(3)) if rest.strip() else 0;
        pad = spaces if 1 <= spaces and spaces <= 4 else 1;
        return {"kind": "bullet:" + b.group(2), "content": len(b.group(1)) + 1 + pad, "rest": rest};
    }
    o = _ORDERED.match(line);
    if o is not None {
        rest = o.group(5);
        if in_paragraph and (not rest.strip() or int(o.group(2)) != 1) { return None; }
        spaces = _indent_of(o.group(4)) if rest.strip() else 0;
        pad = spaces if 1 <= spaces and spaces <= 4 else 1;
        return {"kind": "ordered:" + o.group(3), "content": len(o.group(1)) + len(o.group(2)) + 1 + pad, "rest": rest};
    }
    return None;
}

def _interrupts_paragraph(line: str) -> bool {
    if _BLANK.match(line) { return True; }
    if _indent_of(line) > 3 { return False; }
    return (_THEMATIC.match(line) is not None or _ATX.match(line) is not None or _fence_marker(line) is not None
        or _QUOTE.match(line) is not None or _html_start(line, True) is not None or _list_marker(line, True) is not None);
}

def _lazy_line(line: str) -> bool {
    # Paragraph continuation inside a quote or list item. micromark (unlike
    # commonmark.js) lets any HTML flow start - kind 7 included - close the
    # containers rather than continue their paragraph lazily.
    return not _interrupts_paragraph(line) and _html_start(line, False) is None;
}

def _code_spans(text: str) -> list[any] {
    spans: list[any] = [];
    i = 0;
    while i < len(text) {
        if text[i] == "\\" { i += 2; continue; }
        if text[i] != "`" { i += 1; continue; }
        start = i;
        while i < len(text) and text[i] == "`" { i += 1; }
        width = i - start;
        j = i;
        closed = -1;
        while j < len(text) {
            if text[j] != "`" { j += 1; continue; }
            run = j;
            while j < len(text) and text[j] == "`" { j += 1; }
            if j - run == width {
                closed = j;
                break;
            }
        }
        if closed >= 0 {
            spans.append([start, closed]);
            i = closed;
        }
    }
    return spans;
}

def _top_level_html(text: str) -> list[any] {
    # [{start, end, value}] in document order, offsets into `text`.
    lines: list[any] = [];
    cursor = 0;
    while cursor <= len(text) {
        newline = text.find("\n", cursor);
        end = newline if newline >= 0 else len(text);
        raw = text[cursor:end];
        content_end = end - 1 if raw.endswith("\r") else end;
        lines.append({"start": cursor, "end": content_end, "text": text[cursor:content_end]});
        if newline < 0 { break; }
        cursor = newline + 1;
    }
    found: list[any] = [];
    st: dict[str, any] = {"mode": None, "para": [], "inner_fence": None, "lazy": False};
    def _close_paragraph(heading: bool) {
        para = st["para"];
        st["para"] = [];
        if heading or len(para) < 2 { return; }
        first = para[0]["start"];
        last = para[-1]["end"];
        spans = _code_spans(text[first:last]);
        for line in para[1:] {
            if _indent_of(line["text"]) != 0 or not line["text"].startswith("<") { continue; }
            tag = _ATTACHMENT_TAG.match(line["text"]);
            if tag is None { continue; }
            offset = line["start"] - first;
            if any([s[0] <= offset and offset < s[1] for s in spans]) { continue; }
            value = line["text"].rstrip("\t ");
            found.append({"start": line["start"], "end": line["start"] + len(value), "value": value});
        }
    }
    def _container_line(inner: str) {
        # Track fences inside a container so lazy continuation stays honest.
        marker = _fence_marker(inner);
        fence = st["inner_fence"];
        if fence is not None {
            if marker is not None and marker["marker"] == fence["marker"] and marker["length"] >= fence["length"] and _BLANK.match(marker["remainder"]) {
                st["inner_fence"] = None;
            }
            st["lazy"] = False;
        } elif marker is not None {
            st["inner_fence"] = {"marker": marker["marker"], "length": marker["length"]};
            st["lazy"] = False;
        } else {
            st["lazy"] = not _BLANK.match(inner) and _indent_of(inner) < 4 and not _interrupts_paragraph(inner);
        }
    }
    i = 0;
    while i < len(lines) {
        line = lines[i];
        content = line["text"];
        blank = _BLANK.match(content) is not None;
        mode = st["mode"];
        if mode == "fence" {
            marker = _fence_marker(content);
            fence = st["fence"];
            if marker is not None and marker["marker"] == fence["marker"] and marker["length"] >= fence["length"] and _BLANK.match(marker["remainder"]) {
                st["mode"] = None;
            }
            i += 1;
            continue;
        }
        if mode == "html" {
            block = st["html"];
            if block["end"] is None {
                if blank {
                    _finish_html(found, text, block, lines[i - 1]["end"]);
                    st["mode"] = None;
                }
                i += 1;
                continue;
            }
            if block["end"] in content.lower() {
                _finish_html(found, text, block, line["end"]);
                st["mode"] = None;
            }
            i += 1;
            continue;
        }
        if mode == "icode" {
            if blank or _indent_of(content) >= 4 {
                i += 1;
                continue;
            }
            st["mode"] = None;
            continue;
        }
        if mode == "quote" {
            if _QUOTE.match(content) {
                inner = re.sub(r"^ {0,3}> ?", "", content, count=1);
                _container_line(inner);
                i += 1;
                continue;
            }
            if not blank and st["lazy"] and _lazy_line(content) {
                i += 1;
                continue;
            }
            st["mode"] = None;
            if blank {
                i += 1;
                continue;
            }
            continue;
        }
        if mode == "list" {
            if blank {
                st["after_blank"] = True;
                st["lazy"] = False;
                i += 1;
                continue;
            }
            if _indent_of(content) >= st["content"] {
                _container_line(_strip_columns(content, st["content"]));
                st["after_blank"] = False;
                i += 1;
                continue;
            }
            item = _list_marker(content, False);
            if item is not None and item["kind"] == st["kind"] and st["inner_fence"] is None {
                st["content"] = item["content"];
                st["after_blank"] = False;
                _container_line(item["rest"]);
                i += 1;
                continue;
            }
            if not st["after_blank"] and st["lazy"] and _lazy_line(content) {
                i += 1;
                continue;
            }
            st["mode"] = None;
            st["inner_fence"] = None;
            continue;
        }
        if mode == "paragraph" {
            if blank {
                _close_paragraph(False);
                st["mode"] = None;
                i += 1;
                continue;
            }
            if _indent_of(content) <= 3 and _SETEXT.match(content) {
                _close_paragraph(True);
                st["mode"] = None;
                i += 1;
                continue;
            }
            if not _interrupts_paragraph(content) {
                st["para"].append(line);
                i += 1;
                continue;
            }
            _close_paragraph(False);
            st["mode"] = None;
        }
        # Block start at the top level.
        if blank {
            i += 1;
            continue;
        }
        if _indent_of(content) >= 4 {
            st["mode"] = "icode";
            i += 1;
            continue;
        }
        if _THEMATIC.match(content) or _ATX.match(content) {
            i += 1;
            continue;
        }
        marker = _fence_marker(content);
        if marker is not None and not (marker["marker"] == "`" and "`" in marker["remainder"]) {
            st["mode"] = "fence";
            st["fence"] = {"marker": marker["marker"], "length": marker["length"]};
            i += 1;
            continue;
        }
        if _QUOTE.match(content) {
            st["mode"] = "quote";
            st["inner_fence"] = None;
            _container_line(re.sub(r"^ {0,3}> ?", "", content, count=1));
            i += 1;
            continue;
        }
        html = _html_start(content, False);
        if html is not None {
            block = {"start": line["start"], "end": html["end"], "column1": True};
            if html["end"] is not None and html["end"] in content.lower()[2:] {
                _finish_html(found, text, block, line["end"]);
                i += 1;
                continue;
            }
            st["mode"] = "html";
            st["html"] = block;
            i += 1;
            continue;
        }
        item = _list_marker(content, False);
        if item is not None {
            st["mode"] = "list";
            st["kind"] = item["kind"];
            st["content"] = item["content"];
            st["after_blank"] = False;
            st["inner_fence"] = None;
            _container_line(item["rest"]);
            i += 1;
            continue;
        }
        st["mode"] = "paragraph";
        st["para"] = [line];
        i += 1;
    }
    if st["mode"] == "paragraph" { _close_paragraph(False); }
    if st["mode"] == "html" { _finish_html(found, text, st["html"], lines[-1]["end"]); }
    found.sort(key=_by_start);
    return found;
}

def _by_start(item: dict[str, any]) -> int {
    return item["start"];
}

def _finish_html(found: list[any], text: str, block: dict[str, any], end: int) {
    if not block["column1"] { return; }
    value = text[block["start"]:end];
    # mdast's flow html value excludes the final line ending but keeps a
    # trailing blank-free line as written.
    found.append({"start": block["start"], "end": end, "value": value});
}

# ── path rebasing ──────────────────────────────────────────────────────────

def rebase_path(value: str, source: str, destination: str) -> str {
    # Explicit old-root prefix, not a free-form text replacement.
    normalized = value.replace("\\", "/");
    original = source.replace("\\", "/");
    if original.endswith("/") { original = original[0:-1]; }
    if normalized != original and not normalized.startswith(original + "/") { return value; }
    suffix = normalized[len(original):];
    if suffix.startswith("/") { suffix = suffix[1:]; }
    if suffix and not _valid_relative(suffix) { return value; }
    return os.path.normpath(os.path.join(destination, suffix)) if suffix else destination;
}

def rebase_fields(value: any, source: str, destination: str) {
    if isinstance(value, list) {
        for item in value { rebase_fields(item, source, destination); }
    } elif _record(value) {
        for key in list(value.keys()) {
            item = value[key];
            if key in PATH_KEYS and isinstance(item, str) {
                value[key] = rebase_path(item, source, destination);
            } elif isinstance(item, (dict, list)) {
                rebase_fields(item, source, destination);
            }
        }
    }
}

def rebase_message(message: any, source: str, destination: str) {
    if not _record(message) { return; }
    for field in ["attachments", "images", "fileAttachments", "file", "card"] {
        rebase_fields(message.get(field), source, destination);
    }
    if not isinstance(message.get("text"), str) { return; }
    # Only top-level attachment markup is rewritten. Quoted prose, code
    # fences, pasted text and other mentions of the old path stay exact.
    text = message["text"];
    edits: list[any] = [];
    for node in _top_level_html(text) {
        line_end = text.find("\n", node["end"]);
        if text[node["end"]:(line_end if line_end >= 0 else len(text))].strip() { continue; }
        parsed = split_transcript_attachments(node["value"], False);
        attachments = parsed["images"] + parsed["files"];
        if parsed["display"].strip() or not attachments { continue; }
        def _swap(m: any) -> str {
            for attachment in attachments {
                if escape_attribute(attachment["path"]) == m.group(2) {
                    return m.group(1) + escape_attribute(rebase_path(attachment["path"], source, destination)) + m.group(3);
                }
            }
            return m.group(0);
        }
        updated = _ATTACHMENT_PATH_ATTR.sub(_swap, node["value"]);
        if updated != node["value"] { edits.append({"from": node["start"], "to": node["end"], "text": updated}); }
    }
    edits.reverse();
    for edit in edits { text = text[0:edit["from"]] + edit["text"] + text[edit["to"]:]; }
    message["text"] = text;
}

# ── restore ────────────────────────────────────────────────────────────────

glob _MESSAGES_JSON: any = re.compile(r"^messages-[^/]+\.json\Z");

def _change_json(prepared: str, name: str, change: any) {
    path = os.path.join(prepared, name.replace("/", os.sep));
    if not os.path.exists(path) { return; }
    value = _private_json(path);
    change(value);
    _write_json(path, value);
}

def _now_ms -> int {
    return int(time.time() * 1000);
}

def _prepare_restore(data_dir: str, id: str, manifest: dict[str, any]) -> str {
    _assert_local_auth_outside_snapshot(data_dir);
    job = _job_path(data_dir, id);
    prepared = os.path.join(job, "apply", "data");
    if os.path.exists(os.path.join(job, "apply")) { shutil.rmtree(os.path.join(job, "apply"), ignore_errors=True); }
    _folder(prepared);
    source_dir = manifest["sourceDataDir"];
    destination_dir = _resolve(data_dir);
    # The authenticated staging tree stays intact for reinspection and
    # recovery; only this installation copy is adapted. An archive from a
    # release that exported per-turn hook tokens still restores, without
    # installing the dead tokens.
    installed = [e for e in manifest["entries"] if not ephemeral_workspace_token_path(e["path"])];
    for item in installed {
        if item["type"] == "directory" { _folder(os.path.join(prepared, item["path"].replace("/", os.sep))); }
    }
    for item in installed {
        if item["type"] == "file" {
            _copy_regular(os.path.join(job, "staged", "data", item["path"].replace("/", os.sep)), os.path.join(prepared, item["path"].replace("/", os.sep)));
        }
    }
    def _rebase(value: any) { rebase_fields(value, source_dir, destination_dir); }
    for name in ["bots.json", "groups.json", "config.json", "routines.json", "calendar-calls.json"] {
        _change_json(prepared, name, _rebase);
    }
    # Voice configuration stays with the destination: imported per-agent ids
    # belong to the source provider's catalog.
    def _drop_voice(value: any) {
        if not isinstance(value, list) { _fail("Invalid bot definitions in workspace backup."); }
        for bot in value {
            if _record(bot) { bot.pop("voice", None); }
        }
    }
    _change_json(prepared, "bots.json", _drop_voice);
    # Never install source connection settings: destination keys, endpoints,
    # driver environments and MCP configuration stay paired and unchanged.
    old_config = os.path.join(data_dir, "config.json");
    new_config = os.path.join(prepared, "config.json");
    if os.path.exists(old_config) or os.path.exists(new_config) {
        portable = _private_json(new_config) if os.path.exists(new_config) else {};
        destination = _private_json(old_config) if os.path.exists(old_config) else {};
        _write_json(new_config, _restored_config(portable, destination));
    }
    # Browser authentication lives beside ordinary VM files: copy only the
    # destination's excluded subtrees into the install copy, so they join
    # the same top-level swap and crash rollback.
    browser_homes: list[str] = ["vm-home"];
    vm_homes = os.path.join(data_dir, "vm-homes");
    if _entry_exists(vm_homes) {
        if not stat.S_ISDIR(os.lstat(vm_homes).st_mode) { _fail("Stop managed desktops and repair the VM home directory before restoring."); }
        for name in os.listdir(vm_homes) {
            if _valid_relative(name) { browser_homes.append(f"vm-homes/{name}"); }
        }
    }
    for home in browser_homes {
        home_path = os.path.join(data_dir, home.replace("/", os.sep));
        if not _entry_exists(home_path) { continue; }
        if not stat.S_ISDIR(os.lstat(home_path).st_mode) { _fail("Stop managed desktops and repair the VM home directory before restoring."); }
        source = os.path.join(home_path, ".browser-profiles");
        if not _entry_exists(source) { continue; }
        _folder(os.path.join(prepared, home.replace("/", os.sep)));
        shutil.copytree(source, os.path.join(prepared, home.replace("/", os.sep), ".browser-profiles"), symlinks=True);
    }
    def _pause_routines(value: any) {
        if not _record(value) { _fail("Invalid routine definitions in workspace backup."); }
        if isinstance(value.get("routines"), list) {
            for routine in value["routines"] {
                if _record(routine) { routine["enabled"] = False; }
            }
        }
        if isinstance(value.get("runs"), list) {
            for run in value["runs"] {
                if _record(run) and str(run.get("status")) in ["queued", "running", "waiting"] {
                    run["status"] = "failed";
                    run["error"] = "This queued or active run was not resumed after workspace restore.";
                    run["finishedAt"] = _now_ms();
                    if run.get("target") == "room-goal" { run["goalStatus"] = "failed"; }
                }
            }
        }
    }
    _change_json(prepared, "routines.json", _pause_routines);
    def _pause_webhooks(value: any) {
        if not _record(value) { _fail("Invalid webhook definitions in workspace backup."); }
        current = os.path.join(data_dir, "webhooks.json");
        existing = _private_json(current) if os.path.exists(current) else {};
        old_hooks = existing["webhooks"] if _record(existing) and isinstance(existing.get("webhooks"), list) else [];
        if isinstance(value.get("webhooks"), list) {
            for webhook in value["webhooks"] {
                if not _record(webhook) { continue; }
                webhook["enabled"] = False;
                webhook["verificationPending"] = False;
                previous: any = None;
                for old in old_hooks {
                    if previous is None and _record(old) and old.get("id") == webhook.get("id") and old.get("endpointId") == webhook.get("endpointId") {
                        previous = old;
                    }
                }
                # Unknown random hashes cannot authenticate a caller: a
                # migrated hook needs an explicit secret rotation.
                kept = previous.get("secretHash") if _record(previous) else None;
                if isinstance(kept, str) and re.match(r"^[a-f0-9]{64}\Z", kept) {
                    webhook["secretHash"] = kept;
                } else {
                    webhook["secretHash"] = secrets.token_hex(32);
                }
            }
        }
    }
    _change_json(prepared, "webhooks.json", _pause_webhooks);
    def _pause_calendar(value: any) {
        if not _record(value) { _fail("Invalid calendar definitions in workspace backup."); }
        if isinstance(value.get("calls"), list) {
            for call in value["calls"] {
                if _record(call) { call["nextRunAt"] = None; }
            }
        }
    }
    _change_json(prepared, "calendar-calls.json", _pause_calendar);
    if os.path.exists(os.path.join(prepared, "delegations.json")) { _write_json(os.path.join(prepared, "delegations.json"), {}); }
    if os.path.exists(os.path.join(prepared, "browser-cleanups.json")) { _write_json(os.path.join(prepared, "browser-cleanups.json"), []); }
    def _rebase_transcript(value: any) {
        if isinstance(value, list) {
            for message in value { rebase_message(message, source_dir, destination_dir); }
        } elif _record(value) and isinstance(value.get("messages"), list) {
            for message in value["messages"] { rebase_message(message, source_dir, destination_dir); }
        }
    }
    for item in manifest["entries"] {
        if _MESSAGES_JSON.match(item["path"]) { _change_json(prepared, item["path"], _rebase_transcript); }
    }
    db_path = os.path.join(prepared, "messages.db");
    if os.path.exists(db_path) { _adapt_messages_db(db_path, source_dir, destination_dir); }
    return prepared;
}

def _adapt_messages_db(db_path: str, source_dir: str, destination_dir: str) {
    con = sqlite3.connect(db_path, isolation_level=None);
    try {
        con.execute("BEGIN");
        if source_dir != destination_dir {
            reader = con.cursor();
            reader.execute("SELECT thread_id, id, json FROM messages");
            while True {
                rows = reader.fetchmany(500);
                if not rows { break; }
                for row in rows {
                    message = _js_parse(str(row[2]));
                    rebase_message(message, source_dir, destination_dir);
                    encoded = js_stringify(message);
                    if encoded != row[2] {
                        text = message["text"] if _record(message) and isinstance(message.get("text"), str) else None;
                        con.execute("UPDATE messages SET json = ?, text = ? WHERE thread_id = ? AND id = ?", (encoded, text, row[0], row[1]));
                    }
                }
            }
        }
        # Import is not a server restart: the source may still be running.
        # Keep accepted words and receipts for review, but never execute a
        # copy of its pending work (including when restoring in place).
        if con.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'chat_followups'").fetchone() is not None {
            pending = con.execute("SELECT id, payload FROM chat_followups WHERE status IN ('pending', 'dispatching', 'interrupted')").fetchall();
            for row in pending {
                payload = _js_parse(str(row[1]));
                rebase_message(payload, source_dir, destination_dir);
                if _record(payload) { payload.pop("prompt", None); }
                con.execute("UPDATE chat_followups SET status = 'interrupted', payload = ? WHERE id = ?", (js_stringify(payload), row[0]));
            }
        }
        con.execute("COMMIT");
    } finally {
        con.close();
    }
}

def wb_read_last(data_dir: str) -> any {
    top = _backup_root(data_dir);
    path = os.path.join(top, "last-restore.json");
    if not os.path.exists(path) { return None; }
    raw = _private_json(path);
    if not _record(raw) or raw.get("restored") is not True or not isinstance(raw.get("id"), str) or ID_RE.match(raw["id"]) is None {
        _fail("Invalid workspace restore receipt.");
    }
    return raw;
}

def _finish_restore(data_dir: str, id: str, consume_pending: bool = True) -> dict[str, any] {
    top = _backup_root(data_dir);
    staged = wb_read_staged(data_dir, id);
    summary = staged["summary"];
    client_state = staged["clientState"];
    drafts = client_state.get("omb-draft-attachments");
    if drafts {
        try {
            value = _js_parse(drafts);
            manifest = validate_manifest(_private_json(os.path.join(_job_path(data_dir, id), "staged", "manifest.json")));
            rebase_fields(value, manifest["sourceDataDir"], _resolve(data_dir));
            client_state["omb-draft-attachments"] = js_stringify(value);
        } except Exception {
            # A malformed client draft must not jeopardize durable server data.
            client_state["omb-draft-attachments"] = drafts;
        }
    }
    result = {"restored": True, "id": id, "safetyCopyPath": os.path.join(top, f"safety-{id}"), "summary": summary, "clientState": client_state};
    _write_json(os.path.join(top, "last-restore.json"), result);
    if consume_pending {
        try { os.unlink(os.path.join(top, "pending-restore.json")); } except FileNotFoundError { }
    }
    return result;
}

def _unlink_quiet(path: str) {
    try { os.unlink(path); } except FileNotFoundError { }
}

def wb_apply_pending(data_dir: str) -> dict[str, any] {
    # Runs before node constructs any config, Store, session or provider
    # object. The DATA_DIR and all destination identity/session/lease files
    # stay in place; the previous tree is kept under .backups/safety-ID.
    top = _backup_root(data_dir);
    journal_file = os.path.join(top, "restore-journal.json");
    pending_file = os.path.join(top, "pending-restore.json");
    if os.path.exists(journal_file) {
        previous = _read_journal(journal_file);
        if previous["phase"] == "applying" {
            _rollback(data_dir, previous);
            rolled = dict(previous);
            rolled["phase"] = "rolled-back";
            _write_json(journal_file, rolled);
            _unlink_quiet(pending_file);
            return {"restored": False, "rolledBack": True, "id": previous["id"], "safetyCopyPath": os.path.join(top, f"safety-{previous['id']}")};
        }
        if previous["phase"] == "committed" and os.path.exists(pending_file) {
            pending_record = _private_json(pending_file);
            if _record(pending_record) and pending_record.get("id") == previous["id"] {
                return _finish_restore(data_dir, previous["id"]);
            }
        }
    }
    pending = wb_read_pending(data_dir);
    if pending is None { return {"restored": False}; }
    pending_id = pending["id"];
    manifest = _validate_staged(os.path.join(_job_path(data_dir, pending_id), "staged"));
    prepared = _prepare_restore(data_dir, pending_id, manifest);
    safety = os.path.join(top, f"safety-{pending_id}");
    if os.path.exists(safety) { _fail("A safety copy already exists for this restore. Original files have not been changed."); }
    _folder(os.path.join(safety, "data"));
    journal = {
        "id": pending_id, "phase": "applying",
        "existing": sorted([name for name in os.listdir(data_dir) if not _kept_in_place(name)]),
        "incoming": sorted(os.listdir(prepared)),
    };
    # Top-level names are checked before recording any move; a restored root
    # never traverses an archive-controlled directory.
    names: list[any] = list(journal["existing"]) + list(journal["incoming"]);
    for name in names {
        if not _valid_relative(name) or "/" in name or _preserved(name) { _fail("Unsafe workspace restore target."); }
    }
    _write_json(os.path.join(safety, "manifest.json"), {"id": pending_id, "createdAt": _iso_now(), "originalEntries": journal["existing"]});
    if os.path.exists(os.path.join(top, "last-restore.json")) {
        _write_json(os.path.join(safety, "previous-restore.json"), _private_json(os.path.join(top, "last-restore.json")));
    }
    _write_json(journal_file, journal);
    try {
        for name in journal["existing"] { os.rename(os.path.join(data_dir, name), os.path.join(safety, "data", name)); }
        for name in journal["incoming"] {
            if _entry_exists(os.path.join(prepared, name)) { os.rename(os.path.join(prepared, name), os.path.join(data_dir, name)); }
        }
        _finish_restore(data_dir, pending_id, False);
        committed = dict(journal);
        committed["phase"] = "committed";
        _write_json(journal_file, committed);
    } except Exception {
        _rollback(data_dir, journal);
        rolled = dict(journal);
        rolled["phase"] = "rolled-back";
        _write_json(journal_file, rolled);
        _unlink_quiet(pending_file);
        _fail("The workspace restore failed and the previous workspace was recovered.");
    }
    return _finish_restore(data_dir, pending_id);
}

def wb_remove_job(data_dir: str, id: any) {
    # Delete only an unreferenced upload/export/staging job, never a safety
    # copy or a job a pending restore or its latest receipt still needs.
    path = _job_path(data_dir, id);
    top = _backup_root(data_dir);
    for name in ["pending-restore.json", "restore-journal.json", "last-restore.json"] {
        if not os.path.exists(os.path.join(top, name)) { continue; }
        value = _private_json(os.path.join(top, name));
        if _record(value) and value.get("id") == id { _fail("This backup is still needed for restore or recovery and cannot be removed."); }
    }
    if os.path.exists(os.path.join(top, f"safety-{id}")) { _fail("This backup has a recovery copy and cannot be removed."); }
    if not _entry_exists(path) { return; }
    if not _is_real_dir(path) { _fail("Unsafe workspace backup cleanup target."); }
    shutil.rmtree(path);
}

# ── coordinated operations (what the HTTP surface runs) ─────────────────────

def wb_create_quiesced(data_dir: str, options: dict[str, any]) -> dict[str, any] {
    _hook("quiesce")(data_dir);
    return wb_create(data_dir, options);
}

def wb_commit_quiesced(data_dir: str, id: any) -> dict[str, any] {
    # The scheduler stays paused: node's gate is held until restart.
    _hook("quiesce")(data_dir);
    return wb_commit(data_dir, id);
}

def wb_apply_and_reload(data_dir: str) -> dict[str, any] {
    try {
        result = wb_apply_pending(data_dir);
    } except Exception {
        # A failed swap was rolled back: files may still have moved.
        _hook("reload")(data_dir);
        raise;
    }
    if result.get("restored") or result.get("rolledBack") { _hook("reload")(data_dir); }
    return result;
}

# ── HTTP surface (re-bound onto harness.jac as workspace_backup_*) ──────────

def _guard(omb_token: any) -> any {
    want = os.environ.get("OMB_JAC_TOKEN");
    if want and omb_token != want {
        return {"ok": False, "status": 403, "error": "unauthorized"};
    }
    return None;
}

def _invoke(omb_token: any, policy_url: any, fn: any) -> any {
    g = _guard(omb_token);
    if g is not None { return g; }
    _tls.policy_url = policy_url if isinstance(policy_url, str) and policy_url.startswith("http://127.0.0.1:") else None;
    try {
        return fn();
    } except Exception as e {
        return {"ok": False, "status": _status_of(e), "error": str(e)};
    } finally {
        _tls.policy_url = None;
    }
}

# Optional kwargs: the fused jacup binary binds the stringified default when
# a request omits one, so each is type-checked before use.
def _dir_arg(data_dir: any) -> str {
    return data_dir if isinstance(data_dir, str) and data_dir and data_dir != "None" and os.path.isabs(data_dir) else DATA_DIR;
}

def _str_arg(value: any) -> any {
    return value if isinstance(value, str) and value != "None" else None;
}

def:pub workspace_backup_create(password: any = None, client_state: any = None, app_version: any = None, data_dir: any = None, policy_url: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        options: dict[str, any] = {"password": password};
        if isinstance(client_state, dict) { options["clientState"] = client_state; }
        if _str_arg(app_version) is not None { options["appVersion"] = app_version; }
        return wb_create_quiesced(_dir_arg(data_dir), options);
    }
    return _invoke(omb_token, policy_url, _go);
}

def:pub workspace_backup_stage(archive_path: str, password: any = None, current_app_version: any = None, data_dir: any = None, policy_url: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return wb_stage(_dir_arg(data_dir), archive_path, password, _str_arg(current_app_version));
    }
    return _invoke(omb_token, policy_url, _go);
}

def:pub workspace_backup_read_staged(id: str, data_dir: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"staged": wb_read_staged(_dir_arg(data_dir), id)}; }
    return _invoke(omb_token, None, _go);
}

def:pub workspace_backup_commit(id: str, data_dir: any = None, policy_url: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return wb_commit_quiesced(_dir_arg(data_dir), id); }
    return _invoke(omb_token, policy_url, _go);
}

def:pub workspace_backup_read_pending(data_dir: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"pending": wb_read_pending(_dir_arg(data_dir))}; }
    return _invoke(omb_token, None, _go);
}

def:pub workspace_backup_apply_pending(data_dir: any = None, policy_url: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"result": wb_apply_and_reload(_dir_arg(data_dir))}; }
    return _invoke(omb_token, policy_url, _go);
}

def:pub workspace_backup_read_last(data_dir: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"receipt": wb_read_last(_dir_arg(data_dir))}; }
    return _invoke(omb_token, None, _go);
}

def:pub workspace_backup_remove_job(id: str, data_dir: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        wb_remove_job(_dir_arg(data_dir), id);
        return {"ok": True};
    }
    return _invoke(omb_token, None, _go);
}

with entry {
    _reset_wb();
}
