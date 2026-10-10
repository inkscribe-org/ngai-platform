"""Ported invariants from server/workspace-backup.test.ts (+ worker/policy).

Annexes workspace_backup.jac (no self-import). Node's config policy
(portableWorkspaceConfig / restoredWorkspaceConfig, zod-backed) is a fake
hook with the same allowlist; quiesce/reload are recorded so the Jac-owned
file coordination is asserted too.
"""

import os;
import re;
import gzip;
import json;
import stat;
import shutil;
import hashlib;
import sqlite3;
import tarfile;
import secrets;
import tempfile;

glob PASSWORD: str = "correct horse battery staple";
glob AVATAR: bytes = bytes([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13]);
glob PORTABLE: list[str] = ["profile", "language", "budgets", "billing", "rooms", "threads", "localVm", "features", "browserProfiles"];
glob TS_FIXTURE_SOURCE: str = "/tmp/omb-ts-fixture-rRoEbV";
glob _dirs: list[str] = [];
glob _calls: dict[str, any] = {"quiesce": [], "reload": [], "policy": []};

def _cleanup {
    while len(_dirs) > 0 {
        shutil.rmtree(_dirs.pop(), ignore_errors=True);
    }
}

def _fake_policy(action: str, config: any, destination: any) -> any {
    _calls["policy"].append(action);
    portable: dict[str, any] = {};
    for k in PORTABLE {
        if k in config { portable[k] = config[k]; }
    }
    if action == "portable" { return portable; }
    merged: dict[str, any] = {};
    for (k, v) in destination.items() {
        if k not in PORTABLE { merged[k] = v; }
    }
    merged.update(portable);
    return merged;
}

def _fake_quiesce(data_dir: str) { _calls["quiesce"].append(data_dir); }
def _fake_reload(data_dir: str) { _calls["reload"].append(data_dir); }

def _setup {
    _cleanup();
    _calls.update({"quiesce": [], "reload": [], "policy": []});
    _wb.update({"hooks": {"config_policy": _fake_policy, "quiesce": _fake_quiesce, "reload": _fake_reload}});
}

def _directory -> str {
    d = tempfile.mkdtemp(prefix="omb-workspace-backup-");
    _dirs.append(d);
    return d;
}

def _json(path: str, value: any) {
    os.makedirs(os.path.dirname(path), exist_ok=True);
    with open(path, "w", encoding="utf-8") as f { f.write(json.dumps(value, separators=(",", ":"))); }
}

def _read_json(path: str) -> any {
    with open(path, "r", encoding="utf-8") as f { return json.load(f); }
}

def _write(path: str, data: any) {
    os.makedirs(os.path.dirname(path), exist_ok=True);
    mode = "wb" if isinstance(data, bytes) else "w";
    with open(path, mode) as f { f.write(data); }
}

def _read(path: str) -> str {
    with open(path, "r", encoding="utf-8") as f { return f.read(); }
}

def _read_bytes(path: str) -> bytes {
    with open(path, "rb") as f { return f.read(); }
}

def _throws(fn: any, pattern: str) {
    try {
        fn();
    } except Exception as e {
        assert re.search(pattern, str(e)), "error " + json.dumps(str(e)) + " does not match " + json.dumps(pattern);
        return;
    }
    raise Exception("expected an exception matching " + pattern);
}

def _create(source: str, options: any = None) -> dict[str, any] {
    opts: dict[str, any] = {"password": PASSWORD};
    if isinstance(options, dict) { opts.update(options); }
    return wb_create_quiesced(source, opts);
}

def _stage(target: str, archive: str, version: any = None) -> dict[str, any] {
    return wb_stage(target, archive, PASSWORD, version);
}

def _fixture(top: str) {
    _write(os.path.join(top, "attachments", "image.png"), bytes([0, 1, 2, 255, 0, 128]));
    _write(os.path.join(top, "attachments", "avatar.png"), AVATAR);
    _write(os.path.join(top, "task-workspaces", "bot", "thread", "binary.bin"), bytes([0xa5]) * (2 * 1024 * 1024));
    work = os.path.join(top, "task-workspaces", "bot", "thread");
    _json(os.path.join(top, "config.json"), {"language": "ja", "instances": {"custom": {"driver": "claudeAgent", "config": {"configDir": os.path.join(top, "providers", "account")}}}, "apiKey": "private-key-in-config"});
    _json(os.path.join(top, "bots.json"), [{"id": "bot", "threadId": "thread", "cwd": work, "soul": f"Do not rewrite this prose mentioning {top}.", "avatarUrl": "/api/attachments/avatar.png", "avatarCrop": "circle", "voice": "source-provider-voice", "tasks": [{"threadId": "thread", "cwd": work}]}]);
    _json(os.path.join(top, "groups.json"), [{"id": "room", "memberIds": ["bot"], "cwd": "/external/project"}]);
    _json(os.path.join(top, "routines.json"), {"version": 1, "routines": [{"id": "routine", "enabled": True}], "runs": [{"id": "waiting", "status": "queued"}, {"id": "historical", "status": "completed"}]});
    _json(os.path.join(top, "webhooks.json"), {"version": 1, "webhooks": [{"id": "hook", "endpointId": "endpoint", "enabled": True, "secretHash": "a" * 64}], "deliveries": [{"id": "delivery"}]});
    _json(os.path.join(top, "calendar-calls.json"), {"version": 1, "calls": [{"id": "call", "nextRunAt": 100}]});
    _json(os.path.join(top, "delegations.json"), {"thread": [{"id": "pending"}]});
    _json(os.path.join(top, "delegation-receipts.json"), [{"id": "receipt"}]);
    _json(os.path.join(top, "sessions.json"), {"identity": "source-session"});
    _json(os.path.join(top, "cloud-owner.json"), {"identity": "source-owner-record"});
    _write(os.path.join(top, "environment-id"), "source-environment");
    _write(os.path.join(top, "tools", "downloaded"), "reinstallable");
    _write(os.path.join(top, "decider-log", "2026-09.ndjson"), "{\"seam\":\"roomRouting\"}\n");
    image = os.path.join(top, "attachments", "image.png");
    con = sqlite3.connect(os.path.join(top, "messages.db"), isolation_level=None);
    con.execute("PRAGMA journal_mode=WAL");
    con.execute("CREATE TABLE messages(thread_id TEXT, id TEXT, text TEXT, json TEXT, PRIMARY KEY(thread_id,id))");
    con.execute("CREATE TABLE thread_state(thread_id TEXT PRIMARY KEY, active_leaf_id TEXT)");
    text = f"Keep prose {top}.\n<attached-image path=\"{image}\" name=\"image.png\" />\n\n```\n<attached-image path=\"{image}\" />\n```";
    message = {"id": "message", "role": "user", "kind": "text", "at": 123, "text": text, "attachments": [{"kind": "image", "path": image, "mime": "image/png"}]};
    con.execute("INSERT INTO messages VALUES (?, ?, ?, ?)", ("thread", "message", text, json.dumps(message, separators=(",", ":"))));
    con.execute("INSERT INTO thread_state VALUES (?, ?)", ("thread", "message"));
    con.execute("CREATE TABLE chat_followups(id TEXT PRIMARY KEY, kind TEXT, owner_id TEXT, thread_id TEXT, send_id TEXT, status TEXT, payload TEXT)");
    for status in ["pending", "dispatching", "cancelled"] {
        payload = json.dumps({"text": text, "replyToId": "message", "prompt": "Source-only reply context"}, separators=(",", ":"));
        con.execute("INSERT INTO chat_followups VALUES (?, 'bot', 'bot', 'thread', ?, ?, ?)", (status, "send-" + status, status, payload));
    }
    con.close();
}

