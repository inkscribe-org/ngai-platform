"""The memory markdown layer — byte-faithful port of:

  - server/memory-store.ts   : person-facing doc access under
                               DATA_DIR/workspaces/<botId> (parse/resolve/
                               read/write/delete + overview, atomic 0600
                               writes with expectedHash CAS)
  - server/memory-entries.ts : the dated-entry grammar of MEMORY.md
                               (parse, expiry, fact identity/dedupe)
  - server/memory-topics.ts  : topic-file YAML frontmatter, topic words,
                               topic-index rendering, mergeTopicText

plus the workspace plumbing they depend on (workspace.ts's memory file
operations: ensure_workspace, topic/log lists, the load budget, the FTS
sync) and the two shared helpers server/atomic.ts + shared/redact.ts.

The FTS index itself lives in messages.jac (memory_files/memory_fts) —
this module calls index_memory_file / remove_memory_file /
indexed_memory_files / recall_memory; it does not duplicate them.

Byte-parity notes:

  - JS RegExp semantics are preserved: \\d/\\w/\\b are compiled ASCII
    (JS \\w is ASCII-only even in /u); JS \\s is an explicit char class
    (_S) because Python's \\s adds \x1c-\x1f and \x85; JS '.' excludes
    \\r\\u2028\\u2029 (_DOT).
  - JS string ops use JS rules: _js_trim (JS WhiteSpace+FEFF, which is a
    different set than Python's strip), _js_len (UTF-16 code units).
  - topic file names use \\p{L}\\p{N} — implemented via unicodedata
    category, which is what both JS and Python mean by letter/number.
  - Reads decode UTF-8 with errors="replace", matching Node's
    readFileSync("utf8") substitution char behaviour; binary mode so
    \\r\\n bytes reach the parser unchanged.
"""

import os;
import re;
import sys;
import time;
import uuid;
import errno;
import hashlib;
import stat;
import datetime;
import functools;
import subprocess;
import unicodedata;
import urllib.parse;

import from jsutil { js_stringify }
import from db { DATA_DIR }
# shared/redact.ts and server/atomic.ts (re-exported under their port names).
import from common {
    redact_mask as mask,
    redact_secrets_in_text,
    rename_with_retry,
    write_file_atomic,
}
import from messages {
    index_memory_file, remove_memory_file, indexed_memory_files,
    recall_memory
}

# ── JS text semantics ─────────────────────────────────────────────────
# JS WhiteSpace + FEFF — what String.prototype.trim strips and /\s/
# matches. Python's \s is broader (\x1c-\x1f, \x85) so the regexes that
# must be byte-identical are built from this class.
glob _WS_CHARS: str = " \t\n\v\f\r\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff",
    _S: str = "[ \t\n\v\f\r\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]",
    # JS '.' without /s: everything except \n \r \u2028 \u2029.
    _DOT: str = "[^\n\r\u2028\u2029]";


def _js_trim(text: str) -> str {
    return text.strip(_WS_CHARS);
}


def _js_len(text: str) -> int {
    # JS .length counts UTF-16 code units: non-BMP chars count 2.
    n = 0;
    for ch in text {
        if ord(ch) > 0xFFFF {
            n += 2;
        } else {
            n += 1;
        }
    }
    return n;
}


def _is_ln(ch: str) -> bool {
    # \p{L} or \p{N} — Unicode general category L* or N*.
    return unicodedata.category(ch)[0:1] in ("L", "N");
}


def _locale_compare(a: str, b: str) -> int {
    # Approximation of JS localeCompare for the names that pass the topic
    # gate: case-insensitive first, then code points. (ICU's tertiary
    # pass puts lowercase before uppercase, which swapcase() emulates.)
    ka = a.casefold();
    kb = b.casefold();
    if ka != kb {
        return -1 if ka < kb else 1;
    }
    sa = a.swapcase();
    sb = b.swapcase();
    if sa != sb {
        return -1 if sa < sb else 1;
    }
    return 0;
}


def _read_utf8(path: str) -> str {
    # readFileSync(path, "utf8"): raw bytes (no newline translation),
    # malformed sequences replaced by U+FFFD.
    f = open(path, "rb");
    try {
        return f.read().decode("utf-8", errors="replace");
    } finally {
        f.close();
    }
}


def _mkdir_p_mode(dir_: str, mode: int) -> None {
    # mkdirSync(dir, {recursive: true, mode}) applies `mode` to every
    # directory it creates; os.makedirs only modes the leaf.
    missing: list[any] = [];
    cur = dir_;
    while not os.path.exists(cur) {
        missing.append(cur);
        parent = os.path.dirname(cur);
        if parent == cur {
            break;
        }
        cur = parent;
    }
    for d in reversed(missing) {
        os.mkdir(d, mode);
    }
    if not os.path.isdir(dir_) {
        raise NotADirectoryError(errno.ENOTDIR, f"not a directory: {dir_}");
    }
}


# ── workspace.ts memory plumbing ──────────────────────────────────────
glob WORKSPACES_DIR: str = os.path.join(DATA_DIR, "workspaces"),
    MEMORY_INDEX: str = "MEMORY.md",
    # The load budget: only this much of MEMORY.md rides into the prompt.
    MEMORY_MAX_LINES: int = 200,
    MEMORY_MAX_BYTES: int = 24000,
    # Cap on what the memory API will write to one file.
    MEMORY_FILE_MAX_BYTES: int = 256 * 1024,
    ARCHIVE_TOPIC: str = "archive.md",
    MEMORY_LOG_DIR: str = "log",
    # On an OMB Cloud home, memory is read only from regular files.
    _regular_memory_files_only: bool = False,
    _memory_index_dates: dict[str, str] = {},
    _LOG_FILE_NAME: any = re.compile(r"^\d{4}-\d{2}-\d{2}\.md$", re.ASCII);


