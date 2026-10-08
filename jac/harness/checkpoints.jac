"""Per-turn workspace checkpoints: a shadow git repository per bot+folder.

Byte-faithful port of server/checkpoints.ts. Before a turn's engine can
touch files, the working folder is snapshotted into a shadow repo at
DATA_DIR/checkpoints/<botId>/<sha256(cwd)[..16]>/.git. When the turn
settles, its digest diffs the folder against that snapshot to list the
files the turn changed, added and deleted. The user's own .git (if the
folder is a repository) is never read, written, or locked: every git call
runs with GIT_DIR pointing at the shadow repo and GIT_WORK_TREE pointing
at the folder, so the shadow index is the only index involved — and git
always skips directories named .git when walking a work tree, so the
user's repository internals are invisible to the snapshot.

Ignored/excluded files (node_modules, .env, media) are never snapshotted.

Failure policy: checkpointing is best-effort convenience, never
load-bearing. Any git failure disables the feature for that bot for the
rest of the session and logs — nothing here ever throws into the turn
path. A git call that hits the timeout disables only that bot+folder, so
a slow folder costs one wait and one log line, not one wait per turn.

Synchronous port: the TS promise chain per shadow becomes a threading
lock (the harness calls these from worker threads; callers still see one
operation at a time per folder). A git child honours the hard timeout and
polls `signal` every 250 ms so a cancelled turn does not wait the full
GIT_TIMEOUT_S.
"""

import os;
import sys;
import re;
import time;
import stat;
import hashlib;
import threading;
import subprocess;
import unicodedata;
import pathlib;

import from db { DATA_DIR }

glob CHECKPOINTS_DIR: str = os.path.join(DATA_DIR, "checkpoints"),
    # Full sha1 hex only: accepting anything looser would let arbitrary
    # revspecs ("HEAD~3", "main@{u}") reach git.
    COMMIT_HASH: any = re.compile(r"[0-9a-f]{40}"),
    # gpgsign off: the user's global config may demand signing, and a
    # shadow commit must never block on a passphrase prompt. Automatic GC
    # stays off: explicit GC runs in the same per-folder queue as
    # snapshots and diffs, on the throttle below, after the objects it
    # drops are no longer needed.
    GITCONFIG: str = "[commit]\n\tgpgsign = false\n[core]\n\tautocrlf = false\n[gc]\n\tauto = 0\n",
    # Hard ceiling on one git call. A hung git (index lock, dead network
    # filesystem, cloud placeholders being downloaded) would otherwise
    # jam the per-repo queue for the whole session.
    GIT_TIMEOUT_S: float = 120.0,
    # The snapshot is awaited before every turn's dispatch, so GC does
    # not run on every snapshot: collect after this many HEAD-advancing
    # snapshots of one folder, or sooner when loose objects (git's own
    # gc.auto default) or new object data pile up. Counters are per
    # process and reset on restart.
    GC_EVERY_COMMITS: int = 25,
    GC_LOOSE_OBJECTS: int = 6700,
    GC_NEW_DATA_KIB: int = 262144,
    # A ref per running turn, see _live_ref.
    LIVE_REFS: str = "refs/omb-live/",
    # Folder listings in flight at once (the TS port reads them on
    # libuv's four-thread pool; here they are read sequentially, which
    # only makes the same reads slower, never different).
    LISTING_CONCURRENCY: int = 4,
    # One failed git call disables checkpoints for that bot until
    # restart — a broken shadow repo must cost the user one log line,
    # not a failed turn.
    _disabled_bots: any = set(),
    # Bot+folder pairs (keyed by shadow dir) switched off after a
    # timeout.
    _disabled_folders: any = set(),
    # Probed once: either the system has a usable git or checkpoints
    # stay off.
    _git_probe: any = None,
    _swept_shadows: any = set(),
    _dropped_pins: any = set(),
    # HEAD-advancing snapshots per shadow since this process last
    # collected.
    _commits_since_gc: dict[str, int] = {},
    # Pack size (KiB) first counted after the last collection — the
    # live snapshot. Packs also grow between collections: `git add`
    # streams files over core.bigFileThreshold straight into new packs.
    _pack_baseline_kib: dict[str, int] = {},
    # A collection the throttle asked for, held until that turn's
    # settled diff has been queued, or — when the turn settled without
    # one — until the next snapshot, which runs it first.
    _pending_collections: dict[str, any] = {},
    # One operation at a time per shadow repo: snapshots, diffs and pin
    # releases against the same folder queue behind each other (git's
    # index lock would fail the loser anyway — this turns a crash into
    # a wait).
    _chains: dict[str, any] = {},
    _chains_lock: any = threading.Lock();


