"""Invariants ported from server/local-computer.test.ts.

Not ported: the two gatedLocalComputer tests (the stdio gate's spawn spec
stays in node, with its tests). The Electron-sync test is kept by reading
the producer sources as text.
"""

import os;
import json;
import shutil;
import socket;
import tempfile;

glob _tmp_dirs: list[str] = [];

def _private_user_data(name: str) -> str {
    base = os.path.realpath("/tmp");
    top = tempfile.mkdtemp(prefix="omb-local-computer-", dir=base);
    _tmp_dirs.append(top);
    user_data = os.path.join(top, name);
    os.makedirs(user_data, mode=0o700, exist_ok=True);
    os.chmod(user_data, 0o700);
    return user_data;
}

def _cleanup {
    while _tmp_dirs {
        shutil.rmtree(_tmp_dirs.pop(), ignore_errors=True);
    }
}

def _write(path: str, value: any, mode: any = None) {
    exists = os.path.exists(path);
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC;
    fd = os.open(path, flags, mode if mode is not None else 0o666);
    with os.fdopen(fd, "w", encoding="utf-8") as fh {
        fh.write(value if isinstance(value, str) else json.dumps(value));
    }
    if mode is not None and not exists { os.chmod(path, mode); }
}

def _identity(file: str) -> dict[str, str] {
    st = os.stat(file);
    return {
        "dev": str(st.st_dev), "ino": str(st.st_ino), "uid": str(st.st_uid), "gid": str(st.st_gid),
        "mode": str(st.st_mode), "size": str(st.st_size), "mtimeNs": str(st.st_mtime_ns), "ctimeNs": str(st.st_ctime_ns),
    };
}

def _linux_descriptor(user_data: str, session: str = "x11") -> dict[str, any] {
    binary = os.path.join(user_data, "cua-driver");
    sock = os.path.join(user_data, "runtime", "driver.sock");
    _write(binary, "fake", 0o700);
    env = {
        "CUA_DRIVER_EMBEDDED": "1",
        "CUA_DRIVER_HOST_BUNDLE_ID": "com.openmausbot.app",
        "CUA_DRIVER_RS_UPDATE_CHECK": "false",
        "CUA_DRIVER_RS_TELEMETRY_ENABLED": "false",
    };
    if session == "wayland" { env["CUA_DRIVER_RS_ENABLE_WAYLAND"] = "1"; }
    d = {
        "schemaVersion": 1,
        "mode": "linux-wayland-gnome-supervised" if session == "wayland" else "linux-x11-supervised",
        "platform": "linux",
        "session": session,
        "enabled": True,
        "status": "ready",
        "ownerPid": os.getpid(),
        "generation": "01234567-89ab-cdef-0123-456789abcdef",
        "driver": {"path": binary, "version": "0.19.3", "source": "environment", "manifestSchema": "1", "fileIdentity": _identity(binary)},
        "daemon": {
            "socketPath": sock, "pid": os.getpid(), "contractVersion": "0.6.0",
            "toolsListSchemaVersion": "1", "capabilityVersion": "1", "mcpProtocolVersion": "2025-06-18",
        },
        "mcp": {"command": binary, "args": ["mcp", "--embedded", "--socket", sock], "env": env},
        "toolNames": ["click", "get_window_state", "list_apps", "type_text"],
        "doctorWarnings": [],
    };
    if session == "wayland" { d["compositor"] = "gnome-mutter"; }
    return d;
}

def _with(base: dict[str, any], more: dict[str, any]) -> dict[str, any] {
    out = dict(base);
    out.update(more);
    return out;
}

def _always_true(a: any, b: any) -> bool { return True; }
def _always_false(a: any, b: any) -> bool { return False; }

def _expected(d: dict[str, any]) -> dict[str, any] {
    return {
        "command": d["driver"]["path"], "args": d["mcp"]["args"], "env": d["mcp"]["env"],
        "platform": "linux", "generation": d["generation"], "scope": "local-computer",
    };
}

glob _LEGACY_CONNECTION: dict[str, any] = {
    "mode": "embedded", "socketPath": "/fixture/stale.sock", "mcpCommand": "/fixture/stale-driver",
    "mcpArgs": ["mcp"], "mcpEnv": {},
};

