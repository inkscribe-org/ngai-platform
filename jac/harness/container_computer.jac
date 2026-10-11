"""Local VM lifecycle on Jac (phase 4, computers).

Port of the I/O half of server/container-computer.ts: runtime detection,
container inspection/readiness, lifecycle actions, the screen frame and
containerExec. The pure contract (constants, argv builders, setup commands,
the MCP spawn spec) stays in TypeScript because the deferred VPS tier and
the spawned node proxies import it; the parts this module needs are
duplicated here and pinned by drift guards in container_computer.test.jac
(Dockerfile sha256, golden argv).

Targets arrive from node as {key, containerName, workspaceDir, viewerPort,
label}. Every CLI call goes through a runner: production runs the real
binary with node's augmented PATH (OMB_EXTRA_PATH first, so the fake docker
index.test.ts injects keeps working); tests swap `_cv["hooks"]`.

Sync def:pub endpoints run in the Jac threadpool concurrently, so the
screenshot status cache is guarded by a lock.
"""

import os;
import re;
import sys;
import json;
import math;
import time;
import shutil;
import base64;
import hashlib;
import secrets;
import tempfile;
import threading;
import subprocess;
import urllib.parse;
import concurrent.futures;

import from db { DATA_DIR }

glob SCREENSHOT_STATUS_TTL_MS: int = 10000;
glob CUA_DRIVER_VERSION: str = "0.20.0";
glob BASE_IMAGE_REPOSITORY: str = "docker.io/trycua/xfce-cua";
glob BASE_IMAGE_DIGEST: str = "sha256:274eb636f5cf3fc58f705916ee72b7a701270b3877369d08533a385c5325be9b";
glob BASE_IMAGE: str = BASE_IMAGE_REPOSITORY + "@" + BASE_IMAGE_DIGEST;
glob IMAGE_REPOSITORY: str = "localhost/openmausbot/cua-local-vm";
glob IMAGE_LAYER_VERSION: str = "5";
glob IMAGE_LAYER_LABEL: str = "com.openmausbot.image-layer";
glob IMAGE: str = IMAGE_REPOSITORY + ":driver-" + CUA_DRIVER_VERSION + "-v" + IMAGE_LAYER_VERSION;
glob CONTAINER: str = "openmausbot-computer";
glob MANAGED_LABEL: str = "com.openmausbot.local-vm";
glob DRIVER_LABEL: str = "com.openmausbot.cua-driver";
glob BASE_IMAGE_LABEL: str = "com.openmausbot.cua-base";
glob WORKSPACE_LABEL: str = "com.openmausbot.workspace";
glob TARGET_LABEL: str = "com.openmausbot.local-vm-target";
glob VM_WORKSPACE_DIR: str = os.path.join(DATA_DIR, "vm-home");
glob VM_WORKSPACE_GUEST: str = "/home/cua/workspace";
glob DISPLAY: str = ":1";
glob CUA_SOCKET: str = "/run/user/1000/openmausbot-cua.sock";
glob CUA_EXECUTABLE: str = "/usr/local/libexec/openmausbot/cua-driver";

glob RUNTIMES: list[str] = ["docker", "podman", "container"];
glob LIFECYCLE_ACTIONS: list[str] = ["pull", "run", "start", "stop", "remove"];
glob INTERNAL_VIEWER_PORT: int = 6901;
glob HOST_VIEWER_PORT: int = 6080;
glob MEMORY_BYTES: int = 4 * 1024 * 1024 * 1024;
glob PIDS_LIMIT: int = 512;

glob EXEC_DEFAULT_SECONDS: int = 60;
glob EXEC_MAX_SECONDS: int = 300;
glob EXEC_OUTPUT_LIMIT: int = 20000;

glob SHARED_LOCAL_VM_TARGET: dict[str, any] = {
    "key": "shared",
    "containerName": CONTAINER,
    "workspaceDir": VM_WORKSPACE_DIR,
    "viewerPort": HOST_VIEWER_PORT,
    "label": "shared",
};

# Module state: injectable hooks (tests) and the frame poller's status cache.
glob _cv: dict[str, any] = {"hooks": {}, "cache": {}};
glob _cv_lock: any = threading.Lock();

# Test fixture seam (server/testing/group-local-vm-hooks.mjs): when
# OMB_TEST_VM_STATE is set, the container boundary below is the state file's
# fixture. Before the computers port the same fixture was a node-side module
# mock of container-computer.ts; the boundary now lives here, so the fixture
# had to move with it. Only e2e fixtures and behavior evals set the variable.
glob TEST_VM_STATE: str = os.environ.get("OMB_TEST_VM_STATE") or "";

class ContainerError(Exception) {
    # Error carrying an HTTP status (JS `Object.assign(new Error, {status})`).
}

def _fail(status: int, message: str) {
    err = ContainerError(message);
    setattr(err, "status", status);
    raise err;
}

def _status_of(e: Exception) -> int {
    s = getattr(e, "status", None);
    return s if isinstance(s, int) and not isinstance(s, bool) else 500;
}

# ── JS-semantics helpers ───────────────────────────────────────────────────

glob _MISSING: any = object();

def _g(value: any, key: any) -> any {
    # `value?.[key]` over parsed JSON: undefined (None) unless an object.
    if isinstance(value, dict) {
        return value.get(key);
    }
    if isinstance(value, list) and isinstance(key, int) and not isinstance(key, bool) {
        return value[key] if 0 <= key and key < len(value) else None;
    }
    return None;
}

def _has(value: any, key: str) -> bool {
    return isinstance(value, dict) and key in value;
}

def _coalesce(values: list[any]) -> any {
    for v in values {
        if v is not None { return v; }
    }
    return None;
}

def _truthy(v: any) -> bool {
    # JavaScript truthiness (arrays/objects are always truthy).
    if v is None or v is False { return False; }
    if isinstance(v, bool) { return True; }
    if isinstance(v, (int, float)) {
        return not (v == 0 or (isinstance(v, float) and math.isnan(v)));
    }
    if isinstance(v, str) { return len(v) > 0; }
    return True;
}

def _is_num(v: any) -> bool {
    return isinstance(v, (int, float)) and not isinstance(v, bool);
}

def _num_eq(v: any, n: int) -> bool {
    return _is_num(v) and v == n;
}

def _is_integer(v: any) -> bool {
    # Number.isInteger: a number with no fraction (5.0 counts).
    if isinstance(v, bool) { return False; }
    if isinstance(v, int) { return True; }
    return isinstance(v, float) and math.isfinite(v) and v.is_integer();
}

def _js_number(v: any) -> float {
    # Number(v) for the scalar shapes inspect output carries.
    if isinstance(v, bool) { return 1.0 if v else 0.0; }
    if isinstance(v, (int, float)) { return float(v); }
    if isinstance(v, str) {
        s = v.strip();
        if s == "" { return 0.0; }
        if not re.fullmatch(r"[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?", s) {
            return float("nan");
        }
        return float(s);
    }
    return float("nan");
}

def _js_str(v: any) -> str {
    if v is True { return "true"; }
    if v is False { return "false"; }
    if v is None { return "null"; }
    if isinstance(v, float) and v.is_integer() { return str(int(v)); }
    if isinstance(v, (dict, list)) { return "[object Object]" if isinstance(v, dict) else ",".join([_js_str(x) for x in v]); }
    return str(v);
}

def _node_platform -> str {
    p = sys.platform;
    if p.startswith("linux") { return "linux"; }
    if p == "darwin" { return "darwin"; }
    if p == "win32" or p == "cygwin" { return "win32"; }
    return p;
}

# ── PATH (port of server/env-path.ts augmentedPath, without the login-shell
#    probe and app-registered dirs, which never carry a container runtime) ──

def _version_key(name: str) -> list[any] {
    parts = re.split(r"(\d+)", name);
    out: list[any] = [];
    for p in parts {
        if p.isdigit() { out.append((1, int(p), "")); }
        else { out.append((0, 0, p)); }
    }
    return out;
}