# What a checkpoint deliberately does not carry, so a digest never lists
# these either. Categories follow Roo-Code's checkpoint excludes: VCS
# internals, dependency trees, build output, caches, logs, secrets,
# media, archives, databases, model weights.
glob EXCLUDES: str = """# OpenMausBot checkpoint excludes — never snapshotted
.git/
.svn/
.hg/
node_modules/
bower_components/
.pnpm-store/
.venv/
venv/
.direnv/
__pycache__/
.pytest_cache/
.mypy_cache/
.ruff_cache/
.tox/
.gradle/
Pods/
dist/
build/
out/
.next/
.nuxt/
.output/
.svelte-kit/
target/
coverage/
.cache/
.parcel-cache/
.turbo/
.vite/
.terraform/
*.log
logs/
*.tmp
*.swp
.DS_Store
Thumbs.db
*.env*
.env
.env.*
*.pem
*.key
*.jpg
*.jpeg
*.png
*.gif
*.bmp
*.tiff
*.webp
*.ico
*.icns
*.psd
*.mp3
*.wav
*.flac
*.ogg
*.mp4
*.mov
*.avi
*.mkv
*.webm
*.zip
*.tar
*.gz
*.tgz
*.bz2
*.xz
*.7z
*.rar
*.jar
*.iso
*.dmg
*.sqlite
*.sqlite3
*.db
*.parquet
*.onnx
*.safetensors
*.gguf
""";


class GitTimeoutError(Exception) {
    # A git call that hit GIT_TIMEOUT_S (not a cancellation). The folder
    # is too slow to snapshot — waiting that long again on every turn is
    # worse than having no checkpoint, so only that bot+folder is
    # switched off.
}


def _aborted(signal: any) -> bool {
    # Accepts anything AbortSignal-shaped (an `aborted` attribute or
    # method) plus threading.Event (`is_set`).
    if signal is None {
        return False;
    }
    flag = getattr(signal, "aborted", None);
    if flag is not None {
        return bool(flag() if callable(flag) else flag);
    }
    is_set = getattr(signal, "is_set", None);
    if is_set is not None {
        return bool(is_set());
    }
    return False;
}


def _warn(message: str) -> None {
    # console.warn writes to stderr.
    print(message, file=sys.stderr);
}


def _disable(bot_id: str, message: str) -> None {
    _disabled_bots.add(bot_id);
    _warn(f"workspace checkpoints disabled for bot {bot_id} this session: {message}");
}


def _disable_folder(shadow: str, bot_id: str, worktree: str, message: str) -> None {
    if shadow in _disabled_folders {
        return;
    }
    _disabled_folders.add(shadow);
    _warn(
        f"workspace checkpoints disabled for bot {bot_id} in {worktree} this session: {message}"
    );
}


def _shadow_dir(bot_id: str, cwd: str) -> str {
    key = hashlib.sha256(os.path.abspath(cwd).encode("utf-8")).hexdigest()[0:16];
    return os.path.join(CHECKPOINTS_DIR, bot_id, key);
}


def _folder_shadow(bot_id: str, cwd: str) -> (dict[str, str] | None) {
    # The shadow dir doubles as the bot+folder key. None when the folder
    # cannot be resolved (the refusal check reports that case).
    try {
        worktree = str(pathlib.Path(os.path.abspath(cwd)).resolve(strict=True));
        return {"worktree": worktree, "shadow": _shadow_dir(bot_id, worktree)};
    } except Exception {
        return None;
    }
}


def _git_available -> bool {
    if _git_probe is not None {
        return _git_probe;
    }
    ok = False;
    try {
        out = subprocess.run(
            ["git", "--version"], capture_output=True, timeout=5
        );
        ok = out.returncode == 0;
    } except Exception {
        ok = False;
    }
    globals()["_git_probe"] = ok;
    return ok;
}


