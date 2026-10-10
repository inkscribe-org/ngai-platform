"""Shared harness helpers.

One home for the plumbing every phase-4 port had copied: the shared-secret
op guard and `{ok:false,status,error}` failure envelope, status-carrying
errors, the jac -> node bridge transport, server/atomic.ts writeFileAtomic,
JSON.stringify(_, null, 2), shared/redact.ts, and JS text/time helpers.
Behavior is byte-identical to the copies it replaced; module-specific
policy (stub replies, swallowed bridge errors, test injection) stays in
the calling module.
"""

import os;
import re;
import json;
import hmac;
import time;
import uuid;
import datetime;
import urllib.request;

import from jsutil { js_string, js_stringify }

# ── JS text semantics ──────────────────────────────────────────────────────
# JS WhiteSpace + FEFF: what String.prototype.trim strips and /\s/ matches.
# Python's \s is broader (\x1c-\x1f, \x85), so regexes that must match JS
# byte-for-byte are built from JS_S_CLASS.

glob JS_WS_CHARS: str = (
    "\t\n\x0b\x0c\r \xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005"
    "\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"
);
# The same set as a character-class body (\u2000-\u200a is a range).
glob _JS_WS_CLASS_BODY: str = "\t\n\x0b\x0c\r \xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff";
glob JS_S_CLASS: str = "[" + _JS_WS_CLASS_BODY + "]";

def js_len(text: str) -> int {
    # JS .length counts UTF-16 code units: non-BMP chars count 2.
    return len(text.encode("utf-16-le", "surrogatepass")) // 2;
}

def js_trim(text: str) -> str {
    return text.strip(JS_WS_CHARS);
}

# JSON.stringify drops own keys whose value is `undefined` and writes an
# undefined array element as null. Ports that model undefined use UNDEF.
class _Undefined {
    # Falsy like JS undefined.
    def __bool__(self: any) -> bool {
        return False;
    }
}

glob UNDEF: any = _Undefined();

def js_pretty(value: any, level: int = 0) -> str {
    # JSON.stringify(value, null, 2): objects and arrays spread over lines,
    # primitives via the jsutil byte-exact writers.
    if isinstance(value, dict) {
        items = [(k, v) for (k, v) in value.items() if v is not UNDEF];
        if not items {
            return "{}";
        }
        gap = "  " * (level + 1);
        base = "  " * level;
        parts: list[str] = [];
        for (k, v) in items {
            parts.append(gap + js_string(str(k)) + ": " + js_pretty(v, level + 1));
        }
        return "{\n" + ",\n".join(parts) + "\n" + base + "}";
    }
    if isinstance(value, (list, tuple)) {
        if not value {
            return "[]";
        }
        gap = "  " * (level + 1);
        base = "  " * level;
        parts: list[str] = [];
        for v in value {
            parts.append(gap + js_pretty(v, level + 1));
        }
        return "[\n" + ",\n".join(parts) + "\n" + base + "]";
    }
    if value is UNDEF {
        return "null";
    }
    return js_stringify(value);
}

# ── time / ids ─────────────────────────────────────────────────────────────

def now_ms -> int {
    return int(time.time() * 1000);
}

