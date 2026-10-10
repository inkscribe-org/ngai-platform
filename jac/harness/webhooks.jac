"""WebhookManager port - the webhooks subsystem on Jac (phase 4).

Faithful port of server/webhooks.ts. webhooks.json keeps the same shape
(JSON.stringify(_, null, 2), mode 0600), validation errors keep zod 4's
first-issue text, and every option callback the TS manager took is a hook
in `_wh["hooks"]`:

  bot_state / post / resolve_post_thread  -> node bridge ops
  enqueue / find_run / cancel_queued / pending_runs -> routines.jac,
      in-process (the run queue already lives in this harness)
  emit -> routines' emit bridge op (mirror + SSE broadcast node-side)

Tests swap the whole table via webhooks_set_hooks; None for post or
resolve_post_thread models a host without that sink.
"""

import os;
import json;
import uuid;
import hmac;
import time;
import hashlib;
import secrets;

import from db { DATA_DIR }
import from jsutil { js_stringify }
import from common {
    status_error,
    status_of as _status_of,
    invoke as _invoke,
    js_pretty as _js_pretty,
    iso_from_ms as _iso,
    write_json_private,
}
import from routines {
    _bridge,
    _bot_state,
    _emit,
    _ensure_booted,
    _enqueue_webhook,
    _webhook_run_receipt,
    _active_webhook_run_count,
    _cancel_queued_webhook,
}

glob MAX_DELIVERIES: int = 2000;
glob MAX_ATTEMPTS: int = 2000;
glob MAX_EVENT_CHARS: int = 48000;
glob RATE_WINDOW_MS: int = 60000;
glob RATE_LIMIT: int = 10;
glob UNAUTHORIZED_REASON: str = "Invalid webhook URL or secret";
glob DEFAULT_MAX_PENDING_RUNS: int = 3;
glob MAX_PENDING_RUNS_LIMIT: int = 50;
glob RUN_ON_VALUES: list[str] = ["maus", "cloud"];
glob DELIVERY_VALUES: list[str] = ["run", "post"];
glob SECRET_HASH_LEN: int = 64;

glob _wh: dict[str, any] = {};

def _reset -> None {
    _wh.update({
        "file": None,
        "now_ms": None,
        "loaded": False,
        "webhooks": [],
        "deliveries": [],
        "attempts": [],
        "rate": {},
        "unauthorized": {},
        "hooks": _default_hooks(),
    });
}

def _fail(status: int, message: str) {
    raise status_error(message, status);
}

def _now -> int {
    v = _wh.get("now_ms");
    if v is not None { return int(v); }
    return int(time.time() * 1000);
}

def _file_path -> str {
    f = _wh.get("file");
    if f is None {
        f = os.path.join(DATA_DIR, "webhooks.json");
        _wh.update({"file": f});
    }
    return f;
}

# ── default hooks (production wiring) ──────────────────────────────────────

def _hook_enqueue(input: dict[str, any]) -> dict[str, any] {
    _ensure_booted();
    return _enqueue_webhook(input);
}

def _hook_find_run(webhook_id: str, delivery_id: str) -> any {
    _ensure_booted();
    return _webhook_run_receipt(webhook_id, delivery_id);
}

def _hook_cancel_queued(webhook_id: str, message: str) {
    _ensure_booted();
    _cancel_queued_webhook(webhook_id, message);
}

def _hook_pending_runs(webhook_id: str) -> int {
    _ensure_booted();
    return _active_webhook_run_count(webhook_id);
}

def _hook_post(bot_id: str, thread_id: str, text: str) {
    _bridge("webhook_post", {"bot_id": bot_id, "thread_id": thread_id, "text": text});
}

def _hook_resolve_post_thread(trigger: dict[str, any], force_new: bool) -> any {
    res = _bridge("webhook_post_thread", {
        "bot_id": trigger["botId"],
        "results_thread_id": trigger.get("resultsThreadId"),
        "force_new": force_new,
    });
    tid = res.get("threadId") or res.get("thread_id");
    return tid if isinstance(tid, str) and tid else None;
}

def _default_hooks -> dict[str, any] {
    return {
        "bot_state": _bot_state,
        "enqueue": _hook_enqueue,
        "find_run": _hook_find_run,
        "cancel_queued": _hook_cancel_queued,
        "pending_runs": _hook_pending_runs,
        "post": _hook_post,
        "resolve_post_thread": _hook_resolve_post_thread,
        "emit": _emit,
    };
}

def _hook(name: str) -> any {
    return _wh["hooks"].get(name);
}

