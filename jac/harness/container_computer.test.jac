"""Invariants ported from server/container-computer.test.ts and
server/container-exec.test.ts, against fake command runners.

Not ported (the pure contract stays in TypeScript and keeps its tests
there): setupCommands, containerComputerMcp, localVmWorkspaceExists,
autoLocalVmAttachable. containerRunArgs/cuaExecArgs/managedImageDockerfile
are duplicated here, so they carry golden/drift guards instead.
"""

import os;
import json;
import base64;
import hashlib;

# ── fixtures ───────────────────────────────────────────────────────────────

def _fake(responses: dict[str, any]) -> dict[str, any] {
    calls: list[str] = [];
    def _run(command: str, args: list[str], timeout_ms: int = 0) -> str {
        key = " ".join([command] + list(args));
        calls.append(key);
        r = responses.get(key);
        if r is None {
            raise Exception("unexpected command: " + key);
        }
        if isinstance(r, Exception) {
            raise r;
        }
        return r;
    }
    return {"calls": calls, "run": _run};
}

def _err(message: str = "missing") -> any {
    return Exception(message);
}

def _driver_exec(runtime: str, container: str) -> str {
    return (
        runtime + " exec -u cua -e HOME=/home/cua -e DISPLAY=:1 -e CUA_DRIVER_INSTALL_CHANNEL=python_package "
        + "-e CUA_DRIVER_RS_TELEMETRY_ENABLED=0 " + container + " " + CUA_EXECUTABLE
    );
}

def _dx -> str { return _driver_exec("docker", CONTAINER); }
def _version_probe -> str { return _dx() + " --version"; }
def _status_probe -> str { return _dx() + " status --socket " + CUA_SOCKET; }
def _health_probe -> str { return _dx() + " call health_report {} --socket " + CUA_SOCKET; }
def _readiness_probe -> str { return _dx() + " call get_desktop_state {} --socket " + CUA_SOCKET + " --screenshot-out-file /tmp/openmausbot-readiness.png"; }
glob _VALID_PNG: bytes = b"\x89PNG\r\n\x1a\n" + bytes(600) + b"IEND";
glob _VALID_PNG_B64: str = base64.b64encode(_VALID_PNG).decode("ascii");

def _prepared_labels -> dict[str, any] {
    return {
        MANAGED_LABEL: "1",
        DRIVER_LABEL: CUA_DRIVER_VERSION,
        BASE_IMAGE_LABEL: BASE_IMAGE_DIGEST,
        IMAGE_LAYER_LABEL: IMAGE_LAYER_VERSION,
    };
}

def _prepared_image_inspect -> str {
    return json.dumps([{"Id": "sha256:managed-image-id", "Config": {"Labels": _prepared_labels()}}]);
}

def _apple_variant(labels: any, architecture: str = "arm64", os_name: str = "linux") -> dict[str, any] {
    return {"platform": {"os": os_name, "architecture": architecture}, "config": {"config": {"Labels": labels}}};
}

def _apple_image_inspect(variants: list[any]) -> str {
    return json.dumps([{
        "configuration": {"name": IMAGE, "descriptor": {"digest": "sha256:managed-image-id"}},
        "variants": variants,
    }]);
}

def _apple_runtime -> dict[str, any] {
    return {
        "/usr/bin/which docker": _err(),
        "/usr/bin/which podman": _err(),
        "/usr/bin/which container": "container\n",
        "container system status": "running\n",
    };
}

def _docker_linux -> dict[str, any] {
    return {
        "/usr/bin/which docker": "docker\n",
        "/usr/bin/which podman": _err(),
        "docker info --format {{.ServerVersion}}": "29\n",
    };
}

def _with(base: dict[str, any], more: dict[str, any]) -> dict[str, any] {
    out = dict(base);
    out.update(more);
    return out;
}

def _ready_detail -> dict[str, any] {
    labels = _prepared_labels();
    labels[WORKSPACE_LABEL] = "1";
    return {
        "Config": {"Image": IMAGE, "Labels": labels, "Env": ["VNC_PW=secret123"]},
        "State": {"Running": True},
        "Image": "sha256:managed-image-id",
        "HostConfig": {
            "Memory": 4 * 1024 * 1024 * 1024,
            "MemorySwap": 4 * 1024 * 1024 * 1024,
            "NanoCpus": 2000000000,
            "PidsLimit": 512,
            "CapDrop": ["ALL"],
            "CapAdd": ["CAP_SETUID", "CAP_SETGID"],
            "Privileged": False,
            "IpcMode": "private",
            "CgroupnsMode": "private",
            "ShmSize": 512 * 1024 * 1024,
            "RestartPolicy": {"Name": "no", "MaximumRetryCount": 0},
            "PortBindings": {"6901/tcp": [{"HostIp": "127.0.0.1"}]},
        },
        "Mounts": [{"Type": "bind", "Source": VM_WORKSPACE_DIR, "Destination": VM_WORKSPACE_GUEST, "RW": True}],
    };
}

def _ready_inspect(overrides: dict[str, any] = {}) -> str {
    detail = _ready_detail();
    detail.update(overrides);
    return json.dumps([detail]);
}

def _per_bot_ready_detail(bot_id: str, viewer_port: int, target_label: any = None) -> dict[str, any] {
    target = per_bot_local_vm_target(bot_id);
    detail = _ready_detail();
    detail["Config"]["Labels"][TARGET_LABEL] = target_label if target_label is not None else target["label"];
    detail["Mounts"][0]["Source"] = target["workspaceDir"];
    detail["HostConfig"]["PortBindings"]["6901/tcp"][0]["HostPort"] = str(viewer_port);
    detail["NetworkSettings"] = {"Ports": {"6901/tcp": [{"HostIp": "127.0.0.1", "HostPort": str(viewer_port)}]}};
    return detail;
}

def _desktop_probes(runtime: str, container: str, overall: str = "ok") -> dict[str, any] {
    ex = _driver_exec(runtime, container);
    return {
        ex + " --version": f"cua-driver {CUA_DRIVER_VERSION}\n",
        ex + " status --socket " + CUA_SOCKET: "running\n",
        ex + " call health_report {} --socket " + CUA_SOCKET: json.dumps({"schema_version": "1", "overall": overall, "checks": []}),
        ex + " call get_desktop_state {} --socket " + CUA_SOCKET + " --screenshot-out-file /tmp/openmausbot-readiness.png": "{}\n",
        runtime + " exec " + container + " base64 -w0 /tmp/openmausbot-readiness.png": _VALID_PNG_B64,
    };
}