def iso_from_ms(ms: int) -> str {
    # new Date(ms).toISOString() (floor semantics hold for negative ms).
    d = datetime.datetime.fromtimestamp(ms // 1000, datetime.timezone.utc);
    return d.strftime("%Y-%m-%dT%H:%M:%S") + "." + str(ms % 1000).zfill(3) + "Z";
}

def iso_now -> str {
    # One clock read: seconds and milliseconds must come from the same instant.
    return iso_from_ms(now_ms());
}

def new_uuid -> str {
    return str(uuid.uuid4());
}

# ── status-carrying errors + op surface ────────────────────────────────────
# JS `Object.assign(new Error(message), {status})`.

class StatusError(Exception) {
    # Error carrying an HTTP status in `.status`.
}

def status_error(message: str, status: int, cls: any = None) -> Exception {
    err = (cls if cls is not None else StatusError)(message);
    setattr(err, "status", status);
    return err;
}

def status_of(e: any, default_status: int = 500) -> int {
    s = getattr(e, "status", None);
    if isinstance(s, int) and not isinstance(s, bool) {
        return s;
    }
    return default_status;
}

def failure(e: any, default_status: int = 500, with_code: bool = False) -> dict[str, any] {
    out: dict[str, any] = {"ok": False, "status": status_of(e, default_status), "error": str(e)};
    if with_code {
        code = getattr(e, "code", None);
        if isinstance(code, str) {
            out["code"] = code;
        }
    }
    return out;
}

def token_ok(omb_token: any) -> bool {
    # The shared secret node passes as `omb_token` on every op; unset means
    # an unguarded dev/conformance harness. Constant-time compare.
    want = os.environ.get("OMB_JAC_TOKEN");
    if not want {
        return True;
    }
    if not isinstance(omb_token, str) {
        return False;
    }
    return hmac.compare_digest(omb_token.encode("utf-8"), want.encode("utf-8"));
}

def guard(omb_token: any, status: int = 403, error: str = "unauthorized") -> any {
    # None when the call may proceed, else the failure envelope to return.
    if token_ok(omb_token) {
        return None;
    }
    return {"ok": False, "status": status, "error": error};
}

def invoke(omb_token: any, fn: any, default_status: int = 500, with_code: bool = False) -> any {
    # guard -> fn() -> {ok:false,status,error} on any raise.
    g = guard(omb_token);
    if g is not None {
        return g;
    }
    try {
        return fn();
    } except Exception as e {
        return failure(e, default_status, with_code);
    }
}

# ── jac -> node bridge transport ───────────────────────────────────────────
# Callers keep their own injection/stub policy; this is only the wire.

def bridge_url_from_env -> str {
    # "" when no node is configured (stub mode).
    base = os.environ.get("OMB_ROUTINES_BRIDGE_URL") or os.environ.get("OMB_NODE_URL");
    return (base.rstrip("/") + "/api/internal/routine-bridge") if base else "";
}

def bridge_post(url: str, call: dict[str, any], timeout: float = 5) -> dict[str, any] {
    # POST {op, ...payload}; the shared secret rides in x-omb-jac-token.
    # Raises on transport/HTTP errors; a non-object reply reads as {}.
    body = json.dumps(call).encode("utf-8");
    headers = {"content-type": "application/json"};
    token = os.environ.get("OMB_JAC_TOKEN");
    if token {
        headers["x-omb-jac-token"] = token;
    }
    req = urllib.request.Request(url, data=body, headers=headers, method="POST");
    resp = urllib.request.urlopen(req, timeout=timeout);
    try {
        raw = resp.read().decode("utf-8");
    } finally {
        resp.close();
    }
    if not raw {
        return {};
    }
    parsed = json.loads(raw);
    return parsed if isinstance(parsed, dict) else {};
}

# ── server/atomic.ts writeFileAtomic ───────────────────────────────────────
# Sibling `<path>.<pid>.<uuid>.tmp` (the name workspace-backup-policy.ts
# recognizes), fsync, rename over the target. The mode goes on the temp
# inode so a broader-permission file is never visible.

glob RENAME_RETRY_DELAYS_MS: list[any] = [5, 10, 20, 40, 80];
glob _RETRYABLE_RENAME_ERRNOS: any = frozenset({1, 13, 16});  # EPERM EACCES EBUSY

def rename_with_retry(tmp: str, path: str) -> None {
    attempt = 0;
    while True {
        try {
            os.replace(tmp, path);
            return;
        } except OSError as e {
            if e.errno not in _RETRYABLE_RENAME_ERRNOS or attempt >= len(RENAME_RETRY_DELAYS_MS) {
                raise;
            }
            time.sleep(RENAME_RETRY_DELAYS_MS[attempt] / 1000);
        }
        attempt += 1;
    }
}

def write_file_atomic(path: str, data: any, mode: (int | None) = None, durable: bool = True) -> None {
    # data: str (written as UTF-8) or bytes.
    payload = data if isinstance(data, (bytes, bytearray)) else data.encode("utf-8");
    tmp = f"{path}.{os.getpid()}.{uuid.uuid4()}.tmp";
    fd: any = None;
    try {
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, (mode if mode is not None else 0o666));
        if mode is not None {
            # The umask may have narrowed or (with group bits) kept extra bits.
            os.fchmod(fd, mode);
        }
        view = memoryview(payload);
        while len(view) > 0 {
            view = view[os.write(fd, view):];
        }
        if durable {
            os.fsync(fd);
        }
        os.close(fd);
        fd = None;
        rename_with_retry(tmp, path);
    } except Exception {
        if fd is not None {
            try {
                os.close(fd);
            } except Exception { }
        }
        try {
            os.unlink(tmp);
        } except Exception { }
        raise;
    }
}

def write_json_private(path: str, value: any, durable: bool = True) -> None {
    # The JSON stores node owns: JSON.stringify(_, null, 2), mode 0600.
    dirn = os.path.dirname(path) or ".";
    os.makedirs(dirn, exist_ok=True);
    write_file_atomic(path, js_pretty(value), 0o600, durable);
}

# ── shared/redact.ts ───────────────────────────────────────────────────────
# A credential becomes «redacted N chars» (N in UTF-16 units); the marker
# itself is never re-masked. re.ASCII gives JS's ASCII \b and \d; every \s
# is the JS whitespace class; JS `$` (no m flag) is \Z.