glob MEMORY_SEED: str = (
    f"# Memory\n\n"
    f"Durable notes this bot keeps between tasks. The first {MEMORY_MAX_LINES} lines\n"
    "load at the start of every session — keep this file short and curated.\n"
    "Longer notes belong in memory/<topic>.md files, read on demand.\n"
);


def workspace_dir(bot_id: str) -> str {
    return os.path.join(WORKSPACES_DIR, bot_id);
}


def read_memory_only_from_regular_files -> None {
    # Jac has no `global`: a def-local assignment only shadows. Rebind
    # through globals() so the module flag actually flips.
    globals()["_regular_memory_files_only"] = True;
}


def ensure_workspace(bot_id: str) -> str {
    dir_ = workspace_dir(bot_id);
    # Memories can contain personal details: owner-only directories.
    _mkdir_p_mode(os.path.join(dir_, "memory"), 0o700);
    memory_file = os.path.join(dir_, "MEMORY.md");
    if not os.path.exists(memory_file) {
        write_file_atomic(memory_file, MEMORY_SEED, 0o600);
    }
    return dir_;
}


def is_memory_topic_name(name: any) -> bool {
    # /^[\p{L}\p{N}_][\p{L}\p{N}_ .-]{0,199}\.md$/u — one path segment,
    # no separators, no leading dot, ends in .md.
    if not isinstance(name, str) or len(name) < 4 or len(name) > 203 or not name.endswith(".md") {
        return False;
    }
    first = name[0];
    if not (_is_ln(first) or first == "_") {
        return False;
    }
    for ch in name[1:-3] {
        if not (_is_ln(ch) or ch in "_ .-") {
            return False;
        }
    }
    return True;
}


def memory_date(now: any = None) -> str {
    # The calendar day in the machine's own zone.
    if now is None {
        now = datetime.datetime.now();
    }
    return f"{now.year}-{now.month:02d}-{now.day:02d}";
}


def memory_line_count(text: str) -> int {
    # Lines as a person counts them: a trailing newline does not make
    # an extra empty line.
    if not text {
        return 0;
    }
    return len(re.sub(r"\n$", "", text).split("\n"));
}


def memory_over_budget(text: str) -> bool {
    return memory_line_count(text) > MEMORY_MAX_LINES or len(text.encode("utf-8")) > MEMORY_MAX_BYTES;
}


def read_memory_text(path: str) -> str {
    # Throws like readFileSync when it cannot be read; on a Cloud home,
    # also when the path is not a regular file (a link is refused at
    # open via O_NOFOLLOW where the platform has one).
    if not _regular_memory_files_only {
        return _read_utf8(path);
    }
    if not stat.S_ISREG(os.lstat(path).st_mode) {
        raise OSError(errno.EINVAL, f"not a regular file: {path}");
    }
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0));
    try {
        if not stat.S_ISREG(os.fstat(fd).st_mode) {
            raise OSError(errno.EINVAL, f"not a regular file: {path}");
        }
        chunks: list[any] = [];
        while True {
            chunk = os.read(fd, 65536);
            if not chunk {
                break;
            }
            chunks.append(chunk);
        }
        return b"".join(chunks).decode("utf-8", errors="replace");
    } finally {
        os.close(fd);
    }
}


def _memory_folder_entries(dir_: str) -> list[any] {
    if _regular_memory_files_only and not stat.S_ISDIR(os.lstat(dir_).st_mode) {
        return [];
    }
    return os.listdir(dir_);
}


def _regular_file(path: str) -> bool {
    try {
        return stat.S_ISREG(os.lstat(path).st_mode);
    } except Exception {
        return False;
    }
}


def _memory_entry_stat(path: str) -> any {
    # The stat a listing trusts: on a Cloud home the entry's own (a link
    # is not a file); elsewhere what it points at, as before.
    if _regular_memory_files_only {
        return os.lstat(path);
    }
    return os.stat(path);
}


def read_memory_file(bot_id: str) -> dict[str, any] {
    # MEMORY.md whole, as an editor sees it; seed-only reads as empty.
    try {
        raw = read_memory_text(os.path.join(workspace_dir(bot_id), "MEMORY.md"));
    } except Exception {
        return {"text": "", "truncated": False};
    }
    if not _js_trim(raw) or raw == MEMORY_SEED {
        return {"text": "", "truncated": False};
    }
    return {"text": raw, "truncated": memory_over_budget(raw)};
}


def write_memory_file(bot_id: str, text: str) -> None {
    # ensureWorkspace first: the person may edit memory before the bot
    # has ever run a turn.
    ensure_workspace(bot_id);
    write_file_atomic(os.path.join(workspace_dir(bot_id), "MEMORY.md"), redact_secrets_in_text(text), 0o600);
    _index_written_memory_file(bot_id, "MEMORY.md");
}


def load_memory(bot_id: str, now: any = None) -> (dict[str, any] | None) {
    # MEMORY.md under the load budget: first MEMORY_MAX_LINES lines or
    # MEMORY_MAX_BYTES bytes, whichever cuts first. Null when missing or
    # effectively empty (seed-only counts as empty).
    try {
        raw = read_memory_text(os.path.join(workspace_dir(bot_id), "MEMORY.md"));
    } except Exception {
        return None;
    }
    if not _js_trim(raw) or raw == MEMORY_SEED {
        return None;
    }
    # A fact past its `until` day is no longer true: it stays in the
    # file but no turn sees it.
    visible = without_expired(raw, memory_date(now));
    text = visible["text"];
    truncated = False;
    lines = text.split("\n");
    if memory_line_count(text) > MEMORY_MAX_LINES {
        text = "\n".join(lines[:MEMORY_MAX_LINES]);
        truncated = True;
    }
    if len(text.encode("utf-8")) > MEMORY_MAX_BYTES {
        text = text.encode("utf-8")[:MEMORY_MAX_BYTES].decode("utf-8", errors="replace");
        # a multi-byte character sliced in half decodes as U+FFFD — drop it
        text = re.sub("\ufffd+$", "", text);
        truncated = True;
    }
    return {
        "text": text,
        "truncated": truncated,
        "lines": memory_line_count(raw),
        "bytes": len(raw.encode("utf-8")),
        "expired": visible["hidden"],
    };
}