def _raises(fn: any, needle: str = "") -> dict[str, any] {
    try {
        fn();
    } except Exception as e {
        assert needle in str(e), f"{needle!r} not in {str(e)!r}";
        return {"status": _status_of(e), "message": str(e)};
    }
    assert False, "expected an error";
    return {};
}

# ── Apple container image inspection ───────────────────────────────────────

test "reads the Linux ARM64 variant, preserving the inspected image digest" {
    f = _fake(_with(_apple_runtime(), {
        f"container image inspect {IMAGE}": _apple_image_inspect([_apple_variant({}, "amd64"), _apple_variant(_prepared_labels())]),
        f"container inspect {CONTAINER}": _err("missing container"),
    }));
    status = container_computer_status(f["run"], "darwin");
    assert status["image"] is True;
    assert status["image_id"] == "managed-image-id";
    assert local_vm_recreatable_on_demand(status);
}

test "does not let root labels override missing or ambiguous ARM64 variants" {
    for variants in [[], [_apple_variant(_prepared_labels()), _apple_variant(_prepared_labels())]] {
        image = json.loads(_apple_image_inspect(variants));
        image[0]["Config"] = {"Labels": _prepared_labels()};
        image[0]["configuration"]["labels"] = _prepared_labels();
        f = _fake(_with(_apple_runtime(), {
            f"container image inspect {IMAGE}": json.dumps(image),
            f"container inspect {CONTAINER}": _err("missing container"),
        }));
        status = container_computer_status(f["run"], "darwin");
        assert status["image"] is False;
        assert not local_vm_recreatable_on_demand(status);
    }
}

test "rejects malformed, foreign or stale Apple image variants without authorizing recreation" {
    p = _prepared_labels();
    def _patched(k: str, v: str) -> dict[str, any] {
        out = dict(p);
        out[k] = v;
        return out;
    }
    cases = [
        [_apple_variant(None)],
        [_apple_variant(p, "amd64"), _apple_variant({})],
        [_apple_variant(p, "arm64", "windows")],
        [_apple_variant(p, "amd64")],
        [_apple_variant(p), _apple_variant(p)],
        [],
        [_apple_variant(_patched(DRIVER_LABEL, "stale"))],
        [_apple_variant(_patched(BASE_IMAGE_LABEL, "stale"))],
        [_apple_variant(_patched(IMAGE_LAYER_LABEL, "stale"))],
        [_apple_variant(_patched(MANAGED_LABEL, "0"))],
        [None],
    ];
    for variants in cases {
        f = _fake(_with(_apple_runtime(), {
            f"container image inspect {IMAGE}": _apple_image_inspect(variants),
            f"container inspect {CONTAINER}": _err("missing container"),
        }));
        status = container_computer_status(f["run"], "darwin");
        assert status["image"] is False, json.dumps(variants);
        assert not local_vm_recreatable_on_demand(status);
    }
}

# ── managed image preparation ──────────────────────────────────────────────

test "uses each runtime's supported pull command before building" {
    for runtime in ["container", "docker", "podman"] {
        st: dict[str, any] = {"prepared": False, "context": None, "dockerfile": None, "calls": []};
        def _run(command: str, args: list[str], timeout_ms: int = 0) -> str {
            st["calls"].append([command] + list(args));
            joined = " ".join(args);
            if command == "/usr/bin/which" {
                if args[0] == runtime { return runtime; }
                raise Exception("missing executable");
            }
            if command != runtime { raise Exception("unexpected runtime"); }
            if args[0] == "info" or joined == "system status" { return "running"; }
            if " ".join(args[:2]) == "image inspect" {
                if not st["prepared"] { raise Exception("missing image"); }
                if runtime == "container" { return _apple_image_inspect([_apple_variant(_prepared_labels())]); }
                return _prepared_image_inspect();
            }
            if args[0] == "inspect" { raise Exception("missing container"); }
            pull = f"image pull {BASE_IMAGE}" if runtime == "container" else f"pull {BASE_IMAGE}";
            if joined == pull { return "pulled"; }
            if " ".join(args[:3]) == f"build -t {IMAGE}" {
                st["context"] = args[3];
                with open(os.path.join(args[3], "Dockerfile"), "r", encoding="utf-8", newline="") as fh {
                    st["dockerfile"] = fh.read();
                }
                st["prepared"] = True;
                return "built";
            }
            raise Exception("unsupported command: " + command + " " + joined);
        }
        status = container_computer_action("pull", _run, "darwin");
        assert status["image"] is True, runtime;
        assert st["dockerfile"] == managed_image_dockerfile();
        pull_args = ["image", "pull", BASE_IMAGE] if runtime == "container" else ["pull", BASE_IMAGE];
        joined_calls = [" ".join(c) for c in st["calls"]];
        pull_index = joined_calls.index(" ".join([runtime] + pull_args));
        build_index = [i for i in range(len(st["calls"])) if st["calls"][i][1] == "build"][0];
        assert build_index > pull_index;
        assert st["context"] is not None and not os.path.exists(st["context"]);
    }
}

# ── containerComputerStatus ────────────────────────────────────────────────

test "prefers the supported Podman image store when Docker is also healthy on Windows" {
    f = _fake({
        "where.exe podman": "C:\\Program Files\\RedHat\\Podman\\podman.exe\n",
        "where.exe docker": "C:\\Program Files\\Docker\\docker.exe\n",
        "podman info --format json": "{\"host\":{\"arch\":\"amd64\"}}\n",
        "docker info --format {{.ServerVersion}}": "29.0.0\n",
    });
    assert container_runtime_status(f["run"], "win32") == {"runtime": "podman", "available": ["podman", "docker"], "daemonUp": True};
}