def _emit_event(payload: dict[str, any]) {
    emit = _hook("emit");
    if emit is not None { emit(payload); }
}

# ── zod-faithful validation (first issue, schema key order) ────────────────

def _js_type(v: any) -> str {
    if v is None { return "null"; }
    if isinstance(v, bool) { return "boolean"; }
    if isinstance(v, (int, float)) { return "number"; }
    if isinstance(v, str) { return "string"; }
    if isinstance(v, list) { return "array"; }
    return "object";
}

def _issue(path: str, message: str) {
    _fail(400, (path + " " + message) if path else message);
}

def _expect(path: str, want: str, v: any) {
    _expect_got(path, want, _js_type(v));
}

def _expect_got(path: str, want: str, got: str) {
    _issue(path, "Invalid input: expected " + want + ", received " + got);
}

def _check_str(rec: dict[str, any], key: str, required: bool) {
    if key not in rec {
        if required { _expect_got(key, "string", "undefined"); }
        return;
    }
    if not isinstance(rec[key], str) { _expect(key, "string", rec[key]); }
}

def _check_bool(rec: dict[str, any], key: str) {
    if key in rec and not isinstance(rec[key], bool) { _expect(key, "boolean", rec[key]); }
}

def _check_enum(rec: dict[str, any], key: str, values: list[str]) {
    if key in rec and rec[key] not in values {
        _issue(key, "Invalid option: expected one of " + "|".join([js_stringify(v) for v in values]));
    }
}

def _check_event_types(rec: dict[str, any]) {
    if "eventTypes" not in rec { return; }
    v = rec["eventTypes"];
    if not isinstance(v, list) { _expect("eventTypes", "array", v); }
    for (i, item) in enumerate(v) {
        if not isinstance(item, str) { _expect("eventTypes." + str(i), "string", item); }
    }
    if len(v) > 20 { _issue("eventTypes", "Too big: expected array to have <=20 items"); }
}

def _is_int_number(v: any) -> bool {
    if isinstance(v, bool) { return False; }
    if isinstance(v, int) { return True; }
    return isinstance(v, float) and v.is_integer();
}

def _check_max_pending(rec: dict[str, any]) {
    if "maxPendingRuns" not in rec or rec["maxPendingRuns"] is None { return; }
    v = rec["maxPendingRuns"];
    if isinstance(v, bool) or not isinstance(v, (int, float)) { _expect("maxPendingRuns", "number", v); }
    if not _is_int_number(v) { _expect("maxPendingRuns", "int", v); }
    if v < 1 { _issue("maxPendingRuns", "Too small: expected number to be >=1"); }
    if v > MAX_PENDING_RUNS_LIMIT { _issue("maxPendingRuns", "Too big: expected number to be <=50"); }
}

def _parse_trigger(value: any, partial: bool) -> dict[str, any] {
    if not isinstance(value, dict) { _expect("", "object", value); }
    _check_str(value, "name", not partial);
    _check_str(value, "prompt", not partial);
    _check_str(value, "botId", not partial);
    _check_enum(value, "runOn", RUN_ON_VALUES);
    _check_enum(value, "delivery", DELIVERY_VALUES);
    _check_bool(value, "enabled");
    _check_bool(value, "verificationPending");
    _check_event_types(value);
    _check_max_pending(value);
    out: dict[str, any] = {};
    for key in ["name", "prompt", "botId", "runOn", "delivery", "enabled", "verificationPending", "eventTypes", "maxPendingRuns"] {
        if key in value {
            v = value[key];
            if key == "maxPendingRuns" and v is not None { v = int(v); }
            out[key] = v;
        }
    }
    return out;
}

def _clean_input(input: dict[str, any]) -> dict[str, any] {
    name = input["name"].strip()[:80];
    prompt = input["prompt"].strip()[:20000];
    bot_id = input["botId"].strip();
    run_on = input.get("runOn") or "maus";
    if not name { _fail(400, "Give the webhook a name"); }
    if not bot_id { _fail(400, "Choose a MAUS"); }
    if run_on not in RUN_ON_VALUES { _fail(400, "Choose where this webhook runs"); }
    event_types: list[str] = [];
    for raw in (input.get("eventTypes") or []) {
        v = raw.strip()[:200];
        if v and v not in event_types { event_types.append(v); }
    }
    event_types = event_types[:20];
    enabled = input.get("enabled") is not False;
    clean: dict[str, any] = {
        "name": name,
        "prompt": prompt,
        "botId": bot_id,
        "runOn": run_on,
        "enabled": enabled,
        "verificationPending": False if enabled else input.get("verificationPending") is True,
    };
    if event_types { clean["eventTypes"] = event_types; }
    if input.get("delivery") { clean["delivery"] = input["delivery"]; }
    mpr = input.get("maxPendingRuns");
    if isinstance(mpr, int) and not isinstance(mpr, bool) { clean["maxPendingRuns"] = mpr; }
    return clean;
}