def _encrypted_payload(top: str, plaintext: bytes) -> str {
    salt = secrets.token_bytes(16);
    iv = secrets.token_bytes(12);
    header = MAGIC + salt + iv;
    gcm = Gcm(encrypt=True);
    gcm.start(_password_key(PASSWORD, salt), iv, header);
    body = gcm.update(plaintext) + gcm.finish_encrypt();
    gcm.close();
    path = os.path.join(top, "malicious.ombbackup");
    _write(path, header + body);
    return path;
}

def _tar_entry(path: str, kind: str = "File", content: str = "") -> bytes {
    info = tarfile.TarInfo(path);
    data = content.encode("utf-8");
    info.size = len(data) if kind == "File" else 0;
    info.mode = 0o600;
    kinds = {"File": tarfile.REGTYPE, "Directory": tarfile.DIRTYPE, "SymbolicLink": tarfile.SYMTYPE, "Link": tarfile.LNKTYPE, "FIFO": tarfile.FIFOTYPE};
    info.type = kinds[kind];
    if kind == "SymbolicLink" or kind == "Link" { info.linkname = "/outside"; }
    block = info.tobuf(tarfile.USTAR_FORMAT, "utf-8", "strict");
    pad = (512 - len(data) % 512) % 512;
    return block + data + bytes(pad);
}

def _manifest_paths(staging: str) -> list[str] {
    return [e["path"] for e in _read_json(os.path.join(staging, "manifest.json"))["entries"]];
}

def _db_rows(path: str, sql: str) -> list[any] {
    con = sqlite3.connect(_sqlite_uri(path, "ro"), uri=True);
    try { return con.execute(sql).fetchall(); } finally { con.close(); }
}