test "stays synchronized with the Electron producer" {
    here = os.path.dirname(os.path.abspath(__file__));
    electron = os.path.join(here, "..", "..", "electron");
    with open(os.path.join(electron, "cua-linux.cjs"), "r", encoding="utf-8") as fh {
        src = fh.read();
    }
    start = src.index("const DRIVER_FILE_IDENTITY_KEYS = Object.freeze([");
    block = src[start:src.index("]);", start)];
    assert [ln.strip().strip(",").strip("\"") for ln in block.split("\n")[1:] if ln.strip()] == DRIVER_FILE_IDENTITY_KEYS;
    with open(os.path.join(electron, "cua-linux-runtime.cjs"), "r", encoding="utf-8") as fh {
        rt = fh.read();
    }
    assert "const REQUIRED_TOOLS = " + json.dumps(REQUIRED_LINUX_TOOLS) + ";" in rt;
}

test "reports a private unavailable reason without making that descriptor mountable" {
    try {
        user_data = _private_user_data("mac-unavailable");
        file = os.path.join(user_data, "cua-connection.json");
        reason = "embedded host failed: Screen Recording required; grant access in System Settings and restart OpenMausBot";
        _write(file, {"mode": "unavailable", "reason": reason}, 0o600);
        opts = {"platform": "darwin", "user_data": user_data};
        assert read_cua_connection(opts) is None;
        assert read_cua_unavailable_reason(opts) == reason;
        _write(file, {"mode": "unavailable", "reason": {"message": reason}});
        assert read_cua_unavailable_reason(opts) is None;
        _write(file, {"mode": "unavailable", "reason": reason, "mcpCommand": "/fixture/driver"});
        assert read_cua_unavailable_reason(opts) is None;
    } finally {
        _cleanup();
    }
}

test "rejects an explicitly unavailable or malformed status on an otherwise complete connection" {
    try {
        user_data = _private_user_data("contradictory-status");
        file = os.path.join(user_data, "cua-connection.json");
        connection = {"mode": "embedded", "socketPath": "/fixture/cua.sock", "mcpCommand": "/fixture/cua-driver", "mcpArgs": ["mcp"], "mcpEnv": {}};
        for status in ["unavailable", None, {}] {
            _write(file, _with(connection, {"status": status}), 0o600);
            assert read_cua_connection({"platform": "darwin", "user_data": user_data}) is None;
            assert read_cua_connection({"platform": "win32", "user_data": user_data}) is None;
        }
        _write(file, _with(connection, {"status": "ready"}), 0o600);
        assert read_cua_connection({"platform": "darwin", "user_data": user_data})["command"] == "/fixture/cua-driver";
    } finally {
        _cleanup();
    }
}

test "never substitutes a stale legacy descriptor for the packaged app's exact status" {
    try {
        user_data = _private_user_data("exact-mac-user-data");
        home = os.path.join(user_data, "fixture-home");
        legacy = os.path.join(home, "Library", "Application Support", "OpenMausBot");
        os.makedirs(legacy, mode=0o700);
        legacy_file = os.path.join(legacy, "cua-connection.json");
        _write(legacy_file, _LEGACY_CONNECTION, 0o600);
        exact_file = os.path.join(user_data, "cua-connection.json");
        reason = "Screen Recording required; grant access in System Settings and restart OpenMausBot";
        _write(exact_file, {"mode": "unavailable", "reason": reason}, 0o600);
        opts = {"platform": "darwin", "user_data": user_data, "home": home};
        assert read_cua_connection(opts) is None;
        assert read_cua_unavailable_reason(opts) == reason;
        _write(legacy_file, {"mode": "unavailable", "reason": "stale legacy failure"});
        _write(exact_file, {"mode": "embedded"});
        assert read_cua_connection(opts) is None;
        assert read_cua_unavailable_reason(opts) is None;
    } finally {
        _cleanup();
    }
}

test "treats the first present legacy descriptor as authoritative" {
    try {
        home = _private_user_data("legacy-mac-home");
        first = os.path.join(home, "Library", "Application Support", "OpenMausBot");
        stale = os.path.join(home, "Library", "Application Support", "OpenGrokBot");
        os.makedirs(first, mode=0o700);
        os.makedirs(stale, mode=0o700);
        reason = "Accessibility required; grant access in System Settings and restart OpenMausBot";
        _write(os.path.join(first, "cua-connection.json"), {"mode": "unavailable", "reason": reason}, 0o600);
        _write(os.path.join(stale, "cua-connection.json"), _LEGACY_CONNECTION, 0o600);
        opts = {"platform": "darwin", "home": home, "user_data": ""};
        assert read_cua_connection(opts) is None;
        assert read_cua_unavailable_reason(opts) == reason;
    } finally {
        _cleanup();
    }
}

