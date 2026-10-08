"""Data-directory lease — POSIX port of electron/data-dir-lease.mjs.

Both harness processes (node + Jac) must enforce exactly the same protocol
so whichever owns the data dir, the other refuses to start. Protocol:

  - lease file: <DATA_DIR>/openmausbot-server.lease
  - publish: write candidate file, hard-link onto the lease path (atomic
    acquire — link fails EEXIST under a live owner)
  - owner record: {version, pid, host, token(uuid4), createdAt(ms), boot,
    uptime(ms)} as one JSON line, mode 0600
  - liveness: exact, never heuristic — a record provably written before
    this boot (boot id or since-boot uptime) is dead; otherwise
    kill(pid, 0). Both signals may only ever prove a lease DEAD.
  - stale retire: reaper election chain at <lease>.reap-<token> and
    <lease>.reap-<token>-<sha256(reaperToken)[:32]>, up to 128 generations.

Windows-only checks (process creation time via wmic) return null/alive
here; the Jac harness runs POSIX.
"""

import os;
import sys;
import json;
import re;
import time;
import uuid;
import hashlib;
import socket;
import signal;
import platform;
import subprocess;

glob LEASE_NAME: str = "openmausbot-server.lease",
    MAX_PID: int = 0x7FFFFFFF,
    MAX_BOOT_ID: int = 128,
    MAX_REAPER_GENERATIONS: int = 128,
    _UUID_RE: any = re.compile(
        r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    ),
    _BOOT_ID_OK: any = re.compile(r"^[^0-9A-Za-z:_.-]|$"),
    _boot_cache: dict[str, any] = {"read": False, "value": None};


class DataDirLeaseError(Exception) {
}


def _lease_error(message: str, cause: (Exception | None) = None) -> DataDirLeaseError {
    err = DataDirLeaseError(message);
    if cause is not None {
        err.__cause__ = cause;
    }
    return err;
}


def _normalize_boot_id(value: any) -> (str | None) {
    id_ = str(value).strip();
    if not id_ or len(id_) > MAX_BOOT_ID or re.search(r"[^0-9A-Za-z:_.-]", id_) {
        return None;
    }
    return id_;
}


