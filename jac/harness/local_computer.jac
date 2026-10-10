"""Local computer (Cua Driver on this machine) descriptor readers on Jac.

Port of the reader half of server/local-computer.ts: Electron publishes a
`cua-connection.json` descriptor; this module decodes it against the exact
certified contract and revalidates the runtime facts it names (private
descriptor, unchanged driver binary, private socket, live owner processes)
before anything may mount it. Missing, malformed, tampered or stale
descriptors are unavailable, never an error.

`gatedLocalComputer` (the stdio gate's spawn spec) stays in node: it names
node's own executable and proxy path.

Decoding follows JavaScript semantics where they differ from Python's:
Number.isInteger (bools are not numbers, 5.0 is an integer), typeof
checks, exact key sets.
"""

import os;
import re;
import sys;
import json;
import stat;
import math;

glob REQUIRED_LINUX_TOOLS: list[str] = ["click", "get_window_state", "list_apps", "type_text"];
# Keep synchronized with DRIVER_FILE_IDENTITY_KEYS in electron/cua-linux.cjs.
glob DRIVER_FILE_IDENTITY_KEYS: list[str] = ["dev", "ino", "uid", "gid", "mode", "size", "mtimeNs", "ctimeNs"];
glob LEGACY_DIRECTORIES: list[str] = ["OpenMausBot", "openmausbot", "OpenGrokBot", "opengrokbot"];

# Test seam for the def:pub surface: platform, user_data, home, uid,
# is_process_alive, validate_linux_runtime, validate_legacy_runtime.
glob _lc: dict[str, any] = {"hooks": {}};

glob _UNSET: any = object();

def local_computer_set_hooks(hooks: dict[str, any]) {
    _lc["hooks"] = dict(hooks);
}

def _node_platform -> str {
    p = sys.platform;
    if p.startswith("linux") { return "linux"; }
    if p == "darwin" { return "darwin"; }
    if p == "win32" or p == "cygwin" { return "win32"; }
    return p;
}

def _is_integer(v: any) -> bool {
    if isinstance(v, bool) { return False; }
    if isinstance(v, int) { return True; }
    return isinstance(v, float) and math.isfinite(v) and v.is_integer();
}

def _is_obj(v: any) -> bool {
    # typeof v === "object" && v !== null && !Array.isArray(v)
    return isinstance(v, dict);
}

def _exact_keys(value: dict[str, any], keys: list[str]) -> bool {
    expected = set(keys);
    return len(value) == len(expected) and all([k in expected for k in value.keys()]);
}

def _js_string(v: any) -> str {
    # String(v) for the shapes JSON can carry.
    if isinstance(v, str) { return v; }
    if v is None { return "null"; }
    if v is True { return "true"; }
    if v is False { return "false"; }
    if isinstance(v, list) { return ",".join(["" if x is None else _js_string(x) for x in v]); }
    if isinstance(v, dict) { return "[object Object]"; }
    if isinstance(v, float) and v.is_integer() { return str(int(v)); }
    return str(v);
}

def _legacy_platform(platform: str) -> any {
    return platform if platform in ["darwin", "win32"] else None;
}

def _valid_driver_file_identity(value: any) -> bool {
    if not _is_obj(value) or not _exact_keys(value, DRIVER_FILE_IDENTITY_KEYS) { return False; }
    for k in DRIVER_FILE_IDENTITY_KEYS {
        v = value[k];
        if not isinstance(v, str) or re.fullmatch(r"[0-9]+", v) is None { return False; }
    }
    return True;
}

def _current_driver_file_identity(file: str) -> dict[str, str] {
    st = os.stat(file);
    return {
        "dev": str(st.st_dev),
        "ino": str(st.st_ino),
        "uid": str(st.st_uid),
        "gid": str(st.st_gid),
        "mode": str(st.st_mode),
        "size": str(st.st_size),
        "mtimeNs": str(st.st_mtime_ns),
        "ctimeNs": str(st.st_ctime_ns),
    };
}

def _same_driver_file_identity(expected: any, actual: dict[str, str]) -> bool {
    if not _valid_driver_file_identity(expected) { return False; }
    return all([expected[k] == actual[k] for k in DRIVER_FILE_IDENTITY_KEYS]);
}