def _topics_sort_cmp(a: dict[str, any], b: dict[str, any]) -> int {
    return _locale_compare(a["name"], b["name"]);
}


def list_memory_topics(bot_id: str) -> list[any] {
    # The bot's memory/ topic files, name + size only.
    try {
        entries = _memory_folder_entries(os.path.join(workspace_dir(bot_id), "memory"));
    } except Exception {
        return [];
    }
    out: list[any] = [];
    for name in entries {
        if not is_memory_topic_name(name) {
            continue;
        }
        try {
            st = _memory_entry_stat(os.path.join(workspace_dir(bot_id), "memory", name));
            if stat.S_ISREG(st.st_mode) {
                out.append({"name": name, "bytes": st.st_size});
            }
        } except Exception {
        }
    }
    return sorted(out, key=functools.cmp_to_key(_topics_sort_cmp));
}


def write_memory_topic(bot_id: str, name: str, text: str) -> None {
    if not is_memory_topic_name(name) {
        raise ValueError("invalid topic name");
    }
    ensure_workspace(bot_id);
    write_file_atomic(os.path.join(workspace_dir(bot_id), "memory", name), redact_secrets_in_text(text), 0o600);
    _index_written_memory_file(bot_id, f"memory/{name}");
}


def read_memory_topic(bot_id: str, name: str) -> (str | None) {
    if not is_memory_topic_name(name) {
        return None;
    }
    try {
        return read_memory_text(os.path.join(workspace_dir(bot_id), "memory", name));
    } except Exception {
        return None;
    }
}


def append_memory_archive(bot_id: str, lines: list[any]) -> None {
    head = "";
    try {
        head = read_memory_text(os.path.join(workspace_dir(bot_id), "memory", ARCHIVE_TOPIC));
    } except Exception as e {
        if getattr(e, "errno", None) != errno.ENOENT {
            raise;
        }
    }
    text = head;
    if head and not head.endswith("\n") {
        text += "\n";
    }
    text += "\n".join(lines) + "\n";
    write_memory_topic(bot_id, ARCHIVE_TOPIC, text);
}


def list_memory_logs(bot_id: str) -> list[any] {
    # The bot's daily log files, oldest first, by day name. Plain
    # code-point sort, like JS .sort().
    try {
        dir_ = os.path.join(workspace_dir(bot_id), "memory", MEMORY_LOG_DIR);
        names: list[any] = [];
        for n in _memory_folder_entries(dir_) {
            if _LOG_FILE_NAME.match(n) and (not _regular_memory_files_only or _regular_file(os.path.join(dir_, n))) {
                names.append(n);
            }
        }
        return sorted(names);
    } except Exception {
        return [];
    }
}


def read_memory_log(bot_id: str, name: str) -> (str | None) {
    if not _LOG_FILE_NAME.match(name) {
        return None;
    }
    try {
        return read_memory_text(os.path.join(workspace_dir(bot_id), "memory", MEMORY_LOG_DIR, name));
    } except Exception {
        return None;
    }
}


def write_memory_log(bot_id: str, name: str, text: str) -> None {
    # One whole day's log — a backup import restoring it — through the
    # same gate, scrub, modes and index as a line appended today.
    if not _LOG_FILE_NAME.match(name) {
        raise ValueError("invalid log name");
    }
    dir_ = os.path.join(ensure_workspace(bot_id), "memory", MEMORY_LOG_DIR);
    _mkdir_p_mode(dir_, 0o700);
    write_file_atomic(os.path.join(dir_, name), redact_secrets_in_text(text), 0o600);
    _index_written_memory_file(bot_id, f"memory/{MEMORY_LOG_DIR}/{name}");
}


# ── FTS sync (index lives in messages.jac) ────────────────────────────
def _index_written_memory_file(bot_id: str, relative_path: str) -> None {
    # Put a just-written file into the search index, with the stat the
    # write left, so a later sync sees it as current. Indexing must
    # never break a write that already succeeded.
    try {
        path = os.path.join(workspace_dir(bot_id), relative_path);
        st = os.stat(path);
        index_memory_file(
            bot_id,
            relative_path,
            _searchable_memory_text(relative_path, read_memory_text(path)),
            {"mtimeMs": st.st_mtime * 1000.0, "bytes": st.st_size}
        );
    } except Exception {
    }
}


def _memory_files_on_disk(bot_id: str) -> list[any] {
    dir_ = workspace_dir(bot_id);
    names: list[any] = ["MEMORY.md"];
    for topic in list_memory_topics(bot_id) {
        names.append(f"memory/{topic['name']}");
    }
    for log in list_memory_logs(bot_id) {
        names.append(f"memory/{MEMORY_LOG_DIR}/{log}");
    }
    out: list[any] = [];
    for relative_path in names {
        try {
            st = _memory_entry_stat(os.path.join(dir_, relative_path));
            if stat.S_ISREG(st.st_mode) {
                out.append({"path": relative_path, "mtimeMs": st.st_mtime * 1000.0, "bytes": st.st_size});
            }
        } except Exception {
        }
    }
    return out;
}