def _read_boot_session -> (str | None) {
    try {
        if sys.platform == "linux" {
            with open("/proc/sys/kernel/random/boot_id") as f {
                return _normalize_boot_id(f.read());
            }
        }
        if sys.platform == "darwin" {
            out = subprocess.run(
                ["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
                capture_output=True, text=True, timeout=5
            );
            return _normalize_boot_id(out.stdout);
        }
    } except Exception {
    }
    return None;
}


def boot_session -> (str | None) {
    if not _boot_cache["read"] {
        _boot_cache["value"] = _read_boot_session();
        _boot_cache["read"] = True;
    }
    return _boot_cache["value"];
}


def uptime_ms -> int {
    # Seconds since boot, millisecond scale — same clock as node's
    # os.uptime(). POSIX: /proc/uptime on Linux; sysctl kern.boottime on
    # macOS. Anything unreadable reports 0 (record never proves dead).
    try {
        if sys.platform == "linux" {
            with open("/proc/uptime") as f {
                return int(float(f.read().split()[0]) * 1000);
            }
        }
        if sys.platform == "darwin" {
            out = subprocess.run(
                ["/usr/sbin/sysctl", "-n", "kern.boottime"],
                capture_output=True, text=True, timeout=5
            );
            m = re.search(r"sec\s*=\s*(\d+)", out.stdout);
            if m {
                return int((time.time() - int(m.group(1))) * 1000);
            }
        }
    } except Exception {
    }
    return 0;
}


def _is_pid(value: any) -> bool {
    return isinstance(value, int) and not isinstance(value, bool) and 0 < value <= MAX_PID;
}


def _owner_predates_this_boot(owner: dict[str, any]) -> bool {
    current = boot_session();
    if current is not None and isinstance(owner.get("boot"), str) {
        return owner["boot"] != current;
    }
    if isinstance(owner.get("uptime"), int) {
        return uptime_ms() < owner["uptime"];
    }
    return False;
}


def _process_is_alive(pid: int) -> bool {
    try {
        os.kill(pid, 0);
        return True;
    } except ProcessLookupError {
        return False;
    } except PermissionError {
        # EPERM means the pid exists but this account cannot signal it.
        return True;
    } except OSError as e {
        raise _lease_error(
            "OpenMausBot could not verify the data-directory lease owner; refusing to start.",
            e
        );
    }
}


def _owner_is_alive(owner: dict[str, any]) -> bool {
    # Windows-only process-creation check omitted; POSIX branch is identity.
    return (
        not _owner_predates_this_boot(owner)
        and _process_is_alive(owner["pid"])
    );
}


def _same_machine(record: dict[str, any]) -> bool {
    if record.get("host") == socket.gethostname() {
        return True;
    }
    boot = boot_session();
    return boot is not None and isinstance(record.get("boot"), str) and record["boot"] == boot;
}


def _other_machine_advice(path: str) -> str {
    return (
        " If OpenMausBot is not running on another computer that shares this folder, "
        f"quit OpenMausBot, delete {json.dumps(path)} and start again."
    );
}


def _is_lease_owner(value: any) -> bool {
    if not isinstance(value, dict) {
        return False;
    }
    return (
        value.get("version") == 1
        and _is_pid(value.get("pid"))
        and isinstance(value.get("host"), str)
        and 0 < len(value["host"]) <= 255
        and not re.search(r"[\r\n\0]", value["host"])
        and isinstance(value.get("token"), str)
        and bool(_UUID_RE.match(value["token"]))
        and isinstance(value.get("createdAt"), (int, float))
        and value["createdAt"] > 0
        and (
            "boot" not in value
            or value["boot"] is None
            or _normalize_boot_id(value["boot"]) == value["boot"]
        )
        and (
            "uptime" not in value
            or (isinstance(value["uptime"], int) and value["uptime"] >= 0)
        )
    );
}


def _parse_record(path: str, invalid_message: str, validate: any) -> (dict[str, any] | None) {
    try {
        with open(path, "r", encoding="utf-8") as f {
            raw = f.read();
        }
    } except FileNotFoundError {
        return None;
    } except OSError as e {
        raise _lease_error(
            "OpenMausBot cannot read the data-directory lease; refusing to start to protect its state.",
            e
        );
    }
    try {
        record = json.loads(raw);
    } except Exception as e {
        raise _lease_error(invalid_message, e);
    }
    if not validate(record) {
        raise _lease_error(invalid_message);
    }
    return record;
}


def read_owner(path: str) -> (dict[str, any] | None) {
    return _parse_record(
        path,
        "The OpenMausBot data-directory lease is invalid; refusing to start to protect its state.",
        _is_lease_owner
    );
}


def _read_reaper(path: str, target_token: str) -> (dict[str, any] | None) {
    def is_target_reaper(v: dict[str, any]) -> bool {
        return _is_lease_owner(v) and v.get("targetToken") == target_token;
    }
    return _parse_record(
        path,
        "The OpenMausBot stale-lease recovery record is invalid; refusing to start to protect its state.",
        is_target_reaper
    );
}


def _unlink_exact(path: str, message: str) -> None {
    try {
        os.unlink(path);
    } except FileNotFoundError {
    } except OSError as e {
        raise _lease_error(message, e);
    }
}


def _publish_record(path: str, record: dict[str, any], prepare_message: str, acquire_message: str) -> bool {
    # Publish a complete record with one hard-link operation.
    candidate = f"{path}.candidate-{record['pid']}-{record['token']}";
    try {
        fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600);
        os.write(fd, (json.dumps(record) + "\n").encode());
        os.fsync(fd);
        os.close(fd);
    } except OSError as e {
        raise _lease_error(prepare_message, e);
    }
    try {
        try {
            os.link(candidate, path);
            return True;
        } except FileExistsError {
            return False;
        } except OSError as e {
            raise _lease_error(acquire_message, e);
        }
    } finally {
        _unlink_exact(candidate, "OpenMausBot could not remove its lease candidate.");
    }
}


def _successor_reaper_path(lease_path: str, target_token: str, reaper_token: str) -> str {
    digest = hashlib.sha256(reaper_token.encode()).hexdigest()[:32];
    return f"{lease_path}.reap-{target_token}-{digest}";
}


def _claim_reaper_authority(lease_path: str, expected: dict[str, any]) -> bool {
    # Elect exactly one live process to retire a particular dead owner.
    # A crashed reaper's successor is elected at a deterministic new path
    # derived from its token, so no contender can delete a newer replacement.
    reaper_path = f"{lease_path}.reap-{expected['token']}";
    for _generation in range(MAX_REAPER_GENERATIONS) {
        candidate = {
            "version": 1,
            "pid": os.getpid(),
            "host": socket.gethostname(),
            "token": str(uuid.uuid4()),
            "createdAt": int(time.time() * 1000),
            "boot": boot_session(),
            "uptime": uptime_ms(),
            "targetToken": expected["token"],
        };
        if _publish_record(
            reaper_path,
            candidate,
            "OpenMausBot could not prepare stale-lease recovery.",
            "OpenMausBot could not safely recover the stale data-directory lease."
        ) {
            return True;
        }
        current = _read_reaper(reaper_path, expected["token"]);
        if current is None {
            continue;
        }
        if not _same_machine(current) {
            raise _lease_error(
                "A stale OpenMausBot data-directory lease is being recovered on another machine. "
                f"Recovery record: {json.dumps(reaper_path)}."
            );
        }
        if _owner_is_alive(current) {
            return False;
        }
        reaper_path = _successor_reaper_path(lease_path, expected["token"], current["token"]);
    }
    raise _lease_error(
        "OpenMausBot could not recover the stale data-directory lease after repeated interrupted attempts."
    );
}