test "checks Podman-on-Windows readiness by capabilities with a WSL-translated durable mount" {
    for caps in ["exact", "legacy", "missing-effective", "missing-bounding", "extra-effective", "extra-bounding"] {
        target = dict(per_bot_local_vm_target("bot-win"));
        target["workspaceDir"] = "C:\\Users\\light\\.openmausbot\\vm-homes\\win-target";
        detail = _per_bot_ready_detail("bot-win", 41629);
        detail["Mounts"][0]["Source"] = "/mnt/c/Users/light/.openmausbot/vm-homes/win-target";
        hc = dict(detail["HostConfig"]);
        hc.update({"CapDrop": ["CAP_CHOWN", "CAP_DAC_OVERRIDE"], "CapAdd": [], "PidMode": "private", "UTSMode": "private", "CgroupnsMode": None});
        detail["HostConfig"] = hc;
        eff = ["CAP_SETGID", "CAP_SETUID", "CAP_SYS_CHROOT"];
        bnd = ["CAP_SETGID", "CAP_SETUID", "CAP_SYS_CHROOT"];
        if caps == "legacy" or caps == "missing-effective" { eff.pop(); }
        if caps == "legacy" or caps == "missing-bounding" { bnd.pop(); }
        if caps == "extra-effective" { eff.append("CAP_SYS_ADMIN"); }
        if caps == "extra-bounding" { bnd.append("CAP_SYS_ADMIN"); }
        detail["EffectiveCaps"] = eff;
        detail["BoundingCaps"] = bnd;
        responses = _with({
            "where.exe podman": "C:\\Program Files\\RedHat\\Podman\\podman.exe\n",
            "where.exe docker": _err(),
            "podman info --format json": "{\"host\":{\"arch\":\"amd64\"}}\n",
            f"podman image inspect {IMAGE}": _prepared_image_inspect(),
            f"podman inspect {target['containerName']}": json.dumps([detail]),
        }, _desktop_probes("podman", target["containerName"]));
        f = _fake(responses);
        status = container_computer_status(f["run"], "win32", target);
        if caps != "exact" {
            assert status["security"] == "unsafe" and status["ready"] is False, caps;
            assert "recreate" in status["problem"];
            assert not local_vm_recreatable_on_demand(status);
            assert not any([c.startswith("podman exec ") for c in f["calls"]]);
            assert not any([c.startswith("podman run ") or c.startswith("podman rm ") or c.startswith("podman start ") or c.startswith("podman stop ") for c in f["calls"]]);
            continue;
        }
        assert status["runtime"] == "podman";
        assert status["security"] == "hardened" and status["persistence"] == "durable";
        assert status["network"] == "loopback" and status["ready"] is True, status["problem"];
    }
}

test "rejects extra effective or bounding capabilities in Podman inspect output" {
    config = {
        "Memory": 4 * 1024 * 1024 * 1024, "MemorySwap": 4 * 1024 * 1024 * 1024,
        "NanoCpus": 2000000000, "PidsLimit": 512, "CapDrop": ["CAP_CHOWN"], "CapAdd": [],
        "Privileged": False, "PidMode": "private", "IpcMode": "private", "UTSMode": "private",
        "ShmSize": 512 * 1024 * 1024, "Devices": [], "DeviceRequests": None, "SecurityOpt": [],
        "UsernsMode": "", "OomKillDisable": False, "AutoRemove": False,
        "RestartPolicy": {"Name": "no", "MaximumRetryCount": 0},
    };
    full = ["CAP_SETGID", "CAP_SETUID", "CAP_SYS_CHROOT"];
    assert podman_security_is_hardened(config, full, full);
    assert not podman_security_is_hardened(config, ["CAP_SETGID", "CAP_SETUID"], ["CAP_SETGID", "CAP_SETUID"]);
    for mode in ["private", "keep-id:uid=1000,gid=1000", "host", "container:other", "keep-id:uid=0,gid=0", "auto"] {
        c = dict(config);
        c["UsernsMode"] = mode;
        assert podman_security_is_hardened(c, full, full) == (mode == "private" or mode == "keep-id:uid=1000,gid=1000"), mode;
    }
    assert not podman_security_is_hardened(config, ["CAP_NET_RAW"] + full, full);
}

test "does not extend Docker/VPS capabilities with any restart policy" {
    for policy in ["no", "always", "on-failure", "unless-stopped"] {
        config = _ready_detail()["HostConfig"];
        config["RestartPolicy"]["Name"] = policy;
        assert docker_security_is_hardened(config, "any");
        config["CapAdd"].append("CAP_SYS_CHROOT");
        assert not docker_security_is_hardened(config, "any");
    }
}

test "accepts operator-selected resources in the shared isolation check" {
    full = ["CAP_SETGID", "CAP_SETUID", "CAP_SYS_CHROOT"];
    for resources in [
        {"Memory": 1024 ** 3, "MemorySwap": 2 * 1024 ** 3, "NanoCpus": 4000000000, "PidsLimit": 1024, "ShmSize": 1024 ** 3, "OomKillDisable": True},
        {"Memory": 0, "MemorySwap": -1, "NanoCpus": 0, "PidsLimit": -1, "ShmSize": 64 * 1024 ** 2, "OomKillDisable": None},
    ] {
        config = _ready_detail()["HostConfig"];
        config.update(resources);
        assert docker_security_is_hardened(config);
        assert podman_security_is_hardened(config, full, full);
    }
}

test "keeps Local VM lifecycle under app control whatever the restart policy" {
    for policy in ["always", "on-failure", "unless-stopped"] {
        config = _ready_detail()["HostConfig"];
        config["RestartPolicy"]["Name"] = policy;
        assert not docker_security_is_hardened(config);
    }
}

test "keeps per-bot identities, workspaces, and ephemeral viewer ports separate" {
    target = per_bot_local_vm_target("bot-a");
    f = _fake(_with(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {target['containerName']}": json.dumps([_per_bot_ready_detail("bot-a", 49152)]),
    }), _desktop_probes("docker", target["containerName"])));
    status = container_computer_status(f["run"], "linux", target);
    assert status["container_name"] == target["containerName"];
    assert status["target_key"] == target["key"];
    assert status["workspace_path"] == target["workspaceDir"];
    assert status["viewer_port"] == 49152;
    assert status["managed"] is True and status["persistence"] == "durable" and status["ready"] is True;
    assert "http://127.0.0.1:49152/vnc.html" in status["viewer_url"];
}

test "refuses a per-bot container carrying another target's label" {
    target = per_bot_local_vm_target("bot-a");
    other = per_bot_local_vm_target("bot-b");
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {target['containerName']}": json.dumps([_per_bot_ready_detail("bot-a", 49152, other["label"])]),
    }));
    status = container_computer_status(f["run"], "linux", target);
    assert status["managed"] is False and status["ready"] is False;
    assert "not created by OpenMausBot" in status["problem"];
}