# ── disk ───────────────────────────────────────────────────────────────────

def _finite_nonneg(v: any) -> bool {
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 and v == v and v != float("inf");
}

def _opt(rec: dict[str, any], key: str, ok: any) -> bool {
    return key not in rec or ok(rec[key]);
}

def _is_str(v: any) -> bool { return isinstance(v, str); }

def _nonneg_int(v: any) -> bool {
    n: any = v;
    return _is_int_number(n) and n >= 0;
}

def _status_code(v: any) -> bool {
    n: any = v;
    return _is_int_number(n) and 100 <= n and n <= 599;
}

def _is_nonempty_str(v: any) -> bool { return isinstance(v, str) and len(v) > 0; }

def _is_bool(v: any) -> bool { return isinstance(v, bool); }

def _is_str_list(v: any) -> bool {
    return isinstance(v, list) and len(v) <= 20 and all([isinstance(x, str) for x in v]);
}

def _is_sample(v: any) -> bool {
    return isinstance(v, dict) and _finite_nonneg(v.get("receivedAt")) and isinstance(v.get("preview"), str)
        and _opt(v, "eventName", _is_str) and _opt(v, "contentType", _is_str);
}

def _is_secret_hash(v: any) -> bool {
    return isinstance(v, str) and len(v) == SECRET_HASH_LEN and all([c in "0123456789abcdef" for c in v]);
}

# storedWebhookSchema: unknown keys are stripped (durationMinutes from an
# earlier build); an out-of-range maxPendingRuns falls back to the default.
glob STORED_KEYS: list[str] = [
    "id", "endpointId", "name", "prompt", "botId", "runOn", "delivery", "enabled",
    "createdAt", "updatedAt", "lastReceivedAt", "lastRunId", "resultsThreadId",
    "deliveryCount", "verificationPending", "verifiedAt", "verificationSample",
    "eventTypes", "maxPendingRuns", "secretHash",
];

def _load_webhook(v: any) -> any {
    if not isinstance(v, dict) { return None; }
    ok = _is_nonempty_str(v.get("id")) and _is_nonempty_str(v.get("endpointId"))
        and _is_str(v.get("name")) and _is_str(v.get("prompt")) and _is_nonempty_str(v.get("botId"))
        and v.get("runOn") in RUN_ON_VALUES and _opt(v, "delivery", DELIVERY_VALUES.__contains__)
        and _is_bool(v.get("enabled")) and _finite_nonneg(v.get("createdAt")) and _finite_nonneg(v.get("updatedAt"))
        and _opt(v, "lastReceivedAt", _finite_nonneg) and _opt(v, "lastRunId", _is_str)
        and _opt(v, "resultsThreadId", _is_nonempty_str)
        and _nonneg_int(v.get("deliveryCount"))
        and _opt(v, "verificationPending", _is_bool) and _opt(v, "verifiedAt", _finite_nonneg)
        and _opt(v, "verificationSample", _is_sample) and _opt(v, "eventTypes", _is_str_list)
        and _is_secret_hash(v.get("secretHash"));
    if not ok { return None; }
    out: dict[str, any] = {};
    for key in STORED_KEYS {
        if key in v { out[key] = v[key]; }
    }
    mpr = out.get("maxPendingRuns");
    if mpr is not None and not (_is_int_number(mpr) and 1 <= mpr and mpr <= MAX_PENDING_RUNS_LIMIT) {
        del out["maxPendingRuns"];
    }
    return out;
}

def _is_receipt(v: any) -> bool {
    return isinstance(v, dict) and _is_nonempty_str(v.get("key")) and _is_nonempty_str(v.get("runId"))
        and _finite_nonneg(v.get("at"));
}

glob ATTEMPT_OUTCOMES: list[str] = ["accepted", "captured", "duplicate", "ignored", "rejected"];

def _is_attempt(v: any) -> bool {
    return isinstance(v, dict) and _is_nonempty_str(v.get("id")) and _is_nonempty_str(v.get("webhookId"))
        and _finite_nonneg(v.get("receivedAt")) and v.get("outcome") in ATTEMPT_OUTCOMES
        and _status_code(v.get("statusCode"))
        and _opt(v, "eventName", _is_str) and _opt(v, "preview", _is_str) and _opt(v, "deliveryId", _is_str)
        and _opt(v, "runId", _is_str) and _opt(v, "reason", _is_str);
}

