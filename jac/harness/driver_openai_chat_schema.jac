"""JSON Schema validation for chat MCP tools — the Jac stand-in for the Ajv
(+ ajv-formats) compiler in server/drivers/chat-mcp-tools.ts.

A schema is a contract, so a conversion that drops constraints is not safe:
the same schema sent to the provider is validated here without coercing
values, applying defaults, removing fields or fetching external references.
Ajv's strict mode is mirrored by refusing what cannot be validated — an
unknown keyword, an unregistered format, a non-local $ref — at compile time
instead of silently weakening the check. Draft-07 and 2020-12 only."""

import re;
import json;
import math;
import ipaddress;

glob DRAFT_07: str = "http://json-schema.org/draft-07/schema#";
glob DRAFT_2020: str = "https://json-schema.org/draft/2020-12/schema";

glob SCHEMA_ERROR: str = "MCP tool schema could not be validated; check its constraints, formats, and references";
glob DIALECT_ERROR: str = "MCP tool schema uses an unsupported dialect; use JSON Schema draft-07 or 2020-12";

class SchemaCompileError(Exception) {
}

# Keywords that only annotate: accepted, never asserted.
glob ANNOTATIONS: list[str] = [
    "$schema", "$id", "$comment", "$defs", "definitions", "$anchor",
    "title", "description", "default", "examples", "deprecated",
    "readOnly", "writeOnly", "contentMediaType", "contentEncoding",
];
glob ASSERTIONS: list[str] = [
    "$ref", "type", "enum", "const", "multipleOf", "maximum", "exclusiveMaximum",
    "minimum", "exclusiveMinimum", "maxLength", "minLength", "pattern",
    "maxItems", "minItems", "uniqueItems", "maxContains", "minContains",
    "maxProperties", "minProperties", "required", "dependentRequired",
    "dependencies", "format", "allOf", "anyOf", "oneOf", "not", "if", "then",
    "else", "properties", "patternProperties", "additionalProperties",
    "propertyNames", "items", "prefixItems", "additionalItems", "contains",
    "dependentSchemas",
];
glob TYPES: list[str] = ["null", "boolean", "object", "array", "number", "integer", "string"];

# ── formats (ajv-formats "full" + the two the runtime registers) ──────────