test "round-trips WAL conversations, binary files, drafts and IDs; preserves destination identity and connections" {
    _setup();
    source = _directory();
    _fixture(source);
    _json(os.path.join(source, "team-computers.json"), {"version": 1, "environmentId": "source-environment", "computers": [{"id": "source-computer", "name": "Source desktop", "section": "Design"}]});
    original_db = _read_bytes(os.path.join(source, "messages.db"));
    image = os.path.join(source, "attachments", "image.png");
    exported = _create(source, {"appVersion": "test", "clientState": {
        "omb-drafts": "{\"thread\":\"unsent\"}",
        "omb-draft-attachments": json.dumps({"thread": [{"kind": "file", "path": image}]}),
    }});
    assert _calls["quiesce"] == [source];
    s = exported["summary"];
    assert s["bots"] == 1 and s["groups"] == 1 and s["threads"] == 1 and s["messages"] == 1;
    assert "includesCredentials" not in s;
    encrypted = _read_bytes(exported["path"]);
    assert b"private-secret" not in encrypted and b"private-key-in-config" not in encrypted;
    assert _read_bytes(os.path.join(source, "messages.db")) == original_db;
    target = _directory();
    connections = {"xai": {"key": "destination-key", "url": "https://destination.example"}, "instances": {"local": {"driver": "claudeAgent", "config": {"configDir": os.path.join(target, "providers", "local")}}}};
    dest_config = dict(connections);
    dest_config["language"] = "en";
    _json(os.path.join(target, "config.json"), dest_config);
    _json(os.path.join(target, "bots.json"), [{"id": "old"}]);
    _json(os.path.join(target, "sessions.json"), {"identity": "target-session"});
    _json(os.path.join(target, "cloud-owner.json"), {"identity": "target-owner-record"});
    target_computers = {"version": 1, "environmentId": "target-environment", "computers": [{"id": "target-computer", "name": "Destination desktop", "section": None}]};
    _json(os.path.join(target, "team-computers.json"), target_computers);
    _write(os.path.join(target, "environment-id"), "target-environment");
    _write(os.path.join(target, "openmausbot-server.lease"), "live-lease");
    _write(os.path.join(target, "messages.db-wal"), "old database WAL must not enter the new DB");
    _write(os.path.join(target, "messages.db-shm"), "old database shared memory");
    staged = _stage(target, exported["path"]);
    assert staged["summary"] == exported["summary"];
    assert _read_json(os.path.join(target, "bots.json")) == [{"id": "old"}];
    assert "credentials" not in wb_read_staged(target, staged["id"]);
    data = os.path.join(target, ".backups", staged["id"], "staged", "data");
    assert not os.path.exists(os.path.join(data, "team-computers.json"));
    assert os.path.exists(os.path.join(data, "bots.json"));
    assert not os.path.exists(os.path.join(data, "cloud-owner.json"));
    assert _read_json(os.path.join(data, "config.json")) == {"language": "ja"};
    assert "secretHash" not in _read_json(os.path.join(data, "webhooks.json"))["webhooks"][0];
    committed = wb_commit_quiesced(target, staged["id"]);
    assert committed["id"] == staged["id"] and committed["restartRequired"] is True;
    assert wb_read_pending(target)["id"] == staged["id"];
    result = wb_apply_and_reload(target);
    assert result["restored"] is True and result["id"] == staged["id"];
    assert _calls["reload"] == [target];
    bot = _read_json(os.path.join(target, "bots.json"))[0];
    assert bot["id"] == "bot" and bot["cwd"] == os.path.join(target, "task-workspaces", "bot", "thread");
    assert bot["soul"] == f"Do not rewrite this prose mentioning {source}." and bot["avatarUrl"] == "/api/attachments/avatar.png" and bot["avatarCrop"] == "circle";
    assert "voice" not in bot;
    assert _read_bytes(os.path.join(target, "attachments", "avatar.png")) == AVATAR;
    assert _read_json(os.path.join(target, "groups.json"))[0]["cwd"] == "/external/project";
    expected_config = dict(connections);
    expected_config["language"] = "ja";
    assert _read_json(os.path.join(target, "config.json")) == expected_config;
    assert _read_bytes(os.path.join(target, "task-workspaces", "bot", "thread", "binary.bin")) == bytes([0xa5]) * (2 * 1024 * 1024);
    assert _read_json(os.path.join(target, "sessions.json")) == {"identity": "target-session"};
    assert _read_json(os.path.join(target, "cloud-owner.json")) == {"identity": "target-owner-record"};
    assert _read_json(os.path.join(target, "team-computers.json")) == target_computers;
    assert _read(os.path.join(target, "environment-id")) == "target-environment";
    assert _read(os.path.join(target, "openmausbot-server.lease")) == "live-lease";
    assert not os.path.exists(os.path.join(target, "messages.db-wal"));
    assert _read(os.path.join(result["safetyCopyPath"], "data", "messages.db-wal")) == "old database WAL must not enter the new DB";
    assert not os.path.exists(os.path.join(target, "tools"));
    assert not os.path.exists(os.path.join(target, "decider-log"));
    assert _read_json(os.path.join(result["safetyCopyPath"], "data", "bots.json")) == [{"id": "old"}];
    db = os.path.join(target, "messages.db");
    message = json.loads(_db_rows(db, "SELECT json FROM messages WHERE id='message'")[0][0]);
    new_image = os.path.join(target, "attachments", "image.png");
    assert message["attachments"][0]["path"] == new_image;
    assert _read_bytes(message["attachments"][0]["path"]) == bytes([0, 1, 2, 255, 0, 128]);
    assert f"Keep prose {source}." in message["text"];
    assert f"<attached-image path=\"{new_image}\" name=\"image.png\" />" in message["text"];
    assert f"```\n<attached-image path=\"{image}\" />\n```" in message["text"];
    assert _db_rows(db, "SELECT active_leaf_id FROM thread_state")[0][0] == "message";
    assert _db_rows(db, "SELECT id, status FROM chat_followups ORDER BY rowid") == [("pending", "interrupted"), ("dispatching", "interrupted"), ("cancelled", "cancelled")];
    followup = json.loads(_db_rows(db, "SELECT payload FROM chat_followups WHERE id = 'pending'")[0][0]);
    assert followup["replyToId"] == "message" and new_image in followup["text"] and "prompt" not in followup;
    routines = _read_json(os.path.join(target, "routines.json"));
    assert routines["routines"][0]["enabled"] is False;
    assert routines["runs"][0]["status"] == "failed" and routines["runs"][1]["status"] == "completed";
    hooks = _read_json(os.path.join(target, "webhooks.json"));
    assert hooks["webhooks"][0]["enabled"] is False and hooks["deliveries"] == [{"id": "delivery"}];
    assert re.match(r"^[a-f0-9]{64}$", hooks["webhooks"][0]["secretHash"]) and hooks["webhooks"][0]["secretHash"] != "a" * 64;
    assert _read_json(os.path.join(target, "calendar-calls.json"))["calls"][0]["nextRunAt"] is None;
    assert _read_json(os.path.join(target, "delegations.json")) == {};
    assert _read_json(os.path.join(target, "delegation-receipts.json")) == [{"id": "receipt"}];
    receipt = wb_read_last(target);
    assert receipt["id"] == staged["id"] and "credentials" not in receipt;
    assert json.loads(receipt["clientState"]["omb-draft-attachments"])["thread"][0]["path"] == new_image;
    assert wb_apply_and_reload(target) == {"restored": False};
    assert _calls["reload"] == [target];
    assert stat.S_IMODE(os.stat(exported["path"]).st_mode) == 0o600;
    assert stat.S_IMODE(os.stat(os.path.join(target, "attachments", "image.png")).st_mode) == 0o600;
    _cleanup();
}

test "also pauses pending chat follow-ups when restoring into the original home" {
    _setup();
    source = _directory();
    _fixture(source);
    exported = _create(source);
    staged = _stage(source, exported["path"]);
    wb_commit(source, staged["id"]);
    wb_apply_pending(source);
    rows = _db_rows(os.path.join(source, "messages.db"), "SELECT id, status FROM chat_followups ORDER BY rowid");
    assert rows == [("pending", "interrupted"), ("dispatching", "interrupted"), ("cancelled", "cancelled")];
    _cleanup();
}