def _nvm_bin_dirs(home: str) -> list[str] {
    base = os.path.join(home, ".nvm", "versions", "node");
    try {
        versions = [v for v in os.listdir(base) if v.startswith("v")];
    } except Exception {
        return [];
    }
    versions.sort(key=_version_key, reverse=True);
    return [os.path.join(base, v, "bin") for v in versions];
}

def _known_dirs(home: str) -> list[str] {
    sealed = os.environ.get("OMB_TEST_SEALED_PATH") == "1";
    dirs = [
        os.path.join(home, ".local", "bin"),
        os.path.join(home, ".npm-global", "bin"),
        os.path.join(home, ".kimi-code", "bin"),
        os.path.join(home, ".grok", "bin"),
        os.path.join(home, ".opencode", "bin"),
        os.path.join(home, ".claude", "local"),
    ];
    if not sealed {
        dirs.extend(["/opt/homebrew/bin", "/usr/local/bin"]);
    }
    dirs.extend([
        os.path.join(home, ".volta", "bin"),
        os.path.join(home, ".bun", "bin"),
        os.path.join(home, ".asdf", "shims"),
        os.path.join(home, ".local", "share", "mise", "shims"),
        os.path.join(home, ".deno", "bin"),
        os.path.join(home, "bin"),
    ]);
    dirs.extend(_nvm_bin_dirs(home));
    return dirs;
}

def _windows_known_dirs(home: str) -> list[str] {
    app_data = os.environ.get("APPDATA") or os.path.join(home, "AppData", "Roaming");
    local_app_data = os.environ.get("LOCALAPPDATA") or os.path.join(home, "AppData", "Local");
    program_files = os.environ.get("ProgramFiles") or "C:\\Program Files";
    return [
        os.path.join(app_data, "npm"),
        os.path.join(home, ".grok", "bin"),
        os.path.join(local_app_data, "agy", "bin"),
        os.path.join(local_app_data, "cursor-agent"),
        os.path.join(home, ".local", "bin"),
        os.path.join(home, ".claude", "local"),
        os.path.join(home, "bin"),
        os.path.join(home, ".bun", "bin"),
        os.path.join(home, ".deno", "bin"),
        os.path.join(home, "go", "bin"),
        os.path.join(program_files, "Docker", "Docker", "resources", "bin"),
    ];
}

def augmented_path -> str {
    home = os.path.expanduser("~");
    parts: list[str] = [];
    extra = os.environ.get("OMB_EXTRA_PATH");
    if extra { parts.extend(extra.split(os.pathsep)); }
    inherited = os.environ.get("PATH");
    if inherited { parts.extend(inherited.split(os.pathsep)); }
    known = _windows_known_dirs(home) if _node_platform() == "win32" else _known_dirs(home);
    parts.extend([d for d in known if os.path.exists(d)]);
    seen: set[str] = set();
    merged: list[str] = [];
    for p in parts {
        if p and p not in seen {
            seen.add(p);
            merged.append(p);
        }
    }
    return os.pathsep.join(merged);
}

# ── command runners ────────────────────────────────────────────────────────

def _spawn(command: str, args: list[str], timeout_ms: int) -> any {
    path = augmented_path();
    env = dict(os.environ);
    env["PATH"] = path;
    exe = command;
    if os.sep not in command and "/" not in command {
        found = shutil.which(command, path=path);
        if found { exe = found; }
    }
    return subprocess.run(
        [exe] + list(args),
        capture_output=True,
        stdin=subprocess.DEVNULL,
        timeout=timeout_ms / 1000.0,
        env=env,
        encoding="utf-8",
        errors="replace",
    );
}

def _default_run(command: str, args: list[str], timeout_ms: int = 8000) -> str {
    # execFile semantics: a non-zero exit, a timeout or a missing binary
    # rejects; the message mirrors node's "Command failed: ...".
    try {
        proc = _spawn(command, args, timeout_ms);
    } except subprocess.TimeoutExpired {
        raise Exception(f"Command failed: {command} {' '.join(args)}\n(timed out)");
    }
    if proc.returncode != 0 {
        raise Exception(f"Command failed: {command} {' '.join(args)}\n{proc.stderr or ''}");
    }
    return proc.stdout or "";
}

def _default_exec(command: str, args: list[str], timeout_ms: int) -> dict[str, any] {
    try {
        proc = _spawn(command, args, timeout_ms);
    } except subprocess.TimeoutExpired {
        _fail(502, "the command client timed out");
    } except Exception as e {
        _fail(502, str(e) or "could not run the command");
    }
    if proc.returncode < 0 {
        _fail(502, f"Command failed: {command} {' '.join(args)}");
    }
    return {"stdout": proc.stdout or "", "stderr": proc.stderr or "", "code": proc.returncode};
}

def _hook_run -> any {
    r = _cv["hooks"].get("run");
    return r if r is not None else _default_run;
}

def _hook_exec -> any {
    r = _cv["hooks"].get("exec");
    return r if r is not None else _default_exec;
}

def _hook_platform -> str {
    p = _cv["hooks"].get("platform");
    return p if isinstance(p, str) else _node_platform();
}

def container_set_hooks(hooks: dict[str, any]) {
    # Test seam: {"run", "exec", "platform"}; {} restores production.
    _cv["hooks"] = dict(hooks);
    with _cv_lock {
        _cv["cache"].clear();
    }
}

def _cacheable(run: any, platform: str) -> bool {
    return run is _default_run and platform == _node_platform();
}

def _cache_delete(key: str) {
    with _cv_lock {
        _cv["cache"].pop(key, None);
    }
}

# ── targets ────────────────────────────────────────────────────────────────

def per_bot_local_vm_target(bot_id: str) -> dict[str, any] {
    digest = hashlib.sha256(bot_id.encode("utf-8")).hexdigest();
    short = digest[:16];
    return {
        "key": "bot:" + digest,
        "containerName": CONTAINER + "-" + short,
        "workspaceDir": os.path.join(DATA_DIR, "vm-homes", short),
        "viewerPort": None,
        "label": digest,
    };
}

def pool_local_vm_target(seat: int) -> dict[str, any] {
    return {
        "key": f"pool:{seat}",
        "containerName": f"{CONTAINER}-p{seat}",
        "workspaceDir": os.path.join(DATA_DIR, "vm-homes", f"pool-{seat}"),
        "viewerPort": None,
        "label": f"pool-{seat}",
    };
}

def _target_arg(target: any) -> dict[str, any] {
    if not isinstance(target, dict) { _fail(400, "target is required"); }
    for k in ["key", "containerName", "workspaceDir", "label"] {
        v = target.get(k);
        if not isinstance(v, str) or not v { _fail(400, f"target.{k} must be a non-empty string"); }
    }
    port = target.get("viewerPort");
    if port is not None and not (_is_integer(port) and 0 < port and port <= 65535) {
        _fail(400, "target.viewerPort must be a port or null");
    }
    return {
        "key": target["key"],
        "containerName": target["containerName"],
        "workspaceDir": target["workspaceDir"],
        "viewerPort": int(port) if port is not None else None,
        "label": target["label"],
    };
}

# ── pure contract (duplicated from server/container-computer.ts) ───────────