def refusal_reason(cwd: str) -> (str | None) {
    # Folders a checkpoint must never be taken in: missing paths, the
    # sprawling personal folders (home, Desktop, Documents, Downloads),
    # and the filesystem root — snapshotting those would trawl unbounded
    # personal data into a repo.
    if not os.path.isabs(cwd) {
        return "the working folder must be an absolute path";
    }
    requested = os.path.abspath(cwd);
    try {
        st = os.stat(requested);
        dir_ = str(pathlib.Path(requested).resolve(strict=True));
    } except Exception {
        return "the working folder does not exist";
    }
    if not stat.S_ISDIR(st.st_mode) {
        return "the working folder is not a folder";
    }
    # Compare canonical paths too: otherwise /tmp/home-link -> $HOME
    # bypasses the refusal while git still follows the symlink into the
    # protected tree. The realpath also settles Windows' spellings of
    # one folder — c:\users\me, C:\Users\me\DOCUME~1 — and names compare
    # case-insensitively there.
    def same(a: str, b: str) -> bool {
        if sys.platform == "win32" {
            return a.lower() == b.lower();
        }
        return a == b;
    }
    fs_root = os.path.splitdrive(dir_)[0] + os.path.sep;
    if dir_ == fs_root {
        return "checkpoints are not taken at the filesystem root";
    }
    requested_home = os.path.abspath(os.path.expanduser("~"));
    home = requested_home;
    if os.path.exists(requested_home) {
        home = str(pathlib.Path(requested_home).resolve(strict=True));
    }
    if same(requested, requested_home) or same(dir_, home) {
        return "checkpoints are not taken in the home folder";
    }
    for name in ["Desktop", "Documents", "Downloads"] {
        requested_protected = os.path.join(requested_home, name);
        protected_dir = requested_protected;
        if os.path.exists(requested_protected) {
            protected_dir = str(pathlib.Path(requested_protected).resolve(strict=True));
        }
        if same(requested, requested_protected) or same(dir_, protected_dir) {
            return f"checkpoints are not taken in the {name} folder";
        }
    }
    return None;
}


def _git_env(shadow: str, cwd: str) -> dict[str, any] {
    env = dict(os.environ);
    # Git has several redirection/config environment variables beyond
    # the common GIT_DIR set (for example GIT_COMMON_DIR and
    # GIT_CONFIG_KEY_*). None are needed by a local shadow repo, so
    # clear the complete namespace before installing the small, explicit
    # environment below.
    for name in list(env.keys()) {
        if name.startswith("GIT_") {
            del env[name];
        }
    }
    env["GIT_DIR"] = os.path.join(shadow, ".git");
    env["GIT_WORK_TREE"] = os.path.abspath(cwd);
    env["GIT_CONFIG_GLOBAL"] = os.path.join(shadow, "gitconfig");
    env["GIT_CONFIG_SYSTEM"] = os.path.join(shadow, "gitconfig_empty");
    env["GIT_AUTHOR_NAME"] = "OpenMausBot Checkpoint";
    env["GIT_AUTHOR_EMAIL"] = "checkpoint@openmausbot.local";
    env["GIT_COMMITTER_NAME"] = "OpenMausBot Checkpoint";
    env["GIT_COMMITTER_EMAIL"] = "checkpoint@openmausbot.local";
    return env;
}


def _decode_text(data: any) -> str {
    if isinstance(data, bytes) {
        return data.decode("utf-8", errors="replace");
    }
    if isinstance(data, str) {
        return data;
    }
    return "";
}


def _git_failure(command: str, err: any, stderr: str, signal: any = None) -> Exception {
    # subprocess reports a timeout as TimeoutExpired; a cancellation via
    # `signal` raises before the child reports and is not a timeout.
    if isinstance(err, subprocess.TimeoutExpired) and not _aborted(signal) {
        return GitTimeoutError(
            f"git {command} timed out after {int(GIT_TIMEOUT_S)} s"
        );
    }
    detail = stderr if stderr else str(err);
    return RuntimeError(f"git {command}: {detail.strip()[0:400]}");
}


def _exec_git(
    args: list[str], cwd: str, env: dict[str, any], signal: any = None
) -> tuple[int, str, str] {
    # Spawn one git command against the shadow repo. cwd is the WORK
    # TREE — the "." pathspec in add resolves relative to it. Every call
    # carries the GIT_TIMEOUT_S hard timeout and is polled for
    # cancellation every 250 ms. Returns (exit code, stdout, stderr).
    if _aborted(signal) {
        raise RuntimeError("This operation was aborted");
    }
    proc = subprocess.Popen(
        ["git"] + args,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    );
    deadline = time.monotonic() + GIT_TIMEOUT_S;
    out = b"";
    err = b"";
    while True {
        if _aborted(signal) {
            proc.kill();
            proc.communicate();
            raise RuntimeError("This operation was aborted");
        }
        remaining = deadline - time.monotonic();
        if remaining <= 0 {
            proc.kill();
            pair = proc.communicate();
            raise _git_failure(
                args[0],
                subprocess.TimeoutExpired(["git"] + args, GIT_TIMEOUT_S),
                _decode_text(pair[1]),
                signal
            );
        }
        try {
            pair = proc.communicate(
                timeout=(remaining if remaining < 0.25 else 0.25)
            );
            out = pair[0];
            err = pair[1];
            break;
        } except subprocess.TimeoutExpired {
        }
    }
    return (proc.returncode, _decode_text(out), _decode_text(err));
}