test "authenticates before extraction and leaves the existing workspace unchanged for wrong passwords or damaged ciphertext" {
    _setup();
    source = _directory();
    _json(os.path.join(source, "bots.json"), []);
    exported = _create(source);
    target = _directory();
    _write(os.path.join(target, "untouched"), "original");
    def _wrong { wb_stage(target, exported["path"], "incorrect-password", None); }
    _throws(_wrong, "password is incorrect");
    assert os.listdir(os.path.join(target, ".backups")) == [];
    corrupted = bytearray(_read_bytes(exported["path"]));
    corrupted[-1] = corrupted[-1] ^ 1;
    path = os.path.join(source, "corrupted.ombbackup");
    _write(path, bytes(corrupted));
    def _damaged { _stage(target, path); }
    _throws(_damaged, "damaged");
    assert _read(os.path.join(target, "untouched")) == "original";
    assert os.listdir(os.path.join(target, ".backups")) == [];
    _cleanup();
}

test "leaves owned authentication stores out of the archive and retains only the destination copies" {
    _setup();
    source = _directory();
    target = _directory();
    auth_paths = [
        "workspace-credentials.json", "browser-engine-key", "config.json.123.tmp",
        "external-runtimes.json", "external-runtimes.json.123.tmp",
        "providers/account/auth.json", "providers/antigravity/account/acp_token.json",
        "caddy/data/private.key", "chrome-profile/Cookies", ".agent-browser/auth.json",
        "vm-home/.browser-profiles/chrome/Cookies", "vm-homes/abc/.browser-profiles/chromium/Cookies",
        "tmp/omb-mcp-123/mcp.json", ".tmp/secret",
    ];
    for top in [source, target] {
        for p in auth_paths {
            _write(os.path.join(top, p), "SOURCE_SAVED_SECRET" if top == source else "DESTINATION_SAVED_SECRET");
        }
    }
    _write(os.path.join(source, "attachments", "user-note.txt"), "A user-pasted secret is not silently redacted.");
    _write(os.path.join(source, "vm-home", "project.txt"), "ordinary managed VM file");
    _json(os.path.join(source, "config.json"), {"xai": {"key": "SOURCE_SAVED_SECRET", "url": "https://source.example"}, "language": "ja"});
    _json(os.path.join(source, "webhooks.json"), {"webhooks": [{"id": "same", "endpointId": "same-endpoint", "secretHash": "a" * 64, "enabled": True, "verificationPending": True}]});
    _json(os.path.join(target, "config.json"), {"xai": {"key": "DESTINATION_SAVED_SECRET", "url": "https://destination.example"}, "language": "en"});
    _json(os.path.join(target, "webhooks.json"), {"webhooks": [{"id": "same", "endpointId": "same-endpoint", "secretHash": "b" * 64}]});
    exported = _create(source);
    staged = _stage(target, exported["path"]);
    staging = os.path.join(target, ".backups", staged["id"], "staged");
    manifest = _read_json(os.path.join(staging, "manifest.json"));
    assert "credentials" not in manifest and "includesCredentials" not in manifest["summary"];
    for p in auth_paths { assert not os.path.exists(os.path.join(staging, "data", p)), p; }
    for e in manifest["entries"] {
        if e["type"] == "file" { assert b"SOURCE_SAVED_SECRET" not in _read_bytes(os.path.join(staging, "data", e["path"])); }
    }
    wb_commit(target, staged["id"]);
    wb_apply_pending(target);
    for p in auth_paths { assert _read(os.path.join(target, p)) == "DESTINATION_SAVED_SECRET", p; }
    assert _read(os.path.join(target, "vm-home", "project.txt")) == "ordinary managed VM file";
    assert _read(os.path.join(target, "attachments", "user-note.txt")) == "A user-pasted secret is not silently redacted.";
    assert _read_json(os.path.join(target, "config.json")) == {"xai": {"key": "DESTINATION_SAVED_SECRET", "url": "https://destination.example"}, "language": "ja"};
    hook = _read_json(os.path.join(target, "webhooks.json"))["webhooks"][0];
    assert hook["secretHash"] == "b" * 64 and hook["enabled"] is False and hook["verificationPending"] is False;
    for p in auth_paths { assert _read(os.path.join(source, p)) == "SOURCE_SAVED_SECRET"; }
    assert _read_json(os.path.join(source, "webhooks.json"))["webhooks"][0]["secretHash"] == "a" * 64;
    _cleanup();
}

test "never lists a per-turn hook token directory in a backup manifest" {
    _setup();
    source = _directory();
    _write(os.path.join(source, "hook-tokens", ("a" * 24) + ".token"), "SOURCE_TURN_BEARER");
    _write(os.path.join(source, "attachments", "note.txt"), "ordinary user file");
    exported = _create(source);
    staged = _stage(source, exported["path"]);
    staging = os.path.join(source, ".backups", staged["id"], "staged");
    paths = _manifest_paths(staging);
    assert "attachments/note.txt" in paths;
    assert [p for p in paths if "token" in p.lower()] == [];
    assert not os.path.exists(os.path.join(staging, "data", "hook-tokens"));
    _cleanup();
}

test "leaves the Organization library's downloaded catalog and release files out, and keeps what the runtime added" {
    _setup();
    source = _directory();
    library = os.path.join(source, "org-library");
    _json(os.path.join(library, "state.json"), {"version": 1, "source": None, "appliedDigest": None, "installs": {}});
    _json(os.path.join(library, "presets.json"), {"version": 1, "presets": []});
    _write(os.path.join(library, "catalog.json"), "ORGANIZATION_CATALOG_BYTES");
    _write(os.path.join(library, "catalog.json." + ("0" * 8) + "-0000-4000-8000-" + ("0" * 12) + ".tmp"), "ORGANIZATION_CATALOG_BYTES");
    _write(os.path.join(library, "blobs", ("b" * 64) + ".json"), "ORGANIZATION_RELEASE_BYTES");
    exported = _create(source);
    staged = _stage(source, exported["path"]);
    staging = os.path.join(source, ".backups", staged["id"], "staged");
    assert [p for p in _manifest_paths(staging) if p.startswith("org-library")] == ["org-library", "org-library/presets.json", "org-library/state.json"];
    assert not os.path.exists(os.path.join(staging, "data", "org-library", "blobs"));
    _cleanup();
}