glob F: int = re.I | re.A;
glob DATE_RE: any = re.compile(r"^(\d\d\d\d)-(\d\d)-(\d\d)\Z", re.A);
glob TIME_RE: any = re.compile(r"^(\d\d):(\d\d):(\d\d(?:\.\d+)?)(z|([+-])(\d\d)(?::?(\d\d))?)?\Z", F);
glob DAYS: list[int] = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
glob DATE_TIME_SEP_RE: any = re.compile(r"t|\s", F);
glob DURATION_RE: any = re.compile(r"^P(?!$)((\d+Y)?(\d+M)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+S)?)?|(\d+W)?)\Z", re.A);
glob NOT_URI_FRAGMENT_RE: any = re.compile(r"/|:");
glob H16: str = r"[0-9a-f]{1,4}";
glob IPV4_PART: str = r"(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)";
glob IPV6_LIT: str = (
    r"(?:(?:(?:(?:[0-9a-f]{1,4}:){6}|::(?:[0-9a-f]{1,4}:){5}|(?:[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){4}|(?:(?:[0-9a-f]{1,4}:){0,1}[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){3}|(?:(?:[0-9a-f]{1,4}:){0,2}[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){2}|(?:(?:[0-9a-f]{1,4}:){0,3}[0-9a-f]{1,4})?::[0-9a-f]{1,4}:|(?:(?:[0-9a-f]{1,4}:){0,4}[0-9a-f]{1,4})?::)(?:[0-9a-f]{1,4}:[0-9a-f]{1,4}|"
    + IPV4_PART
    + r")|(?:(?:[0-9a-f]{1,4}:){0,5}[0-9a-f]{1,4})?::[0-9a-f]{1,4}|(?:(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{1,4})?::)|[Vv][0-9a-f]+\.[a-z0-9\-._~!$&'()*+,;=:]+)"
);
glob URI_TAIL: str = (
    r"(?:\/?\/(?:(?:[a-z0-9\-._~!$&'()*+,;=:]|%[0-9a-f]{2})*@)?(?:\["
    + IPV6_LIT
    + r"\]|"
    + IPV4_PART
    + r"|(?:[a-z0-9\-._~!$&'()*+,;=]|%[0-9a-f]{2})*)(?::\d*)?(?:\/(?:[a-z0-9\-._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*|\/(?:(?:[a-z0-9\-._~!$&'()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[a-z0-9\-._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*)?|(?:[a-z0-9\-._~!$&'()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[a-z0-9\-._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*)(?:\?(?:[a-z0-9\-._~!$&'()*+,;=:@/?]|%[0-9a-f]{2})*)?(?:#(?:[a-z0-9\-._~!$&'()*+,;=:@/?]|%[0-9a-f]{2})*)?\Z"
);
glob URI_RE: any = re.compile(r"^(?:[a-z][a-z0-9+\-.]*:)" + URI_TAIL, F);
glob URI_REF_RE: any = re.compile(
    r"^(?:[a-z][a-z0-9+\-.]*:)?(?:\/?\/(?:(?:[a-z0-9\-._~!$&'()*+,;=:]|%[0-9a-f]{2})*@)?(?:\["
    + IPV6_LIT
    + r"\]|"
    + IPV4_PART
    + r"|(?:[a-z0-9\-._~!$&'\"()*+,;=]|%[0-9a-f]{2})*)(?::\d*)?(?:\/(?:[a-z0-9\-._~!$&'\"()*+,;=:@]|%[0-9a-f]{2})*)*|\/(?:(?:[a-z0-9\-._~!$&'\"()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[a-z0-9\-._~!$&'\"()*+,;=:@]|%[0-9a-f]{2})*)*)?|(?:[a-z0-9\-._~!$&'\"()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[a-z0-9\-._~!$&'\"()*+,;=:@]|%[0-9a-f]{2})*)*)?(?:\?(?:[a-z0-9\-._~!$&'\"()*+,;=:@/?]|%[0-9a-f]{2})*)?(?:#(?:[a-z0-9\-._~!$&'\"()*+,;=:@/?]|%[0-9a-f]{2})*)?\Z",
    F
);
glob URI_TEMPLATE_RE: any = re.compile(r"^(?:(?:[^\x00-\x20\"'<>%\\^`{|}]|%[0-9a-f]{2})|\{[+#./;?&=,!@|]?(?:[a-z0-9_]|%[0-9a-f]{2})+(?::[1-9][0-9]{0,3}|\*)?(?:,(?:[a-z0-9_]|%[0-9a-f]{2})+(?::[1-9][0-9]{0,3}|\*)?)*\})*\Z", F);
glob URL_RE: any = re.compile(r"^(?:https?|ftp):\/\/(?:\S+(?::\S*)?@)?(?:(?!(?:10|127)(?:\.\d{1,3}){3})(?!(?:169\.254|192\.168)(?:\.\d{1,3}){2})(?!172\.(?:1[6-9]|2\d|3[0-1])(?:\.\d{1,3}){2})(?:[1-9]\d?|1\d\d|2[01]\d|22[0-3])(?:\.(?:1?\d{1,2}|2[0-4]\d|25[0-5])){2}(?:\.(?:[1-9]\d?|1\d\d|2[0-4]\d|25[0-4]))|(?:(?:[a-z0-9¡-￿]+-)*[a-z0-9¡-￿]+)(?:\.(?:[a-z0-9¡-￿]+-)*[a-z0-9¡-￿]+)*(?:\.(?:[a-z¡-￿]{2,})))(?::\d{2,5})?(?:\/[^\s]*)?\Z", F);
glob EMAIL_RE: any = re.compile(r"^[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\Z", F);
glob HOSTNAME_RE: any = re.compile(r"^(?=.{1,253}\.?\Z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[-0-9a-z]{0,61}[0-9a-z])?)*\.?\Z", F);
glob IPV4_RE: any = re.compile(r"^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\Z", re.A);
glob UUID_RE: any = re.compile(r"^(?:urn:uuid:)?[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\Z", F);
glob JSON_POINTER_RE: any = re.compile(r"^(?:\/(?:[^~/]|~0|~1)*)*\Z");
glob JSON_POINTER_FRAG_RE: any = re.compile(r"^#(?:\/(?:[a-z0-9_\-.!$&'()*+,;:=@]|%[0-9a-f]{2}|~0|~1)*)*\Z", F);
glob REL_JSON_POINTER_RE: any = re.compile(r"^(?:0|[1-9][0-9]*)(?:#|(?:\/(?:[^~/]|~0|~1)*)*)\Z");
glob BYTE_RE: any = re.compile(r"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$", re.M);
glob Z_ANCHOR_RE: any = re.compile(r"[^\\]\\Z");