def _searchable_memory_text(path: str, text: str) -> str {
    if path == "MEMORY.md" and text == MEMORY_SEED {
        return "";
    }
    # Keep historical records searchable, but do not recall expired
    # current facts.
    if path == f"memory/{ARCHIVE_TOPIC}" or path.startswith(f"memory/{MEMORY_LOG_DIR}/") {
        return text;
    }
    return without_expired(text, memory_date())["text"];
}


def sync_memory_index(bot_id: str) -> None {
    # Sync edits and deletions from disk; refresh unchanged files once a
    # day too, because facts can expire without their files changing.
    today = memory_date();
    date_changed = _memory_index_dates.get(bot_id) != today;
    on_disk = _memory_files_on_disk(bot_id);
    indexed: dict[str, any] = {};
    for file in indexed_memory_files(bot_id) {
        indexed[file["path"]] = file;
    }
    for file in on_disk {
        known = indexed.pop(file["path"], None);
        if (not date_changed) and known is not None and known["bytes"] == file["bytes"] and known["mtimeMs"] == int(file["mtimeMs"]) {
            continue;
        }
        try {
            text = read_memory_text(os.path.join(workspace_dir(bot_id), file["path"]));
            index_memory_file(bot_id, file["path"], _searchable_memory_text(file["path"], text), file);
        } except Exception {
            # vanished between the listing and the read
        }
    }
    for gone in indexed {
        remove_memory_file(bot_id, gone);
    }
    _memory_index_dates[bot_id] = today;
}


def search_memory_files(bot_id: str, query: str, limit: int = 12, mode: str = "all") -> list[any] {
    # Search one bot's memory files, after syncing the index to disk.
    sync_memory_index(bot_id);
    return recall_memory(query, bot_id, limit, mode);
}


# ── server/memory-entries.ts ──────────────────────────────────────────
# The entry grammar of MEMORY.md, read back: one dated line per fact,
# `- YYYY-MM-DD · from <source> · text[ · until YYYY-MM-DD]`, with a
# struck-through body for a superseded fact.
glob UNTIL_DATE: any = re.compile(r"^\d{4}-\d{2}-\d{2}$", re.ASCII),
    _DATED: any = re.compile(r"^(- (\d{4}-\d{2}-\d{2}) · (?:from [^·\n]* · )?)(" + _DOT + r"*)$", re.ASCII),
    _UNTIL_MARK: any = re.compile(r" · until (\d{4}-\d{2}-\d{2})(?= · |$)", re.ASCII),
    _TRAILING_MARKS: any = re.compile(r"(?: · (?:updated|confirmed|until|expired|superseded|moved) \d{4}-\d{2}-\d{2})+$", re.ASCII),
    _BULLET: any = re.compile("^" + _S + r"*(?:[-*•]|\d+[.)])" + _S + "+", re.ASCII),
    # A safety or health fact must load into every turn, whatever else
    # happens.
    _ALWAYS_CORE: any = re.compile(
        r"\b(?:allerg\w*|anaphyla\w*|intoleran\w*|vegetarian|vegan|halal|kosher|gluten|lactose|diet\w*|diabet\w*|asthma\w*|epilep\w*|pregnan\w*|medicat\w*|medicine|medical|disabilit\w*|wheelchair|blind|deaf|health)\b",
        re.IGNORECASE | re.ASCII
    );


def always_core(body: str) -> bool {
    return _ALWAYS_CORE.search(body) is not None;
}


def is_memory_date(value: any) -> bool {
    # A real calendar date in YYYY-MM-DD form.
    if not isinstance(value, str) or not UNTIL_DATE.match(value) {
        return False;
    }
    parts = value.split("-");
    year = int(parts[0]);
    try {
        # JS accepts year 0000 (proleptic leap year); datetime starts at
        # 1 — validate month/day for year 0 against 2000, which is also
        # leap, so day-of-month checks agree.
        datetime.datetime((2000 if year == 0 else year), int(parts[1]), int(parts[2]));
        return True;
    } except ValueError {
        return False;
    }
}


def until_mark(until: (str | None)) -> str {
    return f" · until {until}" if until else "";
}


def _toggles_fence(line: str) -> bool {
    # A line with an odd number of fences opens or closes a code block.
    return len(re.findall(r"```", line)) % 2 == 1;
}


def parse_memory_entries(text: str) -> list[any] {
    # Every dated entry in a MEMORY.md text, in file order. An entry
    # also owns the lines under it, up to the next dated line: indented
    # ones and a code block it opens, through its closing fence. A
    # fence that never closes claims nothing.
    out: list[any] = [];
    lines = text.split("\n");
    line = 0;
    while line < len(lines) {
        raw = lines[line];
        m = _DATED.match(raw);
        if not m {
            line += 1;
            continue;
        }
        open_ = _toggles_fence(raw);
        end = line + 1;
        nxt = line + 1;
        while nxt < len(lines) and not _DATED.match(lines[nxt]) {
            if (not open_) and not re.match(r"[ \t]", lines[nxt]) and not lines[nxt].startswith("```") {
                break;
            }
            if _toggles_fence(lines[nxt]) {
                open_ = not open_;
            }
            if not open_ {
                end = nxt + 1;
            }
            nxt += 1;
        }
        rest = m.group(3);
        struck = rest.startswith("~~");
        um = _UNTIL_MARK.search(rest);
        until = um.group(1) if um else None;
        body = _TRAILING_MARKS.sub("", rest);
        body = re.sub(r"^~~", "", body);
        body = re.sub(r"~~$", "", body);
        body = _js_trim(body);
        out.append({
            "line": line,
            "end": end,
            "raw": raw,
            "prefix": m.group(1),
            "body": body,
            "date": m.group(2),
            "until": until,
            "struck": struck,
        });
        line = end;
    }
    return out;
}

def is_expired(e: dict[str, any], today: str) -> bool {
    # A live entry whose `until` day has passed; the until day itself
    # still counts.
    return not e["struck"] and e["until"] is not None and e["until"] < today;
}


