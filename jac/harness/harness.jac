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


# --- routines module HTTP surface ---------------------------------------------
# jac run mounts only the entry module's defs; re-bind every routines.jac
# def:pub under the entry module so POST /function/<name> resolves. The
# endpoint signatures come from the defs themselves; globs carry the binding.
import from routines {
    routine_boot as _routines_routine_boot,
    routine_set_now as _routines_routine_set_now,
    routine_tick as _routines_routine_tick,
    routine_reset as _routines_routine_reset,
    routine_pause as _routines_routine_pause,
    routine_resume as _routines_routine_resume,
    routine_state as _routines_routine_state,
    routine_list as _routines_routine_list,
    routine_package_stamps as _routines_routine_package_stamps,
    routine_stamp_installed_package as _routines_routine_stamp_installed_package,
    routine_list_runs as _routines_routine_list_runs,
    routine_wake_hold as _routines_routine_wake_hold,
    routine_active_run_for_bot as _routines_routine_active_run_for_bot,
    routine_active_bot_run_for_bot as _routines_routine_active_bot_run_for_bot,
    routine_is_active_thread as _routines_routine_is_active_thread,
    routine_run_for_thread as _routines_routine_run_for_thread,
    routine_create as _routines_routine_create,
    routine_update as _routines_routine_update,
    routine_remove as _routines_routine_remove,
    routine_run_now as _routines_routine_run_now,
    routine_cancel_run as _routines_routine_cancel_run,
    routine_mark_seen as _routines_routine_mark_seen,
    routine_mark_all_seen as _routines_routine_mark_all_seen,
    routine_disable_for_bot as _routines_routine_disable_for_bot,
    routine_disable_for_group as _routines_routine_disable_for_group,
    routine_enqueue_webhook as _routines_routine_enqueue_webhook,
    routine_webhook_run_receipt as _routines_routine_webhook_run_receipt,
    routine_active_webhook_run_count as _routines_routine_active_webhook_run_count,
    routine_cancel_queued_webhook as _routines_routine_cancel_queued_webhook,
    routine_runtime_event as _routines_routine_runtime_event,
    routine_fail_thread as _routines_routine_fail_thread,
    routine_finish_goal_run as _routines_routine_finish_goal_run,
    routine_receipt as _routines_routine_receipt,
    routine_receipt_owners as _routines_routine_receipt_owners,
    routine_forget_receipt as _routines_routine_forget_receipt,
    routine_forget_receipts_for_thread as _routines_routine_forget_receipts_for_thread,
    routine_reconcile_receipts as _routines_routine_reconcile_receipts,
    routine_next_occurrence as _routines_routine_next_occurrence,
    routines_tick as _routines_routines_tick,
}
glob routine_boot: any = _routines_routine_boot;
glob routine_set_now: any = _routines_routine_set_now;
glob routine_tick: any = _routines_routine_tick;
glob routine_reset: any = _routines_routine_reset;
glob routine_pause: any = _routines_routine_pause;
glob routine_resume: any = _routines_routine_resume;
glob routine_state: any = _routines_routine_state;
glob routine_list: any = _routines_routine_list;
glob routine_package_stamps: any = _routines_routine_package_stamps;
glob routine_stamp_installed_package: any = _routines_routine_stamp_installed_package;
glob routine_list_runs: any = _routines_routine_list_runs;
glob routine_wake_hold: any = _routines_routine_wake_hold;
glob routine_active_run_for_bot: any = _routines_routine_active_run_for_bot;
glob routine_active_bot_run_for_bot: any = _routines_routine_active_bot_run_for_bot;
glob routine_is_active_thread: any = _routines_routine_is_active_thread;
glob routine_run_for_thread: any = _routines_routine_run_for_thread;
glob routine_create: any = _routines_routine_create;
glob routine_update: any = _routines_routine_update;
glob routine_remove: any = _routines_routine_remove;
glob routine_run_now: any = _routines_routine_run_now;
glob routine_cancel_run: any = _routines_routine_cancel_run;
glob routine_mark_seen: any = _routines_routine_mark_seen;
glob routine_mark_all_seen: any = _routines_routine_mark_all_seen;
glob routine_disable_for_bot: any = _routines_routine_disable_for_bot;
glob routine_disable_for_group: any = _routines_routine_disable_for_group;
glob routine_enqueue_webhook: any = _routines_routine_enqueue_webhook;
glob routine_webhook_run_receipt: any = _routines_routine_webhook_run_receipt;
glob routine_active_webhook_run_count: any = _routines_routine_active_webhook_run_count;
glob routine_cancel_queued_webhook: any = _routines_routine_cancel_queued_webhook;
glob routine_runtime_event: any = _routines_routine_runtime_event;
glob routine_fail_thread: any = _routines_routine_fail_thread;
glob routine_finish_goal_run: any = _routines_routine_finish_goal_run;
glob routine_receipt: any = _routines_routine_receipt;
glob routine_receipt_owners: any = _routines_routine_receipt_owners;
glob routine_forget_receipt: any = _routines_routine_forget_receipt;
glob routine_forget_receipts_for_thread: any = _routines_routine_forget_receipts_for_thread;
glob routine_reconcile_receipts: any = _routines_routine_reconcile_receipts;
glob routine_next_occurrence: any = _routines_routine_next_occurrence;
glob routines_tick: any = _routines_routines_tick;
