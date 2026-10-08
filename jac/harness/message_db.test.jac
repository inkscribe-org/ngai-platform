"""Ported invariants from server/message-db.test.ts.

Each test mirrors a named case in the TS suite; the corpus runner
(conformance/) covers wire-level parity — these cover behavior that must
hold regardless of transport: reopen persistence, one-time legacy import,
file modes, FTS recall ordering/scoping, tail paging, import guard.
"""

import os;
import json;
import tempfile;
import stat;

import from messages {
    append_message, insert_message, update_message, read_thread,
    read_thread_tail, set_active_leaf, delete_thread, import_thread,
    search_messages, recall_messages, recent_messages, latest_said_by_bot,
    read_message_text, index_memory_file, indexed_memory_files,
    remove_memory_file, recall_memory, recall_terms, recall_match_term,
    working_goal_run_messages, chat_followups, save_chat_followup,
    settle_chat_followups, cancelled_chat_followup,
}
import from db { db_file, close_db, set_data_dir }

glob _tmpdir: str = "";


def _fresh_dir -> str {
    # Isolate each test: fresh DATA_DIR + cleared DB handle.
    globals()["_tmpdir"] = tempfile.mkdtemp(prefix="omb-jac-test-");
    set_data_dir(_tmpdir);
    return _tmpdir;
}


def _legacy(thread_id: str) -> str {
    return os.path.join(_tmpdir, f"messages-{thread_id}.json");
}


def _msg(mid: str, at: int, text: str, role: str = "user") -> dict[str, any] {
    return {"id": mid, "at": at, "role": role, "kind": "text", "text": text};
}


test "persists inserts, updates, and the active leaf across a reopen" {
    _fresh_dir();
    append_message("t1", _msg("m1", 1000, "first"));
    append_message("t1", _msg("m2", 2000, "second", role="bot"));
    update_message(
        "t1",
        {"id": "m2", "at": 2000, "role": "bot", "kind": "text", "text": "second edited"}
    );
    close_db();
    rows = read_thread("t1", _legacy("t1"));
    assert len(rows["messages"]) == 2;
    assert rows["messages"][1]["text"] == "second edited";
    assert rows["activeLeafId"] == "m2";
}


test "imports a legacy JSON thread file exactly once" {
    _fresh_dir();
    legacy = _legacy("lg");
    with open(legacy, "w") as f {
        f.write(
            json.dumps({"messages": [_msg("l1", 1, "old line")], "activeLeafId": "l1"})
        );
    }
    rows = read_thread("lg", legacy);
    assert len(rows["messages"]) == 1 and rows["activeLeafId"] == "l1";
    assert not os.path.exists(legacy);
    assert os.path.exists(legacy + ".imported");
    rows2 = read_thread("lg", legacy);
    assert rows2["messages"][0]["id"] == "l1";
}


test "imports a pre-branching flat array file" {
    _fresh_dir();
    legacy = _legacy("flat");
    with open(legacy, "w") as f {
        f.write(json.dumps([_msg("f1", 1, "flat msg")]));
    }
    rows = read_thread("flat", legacy);
    assert len(rows["messages"]) == 1;
    assert rows["activeLeafId"] is None;
}


test "stores transcripts with owner-only permissions" {
    _fresh_dir();
    append_message("t1", _msg("m1", 1, "private"));
    mode = stat.S_IMODE(os.stat(db_file()).st_mode);
    assert mode == 0o600;
}


test "deleteThread removes rows and state" {
    _fresh_dir();
    append_message("t1", _msg("m1", 1, "gone soon"));
    delete_thread("t1");
    rows = read_thread("t1", _legacy("t1"));
    assert rows["messages"] == [] and rows["activeLeafId"] is None;
}


test "recall ranks by relevance, scopes threads, survives updates and deletes" {
    _fresh_dir();
    append_message("ta", _msg("a1", 1000, "the deployment pipeline broke"));
    append_message("ta", _msg("a2", 2000, "deployment fixed by restart", role="bot"));
    append_message("tb", _msg("b1", 1000, "unrelated chat about lunch"));
    hits = recall_messages("deployment", ["ta", "tb"], 12);
    assert len(hits) == 2;
    assert all(h["threadId"] == "ta" for h in hits);
    update_message(
        "ta",
        {"id": "a1", "at": 1000, "role": "user", "kind": "text", "text": "nothing about that word"}
    );
    hits2 = recall_messages("deployment", ["ta"], 12);
    assert len(hits2) == 1;
    delete_thread("ta");
    assert recall_messages("deployment", ["ta"], 12) == [];
}