def without_expired(text: str, today: str) -> dict[str, any] {
    # MEMORY.md with expired live entries left out: what a turn should
    # see. The file is untouched; the tidy-up moves them to the archive.
    expired: set = set();
    for e in parse_memory_entries(text) {
        if is_expired(e, today) {
            expired.add(e["line"]);
        }
    }
    if not expired {
        return {"text": text, "hidden": 0};
    }
    kept: list[any] = [];
    for (index, l) in enumerate(text.split("\n")) {
        if index not in expired {
            kept.append(l);
        }
    }
    return {"text": "\n".join(kept), "hidden": len(expired)};
}


def fact_identity(text: str) -> str {
    # The identity of a fact, for "is this already written down":
    # whitespace collapses, a bullet marker and one trailing full stop
    # drop, and nothing else changes.
    out = unicodedata.normalize("NFC", text);
    out = _BULLET.sub("", out);
    out = re.sub(_S + "+", " ", out);
    out = _js_trim(out);
    out = re.sub(r"\.$", "", out);
    out = _js_trim(out);
    return out;
}


def line_fact_identity(line: str) -> str {
    # The body of a line as it would be compared: the grammar's prefix
    # and marks stripped when it is an entry, the bullet stripped
    # otherwise.
    entries = parse_memory_entries(line);
    if entries {
        if entries[0]["struck"] {
            return "";
        }
        return fact_identity(entries[0]["body"]);
    }
    return fact_identity(line.replace("~~", ""));
}


def notebook_identities(text: str) -> set {
    # Every live fact identity in a notebook, for dedupe against it.
    out: set = set();
    for line in text.split("\n") {
        ident = line_fact_identity(line);
        if ident {
            out.add(ident);
        }
    }
    return out;
}


# ── server/memory-topics.ts ───────────────────────────────────────────
# One line per memory/<topic>.md, so a bot knows what its longer notes
# cover without a pointer in MEMORY.md.
glob HEAD_BYTES: int = 2048,
    TOPIC_INDEX_MAX_TOPICS: int = 40,
    TOPIC_INDEX_MAX_CHARS: int = 2000,
    _LEAD: any = re.compile("^(?:" + _S + r"*\r?\n|#{1,6}[ \t]+[^\r\n]*\r?\n)*"),
    _HEADING: any = re.compile(r"^#{1,6}[ \t]+([^\r\n]+)", re.MULTILINE),
    _HEADER_BLOCK: any = re.compile(r"^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)"),
    _FIELD: any = re.compile("^(title|description|aliases|tags)" + _S + "*:" + _S + "*(" + _DOT + "*)$"),
    _LIST_ITEM: any = re.compile("^" + _S + "*-" + _S + "+");


def _unquote(value: str) -> str {
    v = _js_trim(value);
    if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")) {
        return _js_trim(v[1:-1]);
    }
    return v;
}


def parse_topic_header(text: str) -> dict[str, any] {
    # The frontmatter fields the index uses. Anything else, or no
    # frontmatter, reads as an empty header — a hand-written topic is
    # still listed by name.
    header: dict[str, any] = {"aliases": []};
    # People write a "# Title" first and the block under it, so a
    # heading and blank lines may come before the block; the heading is
    # the title when the block names none.
    lm = _LEAD.match(text);
    lead = lm.group(0) if lm else "";
    hm = _HEADING.search(lead);
    heading = _js_trim(hm.group(1)) if hm else "";
    m = _HEADER_BLOCK.match(text[len(lead):]);
    if not m {
        if heading {
            header["title"] = heading[:160];
        }
        return header;
    }
    lines = re.split(r"\r?\n", m.group(1));
    i = 0;
    while i < len(lines) {
        field = _FIELD.match(lines[i]);
        if not field {
            i += 1;
            continue;
        }
        key = field.group(1);
        value = field.group(2);
        if key == "title" or key == "description" {
            if _js_trim(value) {
                header[key] = _unquote(value)[:160];
            }
            i += 1;
            continue;
        }
        # aliases (and tags, which people use the same way): [a, b] or a
        # list below
        items: list[any] = [];
        trimmed = _js_trim(value);
        if trimmed.startswith("[") {
            for item in re.sub(r"^\[|\]$", "", trimmed).split(",") {
                items.append(item);
            }
        } elif trimmed {
            for item in value.split(",") {
                items.append(item);
            }
        } else {
            while i + 1 < len(lines) and _LIST_ITEM.match(lines[i + 1]) {
                i += 1;
                items.append(_LIST_ITEM.sub("", lines[i]));
            }
        }
        for item in items {
            item = _unquote(item);
            if not item {
                continue;
            }
            # dedupe happens on the untruncated item, like the original
            if item not in header["aliases"] {
                header["aliases"].append(item[:40]);
            }
        }
        i += 1;
    }
    header["aliases"] = header["aliases"][:12];
    if not header.get("title") and heading {
        header["title"] = heading[:160];
    }
    return header;
}


def topic_words(name: str, header: dict[str, any]) -> list[any] {
    # The words a topic answers to: its file name, title, description
    # and aliases, lower-cased, for matching a message against without
    # a search.
    parts: list[any] = [
        re.sub(r"[-_.]+", " ", re.sub(r"\.md$", "", name, 0, re.IGNORECASE)),
        header.get("title") or "",
        header.get("description") or "",
    ];
    for alias in (header.get("aliases") or []) {
        parts.append(alias);
    }
    text = " ".join(parts).lower();
    out: list[any] = [];
    seen: set = set();
    word = "";
    for ch in text {
        if _is_ln(ch) {
            word += ch;
        } else {
            if _js_len(word) >= 3 and word not in seen {
                seen.add(word);
                out.append(word);
            }
            word = "";
        }
    }
    if _js_len(word) >= 3 and word not in seen {
        out.append(word);
    }
    return out;
}