def decode_legacy_descriptor(value: any, platform: str) -> any {
    supported = _legacy_platform(platform);
    if supported is None or not _is_obj(value) { return None; }
    mode = value.get("mode");
    if not (mode == "embedded" or (supported == "darwin" and mode == "standalone")) { return None; }
    if "status" in value and value["status"] != "ready" { return None; }
    socket_path = value.get("socketPath");
    if not isinstance(socket_path, str) or not socket_path { return None; }
    command = value.get("mcpCommand");
    if not isinstance(command, str) or not command.strip() { return None; }
    args = value.get("mcpArgs");
    if not isinstance(args, list) or len(args) == 0 or args[0] != "mcp" { return None; }
    env = value.get("mcpEnv");
    if not _is_obj(env) { return None; }
    if not all([isinstance(a, str) for a in args]) { return None; }
    if not all([isinstance(v, str) for v in env.values()]) { return None; }
    return {
        "command": command,
        "args": list(args),
        "env": dict(env),
        "platform": supported,
        "scope": "local-computer",
    };
}

def _valid_doctor_warning(warning: any) -> bool {
    if not _is_obj(warning) { return False; }
    if len(warning) not in [3, 4] { return False; }
    if not all([k in ["label", "status", "message", "detail"] for k in warning.keys()]) { return False; }
    if not isinstance(warning.get("label"), str) { return False; }
    if warning.get("status") != "warn" { return False; }
    if not isinstance(warning.get("message"), str) { return False; }
    if "detail" in warning and not isinstance(warning["detail"], str) { return False; }
    return True;
}

def decode_linux_descriptor(value: any) -> any {
    if not _is_obj(value) { return None; }
    x11 = value.get("mode") == "linux-x11-supervised" and value.get("session") == "x11";
    wayland = (
        value.get("mode") == "linux-wayland-gnome-supervised"
        and value.get("session") == "wayland"
        and value.get("compositor") == "gnome-mutter"
    );
    descriptor_keys = [
        "schemaVersion", "mode", "platform", "session", "enabled", "status", "ownerPid",
        "generation", "driver", "daemon", "mcp", "toolNames", "doctorWarnings",
    ];
    if wayland { descriptor_keys.append("compositor"); }
    owner_pid = value.get("ownerPid");
    generation = value.get("generation");
    if (
        (not x11 and not wayland)
        or not _exact_keys(value, descriptor_keys)
        or not (_is_integer(value.get("schemaVersion")) and value.get("schemaVersion") == 1)
        or value.get("platform") != "linux"
        or value.get("enabled") is not True
        or value.get("status") != "ready"
        or not _is_integer(owner_pid)
        or owner_pid <= 0
        or not isinstance(generation, str)
        or re.fullmatch(r"[0-9a-fA-F-]{32,64}", generation) is None
    ) {
        return None;
    }
    driver = value.get("driver");
    daemon = value.get("daemon");
    mcp = value.get("mcp");
    if not (_is_obj(driver) and _is_obj(daemon) and _is_obj(mcp)) { return None; }
    if (
        not _exact_keys(driver, ["path", "version", "source", "manifestSchema", "fileIdentity"])
        or not _exact_keys(daemon, ["socketPath", "pid", "contractVersion", "toolsListSchemaVersion", "capabilityVersion", "mcpProtocolVersion"])
        or not _exact_keys(mcp, ["command", "args", "env"])
    ) {
        return None;
    }
    path = driver.get("path");
    socket_path = daemon.get("socketPath");
    daemon_pid = daemon.get("pid");
    args = mcp.get("args");
    env = mcp.get("env");
    if (
        not isinstance(path, str)
        or not os.path.isabs(path)
        or driver.get("version") != "0.19.3"
        or _js_string(driver.get("source")) not in ["bundled", "environment", "user-local", "path"]
        or driver.get("manifestSchema") != "1"
        or not _valid_driver_file_identity(driver.get("fileIdentity"))
        or not isinstance(socket_path, str)
        or not os.path.isabs(socket_path)
        or not _is_integer(daemon_pid)
        or daemon_pid <= 0
        or daemon.get("contractVersion") != "0.6.0"
        or daemon.get("toolsListSchemaVersion") != "1"
        or daemon.get("capabilityVersion") != "1"
        or daemon.get("mcpProtocolVersion") != "2025-06-18"
        or mcp.get("command") != path
        or not isinstance(args, list)
        or len(args) != 4
        or args[0] != "mcp"
        or args[1] != "--embedded"
        or args[2] != "--socket"
        or args[3] != socket_path
        or not _is_obj(env)
    ) {
        return None;
    }
    env_keys = [
        "CUA_DRIVER_EMBEDDED", "CUA_DRIVER_HOST_BUNDLE_ID",
        "CUA_DRIVER_RS_UPDATE_CHECK", "CUA_DRIVER_RS_TELEMETRY_ENABLED",
    ];
    if wayland { env_keys.append("CUA_DRIVER_RS_ENABLE_WAYLAND"); }
    if (
        not _exact_keys(env, env_keys)
        or env.get("CUA_DRIVER_EMBEDDED") != "1"
        or env.get("CUA_DRIVER_HOST_BUNDLE_ID") != "com.openmausbot.app"
        or env.get("CUA_DRIVER_RS_UPDATE_CHECK") != "false"
        or env.get("CUA_DRIVER_RS_TELEMETRY_ENABLED") != "false"
        or (wayland and env.get("CUA_DRIVER_RS_ENABLE_WAYLAND") != "1")
    ) {
        return None;
    }
    tools = value.get("toolNames");
    if not isinstance(tools, list) or not all([isinstance(t, str) for t in tools]) { return None; }
    if not all([name in tools for name in REQUIRED_LINUX_TOOLS]) { return None; }
    warnings = value.get("doctorWarnings");
    if not isinstance(warnings, list) { return None; }
    for warning in warnings {
        if not _valid_doctor_warning(warning) { return None; }
    }
    return {
        "command": path,
        "args": list(args),
        "env": dict(env),
        "platform": "linux",
        "generation": generation,
        "scope": "local-computer",
    };
}