test "prefers a running runtime over an earlier installed but stopped one" {
    f = _fake({
        "/usr/bin/which docker": "docker\n",
        "/usr/bin/which podman": "podman\n",
        "docker info --format {{.ServerVersion}}": _err("daemon stopped"),
        "podman info --format json": "{\"host\":{\"arch\":\"amd64\"}}\n",
        f"podman image inspect {IMAGE}": _prepared_image_inspect(),
        f"podman inspect {CONTAINER}": json.dumps([{
            "State": {"Running": False},
            "HostConfig": {"PortBindings": {"6901/tcp": [{"HostIp": "127.0.0.1"}]}},
        }]),
    });
    status = container_computer_status(f["run"], "linux");
    assert status["runtime"] == "podman";
    assert status["available"] == ["docker", "podman"];
    assert status["daemonUp"] is True and status["image"] is True;
    assert status["container"] == "stopped" and status["network"] == "loopback";
}

test "uses Apple container's actual system and inspect commands" {
    labels = _prepared_labels();
    labels[WORKSPACE_LABEL] = "1";
    f = _fake(_with(_apple_runtime(), {
        f"container image inspect {IMAGE}": _apple_image_inspect([_apple_variant(_prepared_labels())]),
        f"container inspect {CONTAINER}": json.dumps([{
            "configuration": {
                "image": {"reference": IMAGE, "descriptor": {"digest": "sha256:managed-image-id"}},
                "resources": {"cpus": 2, "memoryInBytes": 4 * 1024 * 1024 * 1024},
                "publishedPorts": [{"hostAddress": "127.0.0.1", "containerPort": 6901}],
                "labels": labels,
                "mounts": [{"source": VM_WORKSPACE_DIR, "destination": VM_WORKSPACE_GUEST, "options": []}],
            },
            "status": {"state": "running"},
        }]),
    }));
    status = container_computer_status(f["run"], "darwin");
    assert status["runtime"] == "container";
    assert status["container"] == "running" and status["network"] == "loopback";
    assert status["imageMatches"] is True and status["managed"] is True;
    assert status["security"] == "hardened" and status["persistence"] == "durable";
    assert "container info --format {{.ServerVersion}}" not in f["calls"];
    assert "stopped_at" not in status;
}

test "does not report a running container as ready when its viewer is public" {
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect({"HostConfig": {
            "Memory": 4 * 1024 * 1024 * 1024, "MemorySwap": 4 * 1024 * 1024 * 1024,
            "NanoCpus": 2000000000, "PidsLimit": 512, "CapDrop": ["ALL"],
            "CapAdd": ["CAP_SETUID", "CAP_SETGID"],
            "PortBindings": {"6901/tcp": [{"HostIp": "0.0.0.0"}]},
        }}),
    }));
    status = container_computer_status(f["run"], "linux");
    assert status["container"] == "running" and status["network"] == "unsafe" and status["ready"] is False;
}

test "rejects a privileged or host-namespaced Local VM even with correct limits" {
    for ovr in [
        {"Privileged": True},
        {"IpcMode": "host"},
        {"PidMode": "host"},
        {"CgroupnsMode": "host"},
        {"SecurityOpt": ["seccomp=unconfined"]},
        {"DeviceRequests": [{"Driver": "nvidia"}]},
        {"AutoRemove": True},
        {"RestartPolicy": {"Name": "always", "MaximumRetryCount": 0}},
    ] {
        hc = _ready_detail()["HostConfig"];
        hc.update(ovr);
        f = _fake(_with(_docker_linux(), {
            f"docker image inspect {IMAGE}": _prepared_image_inspect(),
            f"docker inspect {CONTAINER}": _ready_inspect({"HostConfig": hc}),
        }));
        status = container_computer_status(f["run"], "linux");
        assert status["security"] == "unsafe", json.dumps(ovr);
        assert status["ready"] is False;
    }
}

test "rejects missing or unexpected host mounts instead of exposing them to the bot" {
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect({"Mounts": [
            {"Type": "bind", "Source": VM_WORKSPACE_DIR, "Destination": VM_WORKSPACE_GUEST, "RW": True},
            {"Type": "bind", "Source": "/tmp/unexpected", "Destination": "/host", "RW": True},
        ]}),
    }));
    status = container_computer_status(f["run"], "linux");
    assert status["persistence"] == "unsafe" and status["ready"] is False;
    assert status["problem"] == "The existing Local VM is missing its durable folder; recreate it";
}

test "does not mistake an unrelated container executable for Apple container off macOS" {
    f = _fake({"where.exe docker": _err(), "where.exe podman": _err()});
    status = container_computer_status(f["run"], "win32");
    assert status["runtime"] is None;
    assert "where.exe container" not in f["calls"];
}

test "reports ready only after the exact image, limits, network, version and daemon pass" {
    f = _fake(_with(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect(),
    }), _desktop_probes("docker", CONTAINER)));
    status = container_computer_status(f["run"], "linux");
    assert status["imageMatches"] is True and status["managed"] is True;
    assert status["network"] == "loopback" and status["security"] == "hardened" and status["persistence"] == "durable";
    assert status["desktopReady"] is True and status["desktop_error"] is None;
    assert status["ready"] is True and status["problem"] is None;
    assert status["driver_version"] == "0.20.0";
    assert "#autoconnect=true&resize=scale&password=secret123" in status["viewer_url"];
    assert status["stopped_at"] is None;
}

test "can inspect the viewer without waiting for CUA health or screenshots" {
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect(),
    }));
    status = container_computer_status(f["run"], "linux", None, False);
    assert "#autoconnect=true&resize=scale&password=secret123" in status["viewer_url"];
    assert status["managed"] is True;
    assert not any([c.startswith("docker exec") for c in f["calls"]]);
}

test "reports the bounded desktop startup error instead of waiting forever" {
    error_probe = f"docker exec {CONTAINER} tail -n 4 /var/log/supervisor/cua-driver.error.log";
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect(),
        _version_probe(): _err("driver unavailable"),
        error_probe: "X display :1 did not become ready within 45 seconds\n",
    }));
    status = container_computer_status(f["run"], "linux");
    assert status["desktopReady"] is False;
    assert "did not become ready" in status["desktop_error"];
    assert "desktop failed to start" in status["problem"];
}