test "leaves the destination's session open-marker in place" {
    _setup();
    source = _directory();
    target = _directory();
    _json(os.path.join(source, "bots.json"), [{"id": "bot"}]);
    _write(os.path.join(source, "sessions.json.open"), "Session registry is open.\n");
    exported = _create(source);
    _json(os.path.join(target, "sessions.json"), {"version": 1, "sessions": [{"id": "member"}]});
    _write(os.path.join(target, "sessions.json.open"), "Session registry is open.\n");
    staged = _stage(target, exported["path"]);
    assert "sessions.json.open" not in _manifest_paths(os.path.join(target, ".backups", staged["id"], "staged"));
    wb_commit(target, staged["id"]);
    assert wb_apply_pending(target)["restored"] is True;
    assert os.path.exists(os.path.join(target, "sessions.json.open"));
    assert not os.path.exists(os.path.join(target, ".backups", "safety-" + staged["id"], "data", "sessions.json.open"));
    _cleanup();
}

test "never lets tar decompress a payload: zstd is refused like gzip" {
    _setup();
    top = _directory();
    archive = _encrypted_payload(top, b"\x28\xb5\x2f\xfd" + bytes(1020));
    def _go { _stage(_directory(), archive); }
    _throws(_go, "Compressed payloads are not supported");
    _cleanup();
}

test "still restores an archive from a release that exported hook tokens, without installing them" {
    _setup();
    source = _directory();
    exported = _create(source);
    probe = _stage(source, exported["path"]);
    base = _read_json(os.path.join(source, ".backups", probe["id"], "staged", "manifest.json"));
    token = "STALE_TURN_BEARER";
    note = "kept";
    def _file(path: str, content: str) -> dict[str, any] {
        return {"path": path, "type": "file", "size": len(content.encode()), "mode": 0o600, "sha256": hashlib.sha256(content.encode()).hexdigest()};
    }
    manifest = dict(base);
    manifest["entries"] = [{"path": "hook-tokens", "type": "directory", "size": 0, "mode": 0o700}, _file("hook-tokens/old.token", token), _file("note.txt", note)];
    summary = dict(base["summary"]);
    summary.update({"directories": 1, "files": 2, "bytes": len(token) + len(note)});
    manifest["summary"] = summary;
    archive = _encrypted_payload(source, _tar_entry("manifest.json", "File", json.dumps(manifest)) + _tar_entry("data", "Directory")
        + _tar_entry("data/hook-tokens", "Directory") + _tar_entry("data/hook-tokens/old.token", "File", token)
        + _tar_entry("data/note.txt", "File", note) + bytes(1024));
    target = _directory();
    staged = _stage(target, archive);
    wb_commit(target, staged["id"]);
    assert wb_apply_pending(target)["restored"] is True;
    assert _read(os.path.join(target, "note.txt")) == note;
    assert not os.path.exists(os.path.join(target, "hook-tokens"));
    _cleanup();
}

test "rejects authenticated credential metadata, saved auth paths, and connection-bearing config" {
    _setup();
    source = _directory();
    exported = _create(source);
    staged = _stage(source, exported["path"]);
    base = _read_json(os.path.join(source, ".backups", staged["id"], "staged", "manifest.json"));
    bad_summary = dict(base["summary"]);
    bad_summary["includesCredentials"] = False;
    for variant in [{"credentials": {"xaiApiKey": "secret"}}, {"summary": bad_summary}] {
        manifest = dict(base);
        manifest.update(variant);
        path = _encrypted_payload(source, _tar_entry("manifest.json", "File", json.dumps(manifest)) + _tar_entry("data", "Directory") + bytes(1024));
        def _meta { _stage(_directory(), path); }
        _throws(_meta, "metadata");
    }
    cases = [
        ["team-computers.json", "{\"computers\":[{\"id\":\"foreign-computer\",\"section\":\"Design\"}]}"],
        ["workspace-credentials.json", "{\"xaiApiKey\":\"secret\"}"],
        ["external-runtimes.json", "{\"bot-id\":\"external-runtime-secret\"}"],
        ["External-Runtimes.json", "external-runtime-secret"],
        ["Sessions.json", "secret"],
        ["Providers", "secret"],
        ["Caddy", "secret"],
        ["Browser-Engine-Key", "secret"],
        ["vm-home/.Browser-Profiles", "secret"],
        ["vm-homes/bot/.BROWSER-PROFILES", "secret"],
        ["Config.json", "{\"xai\":{\"key\":\"secret\"}}"],
        ["Webhooks.json", "{\"webhooks\":[{\"secretHash\":\"secret\"}]}"],
        ["browser-engine-key", "secret"],
        ["config.json", "{\"xai\":{\"key\":\"secret\",\"url\":\"https://source.example\"}}"],
        ["config.json", "{\"futureAuth\":{\"field\":\"secret\"}}"],
        ["webhooks.json", "{\"webhooks\":[{\"secretHash\":\"secret\"}]}"],
    ];
    for pair in cases {
        name = pair[0];
        content = pair[1];
        item = {"path": name, "type": "file", "size": len(content.encode()), "mode": 0o600, "sha256": hashlib.sha256(content.encode()).hexdigest()};
        segments = name.split("/");
        parents = ["/".join(segments[0:i + 1]) for i in range(len(segments) - 1)];
        manifest = dict(base);
        manifest["entries"] = [{"path": p, "type": "directory", "size": 0, "mode": 0o700} for p in parents] + [item];
        summary = dict(base["summary"]);
        summary.update({"directories": len(parents), "files": 1, "bytes": item["size"]});
        manifest["summary"] = summary;
        payload = _tar_entry("manifest.json", "File", json.dumps(manifest)) + _tar_entry("data", "Directory");
        for p in parents { payload = payload + _tar_entry("data/" + p, "Directory"); }
        payload = payload + _tar_entry("data/" + name, "File", content) + bytes(1024);
        path = _encrypted_payload(source, payload);
        def _bad { _stage(_directory(), path); }
        _throws(_bad, "Unsafe|connection settings|webhook credentials");
    }
    _cleanup();
}