# webhookFileSchema is all-or-nothing: one bad record empties everything.
def _load {
    if _wh.get("loaded") { return; }
    _wh.update({"loaded": True, "webhooks": [], "deliveries": [], "attempts": []});
    try {
        with open(_file_path(), "r", encoding="utf-8") as f {
            data = json.load(f);
        }
    } except Exception {
        return;
    }
    if not isinstance(data, dict) or data.get("version") != 1 { return; }
    raw_hooks = data.get("webhooks");
    raw_deliveries = data.get("deliveries");
    raw_attempts = data.get("attempts") if "attempts" in data else [];
    if not isinstance(raw_hooks, list) or not isinstance(raw_deliveries, list) or not isinstance(raw_attempts, list) {
        return;
    }
    hooks: list[any] = [];
    for raw in raw_hooks {
        w = _load_webhook(raw);
        if w is None { return; }
        hooks.append(w);
    }
    if not all([_is_receipt(d) for d in raw_deliveries]) { return; }
    if not all([_is_attempt(a) for a in raw_attempts]) { return; }
    _wh.update({
        "webhooks": hooks,
        "deliveries": raw_deliveries[-MAX_DELIVERIES:],
        "attempts": raw_attempts[-MAX_ATTEMPTS:],
    });
}

def _save {
    write_json_private(_file_path(), {
        "version": 1,
        "webhooks": _wh["webhooks"],
        "deliveries": _wh["deliveries"],
        "attempts": _wh["attempts"],
    });
}

# ── helpers ────────────────────────────────────────────────────────────────

def _hash_secret(secret: str) -> str {
    return hashlib.sha256(secret.encode("utf-8")).hexdigest();
}

def _secret_matches(secret: any, expected_hex: str) -> bool {
    if not isinstance(secret, str) or not secret { return False; }
    return hmac.compare_digest(_hash_secret(secret), expected_hex);
}

def _public(trigger: dict[str, any]) -> dict[str, any] {
    out = dict(trigger);
    out.pop("secretHash", None);
    return out;
}

def _serialize_payload(payload: any) -> str {
    if isinstance(payload, str) {
        text = payload;
    } else {
        try {
            text = _js_pretty(payload);
        } except Exception {
            text = str(payload);
        }
    }
    if len(text) <= MAX_EVENT_CHARS { return text; }
    return text[:MAX_EVENT_CHARS] + "\n\n[Payload truncated by OpenMausBot]";
}

def _preview(payload: any) -> str {
    return " ".join(_serialize_payload(payload).split())[:2000];
}

def _task_from_payload(payload: any) -> str {
    if not isinstance(payload, dict) { return ""; }
    task = payload.get("task");
    message = payload.get("message");
    if task is not None and not isinstance(task, str) { return ""; }
    if message is not None and not isinstance(message, str) { return ""; }
    picked = task if task is not None else (message if message is not None else "");
    return picked.strip()[:20000];
}

def _event_prompt(trigger: dict[str, any], event: dict[str, any], received_at: int, delivery_id: str) -> str {
    metadata = ["Received: " + _iso(received_at), "Delivery ID: " + delivery_id];
    if event.get("eventName") { metadata.append("Event: " + event["eventName"][:200]); }
    if event.get("contentType") { metadata.append("Content-Type: " + event["contentType"][:200]); }
    if event.get("userAgent") { metadata.append("Sender: " + event["userAgent"][:300]); }
    configured = trigger["prompt"].strip();
    requested = "" if configured else _task_from_payload(event.get("payload"));
    if configured {
        block = ["[USER-CONFIGURED WEBHOOK INSTRUCTIONS]", configured, "[/USER-CONFIGURED WEBHOOK INSTRUCTIONS]"];
    } elif requested {
        block = ["[AUTHENTICATED WEBHOOK TASK]", requested, "[/AUTHENTICATED WEBHOOK TASK]"];
    } else {
        block = [
            "[DEFAULT WEBHOOK INSTRUCTIONS]",
            "Review the incoming event and summarize what happened. Do not take external actions unless the event clearly requires them and existing permissions allow them.",
            "[/DEFAULT WEBHOOK INSTRUCTIONS]",
        ];
    }
    lines = block + ["", "[UNTRUSTED WEBHOOK EVENT DATA]"] + metadata
        + ["", _serialize_payload(event.get("payload")), "[/UNTRUSTED WEBHOOK EVENT DATA]"];
    return "\n".join(lines);
}