def _run_git(
    args: list[str], cwd: str, env: dict[str, any], signal: any = None
) -> str {
    res = _exec_git(args, cwd, env, signal);
    if res[0] != 0 {
        detail = "Command failed: git " + " ".join(args);
        raise _git_failure(args[0], RuntimeError(detail), res[2], signal);
    }
    return res[1];
}


def _has_staged_changes(cwd: str, env: dict[str, any], signal: any = None) -> bool {
    # `git diff --cached --quiet`: is there anything staged beyond HEAD?
    # Used instead of `status --porcelain` emptiness on purpose — a
    # nested repo with a dirty work tree shows up in status forever
    # while staging nothing, which would either commit empty churn every
    # turn or fail the commit outright.
    res = _exec_git(
        ["diff", "--cached", "--quiet", "--ignore-submodules=dirty"], cwd, env, signal
    );
    if res[0] == 0 {
        return False;
    }
    if res[0] == 1 {
        return True;
    }
    raise _git_failure(
        "diff",
        RuntimeError("Command failed: git diff --cached --quiet --ignore-submodules=dirty"),
        res[2],
        signal
    );
}


def _serialized(key: str, fn: any) -> any {
    # One operation at a time per shadow repo. The TS module stores a
    # non-rejecting promise tail so one failed operation cannot poison
    # the queue; a threading lock gives the same wait-instead-of-crash.
    _chains_lock.acquire();
    try {
        lock: any = _chains.get(key);
        if lock is None {
            lock = threading.Lock();
            _chains[key] = lock;
        }
    } finally {
        _chains_lock.release();
    }
    lock.acquire();
    try {
        return fn();
    } finally {
        lock.release();
    }
}


def _live_ref(pin: str) -> str {
    # A ref per running turn. Every snapshot parents only the empty base
    # and a collection prunes whatever HEAD no longer reaches — so when
    # a bot's threads work side by side in one folder, a collection
    # after a sibling's snapshot would discard the pre-turn commit a
    # still-running turn diffs against at its end. A pin keeps that
    # commit reachable until release(). The pin's name is hashed so any
    # token is a legal ref name.
    return LIVE_REFS + hashlib.sha256(pin.encode("utf-8")).hexdigest()[0:16];
}


def _sweep_live_refs(cwd: str, env: dict[str, any], shadow: str, signal: any = None) -> None {
    # Pins outlive the process that wrote them (a crash mid-turn), so
    # the first use of each shadow in this process drops every pin left
    # behind: no turn of ours can be live in a shadow this process has
    # not touched yet. Dropping one makes the next snapshot's collection
    # due (see _collection_due).
    if shadow in _swept_shadows {
        return;
    }
    stale = [
        ref
        for ref in _run_git(
            ["for-each-ref", "--format=%(refname)", LIVE_REFS], cwd, env, signal
        ).split("\n")
        if ref
    ];
    for ref in stale {
        _run_git(["update-ref", "-d", ref], cwd, env, signal);
    }
    if len(stale) > 0 {
        _dropped_pins.add(shadow);
    }
    _swept_shadows.add(shadow);
}


def _mkdir_p(path: str, mode: int = 0o777) -> None {
    # mkdirSync(recursive, mode) applies mode to every component it
    # creates; os.makedirs applies it to the leaf only. Mirror node.
    if os.path.isdir(path) {
        return;
    }
    parent = os.path.dirname(path);
    if parent and parent != path and not os.path.isdir(parent) {
        _mkdir_p(parent, mode);
    }
    try {
        os.mkdir(path, mode);
    } except FileExistsError as e {
        if not os.path.isdir(path) {
            # mkdir lost the race against a file: surface a real error.
            raise e;
        }
    }
}


def _write_file(path: str, text: str, mode: int = 0o666) -> None {
    # writeFileSync(path, text, { mode }): utf-8, create-or-truncate;
    # mode applies only when the file is created.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode);
    data = text.encode("utf-8");
    try {
        while len(data) > 0 {
            written = os.write(fd, data);
            data = data[written:];
        }
    } finally {
        os.close(fd);
    }
}