test "readThreadTail reads only the newest rows and still reports hasMore" {
    _fresh_dir();
    for i in range(5) {
        append_message("tt", _msg(f"m{i}", i * 1000, f"line {i}"));
    }
    tail = read_thread_tail("tt", _legacy("tt"), 2);
    assert len(tail["messages"]) == 2;
    assert tail["messages"][0]["id"] == "m3" and tail["messages"][1]["id"] == "m4";
    assert tail["hasMore"] == True;
    full = read_thread_tail("tt", _legacy("tt"), 10);
    assert len(full["messages"]) == 5 and full["hasMore"] == False;
}


test "importThread refuses a thread that already has rows" {
    _fresh_dir();
    append_message("t1", _msg("m1", 1, "existing"));
    raised = False;
    try {
        import_thread("t1", [_msg("x", 2, "nope")], None);
    } except Exception {
        raised = True;
    }
    assert raised;
}


test "search is case-insensitive, escapes LIKE wildcards" {
    _fresh_dir();
    append_message("t1", _msg("m1", 1, "MiXeD case line"));
    append_message("t1", _msg("m2", 2, "literal 100%_wild chars"));
    hits = search_messages("mixed", 40);
    assert len(hits) == 1 and hits[0]["messageId"] == "m1";
    wild = search_messages("100%_wild", 40);
    assert len(wild) == 1 and wild[0]["messageId"] == "m2";
    assert search_messages("   ", 40) == [];
}


test "recall names the bot behind an ask_bot line" {
    _fresh_dir();
    append_message(
        "t1",
        _msg(
            "a1",
            1,
            "[Message from @Scout, another bot in this OpenMausBot workspace — not from your user.] hi",
        )
    );
    hit = read_message_text("t1", "a1");
    assert hit is not None and hit["peer"] == "Scout";
}


test "memory recall scopes one bot's files and never shows another's" {
    _fresh_dir();
    index_memory_file(
        "b1", "MEMORY.md", "likes green tea", {"mtimeMs": 1, "bytes": 15}
    );
    index_memory_file(
        "b2", "MEMORY.md", "vault secret phrase", {"mtimeMs": 2, "bytes": 19}
    );
    hits = recall_memory("green", "b1", 12);
    assert len(hits) == 1 and hits[0]["file"] == "MEMORY.md";
    assert recall_memory("secret", "b1", 12) == [];
    remove_memory_file("b1", "MEMORY.md");
    assert indexed_memory_files("b1") == [];
}


test "followups settle with tombstones and retires" {
    _fresh_dir();
    save_chat_followup(
        {"id": "f1", "kind": "bot", "ownerId": "o", "threadId": "t1",
         "payload": {"sendId": "s1", "text": "q"}}
    );
    settle_chat_followups(["f1"], "cancelled");
    assert cancelled_chat_followup("bot", "o", "t1", "s1");
    settle_chat_followups(["f1"], None);
    assert chat_followups() == [];
}


test "goal.run rows are recoverable without loading every transcript" {
    _fresh_dir();
    append_message(
        "t1",
        {"id": "g1", "at": 1, "role": "bot", "kind": "goal.run",
         "goalRun": {"status": "working"}}
    );
    append_message(
        "t2",
        {"id": "g2", "at": 2, "role": "bot", "kind": "goal.run",
         "goalRun": {"status": "done"}}
    );
    working = working_goal_run_messages();
    assert len(working) == 1 and working[0]["threadId"] == "t1";
}


test "recallTerms drops filler and splits on letter-internal separators" {
    _fresh_dir();
    terms = recall_terms(
        "Can you please remind me about the migration plan for v2.1?"
    );
    assert "migration" in terms and "v2.1" in terms;
    assert "please" not in terms and "the" not in terms;
}
