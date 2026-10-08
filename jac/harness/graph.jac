"""OSP graph layer over the transcript tables.

SQLite remains the durable store (seam rule: same files, byte-identical
rows). Nodes materialize lazily: a Thread is created under root the first
time it is read, its Messages chained in rowid order via Next edges, so
walkers traverse a transcript as a graph — [t -->][?:Message] then
[--> +:Next:+>] — instead of looping over a row list. Writes go through
messages.jac's SQL first and the graph is rebuilt after, so the in-memory
view never runs ahead of the database.
"""

import json;

import from messages {
    read_thread,
    append_message,
}

node Thread {
    has thread_id: str,
        active_leaf_id: (str | None) = None;
}

node Message {
    has message_id: str,
        at: int = 0,
        role: str = "",
        kind: str = "",
        has_text: bool = False;
}

node Bot {
    has bot_id: str;
}

node MemoryFile {
    has path: str,
        mtime_ms: int = 0,
        bytes: int = 0;
}

edge Next {}
edge Contains {}
edge Authored {}
edge Indexes {}


def thread_node(thread_id: str) -> Thread {
    # The Thread node for `thread_id`, created under root if absent.
    matches = [root -->][?:Thread][?thread_id == thread_id];
    if matches {
        return matches[0];
    }
    t = Thread(thread_id=thread_id);
    root ++> t;
    return t;
}


def bot_node(bot_id: str) -> Bot {
    matches = [root -->][?:Bot][?bot_id == bot_id];
    if matches {
        return matches[0];
    }
    b = Bot(bot_id=bot_id);
    root ++> b;
    return b;
}


def hydrate_thread(thread_id: str, legacy_file: str) -> Thread {
    # (Re)materialize one thread's transcript: Thread -Contains-> first
    # Message, then Message -Next-> Message in rowid order. Idempotent —
    # existing Message nodes for the thread are removed and rebuilt from
    # SQL so the graph never shows a stale transcript.
    t = thread_node(thread_id);
    for old in [t -->][?:Message] {
        del old;
    }
    # Chained off the first Message; rebuilt below, so also drop any that
    # survived a partial prior hydrate.
    for head in [t ->:Contains:->][?:Message] {
        cur: (Message | None) = head;
        while cur is not None {
            nxts = [cur ->:Next:->][?:Message];
            del cur;
            cur = nxts[0] if nxts else None;
        }
    }
    rows = read_thread(thread_id, legacy_file);
    t.active_leaf_id = rows["activeLeafId"];
    prev: (Message | None) = None;
    for m in rows["messages"] {
        mnode = Message(
            message_id=m["id"],
            at=m["at"],
            role=m["role"],
            kind=m["kind"],
            has_text=m.get("text") is not None,
        );
        if prev is None {
            t +>:Contains:+> mnode;
        } else {
            prev +>:Next:+> mnode;
        }
        prev = mnode;
    }
    return t;
}


def thread_messages_ordered(t: Thread) -> list[Message] {
    # Walk the Next chain; the canonical transcript order.
    out: list[Message] = [];
    heads = [t ->:Contains:->][?:Message];
    if not heads {
        return out;
    }
    cur: (Message | None) = heads[0];
    while cur is not None {
        out.append(cur);
        nxts = [cur ->:Next:->][?:Message];
        cur = nxts[0] if nxts else None;
    }
    return out;
}


walker RefreshThread {
    # (Re)materialize a thread's message chain from SQLite.
    has thread_id: str,
        legacy_file: str = "";

    can go with Root entry {
        t = hydrate_thread(self.thread_id, self.legacy_file);
        report {
            "thread_id": self.thread_id,
            "messages": len(thread_messages_ordered(t)),
            "active_leaf_id": t.active_leaf_id,
        };
    }
}


walker AppendToThread {
    # Persist a message (SQL first), then grow the graph to match.
    has thread_id: str,
        message: dict[str, any],
        legacy_file: str = "";

    can go with Root entry {
        append_message(self.thread_id, self.message);
        t = hydrate_thread(self.thread_id, self.legacy_file);
        report {
            "thread_id": self.thread_id,
            "messages": len(thread_messages_ordered(t)),
            "active_leaf_id": t.active_leaf_id,
        };
    }
}