test "does not report ready when the driver's health contract fails" {
    error_probe = f"docker exec {CONTAINER} tail -n 4 /var/log/supervisor/cua-driver.error.log";
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect(),
        _version_probe(): f"cua-driver {CUA_DRIVER_VERSION}\n",
        _status_probe(): "running\n",
        _health_probe(): json.dumps({"schema_version": "1", "overall": "failed", "checks": []}),
        error_probe: "",
    }));
    status = container_computer_status(f["run"], "linux");
    assert status["desktopReady"] is False;
    assert "health report is failed" in status["desktop_error"];
    assert _readiness_probe() not in f["calls"];
}

test "keeps an owned stale container removable without treating it as ready" {
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect({"Config": {"Image": IMAGE, "Labels": {
            MANAGED_LABEL: "1", DRIVER_LABEL: "0.12.4", BASE_IMAGE_LABEL: "wrong",
            IMAGE_LAYER_LABEL: "old", WORKSPACE_LABEL: "1",
        }}}),
    }));
    status = container_computer_status(f["run"], "linux");
    assert status["managed"] is True and status["imageMatches"] is False and status["ready"] is False;
    assert "older desktop or Cua Driver" in status["problem"];
    assert _version_probe() not in f["calls"];
}

test "rejects a container created from a stale build under the same mutable tag" {
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect({"Image": "sha256:previous-build-id"}),
    }));
    status = container_computer_status(f["run"], "linux");
    assert status["image_id"] == "managed-image-id";
    assert status["imageMatches"] is False and status["ready"] is False;
    assert "older desktop or Cua Driver" in status["problem"];
}

test "does not treat an unlabelled image under the local tag as prepared" {
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": json.dumps([{"Config": {"Labels": {}}}]),
        f"docker inspect {CONTAINER}": _err("missing container"),
    }));
    status = container_computer_status(f["run"], "linux");
    assert status["image"] is False;
    assert "Prepare the Cua desktop image" in status["problem"];
}

# ── Cua integration ────────────────────────────────────────────────────────

test "managed image Dockerfile is byte-identical to the TypeScript contract" {
    # Drift guard: sha256 of server/container-computer.ts managedImageDockerfile()
    # at the time of the port. Re-derive it (node --experimental-strip-types)
    # whenever the TS recipe changes, and change both together.
    d = managed_image_dockerfile();
    assert hashlib.sha256(d.encode("utf-8")).hexdigest() == "b95a484db3c765be4b36c7b68f981cf0a2476854a2ee21de6d5677d3b21ed60e";
    assert len(d) == 5659;
}

test "builds an exact, checksum-verified Cua Driver 0.20.0 image" {
    d = managed_image_dockerfile();
    assert BASE_IMAGE.startswith(BASE_IMAGE_REPOSITORY + "@sha256:") and len(BASE_IMAGE_DIGEST) == 71;
    for needle in [
        f"FROM {BASE_IMAGE}",
        "cua_driver-0.20.0-py3-none-manylinux_2_31_x86_64.whl",
        "cua_driver-0.20.0-py3-none-manylinux_2_31_aarch64.whl",
        "sha256sum -c -",
        f"install -D -m 0755 \"$driver_bin\" {CUA_EXECUTABLE}",
        f"cua-driver {CUA_DRIVER_VERSION}",
        f"serve --socket {CUA_SOCKET} --permission-mode standard",
        "CUA_DRIVER_RS_TELEMETRY_ENABLED=0",
        "prepare-openmausbot-workspace.sh",
        "if ! chmod 0700 \"$workspace\"",
        "test -r \"$directory\" && test -w \"$directory\" && test -x \"$directory\"",
        "migrate_profile google-chrome",
        "migrate_profile chromium",
        "SingletonLock",
        f"{IMAGE_LAYER_LABEL}=\"{IMAGE_LAYER_VERSION}\"",
        "did not become ready within 45 seconds",
        "NotoSansCJKjp-Regular.otf",
        "fc-cache -f",
    ] {
        assert needle in d, needle;
    }
    assert "/tmp/cua-driver.whl" not in d;
    assert "while ! DISPLAY=:1 xset q" not in d;
    gate = d.find("[ ! -s \"$ssl_lib\" ]");
    assert gate > -1 and d.find("curl -fsSL") > gate;
}

test "captures the preview through Cua Driver and hands back raw base64 and a bare format" {
    screenshot_call = _dx() + " call get_desktop_state {} --socket " + CUA_SOCKET + " --screenshot-out-file /tmp/openmausbot-preview.png";
    f = _fake(_with(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect(),
        screenshot_call: "{}\n",
        f"docker exec {CONTAINER} base64 -w0 /tmp/openmausbot-preview.png": _VALID_PNG_B64,
    }), _desktop_probes("docker", CONTAINER, "degraded")));
    frame = container_computer_frame(f["run"], "linux");
    assert frame == {"png": _VALID_PNG_B64, "format": "png"};
    assert not frame["png"].startswith("data:");
    assert screenshot_call in f["calls"];
    assert not any([("xdotool" in c.lower() or "scrot" in c.lower() or "vnc" in c.lower()) for c in f["calls"]]);
}

test "refuses a truncated preview frame with 502" {
    screenshot_call = _dx() + " call get_desktop_state {} --socket " + CUA_SOCKET + " --screenshot-out-file /tmp/openmausbot-preview.png";
    f = _fake(_with(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect(),
        screenshot_call: "{}\n",
        f"docker exec {CONTAINER} base64 -w0 /tmp/openmausbot-preview.png": base64.b64encode(_VALID_PNG[:-4]).decode("ascii"),
    }), _desktop_probes("docker", CONTAINER)));
    def _go { container_computer_frame(f["run"], "linux"); }
    r = _raises(_go, "incomplete screenshot");
    assert r["status"] == 502;
}

test "whole screenshot recognizes complete PNG and JPEG frames only" {
    assert whole_screenshot(_VALID_PNG)["ok"];
    assert not whole_screenshot(_VALID_PNG[:400])["ok"];
    jpeg = b"\xff\xd8" + bytes(600) + b"\xff\xd9";
    assert whole_screenshot(jpeg) == {"ok": True, "mime": "image/jpeg"};
    assert not whole_screenshot(b"\xff\xd8" + bytes(600))["ok"];
}

