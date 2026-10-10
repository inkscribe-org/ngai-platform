"""Chat-completions wire protocol — the Jac port of
server/drivers/openai-chat-protocol.ts plus the pure error/verdict helpers of
server/drivers/openai-chat.ts and server/key-rejections.ts.

Nothing here does I/O: the runtime (driver_openai_chat.jac) feeds parsed
provider JSON in and gets typed verdicts out, so every provider that speaks
OpenAI chat completions (openai-compat today; cerebras, mistral, minimax,
grok later) shares one accumulator and one error vocabulary. Assistant
content is never parsed as a tool: only structured tool_calls are."""

import re;
import json;
import hashlib;

# Calls one model reply may carry (its index bound). The turn's own total is
# MAX_TURN_TOOL_CALLS in driver_openai_chat.jac.
glob MAX_REPLY_TOOL_CALLS: int = 32;
glob MAX_ARGUMENT_CHARS: int = 256000;
glob MAX_REASONING_DETAIL_CHARS: int = 256000;

glob TOOL_NAME_RE: any = re.compile(r"^[A-Za-z0-9_-]{1,64}$");

# ── error types ────────────────────────────────────────────────────────────

class ChatProtocolError(Exception) {
    # The provider broke the chat-completions contract; never retried.
}

class RejectedToolCallError(ChatProtocolError) {
    # Groq's `tool_use_failed`: the provider refused a generated call. The
    # provider's whole error object rides as attribute `refusal`.
}

class UnsupportedChatToolsError(Exception) {
    # An explicit rejection of the `tools` request parameter.
}

class UnsupportedReasoningReplayError(Exception) {
    # A schema rejection of an echoed `reasoning_content` property.
}

class ChatToolSessionError(Exception) {
    # The tool transport cannot safely continue this turn. A dispatched
    # operation may already have taken effect, so it is never retried.
}

def rejected_tool_call_error(message: str, refusal: dict[str, any]) -> Exception {
    err = RejectedToolCallError(message);
    setattr(err, "refusal", refusal);
    return err;
}

def is_object(value: any) -> bool {
    return isinstance(value, dict);
}

def js_string(value: any) -> str {
    # String(value) for the JSON shapes a provider can send.
    if value is None { return "null"; }
    if value is True { return "true"; }
    if value is False { return "false"; }
    if isinstance(value, str) { return value; }
    if isinstance(value, float) and value.is_integer() and abs(value) < 1e21 { return str(int(value)); }
    return str(value);
}

def is_js_integer(value: any) -> bool {
    # Number.isInteger: bools are not numbers in JSON.
    if isinstance(value, bool) { return False; }
    if isinstance(value, int) { return True; }
    return isinstance(value, float) and value == value and value not in (float("inf"), float("-inf")) and value.is_integer();
}

# ── reasoning details ──────────────────────────────────────────────────────

obj ChatReasoningDetails {
    # Opaque provider reasoning blocks keep their original order/signatures.
    # OpenRouter streams the sequence as arrays of blocks.
    has blocks: list[any] = [],
        chars: int = 0;

    def add(value: any) {
        if value is None { return; }
        if not isinstance(value, list) {
            raise ChatProtocolError("provider returned invalid reasoning details");
        }
        for block in value {
            if not isinstance(block, dict) {
                raise ChatProtocolError("provider returned invalid reasoning details");
            }
        }
        self.chars += len(json.dumps(value, separators=(",", ":"), ensure_ascii=False));
        if self.chars > MAX_REASONING_DETAIL_CHARS {
            raise ChatProtocolError("provider reasoning details exceeded the size limit");
        }
        self.blocks.extend(value);
    }
}

def new_reasoning_details() -> ChatReasoningDetails {
    return ChatReasoningDetails(blocks=[], chars=0);
}

# ── tool-call accumulator ──────────────────────────────────────────────────

