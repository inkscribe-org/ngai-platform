"""Pairing codes, bearer sessions and stream tickets — port of server/sessions.ts.

A pairing code is 12 characters from a 32-symbol alphabet with no 0/O/1/I
(60 bits), single use, five minutes. Exchanging it yields an opaque
session token (omb_sess_…, 256 bits) that lives 30 days, renewed on use
up to 180 days from pairing; only its sha256 is stored. A stream ticket
is a 5-minute single-use credential for the SSE endpoint, because
EventSource cannot set headers. Failed exchanges are counted per source:
ten in a minute lock that source out for one.

Persistence: one JSON file {version:1, sessions:[…]} written atomically
(temp + rename, mode 0o600, dir fsync — server/atomic.ts), plus a
<file>.open crash marker written before any persisted bearer is accepted
and removed only by close(). Pairings, tickets, lockouts, exchange
replays and last-seen debounce state are memory-only module globs.

The TS SessionRegistry is constructed once in server/index.ts; here its
state is module-level and init(options) plays the constructor.
"""

import os;
import sys;
import re;
import json;
import math;
import time;
import errno;
import hmac;
import base64;
import hashlib;
import secrets;
import uuid;

import from jsutil { js_string, js_stringify }
import from common { js_pretty as _js_pretty, write_file_atomic as _write_file_atomic }


# JS strips its own whitespace set in trim() and ToNumber; Python's is
# close but not identical (\u000b-\u000d, \ufeff, U+1680 …).
glob _JS_WS: str = (
    "\t\n\x0b\x0c\r \xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005"
    "\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"
);


def _js_len(text: str) -> int {
    # JS string length counts UTF-16 code units, not code points.
    return len(text.encode("utf-16-le", "surrogatepass")) // 2;
}

def _js_trim(text: any) -> str {
    return text.strip(_JS_WS);
}


def _js_slice_16(text: str, start: int, end: (int | None) = None) -> str {
    # JS .slice counts UTF-16 code units; a boundary can split a surrogate
    # pair, which surrogatepass preserves as a lone surrogate — js_string
    # then escapes it exactly as JSON.stringify would.
    units = text.encode("utf-16-le", "surrogatepass");
    if end is None {
        end = len(units) // 2;
    }
    return units[start * 2 : end * 2].decode("utf-16-le", "surrogatepass");
}


def _js_number(value: any) -> float {
    # JS Number(value), restricted to what env strings can hold.
    if value is None {
        return float("nan");
    }
    if isinstance(value, bool) {
        return (1.0 if value else 0.0);
    }
    if isinstance(value, int) or isinstance(value, float) {
        return float(value);
    }
    s = str(value).strip(_JS_WS);
    if s == "" {
        return 0.0;
    }
    # Non-decimal integer literals take no sign in the JS grammar.
    if re.fullmatch(r"0[xX][0-9a-fA-F]+", s) {
        return float(int(s[2:], 16));
    }
    if re.fullmatch(r"0[oO][0-7]+", s) {
        return float(int(s[2:], 8));
    }
    if re.fullmatch(r"0[bB][01]+", s) {
        return float(int(s[2:], 2));
    }
    if re.fullmatch(r"[+-]?(?:Infinity|(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)", s) {
        return float(s);
    }
    return float("nan");
}


def days_ms(value: (str | None), fallback_days: int) -> int {
    # A whole number of days from an environment variable, as
    # milliseconds. Anything that is not a whole number of days between 1
    # and 3650 falls back to the default rather than being clamped, so a
    # typo is not silently turned into a policy.
    days = _js_number(value);
    ok = not math.isnan(days) and not math.isinf(days) and days == math.floor(days) and days >= 1 and days <= 3650;
    return ((int(days) if ok else fallback_days)) * 24 * 60 * 60 * 1000;
}


