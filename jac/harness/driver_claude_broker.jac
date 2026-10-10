"""The per-turn permission broker for the Claude driver — the Jac port of
server/drivers/claude.ts's createPermissionBroker.

A headless run that hits a permission acceptEdits doesn't cover should
neither stall silently NOR get blanket-denied — it asks the user. The broker
is a unix-socket server on a per-turn path; the proxy the claude CLI spawns
(server/permission-proxy.ts, unchanged node code) forwards asks over it and
waits. Unanswered permission asks deny after timeoutMs with a keep-moving
note; unanswered questions answer with "use your best judgment"."""

import os;
import json;
import socket;
import stat;
import threading;
import time;

def new_broker_ask_id() -> str {
    import uuid;
    return str(uuid.uuid4());
}

glob DENY_TIMEOUT_NOTE: str = "OpenMausBot: nobody answered this permission request in time. Skip this action and finish what you can without it.";
glob QUESTION_TIMEOUT_NOTE: str = "OpenMausBot: nobody answered in time. Use your best judgment and continue.";
glob DUPLICATE_ASK_ID_NOTE: str = "OpenMausBot: duplicate ask id — skipping this request.";

def system_ended_reply(kind: str) -> dict[str, any] {
    # The system-source reply for an ask that outlives the turn — used both
    # to drain in-flight pending asks on close() and to answer one that
    # arrives on an already-closed broker.
    if kind == "question" {
        return {"behavior": "answer", "message": "OpenMausBot: the turn is ending — wrap up."};
    }
    return {"behavior": "deny", "message": "OpenMausBot: the turn ended"};
}

def _send_line(conn: any, payload_obj: dict[str, any], wlock: any) {
    payload = (json.dumps(payload_obj) + "\n").encode("utf-8");
    try {
        wlock.acquire();
        try {
            conn.sendall(payload);
        } finally {
            wlock.release();
        }
    } except Exception {
    }
}

