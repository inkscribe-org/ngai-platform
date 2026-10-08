"""Transcript operations — port of server/message-db.ts's exported surface.

Every function takes/returns the same shapes as the TS module; the `json`
column is produced by jsutil.js_stringify so stored bytes match
JSON.stringify. `at` arrives from the client as milliseconds (a JS number);
it is stored verbatim in the INTEGER column, same as node.
"""

import os;
import json;
import re;

import from jsutil { js_stringify }
import from db {
    db, transaction, write_followups, db_file
}

# INSERT OR REPLACE would delete+insert under a new rowid without firing the
# delete trigger, leaving a dangling FTS entry. An upsert keeps the rowid.
glob UPSERT_MESSAGE: str = (
    "INSERT INTO messages (thread_id, id, at, role, kind, text, json) VALUES (?, ?, ?, ?, ?, ?, ?) "
    "ON CONFLICT(thread_id, id) DO UPDATE SET at = excluded.at, role = excluded.role, kind = excluded.kind, "
    "text = excluded.text, json = excluded.json"
);


def peer_provenance_author(text: str) -> (str | None) {
    # The bot named by an ask_bot note at the start of a stored line.
    m = re.match(
        r"^\[Message from @(.+?), another bot in this OpenMausBot workspace",
        text
    );
    return m.group(1) if m else None;
}


def _peer_author(peer_name: (str | None), text: str) -> (str | None) {
    return peer_name if peer_name is not None else peer_provenance_author(text);
}


def insert_message(thread_id: str, message: dict[str, any]) -> None {
    db().execute(
        UPSERT_MESSAGE,
        (
            thread_id,
            message["id"],
            message["at"],
            message["role"],
            message["kind"],
            message.get("text"),
            js_stringify(message),
        )
    );
}


def set_active_leaf(thread_id: str, leaf_id: (str | None)) -> None {
    db().execute(
        "INSERT INTO thread_state (thread_id, active_leaf_id) VALUES (?, ?) "
        "ON CONFLICT(thread_id) DO UPDATE SET active_leaf_id = excluded.active_leaf_id",
        (thread_id, leaf_id)
    );
}


def _import_legacy(thread_id: str, legacy_file: str) -> dict[str, any] {
    # Pull the pre-SQLite JSON thread file in on first touch, then rename
    # it so the import never runs twice against a thread whose rows were
    # later deleted.
    messages: list[any] = [];
    active_leaf_id = None;
    try {
        with open(legacy_file, "r", encoding="utf-8") as f {
            raw = json.load(f);
        }
    } except Exception {
        return {"messages": messages, "activeLeafId": active_leaf_id};
    }
    if isinstance(raw, list) {
        messages = raw;
    } elif isinstance(raw, dict) {
        messages = raw.get("messages") or [];
        active_leaf_id = raw.get("activeLeafId");
    }
    conn = db();
    conn.execute("BEGIN");
    try {
        for message in messages {
            conn.execute(
                UPSERT_MESSAGE,
                (
                    thread_id,
                    message["id"],
                    message["at"],
                    message["role"],
                    message["kind"],
                    message.get("text"),
                    js_stringify(message),
                )
            );
        }
        conn.execute(
            "INSERT INTO thread_state (thread_id, active_leaf_id) VALUES (?, ?) "
            "ON CONFLICT(thread_id) DO UPDATE SET active_leaf_id = excluded.active_leaf_id",
            (thread_id, active_leaf_id)
        );
        conn.execute("COMMIT");
    } except Exception {
        conn.execute("ROLLBACK");
        raise;
    }
    try {
        os.rename(legacy_file, legacy_file + ".imported");
        try {
            os.chmod(legacy_file + ".imported", 0o600);
        } except OSError {
        }
    } except OSError {
    }
    return {"messages": messages, "activeLeafId": active_leaf_id};
}


def read_thread(thread_id: str, legacy_file: str) -> dict[str, any] {
    rows = db().execute(
        "SELECT json FROM messages WHERE thread_id = ? ORDER BY rowid",
        (thread_id,)
    ).fetchall();
    if rows {
        state = db().execute(
            "SELECT active_leaf_id FROM thread_state WHERE thread_id = ?",
            (thread_id,)
        ).fetchone();
        return {
            "messages": [json.loads(r[0]) for r in rows],
            "activeLeafId": state[0] if state else None,
        };
    }
    return _import_legacy(thread_id, legacy_file);
}