def _retire_dead_owner(lease_path: str, expected: dict[str, any]) -> bool {
    if not _claim_reaper_authority(lease_path, expected) {
        return False;
    }
    current = read_owner(lease_path);
    if current is None or current["token"] != expected["token"] {
        return True;
    }
    if not _same_machine(current) {
        raise _lease_error(
            "The stale OpenMausBot data-directory lease changed ownership to another machine. "
            f"Lease record: {json.dumps(lease_path)}."
        );
    }
    if _owner_is_alive(current) {
        return False;
    }
    _unlink_exact(lease_path, "OpenMausBot could not retire the stale data-directory lease.");
    return True;
}


def _prepare_data_dir(data_dir: str, legacy_data_dir: (str | None) = None) -> str {
    if not data_dir or re.search(r"[\r\n\0]", data_dir) {
        raise _lease_error("OpenMausBot cannot lease an invalid data directory.");
    }
    if legacy_data_dir is not None {
        if not legacy_data_dir or re.search(r"[\r\n\0]", legacy_data_dir) {
            raise _lease_error("OpenMausBot cannot lease an invalid data directory.");
        }
        # Preserve the pre-rename migration order: a one-time rename only
        # when the new dir does not yet exist.
        if not os.path.exists(data_dir) and os.path.exists(legacy_data_dir) {
            try {
                os.rename(legacy_data_dir, data_dir);
            } except OSError {
            }
        }
    }
    try {
        os.makedirs(data_dir, mode=0o700, exist_ok=True);
    } except OSError as e {
        raise _lease_error("OpenMausBot cannot create its data directory.", e);
    }
    return os.path.join(data_dir, LEASE_NAME);
}


obj DataDirLease {
    # Handle returned by acquire_data_dir_lease; release() unlinks only a
    # record this process still owns.
    has lease_path: str,
        owner: dict[str, any],
        released: bool = False;

    def owner_pid -> int {
        return self.owner["pid"];
    }

    def release -> bool {
        if self.released {
            return False;
        }
        current = read_owner(self.lease_path);
        if (
            current is None
            or current["pid"] != self.owner["pid"]
            or current["host"] != self.owner["host"]
            or current["token"] != self.owner["token"]
        ) {
            raise _lease_error(
                "OpenMausBot will not release a data-directory lease owned by another process."
            );
        }
        try {
            os.unlink(self.lease_path);
        } except OSError as e {
            raise _lease_error("OpenMausBot could not release its data-directory lease.", e);
        }
        self.released = True;
        return True;
    }
}


def acquire_data_dir_lease(data_dir: str) -> DataDirLease {
    lease_path = _prepare_data_dir(data_dir);
    owner = {
        "version": 1,
        "pid": os.getpid(),
        "host": socket.gethostname(),
        "token": str(uuid.uuid4()),
        "createdAt": int(time.time() * 1000),
        "boot": boot_session(),
        "uptime": uptime_ms(),
    };
    candidate_path = f"{lease_path}.candidate-{owner['pid']}-{owner['token']}";
    try {
        fd = os.open(candidate_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600);
        os.write(fd, (json.dumps(owner) + "\n").encode());
        os.fsync(fd);
        os.close(fd);
    } except OSError as e {
        raise _lease_error("OpenMausBot cannot prepare its data-directory lease.", e);
    }

    acquired = False;
    try {
        while True {
            try {
                os.link(candidate_path, lease_path);
                acquired = True;
                break;
            } except FileExistsError {
            } except OSError as e {
                raise _lease_error("OpenMausBot cannot acquire its data-directory lease.", e);
            }
            current = read_owner(lease_path);
            if current is None {
                continue;
            }
            if not _same_machine(current) {
                raise _lease_error(
                    "This OpenMausBot data directory is already owned by a process on another machine. "
                    f"Lease record: {json.dumps(lease_path)}.{_other_machine_advice(lease_path)}"
                );
            }
            if _owner_is_alive(current) {
                raise _lease_error(
                    f"OpenMausBot is already using this data directory (process {current['pid']}). "
                    "Close the other instance first. If no OpenMausBot is running, delete this "
                    f"lease record and start again: {json.dumps(lease_path)}."
                );
            }
            if not _retire_dead_owner(lease_path, current) {
                raise _lease_error(
                    "A stale OpenMausBot data-directory lease is already being recovered; try again shortly."
                );
            }
        }
    } finally {
        _unlink_exact(candidate_path, "OpenMausBot could not remove its lease candidate.");
    }
    if not acquired {
        raise _lease_error("OpenMausBot could not acquire its data-directory lease.");
    }
    return DataDirLease(lease_path=lease_path, owner=owner);
}