glob DATA_DIR: str = os.environ.get(
        "OMB_DATA_DIR",
        os.path.join(os.path.expanduser("~"), ".openmausbot")
    ),
    SCOPES: list[str] = ["admin", "client"],
    PAIRING_CODE_ALPHABET: str = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ",
    PAIRING_CODE_LENGTH: int = 12,
    PAIRING_CODE_TTL_MS: int = 5 * 60000,
    PAIRING_CREDENTIAL_PREFIX: str = "omb_pair_",
    SESSION_TTL_MS: int = days_ms(os.environ.get("OMB_SESSION_TTL_DAYS"), 30),
    SESSION_MAX_AGE_MS: int = days_ms(os.environ.get("OMB_SESSION_MAX_DAYS"), 180),
    SESSION_RENEW_WHEN_LEFT_MS: int = SESSION_TTL_MS // 2,
    STREAM_TICKET_TTL_MS: int = 5 * 60000,
    EXCHANGE_REPLAY_MS: int = 60000,
    MAX_STREAM_TICKETS_PER_SESSION: int = 5,
    LAST_SEEN_WRITE_INTERVAL_MS: int = 60000,
    LOCKOUT: dict[str, int] = {"failures": 10, "windowMs": 60000, "lockMs": 60000},
    _CONTROL_RE: any = re.compile(
        "[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]"
    ),
    _ATTEMPT_ID_RE: any = re.compile(r"[A-Za-z0-9_-]{8,64}"),
    _PORTAL_GRANT_RE: any = re.compile(r"[A-Za-z0-9_-]{43}"),
    _sessions: list[dict[str, any]] = [],
    _pairings: list[dict[str, any]] = [],
    _tickets: dict[str, dict[str, any]] = {},
    _failures: dict[any, dict[str, any]] = {},
    _replays: list[dict[str, any]] = [],
    _on_revoked: list[any] = [],
    _last_seen_writes: dict[str, any] = {},
    _file: str = "",
    _open_marker: str = "",
    _now_fn: any = None,
    _email_scopes: any = None,
    _email_scopes_snapshot: any = None,
    _portal_membership: bool = False,
    _closed: bool = False,
    _admin_only: any = None;


def sessions_file -> str {
    return os.path.join(DATA_DIR, "sessions.json");
}


def _now -> any {
    if _now_fn is not None {
        return _now_fn();
    }
    # Date.now(): integer milliseconds.
    return int(time.time() * 1000);
}


def sha256(value: any) -> str {
    return hashlib.sha256(value.encode("utf-8")).hexdigest();
}


def _dirname(path: str) -> str {
    # node:path.dirname("sessions.json") is "."; os.path.dirname is "".
    d = os.path.dirname(path);
    return (d if d else ".");
}


def _hex_decode(value: str) -> bytes {
    # Buffer.from(value, "hex"): pairs parsed until the first invalid or
    # lone nibble, which is dropped silently.
    out = bytearray();
    i = 0;
    while i + 1 < len(value) {
        try {
            out.append(int(value[i : i + 2], 16));
        } except ValueError {
            break;
        }
        i += 2;
    }
    return bytes(out);
}


def same_digest(a: str, b: str) -> bool {
    left = _hex_decode(a);
    right = _hex_decode(b);
    return len(left) == len(right) and hmac.compare_digest(left, right);
}


def device_label(value: (str | None)) -> str {
    # A device's name as the sessions list shows it: what a client sent,
    # less control and bidirectional-formatting characters.
    return _js_trim(_CONTROL_RE.sub("", (value if value is not None else "")));
}