test "accepts only the exact certified Linux X11 descriptor" {
    try {
        user_data = _private_user_data("linux-user-data");
        d = _linux_descriptor(user_data);
        _write(os.path.join(user_data, "cua-connection.json"), d, 0o600);
        got = read_cua_connection({"platform": "linux", "user_data": user_data, "validate_linux_runtime": _always_true});
        assert got == _expected(d);
    } finally {
        _cleanup();
    }
}

test "accepts the exact GNOME Wayland descriptor without weakening the X11 contract" {
    try {
        user_data = _private_user_data("linux-wayland-user-data");
        d = _linux_descriptor(user_data, "wayland");
        assert decode_linux_descriptor(d) == _expected(d);
        assert decode_linux_descriptor(_with(d, {"compositor": "kde-kwin"})) is None;
        x11_only_env = dict(d["mcp"]["env"]);
        del x11_only_env["CUA_DRIVER_RS_ENABLE_WAYLAND"];
        assert decode_linux_descriptor(_with(d, {"mcp": _with(d["mcp"], {"env": x11_only_env})})) is None;
        x11 = _linux_descriptor(user_data);
        assert decode_linux_descriptor(_with(x11, {"mcp": _with(x11["mcp"], {"env": _with(x11["mcp"]["env"], {"CUA_DRIVER_RS_ENABLE_WAYLAND": "1"})})})) is None;
    } finally {
        _cleanup();
    }
}

test "rejects unknown fields, stale modes, arbitrary argv, and incomplete tool surfaces" {
    try {
        user_data = _private_user_data("linux-invalid-user-data");
        d = _linux_descriptor(user_data);
        assert decode_linux_descriptor(d) is not None;
        assert decode_linux_descriptor(_with(d, {"unexpected": True})) is None;
        assert decode_linux_descriptor(_with(d, {"status": "starting"})) is None;
        telemetry_missing = dict(d["mcp"]["env"]);
        del telemetry_missing["CUA_DRIVER_RS_TELEMETRY_ENABLED"];
        assert decode_linux_descriptor(_with(d, {"mcp": _with(d["mcp"], {"env": telemetry_missing})})) is None;
        assert decode_linux_descriptor(_with(d, {"mcp": _with(d["mcp"], {"args": ["mcp", "--socket", d["daemon"]["socketPath"], "--evil"]})})) is None;
        assert decode_linux_descriptor(_with(d, {"toolNames": ["list_apps"]})) is None;
        assert decode_linux_descriptor(_with(d, {"mcp": _with(d["mcp"], {"env": _with(d["mcp"]["env"], {"CUA_DRIVER_RS_TELEMETRY_ENABLED": "true"})})})) is None;
        assert decode_linux_descriptor(_with(d, {"driver": _with(d["driver"], {"fileIdentity": _with(d["driver"]["fileIdentity"], {"extra": "1"})})})) is None;
        no_identity = dict(d["driver"]);
        del no_identity["fileIdentity"];
        assert decode_linux_descriptor(_with(d, {"driver": no_identity})) is None;
    } finally {
        _cleanup();
    }
}

test "applies JavaScript number semantics to pids and the schema version" {
    try {
        user_data = _private_user_data("linux-js-numbers");
        d = _linux_descriptor(user_data);
        assert decode_linux_descriptor(_with(d, {"ownerPid": float(os.getpid())})) is not None;
        assert decode_linux_descriptor(_with(d, {"schemaVersion": 1.0})) is not None;
        assert decode_linux_descriptor(_with(d, {"schemaVersion": True})) is None;
        assert decode_linux_descriptor(_with(d, {"ownerPid": True})) is None;
        assert decode_linux_descriptor(_with(d, {"ownerPid": 1.5})) is None;
        assert decode_linux_descriptor(_with(d, {"ownerPid": 0})) is None;
        assert decode_linux_descriptor(_with(d, {"generation": "not-a-generation"})) is None;
        assert decode_linux_descriptor(_with(d, {"doctorWarnings": [{"label": "x", "status": "warn", "message": "m"}]})) is not None;
        assert decode_linux_descriptor(_with(d, {"doctorWarnings": [{"label": "x", "status": "warn", "message": "m", "detail": None}]})) is None;
        assert decode_linux_descriptor(_with(d, {"doctorWarnings": [{"label": "x", "status": "fail", "message": "m"}]})) is None;
    } finally {
        _cleanup();
    }
}

test "fails closed when runtime ownership or liveness validation fails" {
    try {
        user_data = _private_user_data("linux-stale-user-data");
        d = _linux_descriptor(user_data);
        _write(os.path.join(user_data, "cua-connection.json"), d, 0o600);
        assert read_cua_connection({"platform": "linux", "user_data": user_data, "validate_linux_runtime": _always_false}) is None;
    } finally {
        _cleanup();
    }
}