def _escape_exclude(directory: str) -> str {
    # .git/info/exclude glob escaping, as in the TS regex
    # /[\\*?[\]#! ]/g -> "\\$&".
    out: list[str] = [];
    for ch in directory {
        if ch in "\\*?[]#! " {
            out.append("\\");
        }
        out.append(ch);
    }
    return "".join(out);
}


def _ensure_shadow(cwd: str, env: dict[str, any], shadow: str, signal: any = None) -> None {
    # Create the shadow repo on first use; self-heal its config files on
    # every use (they are tiny, and rewriting them lets exclude-list
    # updates reach shadows that already exist). The base commit is an
    # EMPTY marker so HEAD always resolves; every snapshot parents only
    # it.
    if _aborted(signal) {
        raise RuntimeError("This operation was aborted");
    }
    _mkdir_p(shadow, 0o700);
    _write_file(os.path.join(shadow, "gitconfig"), GITCONFIG, 0o600);
    _write_file(os.path.join(shadow, "gitconfig_empty"), "", 0o600);
    if not os.path.exists(os.path.join(shadow, ".git", "HEAD")) {
        # --template= keeps the user's init.templateDir hooks/config out
        _run_git(["init", "--initial-branch=main", "--template="], cwd, env, signal);
    }
    _mkdir_p(os.path.join(shadow, ".git", "info"));
    _write_file(os.path.join(shadow, ".git", "info", "exclude"), EXCLUDES);
    # Cargo and other tools can put caches outside conventional target/
    # or build/ paths. Honor the standard tag even for previously
    # indexed caches.
    tags = _run_git(
        [
            "ls-files", "--cached", "--others", "--exclude-standard",
            "-z", "--", "**/CACHEDIR.TAG"
        ],
        cwd, env, signal
    ).split("\x00");
    cache_patterns: list[str] = [];
    for tag in tags {
        if "/" not in tag or re.search(r"[\r\n]", tag) {
            continue;
        }
        try {
            path = os.path.join(cwd, tag);
            st = os.lstat(path);
            if not stat.S_ISREG(st.st_mode) or st.st_size > 4096 {
                continue;
            }
            with open(path, "r", encoding="utf-8", errors="replace") as f {
                head = f.read();
            }
            if not head.startswith("Signature: 8a477f597d28d172789f06886806bc55") {
                continue;
            }
            directory = tag[0:len(tag) - len("CACHEDIR.TAG")];
            pattern = "/" + _escape_exclude(directory);
            if pattern not in cache_patterns {
                cache_patterns.append(pattern);
            }
        } except Exception {
            # A disappearing/unreadable tag is not evidence that a path
            # is a cache.
        }
    }
    _write_file(
        os.path.join(shadow, ".git", "info", "exclude"),
        EXCLUDES + "\n".join(cache_patterns) + "\n"
    );
    try {
        _run_git(["rev-parse", "--verify", "HEAD"], cwd, env, signal);
    } except Exception {
        # brand-new repo (or a crash between init and first commit)
        _run_git(
            ["commit", "--no-verify", "--allow-empty", "-m", "checkpoint base"],
            cwd, env, signal
        );
    }
    _sweep_live_refs(cwd, env, shadow, signal);
}


def _case_renamed(cwd: str, paths: list[str]) -> bool {
    # Case-insensitive file systems only (APFS/HFS+ as macOS formats
    # them, NTFS): does a staged path, or one of its folders, now exist
    # on disk under a different case? git init sets core.ignorecase
    # there, so an incremental `add -A` matches `R0` to the staged `r0`
    # and keeps the old spelling forever. Reads folder listings only —
    # never file contents. Names compare in NFC: git stores precomposed
    # paths on macOS, readdir returns names as they were created.
    if len(paths) == 0 {
        return False;
    }
    pending = set([""]);
    for path in paths {
        slash = path.find("/");
        while slash > 0 {
            pending.add(path[0:slash]);
            slash = path.find("/", slash + 1);
        }
    }
    listings: dict[str, any] = {};
    for dir_ in pending {
        try {
            exact = set(
                [
                    unicodedata.normalize("NFC", name)
                    for name in os.listdir(os.path.join(cwd, dir_))
                ]
            );
            listings[dir_] = {
                "exact": exact,
                "folded": set([name.lower() for name in exact])
            };
        } except Exception {
            # gone or unreadable: add -A handles deletions itself
            listings[dir_] = None;
        }
    }
    folders: dict[str, bool] = {};
    def renamed(path: str, is_folder: bool) -> bool {
        if is_folder and path in folders {
            return folders[path];
        }
        slash = path.rfind("/");
        parent = "" if slash < 0 else path[0:slash];
        name = unicodedata.normalize("NFC", path[slash + 1:]);
        names = listings.get(parent);
        verdict = False;
        if names is None {
            verdict = False;
        } elif name not in names["exact"] {
            # else simply deleted
            verdict = name.lower() in names["folded"];
        } else {
            verdict = parent != "" and renamed(parent, True);
        }
        if is_folder {
            folders[path] = verdict;
        }
        return verdict;
    }
    for path in paths {
        if renamed(path, False) {
            return True;
        }
    }
    return False;
}