glob _REDACTION_MARKER: any = re.compile(r"^«redacted \d+ chars»\Z", re.ASCII);
glob _KEY_PREFIXES: list[any] = [
    re.compile(r"\bom[dg]_[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])", re.ASCII),  # desktop device and model-only credentials
    re.compile(r"\bsk-(?:ant-|proj-|live-|test-)?[A-Za-z0-9_-]{16,}", re.ASCII),  # anthropic / openai / stripe
    re.compile(r"\bxai-[A-Za-z0-9_-]{20,}", re.ASCII),  # xai (grok)
    re.compile(r"\bgsk_[A-Za-z0-9]{40,}", re.ASCII),  # groq
    re.compile(r"\bcsk-[A-Za-z0-9]{32,}", re.ASCII),  # cerebras
    re.compile(r"\bhf_[A-Za-z0-9]{30,}", re.ASCII),  # hugging face
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}", re.ASCII),  # github classic
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}", re.ASCII),  # github fine-grained
    re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{20,}", re.ASCII),  # slack
    re.compile(r"\bAKIA[0-9A-Z]{16}\b", re.ASCII),  # aws access key id
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}", re.ASCII),  # google api key
    re.compile(r"\bnpm_[A-Za-z0-9]{20,}", re.ASCII),  # npm
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b", re.ASCII),  # jwt
];
glob _PEM_BLOCK: any = re.compile(
    r"(-----BEGIN [A-Z ]*PRIVATE KEY-----)([\s\S]*?)(-----END [A-Z ]*PRIVATE KEY-----)", re.ASCII
);
glob _BEARER: any = re.compile(r"(\bBearer" + JS_S_CLASS + r"+)([A-Za-z0-9._~+/=-]{12,})", re.ASCII);
# key=value / key: value / key="value" where the key is secret-shaped.
glob _KEY_VALUE: any = re.compile(
    r"\b((?:[A-Za-z0-9_-]*_)?(?:api[_-]?key|apikey|secret|token|password|passwd|authorization|auth[_-]?token|access[_-]?key|private[_-]?key)s?)"
    r"([\"']?" + JS_S_CLASS + r"*[=:]" + JS_S_CLASS + r"*)([\"']?)([A-Za-z0-9._~+/=-]{8,})\3",
    re.ASCII | re.IGNORECASE
);
# X_KEY=value: an assignment to a name that ENDS in key is a credential.
glob _KEY_SUFFIX_ASSIGNMENT: any = re.compile(
    r"\b([A-Za-z][A-Za-z0-9_-]*[_-]key)s?(=)([\"']?)([A-Za-z0-9._~+/=-]+)\3",
    re.ASCII | re.IGNORECASE
);
# --token abc, --password=abc: the flag names a secret.
glob _SECRET_FLAG: any = re.compile(
    r"(--(?:token|password|passwd|api-key|apikey|secret|access-key|auth-token)(?:=|" + JS_S_CLASS + r"+))([\"']?)(?!-)([A-Za-z0-9._~+/=-]+)\2",
    re.ASCII | re.IGNORECASE
);
# scheme://user:secret@host: the password in a URL's userinfo.
glob _URL_USERINFO: any = re.compile(
    r"(\b[a-z][a-z0-9+.-]*://[^" + _JS_WS_CLASS_BODY + r"/:@'\"]+:)([^" + _JS_WS_CLASS_BODY + r"/@'\"«»]+)(@)",
    re.ASCII | re.IGNORECASE
);

def redact_mask(value: str) -> str {
    # Keep repeated redaction byte-for-byte stable.
    if _REDACTION_MARKER.match(value) {
        return value;
    }
    return f"«redacted {js_len(value)} chars»";
}

def _sub_mask(m: any) -> str {
    return redact_mask(m.group(0));
}

def _sub_pem(m: any) -> str {
    return m.group(1) + "\n" + redact_mask(js_trim(m.group(2))) + "\n" + m.group(3);
}

def _sub_bearer(m: any) -> str {
    return m.group(1) + redact_mask(m.group(2));
}

def _sub_key_value(m: any) -> str {
    return m.group(1) + m.group(2) + m.group(3) + redact_mask(m.group(4)) + m.group(3);
}

def _sub_flag(m: any) -> str {
    return m.group(1) + m.group(2) + redact_mask(m.group(3)) + m.group(2);
}

def _sub_userinfo(m: any) -> str {
    return m.group(1) + redact_mask(m.group(2)) + m.group(3);
}

def redact_secrets_in_text(text: any) -> any {
    # Non-strings (undefined/null in JS) and short strings pass through.
    if not isinstance(text, str) or js_len(text) < 8 {
        return text;
    }
    out = _PEM_BLOCK.sub(_sub_pem, text);
    for pattern in _KEY_PREFIXES {
        out = pattern.sub(_sub_mask, out);
    }
    out = _BEARER.sub(_sub_bearer, out);
    out = _KEY_VALUE.sub(_sub_key_value, out);
    out = _KEY_SUFFIX_ASSIGNMENT.sub(_sub_key_value, out);
    out = _SECRET_FLAG.sub(_sub_flag, out);
    out = _URL_USERINFO.sub(_sub_userinfo, out);
    return out;
}