def read_thread_tail(thread_id: str, legacy_file: str, limit: int) -> dict[str, any] {
    # Newest `limit` rows only, read at the SQL boundary.
    rows = db().execute(
        "SELECT json FROM messages WHERE thread_id = ? ORDER BY rowid DESC LIMIT ?",
        (thread_id, limit + 1)
    ).fetchall();
    if rows {
        has_more = len(rows) > limit;
        if has_more {
            rows = rows[:limit];
        }
        rows.reverse();
        state = db().execute(
            "SELECT active_leaf_id FROM thread_state WHERE thread_id = ?",
            (thread_id,)
        ).fetchone();
        return {
            "messages": [json.loads(r[0]) for r in rows],
            "activeLeafId": state[0] if state else None,
            "hasMore": has_more,
        };
    }
    return _import_legacy(thread_id, legacy_file);
}


def import_thread(thread_id: str, messages: list[any], active_leaf_id: (str | None)) -> None {
    # A backup may only populate a fresh thread, never replace a transcript.
    def apply(database: any) -> None {
        if (
            database.execute(
                "SELECT 1 FROM messages WHERE thread_id = ? LIMIT 1", (thread_id,)
            ).fetchone()
            or database.execute(
                "SELECT 1 FROM thread_state WHERE thread_id = ?", (thread_id,)
            ).fetchone()
        ) {
            raise RuntimeError("Cannot import over an existing conversation");
        }
        for message in messages {
            database.execute(
                UPSERT_MESSAGE,
                (
                    thread_id,
                    message["id"],
                    message["at"],
                    message["role"],
                    message["kind"],
                    message.get("text"),
                    js_stringify(message),
                )
            );
        }
        database.execute(
            "INSERT INTO thread_state (thread_id, active_leaf_id) VALUES (?, ?) "
            "ON CONFLICT(thread_id) DO UPDATE SET active_leaf_id = excluded.active_leaf_id",
            (thread_id, active_leaf_id)
        );
    }
    transaction(apply);
}


def append_message(thread_id: str, message: dict[str, any]) -> None {
    # Persist a new message and the branch head as one crash-safe mutation.
    def apply(_database: any) -> None {
        insert_message(thread_id, message);
        set_active_leaf(thread_id, message["id"]);
    }
    transaction(apply);
}


def update_message(thread_id: str, message: dict[str, any]) -> None {
    db().execute(
        "UPDATE messages SET at = ?, role = ?, kind = ?, text = ?, json = ? WHERE thread_id = ? AND id = ?",
        (
            message["at"],
            message["role"],
            message["kind"],
            message.get("text"),
            js_stringify(message),
            thread_id,
            message["id"],
        )
    );
}


def working_goal_run_messages -> list[any] {
    # Crash recovery locates the tiny set of unfinished goal-run receipts.
    rows = db().execute(
        "SELECT thread_id, json FROM messages "
        "WHERE kind = 'goal.run' AND json_extract(json, '$.goalRun.status') = 'working'"
    ).fetchall();
    return [
        {"threadId": r[0], "message": json.loads(r[1])}
        for r in rows
    ];
}


def latest_message_ats(thread_ids: list[any]) -> dict[str, any] {
    # Newest message timestamp per thread, chunked under SQLite's variable
    # limit. Threads with no rows are absent.
    ids = list(dict.fromkeys(t for t in thread_ids if t));
    out: dict[str, any] = {};
    chunk = 400;
    i = 0;
    while i < len(ids) {
        slice_ = ids[i:i + chunk];
        placeholders = ", ".join("?" for _ in slice_);
        rows = db().execute(
            f"SELECT thread_id, MAX(at) AS at FROM messages WHERE thread_id IN ({placeholders}) GROUP BY thread_id",
            tuple(slice_)
        ).fetchall();
        for row in rows {
            if row[1] is not None {
                out[row[0]] = row[1];
            }
        }
        i += chunk;
    }
    return out;
}


def delete_thread(thread_id: str) -> None {
    def write(connection: any) -> None {
        connection.execute("DELETE FROM chat_followups WHERE thread_id = ?", (thread_id,));
        connection.execute("DELETE FROM messages WHERE thread_id = ?", (thread_id,));
        connection.execute("DELETE FROM thread_state WHERE thread_id = ?", (thread_id,));
    }
    write_followups(write);
}


def threads_referencing(fragment: str) -> list[any] {
    if not fragment {
        return [];
    }
    rows = db().execute(
        "SELECT DISTINCT thread_id FROM messages WHERE instr(json, ?) > 0",
        (fragment,)
    ).fetchall();
    return [r[0] for r in rows];
}


