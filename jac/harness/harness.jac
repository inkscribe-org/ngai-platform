"""Jac harness — phase 1: the OSP data layer over ~/.openmausbot.

Endpoints mirror server/message-db.ts's exported operations so the
conformance corpus can drive identical call sequences against both
harnesses and diff the resulting SQLite bytes.

POST /function/<name> with a JSON body of kwargs. All guest-callable for
now, matching the spike; auth lands with the session port.
"""

import os;
import json;

import from db { db, db_file, DATA_DIR, close_db }
import from messages {
    insert_message, append_message, update_message, import_thread,
    read_thread, read_thread_tail, set_active_leaf, delete_thread,
    latest_message_ats, threads_referencing, search_messages,
    recall_messages, recent_messages, latest_said_by_bot,
    read_message_text, working_goal_run_messages,
    read_command_receipt, save_chat_followup, settle_chat_followups,
    chat_followups, cancelled_chat_followup,
    index_memory_file, remove_memory_file, indexed_memory_files,
    recall_memory, recall_terms, recall_match_term,
}
import from graph { RefreshThread, AppendToThread, thread_messages_ordered }
import from graph { hydrate_thread, thread_node }


def _legacy_file(thread_id: str) -> str {
    return os.path.join(DATA_DIR, f"messages-{thread_id}.json");
}

def:pub health -> dict[str, any] {
    return {"ok": True, "db": os.path.abspath(db_file()), "data_dir": DATA_DIR};
}


def:pub op_append_message(thread_id: str, message: dict[str, any]) -> dict[str, any] {
    append_message(thread_id, message);
    return {"ok": True};
}


def:pub op_insert_message(thread_id: str, message: dict[str, any]) -> dict[str, any] {
    insert_message(thread_id, message);
    return {"ok": True};
}


def:pub op_update_message(thread_id: str, message: dict[str, any]) -> dict[str, any] {
    update_message(thread_id, message);
    return {"ok": True};
}


def:pub op_import_thread(
    thread_id: str, messages: list[any], active_leaf_id: (str | None) = None
) -> dict[str, any] {
    import_thread(thread_id, messages, active_leaf_id);
    return {"ok": True};
}


def:pub op_read_thread(thread_id: str) -> dict[str, any] {
    return read_thread(thread_id, _legacy_file(thread_id));
}


def:pub op_read_thread_tail(thread_id: str, limit: int) -> dict[str, any] {
    return read_thread_tail(thread_id, _legacy_file(thread_id), limit);
}


def:pub op_set_active_leaf(thread_id: str, leaf_id: (str | None) = None) -> dict[str, any] {
    set_active_leaf(thread_id, leaf_id);
    return {"ok": True};
}


def:pub op_delete_thread(thread_id: str) -> dict[str, any] {
    delete_thread(thread_id);
    return {"ok": True};
}


def:pub op_latest_message_ats(thread_ids: list[any]) -> dict[str, any] {
    return {"ats": latest_message_ats(thread_ids)};
}


def:pub op_threads_referencing(fragment: str) -> dict[str, any] {
    return {"threads": threads_referencing(fragment)};
}


def:pub op_search_messages(
    query: str, limit: int = 40, thread_id: (str | None) = None
) -> dict[str, any] {
    return {"hits": search_messages(query, limit, thread_id)};
}


def:pub op_recall_messages(
    query: str,
    thread_ids: list[any],
    limit: int = 12,
    range_: (dict[str, any] | None) = None,
    mode: str = "all"
) -> dict[str, any] {
    return {"hits": recall_messages(query, thread_ids, limit, range_, mode)};
}


def:pub op_recent_messages(
    thread_ids: list[any], range_: dict[str, any], limit: int = 12
) -> dict[str, any] {
    return {"hits": recent_messages(thread_ids, range_, limit)};
}


def:pub op_latest_said_by_bot(
    thread_ids: list[any], bot_id: str, since: int, limit: int = 20
) -> dict[str, any] {
    return {"latest": latest_said_by_bot(thread_ids, bot_id, since, limit)};
}


def:pub op_read_message_text(thread_id: str, message_id: str) -> dict[str, any] {
    return {"row": read_message_text(thread_id, message_id)};
}


def:pub op_working_goal_run_messages -> dict[str, any] {
    return {"goals": working_goal_run_messages()};
}


def:pub op_read_command_receipt(kind: str, key: str) -> dict[str, any] {
    return {"receipt": read_command_receipt(kind, key)};
}


def:pub op_save_chat_followup(followup: dict[str, any]) -> dict[str, any] {
    save_chat_followup(followup);
    return {"ok": True};
}


def:pub op_settle_chat_followups(ids: list[any], status: (str | None) = None) -> dict[str, any] {
    settle_chat_followups(ids, status);
    return {"ok": True};
}


def:pub op_chat_followups(kind: (str | None) = None) -> dict[str, any] {
    return {"followups": chat_followups(kind)};
}


def:pub op_cancelled_chat_followup(
    kind: str, owner_id: str, thread_id: str, send_id: str
) -> dict[str, any] {
    return {"cancelled": cancelled_chat_followup(kind, owner_id, thread_id, send_id)};
}


def:pub op_index_memory_file(
    bot_id: str, path: str, text: str, stat: dict[str, any]
) -> dict[str, any] {
    index_memory_file(bot_id, path, text, stat);
    return {"ok": True};
}


def:pub op_remove_memory_file(bot_id: str, path: str) -> dict[str, any] {
    remove_memory_file(bot_id, path);
    return {"ok": True};
}


def:pub op_indexed_memory_files(bot_id: str) -> dict[str, any] {
    return {"files": indexed_memory_files(bot_id)};
}


def:pub op_recall_memory(
    query: str, bot_id: str, limit: int = 12, mode: str = "all"
) -> dict[str, any] {
    return {"hits": recall_memory(query, bot_id, limit, mode)};
}


def:pub op_recall_terms(query: str) -> dict[str, any] {
    return {"terms": recall_terms(query)};
}


def:pub op_recall_match_term(term: str) -> dict[str, any] {
    return {"term": recall_match_term(term)};
}


def:pub op_close_db -> dict[str, any] {
    close_db();
    return {"ok": True};
}


walker:pub refresh_thread {
    has thread_id: str;

    can go with Root entry {
        t = hydrate_thread(self.thread_id, _legacy_file(self.thread_id));
        report {
            "thread_id": self.thread_id,
            "messages": len(thread_messages_ordered(t)),
            "active_leaf_id": t.active_leaf_id,
        };
    }
}


def:pub echo_opt_probe(thread_id: (str | None) = None, range_: (dict[str, any] | None) = None, mode: str = "all") -> dict[str, any] {
    return {
        "thread_id": repr(thread_id),
        "range_": repr(range_),
        "mode": repr(mode),
    };
}