def topic_body(text: str) -> str {
    # A topic's text without its header block, for a recalled passage.
    lm = _LEAD.match(text);
    lead = lm.group(0) if lm else "";
    rest = _HEADER_BLOCK.sub("", text[len(lead):], 1);
    return _js_trim(rest);
}


def read_topic_head(path: str) -> str {
    fd: (int | None) = None;
    try {
        fd = os.open(path, os.O_RDONLY);
        data = os.read(fd, HEAD_BYTES);
        return data.decode("utf-8", errors="replace");
    } except Exception {
        return "";
    } finally {
        if fd is not None {
            try {
                os.close(fd);
            } except OSError {
            }
        }
    }
}


def _topic_index_cmp(a: dict[str, any], b: dict[str, any]) -> int {
    # archive.md last, then localeCompare on the name.
    arc = int(a["name"] == "archive.md") - int(b["name"] == "archive.md");
    if arc != 0 {
        return arc;
    }
    return _locale_compare(a["name"], b["name"]);
}


def render_topic_index(topics: list[any]) -> str {
    # One line per topic, capped by count and length. The archive is
    # listed last and labelled, so it is not mistaken for current notes.
    if not topics {
        return "";
    }
    ordered = sorted(topics, key=functools.cmp_to_key(_topic_index_cmp));
    lines: list[any] = [];
    length = 0;
    omitted = 0;
    for topic in ordered {
        name = topic["name"];
        header = topic["header"];
        if len(lines) >= TOPIC_INDEX_MAX_TOPICS {
            omitted += 1;
            continue;
        }
        about = "";
        if name == "archive.md" {
            about = "older notes moved out of MEMORY.md, kept for the record";
        } else {
            parts: list[any] = [];
            if header.get("title") {
                parts.append(header["title"]);
            }
            if header.get("description") {
                parts.append(header["description"]);
            }
            about = " — ".join(parts);
        }
        also = "";
        if header.get("aliases") {
            also = " (also: " + ", ".join(header["aliases"]) + ")";
        }
        line = "- memory/" + name;
        if about {
            line += " — " + about;
        }
        line += also;
        line = re.sub(_S + "+", " ", line);
        if length + _js_len(line) + 1 > TOPIC_INDEX_MAX_CHARS {
            omitted += 1;
            continue;
        }
        lines.append(line);
        length += _js_len(line) + 1;
    }
    if omitted {
        lines.append(f"- …and {omitted} more in memory/");
    }
    return "\n".join(lines);
}


def _alias_list(aliases: list[any]) -> str {
    return "[" + ", ".join(aliases) + "]";
}


def merge_topic_text(existing: (str | None), input: dict[str, any]) -> str {
    # A topic file with new entry lines appended and new aliases merged
    # into its header — created, header first, when it does not exist
    # yet.
    lines = "\n".join(input["lines"]);
    if existing is None or not _js_trim(existing) {
        aliases = list(dict.fromkeys(input["aliases"]))[:12];
        head = f"---\ntitle: {input['title']}\n";
        if aliases {
            head += f"aliases: {_alias_list(aliases)}\n";
        }
        return head + f"---\n\n{lines}\n";
    }
    lm = _LEAD.match(existing);
    lead = lm.group(0) if lm else "";
    rest = existing[len(lead):];
    block = _HEADER_BLOCK.match(rest);
    text: str;
    if not block {
        aliases = list(dict.fromkeys(input["aliases"]))[:12];
        title = parse_topic_header(existing).get("title");
        if title is None {
            title = input["title"];
        }
        text = f"---\ntitle: {title}\n";
        if aliases {
            text += f"aliases: {_alias_list(aliases)}\n";
        }
        text += f"---\n\n{existing}";
    } else {
        known = parse_topic_header(existing)["aliases"];
        lower: set = set();
        for alias in known {
            lower.add(alias.lower());
        }
        added: list[any] = [];
        for alias in input["aliases"] {
            if alias.lower() not in lower {
                added.append(alias);
            }
        }
        if not added {
            text = existing;
        } else {
            merged = (list(known) + added)[:12];
            body = re.split(r"\r?\n", block.group(1));
            at = -1;
            for (idx, bline) in enumerate(body) {
                if re.match(r"^aliases" + _S + "*:", bline) {
                    at = idx;
                    break;
                }
            }
            if at == -1 {
                body.append(f"aliases: {_alias_list(merged)}");
            } else {
                # a multi-line list under aliases: is replaced by the
                # one-line form
                end = at + 1;
                while end < len(body) and _LIST_ITEM.match(body[end]) {
                    end += 1;
                }
                body[at:end] = [f"aliases: {_alias_list(merged)}"];
            }
            text = lead + "---\n" + "\n".join(body) + "\n---\n" + rest[len(block.group(0)):];
        }
    }
    if not text.endswith("\n") {
        text += "\n";
    }
    return text + lines + "\n";
}


# ── server/memory-store.ts ────────────────────────────────────────────
# The person-facing half of bot memory. A `path` arrives from outside,
# so it is matched against an allowlist of the three shapes memory
# actually has rather than sanitised.
class MemoryStoreError(Exception) {
}


def _store_error(code: str, status: int, message: str, conflict: (dict[str, any] | None) = None) -> MemoryStoreError {
    err = MemoryStoreError(message);
    # setattr: the checker's static class shape does not model dynamic
    # attribute assignment; the TS error carries these fields at runtime.
    setattr(err, "code", code);
    setattr(err, "status", status);
    if conflict is not None {
        setattr(err, "currentHash", conflict["currentHash"]);
        setattr(err, "current", conflict["current"]);
    }
    return err;
}