def _index_needs_rebuild(cwd: str, env: dict[str, any], signal: any = None) -> bool {
    # Would an incremental `git add -A` leave the shadow index different
    # from one rebuilt from empty? Only in four cases, all detected
    # here: a tracked path is now ignored or inside a cache-tagged
    # directory (add -A never drops tracked files), a folder holding
    # tracked files became a nested repository (add -A keeps the files
    # instead of a gitlink), a recorded nested repository lost its .git
    # (add -A keeps the stale gitlink), or — on a case-insensitive file
    # system — a tracked path was renamed by case only (add -A keeps
    # the old spelling).
    # If the index cannot be inspected (say, a listing past the pipe
    # buffer on a huge folder), rebuild: that is always correct, just
    # slower.
    def list_cmd(args: list[str]) -> (str | None) {
        try {
            return _run_git(args, cwd, env, signal);
        } except GitTimeoutError {
            raise;
        } except Exception {
            if _aborted(signal) {
                raise;
            }
            return None;
        }
    }
    ignored = list_cmd(
        ["ls-files", "--cached", "--ignored", "--exclude-standard", "-z"]
    );
    if ignored is None or len(ignored) > 0 {
        return True;
    }
    staged = list_cmd(["ls-files", "--stage", "-z"]);
    if staged is None {
        return True;
    }
    paths: list[str] = [];
    parents = set();
    for item in staged.split("\x00") {
        tab = item.find("\t");
        if tab < 0 {
            continue;
        }
        path = item[tab + 1:];
        paths.append(path);
        if item.startswith("160000 ") {
            if not os.path.exists(os.path.join(cwd, path, ".git")) {
                return True;
            }
            continue;
        }
        slash = path.find("/");
        while slash > 0 {
            parents.add(path[0:slash]);
            slash = path.find("/", slash + 1);
        }
    }
    for dir_ in parents {
        if os.path.exists(os.path.join(cwd, dir_, ".git")) {
            return True;
        }
    }
    return (
        (sys.platform == "darwin" or sys.platform == "win32")
        and _case_renamed(cwd, paths)
    );
}


def _stage_work_tree(cwd: str, env: dict[str, any], signal: any = None) -> None {
    # Stage the work tree into the shadow index. The index persists
    # between snapshots so `git add -A` only re-reads files whose stat
    # data changed; rebuilding it from empty re-reads and re-hashes
    # every file (and downloads every cloud placeholder). It is rebuilt
    # only when _index_needs_rebuild says an incremental add would
    # differ, so the staged content always matches a from-empty rebuild.
    # Only the shadow index changes; no user index or work-tree file
    # does.
    if _index_needs_rebuild(cwd, env, signal) {
        _run_git(["read-tree", "--empty"], cwd, env, signal);
    }
    _run_git(["add", "-A", "--ignore-errors", "."], cwd, env, signal);
}


def _commit_all(
    cwd: str, env: dict[str, any], label: str, signal: any = None
) -> (dict[str, any] | None) {
    # Capture fully before advancing HEAD: None when the add was
    # partial, so a partial capture never replaces the last usable
    # checkpoint or authorizes removal of its objects.
    # `advanced`: HEAD moved to a new commit. `compacted`: that move
    # also dropped legacy multi-commit history.
    previous = _run_git(["rev-parse", "HEAD"], cwd, env, signal).strip();
    try {
        _stage_work_tree(cwd, env, signal);
    } except GitTimeoutError {
        # A timeout is not an unreadable file: the caller switches the
        # folder off.
        raise;
    } except Exception {
        return None;
    }
    changed = _has_staged_changes(cwd, env, signal);
    base = _run_git(["rev-list", "--max-parents=0", "HEAD"], cwd, env, signal).strip();
    count = _run_git(["rev-list", "--count", "HEAD"], cwd, env, signal).strip();
    if not changed and int(count) <= 2 {
        return {"hash": previous, "advanced": False, "compacted": False};
    }
    tree = _run_git(["write-tree"], cwd, env, signal).strip();
    message = label;
    if not changed {
        message = _run_git(
            ["show", "-s", "--format=%B", "HEAD"], cwd, env, signal
        ).strip();
    }
    # Parent only the empty marker, never the previous snapshot: keeping
    # the previous commit as an ancestor would retain every old tree
    # indefinitely.
    commit_hash = _run_git(
        ["commit-tree", tree, "-p", base, "-m", message], cwd, env, signal
    ).strip();
    _run_git(["update-ref", "HEAD", commit_hash, previous], cwd, env, signal);
    return {"hash": commit_hash, "advanced": True, "compacted": int(count) > 2};
}