def is_number(value: any) -> bool {
    return isinstance(value, (int, float)) and not isinstance(value, bool);
}

def is_integer(value: any) -> bool {
    if isinstance(value, bool) { return False; }
    if isinstance(value, int) { return True; }
    return isinstance(value, float) and math.isfinite(value) and value.is_integer();
}

def _leap(year: int) -> bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

def _date(s: str) -> bool {
    m = DATE_RE.match(s);
    if m is None { return False; }
    year = int(m.group(1));
    month = int(m.group(2));
    day = int(m.group(3));
    if month < 1 or month > 12 or day < 1 { return False; }
    limit = 29 if (month == 2 and _leap(year)) else DAYS[month];
    return day <= limit;
}

def _time(s: str, strict_tz: bool) -> bool {
    m = TIME_RE.match(s);
    if m is None { return False; }
    hr = int(m.group(1));
    mn = int(m.group(2));
    sec = float(m.group(3));
    tz = m.group(4);
    tz_sign = -1 if m.group(5) == "-" else 1;
    tz_h = int(m.group(6) or "0");
    tz_m = int(m.group(7) or "0");
    if tz_h > 23 or tz_m > 59 or (strict_tz and not tz) { return False; }
    if hr <= 23 and mn <= 59 and sec < 60 { return True; }
    utc_min = mn - tz_m * tz_sign;
    utc_hr = hr - tz_h * tz_sign - (1 if utc_min < 0 else 0);
    return (utc_hr == 23 or utc_hr == -1) and (utc_min == 59 or utc_min == -1) and sec < 61;
}

def _date_time(s: str, strict_tz: bool) -> bool {
    parts = DATE_TIME_SEP_RE.split(s);
    return len(parts) == 2 and _date(parts[0]) and _time(parts[1], strict_tz);
}

def _ipv6(s: str) -> bool {
    if "%" in s or "/" in s { return False; }
    try {
        ipaddress.IPv6Address(s);
        return True;
    } except Exception {
        return False;
    }
}

def _regex_format(s: str) -> bool {
    if Z_ANCHOR_RE.search(s) is not None { return False; }
    try {
        re.compile(s);
        return True;
    } except Exception {
        return False;
    }
}

