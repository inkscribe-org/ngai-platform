"""JSON.stringify-faithful serialization.

The messages.json column must be byte-identical to what node:sqlite stored
from JSON.stringify(message). Python's json.dumps differs in three places:
  - separators (default " , " and " : "; JSON.stringify is compact)
  - ensure_ascii (Python escapes non-ASCII by default; JS emits it raw)
  - number formatting (V8 Number::toString picks fixed vs scientific on a
    different window than CPython's repr: JS is fixed for decimal exponent
    in (-6, 21], scientific outside; repr switches at ~1e-4/1e16)

This module reimplements the ES spec's Number::toString over Python's
shortest-roundtrip digits (repr) and the JSON.stringify string/table
escaping table, so stored bytes match.
"""

import json;
import math;
import decimal;

glob _ESCAPE: dict[str, str] = {
    '"': '\\"',
    "\\": "\\\\",
    "\b": "\\b",
    "\f": "\\f",
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
};


def js_string(value: str) -> str {
    out: list[str] = ['"'];
    for ch in value {
        esc = _ESCAPE.get(ch);
        if esc is not None {
            out.append(esc);
            continue;
        }
        code = ord(ch);
        # Control characters and lone surrogates are escaped; everything
        # else — including non-ASCII — is emitted raw, as V8 does.
        if code < 0x20 or 0xD800 <= code <= 0xDFFF {
            out.append(f"\\u{code:04x}");
        } else {
            out.append(ch);
        }
    }
    out.append('"');
    return "".join(out);
}


def _js_magnitude(digits: str, n: int) -> str {
    # digits has no leading/trailing zeros; value = int(digits) * 10^(n - len(digits)).
    # Applies the ES Number::toString layout rules.
    k = len(digits);
    if k <= n <= 21 {
        return digits + ("0" * (n - k));
    }
    if 0 < n <= 21 {
        return digits[0:n] + "." + digits[n:];
    }
    if -6 < n <= 0 {
        return "0." + ("0" * (-n)) + digits;
    }
    exp = n - 1;
    sign = "+" if exp >= 0 else "-";
    if k == 1 {
        return f"{digits}e{sign}{abs(exp)}";
    }
    return f"{digits[0]}.{digits[1:]}e{sign}{abs(exp)}";
}


def js_number(value: any) -> str {
    if isinstance(value, bool) {
        return "true" if value else "false";
    }
    if isinstance(value, int) {
        return str(value);
    }
    f = float(value);
    if math.isnan(f) or math.isinf(f) {
        # JSON.stringify emits null for non-finite numbers.
        return "null";
    }
    if f == 0 {
        # -0 serializes as 0.
        return "0";
    }
    sign_str = "";
    if f < 0 {
        sign_str = "-";
        f = -f;
    }
    # repr(f) is CPython's shortest round-trip decimal — the same digit
    # sequence V8 derives, only the layout differs.
    d = decimal.Decimal(repr(f));
    tup = d.as_tuple();
    digits = "".join(str(x) for x in tup.digits);
    # Strip trailing zeros; Decimal(repr()) of e.g. 1e21 gives exponent form
    # with digits possibly carrying none anyway, but be exact.
    digits = digits.rstrip("0") or "0";
    # value = int(digits_orig) * 10^exp; n = decimal point position such that
    # value = 0.<digits> * 10^n  ... i.e. n = len(digits_orig) + exp.
    n = len(tup.digits) + tup.exponent;
    return sign_str + _js_magnitude(digits, n);
}


def js_stringify(value: any) -> str {
    if value is None {
        return "null";
    }
    if isinstance(value, bool) {
        return "true" if value else "false";
    }
    if isinstance(value, int) or isinstance(value, float) {
        return js_number(value);
    }
    if isinstance(value, str) {
        return js_string(value);
    }
    if isinstance(value, list) or isinstance(value, tuple) {
        return "[" + ",".join(js_stringify(v) for v in value) + "]";
    }
    if isinstance(value, dict) {
        parts: list[str] = [];
        for (k, v) in value.items() {
            # JSON.stringify drops keys whose value is undefined; Python has
            # no undefined, so dicts simply omit absent keys upstream.
            parts.append(js_string(str(k)) + ":" + js_stringify(v));
        }
        return "{" + ",".join(parts) + "}";
    }
    # Fallback for odd objects: match JS by stringifying is wrong; fail loud.
    raise TypeError(f"js_stringify cannot serialize {type(value).__name__}");
}