def _requested_delivery_id(event: dict[str, any]) -> str {
    raw = event.get("deliveryId");
    return ("" if raw is None else str(raw)).strip()[:200];
}

def _find(key: str, value: any) -> any {
    for w in _wh["webhooks"] {
        if w.get(key) == value { return w; }
    }
    return None;
}

def _emit_trigger(trigger: dict[str, any]) {
    _emit_event({"kind": "webhook", "webhook": _public(trigger)});
}

def _build_attempt(trigger: dict[str, any], event: dict[str, any], details: dict[str, any], id: any = None) -> dict[str, any] {
    attempt: dict[str, any] = {
        "id": id if isinstance(id, str) else str(uuid.uuid4()),
        "webhookId": trigger["id"],
        "receivedAt": _now(),
        "outcome": details["outcome"],
        "statusCode": details["statusCode"],
    };
    if event.get("eventName") { attempt["eventName"] = event["eventName"][:200]; }
    if "payload" in event { attempt["preview"] = _preview(event["payload"]); }
    if details.get("deliveryId") { attempt["deliveryId"] = details["deliveryId"][:200]; }
    if details.get("runId") { attempt["runId"] = details["runId"]; }
    if details.get("reason") { attempt["reason"] = details["reason"]; }
    return attempt;
}

def _append_attempt(trigger: dict[str, any], event: dict[str, any], details: dict[str, any]) -> dict[str, any] {
    attempt = _build_attempt(trigger, event, details);
    attempts = _wh["attempts"];
    attempts.append(attempt);
    if len(attempts) > MAX_ATTEMPTS { del attempts[:len(attempts) - MAX_ATTEMPTS]; }
    _emit_event({"kind": "webhook.attempt", "attempt": dict(attempt)});
    return attempt;
}

def _record_rejected_for(trigger: dict[str, any], status: int, reason: str, event: dict[str, any]) -> dict[str, any] {
    attempt = _append_attempt(trigger, event, {
        "outcome": "rejected", "statusCode": status, "reason": reason[:500], "deliveryId": event.get("deliveryId"),
    });
    _save();
    return attempt;
}

def _push_delivery(key: str, run_id: str, at: int) {
    deliveries = _wh["deliveries"];
    deliveries.append({"key": key, "runId": run_id, "at": at});
    if len(deliveries) > MAX_DELIVERIES { del deliveries[:len(deliveries) - MAX_DELIVERIES]; }
}

# ── manager operations ─────────────────────────────────────────────────────

def wh_list -> list[any] {
    _load();
    return [_public(w) for w in _wh["webhooks"]];
}

def wh_list_attempts -> list[any] {
    _load();
    return [dict(a) for a in _wh["attempts"]];
}

def wh_create(input: any) -> dict[str, any] {
    _load();
    clean = _clean_input(_parse_trigger(input, False));
    if _hook("bot_state")(clean["botId"]) == "missing" { _fail(400, "That MAUS no longer exists"); }
    now = _now();
    secret = "whsec_" + secrets.token_urlsafe(32);
    trigger: dict[str, any] = {"id": str(uuid.uuid4()), "endpointId": "wh_" + secrets.token_urlsafe(12)};
    trigger.update(clean);
    trigger.update({"secretHash": _hash_secret(secret), "createdAt": now, "updatedAt": now, "deliveryCount": 0});
    _wh["webhooks"].insert(0, trigger);
    _save();
    _emit_trigger(trigger);
    return {"webhook": _public(trigger), "secret": secret};
}

def wh_update(id: str, value: any) -> any {
    _load();
    trigger = _find("id", id);
    if trigger is None { return None; }
    patch = _parse_trigger(value, True);
    merged: dict[str, any] = {};
    for key in ["name", "prompt", "botId", "runOn", "delivery", "enabled", "verificationPending", "eventTypes"] {
        v = patch.get(key);
        merged[key] = v if v is not None else trigger.get(key);
    }
    merged["maxPendingRuns"] = trigger.get("maxPendingRuns") if "maxPendingRuns" not in patch else patch["maxPendingRuns"];
    clean = _clean_input(merged);
    if _hook("bot_state")(clean["botId"]) == "missing" { _fail(400, "That MAUS no longer exists"); }
    trigger.update(clean);
    trigger["updatedAt"] = _now();
    if not clean.get("eventTypes") { trigger.pop("eventTypes", None); }
    if clean.get("maxPendingRuns") is None { trigger.pop("maxPendingRuns", None); }
    if patch.get("enabled") is False {
        cancel = _hook("cancel_queued");
        if cancel is not None { cancel(trigger["id"], "The webhook was paused before this delivery started"); }
    }
    _save();
    _emit_trigger(trigger);
    return _public(trigger);
}