# name -> ("string" | "number", checker)
def _string_format(name: str, s: str) -> bool {
    if name == "date" { return _date(s); }
    if name == "time" { return _time(s, True); }
    if name == "date-time" { return _date_time(s, True); }
    if name == "iso-time" { return _time(s, False); }
    if name == "iso-date-time" { return _date_time(s, False); }
    if name == "duration" { return DURATION_RE.match(s) is not None; }
    if name == "uri" { return NOT_URI_FRAGMENT_RE.search(s) is not None and URI_RE.match(s) is not None; }
    if name == "uri-reference" { return URI_REF_RE.match(s) is not None; }
    if name == "uri-template" { return URI_TEMPLATE_RE.match(s) is not None; }
    if name == "url" { return URL_RE.match(s) is not None; }
    if name == "email" { return EMAIL_RE.match(s) is not None; }
    if name == "hostname" { return HOSTNAME_RE.match(s) is not None; }
    if name == "ipv4" { return IPV4_RE.match(s) is not None; }
    if name == "ipv6" { return _ipv6(s); }
    if name == "regex" { return _regex_format(s); }
    if name == "uuid" { return UUID_RE.match(s) is not None; }
    if name == "json-pointer" { return JSON_POINTER_RE.match(s) is not None; }
    if name == "json-pointer-uri-fragment" { return JSON_POINTER_FRAG_RE.match(s) is not None; }
    if name == "relative-json-pointer" { return REL_JSON_POINTER_RE.match(s) is not None; }
    if name == "byte" { return BYTE_RE.search(s) is not None; }
    return True;   # password, binary
}

glob STRING_FORMATS: list[str] = [
    "date", "time", "date-time", "iso-time", "iso-date-time", "duration", "uri",
    "uri-reference", "uri-template", "url", "email", "hostname", "ipv4", "ipv6",
    "regex", "uuid", "json-pointer", "json-pointer-uri-fragment",
    "relative-json-pointer", "byte", "password", "binary",
];
glob NUMBER_FORMATS: list[str] = ["int32", "int64", "float", "double", "uint32", "uint64"];

def _number_format(name: str, n: any) -> bool {
    if name == "int32" { return is_integer(n) and n <= 2147483647 and n >= -2147483648; }
    if name == "int64" { return is_integer(n); }
    if name == "uint32" { return is_integer(n) and n >= 0 and n <= 4294967295; }
    if name == "uint64" { return is_integer(n) and abs(n) <= 9007199254740991 and n >= 0; }
    return True;   # float, double
}

# ── equality with JSON (JS) semantics ─────────────────────────────────────

def json_equal(a: any, b: any) -> bool {
    if isinstance(a, bool) or isinstance(b, bool) {
        return isinstance(a, bool) and isinstance(b, bool) and a == b;
    }
    if is_number(a) and is_number(b) { return a == b; }
    if isinstance(a, str) and isinstance(b, str) { return a == b; }
    if a is None or b is None { return a is None and b is None; }
    if isinstance(a, list) and isinstance(b, list) {
        if len(a) != len(b) { return False; }
        for i in range(len(a)) {
            if not json_equal(a[i], b[i]) { return False; }
        }
        return True;
    }
    if isinstance(a, dict) and isinstance(b, dict) {
        if len(a) != len(b) { return False; }
        for (k, v) in a.items() {
            if k not in b or not json_equal(v, b[k]) { return False; }
        }
        return True;
    }
    return False;
}

def _type_ok(t: str, value: any) -> bool {
    if t == "null" { return value is None; }
    if t == "boolean" { return isinstance(value, bool); }
    if t == "object" { return isinstance(value, dict); }
    if t == "array" { return isinstance(value, list); }
    if t == "number" { return is_number(value) and math.isfinite(value); }
    if t == "integer" { return is_integer(value); }
    if t == "string" { return isinstance(value, str); }
    return False;
}

def _utf16_length(s: str) -> int {
    # Ajv counts code points (ucs2length), which is Python's len().
    return len(s);
}

# ── compile: strict structural check of the whole tree ────────────────────

def _fail() {
    raise SchemaCompileError(SCHEMA_ERROR);
}