test "validates private descriptor, executable, socket, and live owned processes" {
    try {
        user_data = _private_user_data("linux-runtime-security");
        runtime_dir = os.path.join(user_data, "runtime");
        os.mkdir(runtime_dir, 0o700);
        d = _linux_descriptor(user_data);
        file = os.path.join(user_data, "cua-connection.json");
        _write(file, d, 0o600);
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM);
        srv.bind(d["daemon"]["socketPath"]);
        srv.listen(1);
        try {
            os.chmod(d["daemon"]["socketPath"], 0o600);
            assert validate_linux_descriptor_runtime(file, d);
            assert read_cua_connection({"platform": "linux", "user_data": user_data}) is not None;
            os.chmod(file, 0o644);
            assert not validate_linux_descriptor_runtime(file, d);
            os.chmod(file, 0o600);
            assert validate_linux_descriptor_runtime(file, d);
            def _dead(pid: any) -> bool { return False; }
            assert not validate_linux_descriptor_runtime(file, d, None, _dead);
            with open(d["driver"]["path"], "a") as fh {
                fh.write("changed after descriptor publication");
            }
            assert not validate_linux_descriptor_runtime(file, d);
            assert read_cua_connection({"platform": "linux", "user_data": user_data}) is None;
        } finally {
            srv.close();
        }
    } finally {
        _cleanup();
    }
}

test "still rejects an old embedded-looking Linux descriptor" {
    try {
        user_data = _private_user_data("linux-forged-user-data");
        _write(os.path.join(user_data, "cua-connection.json"), {
            "mode": "embedded", "mcpCommand": "/tmp/cua-driver",
            "mcpArgs": ["mcp", "--embedded"], "mcpEnv": {"CUA_DRIVER_EMBEDDED": "1"},
        }, 0o600);
        assert read_cua_connection({"platform": "linux", "user_data": user_data}) is None;
    } finally {
        _cleanup();
    }
}

test "preserves the selected Windows descriptor contract" {
    try {
        user_data = _private_user_data("windows-user-data");
        _write(os.path.join(user_data, "cua-connection.json"), {
            "mode": "embedded", "socketPath": "\\\\.\\pipe\\cua-driver",
            "mcpCommand": "C:\\cua-driver.exe", "mcpArgs": ["mcp"], "mcpEnv": {"CUA_DRIVER_EMBEDDED": "1"},
        });
        assert read_cua_connection({"platform": "win32", "user_data": user_data}) == {
            "command": "C:\\cua-driver.exe", "args": ["mcp"], "env": {"CUA_DRIVER_EMBEDDED": "1"},
            "platform": "win32", "scope": "local-computer",
        };
    } finally {
        _cleanup();
    }
}

test "rejects malformed legacy argv and environment values" {
    try {
        user_data = _private_user_data("invalid-user-data");
        file = os.path.join(user_data, "cua-connection.json");
        _write(file, {"mode": "embedded", "mcpCommand": "cua-driver", "mcpArgs": "mcp"});
        assert read_cua_connection({"platform": "win32", "user_data": user_data}) is None;
        _write(file, {"mode": "unknown", "mcpCommand": "cua-driver", "mcpArgs": ["mcp"]});
        assert read_cua_connection({"platform": "win32", "user_data": user_data}) is None;
    } finally {
        _cleanup();
    }
}

test "a darwin legacy descriptor writable by others is not trusted" {
    try {
        user_data = _private_user_data("mac-world-writable");
        file = os.path.join(user_data, "cua-connection.json");
        _write(file, _LEGACY_CONNECTION, 0o600);
        os.chmod(file, 0o666);
        assert read_cua_connection({"platform": "darwin", "user_data": user_data}) is None;
        os.chmod(file, 0o600);
        assert read_cua_connection({"platform": "darwin", "user_data": user_data}) is not None;
    } finally {
        _cleanup();
    }
}

test "public endpoints read through the hook table" {
    try {
        user_data = _private_user_data("pub-surface");
        _write(os.path.join(user_data, "cua-connection.json"), {"mode": "unavailable", "reason": "  needs Accessibility  "}, 0o600);
        local_computer_set_hooks({"platform": "darwin", "user_data": user_data});
        assert computer_cua_connection() == {"connection": None};
        assert computer_cua_unavailable_reason() == {"reason": "needs Accessibility"};
        local_computer_set_hooks({"platform": "linux", "user_data": user_data});
        assert computer_cua_unavailable_reason() == {"reason": None};
    } finally {
        local_computer_set_hooks({});
        _cleanup();
    }
}