test "retains differently cased destination auth roots and refuses them in recovery journals" {
    _setup();
    source = _directory();
    exported = _create(source);
    target = _directory();
    _write(os.path.join(target, "Providers", "auth.json"), "destination-login");
    _write(os.path.join(target, "Sessions.json"), "destination-session");
    staged = _stage(target, exported["path"]);
    wb_commit(target, staged["id"]);
    wb_apply_pending(target);
    assert _read(os.path.join(target, "Providers", "auth.json")) == "destination-login";
    assert _read(os.path.join(target, "Sessions.json")) == "destination-session";
    _json(os.path.join(target, ".backups", "restore-journal.json"), {"id": staged["id"], "phase": "applying", "existing": [], "incoming": ["Sessions.json"]});
    def _go { wb_apply_pending(target); }
    _throws(_go, "recovery paths");
    assert _read(os.path.join(target, "Sessions.json")) == "destination-session";
    _cleanup();
}

test "fails explicitly on noncanonical source auth paths rather than silently skipping them" {
    _setup();
    source = _directory();
    _write(os.path.join(source, "vm-home", ".Browser-Profiles", "Cookies"), "source-login");
    def _go { _create(source); }
    _throws(_go, "protected authentication");
    assert _read(os.path.join(source, "vm-home", ".Browser-Profiles", "Cookies")) == "source-login";
    _cleanup();
}

test "refuses registered custom auth homes inside ordinary workspace files before export or restore" {
    _setup();
    source = _directory();
    login = os.path.join(source, "custom-login");
    _write(os.path.join(login, "auth.json"), "registered-source-secret");
    for field in ["configDir", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "HOME", "XDG_DATA_HOME"] {
        instance: dict[str, any] = {"driver": "claudeAgent"};
        if field == "configDir" { instance["config"] = {"configDir": login}; }
        else { instance["environment"] = {field: login}; }
        _json(os.path.join(source, "config.json"), {"instances": {"custom": instance}});
        def _go { _create(source); }
        _throws(_go, "Provider authentication storage");
        assert not os.path.exists(os.path.join(source, ".backups"));
    }
    shutil.rmtree(login);
    _json(os.path.join(source, "config.json"), {"instances": {"custom": {"driver": "claudeAgent", "config": {"configDir": os.path.join(source, "providers", "custom")}}}});
    exported = _create(source);
    target = _directory();
    _json(os.path.join(target, "config.json"), {"instances": {"custom": {"driver": "claudeAgent", "config": {"configDir": os.path.join(target, "custom-login")}}}});
    _write(os.path.join(target, "custom-login", "auth.json"), "registered-destination-secret");
    staged = _stage(target, exported["path"]);
    def _commit { wb_commit(target, staged["id"]); }
    _throws(_commit, "Provider authentication storage");
    assert wb_read_pending(target) is None;
    assert _read(os.path.join(target, "custom-login", "auth.json")) == "registered-destination-secret";
    _cleanup();
}

test "rejects authenticated hostile archives" {
    _setup();
    payloads = [
        _tar_entry("../escape"), _tar_entry("/escape"), _tar_entry("data\\escape"),
        _tar_entry("data/link", "SymbolicLink"), _tar_entry("data/link", "Link"), _tar_entry("data/pipe", "FIFO"),
        _tar_entry("data/file") + _tar_entry("data/file"), _tar_entry("data/FILE") + _tar_entry("data/file"),
        gzip.compress(bytes(1024)),
    ];
    for payload in payloads {
        top = _directory();
        path = _encrypted_payload(top, payload + bytes(1024));
        def _go { _stage(top, path); }
        _throws(_go, "unsafe|unsupported entries|Compressed payloads");
        assert os.listdir(os.path.join(top, ".backups")) == [];
    }
    _cleanup();
}

test "refuses external and arbitrary internal symlinks while reporting omitted managed discovery links" {
    _setup();
    top = _directory();
    outside = _directory();
    _write(os.path.join(outside, "secret"), "must never be read");
    os.symlink(os.path.join(outside, "secret"), os.path.join(top, "external"));
    def _external { _create(top); }
    _throws(_external, "outside the workspace");
    os.unlink(os.path.join(top, "external"));
    _write(os.path.join(top, "regular"), "data");
    os.symlink(os.path.join(top, "regular"), os.path.join(top, "internal"));
    def _internal { _create(top); }
    _throws(_internal, "user-created symbolic link");
    os.unlink(os.path.join(top, "internal"));
    skill = os.path.join(top, "workspaces", "bot", "skills", "example");
    _write(os.path.join(skill, "SKILL.md"), "# Example");
    native = os.path.join(top, "workspaces", "bot", ".claude", "skills");
    os.makedirs(native);
    os.symlink(skill, os.path.join(native, "example"));
    exported = _create(top);
    assert any(["1 managed skill" in w for w in exported["summary"]["warnings"]]);
    _cleanup();
}