def search_messages(query: str, limit: int = 40, thread_id: (str | None) = None) -> list[any] {
    # Case-insensitive substring search over text messages, newest first.
    # Port of message-search-query.ts: searchMessagesInDatabase.
    needle = query.strip().lower();
    if not needle {
        return [];
    }
    pattern = "%" + re.sub(r"([\\%_])", r"\\\1", needle) + "%";
    scope = "thread_id = ? AND " if thread_id else "";
    sql = (
        "SELECT thread_id, id, at, role, kind, text, json_extract(json, '$.tool.name') AS tool_name, "
        "json_extract(json, '$.from.name') AS from_name FROM messages "
        f"WHERE {scope}((kind = 'text' AND text IS NOT NULL AND lower(text) LIKE ? ESCAPE '\\') "
        "   OR (kind = 'activity' AND tool_name IS NOT NULL AND lower(tool_name) LIKE ? ESCAPE '\\')) "
        "ORDER BY at DESC LIMIT ?"
    );
    if thread_id {
        rows = db().execute(sql, (thread_id, pattern, pattern, limit)).fetchall();
    } else {
        rows = db().execute(sql, (pattern, pattern, limit)).fetchall();
    }
    out: list[any] = [];
    for row in rows {
        (thread_id_r, mid, at, role, kind, text, tool_name, from_name) = row;
        haystack = (tool_name or "") if kind == "activity" else (text or "");
        hit_at = max(0, haystack.lower().find(needle));
        start = max(0, hit_at - 60);
        end = min(len(haystack), hit_at + len(needle) + 90);
        head = "…" if start > 0 else "";
        body = re.sub(r"\s+", " ", haystack[start:end]).strip();
        snippet = head + body + ("…" if end < len(haystack) else "");
        folded = re.sub(r"\s+", " ", needle);
        match_start = snippet.lower().find(folded);
        hit = {
            "threadId": thread_id_r,
            "messageId": mid,
            "at": at,
            "role": role,
            "kind": kind,
            "snippet": snippet,
            "matchStart": len(head) if match_start < 0 else match_start,
            "matchLength": 0 if match_start < 0 else len(folded),
        };
        if from_name {
            hit["from"] = from_name;
        }
        out.append(hit);
    }
    return out;
}


glob _STOP_WORDS: set = set(
    "a an and are as at be by did do for from had has have how i in is it its of on or that the this to was we were what when where which who why with you your".split(" ")
),
    _RECALL_FILLER: set = set(
        "about again also any anything can could does don't know me my please remember remind should tell there they us would hi hello hey thanks thank ok okay yes yeah no i'm im i've i'll i'd you're quick just".split(" ")
    ),
    PEER_NOTE_HEAD_CHARS: int = 160,
    SNIPPET_TOKENS: int = 48,
    RECENT_HEAD_CHARS: int = 240,
    _RECALL_TOKEN_SPLIT: any = re.compile(r"\s+|(?<=[^\W\d_])[/,;:.—–-]+(?=[^\W\d_])", re.UNICODE),
    _RECALL_TERM_OK: any = re.compile(r"^[^\W_]+$", re.UNICODE),
    _RECALL_LETTERS4: any = re.compile(r"^[^\W\d_]{4,}$", re.UNICODE),
    _RECALL_WORD_CHARS: any = re.compile(r"[^\W_]", re.UNICODE),
    _RECALL_TRIM: any = re.compile(r"^[\s.,;:!?()\[\]{}'`“”‘’]+|[\s.,;:!?()\[\]{}'`“”‘’]+$"),
    _HAS_DIGIT: any = re.compile(r"\d");


def _fts_query(query: str, mode: str = "all") -> (str | None) {
    # Free text into an FTS5 query that cannot be misparsed: every token
    # becomes a quoted string, ANDed (FTS5 default) or ORed for mode 'any'.
    tokens = [
        t
        for t in (tok.replace('"', "").strip() for tok in query.split())
        if t
    ];
    if not tokens {
        return None;
    }
    content = [t for t in tokens if t.lower() not in _STOP_WORDS];
    if mode == "any" {
        terms = [
            mt
            for mt in (recall_match_term(t) for t in recall_terms(query))
            if mt
        ];
        return " OR ".join(terms) if terms else None;
    }
    return " ".join(f'"{t}"' for t in (content if content else tokens));
}


