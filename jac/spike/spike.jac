"""Phase-0 runtime spike for the Jac migration.

Proves a long-lived Jac service process can do what server/index.ts does:

  a) serve HTTP with SSE fanout to multiple clients      (def:pub generators)
  b) spawn an engine CLI and stream its stdout            (asyncio subprocess)
  c) hold SQLite state across restarts                    (stdlib sqlite3)
  d) survive a client disconnect mid-stream               (finally unsubscribe)

Endpoints (all :pub, guest-callable, POST /function/<name>):
  health()                     -> {"ok": true, ...}
  start_turn(prompt, cmd)      -> {"turn_id": int}   starts a background turn
  stream(turn_id)              -> SSE: {"type": "line"|"done"|"spawn", ...}
  history()                    -> persisted turns from SQLite

Default engine: `claude -p <prompt> --output-format stream-json --verbose`.
`cmd` overrides with an arbitrary shell string (used by the spike driver to
exercise the plumbing deterministically without spending tokens).
"""

import os;
import json;
import sqlite3;
import asyncio;
import time;
glob _DB_PATH: str = os.environ.get("SPIKE_DB", "spike.db"),
     _subscribers: dict[int, list[any]] = {},
     _turn_tasks: dict[int, any] = {},
     _db_conn: any = None;


# --- persistence: stdlib sqlite3 on the same file format shape as node ------

def _conn -> any {
    if _db_conn is None {
        _db_conn = sqlite3.connect(_DB_PATH, check_same_thread=False);
        _db_conn.execute(
            "CREATE TABLE IF NOT EXISTS turns ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT,"
            "prompt TEXT NOT NULL,"
            "output TEXT NOT NULL DEFAULT '',"
            "rc INTEGER,"
            "created REAL NOT NULL)"
        );
        _db_conn.commit();
    }
    return _db_conn;
}


# --- event bus: per-turn subscriber queues -----------------------------------

def _publish(turn_id: int, ev: dict[str, any]) {
    for q in _subscribers.get(turn_id, []) {
        q.put_nowait(ev);
    }
}


# --- engine driver: spawn CLI, stream stdout lines into the bus --------------

async def _pump_turn(turn_id: int, prompt: str, cmd: str) {
    if cmd {
        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT
        );
    } else {
        proc = await asyncio.create_subprocess_exec(
            "claude", "-p", prompt,
            "--output-format", "stream-json", "--verbose",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT
        );
    }
    _publish(turn_id, {"type": "spawn", "pid": proc.pid});

    collected: list[str] = [];
    try {
        async for raw in proc.stdout {
            line = raw.decode("utf-8", "replace").rstrip("\r\n");
            collected.append(line);
            _publish(turn_id, {"type": "line", "data": line});
        }
    } except Exception as e {
        _publish(turn_id, {"type": "error", "message": str(e)});
    }
    rc = await proc.`wait();

    conn = _conn();
    conn.execute(
        "UPDATE turns SET output = ?, rc = ? WHERE id = ?",
        ("\n".join(collected), rc, turn_id)
    );
    conn.commit();

    _publish(turn_id, {"type": "done", "rc": rc});
    _turn_tasks.pop(turn_id, None);
}


# --- public endpoints ---------------------------------------------------------

def:pub health -> dict[str, any] {
    return {"ok": True, "time": time.time(), "db": os.path.abspath(_DB_PATH)};
}

async def:pub start_turn(prompt: str = "", cmd: str = "") -> dict[str, any] {
    conn = _conn();
    cur = conn.execute(
        "INSERT INTO turns (prompt, output, created) VALUES (?, '', ?)",
        (prompt if prompt else cmd, time.time())
    );
    conn.commit();
    turn_id = cur.lastrowid;
    _turn_tasks[turn_id] = asyncio.create_task(_pump_turn(turn_id, prompt, cmd));
    return {"turn_id": turn_id};
}

async def:pub stream(turn_id: int) -> any {
    # Async generator => the serving layer wraps it as text/event-stream.
    q = asyncio.Queue();
    _subscribers.setdefault(turn_id, []).append(q);
    try {
        yield {"type": "subscribed", "turn_id": turn_id};

        # Late joiner: if the turn already finished, replay its stored output.
        conn = _conn();
        row = conn.execute(
            "SELECT output, rc FROM turns WHERE id = ?", (turn_id,)
        ).fetchone();
        if row and row[1] is not None {
            for line in row[0].split("\n") {
                yield {"type": "line", "data": line, "replay": True};
            }
            yield {"type": "done", "rc": row[1], "replay": True};
            return;
        }

        while True {
            ev = await q.get();
            yield ev;
            if ev.get("type") == "done" {
                return;
            }
        }
    } finally {
        subs = _subscribers.get(turn_id, []);
        if q in subs {
            subs.remove(q);
        }
    }
}

def:pub history -> dict[str, any] {
    conn = _conn();
    rows = conn.execute(
        "SELECT id, prompt, output, rc, created FROM turns ORDER BY id"
    ).fetchall();
    return {
        "turns": [
            {"id": r[0], "prompt": r[1], "output": r[2], "rc": r[3], "created": r[4]}
            for r in rows
        ]
    };
}


# --- OSP touch: one walker + node to prove graph traversal works under serve --

node Marker {
    has note: str;
}

walker:pub mark {
    has note: str = "spike";

    can create with Root entry {
        here ++> Marker(note=self.note);
        report {"markers": len([-->][?:Marker])};
    }
}