test "leaves out node_modules and links in conversation work folders, and says so" {
    _setup();
    top = _directory();
    outside = _directory();
    _write(os.path.join(outside, "secret"), "must never be read");
    work = os.path.join(top, "task-workspaces", "bot", "thread");
    _write(os.path.join(work, "app.js"), "console.log(1)");
    os.symlink(outside, os.path.join(work, "node_modules"));
    os.symlink(os.path.join(outside, "secret"), os.path.join(work, "linked-secret"));
    _write(os.path.join(top, "workspaces", "bot", "project", "node_modules", "left-pad", "index.js"), "module.exports = 1");
    exported = _create(top);
    assert any([w.startswith("2 installed dependency folder(s) (node_modules)") for w in exported["summary"]["warnings"]]);
    assert any([w.startswith("1 symbolic link(s) in conversation work folders") for w in exported["summary"]["warnings"]]);
    target = _directory();
    staged = _stage(target, exported["path"]);
    data = os.path.join(target, ".backups", staged["id"], "staged", "data");
    assert _read(os.path.join(data, "task-workspaces", "bot", "thread", "app.js")) == "console.log(1)";
    assert not os.path.exists(os.path.join(data, "task-workspaces", "bot", "thread", "node_modules"));
    assert not os.path.exists(os.path.join(data, "task-workspaces", "bot", "thread", "linked-secret"));
    assert not os.path.exists(os.path.join(data, "workspaces", "bot", "project", "node_modules"));
    os.symlink(os.path.join(outside, "secret"), os.path.join(top, "workspaces", "bot", "external"));
    def _go { _create(top); }
    _throws(_go, "outside the workspace");
    _cleanup();
}

test "recovers an interrupted top-level swap before any application state is loaded" {
    _setup();
    source = _directory();
    _json(os.path.join(source, "bots.json"), []);
    exported = _create(source);
    target = _directory();
    _json(os.path.join(target, "bots.json"), [{"id": "original"}]);
    staged = _stage(target, exported["path"]);
    wb_commit(target, staged["id"]);
    top = os.path.join(target, ".backups");
    apply = os.path.join(top, staged["id"], "apply", "data");
    shutil.rmtree(os.path.join(top, staged["id"], "apply"));
    shutil.copytree(os.path.join(top, staged["id"], "staged", "data"), apply);
    saved = os.path.join(top, "safety-" + staged["id"], "data");
    os.makedirs(saved);
    _json(os.path.join(top, "restore-journal.json"), {"id": staged["id"], "phase": "applying", "existing": ["bots.json"], "incoming": ["bots.json"]});
    os.rename(os.path.join(target, "bots.json"), os.path.join(saved, "bots.json"));
    os.rename(os.path.join(apply, "bots.json"), os.path.join(target, "bots.json"));
    result = wb_apply_and_reload(target);
    assert result["restored"] is False and result["rolledBack"] is True and result["id"] == staged["id"];
    assert _calls["reload"] == [target];
    assert _read_json(os.path.join(target, "bots.json")) == [{"id": "original"}];
    assert wb_apply_pending(target) == {"restored": False};
    _cleanup();
}

test "detects staged-file tampering before committing or replacing original data" {
    _setup();
    source = _directory();
    _json(os.path.join(source, "bots.json"), []);
    exported = _create(source);
    target = _directory();
    staged = _stage(target, exported["path"]);
    _write(os.path.join(target, ".backups", staged["id"], "staged", "data", "bots.json"), "[{}]");
    def _go { wb_commit(target, staged["id"]); }
    _throws(_go, "match|checksum");
    assert wb_read_pending(target) is None;
    _cleanup();
}

test "validates password strength, client preferences and downgrade compatibility" {
    _setup();
    top = _directory();
    def _short { _create(top, {"password": "short-passw"}); }
    _throws(_short, "at least 12");
    def _prefs { _create(top, {"clientState": {"untrusted": "not an app preference"}}); }
    _throws(_prefs, "preferences");
    exported = _create(top, {"appVersion": "2.0.0"});
    def _newer { _stage(_directory(), exported["path"], "1.99.99"); }
    _throws(_newer, "newer");
    assert _stage(_directory(), exported["path"], "2.0.0")["summary"]["appVersion"] == "2.0.0";
    _cleanup();
}

test "cleans only unreferenced jobs and refuses traversal or pending/last/safety restore jobs" {
    _setup();
    top = _directory();
    exported = _create(top);
    staged = _stage(top, exported["path"]);
    wb_remove_job(top, exported["id"]);
    assert not os.path.exists(exported["path"]);
    def _traversal { wb_remove_job(top, "../escape"); }
    _throws(_traversal, "identifier");
    wb_commit(top, staged["id"]);
    def _pending { wb_remove_job(top, staged["id"]); }
    _throws(_pending, "needed");
    wb_apply_pending(top);
    _throws(_pending, "needed");
    _cleanup();
}

test "removes only the failed job's partial snapshot after a failure" {
    _setup();
    top = _directory();
    _write(os.path.join(top, "regular"), "data");
    keep = wb_create(top, {"password": PASSWORD});
    os.symlink(os.path.join(top, "regular"), os.path.join(top, "internal"));
    def _go { _create(top); }
    _throws(_go, "user-created symbolic link");
    assert os.listdir(os.path.join(top, ".backups")) == [keep["id"]];
    _cleanup();
}

test "restores an archive made by the TypeScript implementation" {
    # jac/harness/fixtures/ts-workspace-backup.ombbackup was written by
    # server/workspace-backup.ts (node-tar + node:crypto) before the port.
    _setup();
    target = _directory();
    fixture = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "ts-workspace-backup.ombbackup");
    staged = _stage(target, fixture, "0.1.90");
    assert staged["summary"]["appVersion"] == "0.1.90" and staged["summary"]["files"] == 6 and staged["summary"]["messages"] == 1;
    assert wb_read_staged(target, staged["id"])["clientState"] == {"omb-drafts": "{\"thread\":\"unsent\"}"};
    wb_commit(target, staged["id"]);
    assert wb_apply_pending(target)["restored"] is True;
    assert _read_bytes(os.path.join(target, "attachments", "image.png")) == bytes([0, 1, 2, 255, 0, 128]);
    assert _read_json(os.path.join(target, "bots.json"))[0]["cwd"] == os.path.join(target, "attachments");
    assert _read_json(os.path.join(target, "routines.json"))["runs"][0]["status"] == "failed";
    message = json.loads(_db_rows(os.path.join(target, "messages.db"), "SELECT json FROM messages")[0][0]);
    assert message["text"] == "See\n<attached-image path=\"" + os.path.join(target, "attachments", "image.png") + "\" name=\"image.png\" />";
    assert TS_FIXTURE_SOURCE not in json.dumps(message);
    _cleanup();
}