obj ChatToolCalls {
    # One accumulator per completion: indexes identify deltas; IDs correlate
    # results. Streaming treats an explicit null continuation field as absent.
    has calls: dict[int, any] = {},
        argument_chars: int = 0;

    def add(value: any, streaming: bool) {
        if value is None { return; }
        if not isinstance(value, list) {
            raise ChatProtocolError("provider returned invalid tool_calls");
        }
        def omitted(d: dict[str, any], field: str) -> bool {
            if field not in d { return True; }
            return streaming and d[field] is None;
        }
        position = 0;
        for raw in value {
            delta = raw if isinstance(raw, dict) else None;
            index: any = position;
            if streaming {
                index = delta.get("index") if delta is not None else None;
            }
            if delta is None or not is_js_integer(index) or int(index) < 0 or int(index) >= MAX_REPLY_TOOL_CALLS {
                raise ChatProtocolError("provider returned an invalid tool-call index");
            }
            key = int(index);
            call = self.calls.get(key);
            if call is None {
                call = {"id": "", "type": "function", "function": {"name": "", "arguments": ""}};
            }
            if not omitted(delta, "type") and delta["type"] != "function" {
                raise ChatProtocolError("unsupported tool-call type");
            }
            if not omitted(delta, "id") {
                cid = delta["id"];
                if not isinstance(cid, str) or not cid or len(cid) > 256 or (call["id"] and call["id"] != cid) {
                    raise ChatProtocolError("provider changed or omitted a tool-call ID");
                }
                call["id"] = cid;
            }
            if "function" in delta {
                fn = delta["function"];
                if not isinstance(fn, dict) {
                    raise ChatProtocolError("provider returned an invalid tool-call function");
                }
                for field in ["name", "arguments"] {
                    if omitted(fn, field) { continue; }
                    if not isinstance(fn[field], str) {
                        raise ChatProtocolError("provider returned invalid tool-call arguments or name");
                    }
                    call["function"][field] = call["function"][field] + fn[field];
                    if field == "arguments" { self.argument_chars += len(fn[field]); }
                }
            }
            if len(call["function"]["name"]) > 64 or self.argument_chars > MAX_ARGUMENT_CHARS {
                raise ChatProtocolError("provider tool calls exceeded the size limit");
            }
            self.calls[key] = call;
            position += 1;
        }
    }

    def finish(reason: any, malformed_frame: bool) -> list[any] {
        calls = [self.calls[k] for k in sorted(self.calls.keys())];
        if malformed_frame {
            raise ChatProtocolError("provider stream contained a malformed completion frame");
        }
        if reason == "function_call" {
            raise ChatProtocolError("legacy function_call is unsupported; use structured tool_calls");
        }
        if reason == "tool_calls" and not calls {
            raise ChatProtocolError("provider ended for tool calls without a complete call");
        }
        if not calls { return calls; }
        if reason is not None and reason != "tool_calls" and reason != "stop" {
            raise ChatProtocolError("provider tool calls were truncated or malformed");
        }
        ids: dict[str, bool] = {};
        for call in calls {
            if not call["id"] or call["id"] in ids or TOOL_NAME_RE.match(call["function"]["name"]) is None {
                raise ChatProtocolError("provider returned an incomplete or duplicate tool call");
            }
            ids[call["id"]] = True;
        }
        return calls;
    }
}

def new_tool_calls() -> ChatToolCalls {
    return ChatToolCalls(calls={}, argument_chars=0);
}

# ── provider error verdicts (openai-chat.ts) ───────────────────────────────

def provider_error(body: any) -> any {
    # The message of a JSON error body a provider returned with HTTP 200.
    # MiniMax reports auth, balance and parameter failures as `base_resp`.
    if not isinstance(body, dict) { return None; }
    error = body.get("error");
    if isinstance(error, str) { return error; }
    if isinstance(error, dict) {
        msg = error.get("message");
        return msg if isinstance(msg, str) else "unknown error";
    }
    base_resp = body.get("base_resp");
    if isinstance(base_resp, dict) {
        code = base_resp.get("status_code");
        if isinstance(code, (int, float)) and not isinstance(code, bool) and code != 0 {
            msg = base_resp.get("status_msg");
            text = msg if isinstance(msg, str) else "";
            return "upstream error " + js_string(code) + ((": " + text) if text else "");
        }
    }
    return None;
}

def tool_call_refusal(error: any) -> any {
    if isinstance(error, dict) and error.get("code") == "tool_use_failed" { return error; }
    return None;
}

def _json_object(body: str) -> any {
    try {
        parsed = json.loads(body);
    } except Exception {
        return "__invalid__";
    }
    return parsed if isinstance(parsed, dict) else None;
}

def refused_tool_call(status: int, body: str) -> any {
    if status != 400 { return None; }
    envelope = _json_object(body);
    if not isinstance(envelope, dict) { return None; }
    return tool_call_refusal(envelope.get("error"));
}

glob TOOLS_UNSUPPORTED_RES: list[any] = [
    re.compile(r"\bdoes not support (?:tools|tool calling|function calling)(?:[.!]?$|[.!]?\s)", re.I),
    re.compile(r"\b(?:tools|tool calling|function calling) (?:is|are) not supported\b", re.I),
];
glob TOOLS_UNKNOWN_PARAM_RE: any = re.compile(r"^(?:unsupported|unknown|unrecognized) (?:parameter|field):?\s*['\"]?tools['\"]?[.!]?$", re.I);

def rejects_tools_parameter(status: int, body: str) -> bool {
    if status != 400 and status != 422 { return False; }
    envelope = _json_object(body);
    if envelope == "__invalid__" { return False; }
    error = None;
    if isinstance(envelope, dict) and isinstance(envelope.get("error"), dict) {
        error = envelope["error"];
    }
    if error is not None and error.get("param") == "tools" and error.get("code") == "unsupported_parameter" {
        return True;
    }
    message: any = None;
    if error is not None and "message" in error and error["message"] is not None {
        message = error["message"];
    } elif isinstance(envelope, dict) {
        message = envelope.get("error");
    }
    if not isinstance(message, str) { return False; }
    for pattern in TOOLS_UNSUPPORTED_RES {
        if pattern.search(message) is not None { return True; }
    }
    return TOOLS_UNKNOWN_PARAM_RE.search(message.strip()) is not None;
}