# ── containerComputerAction ────────────────────────────────────────────────

test "never removes an exact-name container without OpenMausBot ownership labels" {
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect({"Config": {"Image": IMAGE, "Labels": {}, "Env": []}}),
    }));
    def _go { container_computer_action("remove", f["run"], "linux"); }
    r = _raises(_go, "not created by OpenMausBot");
    assert "remove it manually" in r["message"] and r["status"] == 409;
    assert f"docker rm -f {CONTAINER}" not in f["calls"];
}

test "removes a verified OpenMausBot container even when its version labels are stale" {
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect({"Config": {"Image": IMAGE, "Labels": {
            MANAGED_LABEL: "1", DRIVER_LABEL: "0.12.4", BASE_IMAGE_LABEL: "old",
            IMAGE_LAYER_LABEL: "old", WORKSPACE_LABEL: "1",
        }, "Env": []}}),
        f"docker rm -f {CONTAINER}": "",
    }));
    container_computer_action("remove", f["run"], "linux");
    assert f"docker rm -f {CONTAINER}" in f["calls"];
}

test "fails closed instead of giving Apple container an invalid dynamic-port spec" {
    target = per_bot_local_vm_target("bot-a");
    f = _fake(_with(_apple_runtime(), {
        f"container image inspect {IMAGE}": _apple_image_inspect([_apple_variant(_prepared_labels())]),
        f"container inspect {target['containerName']}": _err("missing container"),
    }));
    def _go { container_computer_action("run", f["run"], "darwin", target); }
    _raises(_go, "require Docker or Podman");
    assert not any([c.startswith("container run ") for c in f["calls"]]);
}

test "does not create a VM before its managed image is prepared" {
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _err("missing image"),
        f"docker inspect {CONTAINER}": _err("missing container"),
    }));
    def _go { container_computer_action("run", f["run"], "linux"); }
    _raises(_go, "Prepare the Cua desktop image");
    assert not any([c.startswith("docker run ") for c in f["calls"]]);
}

test "creates a missing VM in a private workspace with a fresh viewer password" {
    tmp_root = tempfile.mkdtemp(prefix="omb-vm-run-");
    target = dict(per_bot_local_vm_target("bot-run"));
    target["workspaceDir"] = os.path.join(tmp_root, "nested", "workspace");
    st: dict[str, any] = {"created": False, "args": None};
    base = _with(_docker_linux(), {f"docker image inspect {IMAGE}": _prepared_image_inspect()});
    def _run(command: str, args: list[str], timeout_ms: int = 0) -> str {
        key = " ".join([command] + list(args));
        if args[0] == "run" {
            st["args"] = list(args);
            st["created"] = True;
            return "id\n";
        }
        if key == f"docker inspect {target['containerName']}" {
            if not st["created"] { raise Exception("missing container"); }
            return json.dumps([{"State": {"Running": False}}]);
        }
        r = base.get(key);
        if r is None or isinstance(r, Exception) { raise Exception("unexpected " + key); }
        return r;
    }
    try {
        status = container_computer_action("run", _run, "linux", target);
        assert status["container"] == "stopped";
        assert os.path.isdir(target["workspaceDir"]);
        assert (os.stat(target["workspaceDir"]).st_mode & 0o777) == 0o700;
        assert (os.stat(os.path.dirname(target["workspaceDir"])).st_mode & 0o777) == 0o700;
        args = st["args"];
        pw = [a for a in args if a.startswith("VNC_PW=")][0][len("VNC_PW="):];
        assert len(pw) == 8 and pw != "CHANGE_ME";
        assert "127.0.0.1::6901" in args;
    } finally {
        shutil.rmtree(tmp_root, ignore_errors=True);
    }
}

test "resumes a compatible stopped desktop without removing it" {
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect({"State": {"Running": False, "FinishedAt": "2026-10-01T12:00:00Z"}}),
        f"docker start {CONTAINER}": CONTAINER,
    }));
    stopped = container_computer_status(f["run"], "linux");
    assert local_vm_resumable(stopped);
    assert stopped["resumable"] is True;
    assert stopped["stopped_at"] == "2026-10-01T12:00:00Z";
    container_computer_action("start", f["run"], "linux");
    assert f"docker start {CONTAINER}" in f["calls"];
    assert not any([(" rm " in c or " run " in c) for c in f["calls"]]);
}

test "refuses an incompatible, unsafe, or running desktop on resume" {
    for patch in [
        {"Config": {"Image": "foreign"}},
        {"HostConfig": {"Privileged": True}},
        {"Mounts": []},
        {"State": {"Running": True}},
    ] {
        ov = {"State": {"Running": False}};
        ov.update(patch);
        f = _fake({
            "/usr/bin/which docker": "docker\n",
            "/usr/bin/which podman": _err(),
            "docker info --format {{.ServerVersion}}": "29\n",
            f"docker image inspect {IMAGE}": _prepared_image_inspect(),
            f"docker inspect {CONTAINER}": _ready_inspect(ov),
            _version_probe(): _err("not probed in this case"),
            f"docker exec {CONTAINER} tail -n 4 /var/log/supervisor/cua-driver.error.log": "",
        });
        assert container_computer_status(f["run"], "linux")["resumable"] is False, json.dumps(patch);
        def _go { container_computer_action("start", f["run"], "linux"); }
        _raises(_go);
        assert f"docker start {CONTAINER}" not in f["calls"];
    }
}

test "rejects an unknown lifecycle action with 400" {
    def _go { container_computer_action("explode", _fake({})["run"], "linux"); }
    assert _raises(_go)["status"] == 400;
}

# ── localVmRecreatableOnDemand ─────────────────────────────────────────────

def _linux_podman -> dict[str, any] {
    return {
        "/usr/bin/which docker": _err(),
        "/usr/bin/which podman": "podman\n",
        "podman info --format json": "{\"host\":{\"arch\":\"amd64\"}}\n",
    };
}

test "recreates a Local VM the idle timer removed" {
    f = _fake(_with(_linux_podman(), {
        f"podman image inspect {IMAGE}": _prepared_image_inspect(),
        f"podman inspect {CONTAINER}": _err("no such container"),
    }));
    status = container_computer_status(f["run"], "linux", SHARED_LOCAL_VM_TARGET);
    assert status["container"] == "missing";
    assert status["problem"] == "Create the Local VM";
    assert local_vm_recreatable_on_demand(status);
}