def recall_match_term(term: str) -> (str | None) {
    # One recall term as FTS5 syntax: words of 4+ letters match as a
    # prefix with plural -s stripped; punctuation terms are skipped.
    if not _RECALL_TERM_OK.match(term) {
        return None;
    }
    if not _RECALL_LETTERS4.match(term) {
        return f'"{term}"';
    }
    stem = term[:-1] if (len(term) > 4 and term.endswith("s") and not term.endswith("ss")) else term;
    return f'"{stem}"*';
}


def recall_terms(query: str) -> list[any] {
    # Content words of a message for an any-term recall: lower-cased,
    # de-duplicated, stop words and filler dropped.
    out: list[any] = [];
    for raw in _RECALL_TOKEN_SPLIT.split(query) {
        token = _RECALL_TRIM.sub("", raw.replace('"', "")).lower();
        if len(token) < 2 and not _HAS_DIGIT.search(token) {
            continue;
        }
        if not _RECALL_WORD_CHARS.search(token) {
            continue;
        }
        if token in _STOP_WORDS or token in _RECALL_FILLER {
            continue;
        }
        if token not in out {
            out.append(token);
        }
    }
    return out[:16];
}


def read_message_text(thread_id: str, message_id: str) -> (dict[str, any] | None) {
    # Full text of one text message for a session_read after a search hit.
    row = db().execute(
        "SELECT at, role, text, json_extract(json, '$.from.name') AS from_name, "
        "json_extract(json, '$.peerAsk.name') AS peer_name FROM messages "
        "WHERE thread_id = ? AND id = ? AND kind = 'text' AND text IS NOT NULL",
        (thread_id, message_id)
    ).fetchone();
    if row is None {
        return None;
    }
    (at, role, text, from_name, peer_name) = row;
    peer = _peer_author(peer_name, text);
    out = {
        "threadId": thread_id,
        "messageId": message_id,
        "at": at,
        "role": role,
        "text": text,
    };
    if from_name {
        out["from"] = from_name;
    }
    if peer {
        out["peer"] = peer;
    }
    return out;
}


def _range_clause(range_: (dict[str, any] | None), column: str) -> tuple[str, list[any]] {
    parts: list[any] = [];
    params: list[any] = [];
    if range_ is not None {
        if range_.get("since") is not None {
            parts.append(f"{column} >= ?");
            params.append(range_["since"]);
        }
        if range_.get("until") is not None {
            parts.append(f"{column} <= ?");
            params.append(range_["until"]);
        }
    }
    return ("".join(f" AND {p}" for p in parts), params);
}


def recall_messages(
    query: str,
    thread_ids: list[any],
    limit: int = 12,
    range_: (dict[str, any] | None) = None,
    mode: str = "all"
) -> list[any] {
    # Relevance-ranked recall over the text messages of the given threads:
    # bm25 rank from FTS5, FTS5's own snippet, scope in SQL before LIMIT.
    query_str = _fts_query(query, mode);
    if not query_str or not thread_ids {
        return [];
    }
    placeholders = ", ".join("?" for _ in thread_ids);
    (window_sql, window_params) = _range_clause(range_, "m.at");
    rows = db().execute(
        "SELECT m.thread_id, m.id, m.at, m.role, m.kind, json_extract(m.json, '$.from.name') AS from_name, "
        "json_extract(m.json, '$.peerAsk.name') AS peer_name, substr(m.text, 1, ?) AS head, "
        "snippet(messages_fts, 0, '[', ']', '…', ?) AS snippet "
        "FROM messages_fts JOIN messages m ON m.rowid = messages_fts.rowid "
        f"WHERE messages_fts MATCH ? AND m.kind IN ('text', 'digest') AND m.thread_id IN ({placeholders}){window_sql} "
        # a digest ranks after every text hit so recall reads like a conversation first
        "ORDER BY (m.kind = 'digest'), bm25(messages_fts), m.at DESC LIMIT ?",
        (PEER_NOTE_HEAD_CHARS, SNIPPET_TOKENS, query_str, *thread_ids, *window_params, limit)
    ).fetchall();
    out: list[any] = [];
    for row in rows {
        (tid, mid, at, role, kind, from_name, peer_name, head, snippet) = row;
        peer = _peer_author(peer_name, head);
        hit = {
            "threadId": tid,
            "messageId": mid,
            "at": at,
            "role": role,
        };
        if kind == "digest" {
            hit["kind"] = "digest";
        }
        hit["snippet"] = re.sub(r"\s+", " ", snippet).strip();
        if from_name {
            hit["from"] = from_name;
        }
        if peer {
            hit["peer"] = peer;
        }
        out.append(hit);
    }
    return out;
}