def _path_error(path: any) -> MemoryStoreError {
    return _store_error(
        "path",
        400,
        f"not a memory file: {js_stringify(path)} — use MEMORY.md, memory/<topic>.md or memory/log/<day>.md"
    );
}


glob _BOT_ID: any = re.compile(r"[A-Za-z0-9_-]{1,128}", re.ASCII);


def parse_memory_path(path: any) -> dict[str, any] {
    # Only three shapes exist: the index, one topic file directly under
    # memory/, or one daily log directly under memory/log/. No
    # separators inside a name means no traversal; no leading dot means
    # no dotfiles and no bare "..". Backslashes and NUL never match.
    if not isinstance(path, str) or not path {
        raise _path_error(path);
    }
    if path == MEMORY_INDEX {
        return {"path": path, "kind": "index", "name": MEMORY_INDEX};
    }
    parts = path.split("/");
    if len(parts) == 2 and parts[0] == "memory" and is_memory_topic_name(parts[1]) {
        return {"path": path, "kind": "topic", "name": parts[1]};
    }
    if len(parts) == 3 and parts[0] == "memory" and parts[1] == "log" and is_memory_topic_name(parts[2]) {
        return {"path": path, "kind": "log", "name": parts[2]};
    }
    raise _path_error(path);
}


def _assert_bot_id(bot_id: str) -> None {
    if not _BOT_ID.fullmatch(bot_id) {
        raise _store_error("path", 400, "invalid bot id");
    }
}


def _relative_segments(ref: dict[str, any]) -> list[any] {
    if ref["kind"] == "index" {
        return [MEMORY_INDEX];
    }
    if ref["kind"] == "topic" {
        return ["memory", ref["name"]];
    }
    return ["memory", "log", ref["name"]];
}


def resolve_memory_path(bot_id: str, path: str) -> str {
    # The absolute path a memory document lives at, after proving it
    # stays inside the workspace. The grammar already forbids traversal;
    # this guards the other escape — a symlink. The nearest existing
    # ancestor is resolved through realpath and must sit under the real
    # workspace, and the file itself, when present, must be a regular
    # file rather than a link.
    _assert_bot_id(bot_id);
    ref = parse_memory_path(path);
    root_dir = workspace_dir(bot_id);
    absolute = root_dir;
    for seg in _relative_segments(ref) {
        absolute = os.path.join(absolute, seg);
    }
    if not os.path.exists(root_dir) {
        # no workspace yet — nothing to escape from
        return absolute;
    }
    real_root = os.path.realpath(root_dir);
    ancestor = os.path.dirname(absolute);
    while not os.path.exists(ancestor) and ancestor != root_dir {
        ancestor = os.path.dirname(ancestor);
    }
    real_ancestor = os.path.realpath(ancestor);
    if real_ancestor != real_root and not real_ancestor.startswith(real_root + os.sep) {
        raise _store_error("path", 400, f"memory path escapes the workspace: {js_stringify(path)}");
    }
    # islink never raises; a missing file is fine — a topic the person
    # is about to create.
    if os.path.islink(absolute) {
        raise _store_error("path", 400, f"memory file is a link, not a file: {js_stringify(path)}");
    }
    return absolute;
}


def hash_memory_text(text: str) -> str {
    return hashlib.sha256(text.encode("utf-8")).hexdigest();
}


def memory_capacity(raw: str) -> dict[str, any] {
    # Mirrors load_memory()'s cut exactly so the gauge never claims
    # something loads that does not: first MEMORY_MAX_LINES lines, then
    # MEMORY_MAX_BYTES bytes, whichever cuts first.
    if raw == "" {
        lines = 0;
    } else {
        lines = len(raw.split("\n"));
    }
    loaded = raw;
    truncated = False;
    if lines > MEMORY_MAX_LINES {
        loaded = "\n".join(raw.split("\n")[:MEMORY_MAX_LINES]);
        truncated = True;
    }
    if len(loaded.encode("utf-8")) > MEMORY_MAX_BYTES {
        loaded = loaded.encode("utf-8")[:MEMORY_MAX_BYTES].decode("utf-8", errors="replace");
        loaded = re.sub("\ufffd+$", "", loaded);
        truncated = True;
    }
    if loaded == "" {
        loaded_lines = 0;
    } else {
        loaded_lines = len(loaded.split("\n"));
    }
    return {
        "lines": lines,
        "bytes": len(raw.encode("utf-8")),
        "maxLines": MEMORY_MAX_LINES,
        "maxBytes": MEMORY_MAX_BYTES,
        "loadedLines": loaded_lines,
        "loadedBytes": len(loaded.encode("utf-8")),
        "truncated": truncated,
        "hash": hash_memory_text(raw),
    };
}


def _files_sort_cmp(a: dict[str, any], b: dict[str, any]) -> int {
    # newest first: the file the bot just touched is the one to look at
    if b["modifiedAt"] != a["modifiedAt"] {
        return -1 if b["modifiedAt"] < a["modifiedAt"] else 1;
    }
    return _locale_compare(a["name"], b["name"]);
}


def _list_markdown(dir_: str, prefix: str) -> list[any] {
    try {
        names = os.listdir(dir_);
    } except Exception {
        return [];
    }
    files: list[any] = [];
    for name in names {
        if not is_memory_topic_name(name) {
            continue;
        }
        try {
            # lstat, not stat: a symlinked topic is not a memory file
            # and must not be listed as one
            info = os.lstat(os.path.join(dir_, name));
            if not stat.S_ISREG(info.st_mode) {
                continue;
            }
            files.append({
                "path": f"{prefix}/{name}",
                "name": name,
                "bytes": info.st_size,
                "modifiedAt": int(info.st_mtime * 1000 + 0.5),
            });
        } except Exception {
            # deleted between readdir and lstat: simply not listed
        }
    }
    return sorted(files, key=functools.cmp_to_key(_files_sort_cmp));
}