def _release_collection(shadow: str) -> None {
    # Run the folder's pending collection behind whatever was just
    # queued for it (the caller holds no lock; _serialized queues it).
    collect = _pending_collections.pop(shadow, None);
    if collect is None {
        return;
    }
    _serialized(shadow, collect);
}


def _collection_due(
    shadow: str, result: dict[str, any], cwd: str, env: dict[str, any], signal: any = None
) -> bool {
    # Throttle for _collect_obsolete (see GC_EVERY_COMMITS).
    # A compaction or a swept leftover pin frees a whole tree at once:
    # reclaim it now.
    freed = shadow in _dropped_pins;
    _dropped_pins.discard(shadow);
    freed = freed or result["compacted"];
    if not result["advanced"] and not freed {
        return False;
    }
    commits = _commits_since_gc.get(shadow, 0) + (1 if result["advanced"] else 0);
    _commits_since_gc[shadow] = commits;
    due = freed or commits >= GC_EVERY_COMMITS;
    if not due {
        # Advisory only: a failed count must not cost the snapshot just
        # taken.
        counted = "";
        try {
            counted = _run_git(["count-objects", "-v"], cwd, env, signal);
        } except Exception {
            counted = "";
        }
        if counted != "" {
            def field(name: str) -> int {
                m = re.search(r"^" + name + r": (\d+)$", counted, re.MULTILINE);
                return int(m.group(1)) if m else 0;
            }
            pack = field("size-pack");
            if shadow not in _pack_baseline_kib {
                _pack_baseline_kib[shadow] = pack;
            }
            # Every loose object is new since the last collection (gc
            # packs or prunes them all). Only pack growth counts, so a
            # folder whose live snapshot alone passes the ceiling does
            # not collect every turn.
            new_data = field("size") + max(0, pack - _pack_baseline_kib.get(shadow, 0));
            due = field("count") >= GC_LOOSE_OBJECTS or new_data >= GC_NEW_DATA_KIB;
        }
    }
    if due {
        _commits_since_gc[shadow] = 0;
        _pack_baseline_kib.pop(shadow, None);
    }
    return due;
}


def _collect_obsolete(cwd: str, env: dict[str, any]) -> None {
    # No caller may still need an unpinned previous tree: HEAD stays
    # reachable, and so does every commit a live turn still pins.
    try {
        _run_git(["reflog", "expire", "--expire=now", "--all"], cwd, env);
        _run_git(["gc", "--prune=now", "--quiet"], cwd, env);
    } except Exception {
        # A busy/full disk must not hide an otherwise usable snapshot.
        _warn("checkpoint cleanup deferred; the latest snapshot is preserved");
    }
}