def recent_messages(thread_ids: list[any], range_: dict[str, any], limit: int = 12) -> list[any] {
    # Text messages of the given threads inside a time window, newest first.
    if not thread_ids {
        return [];
    }
    placeholders = ", ".join("?" for _ in thread_ids);
    (window_sql, window_params) = _range_clause(range_, "m.at");
    rows = db().execute(
        "SELECT m.thread_id, m.id, m.at, m.role, json_extract(m.json, '$.from.name') AS from_name, "
        "json_extract(m.json, '$.peerAsk.name') AS peer_name, substr(m.text, 1, ?) AS head "
        f"FROM messages m WHERE m.kind = 'text' AND m.text IS NOT NULL AND m.thread_id IN ({placeholders}){window_sql} "
        "ORDER BY m.at DESC LIMIT ?",
        (max(PEER_NOTE_HEAD_CHARS, RECENT_HEAD_CHARS), *thread_ids, *window_params, limit)
    ).fetchall();
    out: list[any] = [];
    for row in rows {
        (tid, mid, at, role, from_name, peer_name, head) = row;
        peer = _peer_author(peer_name, head);
        folded = re.sub(r"\s+", " ", head).strip();
        snippet = (
            folded[:RECENT_HEAD_CHARS] + "…" if len(folded) > RECENT_HEAD_CHARS else folded
        );
        hit = {
            "threadId": tid,
            "messageId": mid,
            "at": at,
            "role": role,
            "snippet": snippet,
        };
        if from_name {
            hit["from"] = from_name;
        }
        if peer {
            hit["peer"] = peer;
        }
        out.append(hit);
    }
    return out;
}


def latest_said_by_bot(thread_ids: list[any], bot_id: str, since: int, limit: int = 20) -> list[any] {
    # For each thread, the newest text message the bot itself said there
    # since `since` — one row per thread, newest thread first.
    if not thread_ids {
        return [];
    }
    placeholders = ", ".join("?" for _ in thread_ids);
    rows = db().execute(
        "SELECT thread_id, id, at, head FROM ("
        "SELECT m.thread_id, m.id, m.at, substr(m.text, 1, 400) AS head, "
        "ROW_NUMBER() OVER (PARTITION BY m.thread_id ORDER BY m.at DESC) AS rn "
        "FROM messages m "
        f"WHERE m.kind = 'text' AND m.role = 'bot' AND m.text IS NOT NULL AND m.at >= ? AND m.thread_id IN ({placeholders}) "
        "AND (json_extract(m.json, '$.from.botId') IS NULL OR json_extract(m.json, '$.from.botId') = ?)"
        ") WHERE rn = 1 ORDER BY at DESC LIMIT ?",
        (since, *thread_ids, bot_id, limit)
    ).fetchall();
    return [
        {
            "threadId": r[0],
            "messageId": r[1],
            "at": r[2],
            "head": re.sub(r"\s+", " ", r[3]).strip(),
        }
        for r in rows
    ];
}


def read_command_receipt(kind: str, key: str) -> (dict[str, any] | None) {
    row = db().execute(
        "SELECT kind, key, at, result FROM command_receipts WHERE kind = ? AND key = ?",
        (kind, key)
    ).fetchone();
    if row is None {
        return None;
    }
    return {"kind": row[0], "key": row[1], "at": row[2], "result": row[3]};
}


def with_command_receipt(kind: str, key: str, apply: any, at: int) -> dict[str, any] {
    # Run `apply` and record its receipt in ONE transaction: a stored
    # receipt short-circuits and `apply` never runs.
    def body(database: any) -> dict[str, any] {
        existing = database.execute(
            "SELECT result FROM command_receipts WHERE kind = ? AND key = ?",
            (kind, key)
        ).fetchone();
        if existing {
            return {"result": existing[0], "replayed": True};
        }
        result = apply();
        database.execute(
            "INSERT INTO command_receipts(kind, key, at, result) VALUES (?, ?, ?, ?)",
            (kind, key, at, result)
        );
        return {"result": result, "replayed": False};
    }
    return transaction(body);
}