glob REASONING_FIELD_RE: any = re.compile(r"\breasoning_content\b");
glob REASONING_REFUSAL_RE: any = re.compile(r"\b(?:unsupported|not supported|unknown|unrecognized|unexpected|not permitted|not allowed)\b", re.I);

def rejects_reasoning_replay(status: int, body: str) -> bool {
    # DeepSeek-style providers need `reasoning_content` echoed on a tool-call
    # assistant message; strict endpoints such as Groq reject the property.
    if status != 400 and status != 422 { return False; }
    envelope = _json_object(body);
    if envelope == "__invalid__" { return False; }
    message: any = None;
    if isinstance(envelope, dict) {
        error = envelope.get("error");
        if isinstance(error, dict) and error.get("message") is not None {
            message = error.get("message");
        } else {
            message = error;
        }
    }
    return isinstance(message, str) and REASONING_FIELD_RE.search(message) is not None and REASONING_REFUSAL_RE.search(message) is not None;
}

def completion_error(body: any, label: str) -> Exception | None {
    message = provider_error(body);
    if not message { return None; }
    text = "provider returned a " + label + ": " + message[0:200];
    refusal = tool_call_refusal(body.get("error"));
    if refusal is not None { return rejected_tool_call_error(text, refusal); }
    return ChatProtocolError(text);
}

glob REFUSED_TOOL_RE: any = re.compile(r"attempted to call tool '([^']+)'");

def refused_tool_call_failure(error: any, earlier_steps: bool) -> str {
    # What a failed turn says once the provider refused every attempt: what
    # happened, the next step, then the provider's words.
    refusal = getattr(error, "refusal", None) or {};
    words: str = refusal["message"] if isinstance(refusal.get("message"), str) else str(error);
    m = REFUSED_TOOL_RE.search(words);
    what = "made a tool call the provider rejected";
    if m is not None {
        what = "tried to use a tool it was not given (\"" + m.group(1) + "\")";
    }
    step = "Nothing ran. Retry; if it keeps happening, rephrase the request or choose another model.";
    if earlier_steps {
        step = "The steps before it already ran, so ask only for what's left.";
    }
    return "The model " + what + ". " + step + " Provider: " + words[0:200];
}

glob ANNOUNCE_TAIL_RE: any = re.compile(r"(?:[:—–]|\.\.\.|…)$");
glob ANNOUNCE_HEAD_RE: any = re.compile(r"^(?:checking|let me|i'll|i will|i'm going to|i am going to|opening|pulling|looking|searching|navigating|reading|fetching|loading|now (?:i'll|let me|opening|checking|pulling|reading))\b", re.I);

def announces_action(text: str) -> bool {
    # A short reply that only announces a next step, with nothing to answer.
    reply = text.strip();
    if not reply or len(reply) > 400 or "?" in reply { return False; }
    return ANNOUNCE_TAIL_RE.search(reply) is not None or ANNOUNCE_HEAD_RE.search(reply) is not None;
}

def usage_from(usage: any) -> any {
    if not isinstance(usage, dict) { return None; }
    prompt = usage.get("prompt_tokens");
    completion = usage.get("completion_tokens");
    return {
        "input": prompt if prompt is not None else 0,
        "output": completion if completion is not None else 0,
    };
}

def usage_count(value: any) -> any {
    # Known provider counts only: unknown stays None, explicit zeroes stay.
    if isinstance(value, bool) or not isinstance(value, (int, float)) { return None; }
    if value != value or value in (float("inf"), float("-inf")) or value < 0 { return None; }
    return value;
}

# ── key rejections (key-rejections.ts) ─────────────────────────────────────
# Node owns the shared registry (every engine on a key + endpoint reads it);
# Jac reports each verdict over the bridge by fingerprint, never the key.

glob KEY_QUOTA_RE: any = re.compile(r"\b(?:quota|billing|credits?|rate.?limit|insufficient.?(?:balance|funds))\b", re.I);
glob KEY_INVALID_RE: any = re.compile(r"\binvalid_api_key\b|\b(?:invalid|incorrect|revoked|expired|disabled|deactivated)[ _-]?(?:api[ _-]?)?key\b|\bapi[ _-]?key (?:is |was |has been )?(?:invalid|incorrect|revoked|expired|disabled|not valid)\b", re.I);

def rejects_key(status: int, body: str) -> bool {
    if KEY_QUOTA_RE.search(body) is not None { return False; }
    if status == 401 { return True; }
    if status != 400 and status != 403 { return False; }
    return KEY_INVALID_RE.search(body) is not None;
}

def key_fingerprint(key: str) -> str {
    return hashlib.sha256(key.strip().encode("utf-8")).hexdigest()[0:32];
}