def process_alive(pid: any) -> bool {
    try {
        os.kill(int(pid), 0);
        return True;
    } except Exception {
        return False;
    }
}

def _default_uid -> int {
    getuid = getattr(os, "getuid", None);
    return getuid() if getuid is not None else -1;
}

def _owned_private(st: any, uid: int) -> bool {
    return (st.st_uid == uid or st.st_uid == 0) and (st.st_mode & 0o077) == 0;
}

def _plain_file(st: any) -> bool {
    return stat.S_ISREG(st.st_mode);
}

def _plain_dir(st: any) -> bool {
    return stat.S_ISDIR(st.st_mode);
}

def validate_linux_descriptor_runtime(descriptor_file: str, raw: any, uid: any = None, is_process_alive: any = None) -> bool {
    who = uid if isinstance(uid, int) else _default_uid();
    alive = is_process_alive if is_process_alive is not None else process_alive;
    try {
        descriptor_stat = os.lstat(descriptor_file);
        descriptor_dir_stat = os.lstat(os.path.dirname(descriptor_file));
        # lstat: a symlink is never a regular file or directory here.
        if (
            not _plain_file(descriptor_stat)
            or not _owned_private(descriptor_stat, who)
            or not _plain_dir(descriptor_dir_stat)
            or not _owned_private(descriptor_dir_stat, who)
        ) {
            return False;
        }
        driver = raw["driver"];
        daemon = raw["daemon"];
        binary_path = driver["path"];
        socket_path = daemon["socketPath"];
        binary_stat = os.stat(binary_path);
        current = _current_driver_file_identity(binary_path);
        socket_stat = os.lstat(socket_path);
        socket_dir_stat = os.lstat(os.path.dirname(socket_path));
        if (
            os.path.realpath(binary_path) != binary_path
            or not _same_driver_file_identity(driver.get("fileIdentity"), current)
            or not _plain_file(binary_stat)
            or (binary_stat.st_uid != who and binary_stat.st_uid != 0)
            or (binary_stat.st_mode & 0o111) == 0
            or (binary_stat.st_mode & 0o022) != 0
            or not stat.S_ISSOCK(socket_stat.st_mode)
            or not _owned_private(socket_stat, who)
            or not _plain_dir(socket_dir_stat)
            or not _owned_private(socket_dir_stat, who)
            or not alive(raw["ownerPid"])
            or not alive(daemon["pid"])
        ) {
            return False;
        }
        return True;
    } except Exception {
        return False;
    }
}

def validate_legacy_descriptor_runtime(descriptor_file: str, platform: str, uid: any = None) -> bool {
    # Legacy darwin/win32 descriptors name any command, so the file must be
    # one only this user could have written. libuv reports every writable
    # Windows file as uid 0 mode 0o666, so only the symlink refusal applies
    # there.
    who = uid if isinstance(uid, int) else _default_uid();
    try {
        st = os.lstat(descriptor_file);
        if not _plain_file(st) { return False; }
        if platform != "win32" and (st.st_uid != who or (st.st_mode & 0o022) != 0) { return False; }
        return True;
    } except Exception {
        return False;
    }
}

def _first_present_cua_descriptor(candidates: list[str]) -> any {
    # An older fallback cannot override a present but unavailable, malformed
    # or unreadable descriptor at a more specific location.
    seen: set[str] = set();
    for file in candidates {
        if file in seen { continue; }
        seen.add(file);
        try {
            os.lstat(file);
            return file;
        } except FileNotFoundError {
            continue;
        } except Exception {
            return file;
        }
    }
    return None;
}

