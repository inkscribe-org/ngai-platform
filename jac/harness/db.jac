"""SQLite layer for the OpenMausBot transcript database.

Byte-for-byte port of server/message-db.ts's connection, schema, and
transaction discipline:

  - file: <DATA_DIR>/messages.db, dir mode 0o700, file mode 0o600
  - PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL
  - synchronous = FULL only inside writeFollowups (small claim transactions)
  - nested writes use SAVEPOINT command_<depth>; outer uses BEGIN IMMEDIATE
  - messages upsert (never INSERT OR REPLACE) so the FTS update trigger
    keeps the index in step — see UPSERT_MESSAGE below.

FTS5 in stdlib sqlite3 depends on the Python build; the module surfaces a
clear error (describe_missing_fts5) instead of "no such module: fts5".
"""

import os;
import json;
import sqlite3;
import threading;
import re;

import from jsutil { js_stringify }

glob DATA_DIR: str = os.environ.get(
        "OMB_DATA_DIR",
        os.path.join(os.path.expanduser("~"), ".openmausbot")
    ),
    _state: dict[str, any] = {"handle": None, "path": ""},
    _txn_local: any = threading.local();


def db_file -> str {
    return os.path.join(DATA_DIR, "messages.db");
}


# Test hook: point the whole DB layer at a fresh directory and drop any
# cached connection. Modules that captured DATA_DIR at import (lease,
# sessions, memory file paths) are unaffected — only DB-backed state.
def set_data_dir(path: str) {
    close_db();
    globals()["DATA_DIR"] = path;
    _state["handle"] = None;
    _state["handle_path"] = None;
}


def describe_missing_fts5(error: Exception) -> (Exception | None) {
    msg = str(error);
    if not re.search(r"no such module:\s*fts5", msg, re.IGNORECASE) {
        return None;
    }
    return RuntimeError(
        "OpenMausBot needs SQLite with FTS5, which is built into Node 24 and newer (and into the app). "
        f"The Python running this harness has none: build or install Python with SQLite FTS5 enabled. ({msg})"
    );
}


# The SQL text of every DDL statement is byte-identical to what node's
# message-db.ts executes — sqlite_master.sql stores the CREATE text verbatim
# (minus IF NOT EXISTS), and .dump replays it, so whitespace must match.
glob _CORE_DDL: str = (
    "\n    CREATE TABLE IF NOT EXISTS messages ("
    "\n      thread_id TEXT NOT NULL,"
    "\n      id TEXT NOT NULL,"
    "\n      at INTEGER NOT NULL,"
    "\n      role TEXT NOT NULL,"
    "\n      kind TEXT NOT NULL,"
    "\n      text TEXT,"
    "\n      json TEXT NOT NULL,"
    "\n      PRIMARY KEY (thread_id, id)"
    "\n    );"
    "\n    CREATE INDEX IF NOT EXISTS messages_thread ON messages(thread_id);"
    "\n    CREATE TABLE IF NOT EXISTS thread_state ("
    "\n      thread_id TEXT PRIMARY KEY,"
    "\n      active_leaf_id TEXT"
    "\n    );"
    "\n    CREATE TABLE IF NOT EXISTS chat_followups ("
    "\n      id TEXT PRIMARY KEY,"
    "\n      kind TEXT NOT NULL,"
    "\n      owner_id TEXT NOT NULL,"
    "\n      thread_id TEXT NOT NULL,"
    "\n      send_id TEXT,"
    "\n      status TEXT NOT NULL,"
    "\n      payload TEXT NOT NULL"
    "\n    );"
    "\n    CREATE INDEX IF NOT EXISTS chat_followups_receipt ON chat_followups(kind, owner_id, thread_id, send_id);"
    "\n    CREATE TABLE IF NOT EXISTS command_receipts ("
    "\n      kind TEXT NOT NULL,"
    "\n      key TEXT NOT NULL,"
    "\n      at INTEGER NOT NULL,"
    "\n      result TEXT NOT NULL,"
    "\n      PRIMARY KEY (kind, key)"
    "\n    );"
    "\n  "
),
    _RECALL_FTS_DDL: str = (
        "\n      CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5("
        "\n        text, content='messages', content_rowid='rowid', tokenize='unicode61'"
        "\n      );"
        "\n    "
    ),
    _RECALL_TRIGGERS_DDL: str = (
        "\n    CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN"
        "\n      INSERT INTO messages_fts(rowid, text) VALUES (new.rowid, new.text);"
        "\n    END;"
        "\n    CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN"
        "\n      INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.rowid, old.text);"
        "\n    END;"
        "\n    CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE ON messages BEGIN"
        "\n      INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.rowid, old.text);"
        "\n      INSERT INTO messages_fts(rowid, text) VALUES (new.rowid, new.text);"
        "\n    END;"
        "\n  "
    ),
    _MEMORY_DDL: str = (
        "\n    CREATE TABLE IF NOT EXISTS memory_files ("
        "\n      bot_id TEXT NOT NULL,"
        "\n      path TEXT NOT NULL,"
        "\n      text TEXT NOT NULL,"
        "\n      mtime_ms INTEGER NOT NULL,"
        "\n      bytes INTEGER NOT NULL,"
        "\n      PRIMARY KEY (bot_id, path)"
        "\n    );"
        "\n    CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5("
        "\n      text, content='memory_files', content_rowid='rowid', tokenize='unicode61'"
        "\n    );"
        "\n    CREATE TRIGGER IF NOT EXISTS memory_fts_ai AFTER INSERT ON memory_files BEGIN"
        "\n      INSERT INTO memory_fts(rowid, text) VALUES (new.rowid, new.text);"
        "\n    END;"
        "\n    CREATE TRIGGER IF NOT EXISTS memory_fts_ad AFTER DELETE ON memory_files BEGIN"
        "\n      INSERT INTO memory_fts(memory_fts, rowid, text) VALUES ('delete', old.rowid, old.text);"
        "\n    END;"
        "\n    CREATE TRIGGER IF NOT EXISTS memory_fts_au AFTER UPDATE ON memory_files BEGIN"
        "\n      INSERT INTO memory_fts(memory_fts, rowid, text) VALUES ('delete', old.rowid, old.text);"
        "\n      INSERT INTO memory_fts(rowid, text) VALUES (new.rowid, new.text);"
        "\n    END;"
        "\n  "
    );