test "does not recreate an existing stopped container" {
    detail = _ready_detail();
    detail["State"] = {"Running": False, "Status": "exited"};
    f = _fake(_with(_linux_podman(), {
        f"podman image inspect {IMAGE}": _prepared_image_inspect(),
        f"podman inspect {CONTAINER}": json.dumps([detail]),
    }));
    status = container_computer_status(f["run"], "linux", SHARED_LOCAL_VM_TARGET);
    assert status["container"] == "stopped";
    assert not local_vm_recreatable_on_demand(status);
}

test "does not create anything when no container runtime is installed" {
    f = _fake({"/usr/bin/which docker": _err(), "/usr/bin/which podman": _err()});
    status = container_computer_status(f["run"], "linux", SHARED_LOCAL_VM_TARGET);
    assert status["runtime"] is None;
    assert not local_vm_recreatable_on_demand(status);
    assert status["problem"] == "Install a supported container runtime first";
    assert "stopped_at" not in status;
}

test "does not create anything before the desktop image has been prepared" {
    f = _fake(_with(_linux_podman(), {
        f"podman image inspect {IMAGE}": _err("no such image"),
        f"podman inspect {CONTAINER}": _err("no such container"),
    }));
    status = container_computer_status(f["run"], "linux", SHARED_LOCAL_VM_TARGET);
    assert status["image"] is False;
    assert not local_vm_recreatable_on_demand(status);
}

# ── targets and argv (golden values from the TS contract) ──────────────────

test "derives opaque, distinct per-bot and pool identities" {
    a = per_bot_local_vm_target("bot-a");
    b = per_bot_local_vm_target("bot-b");
    assert a == per_bot_local_vm_target("bot-a");
    assert a["key"] != b["key"] and a["containerName"] != b["containerName"] and a["workspaceDir"] != b["workspaceDir"];
    assert "bot-a" not in a["containerName"] and "bot-a" not in a["workspaceDir"];
    assert a["key"] == "bot:53ca8050b9fd830b496278f2051479592467bfcac7129ab684fef4be1eafdb7c";
    assert a["containerName"] == "openmausbot-computer-53ca8050b9fd830b";
    assert a["workspaceDir"] == os.path.join(DATA_DIR, "vm-homes", "53ca8050b9fd830b");
    assert a["viewerPort"] is None;
    assert pool_local_vm_target(2) == {
        "key": "pool:2", "containerName": "openmausbot-computer-p2",
        "workspaceDir": os.path.join(DATA_DIR, "vm-homes", "pool-2"), "viewerPort": None, "label": "pool-2",
    };
    assert SHARED_LOCAL_VM_TARGET["viewerPort"] == 6080 and SHARED_LOCAL_VM_TARGET["containerName"] == CONTAINER;
}

test "containerRunArgs matches the TypeScript argv for every runtime" {
    t = per_bot_local_vm_target("bot-a");
    labels = [
        "--label", "com.openmausbot.local-vm=1",
        "--label", "com.openmausbot.cua-driver=0.20.0",
        "--label", "com.openmausbot.cua-base=sha256:274eb636f5cf3fc58f705916ee72b7a701270b3877369d08533a385c5325be9b",
        "--label", "com.openmausbot.image-layer=5",
        "--label", "com.openmausbot.workspace=1",
    ];
    hardening = ["--memory", "4g", "--memory-swap", "4g", "--cpus", "2", "--pids-limit", "512", "--ipc", "private", "--cgroupns", "private", "--cap-drop", "ALL", "--cap-add", "SETUID", "--cap-add", "SETGID", "--shm-size", "512m"];
    image = "localhost/openmausbot/cua-local-vm:driver-0.20.0-v5";
    assert container_run_args("docker", "secret", t) == (
        ["run", "-d", "--name", "openmausbot-computer-53ca8050b9fd830b"] + labels
        + ["--label", "com.openmausbot.local-vm-target=53ca8050b9fd830b496278f2051479592467bfcac7129ab684fef4be1eafdb7c",
           "--hostname", "openmausbot-computer-53ca8050b9fd830b"] + hardening
        + ["--mount", f"type=bind,source={t['workspaceDir']},target=/home/cua/workspace", "-e", "VNC_PW=secret", "-p", "127.0.0.1::6901", image]
    );
    assert container_run_args("podman", "pw") == (
        ["run", "-d", "--name", "openmausbot-computer", "--userns", "keep-id:uid=1000,gid=1000", "--user", "0:0"] + labels
        + ["--label", "com.openmausbot.local-vm-target=shared", "--hostname", "openmausbot-computer"] + hardening
        + ["--cap-add", "SYS_CHROOT", "--mount", f"type=bind,source={VM_WORKSPACE_DIR},target=/home/cua/workspace,relabel=private",
           "-e", "VNC_PW=pw", "-p", "127.0.0.1:6080:6901", image]
    );
    assert container_run_args("container", "pw") == (
        ["run", "-d", "--name", "openmausbot-computer"] + labels
        + ["--label", "com.openmausbot.local-vm-target=shared", "--memory", "4g", "--cpus", "2", "--cap-drop", "ALL",
           "--cap-add", "SETUID", "--cap-add", "SETGID", "--shm-size", "512m",
           "--mount", f"type=bind,source={VM_WORKSPACE_DIR},target=/home/cua/workspace", "-e", "VNC_PW=pw", "-p", "127.0.0.1:6080:6901", image]
    );
    def _go { container_run_args("container", "pw", t); }
    _raises(_go, "require Docker or Podman");
}

test "cuaExecArgs matches the TypeScript argv" {
    assert cua_exec_args(["--version"], "x", True) == [
        "exec", "-i", "-u", "cua", "-e", "HOME=/home/cua", "-e", "DISPLAY=:1",
        "-e", "CUA_DRIVER_INSTALL_CHANNEL=python_package", "-e", "CUA_DRIVER_RS_TELEMETRY_ENABLED=0",
        "x", "/usr/local/libexec/openmausbot/cua-driver", "--version",
    ];
    assert cua_exec_args(["status"])[11] == CONTAINER;
}