def wh_remove(id: str) -> bool {
    _load();
    trigger = _find("id", id);
    if trigger is None { return False; }
    _wh["webhooks"].remove(trigger);
    prefix = trigger["endpointId"] + ":";
    _wh.update({
        "deliveries": [d for d in _wh["deliveries"] if not d["key"].startswith(prefix)],
        "attempts": [a for a in _wh["attempts"] if a["webhookId"] != trigger["id"]],
    });
    _wh["rate"].pop(trigger["endpointId"], None);
    _wh["unauthorized"].pop(trigger["id"], None);
    cancel = _hook("cancel_queued");
    if cancel is not None { cancel(trigger["id"], "The webhook was deleted before this delivery started"); }
    _save();
    _emit_event({"kind": "webhook.deleted", "webhookId": id});
    return True;
}

def wh_rotate_secret(id: str) -> any {
    _load();
    trigger = _find("id", id);
    if trigger is None { return None; }
    secret = "whsec_" + secrets.token_urlsafe(32);
    trigger["secretHash"] = _hash_secret(secret);
    trigger["updatedAt"] = _now();
    _save();
    _emit_trigger(trigger);
    return {"webhook": _public(trigger), "secret": secret};
}

def wh_disable_for_bot(bot_id: str) {
    _load();
    changed = False;
    for trigger in _wh["webhooks"] {
        if trigger["botId"] != bot_id or not trigger["enabled"] { continue; }
        trigger["enabled"] = False;
        trigger["updatedAt"] = _now();
        cancel = _hook("cancel_queued");
        if cancel is not None { cancel(trigger["id"], "The assigned MAUS was deleted"); }
        _emit_trigger(trigger);
        changed = True;
    }
    if changed { _save(); }
}

def wh_authorize(endpoint_id: str, secret: any) -> bool {
    _load();
    trigger = _find("endpointId", endpoint_id);
    return trigger is not None and _secret_matches(secret, trigger["secretHash"]);
}

def wh_receive(endpoint_id: str, secret: any, event: dict[str, any]) -> dict[str, any] {
    _load();
    trigger = _find("endpointId", endpoint_id);
    if trigger is None or not _secret_matches(secret, trigger["secretHash"]) {
        _fail(401, "Invalid webhook URL or secret");
    }
    if trigger.get("verificationPending") and not trigger["enabled"] {
        return _capture_verification(trigger, event);
    }
    try {
        return _dispatch(trigger, event);
    } except Exception as e {
        status = _status_of(e);
        _record_rejected_for(trigger, status, str(e), event);
        raise;
    }
}

def wh_test(id: str, payload: any) -> any {
    _load();
    trigger = _find("id", id);
    if trigger is None { return None; }
    types = trigger.get("eventTypes") or [];
    return _dispatch(trigger, {
        "payload": payload if payload is not None else {"event": "openmaus.test", "message": "Test webhook delivery"},
        "contentType": "application/json",
        "eventName": types[0] if types else "openmaus.test",
        "userAgent": "OpenMausBot webhook tester",
        "deliveryId": "test-" + str(uuid.uuid4()),
    });
}

def wh_record_rejected(endpoint_id: str, status: int, reason: str, event: dict[str, any]) -> any {
    _load();
    trigger = _find("endpointId", endpoint_id);
    if trigger is None { return None; }
    return _record_rejected_for(trigger, status, reason, event);
}

# A wrong-secret flood keeps ONE rolling record per webhook, replaced in
# place (same id) and saved with the next real change.
def wh_record_unauthorized(endpoint_id: str, event: dict[str, any]) -> any {
    _load();
    trigger = _find("endpointId", endpoint_id);
    if trigger is None { return None; }
    attempts = _wh["attempts"];
    at = -1;
    for i in range(len(attempts) - 1, -1, -1) {
        a = attempts[i];
        if a["webhookId"] == trigger["id"] and a["outcome"] == "rejected" and a["statusCode"] == 401 {
            at = i;
            break;
        }
    }
    if at == -1 {
        _wh["unauthorized"][trigger["id"]] = 1;
        return _append_attempt(trigger, event, {
            "outcome": "rejected", "statusCode": 401, "reason": UNAUTHORIZED_REASON, "deliveryId": event.get("deliveryId"),
        });
    }
    count = _wh["unauthorized"].get(trigger["id"], 1) + 1;
    _wh["unauthorized"][trigger["id"]] = count;
    attempt = _build_attempt(trigger, event, {
        "outcome": "rejected", "statusCode": 401,
        "reason": UNAUTHORIZED_REASON + " (" + str(count) + " requests)", "deliveryId": event.get("deliveryId"),
    }, attempts[at]["id"]);
    attempts[at] = attempt;
    _emit_event({"kind": "webhook.attempt", "attempt": dict(attempt)});
    return attempt;
}