def create_permission_broker(
    socket_paths: list[any],
    on_ask: any,
    on_resolve: any,
    is_active: any = None,
    timeout_ms: any = None
) -> dict[str, any] {
    # Bind the first candidate that will take a listener. A broker that never
    # came up used to be silent — every approval then timed out into a deny
    # nobody could explain. Keep the turn fail-closed on total failure.
    if timeout_ms is None { timeout_ms = 15 * 60000; }
    st: dict[str, any] = {
        "closed": False,
        "bound": socket_paths[0] if socket_paths else "",
        "pending": {},   # ask id -> {ask, finish, timer, conn}
        "wlock": threading.RLock(),
        "lock": threading.RLock(),
        "server": None,
    };

    def _finish(ask_id: str, behavior: str, message: any, source: str, always: any = None) {
        p = None;
        st["lock"].acquire();
        try {
            p = st["pending"].pop(ask_id, None);
        } finally {
            st["lock"].release();
        }
        if p is None { return; }
        timer = p.get("timer");
        if timer is not None {
            try {
                timer.cancel();
            } except Exception {
            }
        }
        reply: dict[str, any] = {"t": "answer", "id": ask_id, "behavior": behavior};
        if message is not None { reply["message"] = message; }
        reply["source"] = source;
        # `always` rides to the proxy, which hands the CLI's own suggested
        # permission rules back as updatedPermissions: Claude remembers the
        # allow for the session, the harness remembers nothing.
        if always { reply["always"] = True; }
        _send_line(p["conn"], reply, st["wlock"]);
        if on_resolve is not None {
            resolved = dict(p["ask"]);
            resolved["behavior"] = behavior;
            resolved["source"] = source;
            try {
                on_resolve(resolved);
            } except Exception {
            }
        }
    }

    def _timeout_fire(ask_id: str, kind: str) {
        if kind == "question" {
            _finish(ask_id, "answer", QUESTION_TIMEOUT_NOTE, "timeout");
        } else {
            _finish(ask_id, "deny", DENY_TIMEOUT_NOTE, "timeout");
        }
    }

    def _handle_message(conn: any, msg: dict[str, any]) {
        if msg.get("t") != "ask" { return; }
        ask_id = msg.get("id");
        ask_id = str(ask_id) if ask_id is not None else new_broker_ask_id();
        kind = "question" if msg.get("kind") == "question" else "permission";
        # Closure is terminal and takes precedence over every active-turn
        # rule, including duplicate-id rejection. Never register a pending
        # entry or notify onAsk, but always answer an existing connection:
        # the proxy only resolves on an explicit answer (or a connection
        # error/close), so a silent drop would hang the tool.
        if st["closed"] {
            reply = system_ended_reply(kind);
            out = {"t": "answer", "id": ask_id, "behavior": reply["behavior"], "message": reply["message"], "source": "system"};
            _send_line(conn, out, st["wlock"]);
            return;
        }
        # A retained Claude process keeps its proxy connection between turns.
        # Late/background asks must still fail closed without opening a card
        # for a turn that has already settled.
        if is_active is not None {
            try {
                active = bool(is_active());
            } except Exception {
                active = False;
            }
            if not active {
                reply = system_ended_reply(kind);
                out = {"t": "answer", "id": ask_id, "behavior": reply["behavior"], "message": reply["message"], "source": "system"};
                _send_line(conn, out, st["wlock"]);
                return;
            }
        }
        # `pending` is server-scoped, not per-connection: two asks with the
        # same id — a buggy/adversarial client, never a legitimate retry —
        # would otherwise let the second silently overwrite the first,
        # orphaning it as an unanswerable card once the first resolves.
        st["lock"].acquire();
        try {
            if ask_id in st["pending"] {
                duplicate = True;
            } else {
                duplicate = False;
                ask: dict[str, any] = {
                    "id": ask_id,
                    "kind": kind,
                    "tool": msg.get("tool") if msg.get("tool") is not None else "tool",
                    "input": msg.get("input") if isinstance(msg.get("input"), dict) else {},
                    "at": int(time.time() * 1000),
                };
                record: dict[str, any] = {"ask": ask, "conn": conn, "timer": None};
                st["pending"][ask_id] = record;
            }
        } finally {
            st["lock"].release();
        }
        if duplicate {
            _send_line(conn, {"t": "answer", "id": ask_id, "behavior": "deny", "message": DUPLICATE_ASK_ID_NOTE}, st["wlock"]);
            return;
        }
        timer = threading.Timer(timeout_ms / 1000.0, _timeout_fire, args=(ask_id, kind));
        timer.daemon = True;
        st["lock"].acquire();
        try {
            if ask_id in st["pending"] { st["pending"][ask_id]["timer"] = timer; }
        } finally {
            st["lock"].release();
        }
        timer.start();
        if on_ask is not None {
            try {
                on_ask(ask);
            } except Exception {
            }
        }
    }

    def _handle_conn(conn: any) {
        # An ask carries the whole tool input (a Write's file content), so
        # one line may span many reads; a text-mode file wrapper decodes
        # utf-8 across chunk boundaries.
        try {
            f = conn.makefile("r", encoding="utf-8", errors="replace", newline="\n");
            for line in f {
                line = line.strip();
                if not line { continue; }
                try {
                    msg = json.loads(line);
                } except Exception {
                    continue;
                }
                if isinstance(msg, dict) { _handle_message(conn, msg); }
            }
        } except Exception {
        } finally {
            # Peer hung up (EOF): nothing more can be answered on this conn.
            try { conn.close(); } except Exception { }
        }
    }

    def _accept_loop() {
        while True {
            try {
                pair = st["server"].accept();
            } except Exception {
                break;
            }
            conn = pair[0];
            t = threading.Thread(target=_handle_conn, args=(conn,), daemon=True);
            t.start();
        }
    }

    server: any = None;
    bound_path = st["bound"];
    count = len(socket_paths);
    for index in range(count) {
        candidate = socket_paths[index];
        attempt = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM);
        try {
            os.unlink(candidate);
        } except Exception {
        }
        try {
            attempt.bind(candidate);
            attempt.listen(8);
        } except Exception {
            try {
                attempt.close();
            } except Exception {
            }
            if index == count - 1 {
                raise RuntimeError("claude: permission broker could not bind a local socket");
            }
            continue;
        }
        # A fallback under the shared OS temp root must not be connectable by
        # another local account; applying 0600 to every POSIX socket keeps
        # the rule simple and fail-closed.
        try {
            os.chmod(candidate, stat.S_IRUSR | stat.S_IWUSR);
        } except Exception {
            try {
                attempt.close();
            } except Exception {
            }
            try {
                os.unlink(candidate);
            } except Exception {
            }
            if index == count - 1 {
                raise RuntimeError("claude: permission broker could not bind a local socket");
            }
            continue;
        }
        server = attempt;
        bound_path = candidate;
        break;
    }
    if server is None {
        raise RuntimeError("claude: permission broker could not bind a local socket");
    }
    st["server"] = server;
    st["bound"] = bound_path;
    accept_thread = threading.Thread(target=_accept_loop, daemon=True);
    accept_thread.start();

    def broker_answer(ask_id: str, behavior: str, message: any = None, always: any = None) -> bool {
        st["lock"].acquire();
        try {
            p = st["pending"].get(ask_id);
            if p is None { return False; }
            kind = p["ask"]["kind"];
            if kind == "question" and behavior != "answer" { return False; }
            if kind != "question" and behavior == "answer" { return False; }
        } finally {
            st["lock"].release();
        }
        _finish(ask_id, behavior, message, "user", always and behavior == "allow");
        return True;
    }

    def drain() {
        # Resolve every ask still open, keeping the broker listening for the
        # next turn on the retained process.
        st["lock"].acquire();
        try {
            ids = list(st["pending"].keys());
        } finally {
            st["lock"].release();
        }
        for ask_id in ids {
            st["lock"].acquire();
            try {
                kind = st["pending"].get(ask_id, {}).get("ask", {}).get("kind", "permission");
            } finally {
                st["lock"].release();
            }
            reply = system_ended_reply(kind);
            _finish(ask_id, reply["behavior"], reply["message"], "system");
        }
    }

    def broker_close() {
        st["closed"] = True;
        drain();
        # close() alone does not wake a blocked accept() on Linux.
        try { server.shutdown(socket.SHUT_RDWR); } except Exception { }
        try {
            server.close();
        } except Exception {
        }
        try {
            os.unlink(bound_path);
        } except Exception {
        }
    }

    return {
        # Where the broker actually listens — argv for the proxy child must
        # use this, not the deterministic base, when a fallback was bound.
        "socket_path": bound_path,
        "answer": broker_answer,
        "pause": drain,
        "close": broker_close,
        "_state": st,
    };
}