test "target arguments from node are shape-checked" {
    t = _target_arg(per_bot_local_vm_target("bot-a"));
    assert t["viewerPort"] is None;
    assert _target_arg(SHARED_LOCAL_VM_TARGET)["viewerPort"] == 6080;
    for bad in [None, "shared", {"key": "k"}, _with(SHARED_LOCAL_VM_TARGET, {"viewerPort": "6080"}), _with(SHARED_LOCAL_VM_TARGET, {"label": ""})] {
        def _go { _target_arg(bad); }
        assert _raises(_go)["status"] == 400;
    }
}

# ── containerExec ──────────────────────────────────────────────────────────

def _fake_exec(stdout: str = "", stderr: str = "", code: int = 0) -> dict[str, any] {
    calls: list[any] = [];
    def _ex(command: str, args: list[str], timeout_ms: int) -> dict[str, any] {
        calls.append({"command": command, "args": list(args), "timeout": timeout_ms});
        return {"stdout": stdout, "stderr": stderr, "code": code};
    }
    return {"calls": calls, "exec": _ex};
}

def _exec_target -> dict[str, any] { return per_bot_local_vm_target("bot-under-test"); }

test "runs as the desktop user in the durable workspace, with the limit enforced inside the container" {
    fx = _fake_exec("hello\n");
    result = container_exec(_exec_target(), "echo hello", 30, "podman", fx["exec"]);
    assert result == {"exitCode": 0, "stdout": "hello\n", "stderr": "", "timedOut": False};
    assert len(fx["calls"]) == 1;
    assert fx["calls"][0]["command"] == "podman";
    assert fx["calls"][0]["args"] == [
        "exec", "-u", "cua", "-w", "/home/cua/workspace", "-e", "HOME=/home/cua", "-e", "DISPLAY=:1",
        _exec_target()["containerName"], "timeout", "-k", "5", "30", "sh", "-lc", "echo hello",
    ];
    assert fx["calls"][0]["timeout"] == 50000;
}

test "returns a failing command's exit code and stderr instead of throwing" {
    fx = _fake_exec("", "ModuleNotFoundError: No module named 'reportlab'\n", 1);
    r = container_exec(_exec_target(), "python3 make.py", None, "docker", fx["exec"]);
    assert r["exitCode"] == 1 and r["timedOut"] is False;
    assert r["stderr"] == "ModuleNotFoundError: No module named 'reportlab'\n";
}

test "reports a stopped command as timed out" {
    for code in [124, 137] {
        fx = _fake_exec("", "", code);
        r = container_exec(_exec_target(), "sleep 999", 1, "podman", fx["exec"]);
        assert r["timedOut"] is True and r["exitCode"] == code;
    }
}

test "bounds the time limit and rejects an empty or oversized command" {
    fx = _fake_exec();
    container_exec(_exec_target(), "true", 99999, "podman", fx["exec"]);
    container_exec(_exec_target(), "true", -5, "podman", fx["exec"]);
    k = fx["calls"][0]["args"].index("-k");
    assert [c["args"][k + 2] for c in fx["calls"]] == ["300", "1"];
    def _empty { container_exec(_exec_target(), "   ", None, "podman", fx["exec"]); }
    def _long { container_exec(_exec_target(), "x" * 20001, None, "podman", fx["exec"]); }
    assert _raises(_empty)["status"] == 400;
    assert _raises(_long)["status"] == 400;
    assert len(fx["calls"]) == 2;
    for secs in [float("nan"), float("inf"), float("-inf")] {
        def _bad { container_exec(_exec_target(), "true", secs, "podman", fx["exec"]); }
        assert _raises(_bad)["status"] == 400;
    }
    assert len(fx["calls"]) == 2;
}

test "keeps the start and the end of a long output, where the error usually is" {
    long = "START" + "x" * 50000 + "END";
    clipped = clip_exec_output(long);
    assert len(clipped) < 20100;
    assert clipped.startswith("START") and clipped.endswith("END");
    assert "characters omitted" in clipped;
    assert clip_exec_output("short") == "short";
}

# ── production runner / PATH ───────────────────────────────────────────────

test "the default runner finds a fake runtime through OMB_EXTRA_PATH" {
    tmp_root = tempfile.mkdtemp(prefix="omb-fake-docker-");
    fake = os.path.join(tmp_root, "docker");
    with open(fake, "w") as fh {
        fh.write("#!/bin/sh\necho \"fake $*\"\n[ \"$1\" = fail ] && { echo nope >&2; exit 3; }\nexit 0\n");
    }
    os.chmod(fake, 0o755);
    saved = os.environ.get("OMB_EXTRA_PATH");
    os.environ["OMB_EXTRA_PATH"] = tmp_root;
    try {
        assert augmented_path().split(os.pathsep)[0] == tmp_root;
        assert _default_run("docker", ["info"], 5000) == "fake info\n";
        def _go { _default_run("docker", ["fail"], 5000); }
        assert "nope" in _raises(_go, "Command failed")["message"];
        r = _default_exec("docker", ["fail"], 5000);
        assert r == {"stdout": "fake fail\n", "stderr": "nope\n", "code": 3};
    } finally {
        if saved is None { os.environ.pop("OMB_EXTRA_PATH", None); }
        else { os.environ["OMB_EXTRA_PATH"] = saved; }
        shutil.rmtree(tmp_root, ignore_errors=True);
    }
}

test "public endpoints validate their arguments and use the hook table" {
    f = _fake(_with(_docker_linux(), {
        f"docker image inspect {IMAGE}": _prepared_image_inspect(),
        f"docker inspect {CONTAINER}": _ready_inspect(),
    }));
    container_set_hooks({"run": f["run"], "platform": "linux"});
    try {
        out = computer_vm_status(SHARED_LOCAL_VM_TARGET, False);
        assert out["status"]["managed"] is True;
        assert not any([c.startswith("docker exec") for c in f["calls"]]);
        bad = computer_vm_status("nope", False);
        assert bad["ok"] is False and bad["status"] == 400;
        assert computer_vm_exists("docker", SHARED_LOCAL_VM_TARGET)["exists"] is True;
        assert computer_vm_exists("rkt", SHARED_LOCAL_VM_TARGET)["status"] == 400;
        rt = computer_runtime_status();
        assert rt == {"runtime": "docker", "available": ["docker"], "daemonUp": True};
    } finally {
        container_set_hooks({});
    }
}