def _pointer(top: any, ref: str) -> any {
    # Local refs only: "#", "#/json/pointer", or "#anchor".
    if not ref.startswith("#") { _fail(); }
    frag = ref[1:];
    if frag == "" { return top; }
    if not frag.startswith("/") {
        found = _find_anchor(top, frag);
        if found is None { _fail(); }
        return found;
    }
    cur = top;
    for raw in frag[1:].split("/") {
        part = raw.replace("~1", "/").replace("~0", "~");
        part = re.sub(r"%([0-9A-Fa-f]{2})", _pct, part);
        if isinstance(cur, dict) and part in cur {
            cur = cur[part];
        } elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur) {
            cur = cur[int(part)];
        } else {
            _fail();
        }
    }
    if not (isinstance(cur, dict) or isinstance(cur, bool)) { _fail(); }
    return cur;
}

def _pct(m: any) -> str {
    return chr(int(m.group(1), 16));
}

def _find_anchor(cur: any, anchor: str) -> any {
    if isinstance(cur, dict) {
        if cur.get("$anchor") == anchor { return cur; }
        for v in cur.values() {
            hit = _find_anchor(v, anchor);
            if hit is not None { return hit; }
        }
    } elif isinstance(cur, list) {
        for v in cur {
            hit = _find_anchor(v, anchor);
            if hit is not None { return hit; }
        }
    }
    return None;
}

def _non_negative_int(value: any) -> bool {
    return is_integer(value) and value >= 0;
}

def _check(top: any, schema: any, dialect: str, depth: int) {
    if depth > 64 { _fail(); }
    if isinstance(schema, bool) { return; }
    if not isinstance(schema, dict) { _fail(); }
    for key in schema.keys() {
        if key not in ANNOTATIONS and key not in ASSERTIONS { _fail(); }
    }
    def sub(value: any) { _check(top, value, dialect, depth + 1); }
    def sub_map(value: any) {
        if not isinstance(value, dict) { _fail(); }
        for v in value.values() { sub(v); }
    }
    def sub_list(value: any) {
        if not isinstance(value, list) or len(value) == 0 { _fail(); }
        for v in value { sub(v); }
    }
    if "$ref" in schema {
        ref = schema["$ref"];
        if not isinstance(ref, str) { _fail(); }
        _pointer(top, ref);
    }
    if "$defs" in schema { sub_map(schema["$defs"]); }
    if "definitions" in schema { sub_map(schema["definitions"]); }
    if "type" in schema {
        t = schema["type"];
        names = t if isinstance(t, list) else [t];
        if len(names) == 0 { _fail(); }
        for n in names {
            if not isinstance(n, str) or n not in TYPES { _fail(); }
        }
    }
    if "enum" in schema and not isinstance(schema["enum"], list) { _fail(); }
    for k in ["multipleOf"] {
        if k in schema and (not is_number(schema[k]) or schema[k] <= 0) { _fail(); }
    }
    for k in ["maximum", "minimum", "exclusiveMaximum", "exclusiveMinimum"] {
        if k in schema and not is_number(schema[k]) { _fail(); }
    }
    for k in ["maxLength", "minLength", "maxItems", "minItems", "maxContains", "minContains", "maxProperties", "minProperties"] {
        if k in schema and not _non_negative_int(schema[k]) { _fail(); }
    }
    if "uniqueItems" in schema and not isinstance(schema["uniqueItems"], bool) { _fail(); }
    if "pattern" in schema {
        if not isinstance(schema["pattern"], str) { _fail(); }
        try { re.compile(schema["pattern"]); } except Exception { _fail(); }
    }
    if "required" in schema {
        req = schema["required"];
        if not isinstance(req, list) { _fail(); }
        for r in req {
            if not isinstance(r, str) { _fail(); }
        }
    }
    if "dependentRequired" in schema {
        dr = schema["dependentRequired"];
        if not isinstance(dr, dict) { _fail(); }
        for v in dr.values() {
            if not isinstance(v, list) { _fail(); }
        }
    }
    if "dependencies" in schema {
        deps = schema["dependencies"];
        if not isinstance(deps, dict) { _fail(); }
        for v in deps.values() {
            if not isinstance(v, list) { sub(v); }
        }
    }
    if "dependentSchemas" in schema { sub_map(schema["dependentSchemas"]); }
    if "format" in schema {
        f = schema["format"];
        if not isinstance(f, str) or (f not in STRING_FORMATS and f not in NUMBER_FORMATS) { _fail(); }
    }
    for k in ["allOf", "anyOf", "oneOf"] {
        if k in schema { sub_list(schema[k]); }
    }
    for k in ["not", "if", "then", "else", "additionalProperties", "propertyNames", "contains", "additionalItems"] {
        if k in schema { sub(schema[k]); }
    }
    if "properties" in schema { sub_map(schema["properties"]); }
    if "patternProperties" in schema {
        pp = schema["patternProperties"];
        if not isinstance(pp, dict) { _fail(); }
        for (pat, v) in pp.items() {
            try { re.compile(pat); } except Exception { _fail(); }
            sub(v);
        }
    }
    if "prefixItems" in schema {
        if dialect != "2020" { _fail(); }
        sub_list(schema["prefixItems"]);
    }
    if "items" in schema {
        items = schema["items"];
        if isinstance(items, list) {
            if dialect == "2020" { _fail(); }
            for v in items { sub(v); }
        } else {
            sub(items);
        }
    }
}