def generate_pairing_code -> str {
    # 12 symbols, rejection-sampled so every symbol is equally likely.
    limit = (256 // len(PAIRING_CODE_ALPHABET)) * len(PAIRING_CODE_ALPHABET);
    code = "";
    while len(code) < PAIRING_CODE_LENGTH {
        for byte in secrets.token_bytes(PAIRING_CODE_LENGTH) {
            if byte >= limit {
                continue;
            }
            code += PAIRING_CODE_ALPHABET[byte % len(PAIRING_CODE_ALPHABET)];
            if len(code) == PAIRING_CODE_LENGTH {
                break;
            }
        }
    }
    return code;
}


def generate_pairing_credential -> str {
    # The same pairing window as a 256-bit secret, for a QR a native app
    # scans rather than a code a person reads out. 9 + 43 characters: the
    # Android companion checks that length exactly.
    return PAIRING_CREDENTIAL_PREFIX + base64.urlsafe_b64encode(
        secrets.token_bytes(32)
    ).decode("ascii").rstrip("=");
}


def is_pairing_credential(value: any) -> bool {
    return value.startswith(PAIRING_CREDENTIAL_PREFIX);
}


def normalize_pairing_code(input: any) -> str {
    # Accept what a human typed: dashes, spaces, lowercase, lookalikes.
    return re.sub(r"1", "I", re.sub(r"0", "O", re.sub(r"[^A-Z0-9]", "", input.upper())));
}


def format_pairing_code(code: str) -> str {
    # XXXX-XXXX-XXXX, easier to read out loud. JS /.{1,4}/g counts UTF-16
    # code units, so chunk the encoded form.
    units = code.encode("utf-16-le", "surrogatepass");
    parts: list[str] = [];
    i = 0;
    while i < len(units) {
        parts.append(units[i : i + 8].decode("utf-16-le", "surrogatepass"));
        i += 8;
    }
    if not parts {
        return code;
    }
    return "-".join(parts);
}


def cookie_max_age_seconds(session: dict[str, any], now: any = None) -> int {
    # Max-Age for a cookie that should die with its session: whole
    # seconds, at least one. TS default is Date.now(), independent of the
    # registry's injected clock.
    if now is None {
        now = int(time.time() * 1000);
    }
    return max(1, math.floor((session["expiresAt"] - now) / 1000));
}


def _is_js_number_value(value: any) -> bool {
    # z.number(): a real number, not a bool. JSON cannot carry NaN, so a
    # parsed file can never produce one here.
    return not isinstance(value, bool) and (isinstance(value, int) or isinstance(value, float));
}


def _parse_session(raw: any) -> (dict[str, any] | None) {
    # zod sessionSchema.safeParse: types and bounds checked, unknown keys
    # stripped, output keys in schema order.
    if not isinstance(raw, dict) {
        return None;
    }
    record: dict[str, any] = {};
    id_ = raw.get("id");
    if not isinstance(id_, str) or _js_len(id_) < 1 {
        return None;
    }
    record["id"] = id_;
    token_hash = raw.get("tokenHash");
    if not isinstance(token_hash, str) or _js_len(token_hash) != 64 {
        return None;
    }
    record["tokenHash"] = token_hash;
    label = raw.get("label");
    if not isinstance(label, str) or _js_len(label) > 80 {
        return None;
    }
    record["label"] = label;
    scopes = raw.get("scopes");
    if not isinstance(scopes, list) or len(scopes) < 1 {
        return None;
    }
    for scope in scopes {
        if scope != "admin" and scope != "client" {
            return None;
        }
    }
    record["scopes"] = list(scopes);
    for name in ["createdAt", "lastSeenAt", "expiresAt"] {
        v = raw.get(name);
        if not _is_js_number_value(v) {
            return None;
        }
        record[name] = v;
    }
    if "userId" in raw {
        user_id = raw["userId"];
        if not isinstance(user_id, str) or _js_len(user_id) > 256 {
            return None;
        }
        record["userId"] = user_id;
    }
    if "email" in raw {
        email = raw["email"];
        if not isinstance(email, str) or _js_len(email) > 320 {
            return None;
        }
        record["email"] = email;
    }
    if "membershipAuthority" in raw {
        if raw["membershipAuthority"] != "portal" {
            return None;
        }
        record["membershipAuthority"] = "portal";
    }
    if "cookieOnly" in raw {
        if raw["cookieOnly"] is not True {
            return None;
        }
        record["cookieOnly"] = True;
    }
    if "owner" in raw {
        owner = raw["owner"];
        if not isinstance(owner, str) or _js_len(owner) > 254 {
            return None;
        }
        record["owner"] = owner;
    }
    return record;
}


def _parse_session_file(raw: any) -> (list[dict[str, any]] | None) {
    # fileSchema.safeParse: {version: 1, sessions: sessionSchema[]}.
    if not isinstance(raw, dict) {
        return None;
    }
    version = raw.get("version");
    if isinstance(version, bool) or version != 1 {
        return None;
    }
    sessions_raw = raw.get("sessions");
    if not isinstance(sessions_raw, list) {
        return None;
    }
    out: list[dict[str, any]] = [];
    for item in sessions_raw {
        parsed = _parse_session(item);
        if parsed is None {
            return None;
        }
        out.append(parsed);
    }
    return out;
}


def _load(restore_accounts: bool) -> None {
    if not os.path.exists(_file) {
        return;
    }
    raw: any = None;
    try {
        f = open(_file, "r", encoding="utf-8");
        try {
            raw = json.loads(f.read());
        } finally {
            f.close();
        }
    } except Exception {
        # Unreadable: start empty rather than refuse to boot; pairing
        # again is cheap.
        return;
    }
    parsed = _parse_session_file(raw);
    if parsed is not None {
        kept: list[dict[str, any]] = [];
        for session in parsed {
            if restore_accounts or (session.get("email") is None and session.get("userId") is None) {
                kept.append(session);
            }
        }
        globals()["_sessions"] = kept;
    }
}


def _sync_directory -> None {
    # Windows does not expose directory fsync. The open marker still
    # guards normal process crashes; no stronger power-loss guarantee is
    # claimed.
    if sys.platform == "win32" {
        return;
    }
    fd = os.open(_dirname(_file), os.O_RDONLY);
    try {
        os.fsync(fd);
    } finally {
        os.close(fd);
    }
}


def _persist {
    # Atomic write, owner-only, directory owner-only.
    if _closed {
        raise RuntimeError("Session registry is closed.");
    }
    dir_ = _dirname(_file);
    os.makedirs(dir_, mode=0o700, exist_ok=True);
    _write_file_atomic(
        _file,
        _js_pretty({"version": 1, "sessions": _sessions}, 0) + "\n",
        mode=0o600
    );
    _sync_directory();
}


def init(options: dict[str, any]) {
    # The SessionRegistry constructor: establish the open marker before
    # accepting any persisted bearer, then load and revalidate.
    globals()["_file"] = options.get("file") or sessions_file();
    globals()["_now_fn"] = options.get("now");
    globals()["_email_scopes"] = options.get("emailScopes");
    globals()["_email_scopes_snapshot"] = options.get("emailScopesSnapshot");
    globals()["_portal_membership"] = bool(options.get("portalMembership"));
    globals()["_sessions"] = [];
    globals()["_pairings"] = [];
    globals()["_tickets"] = {};
    globals()["_failures"] = {};
    globals()["_replays"] = [];
    globals()["_on_revoked"] = [];
    globals()["_last_seen_writes"] = {};
    globals()["_closed"] = False;
    globals()["_admin_only"] = None;
    globals()["_open_marker"] = globals()["_file"] + ".open";
    unclean = os.path.exists(_open_marker);
    try {
        os.makedirs(_dirname(_file), mode=0o700, exist_ok=True);
        _write_file_atomic(_open_marker, "Session registry is open.\n", mode=0o600);
        _sync_directory();
    } except Exception {
        raise RuntimeError("Could not establish safe session storage.");
    }
    _load(not unclean);
    revalidate_email_sessions();
}

# Jac compiles `def init` to module __init__ (a lifecycle name, not
# auto-invoked on import). Expose it again under `init` so Python callers
# get sessions.init(options).
glob init: any = init;


def close -> None {
    # Call after HTTP/stream shutdown. A failed close leaves the open
    # marker, so account sessions require fresh sign-in after restart.
    # Paired devices remain durable. Never remove the marker before the
    # reduced set is saved.
    if _closed {
        return;
    }
    try {
        revalidate_email_sessions();
        _persist();
        os.unlink(_open_marker);
        globals()["_closed"] = True;
        # A marker deletion lost on power failure causes extra sign-in
        # only; the session file and its rename were fsynced before
        # removal.
    } except Exception {
        raise RuntimeError("Could not safely close session storage.");
    }
}


def _prune {
    revalidate_email_sessions();
    now = _now();
    globals()["_pairings"] = [p for p in _pairings if p["expiresAt"] > now];
    globals()["_replays"] = [r for r in _replays if r["expiresAt"] > now];
    for (h, ticket) in list(_tickets.items()) {
        if ticket["expiresAt"] <= now {
            _tickets.pop(h);
        }
    }
    for (source, fail_entry) in list(_failures.items()) {
        if fail_entry["lockedUntil"] <= now and now - fail_entry["windowStart"] > LOCKOUT["windowMs"] {
            _failures.pop(source);
        }
    }
    expired = [s for s in _sessions if s["expiresAt"] <= now];
    if expired {
        globals()["_sessions"] = [s for s in _sessions if s["expiresAt"] > now];
        for s in expired {
            _forget(s["id"]);
        }
        _persist();
    }
}


def on_session_revoked(listener: any) -> any {
    # Called with a session id whenever it stops being valid (revoked,
    # logged out, expired), so open streams can be closed. Returns an
    # unsubscribe closure, like the TS Set.delete callback.
    if listener not in _on_revoked {
        _on_revoked.append(listener);
    }
    def unsubscribe {
        if listener in _on_revoked {
            _on_revoked.remove(listener);
        }
    }
    return unsubscribe;
}


def _forget(session_id: str) {
    _last_seen_writes.pop(session_id, None);
    for (h, ticket) in list(_tickets.items()) {
        if ticket["sessionId"] == session_id {
            _tickets.pop(h);
        }
    }
    for listener in list(_on_revoked) {
        listener(session_id);
    }
}


def require_admin(refusal: str) {
    # From now on no pairing window, sign-in or session without admin
    # scope is opened, redeemed, issued or accepted; `refusal` says why
    # (an OMB Cloud home is personal). Sessions stored without it stop
    # authenticating; the caller revokes them.
    globals()["_admin_only"] = refusal;
}


def _personal(scopes: any) -> bool {
    return _admin_only is not None and "admin" not in scopes;
}


def _refuse_personal(scopes: any) {
    if _personal(scopes) {
        err = PermissionError(_admin_only);
        setattr(err, "status", 403);
        setattr(err, "code", "cloud_personal");
        raise err;
    }
}


def open_pairing(input: (dict[str, any] | None) = None) -> dict[str, any] {
    if input is None {
        input = {};
    }
    _prune();
    now = _now();
    code = generate_pairing_code();
    credential = generate_pairing_credential();
    scopes_in = input.get("scopes");
    if scopes_in and len(scopes_in) {
        scopes = list(dict.fromkeys(scopes_in));
    } else {
        scopes = list(SCOPES);
    }
    _refuse_personal(scopes);
    pairing: dict[str, any] = {
        "id": str(uuid.uuid4()),
        "codeHash": sha256(code),
        "credentialHash": sha256(credential),
        "scopes": scopes,
        "label": _js_slice_16(_js_trim((input.get("label") if input.get("label") is not None else "")), 0, 80),
        "createdAt": now,
        "expiresAt": now + (
            input.get("ttlMs") if input.get("ttlMs") is not None else PAIRING_CODE_TTL_MS
        ),
    };
    if input.get("browser") {
        pairing["browser"] = True;
        if input.get("owner") {
            pairing["owner"] = input["owner"];
        }
    }
    _pairings.append(pairing);
    return {
        "id": pairing["id"],
        "code": code,
        "credential": credential,
        "expiresAt": pairing["expiresAt"],
    };
}


def open_pairings -> list[dict[str, any]] {
    _prune();
    out: list[dict[str, any]] = [];
    for p in _pairings {
        out.append({
            "id": p["id"],
            "label": p["label"],
            "scopes": list(p["scopes"]),
            "createdAt": p["createdAt"],
            "expiresAt": p["expiresAt"],
        });
    }
    return out;
}


def preview_browser_sign_in(credential: str) -> (dict[str, any] | None) {
    # What a browser sign-in's page shows before anything is redeemed:
    # whose Cloud it signs in to. Only a browser sign-in's 256-bit
    # credential can match, so this consumes nothing and counts toward no
    # lockout.
    _prune();
    if not is_pairing_credential(credential) {
        return None;
    }
    presented = sha256(credential);
    for p in _pairings {
        if p.get("browser") is True and same_digest(p["credentialHash"], presented) {
            return {"owner": p.get("owner"), "expiresAt": p["expiresAt"]};
        }
    }
    return None;
}


def cancel_pairing(id: str) -> bool {
    before = len(_pairings);
    globals()["_pairings"] = [p for p in _pairings if p["id"] != id];
    return len(_pairings) != before;
}


def failure_sources -> list[str] {
    # Sources with recent failures (for tests and diagnostics; never the
    # codes).
    _prune();
    return list(_failures.keys());
}


def _lock_state(source: any) -> dict[str, any] {
    fail_entry = _failures.get(source);
    if fail_entry is None {
        return {"locked": False, "retryAfterMs": 0};
    }
    now = _now();
    if fail_entry["lockedUntil"] > now {
        return {"locked": True, "retryAfterMs": fail_entry["lockedUntil"] - now};
    }
    return {"locked": False, "retryAfterMs": 0};
}


def _record_failure(source: any) {
    now = _now();
    fail_entry = _failures.get(source);
    if fail_entry is None {
        fail_entry = {"count": 0, "windowStart": now, "lockedUntil": 0};
    }
    if now - fail_entry["windowStart"] > LOCKOUT["windowMs"] {
        fail_entry["count"] = 0;
        fail_entry["windowStart"] = now;
    }
    fail_entry["count"] += 1;
    if fail_entry["count"] >= LOCKOUT["failures"] {
        fail_entry["lockedUntil"] = now + LOCKOUT["lockMs"];
        fail_entry["count"] = 0;
        fail_entry["windowStart"] = now;
    }
    _failures[source] = fail_entry;
}


def public_session(record: dict[str, any]) -> dict[str, any] {
    # What the UI may see: never the hash.
    view: dict[str, any] = {
        "id": record["id"],
        "label": record["label"],
        "scopes": list(record["scopes"]),
        "createdAt": record["createdAt"],
        "lastSeenAt": record["lastSeenAt"],
        "expiresAt": record["expiresAt"],
    };
    if record.get("email") {
        view["email"] = record["email"];
    }
    if record.get("owner") {
        view["owner"] = record["owner"];
    }
    return view;
}


def exchange(input: dict[str, any]) -> dict[str, any] {
    # Turn a pairing code into a session. `source` identifies the caller
    # for the lockout (an IP); `label` is what the client asked to be
    # called, the code's own label (set by whoever minted it) comes next,
    # `fallbackLabel` (derived from the user agent) last. `browser`: this
    # is a browser sign-in (PairingCode `browser`), which redeems only a
    # window opened for one.
    _prune();
    now = _now();
    # A credential is hashed as presented. Normalizing it would be
    # actively unsafe: normalize_pairing_code folds 0 to O and 1 to I,
    # which both destroys a base64url secret and maps distinct secrets
    # onto one digest.
    code_in = input.get("code");
    if is_pairing_credential(code_in) {
        presented = sha256(code_in);
    } else {
        presented = sha256(normalize_pairing_code(code_in));
    }
    browser = input.get("browser") is True;
    attempt_in = input.get("attemptId");
    attempt_id: any = None;
    if isinstance(attempt_in, str) and _ATTEMPT_ID_RE.fullmatch(attempt_in) {
        attempt_id = attempt_in;
    }
    replay: any = None;
    if attempt_id is not None {
        for r in _replays {
            if r["attemptId"] == attempt_id and r["browser"] == browser and same_digest(r["codeHash"], presented) {
                replay = r;
                break;
            }
        }
    }
    if replay is not None {
        return replay["result"];
    }
    lock = _lock_state(input.get("source"));
    if lock["locked"] {
        seconds = math.ceil(lock["retryAfterMs"] / 1000);
        return {
            "ok": False,
            "status": 429,
            "error": f"too many failed pairing attempts from your address; try again in {seconds}s",
        };
    }
    index = -1;
    for (i, p) in enumerate(_pairings) {
        if (p.get("browser") is True) == browser and (
            same_digest(p["credentialHash"], presented)
            or (not p.get("browser") and same_digest(p["codeHash"], presented))
        ) {
            index = i;
            break;
        }
    }
    if index < 0 {
        _record_failure(input.get("source"));
        return {
            "ok": False,
            "status": 401,
            "error": "pairing code is wrong or has expired; create a new one on the server",
        };
    }
    pairing = _pairings.pop(index);  # single use
    _failures.pop(input.get("source"), None);
    if _personal(pairing["scopes"]) {
        return {"ok": False, "status": 403, "error": _admin_only};
    }
    token = "omb_sess_" + base64.urlsafe_b64encode(
        secrets.token_bytes(32)
    ).decode("ascii").rstrip("=");
    label = (
        device_label(input.get("label"))
        or device_label(pairing.get("label"))
        or device_label(input.get("fallbackLabel"))
        or "Unnamed device"
    );
    record: dict[str, any] = {
        "id": str(uuid.uuid4()),
        "tokenHash": sha256(token),
        "label": _js_slice_16(label, 0, 80),
        "scopes": list(pairing["scopes"]),
        "createdAt": now,
        "lastSeenAt": now,
        # The absolute cap applies from the first term, so a TTL
        # configured longer than the cap does not hand out a session the
        # cap forbids.
        "expiresAt": now + min(SESSION_TTL_MS, SESSION_MAX_AGE_MS),
    };
    if pairing.get("browser") is True {
        record["cookieOnly"] = True;
        if pairing.get("owner") {
            record["owner"] = pairing["owner"];
        }
    }
    _sessions.append(record);
    # The exchange itself was the first sighting.
    _last_seen_writes[record["id"]] = now;
    _persist();
    result: dict[str, any] = {"ok": True, "token": token, "session": public_session(record)};
    if attempt_id is not None {
        _replays.append({
            "codeHash": presented,
            "attemptId": attempt_id,
            "browser": browser,
            "result": result,
            "expiresAt": now + EXCHANGE_REPLAY_MS,
        });
    }
    return result;
}


def _issue_account(input: dict[str, any], membership_authority: (str | None) = None) -> dict[str, any] {
    _refuse_personal(input.get("scopes") or []);
    _prune();
    now = _now();
    token = "omb_sess_" + base64.urlsafe_b64encode(
        secrets.token_bytes(32)
    ).decode("ascii").rstrip("=");
    label = device_label(input.get("label")) or "Unnamed device";
    record: dict[str, any] = {
        "id": str(uuid.uuid4()),
        "tokenHash": sha256(token),
        "label": _js_slice_16(label, 0, 80),
        "scopes": list(dict.fromkeys(input.get("scopes") or [])),
        "createdAt": now,
        "lastSeenAt": now,
        "expiresAt": now + min(SESSION_TTL_MS, SESSION_MAX_AGE_MS),
    };
    if input.get("userId") {
        record["userId"] = input["userId"];
    }
    if input.get("email") {
        record["email"] = input["email"];
    }
    if membership_authority {
        record["membershipAuthority"] = membership_authority;
    }
    _sessions.append(record);
    _last_seen_writes[record["id"]] = now;
    _persist();
    return {"token": token, "session": public_session(record)};
}


def issue(input: dict[str, any]) -> dict[str, any] {
    # A session from a verified account sign-in (server/account-signin.ts)
    # rather than a pairing code: same token, same term, same gates.
    return _issue_account(input);
}


def issue_portal(input: dict[str, any]) -> dict[str, any] {
    # Internal hosted-bridge seam: call only after consuming a verified,
    # workspace-bound PKCE grant. No HTTP route accepts this marker as
    # input.
    grant = input.get("grant");
    grant_str = (grant if isinstance(grant, str) else str(grant));
    if not _PORTAL_GRANT_RE.fullmatch(grant_str) or not input.get("email") {
        raise RuntimeError("A verified portal identity is required");
    }
    return _issue_account(
        {
            "label": "Hosted workspace",
            "email": input["email"],
            "userId": f"portal:{grant_str}",
            "scopes": input.get("scopes"),
        },
        "portal"
    );
}


def attempt_allowed(source: str) -> dict[str, any] {
    # The pairing lockout, for other code-like exchanges on the same
    # source.
    lock = _lock_state(source);
    if lock["locked"] {
        return {"ok": False, "retryAfterMs": lock["retryAfterMs"]};
    }
    return {"ok": True};
}


def note_failure(source: str) {
    _record_failure(source);
}


def clear_failures(source: str) {
    _failures.pop(source, None);
}


def revalidate_email_sessions -> None {
    # Email membership is live, not a thirty-day grant. Losing any issued
    # scope revokes the token and its streams; signing in again obtains
    # the new role. Promotions never widen existing credentials. Pairing
    # sessions have no email and remain independent of the hosted sign-in
    # list.
    if _closed {
        raise RuntimeError("Session registry is closed.");
    }
    eligible = [
        s
        for s in _sessions
        if s.get("email") is not None
        and not (_portal_membership and s.get("membershipAuthority") == "portal")
    ];
    if not eligible {
        return;
    }
    resolve_scopes = _email_scopes;
    try {
        if _email_scopes_snapshot is not None {
            resolve_scopes = _email_scopes_snapshot();
        }
    } except Exception {
        # Never fall back to stale membership after a failed snapshot.
        resolve_scopes = None;
    }
    revoked: list[dict[str, any]] = [];
    for session in eligible {
        try {
            allowed = (resolve_scopes(session["email"]) if resolve_scopes is not None else None);
            missing = not allowed;
            if not missing {
                for scope in session["scopes"] {
                    if scope not in allowed {
                        missing = True;
                        break;
                    }
                }
            }
            if missing {
                revoked.append(session);
            }
        } except Exception {
            # Missing or unreadable membership must fail closed.
            revoked.append(session);
        }
    }
    if not revoked {
        return;
    }
    ids = set([s["id"] for s in revoked]);
    globals()["_sessions"] = [s for s in _sessions if s["id"] not in ids];
    for session in revoked {
        _forget(session["id"]);
    }
    try {
        _persist();
    } except Exception {
        # Revocation stays effective in memory and streams close. The
        # boot marker prevents old account bearers from reviving after an
        # unclean restart, even if membership is later restored and all
        # writes failed.
        print("Could not persist email session revocation.", file=sys.stderr);
    }
}


def authenticate(token: (str | None)) -> (dict[str, any] | None) {
    if not token {
        return None;
    }
    revalidate_email_sessions();
    hash_ = sha256(token);
    now = _now();
    record: any = None;
    for s in _sessions {
        if same_digest(s["tokenHash"], hash_) {
            record = s;
            break;
        }
    }
    if record is None or record["expiresAt"] <= now or _personal(record["scopes"]) {
        return None;
    }
    last_write = _last_seen_writes.get(record["id"], 0);
    if now - last_write >= LAST_SEEN_WRITE_INTERVAL_MS {
        record["lastSeenAt"] = now;
        _last_seen_writes[record["id"]] = now;
        _persist();
    }
    return record;
}


def renew(session_id: str) -> bool {
    # Sliding expiry. Called by the request gate once a request has
    # passed the origin and scope checks (so a rejected request never
    # extends anything): a still-valid session with half its term or less
    # left is renewed for the full term, capped at SESSION_MAX_AGE_MS from
    # pairing. Nothing expired is revived. Writes at most once per
    # half-term. Returns whether it renewed.
    revalidate_email_sessions();
    record: any = None;
    for s in _sessions {
        if s["id"] == session_id {
            record = s;
            break;
        }
    }
    now = _now();
    if record is None or record["expiresAt"] <= now {
        return False;
    }
    if record["expiresAt"] - now > SESSION_RENEW_WHEN_LEFT_MS {
        return False;
    }
    next_ = min(now + SESSION_TTL_MS, record["createdAt"] + SESSION_MAX_AGE_MS);
    if next_ <= record["expiresAt"] {
        # Already at the absolute cap.
        return False;
    }
    record["expiresAt"] = next_;
    record["lastSeenAt"] = now;
    _last_seen_writes[record["id"]] = now;
    _persist();
    return True;
}


def is_live(session_id: str) -> bool {
    # Still valid right now (prunes expiry first).
    _prune();
    for s in _sessions {
        if s["id"] == session_id and not _personal(s["scopes"]) {
            return True;
        }
    }
    return False;
}


def list_sessions -> list[dict[str, any]] {
    _prune();
    return [public_session(s) for s in _sessions];
}


def revoke(id: str) -> bool {
    before = len(_sessions);
    globals()["_sessions"] = [s for s in _sessions if s["id"] != id];
    if len(_sessions) == before {
        return False;
    }
    _forget(id);
    _persist();
    return True;
}


def _ticket_expires(item: any) -> any {
    return item[1]["expiresAt"];
}


def issue_stream_ticket(session_id: str) -> dict[str, any] {
    _prune();
    mine = [(h, t) for (h, t) in _tickets.items() if t["sessionId"] == session_id];
    mine = sorted(mine, key=_ticket_expires);
    drop = max(0, len(mine) - (MAX_STREAM_TICKETS_PER_SESSION - 1));
    for i in range(drop) {
        _tickets.pop(mine[i][0]);
    }
    ticket = "omb_tick_" + base64.urlsafe_b64encode(
        secrets.token_bytes(24)
    ).decode("ascii").rstrip("=");
    expires_at = _now() + STREAM_TICKET_TTL_MS;
    _tickets[sha256(ticket)] = {"sessionId": session_id, "expiresAt": expires_at};
    return {"ticket": ticket, "expiresAt": expires_at};
}


def redeem_stream_ticket(ticket: str) -> (dict[str, any] | None) {
    # Single use: a reconnecting client asks for a fresh ticket first.
    _prune();
    hash_ = sha256(ticket);
    t_entry = _tickets.get(hash_);
    if t_entry is None {
        return None;
    }
    _tickets.pop(hash_);
    now = _now();
    record: any = None;
    for s in _sessions {
        if s["id"] == t_entry["sessionId"] {
            record = s;
            break;
        }
    }
    if record is not None and record["expiresAt"] > now and not _personal(record["scopes"]) {
        return record;
    }
    return None;
}