def _ensure_recall_index(db: any) -> None {
    existed = db.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'messages_fts'"
    ).fetchone();
    try {
        db.executescript(_RECALL_FTS_DDL);
    } except Exception as e {
        mapped = describe_missing_fts5(e);
        raise (mapped if mapped is not None else e);
    }
    db.executescript(_RECALL_TRIGGERS_DDL);
    if not existed {
        db.executescript("INSERT INTO messages_fts(messages_fts) VALUES ('rebuild')");
    }
}


def _ensure_memory_index(db: any) -> None {
    db.executescript(_MEMORY_DDL);
}


def open_db -> any {
    os.makedirs(DATA_DIR, mode=0o700, exist_ok=True);
    file = db_file();
    # Transcripts can contain private conversations and tool output: create
    # with owner-only permissions and repair an inherited permissive umask.
    fd = os.open(file, os.O_WRONLY | os.O_CREAT, 0o600);
    os.close(fd);
    try {
        os.chmod(file, 0o600);
    } except OSError {
    }
    conn = sqlite3.connect(file, check_same_thread=False);
    conn.isolation_level = None;  # autocommit: transactions are explicit, as in node
    conn.execute("PRAGMA journal_mode = WAL");
    conn.execute("PRAGMA synchronous = NORMAL");
    conn.executescript(_CORE_DDL);
    _ensure_recall_index(conn);
    _ensure_memory_index(conn);
    return conn;
}


def db -> any {
    # The live handle — reopened when the file was removed out from under
    # us (tests wipe DATA_DIR between cases).
    file = db_file();
    handle = _state["handle"];
    if handle is not None and _state["path"] == file and os.path.exists(file) {
        return handle;
    }
    try {
        if handle is not None {
            handle.close();
        }
    } except Exception {
    }
    handle = open_db();
    _state["handle"] = handle;
    _state["path"] = file;
    return handle;
}


def _txn_depth -> int {
    return getattr(_txn_local, "depth", 0);
}


def transaction(apply: any) -> any {
    # Nested writes use savepoints: even a caught inner error must not
    # commit half of an inner command. The outer transaction owns durability.
    # Per-thread depth — node has one event loop; Python may have many.
    database = db();
    depth = _txn_depth();
    if depth > 0 {
        savepoint = f"command_{depth}";
        database.execute(f"SAVEPOINT {savepoint}");
        _txn_local.depth = depth + 1;
        try {
            result = apply(database);
            database.execute(f"RELEASE {savepoint}");
            return result;
        } except Exception {
            database.execute(f"ROLLBACK TO {savepoint}");
            database.execute(f"RELEASE {savepoint}");
            raise;
        } finally {
            _txn_local.depth = depth;
        }
    }
    database.execute("BEGIN IMMEDIATE");
    _txn_local.depth = 1;
    try {
        result = apply(database);
        database.execute("COMMIT");
        return result;
    } except Exception {
        database.execute("ROLLBACK");
        raise;
    } finally {
        _txn_local.depth = 0;
    }
}


def write_followups(write: any) -> any {
    # A 202/cancel/dispatch claim must reach disk before publishing its
    # result: FULL sync for these small transactions only.
    connection = db();
    connection.execute("PRAGMA synchronous = FULL");
    try {
        connection.execute("BEGIN IMMEDIATE");
        try {
            result = write(connection);
            connection.execute("COMMIT");
            return result;
        } except Exception {
            connection.execute("ROLLBACK");
            raise;
        }
    } finally {
        connection.execute("PRAGMA synchronous = NORMAL");
    }
}


def close_db -> None {
    try {
        if _state["handle"] is not None {
            _state["handle"].close();
        }
    } except Exception {
    }
    _state["handle"] = None;
    _state["path"] = "";
}