def memory_overview(bot_id: str) -> dict[str, any] {
    # Reads never create the workspace: a bot that has not run yet
    # simply has nothing to show.
    _assert_bot_id(bot_id);
    root_dir = workspace_dir(bot_id);
    raw = "";
    try {
        raw = _read_utf8(resolve_memory_path(bot_id, MEMORY_INDEX));
    } except MemoryStoreError {
        raise;
    } except Exception {
        raw = "";
    }
    return {
        "botId": bot_id,
        "workspacePath": root_dir,
        "index": memory_capacity(raw),
        "topics": _list_markdown(os.path.join(root_dir, "memory"), "memory"),
        "logs": _list_markdown(os.path.join(root_dir, "memory", "log"), "memory/log"),
    };
}


def read_memory_doc(bot_id: str, path: str) -> dict[str, any] {
    # A missing document reads as empty rather than as an error: the
    # topic the person is about to create has no file yet, and its hash
    # is the hash of "".
    absolute = resolve_memory_path(bot_id, path);
    try {
        text = _read_utf8(absolute);
        return {"path": path, "text": text, "hash": hash_memory_text(text), "exists": True};
    } except Exception {
        return {"path": path, "text": "", "hash": hash_memory_text(""), "exists": False};
    }
}


def write_memory_doc(bot_id: str, path: str, text: str, expected_hash: (str | None) = None) -> dict[str, any] {
    # Atomic, 0600, redacted. With `expected_hash`, the write is refused
    # (409) unless the file still hashes to what the caller last saw.
    ref = parse_memory_path(path);
    ensure_workspace(bot_id);
    if ref["kind"] == "log" {
        _mkdir_p_mode(os.path.join(workspace_dir(bot_id), "memory", "log"), 0o700);
    }
    absolute = resolve_memory_path(bot_id, path);
    after = redact_secrets_in_text(text);
    if len(after.encode("utf-8")) > MEMORY_FILE_MAX_BYTES {
        raise _store_error(
            "too-large",
            413,
            f"memory files are capped at {int(MEMORY_FILE_MAX_BYTES / 1024)}KB — move longer notes into memory/<topic>.md files"
        );
    }
    current = read_memory_doc(bot_id, path);
    if expected_hash is not None and expected_hash != current["hash"] {
        raise _store_error(
            "conflict",
            409,
            "this file changed since you opened it — reload to see the new version, or save again to overwrite it",
            {"currentHash": current["hash"], "current": current["text"]},
        );
    }
    write_file_atomic(absolute, after, 0o600);
    return {
        "path": path,
        "before": current["text"] if current["exists"] else None,
        "after": after,
        "hash": hash_memory_text(after),
    };
}


def delete_memory_doc(bot_id: str, path: str) -> dict[str, any] {
    # Topic and log files only: MEMORY.md is loaded unconditionally and
    # the next ensure_workspace() would silently reseed it.
    ref = parse_memory_path(path);
    if ref["kind"] == "index" {
        raise _store_error("forbidden", 400, "MEMORY.md cannot be deleted — clear its text instead");
    }
    absolute = resolve_memory_path(bot_id, path);
    current = read_memory_doc(bot_id, path);
    if current["exists"] {
        os.unlink(absolute);
    }
    return {"path": path, "before": current["text"] if current["exists"] else None};
}


def obsidian_url_for(workspace_path: str) -> str {
    # encodeURIComponent leaves - _ . ~ ! ' ( ) * unescaped; quote()
    # needs the extras added to `safe` (and "/" removed).
    return "obsidian://open?path=" + urllib.parse.quote(workspace_path, safe="!'()*");
}


def _spawn_opener(command: str, args: list[any]) -> (int | None) {
    # Runs the platform URL/folder opener and returns its exit code;
    # null when it could not be launched or did not exit in time. No
    # shell, fixed argv, nothing from the request.
    try {
        proc = subprocess.Popen(
            [command] + list(args),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        );
    } except Exception {
        return None;
    }
    try {
        code = proc.wait(timeout=3.0);
        # Node's exit event reports null for a process killed by a
        # signal; Python reports -signum.
        if code < 0 {
            return None;
        }
        return code;
    } except subprocess.TimeoutExpired {
        proc.kill();
        return None;
    }
}


def open_memory_location(bot_id: str, target: str, platform: (str | None) = None, run: any = None) -> dict[str, any] {
    # Opens the bot's memory folder on the machine running the server —
    # in Obsidian (obsidian://open?path=…) or in the file manager.
    if platform is None {
        platform = sys.platform;
    }
    if run is None {
        run = _spawn_opener;
    }
    _assert_bot_id(bot_id);
    workspace_path = ensure_workspace(bot_id);
    location = obsidian_url_for(workspace_path) if target == "obsidian" else workspace_path;
    command: str;
    args: list[any];
    if platform == "darwin" {
        command = "open";
        args = [location];
    } elif platform == "win32" {
        if target == "obsidian" {
            command = "rundll32.exe";
            args = ["url.dll,FileProtocolHandler", location];
        } else {
            command = "explorer.exe";
            args = [location];
        }
    } else {
        command = "xdg-open";
        args = [location];
    }
    code = run(command, args);
    # explorer.exe reports 1 even when it opened the window; only
    # "could not launch" is a failure there
    ok = code == 0 or (platform == "win32" and target == "folder" and code is not None);
    if ok {
        return {"ok": True, "workspacePath": workspace_path};
    }
    if target == "obsidian" {
        error = f"Obsidian did not open. Is it installed? The folder is {workspace_path}";
    } else {
        error = f"The file manager did not open. The folder is {workspace_path}";
    }
    return {"ok": False, "error": error, "workspacePath": workspace_path};
}