def managed_image_dockerfile -> str {
    lines = [
        "FROM " + BASE_IMAGE + "\n",
        "USER root\n",
        "RUN set -eux; \\\n",
        "    arch=\"$(uname -m)\"; \\\n",
        "    case \"$arch\" in \\\n",
        "      x86_64) wheel_url='https://files.pythonhosted.org/packages/fa/d7/a43008a328a40c85e7bc706fc20235b9abedc75e28b413817655153157ff/cua_driver-0.20.0-py3-none-manylinux_2_31_x86_64.whl'; wheel_sha='f60c35696a37f37ac954935e478ae4754f220856d022036625c9400d72185961'; wheel_path='/tmp/cua_driver-0.20.0-py3-none-manylinux_2_31_x86_64.whl'; lib_triplet='x86_64-linux-gnu' ;; \\\n",
        "      aarch64|arm64) wheel_url='https://files.pythonhosted.org/packages/94/9d/1c1838b69067e83266c3d2aae02d74eef353a43dc8644884ccf03fe7f933/cua_driver-0.20.0-py3-none-manylinux_2_31_aarch64.whl'; wheel_sha='48833bc5e4c60e701fc9eefb57dbac36ec77ef3990f816fbbe85b4e954af2c77'; wheel_path='/tmp/cua_driver-0.20.0-py3-none-manylinux_2_31_aarch64.whl'; lib_triplet='aarch64-linux-gnu' ;; \\\n",
        "      *) echo \"unsupported architecture: $arch\" >&2; exit 1 ;; \\\n",
        "    esac; \\\n",
        "    for ssl_lib in \"/lib/$lib_triplet/libssl.so.3\" \"/lib/$lib_triplet/libcrypto.so.3\"; do \\\n",
        "      if [ -e \"$ssl_lib\" ] && [ ! -s \"$ssl_lib\" ]; then \\\n",
        "        echo \"pinned base image is defective on $arch: $ssl_lib is zero bytes, so curl cannot start — re-pull or replace the base image instead of debugging the wheel download\" >&2; \\\n",
        "        exit 1; \\\n",
        "      fi; \\\n",
        "    done; \\\n",
        "    curl -fsSL \"$wheel_url\" -o \"$wheel_path\"; \\\n",
        "    echo \"$wheel_sha  $wheel_path\" | sha256sum -c -; \\\n",
        "    /opt/venv/bin/python -m pip install --no-cache-dir --force-reinstall --no-deps \"$wheel_path\"; \\\n",
        "    rm -f \"$wheel_path\"; \\\n",
        "    driver_bin=\"$(find /opt/venv/lib -path '*/cua_driver/bin/cua-driver' -type f -print -quit)\"; \\\n",
        "    test -n \"$driver_bin\"; \\\n",
        "    install -D -m 0755 \"$driver_bin\" " + CUA_EXECUTABLE + "; \\\n",
        "    install -d -o cua -g cua -m 0700 " + VM_WORKSPACE_GUEST + "; \\\n",
        "    test \"$(" + CUA_EXECUTABLE + " --version)\" = \"cua-driver " + CUA_DRIVER_VERSION + "\"\n",
        "# Install before XFCE starts so the panel and window manager see the font too.\n",
        "# Noto Sans CJK JP is distributed under the SIL Open Font License 1.1.\n",
        "RUN set -eux; \\\n",
        "    install -d -m 0755 /usr/local/share/fonts; \\\n",
        "    curl -fsSL 'https://raw.githubusercontent.com/notofonts/noto-cjk/165c01b46ea533872e002e0785ff17e44f6d97d8/Sans/OTF/Japanese/NotoSansCJKjp-Regular.otf' -o /usr/local/share/fonts/NotoSansCJKjp-Regular.otf; \\\n",
        "    echo '68a3fc98800b2a27b371f2fb79991daf3633bd89309d4ffaa6946fd587f375b5  /usr/local/share/fonts/NotoSansCJKjp-Regular.otf' | sha256sum -c -; \\\n",
        "    chmod 0644 /usr/local/share/fonts/NotoSansCJKjp-Regular.otf; \\\n",
        "    install -d -m 0755 /usr/local/share/licenses/noto-cjk; \\\n",
        "    curl -fsSL 'https://raw.githubusercontent.com/notofonts/noto-cjk/165c01b46ea533872e002e0785ff17e44f6d97d8/LICENSE' -o /usr/local/share/licenses/noto-cjk/OFL.txt; \\\n",
        "    echo '6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2  /usr/local/share/licenses/noto-cjk/OFL.txt' | sha256sum -c -; \\\n",
        "    fc-cache -f\n",
        "RUN printf '%s\\n' \\\n",
        "      '#!/bin/sh' \\\n",
        "      'set -eu' \\\n",
        "      'workspace=" + VM_WORKSPACE_GUEST + "' \\\n",
        "      'profiles=\"$workspace/.browser-profiles\"' \\\n",
        "      'mkdir -p \"$profiles/google-chrome\" \"$profiles/chromium\" \"$HOME/.config\"' \\\n",
        "      'if ! chmod 0700 \"$workspace\" \"$profiles\" \"$profiles/google-chrome\" \"$profiles/chromium\" 2>/dev/null; then' \\\n",
        "      '  for directory in \"$workspace\" \"$profiles\" \"$profiles/google-chrome\" \"$profiles/chromium\"; do' \\\n",
        "      '    test -r \"$directory\" && test -w \"$directory\" && test -x \"$directory\"' \\\n",
        "      '  done' \\\n",
        "      'fi' \\\n",
        "      'migrate_profile() {' \\\n",
        "      '  name=\"$1\"' \\\n",
        "      '  source=\"$HOME/.config/$name\"' \\\n",
        "      '  target=\"$profiles/$name\"' \\\n",
        "      '  if [ -d \"$source\" ] && [ ! -L \"$source\" ] && [ -z \"$(find \"$target\" -mindepth 1 -print -quit)\" ]; then' \\\n",
        "      '    cp -a \"$source\"/. \"$target\"/' \\\n",
        "      '  fi' \\\n",
        "      '  rm -rf \"$source\"' \\\n",
        "      '  ln -s \"$target\" \"$source\"' \\\n",
        "      '}' \\\n",
        "      'migrate_profile google-chrome' \\\n",
        "      'migrate_profile chromium' \\\n",
        "      'find \"$profiles\" \\( -name SingletonLock -o -name SingletonSocket -o -name SingletonCookie -o -name .parentlock \\) -delete' \\\n",
        "      > /usr/local/bin/prepare-openmausbot-workspace.sh \\\n",
        "    && chmod 0755 /usr/local/bin/prepare-openmausbot-workspace.sh\n",
        "RUN printf '%s\\n' \\\n",
        "      '#!/bin/sh' \\\n",
        "      '/usr/local/bin/prepare-openmausbot-workspace.sh' \\\n",
        "      'attempt=0' \\\n",
        "      'until DISPLAY=:1 xset q >/dev/null 2>&1; do' \\\n",
        "      '  attempt=$((attempt + 1))' \\\n",
        "      '  if [ \"$attempt\" -ge 45 ]; then echo \"X display :1 did not become ready within 45 seconds\" >&2; exit 1; fi' \\\n",
        "      '  sleep 1' \\\n",
        "      'done' \\\n",
        "      'exec env CUA_DRIVER_INSTALL_CHANNEL=python_package CUA_DRIVER_RS_TELEMETRY_ENABLED=0 " + CUA_EXECUTABLE + " serve --socket " + CUA_SOCKET + " --permission-mode standard' \\\n",
        "      > /usr/local/bin/start-openmausbot-cua-driver.sh \\\n",
        "    && chmod 0755 /usr/local/bin/start-openmausbot-cua-driver.sh\n",
        "RUN printf '%s\\n' \\\n",
        "      '' \\\n",
        "      '[program:openmausbot-cua-driver]' \\\n",
        "      'command=/usr/local/bin/start-openmausbot-cua-driver.sh' \\\n",
        "      'user=cua' \\\n",
        "      'environment=HOME=\"/home/cua\",USER=\"cua\",DISPLAY=\":1\"' \\\n",
        "      'autorestart=true' \\\n",
        "      'startsecs=2' \\\n",
        "      'stdout_logfile=/var/log/supervisor/cua-driver.log' \\\n",
        "      'stderr_logfile=/var/log/supervisor/cua-driver.error.log' \\\n",
        "      'priority=30' \\\n",
        "      >> /etc/supervisor/supervisord.conf\n",
        "LABEL " + MANAGED_LABEL + "=\"1\" \\\n",
        "      " + DRIVER_LABEL + "=\"" + CUA_DRIVER_VERSION + "\" \\\n",
        "      " + BASE_IMAGE_LABEL + "=\"" + BASE_IMAGE_DIGEST + "\" \\\n",
        "      " + IMAGE_LAYER_LABEL + "=\"" + IMAGE_LAYER_VERSION + "\"\n",
    ];
    return "".join(lines);
}