def _dispatch(trigger: dict[str, any], event: dict[str, any]) -> dict[str, any] {
    if not trigger["enabled"] { _fail(409, "This webhook is paused"); }
    if _hook("bot_state")(trigger["botId"]) == "missing" { _fail(410, "The assigned MAUS no longer exists"); }

    allowed = trigger.get("eventTypes") or [];
    if allowed and (not event.get("eventName") or event.get("eventName") not in allowed) {
        delivery_id = _requested_delivery_id(event) or str(uuid.uuid4());
        reason = ("Event type “" + event["eventName"] + "” is not enabled") if event.get("eventName") else "Event type is missing";
        _append_attempt(trigger, event, {"outcome": "ignored", "statusCode": 202, "deliveryId": delivery_id, "reason": reason});
        _save();
        return {"deliveryId": delivery_id, "duplicate": False, "ignored": True};
    }

    now = _now();
    requested = _requested_delivery_id(event);
    if requested {
        key = trigger["endpointId"] + ":" + requested;
        find_run = _hook("find_run");
        committed = find_run(trigger["id"], requested) if find_run is not None else None;
        dup_run_id: any = None;
        if committed {
            dup_run_id = committed["id"];
        } else {
            for d in _wh["deliveries"] {
                if d["key"] == key { dup_run_id = d["runId"]; break; }
            }
        }
        if dup_run_id is not None {
            _append_attempt(trigger, event, {
                "outcome": "duplicate", "statusCode": 202, "deliveryId": requested,
                "runId": dup_run_id, "reason": "Duplicate delivery ignored",
            });
            _save();
            return {"runId": dup_run_id, "deliveryId": requested, "duplicate": True};
        }
    }

    # A retry of an accepted delivery stays idempotent while the queue is
    # full; only new work consumes a slot.
    max_pending = trigger.get("maxPendingRuns") or DEFAULT_MAX_PENDING_RUNS;
    pending_fn = _hook("pending_runs");
    pending = (pending_fn(trigger["id"]) if pending_fn is not None else 0) or 0;
    if pending >= max_pending {
        _fail(429, "This webhook already has " + str(pending) + " unfinished " + ("task" if pending == 1 else "tasks")
            + " (its limit is " + str(max_pending) + "). "
            + "Retry after one finishes, or raise \"Unfinished tasks at once\" in the webhook's settings.");
    }

    recent = [at for at in _wh["rate"].get(trigger["endpointId"], []) if now - at < RATE_WINDOW_MS];
    if len(recent) >= RATE_LIMIT { _fail(429, "Webhook rate limit exceeded"); }
    recent.append(now);
    _wh["rate"][trigger["endpointId"]] = recent;

    delivery_id = requested or str(uuid.uuid4());
    if trigger.get("delivery") == "post" {
        return _dispatch_post(trigger, event, now, delivery_id);
    }
    run = _hook("enqueue")({
        "webhookId": trigger["id"],
        "webhookName": trigger["name"],
        "prompt": _event_prompt(trigger, event, now, delivery_id),
        "botId": trigger["botId"],
        "runOn": trigger["runOn"],
        "deliveryId": delivery_id,
        "receivedAt": now,
    });
    _push_delivery(trigger["endpointId"] + ":" + delivery_id, run["id"], now);
    trigger.update({"lastReceivedAt": now, "lastRunId": run["id"], "updatedAt": now});
    trigger["deliveryCount"] += 1;
    _append_attempt(trigger, event, {"outcome": "accepted", "statusCode": 202, "deliveryId": delivery_id, "runId": run["id"]});
    _save();
    _emit_trigger(trigger);
    return {"runId": run["id"], "deliveryId": delivery_id, "duplicate": False};
}