def snapshot(
    bot_id: str,
    cwd: str,
    label: str,
    signal: any = None,
    pin: (str | None) = None
) -> (str | None) {
    # Snapshot the folder. Returns the checkpoint hash, or None when the
    # feature is off for this bot or folder, git is missing, the folder
    # is refused, or a file could not be read. With `pin`, the returned
    # commit stays reachable through later snapshots of the same folder
    # until release(pin) — for a turn that will diff against it when it
    # ends. Never throws — this is called fire-and-forget on the turn
    # path.
    if _aborted(signal) {
        return None;
    }
    if bot_id in _disabled_bots {
        return None;
    }
    if not _git_available() {
        return None;
    }
    if refusal_reason(cwd) is not None {
        return None;
    }
    folder = _folder_shadow(bot_id, cwd);
    if folder is None or folder["shadow"] in _disabled_folders {
        return None;
    }
    worktree = folder["worktree"];
    shadow = folder["shadow"];
    def work -> (str | None) {
        env = _git_env(shadow, worktree);
        _ensure_shadow(worktree, env, shadow, signal);
        result = _commit_all(worktree, env, label, signal);
        if result is None {
            return None;
        }
        if pin {
            _run_git(
                ["update-ref", _live_ref(pin), result["hash"]],
                worktree, env, signal
            );
        }
        # Never awaited by the turn waiting on this snapshot, and held
        # for that turn's settled diff: diff_working_tree queues it
        # behind itself, so GC never eats into the digest's capture
        # window.
        if _collection_due(shadow, result, worktree, env, signal) {
            def collect -> None {
                _collect_obsolete(worktree, env);
            }
            _pending_collections[shadow] = collect;
        }
        return result["hash"];
    }
    try {
        # Still pending from the previous snapshot: that turn settled
        # without a diff. Collect ahead of this snapshot, not behind it,
        # so this turn's own diff never queues behind GC and the object
        # counts below see the collected repo (a stale count would make
        # GC due again at once).
        _release_collection(shadow);
        return _serialized(shadow, work);
    } except GitTimeoutError as e {
        if _aborted(signal) {
            return None;
        }
        _disable_folder(shadow, bot_id, worktree, str(e));
        return None;
    } except Exception as e {
        if _aborted(signal) {
            return None;
        }
        _disable(bot_id, str(e));
        return None;
    }
}


def release(bot_id: str, cwd: str, pin: str) -> None {
    # Let go of a pinned pre-turn commit: the next collection may
    # reclaim it. Queued behind the shadow's pending operations, so a
    # digest's diff already in that queue still finds its commit.
    # Best-effort like the rest of this module — a pin that cannot be
    # dropped costs one log line and is swept on the next start.
    if not _git_available() {
        return;
    }
    try {
        worktree = str(pathlib.Path(os.path.abspath(cwd)).resolve(strict=True));
        shadow = _shadow_dir(bot_id, worktree);
        if not os.path.exists(os.path.join(shadow, ".git", "HEAD")) {
            return;
        }
        env = _git_env(shadow, worktree);
        def op -> str {
            return _run_git(["update-ref", "-d", _live_ref(pin)], worktree, env);
        }
        _serialized(shadow, op);
    } except Exception as e {
        _warn(f"checkpoint pin not released for bot {bot_id}: {e}");
    }
}


def diff_working_tree(
    bot_id: str, cwd: str, from_hash: any, signal: any = None
) -> (dict[str, any] | None) {
    # Diff the settled workspace without replacing its pre-turn
    # snapshot. Staging is confined to the shadow index; the user's
    # files and Git are untouched. Returns
    # {"changed": [...], "added": [...], "deleted": [...]} or None.
    if (
        _aborted(signal)
        or not isinstance(from_hash, str)
        or not COMMIT_HASH.fullmatch(from_hash)
    ) {
        return None;
    }
    if (
        bot_id in _disabled_bots
        or not _git_available()
        or refusal_reason(cwd) is not None
    ) {
        return None;
    }
    folder = _folder_shadow(bot_id, cwd);
    if folder is None or folder["shadow"] in _disabled_folders {
        return None;
    }
    worktree = folder["worktree"];
    shadow = folder["shadow"];
    try {
        env = _git_env(shadow, worktree);
        def run -> dict[str, any] {
            _ensure_shadow(worktree, env, shadow, signal);
            _stage_work_tree(worktree, env, signal);
            out = _run_git(
                [
                    "diff", "--cached", "--name-status", "--no-renames",
                    "-z", from_hash
                ],
                worktree, env, signal
            );
            diff: dict[str, any] = {"changed": [], "added": [], "deleted": []};
            fields = [f for f in out.split("\x00") if len(f) > 0];
            i = 0;
            while i + 1 < len(fields) {
                status = fields[i];
                path = fields[i + 1];
                if status.startswith("A") {
                    diff["added"].append(path);
                } elif status.startswith("D") {
                    diff["deleted"].append(path);
                } else {
                    diff["changed"].append(path);
                }
                i += 2;
            }
            return diff;
        }
        # The collection this turn's snapshot left pending runs behind
        # this diff, never ahead of it — queued whether the diff
        # succeeds or fails, as in the TS module's non-rejecting chain.
        diff = None;
        try {
            diff = _serialized(shadow, run);
        } finally {
            _release_collection(shadow);
        }
        return diff;
    } except GitTimeoutError as e {
        if not _aborted(signal) {
            _disable_folder(shadow, bot_id, worktree, str(e));
        }
        return None;
    } except Exception {
        return None;
    }
}