def save_chat_followup(followup: dict[str, any]) -> None {
    def write(connection: any) -> None {
        connection.execute(
            "INSERT INTO chat_followups(id, kind, owner_id, thread_id, send_id, status, payload) "
            "VALUES (?, ?, ?, ?, ?, 'pending', ?)",
            (
                followup["id"],
                followup["kind"],
                followup["ownerId"],
                followup["threadId"],
                followup.get("payload", {}).get("sendId"),
                js_stringify(followup["payload"]),
            )
        );
    }
    write_followups(write);
}


def settle_chat_followups(ids: list[any], status: (str | None)) -> None {
    # Null retires a dispatch whose transcript is durable; cancellation
    # tombstones remain so a retried sendId cannot resurrect it.
    if not ids {
        return;
    }
    def write(connection: any) -> None {
        if status is None {
            sql = "DELETE FROM chat_followups WHERE id = ?";
        } elif status == "cancelled" {
            sql = "UPDATE chat_followups SET status = ?, payload = '{\"text\":\"\"}' WHERE id = ?";
        } else {
            sql = "UPDATE chat_followups SET status = ? WHERE id = ?";
        }
        for fid in ids {
            if status is None {
                connection.execute(sql, (fid,));
            } else {
                connection.execute(sql, (status, fid));
            }
        }
    }
    write_followups(write);
}


def chat_followups(kind: (str | None) = None) -> list[any] {
    if kind {
        rows = db().execute(
            "SELECT id, kind, owner_id, thread_id, status, payload FROM chat_followups WHERE kind = ? ORDER BY rowid",
            (kind,)
        ).fetchall();
    } else {
        rows = db().execute(
            "SELECT id, kind, owner_id, thread_id, status, payload FROM chat_followups ORDER BY rowid"
        ).fetchall();
    }
    return [
        {
            "id": r[0],
            "kind": r[1],
            "ownerId": r[2],
            "threadId": r[3],
            "status": r[4],
            "payload": json.loads(r[5]),
        }
        for r in rows
    ];
}


def cancelled_chat_followup(kind: str, owner_id: str, thread_id: str, send_id: str) -> bool {
    return db().execute(
        "SELECT 1 FROM chat_followups WHERE kind = ? AND owner_id = ? AND thread_id = ? AND send_id = ? AND status = 'cancelled'",
        (kind, owner_id, thread_id, send_id)
    ).fetchone() is not None;
}


def index_memory_file(bot_id: str, path: str, text: str, stat: dict[str, any]) -> None {
    # Index one memory file; the upsert keeps the rowid so the update
    # trigger keeps FTS in step.
    db().execute(
        "INSERT INTO memory_files (bot_id, path, text, mtime_ms, bytes) VALUES (?, ?, ?, ?, ?) "
        "ON CONFLICT(bot_id, path) DO UPDATE SET text = excluded.text, mtime_ms = excluded.mtime_ms, bytes = excluded.bytes",
        (bot_id, path, text, int(stat["mtimeMs"]), stat["bytes"])
    );
}


def remove_memory_file(bot_id: str, path: str) -> None {
    db().execute("DELETE FROM memory_files WHERE bot_id = ? AND path = ?", (bot_id, path));
}


def indexed_memory_files(bot_id: str) -> list[any] {
    rows = db().execute(
        "SELECT path, mtime_ms, bytes FROM memory_files WHERE bot_id = ?",
        (bot_id,)
    ).fetchall();
    return [{"path": r[0], "mtimeMs": r[1], "bytes": r[2]} for r in rows];
}


def recall_memory(query: str, bot_id: str, limit: int = 12, mode: str = "all") -> list[any] {
    # Relevance-ranked recall over ONE bot's memory files, scoped in SQL.
    query_str = _fts_query(query, mode);
    if not query_str {
        return [];
    }
    scope = (
        "AND f.path NOT IN ('MEMORY.md', 'memory/archive.md') AND f.path NOT LIKE 'memory/log/%' "
        if mode == "any"
        else ""
    );
    rows = db().execute(
        "SELECT f.path, f.mtime_ms, "
        "snippet(memory_fts, 0, '[', ']', '…', ?) AS snippet "
        "FROM memory_fts JOIN memory_files f ON f.rowid = memory_fts.rowid "
        f"WHERE memory_fts MATCH ? AND f.bot_id = ? {scope}"
        "ORDER BY bm25(memory_fts), f.mtime_ms DESC LIMIT ?",
        (SNIPPET_TOKENS, query_str, bot_id, limit)
    ).fetchall();
    return [
        {
            "file": r[0],
            "at": r[1],
            "snippet": re.sub(r"\s+", " ", r[2]).strip(),
        }
        for r in rows
    ];
}