def image_labels_match(labels: any) -> bool {
    return (
        _g(labels, MANAGED_LABEL) == "1"
        and _g(labels, DRIVER_LABEL) == CUA_DRIVER_VERSION
        and _g(labels, BASE_IMAGE_LABEL) == BASE_IMAGE_DIGEST
        and _g(labels, IMAGE_LAYER_LABEL) == IMAGE_LAYER_VERSION
    );
}

def cua_exec_args(args: list[str], container: any = None, interactive: bool = False) -> list[str] {
    out = ["exec"];
    if interactive { out.append("-i"); }
    out.extend([
        "-u", "cua",
        "-e", "HOME=/home/cua",
        "-e", "DISPLAY=" + DISPLAY,
        "-e", "CUA_DRIVER_INSTALL_CHANNEL=python_package",
        "-e", "CUA_DRIVER_RS_TELEMETRY_ENABLED=0",
        container if isinstance(container, str) else CONTAINER,
        CUA_EXECUTABLE,
    ]);
    out.extend(args);
    return out;
}

def container_run_args(runtime: str, password: str = "CHANGE_ME", target: any = None) -> list[str] {
    t = target if isinstance(target, dict) else SHARED_LOCAL_VM_TARGET;
    if runtime == "container" and t["key"] != SHARED_LOCAL_VM_TARGET["key"] {
        raise Exception("Per-bot Local VMs require Docker or Podman because Apple container requires a fixed host port");
    }
    common = ["run", "-d", "--name", t["containerName"]];
    if runtime == "podman" {
        common.extend(["--userns", "keep-id:uid=1000,gid=1000", "--user", "0:0"]);
    }
    common.extend([
        "--label", MANAGED_LABEL + "=1",
        "--label", DRIVER_LABEL + "=" + CUA_DRIVER_VERSION,
        "--label", BASE_IMAGE_LABEL + "=" + BASE_IMAGE_DIGEST,
        "--label", IMAGE_LAYER_LABEL + "=" + IMAGE_LAYER_VERSION,
        "--label", WORKSPACE_LABEL + "=1",
        "--label", TARGET_LABEL + "=" + t["label"],
    ]);
    if runtime == "container" {
        common.extend([
            "--memory", "4g", "--cpus", "2",
            "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID",
            "--shm-size", "512m",
        ]);
    } else {
        common.extend([
            "--hostname", t["containerName"],
            "--memory", "4g", "--memory-swap", "4g",
            "--cpus", "2", "--pids-limit", str(PIDS_LIMIT),
            "--ipc", "private", "--cgroupns", "private",
            "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID",
            "--shm-size", "512m",
        ]);
    }
    if runtime == "podman" { common.extend(["--cap-add", "SYS_CHROOT"]); }
    mount = f"type=bind,source={t['workspaceDir']},target={VM_WORKSPACE_GUEST}";
    if runtime == "podman" { mount = mount + ",relabel=private"; }
    port = t.get("viewerPort");
    publish = f"127.0.0.1::{INTERNAL_VIEWER_PORT}";
    if _truthy(port) { publish = f"127.0.0.1:{port}:{INTERNAL_VIEWER_PORT}"; }
    common.extend(["--mount", mount, "-e", "VNC_PW=" + password, "-p", publish, IMAGE]);
    return common;
}

def _base_image_pull_args(runtime: str) -> list[str] {
    return ["image", "pull", BASE_IMAGE] if runtime == "container" else ["pull", BASE_IMAGE];
}

# ── runtime detection ──────────────────────────────────────────────────────

def _installed(cmd: str, run: any, platform: str) -> bool {
    try {
        run("where.exe" if platform == "win32" else "/usr/bin/which", [cmd], 4000);
        return True;
    } except Exception {
        return False;
    }
}

def _healthy(candidate: str, run: any) -> bool {
    info_args = ["info", "--format", "{{.ServerVersion}}"];
    if candidate == "container" { info_args = ["system", "status"]; }
    elif candidate == "podman" { info_args = ["info", "--format", "json"]; }
    try {
        run(candidate, info_args, 10000);
        return True;
    } except Exception {
        return False;
    }
}

def _parallel(fn: any, items: list[any]) -> list[any] {
    # Promise.all over the candidates: each probe has its own timeout, so run
    # them side by side instead of summing the waits.
    if len(items) <= 1 { return [fn(i) for i in items]; }
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(items)) as pool {
        return list(pool.map(fn, items));
    }
}

# ── VM fixture (OMB_TEST_VM_STATE) ──────────────────────────────────────────
# The container boundary as the fixture state file describes it. The semantics
# are the node-side module mock's, verbatim (server/testing/group-local-vm-hooks.mjs):
# an always-up podman daemon over a container list in the state file, exec
# recorded to <state>.exec, status entry marked at <state>.entered, and a
# blocked/blockedTarget gate a test can hold a status probe behind.

def _fixture_read() -> dict[str, any] {
    with open(TEST_VM_STATE, "r", encoding="utf-8") as f {
        state = json.loads(f.read() or "{}");
    }
    return state if isinstance(state, dict) else {};
}

def _fixture_write(state: dict[str, any]) {
    with open(TEST_VM_STATE, "w", encoding="utf-8") as f {
        f.write(json.dumps(state));
    }
}

def _fixture_exists(target: dict[str, any]) -> bool {
    state = _fixture_read();
    containers = state.get("containers");
    if isinstance(containers, list) { return target["key"] in containers; }
    return not state.get("noContainers");
}

def _fixture_status(target: dict[str, any]) -> dict[str, any] {
    with open(TEST_VM_STATE + ".entered", "w", encoding="utf-8") as f {
        f.write(str(target.get("key") or ""));
    }
    while True {
        state = _fixture_read();
        if not state.get("blocked") and state.get("blockedTarget") != target["key"] { break; }
        time.sleep(0.03);
    }
    missing = not _fixture_exists(target);
    stopped = isinstance(state.get("stopped"), list) and target["key"] in state["stopped"];
    ready = (not missing) and (not stopped) and not state.get("failed");
    return {
        "runtime": "podman",
        "daemonUp": True,
        "image": True,
        "create_supported": True,
        "managed": not missing,
        "container": "missing" if missing else ("stopped" if stopped else "running"),
        "ready": ready,
        "imageMatches": True,
        "network": "loopback",
        "security": "hardened",
        "persistence": "durable",
        "resumable": stopped,
        "stopped_at": state.get("stoppedAt") if stopped else None,
        "problem": None if ready else "fixture desktop unavailable",
        "container_name": target["containerName"],
        "target_key": target["key"],
        "workspace_path": target["workspaceDir"],
    };
}