def _opt(opts: dict[str, any], key: str) -> any {
    if key in opts { return opts[key]; }
    hooks = _lc["hooks"];
    if key in hooks { return hooks[key]; }
    return _UNSET;
}

def _inputs(opts: dict[str, any]) -> dict[str, any] {
    platform = _opt(opts, "platform");
    user_data = _opt(opts, "user_data");
    home = _opt(opts, "home");
    return {
        "platform": platform if isinstance(platform, str) else _node_platform(),
        "user_data": os.environ.get("OMB_USER_DATA") if user_data is _UNSET else user_data,
        "home": os.path.expanduser("~") if home is _UNSET or not isinstance(home, str) else home,
    };
}

def _candidates(platform: str, user_data: any, home: str) -> list[str] {
    out: list[str] = [];
    if user_data { out.append(os.path.join(user_data, "cua-connection.json")); }
    if platform == "darwin" and not user_data {
        # Legacy/dev fallback only when Electron did not provide its exact path.
        for d in LEGACY_DIRECTORIES {
            out.append(os.path.join(home, "Library", "Application Support", d, "cua-connection.json"));
        }
    }
    return out;
}

def _read_json(file: str) -> any {
    with open(file, "r", encoding="utf-8") as f {
        return json.loads(f.read());
    }
}

def read_cua_connection(opts: dict[str, any] = {}) -> any {
    inp = _inputs(opts);
    platform = inp["platform"];
    file = _first_present_cua_descriptor(_candidates(platform, inp["user_data"], inp["home"]));
    if file is None { return None; }
    uid = _opt(opts, "uid");
    uid_arg: any = uid if isinstance(uid, int) else None;
    alive = _opt(opts, "is_process_alive");
    alive_arg: any = None if alive is _UNSET else alive;
    try {
        raw = _read_json(file);
        if platform == "linux" {
            decoded = decode_linux_descriptor(raw);
            check = _opt(opts, "validate_linux_runtime");
            ok = False;
            if decoded is not None {
                if check is _UNSET or check is None {
                    ok = validate_linux_descriptor_runtime(file, raw, uid_arg, alive_arg);
                } else {
                    ok = bool(check(file, raw));
                }
            }
            if ok { return decoded; }
        } else {
            decoded = decode_legacy_descriptor(raw, platform);
            check = _opt(opts, "validate_legacy_runtime");
            ok = False;
            if decoded is not None {
                if check is _UNSET or check is None {
                    ok = validate_legacy_descriptor_runtime(file, platform, uid_arg);
                } else {
                    ok = bool(check(file, platform));
                }
            }
            if ok { return decoded; }
        }
    } except Exception {
        # Missing, invalid, tampered, or stale descriptors are unavailable.
    }
    return None;
}

def read_cua_unavailable_reason(opts: dict[str, any] = {}) -> any {
    # Diagnostic only: never a connection, and only a private, well-formed
    # macOS/Windows descriptor may supply text.
    inp = _inputs(opts);
    platform = inp["platform"];
    if _legacy_platform(platform) is None { return None; }
    file = _first_present_cua_descriptor(_candidates(platform, inp["user_data"], inp["home"]));
    if file is None { return None; }
    uid = _opt(opts, "uid");
    try {
        if validate_legacy_descriptor_runtime(file, platform, uid if isinstance(uid, int) else None) {
            raw = _read_json(file);
            if _is_obj(raw) and len(raw) == 2 and raw.get("mode") == "unavailable" {
                reason = raw.get("reason");
                if isinstance(reason, str) and reason.strip() and len(reason) <= 2000 {
                    return reason.strip();
                }
            }
        }
    } except Exception {
        # No usable diagnostic; the caller still refuses computer control.
    }
    return None;
}

# ── HTTP surface (re-bound onto harness.jac as computer_cua_*) ─────────────

def _guard(omb_token: any) -> any {
    want = os.environ.get("OMB_JAC_TOKEN");
    if want and omb_token != want {
        return {"ok": False, "status": 403, "error": "unauthorized"};
    }
    return None;
}

def:pub computer_cua_connection(omb_token: any = None) -> dict[str, any] {
    g = _guard(omb_token);
    if g is not None { return g; }
    return {"connection": read_cua_connection({})};
}

def:pub computer_cua_unavailable_reason(omb_token: any = None) -> dict[str, any] {
    g = _guard(omb_token);
    if g is not None { return g; }
    return {"reason": read_cua_unavailable_reason({})};
}