test "rewrites only top-level attachment markup when rebasing a transcript" {
    src = "/old/home";
    dst = "/new/home";
    tag = "<attached-file path=\"/old/home/a.txt\" name=\"a.txt\" />";
    moved = "<attached-file path=\"/new/home/a.txt\" name=\"a.txt\" />";
    cases = [
        [tag, moved],
        ["Look\n" + tag, "Look\n" + moved],
        ["Look\n" + tag + " trailing words", "Look\n" + tag + " trailing words"],
        ["> " + tag, "> " + tag],
        # micromark closes the list for an HTML flow start (no laziness).
        ["- item\n" + tag, "- item\n" + moved],
        ["> quote\n" + tag, "> quote\n" + moved],
        ["- item\n\n" + tag, "- item\n\n" + moved],
        ["```\n" + tag + "\n```", "```\n" + tag + "\n```"],
        ["    " + tag, "    " + tag],
        ["Heading\n" + tag + "\n---", "Heading\n" + tag + "\n---"],
        ["`code\n" + tag + "\nspan`", "`code\n" + tag + "\nspan`"],
        ["<div>\n" + tag + "\n</div>", "<div>\n" + tag + "\n</div>"],
        ["Prose mentions /old/home/a.txt", "Prose mentions /old/home/a.txt"],
        [tag + "\n" + tag.replace("a.txt", "b.txt"), moved + "\n" + moved.replace("a.txt", "b.txt")],
    ];
    for pair in cases {
        message = {"text": pair[0]};
        rebase_message(message, src, dst);
        assert message["text"] == pair[1], json.dumps(pair[0]) + " -> " + json.dumps(message["text"]);
    }
    escaped = {"text": "<attached-image path=\"/old/home/a&quot;b.png\" />"};
    rebase_message(escaped, src, dst);
    assert escaped["text"] == "<attached-image path=\"/new/home/a&quot;b.png\" />";
    files = {"attachments": [{"path": "/old/home/x"}, {"path": "/elsewhere/x"}], "card": {"cwd": "/old/home"}};
    rebase_message(files, src, dst);
    assert files["attachments"][0]["path"] == "/new/home/x" and files["attachments"][1]["path"] == "/elsewhere/x" and files["card"]["cwd"] == "/new/home";
}

test "path policy matches server/workspace-backup-policy.ts" {
    assert excluded_workspace_auth_path("mcp-oauth.json") and excluded_workspace_auth_path("mcp-oauth.json.123.abc-1.tmp");
    assert not excluded_workspace_auth_path("mcp-oauth.json.bak");
    assert ephemeral_workspace_token_path("hook-tokens") and ephemeral_workspace_token_path("hook-tokens/x.token") and ephemeral_workspace_token_path("sessions.json.open");
    assert not ephemeral_workspace_token_path("hook-tokens-old") and not ephemeral_workspace_token_path("sessions.json");
    assert redownloaded_org_library_path("org-library/catalog.json") and redownloaded_org_library_path("org-library/blobs/x.json");
    assert not redownloaded_org_library_path("org-library/state.json") and not redownloaded_org_library_path("org-library/presets.json");
    assert omitted_from_workspace_backup("tools/x") and omitted_from_workspace_backup("providers/a") and not omitted_from_workspace_backup("attachments/a");
    # JS `$` never matches before a trailing newline.
    assert not excluded_workspace_auth_path("browser-engine-key\n");
    # server/workspace-backup-policy.test.ts vectors.
    for p in ["mcp-oauth.json", "mcp-oauth.json.4242.05a7b3e0-1234-4abc-8def-0123456789ab.tmp"] { assert excluded_workspace_auth_path(p), p; }
    for p in ["mcp-oauth.json.md", "workspaces/bot/mcp-oauth.json"] { assert not excluded_workspace_auth_path(p), p; }
    for p in ["hook-tokens", "hook-tokens/0123456789abcdef01234567.token", "sessions.json.open"] { assert ephemeral_workspace_token_path(p), p; }
    for p in ["hook-tokens.md", "workspaces/bot/hook-tokens/notes.md", "attachments/api.token", "sessions.json.opened", "workspaces/bot/sessions.json.open"] {
        assert not ephemeral_workspace_token_path(p), p;
    }
    tmp = "05a7b3e0-1234-4abc-8def-0123456789ab";
    for p in ["org-library/catalog.json", "org-library/catalog.json." + tmp + ".tmp", "org-library/blobs", "org-library/blobs/" + ("a" * 64) + ".json", "org-library/blobs/" + ("a" * 64) + ".json." + tmp + ".tmp"] {
        assert redownloaded_org_library_path(p), p;
    }
    for p in ["org-library", "org-library/state.json", "org-library/presets.json", "org-library/catalog.json.bak", "org-library/blobs.md", "workspaces/bot/org-library/catalog.json", "attachments/org-library/blobs/x.json", "catalog.json", "blobs/x.json"] {
        assert not redownloaded_org_library_path(p), p;
    }
    for p in ["attachments/key.txt", "workspaces/bot/notes.md", "workspaces/bot/external-runtimes.json", "vm-home/project/config.json", "config.json", "webhooks.json"] {
        assert not excluded_workspace_auth_path(p), p;
    }
}

test "preserves JSON.parse key order and refuses non-JSON constants" {
    assert list(_js_parse("{\"b\":1,\"2\":2,\"a\":3,\"1\":4}").keys()) == ["1", "2", "b", "a"];
    assert js_stringify(_js_parse("{\"x\":[1,2.5,{\"10\":true,\"9\":null}]}")) == "{\"x\":[1,2.5,{\"9\":null,\"10\":true}]}";
    try {
        _js_parse("NaN");
        assert False;
    } except ValueError { }
}