# delivery:"post": the payload becomes the bot's own chat message in the
# trigger's stable destination thread — never a caller's "current" thread
# (OpenMausBot#2071). A host without a sink or resolver fails closed.
def _dispatch_post(trigger: dict[str, any], event: dict[str, any], now: int, delivery_id: str) -> dict[str, any] {
    post = _hook("post");
    if post is None { _fail(503, "This server cannot post webhook messages to chat"); }
    resolve = _hook("resolve_post_thread");
    thread_id = resolve(trigger, False) if resolve is not None else None;
    if not thread_id { _fail(503, "This server could not resolve a destination thread for this delivery"); }
    if thread_id != trigger.get("resultsThreadId") {
        trigger.update({"resultsThreadId": thread_id, "updatedAt": now});
    }
    payload = event.get("payload");
    raw_text = payload.get("text") if isinstance(payload, dict) else None;
    text = raw_text if isinstance(raw_text, str) and raw_text.strip() else _serialize_payload(payload);
    post(trigger["botId"], thread_id, text[:20000]);
    _push_delivery(trigger["endpointId"] + ":" + delivery_id, "post", now);
    trigger.update({"lastReceivedAt": now, "updatedAt": now});
    trigger["deliveryCount"] += 1;
    _append_attempt(trigger, event, {
        "outcome": "accepted", "statusCode": 202, "deliveryId": delivery_id, "reason": "Posted to chat (no task run)",
    });
    _save();
    _emit_trigger(trigger);
    return {"deliveryId": delivery_id, "duplicate": False};
}

def _capture_verification(trigger: dict[str, any], event: dict[str, any]) -> dict[str, any] {
    received_at = _now();
    delivery_id = _requested_delivery_id(event) or str(uuid.uuid4());
    sample: dict[str, any] = {"receivedAt": received_at, "preview": _preview(event.get("payload"))};
    if event.get("eventName") { sample["eventName"] = event["eventName"][:200]; }
    if event.get("contentType") { sample["contentType"] = event["contentType"][:200]; }
    trigger.update({
        "verificationPending": False,
        "verifiedAt": received_at,
        "lastReceivedAt": received_at,
        "updatedAt": received_at,
        "verificationSample": sample,
    });
    _append_attempt(trigger, event, {
        "outcome": "captured", "statusCode": 202, "deliveryId": delivery_id,
        "reason": "Test event captured; enable the webhook to start MAUS tasks",
    });
    _save();
    _emit_trigger(trigger);
    return {"deliveryId": delivery_id, "duplicate": False, "captured": True};
}

# ── HTTP surface (re-bound onto harness.jac as webhook_*) ───────────────────

# Optional kwargs: the fused jacup binary binds the stringified default when
# a request omits one, so every optional arg is type-checked before use.
def _event_arg(event: any) -> dict[str, any] {
    return event if isinstance(event, dict) else {};
}

def:pub webhook_list(omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return {"webhooks": wh_list(), "attempts": wh_list_attempts()};
    }
    return _invoke(omb_token, _go);
}

def:pub webhook_create(input: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return wh_create(input); }
    return _invoke(omb_token, _go);
}

def:pub webhook_update(id: str, patch: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"webhook": wh_update(id, patch)}; }
    return _invoke(omb_token, _go);
}

def:pub webhook_remove(id: str, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"removed": wh_remove(id)}; }
    return _invoke(omb_token, _go);
}

def:pub webhook_rotate(id: str, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        rotated = wh_rotate_secret(id);
        return rotated if rotated is not None else {"webhook": None};
    }
    return _invoke(omb_token, _go);
}

def:pub webhook_disable_for_bot(bot_id: str, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        wh_disable_for_bot(bot_id);
        return {"ok": True};
    }
    return _invoke(omb_token, _go);
}

def:pub webhook_receive(endpoint_id: str, secret: any = None, event: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        # authorize + receive in one op: a bad secret records the rolling
        # 401 attempt and answers 401 without a second round trip.
        if not wh_authorize(endpoint_id, secret) {
            wh_record_unauthorized(endpoint_id, _event_arg(event));
            _fail(401, UNAUTHORIZED_REASON);
        }
        return {"result": wh_receive(endpoint_id, secret, _event_arg(event))};
    }
    return _invoke(omb_token, _go);
}

def:pub webhook_authorize(endpoint_id: str, secret: any = None, event: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        ok = wh_authorize(endpoint_id, secret);
        if not ok { wh_record_unauthorized(endpoint_id, _event_arg(event)); }
        return {"authorized": ok};
    }
    return _invoke(omb_token, _go);
}

def:pub webhook_test(id: str, payload: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] { return {"result": wh_test(id, payload)}; }
    return _invoke(omb_token, _go);
}

def:pub webhook_record_rejected(endpoint_id: str, status: int, reason: str, event: any = None, omb_token: any = None) -> dict[str, any] {
    def _go -> dict[str, any] {
        return {"attempt": wh_record_rejected(endpoint_id, status, reason, _event_arg(event))};
    }
    return _invoke(omb_token, _go);
}

with entry {
    _reset();
}