def _fixture_action(action: str, target: dict[str, any]) -> dict[str, any] {
    state = _fixture_read();
    containers = state.get("containers");
    if not isinstance(containers, list) or action not in ["run", "start", "stop", "remove"] {
        raise Exception("Unexpected container mutation in VM routing test");
    }
    if action == "run" {
        os.makedirs(target["workspaceDir"], exist_ok=True);
        state["containers"] = list(containers) + [target["key"]];
    } elif action == "stop" {
        stopped = list(state.get("stopped") or []);
        stopped.append(target["key"]);
        state["stopped"] = stopped;
        state["stoppedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + ".000Z";
    } elif action == "start" {
        stopped = list(state.get("stopped") or []);
        state["stopped"] = [key for key in stopped if key != target["key"]];
    } else {
        state["containers"] = [key for key in containers if key != target["key"]];
    }
    actions = list(state.get("actions") or []);
    actions.append({"action": action, "target": target["key"]});
    state["actions"] = actions;
    _fixture_write(state);
    return _fixture_status(target);
}

def _fixture_exec(target: dict[str, any], command: any) -> dict[str, any] {
    with open(TEST_VM_STATE + ".exec", "w", encoding="utf-8") as f {
        f.write(json.dumps({"target": target, "command": command}));
    }
    return {"exitCode": 0, "stdout": "fixture command completed", "stderr": "", "timedOut": False};
}

def container_runtime_status(run: any = None, platform: any = None) -> dict[str, any] {
    if TEST_VM_STATE { return {"runtime": "podman", "daemonUp": True}; }
    r = run if run is not None else _default_run;
    p = platform if isinstance(platform, str) else _node_platform();
    candidates = ["podman", "docker"] if p == "win32" else [x for x in RUNTIMES if x != "container" or p == "darwin"];
    def _inst(c: str) -> bool { return _installed(c, r, p); }
    def _ok(c: str) -> bool { return _healthy(c, r); }
    present = _parallel(_inst, candidates);
    available = [candidates[i] for i in range(len(candidates)) if present[i]];
    healthy = _parallel(_ok, available);
    idx = healthy.index(True) if True in healthy else -1;
    runtime: any = None;
    if idx >= 0 { runtime = available[idx]; }
    elif available { runtime = available[0]; }
    return {"runtime": runtime, "available": available, "daemonUp": idx >= 0};
}

# ── status ─────────────────────────────────────────────────────────────────

def _empty_status(platform: str, target: dict[str, any]) -> dict[str, any] {
    port = target["viewerPort"];
    return {
        "platform": platform,
        "runtime": None,
        "available": [],
        "daemonUp": False,
        "image": False,
        "imageMatches": False,
        "managed": False,
        "container": "missing",
        "network": "unknown",
        "security": "unknown",
        "persistence": "unknown",
        "desktopReady": False,
        "desktop_error": None,
        "create_supported": True,
        "resumable": False,
        "ready": False,
        "problem": "Install a supported container runtime first",
        "image_ref": IMAGE,
        "image_id": None,
        "base_image_ref": BASE_IMAGE,
        "driver_version": CUA_DRIVER_VERSION,
        "container_name": target["containerName"],
        "target_key": target["key"],
        "workspace_path": target["workspaceDir"],
        "workspace_guest_path": VM_WORKSPACE_GUEST,
        "viewer_port": port,
        "viewer_url": f"http://127.0.0.1:{port}/vnc.html" if _truthy(port) else "",
    };
}

def local_vm_recreatable_on_demand(status: dict[str, any]) -> bool {
    return (
        _truthy(status.get("runtime"))
        and status.get("daemonUp") is True
        and status.get("image") is True
        and status.get("container") == "missing"
        and status.get("create_supported") is True
    );
}

def _existing_container_problem(status: dict[str, any]) -> any {
    if not status.get("imageMatches") { return "The existing Local VM uses an older desktop or Cua Driver; recreate it"; }
    if not status.get("managed") { return "The existing container was not created by OpenMausBot; recreate it"; }
    if status.get("network") == "unsafe" { return "The existing Local VM exposes its viewer publicly; recreate it"; }
    if status.get("security") == "unsafe" { return "The existing Local VM is missing safety limits; recreate it"; }
    if status.get("persistence") == "unsafe" { return "The existing Local VM is missing its durable folder; recreate it"; }
    return None;
}

def local_vm_resumable(status: dict[str, any]) -> bool {
    return (
        _truthy(status.get("runtime"))
        and _truthy(status.get("daemonUp"))
        and _truthy(status.get("image"))
        and status.get("container") == "stopped"
        and _existing_container_problem(status) is None
        and status.get("network") == "loopback"
        and status.get("security") == "hardened"
        and status.get("persistence") == "durable"
    );
}

def _status_problem(status: dict[str, any]) -> any {
    if not _truthy(status.get("runtime")) { return "Install a supported container runtime first"; }
    if not status.get("daemonUp") { return f"Start {status['runtime']} first"; }
    if not status.get("image") { return f"Prepare the Cua desktop image with Driver {CUA_DRIVER_VERSION}"; }
    if status.get("container") == "missing" and not status.get("create_supported") {
        return "Per-bot Local VMs require Docker or Podman because Apple container requires a fixed host port";
    }
    if status.get("container") == "missing" { return "Create the Local VM"; }
    existing = _existing_container_problem(status);
    if existing is not None { return existing; }
    if status.get("container") == "stopped" { return "The Local VM is stopped; start it to continue"; }
    if status.get("desktop_error") { return f"The Local VM desktop failed to start: {status['desktop_error']}"; }
    if not status.get("desktopReady") { return "The Local VM started, but Cua Driver is not ready yet"; }
    return None;
}

def _ownership_labels_match(labels: any, target: dict[str, any]) -> bool {
    if not (_g(labels, MANAGED_LABEL) == "1" and _g(labels, WORKSPACE_LABEL) == "1") { return False; }
    if target["key"] == SHARED_LOCAL_VM_TARGET["key"] {
        if not _has(labels, TARGET_LABEL) { return True; }
        return labels[TARGET_LABEL] == target["label"];
    }
    return _has(labels, TARGET_LABEL) and labels[TARGET_LABEL] == target["label"];
}

def _normalize_image_id(value: any) -> any {
    if value is None { return None; }
    if not isinstance(value, str) { raise TypeError("id.trim is not a function"); }
    v = re.sub(r"^sha256:", "", value.strip());
    return v if v else None;
}

def _inspected_image(stdout: str, runtime: str) -> dict[str, any] {
    parsed = json.loads(stdout);
    image = _g(parsed, 0);
    labels: any = None;
    if runtime == "container" {
        raw_variants = _g(image, "variants");
        variants: list[any] = [];
        if isinstance(raw_variants, list) {
            for v in raw_variants {
                plat = _g(v, "platform");
                if _g(plat, "os") == "linux" and _g(plat, "architecture") == "arm64" {
                    variants.append(v);
                }
            }
        }
        if len(variants) == 1 {
            labels = _g(_g(_g(variants[0], "config"), "config"), "Labels");
        }
    } else {
        labels = _coalesce([
            _g(_g(image, "Config"), "Labels"),
            _g(_g(image, "config"), "Labels"),
            _g(_g(image, "config"), "labels"),
            _g(_g(image, "configuration"), "labels"),
        ]);
    }
    raw_id = _coalesce([
        _g(image, "Id"),
        _g(image, "id"),
        _g(_g(_g(image, "configuration"), "descriptor"), "digest"),
    ]);
    return {"labels": labels, "id": _normalize_image_id(raw_id)};
}

def _viewer_password(env: any) -> any {
    if isinstance(env, list) {
        for item in env {
            if isinstance(item, str) and item.startswith("VNC_PW=") {
                v = item[len("VNC_PW="):];
                return v if v else None;
            }
        }
        return None;
    }
    v = _g(env, "VNC_PW");
    return v if _truthy(v) else None;
}

def _url_encode_component(value: str) -> str {
    # URLSearchParams serialization (application/x-www-form-urlencoded):
    # only *-._ and alphanumerics stay bare; Python also keeps "~".
    return urllib.parse.quote_plus(value, safe="*-._").replace("~", "%7E");
}

def _viewer_url(password: any, port: any) -> str {
    if not _truthy(port) { return ""; }
    base = f"http://127.0.0.1:{_js_str(port)}/vnc.html";
    if not _truthy(password) { return base; }
    fragment = "autoconnect=true&resize=scale&password=" + _url_encode_component(_js_str(password));
    return base + "#" + fragment;
}

def _loopback(address: any) -> bool {
    return address in ["127.0.0.1", "::1", "[::1]"];
}

def _flat_entries(bindings: any) -> list[any] {
    out: list[any] = [];
    if not isinstance(bindings, dict) { return out; }
    for entries in bindings.values() {
        if entries is None { continue; }
        if isinstance(entries, list) { out.extend(entries); }
        else { out.append(entries); }
    }
    return out;
}

def _docker_ports_are_local(bindings: any) -> bool {
    viewer = _g(bindings, f"{INTERNAL_VIEWER_PORT}/tcp");
    if viewer is None { viewer = []; }
    if not isinstance(viewer, list) { return False; }
    published = _flat_entries(bindings);
    if not (len(viewer) > 0 and len(published) == len(viewer)) { return False; }
    for e in published {
        if not _loopback(_g(e, "HostIp")) { return False; }
    }
    return True;
}

def _valid_port(n: float) -> bool {
    return math.isfinite(n) and n.is_integer() and n > 0 and n <= 65535;
}

def _docker_viewer_port(bindings: any, fallback: any) -> any {
    viewer = _g(bindings, f"{INTERNAL_VIEWER_PORT}/tcp");
    raw: any = None;
    if isinstance(viewer, list) {
        for e in viewer {
            if _loopback(_g(e, "HostIp")) {
                raw = _g(e, "HostPort");
                break;
            }
        }
    }
    parsed = _js_number(raw) if _truthy(raw) else float("nan");
    return int(parsed) if _valid_port(parsed) else fallback;
}

def _apple_ports_are_local(bindings: any) -> bool {
    if not (isinstance(bindings, list) and len(bindings) == 1) { return False; }
    first = bindings[0];
    return _num_eq(_g(first, "containerPort"), INTERNAL_VIEWER_PORT) and _loopback(_g(first, "hostAddress"));
}

def _apple_viewer_port(bindings: any, fallback: any) -> any {
    raw: any = None;
    if isinstance(bindings, list) {
        for b in bindings {
            if _num_eq(_g(b, "containerPort"), INTERNAL_VIEWER_PORT) and _loopback(_g(b, "hostAddress")) {
                raw = _g(b, "hostPort");
                break;
            }
        }
    }
    if _is_integer(raw) and raw > 0 and raw <= 65535 { return int(raw); }
    return fallback;
}

def _resolve(p: str) -> str {
    if not isinstance(p, str) { raise TypeError("The \"path\" argument must be of type string"); }
    return os.path.abspath(p);
}

def _same_workspace_source(source: any, platform: str, expected: str) -> bool {
    if not _truthy(source) { return False; }
    actual = _resolve(source);
    want = _resolve(expected);
    return actual.lower() == want.lower() if platform == "win32" else actual == want;
}

def _same_podman_windows_workspace_source(source: any, expected: str) -> bool {
    if not _truthy(source) { return False; }
    m = re.fullmatch(r"([A-Za-z]):[\\/](.+)", expected);
    if m is None { return False; }
    want = "/mnt/" + m.group(1).lower() + "/" + m.group(2).replace("\\", "/");
    if not isinstance(source, str) { raise TypeError("source.replaceAll is not a function"); }
    actual = source.replace("\\", "/");
    return actual.lower() == want.lower();
}

def _docker_workspace_mount_is_safe(mounts: any, platform: str, expected: str, runtime: str) -> bool {
    first = _g(mounts, 0);
    source_matches = _same_workspace_source(_g(first, "Source"), platform, expected);
    if not source_matches and runtime == "podman" and platform == "win32" {
        source_matches = _same_podman_windows_workspace_source(_g(first, "Source"), expected);
    }
    return (
        isinstance(mounts, list) and len(mounts) == 1
        and _g(first, "Type") == "bind"
        and source_matches
        and _g(first, "Destination") == VM_WORKSPACE_GUEST
        and _g(first, "RW") is not False
    );
}

def _apple_workspace_mount_is_safe(mounts: any, platform: str, expected: str) -> bool {
    first = _g(mounts, 0);
    options = _g(first, "options");
    if options is None { options = []; }
    if not (isinstance(mounts, list) and len(mounts) == 1) { return False; }
    if not _same_workspace_source(_g(first, "source"), platform, expected) { return False; }
    if _g(first, "destination") != VM_WORKSPACE_GUEST { return False; }
    for o in (options if isinstance(options, list) else []) {
        if o == "ro" or o == "readonly" { return False; }
    }
    return True;
}

def _lower_caps(caps: any) -> list[str] {
    out: list[str] = [];
    for c in (caps if isinstance(caps, list) else []) {
        out.append(str(c).lower());
    }
    return out;
}

def _normalize_caps(caps: any) -> list[str] {
    return sorted([re.sub(r"^cap_", "", c) for c in _lower_caps(caps)]);
}

def _empty_or_missing(v: any) -> bool {
    return (not _truthy(v)) or (isinstance(v, list) and len(v) == 0);
}

def docker_security_is_hardened(config: any, restart_policy: any = None, podman_browser_sandbox: bool = False) -> bool {
    if not _truthy(config) or not isinstance(config, dict) { return False; }
    cap_drop = _lower_caps(config.get("CapDrop"));
    cap_add = _normalize_caps(config.get("CapAdd"));
    unsafe_option = False;
    for o in (config.get("SecurityOpt") or []) {
        if re.search(r"(?:^|=)(?:unconfined|disable)\Z", str(o), re.IGNORECASE) {
            unsafe_option = True;
        }
    }
    policy = config.get("RestartPolicy");
    has_name = _has(policy, "Name");
    name = _g(policy, "Name");
    policy_ok = False;
    if restart_policy == "any" { policy_ok = True; }
    elif restart_policy == "unless-stopped" { policy_ok = name == "unless-stopped"; }
    else { policy_ok = (not has_name) or name == "" or name == "no"; }
    want_caps = "setgid,setuid,sys_chroot" if podman_browser_sandbox else "setgid,setuid";
    return (
        "all" in cap_drop
        and ",".join(cap_add) == want_caps
        and config.get("Privileged") is False
        and not _truthy(config.get("PidMode"))
        and config.get("IpcMode") == "private"
        and not _truthy(config.get("UTSMode"))
        and _empty_or_missing(config.get("Devices"))
        and _empty_or_missing(config.get("DeviceRequests"))
        and not unsafe_option
        and not _truthy(config.get("UsernsMode"))
        and config.get("CgroupnsMode") == "private"
        and config.get("AutoRemove") is not True
        and policy_ok
    );
}

def podman_security_is_hardened(config: any, effective_caps: any, bounding_caps: any) -> bool {
    if not _truthy(config) or not isinstance(config, dict) { return False; }
    exact = "setgid,setuid,sys_chroot";
    if ",".join(_normalize_caps(effective_caps)) != exact { return False; }
    if ",".join(_normalize_caps(bounding_caps)) != exact { return False; }
    merged = dict(config);
    merged["CapDrop"] = ["all"];
    merged["CapAdd"] = effective_caps;
    merged["PidMode"] = "" if config.get("PidMode") == "private" else config.get("PidMode");
    merged["UTSMode"] = "" if config.get("UTSMode") == "private" else config.get("UTSMode");
    userns = config.get("UsernsMode");
    merged["UsernsMode"] = "" if userns in ["private", "keep-id:uid=1000,gid=1000"] else userns;
    merged["CgroupnsMode"] = config.get("CgroupnsMode") if _truthy(config.get("CgroupnsMode")) else "private";
    return docker_security_is_hardened(merged, None, True);
}

# ── screenshots ────────────────────────────────────────────────────────────

def _b64_lenient(text: str) -> bytes {
    # Buffer.from(text, "base64"): url-safe chars accepted, junk skipped,
    # padding optional, decoding stops at the first '='.
    cleaned = re.sub(r"[^A-Za-z0-9+/=_-]", "", text).replace("-", "+").replace("_", "/");
    eq = cleaned.find("=");
    if eq >= 0 { cleaned = cleaned[:eq]; }
    rem = len(cleaned) % 4;
    if rem == 1 { cleaned = cleaned[:-1]; }
    elif rem > 0 { cleaned = cleaned + "=" * (4 - rem); }
    return base64.b64decode(cleaned);
}

def whole_screenshot(data: bytes) -> dict[str, any] {
    if len(data) < 512 { return {"ok": False, "mime": "image/png"}; }
    if data[:4] == b"\x89PNG" {
        return {"ok": b"IEND" in data[max(0, len(data) - 12):], "mime": "image/png"};
    }
    jpeg = data[0] == 0xff and data[1] == 0xd8;
    return {"ok": jpeg and b"\xff\xd9" in data[max(0, len(data) - 32):], "mime": "image/jpeg"};
}

# ── containerComputerStatus ────────────────────────────────────────────────

def _inspect_apple(status: dict[str, any], detail: any, platform: str, target: dict[str, any]) {
    configuration = _g(detail, "configuration");
    status["container"] = "running" if _g(_g(detail, "status"), "state") == "running" else "stopped";
    status["network"] = "loopback" if _apple_ports_are_local(_g(configuration, "publishedPorts")) else "unsafe";
    status["viewer_port"] = _apple_viewer_port(_g(configuration, "publishedPorts"), target["viewerPort"]);
    image = _g(configuration, "image");
    apple_image: any = None;
    if isinstance(image, str) {
        apple_image = image;
    } else {
        apple_image = _coalesce([_g(image, "reference"), _g(configuration, "imageReference")]);
    }
    apple_image_id: any = None;
    if _has(configuration, "image") and image is None {
        # typeof null === "object": the TS read throws here.
        raise TypeError("Cannot read properties of null (reading 'descriptor')");
    }
    if isinstance(image, (dict, list)) {
        apple_image_id = _normalize_image_id(_g(_g(image, "descriptor"), "digest"));
    }
    status["imageMatches"] = apple_image == IMAGE and status["image_id"] is not None and apple_image_id == status["image_id"];
    status["managed"] = _ownership_labels_match(_g(configuration, "labels"), target);
    status["persistence"] = "durable" if _apple_workspace_mount_is_safe(_g(configuration, "mounts"), platform, target["workspaceDir"]) else "unsafe";
    resources = _g(configuration, "resources");
    memory = _g(resources, "memoryInBytes");
    if memory is None { memory = 0; }
    status["security"] = "hardened" if (_is_num(memory) and memory >= MEMORY_BYTES and _num_eq(_g(resources, "cpus"), 2)) else "unsafe";
    status["viewer_url"] = _viewer_url(_viewer_password(_g(configuration, "environment")), status["viewer_port"]);
}

def _inspect_docker(status: dict[str, any], detail: any, platform: str, target: dict[str, any]) {
    config = _g(detail, "Config");
    host = _g(detail, "HostConfig");
    state = _g(detail, "State");
    status["container"] = "running" if _truthy(_g(state, "Running")) else "stopped";
    status["stopped_at"] = _g(state, "FinishedAt") if status["container"] == "stopped" else None;
    status["network"] = "loopback" if _docker_ports_are_local(_g(host, "PortBindings")) else "unsafe";
    status["viewer_port"] = _docker_viewer_port(_g(_g(detail, "NetworkSettings"), "Ports"), target["viewerPort"]);
    status["imageMatches"] = (
        _g(config, "Image") == IMAGE
        and image_labels_match(_g(config, "Labels"))
        and status["image_id"] is not None
        and _normalize_image_id(_g(detail, "Image")) == status["image_id"]
    );
    status["managed"] = _ownership_labels_match(_g(config, "Labels"), target);
    status["persistence"] = "durable" if _docker_workspace_mount_is_safe(_g(detail, "Mounts"), platform, target["workspaceDir"], status["runtime"]) else "unsafe";
    hardened = False;
    if status["runtime"] == "podman" {
        hardened = podman_security_is_hardened(host, _g(detail, "EffectiveCaps"), _g(detail, "BoundingCaps"));
    } else {
        hardened = docker_security_is_hardened(host);
    }
    status["security"] = "hardened" if hardened else "unsafe";
    status["viewer_url"] = _viewer_url(_viewer_password(_g(config, "Env")), status["viewer_port"]);
}

def _probe_desktop(status: dict[str, any], run: any, target: dict[str, any]) {
    runtime = status["runtime"];
    name = target["containerName"];
    try {
        expected = f"cua-driver {CUA_DRIVER_VERSION}";
        version = run(runtime, cua_exec_args(["--version"], name), 8000);
        if version.strip() != expected { raise Exception(f"expected {expected}"); }
        run(runtime, cua_exec_args(["status", "--socket", CUA_SOCKET], name), 8000);
        health = run(runtime, cua_exec_args(["call", "health_report", "{}", "--socket", CUA_SOCKET], name), 15000);
        rep = json.loads(health);
        if not isinstance(rep, dict) {
            raise TypeError("Cannot read properties of null (reading 'schema_version')");
        }
        if (
            rep.get("schema_version") != "1"
            or not isinstance(rep.get("checks"), list)
            or rep.get("overall") not in ["ok", "degraded"]
        ) {
            overall = rep.get("overall");
            raise Exception("Cua health report is " + (_js_str(overall) if overall is not None else "invalid"));
        }
        readiness_shot = "/tmp/openmausbot-readiness.png";
        run(runtime, cua_exec_args([
            "call", "get_desktop_state", "{}", "--socket", CUA_SOCKET,
            "--screenshot-out-file", readiness_shot,
        ], name), 20000);
        captured = run(runtime, ["exec", name, "base64", "-w0", readiness_shot], 20000);
        if not whole_screenshot(_b64_lenient(captured.strip()))["ok"] {
            raise Exception("Cua Driver returned an incomplete readiness screenshot");
        }
        status["desktopReady"] = True;
    } except Exception as e {
        status["desktop_error"] = str(e)[:320];
        try {
            log = run(runtime, ["exec", name, "tail", "-n", "4", "/var/log/supervisor/cua-driver.error.log"], 4000);
            text = re.sub(r"\s+", " ", log).strip()[:320];
            if text { status["desktop_error"] = text; }
        } except Exception {
            # The log may not exist during the first seconds of boot.
        }
    }
}

def container_computer_status(run: any = None, platform: any = None, target: any = None, probe_desktop: bool = True) -> dict[str, any] {
    r = run if run is not None else _default_run;
    p = platform if isinstance(platform, str) else _node_platform();
    t = target if isinstance(target, dict) else SHARED_LOCAL_VM_TARGET;
    if TEST_VM_STATE { return _fixture_status(t); }
    status = _empty_status(p, t);
    rt = container_runtime_status(r, p);
    status["available"] = rt["available"];
    status["runtime"] = rt["runtime"];
    status["daemonUp"] = rt["daemonUp"];
    status["create_supported"] = t["key"] == SHARED_LOCAL_VM_TARGET["key"] or status["runtime"] != "container";
    if not status["runtime"] or not status["daemonUp"] {
        status["problem"] = _status_problem(status);
        return status;
    }
    try {
        stdout = r(status["runtime"], ["image", "inspect", IMAGE], 8000);
        image = _inspected_image(stdout, status["runtime"]);
        status["image"] = image_labels_match(image["labels"]);
        status["image_id"] = image["id"];
    } except Exception {
        # The prepared OpenMausBot derivative has not been built yet.
    }
    try {
        stdout = r(status["runtime"], ["inspect", t["containerName"]], 8000);
        detail = _g(json.loads(stdout), 0);
        if status["runtime"] == "container" {
            _inspect_apple(status, detail, p, t);
        } else {
            _inspect_docker(status, detail, p, t);
        }
    } except Exception {
        # No container with this name (or an inspect shape we cannot read).
    }
    can_probe = (
        probe_desktop
        and status["container"] == "running"
        and status["imageMatches"] is True
        and status["managed"] is True
        and status["network"] == "loopback"
        and status["security"] == "hardened"
        and status["persistence"] == "durable"
    );
    if can_probe { _probe_desktop(status, r, t); }
    status["problem"] = _status_problem(status);
    status["ready"] = status["problem"] is None;
    status["resumable"] = local_vm_resumable(status);
    return status;
}

# ── lifecycle ──────────────────────────────────────────────────────────────

def _mkdir_private(path: str) {
    # mkdir({recursive, mode: 0o700}): every directory it creates is private.
    missing: list[str] = [];
    cur = os.path.abspath(path);
    while not os.path.exists(cur) {
        missing.append(cur);
        parent = os.path.dirname(cur);
        if parent == cur { break; }
        cur = parent;
    }
    missing.reverse();
    for d in missing {
        try {
            os.mkdir(d, 0o700);
        } except FileExistsError {
            continue;
        }
    }
    if not os.path.isdir(path) { _fail(500, f"EEXIST: file already exists, mkdir '{path}'"); }
}

def _ensure_vm_workspace(platform: str, target: dict[str, any]) {
    _mkdir_private(target["workspaceDir"]);
    if platform != "win32" { os.chmod(target["workspaceDir"], 0o700); }
}

def _prepare_managed_image(runtime: str, run: any) {
    run(runtime, _base_image_pull_args(runtime), 600000);
    context = tempfile.mkdtemp(prefix="openmausbot-cua-image-");
    try {
        dockerfile = os.path.join(context, "Dockerfile");
        fd = os.open(dockerfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600);
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f {
            f.write(managed_image_dockerfile());
        }
        run(runtime, ["build", "-t", IMAGE, context], 600000);
    } finally {
        shutil.rmtree(context, ignore_errors=True);
    }
}

def container_computer_action(action: str, run: any = None, platform: any = None, target: any = None) -> dict[str, any] {
    if action not in LIFECYCLE_ACTIONS { _fail(400, "Unknown Local VM action"); }
    r = run if run is not None else _default_run;
    p = platform if isinstance(platform, str) else _node_platform();
    t = target if isinstance(target, dict) else SHARED_LOCAL_VM_TARGET;
    if TEST_VM_STATE { return _fixture_action(action, t); }
    if _cacheable(r, p) { _cache_delete(t["key"]); }
    before = container_computer_status(r, p, t);
    runtime = before["runtime"];
    if not runtime { _fail(409, before["problem"] or "No container runtime is installed"); }
    if not before["daemonUp"] { _fail(409, before["problem"] or f"{runtime} is not running"); }
    if action == "run" and before["container"] != "missing" {
        _fail(409, "A Local VM already exists; remove it before creating a replacement");
    }
    if action == "run" and not before["image"] {
        _fail(409, "Prepare the Cua desktop image before creating the Local VM");
    }
    if action == "run" and not before["create_supported"] {
        _fail(409, before["problem"] or "This runtime cannot create a per-bot Local VM");
    }
    if action == "start" and not local_vm_resumable(before) {
        _fail(409, before["problem"] or "The Local VM is not stopped");
    }
    if action == "stop" and before["container"] != "running" {
        _fail(409, "The Local VM is not running");
    }
    if action == "remove" and before["container"] == "missing" { return before; }
    if action == "remove" and not before["managed"] {
        _fail(409, f"The existing container named {t['containerName']} was not created by OpenMausBot; remove it manually in {runtime}");
    }
    if action == "pull" {
        _prepare_managed_image(runtime, r);
    } else {
        if action == "run" { _ensure_vm_workspace(p, t); }
        args: list[str] = [action, t["containerName"]];
        if action == "run" {
            args = container_run_args(runtime, secrets.token_urlsafe(6), t);
        } elif action == "remove" {
            args = ["rm", "--force" if runtime == "container" else "-f", t["containerName"]];
        }
        r(runtime, args, 120000);
    }
    return container_computer_status(r, p, t);
}

def container_computer_exists(runtime: str, target: dict[str, any], run: any = None) -> bool {
    if TEST_VM_STATE { return _fixture_exists(target); }
    r = run if run is not None else _default_run;
    try {
        r(runtime, ["inspect", target["containerName"]], 8000);
        return True;
    } except Exception {
        return False;
    }
}

def container_computer_frame(run: any = None, platform: any = None, target: any = None) -> dict[str, any] {
    r = run if run is not None else _default_run;
    p = platform if isinstance(platform, str) else _node_platform();
    t = target if isinstance(target, dict) else SHARED_LOCAL_VM_TARGET;
    cacheable = _cacheable(r, p);
    now = int(time.time() * 1000);
    cached: any = None;
    if cacheable {
        with _cv_lock {
            cached = _cv["cache"].get(t["key"]);
        }
    }
    status: any = None;
    if cached is not None and cached["expires_at"] > now {
        status = cached["status"];
    } else {
        status = container_computer_status(r, p, t);
    }
    if not status["ready"] or not status["runtime"] {
        if cacheable { _cache_delete(t["key"]); }
        _fail(409, status["problem"] or "The Local VM is not ready");
    }
    if cacheable {
        with _cv_lock {
            _cv["cache"][t["key"]] = {"status": status, "expires_at": now + SCREENSHOT_STATUS_TTL_MS};
        }
    }
    try {
        screenshot = "/tmp/openmausbot-preview.png";
        r(status["runtime"], cua_exec_args([
            "call", "get_desktop_state", "{}", "--socket", CUA_SOCKET,
            "--screenshot-out-file", screenshot,
        ], t["containerName"]), 30000);
        stdout = r(status["runtime"], ["exec", t["containerName"], "base64", "-w0", screenshot], 30000);
        data = stdout.strip();
        checked = whole_screenshot(_b64_lenient(data));
        if not checked["ok"] { _fail(502, "Cua Driver returned an incomplete screenshot"); }
        return {"png": data, "format": "jpeg" if checked["mime"] == "image/jpeg" else "png"};
    } except Exception as e {
        if cacheable { _cache_delete(t["key"]); }
        raise e;
    }
}

# ── exec ───────────────────────────────────────────────────────────────────

def clip_exec_output(text: str, limit: int = 20000) -> str {
    if len(text) <= limit { return text; }
    head = limit // 5;
    return text[:head] + f"\n… {len(text) - limit} characters omitted …\n" + text[len(text) - (limit - head):];
}

def container_exec(target: dict[str, any], command: any, timeout_seconds: any = None, runtime: any = None, exec_fn: any = None) -> dict[str, any] {
    if TEST_VM_STATE { return _fixture_exec(target, command); }
    cmd = command if isinstance(command, str) else "";
    if not cmd.strip() { _fail(400, "command is required"); }
    if len(cmd) > 20000 { _fail(400, "command is too long"); }
    if timeout_seconds is not None and not (_is_num(timeout_seconds) and math.isfinite(timeout_seconds)) {
        _fail(400, "timeout_seconds must be finite");
    }
    rt = runtime;
    if rt is None { rt = container_runtime_status(_hook_run(), _hook_platform())["runtime"]; }
    if not rt { _fail(409, "No container runtime is available for the Local VM"); }
    wanted = timeout_seconds if timeout_seconds is not None else EXEC_DEFAULT_SECONDS;
    seconds = min(max(math.floor(wanted), 1), EXEC_MAX_SECONDS);
    run_exec = exec_fn if exec_fn is not None else _hook_exec();
    result = run_exec(rt, [
        "exec",
        "-u", "cua",
        "-w", VM_WORKSPACE_GUEST,
        "-e", "HOME=/home/cua",
        "-e", "DISPLAY=" + DISPLAY,
        target["containerName"],
        "timeout", "-k", "5", str(seconds),
        "sh", "-lc", cmd,
    ], (seconds + 20) * 1000);
    code = result["code"];
    return {
        "exitCode": code,
        "stdout": clip_exec_output(result.get("stdout") or ""),
        "stderr": clip_exec_output(result.get("stderr") or ""),
        "timedOut": code == 124 or code == 137,
    };
}

# ── HTTP surface (re-bound onto harness.jac as computer_*) ─────────────────

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

def _runtime_arg(runtime: any) -> any {
    return runtime if runtime in RUNTIMES else None;
}

def:pub computer_runtime_status(omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return container_runtime_status(_hook_run(), _hook_platform());
    }
    return _invoke(omb_token, _go);
}

def:pub computer_vm_status(target: any = None, probe_desktop: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        t = _target_arg(target);
        return {"status": container_computer_status(_hook_run(), _hook_platform(), t, probe_desktop is not False)};
    }
    return _invoke(omb_token, _go);
}

def:pub computer_vm_action(action: str, target: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        t = _target_arg(target);
        return {"status": container_computer_action(action, _hook_run(), _hook_platform(), t)};
    }
    return _invoke(omb_token, _go);
}

def:pub computer_vm_exists(runtime: str, target: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        rt = _runtime_arg(runtime);
        if rt is None { _fail(400, "Unknown container runtime"); }
        return {"exists": container_computer_exists(rt, _target_arg(target), _hook_run())};
    }
    return _invoke(omb_token, _go);
}

def:pub computer_vm_frame(target: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return container_computer_frame(_hook_run(), _hook_platform(), _target_arg(target));
    }
    return _invoke(omb_token, _go);
}

def:pub computer_vm_exec(target: any = None, command: any = None, timeout_seconds: any = None, runtime: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        t = _target_arg(target);
        secs: any = timeout_seconds if _is_num(timeout_seconds) else None;
        return container_exec(t, command, secs, _runtime_arg(runtime));
    }
    return _invoke(omb_token, _go);
}