# ── validate ───────────────────────────────────────────────────────────────

def _valid(top: any, schema: any, data: any, depth: int) -> bool {
    if depth > 256 { return False; }
    if schema is True { return True; }
    if schema is False { return False; }
    def v(s: any, d: any) -> bool { return _valid(top, s, d, depth + 1); }
    if "$ref" in schema {
        if not v(_pointer(top, schema["$ref"]), data) { return False; }
    }
    if "type" in schema {
        t = schema["type"];
        names = t if isinstance(t, list) else [t];
        ok = False;
        for n in names {
            if _type_ok(n, data) { ok = True; }
        }
        if not ok { return False; }
    }
    if "enum" in schema {
        hit = False;
        for option in schema["enum"] {
            if json_equal(option, data) { hit = True; }
        }
        if not hit { return False; }
    }
    if "const" in schema and not json_equal(schema["const"], data) { return False; }
    if is_number(data) {
        if "multipleOf" in schema {
            q = data / schema["multipleOf"];
            if not math.isfinite(q) or q != math.floor(q) { return False; }
        }
        if "maximum" in schema and data > schema["maximum"] { return False; }
        if "minimum" in schema and data < schema["minimum"] { return False; }
        if "exclusiveMaximum" in schema and data >= schema["exclusiveMaximum"] { return False; }
        if "exclusiveMinimum" in schema and data <= schema["exclusiveMinimum"] { return False; }
        f = schema.get("format");
        if isinstance(f, str) and f in NUMBER_FORMATS and not _number_format(f, data) { return False; }
    }
    if isinstance(data, str) {
        if "maxLength" in schema and _utf16_length(data) > schema["maxLength"] { return False; }
        if "minLength" in schema and _utf16_length(data) < schema["minLength"] { return False; }
        if "pattern" in schema and re.search(schema["pattern"], data) is None { return False; }
        f = schema.get("format");
        if isinstance(f, str) and f in STRING_FORMATS and not _string_format(f, data) { return False; }
    }
    if isinstance(data, list) {
        if "maxItems" in schema and len(data) > schema["maxItems"] { return False; }
        if "minItems" in schema and len(data) < schema["minItems"] { return False; }
        if schema.get("uniqueItems") is True {
            for i in range(len(data)) {
                for j in range(i + 1, len(data)) {
                    if json_equal(data[i], data[j]) { return False; }
                }
            }
        }
        prefix: list[any] = [];
        rest: any = None;
        has_rest = False;
        if "prefixItems" in schema {
            prefix = schema["prefixItems"];
            if "items" in schema { rest = schema["items"]; has_rest = True; }
        } elif isinstance(schema.get("items"), list) {
            prefix = schema["items"];
            if "additionalItems" in schema { rest = schema["additionalItems"]; has_rest = True; }
        } elif "items" in schema {
            rest = schema["items"];
            has_rest = True;
        }
        for i in range(len(data)) {
            if i < len(prefix) {
                if not v(prefix[i], data[i]) { return False; }
            } elif has_rest and not v(rest, data[i]) {
                return False;
            }
        }
        if "contains" in schema {
            count = 0;
            for item in data {
                if v(schema["contains"], item) { count += 1; }
            }
            least = schema["minContains"] if "minContains" in schema else 1;
            if count < least { return False; }
            if "maxContains" in schema and count > schema["maxContains"] { return False; }
        }
    }
    if isinstance(data, dict) {
        if "maxProperties" in schema and len(data) > schema["maxProperties"] { return False; }
        if "minProperties" in schema and len(data) < schema["minProperties"] { return False; }
        for r in schema.get("required", []) {
            if r not in data { return False; }
        }
        props = schema.get("properties") or {};
        patterns = schema.get("patternProperties") or {};
        for (key, value) in data.items() {
            matched = False;
            if key in props {
                matched = True;
                if not v(props[key], value) { return False; }
            }
            for (pat, ps) in patterns.items() {
                if re.search(pat, key) is not None {
                    matched = True;
                    if not v(ps, value) { return False; }
                }
            }
            if not matched and "additionalProperties" in schema and not v(schema["additionalProperties"], value) {
                return False;
            }
            if "propertyNames" in schema and not v(schema["propertyNames"], key) { return False; }
        }
        for (name, needed) in (schema.get("dependentRequired") or {}).items() {
            if name in data {
                for n in needed {
                    if n not in data { return False; }
                }
            }
        }
        for (name, dep) in (schema.get("dependencies") or {}).items() {
            if name in data {
                if isinstance(dep, list) {
                    for n in dep {
                        if n not in data { return False; }
                    }
                } elif not v(dep, data) {
                    return False;
                }
            }
        }
        for (name, ds) in (schema.get("dependentSchemas") or {}).items() {
            if name in data and not v(ds, data) { return False; }
        }
    }
    if "allOf" in schema {
        for s in schema["allOf"] {
            if not v(s, data) { return False; }
        }
    }
    if "anyOf" in schema {
        any_ok = False;
        for s in schema["anyOf"] {
            if v(s, data) { any_ok = True; break; }
        }
        if not any_ok { return False; }
    }
    if "oneOf" in schema {
        passing = 0;
        for s in schema["oneOf"] {
            if v(s, data) { passing += 1; }
        }
        if passing != 1 { return False; }
    }
    if "not" in schema and v(schema["not"], data) { return False; }
    if "if" in schema {
        if v(schema["if"], data) {
            if "then" in schema and not v(schema["then"], data) { return False; }
        } elif "else" in schema and not v(schema["else"], data) {
            return False;
        }
    }
    return True;
}

def compile_tool_schema(schema: dict[str, any]) -> any {
    # Returns validate(data) -> bool, or raises with the runtime's message.
    dialect = schema.get("$schema");
    if dialect is not None and dialect != DRAFT_07 and dialect != DRAFT_2020 {
        raise SchemaCompileError(DIALECT_ERROR);
    }
    kind = "2020" if dialect == DRAFT_2020 else "07";
    _check(schema, schema, kind, 0);
    # A deep copy: the validator must not see later mutation of the
    # advertised parameters (the runtime strips composition keywords).
    frozen = json.loads(json.dumps(schema));
    def validate(data: any) -> bool {
        try {
            return _valid(frozen, frozen, data, 0);
        } except SchemaCompileError {
            return False;
        } except RecursionError {
            return False;
        }
    }
    return validate;
}
