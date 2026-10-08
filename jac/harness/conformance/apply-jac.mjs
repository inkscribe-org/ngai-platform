// Conformance driver: replays ops.json against the running Jac harness via
// POST /function/op_*. Usage:
//   OMB_DATA_DIR=<dir> node apply-jac.mjs <ops.json> <out-log> [http://localhost:PORT]
// The harness process itself must have been started with the same
// OMB_DATA_DIR so its DATA_DIR matches.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const [opsPath, logPath, baseUrl = "http://localhost:18801"] = process.argv.slice(2);
const { ops } = JSON.parse(readFileSync(opsPath, "utf8"));
const DATA_DIR = process.env.OMB_DATA_DIR;

// op name -> [endpoint, arg-map]. arg-map translates corpus keys into the
// Jac function's kwargs; absent entry means same-name pass-through.
const endpointFor = (name) => `op_${name.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase())}`;

// op name -> {argMap, defaults}. argMap translates corpus keys into the Jac
// function's kwargs. jac serving currently binds omitted optional params to
// their STRINGIFIED default ('None', '40') — an upstream defect with a fix
// in flight — so the driver sends every declared arg explicitly, using the
// typed default for absent corpus keys.
const argKeys = {
  writeFile: null, // handled locally — same filesystem, both drivers
  fileExists: null,
  appendMessage: { map: { threadId: "thread_id", message: "message" } },
  insertMessage: { map: { threadId: "thread_id", message: "message" } },
  updateMessage: { map: { threadId: "thread_id", message: "message" } },
  importThread: { map: { threadId: "thread_id", messages: "messages", activeLeafId: "active_leaf_id" }, defaults: { active_leaf_id: null } },
  readThread: { map: { threadId: "thread_id" } },
  readThreadTail: { map: { threadId: "thread_id", limit: "limit" } },
  setActiveLeaf: { map: { threadId: "thread_id", leafId: "leaf_id" }, defaults: { leaf_id: null } },
  deleteThread: { map: { threadId: "thread_id" } },
  latestMessageAts: { map: { threadIds: "thread_ids" } },
  threadsReferencing: { map: { fragment: "fragment" } },
  searchMessages: { map: { query: "query", limit: "limit", threadId: "thread_id" }, defaults: { limit: 40, thread_id: null } },
  recallMessages: { map: { query: "query", threadIds: "thread_ids", limit: "limit", range: "range_", mode: "mode" }, defaults: { limit: 12, range_: null, mode: "all" } },
  recentMessages: { map: { threadIds: "thread_ids", range: "range_", limit: "limit" }, defaults: { limit: 12 } },
  latestSaidByBot: { map: { threadIds: "thread_ids", botId: "bot_id", since: "since", limit: "limit" }, defaults: { limit: 20 } },
  readMessageText: { map: { threadId: "thread_id", messageId: "message_id" } },
  workingGoalRunMessages: { map: {} },
  readCommandReceipt: { map: { kind: "kind", key: "key" } },
  saveChatFollowup: { map: { followup: "followup" } },
  settleChatFollowups: { map: { ids: "ids", status: "status" }, defaults: { status: null } },
  chatFollowups: { map: { kind: "kind" }, defaults: { kind: null } },
  cancelledChatFollowup: { map: { kind: "kind", ownerId: "owner_id", threadId: "thread_id", sendId: "send_id" } },
  indexMemoryFile: { map: { botId: "bot_id", path: "path", text: "text", stat: "stat" } },
  removeMemoryFile: { map: { botId: "bot_id", path: "path" } },
  indexedMemoryFiles: { map: { botId: "bot_id" } },
  recallMemory: { map: { query: "query", botId: "bot_id", limit: "limit", mode: "mode" }, defaults: { limit: 12, mode: "all" } },
  recallTerms: { map: { query: "query" } },
  recallMatchTerm: { map: { term: "term" } },
};
// Response envelope: {"data": {"result": <return>, "reports": [...]}}.
// Corpus ops map their result so the shape matches the node's direct call:
// endpoints return {"ok": true} for void ops and named-key objects for
// queries; unwrap those here.
const unwrap = (op, payload) => {
  const result = payload?.data?.result;
  switch (op.op) {
    case "appendMessage":
    case "insertMessage":
    case "updateMessage":
    case "setActiveLeaf":
    case "deleteThread":
    case "saveChatFollowup":
    case "settleChatFollowups":
    case "indexMemoryFile":
    case "removeMemoryFile":
      return true;
    case "importThread":
      return result?.ok === true ? true : result;
    case "readThread":
      return result; // {messages, activeLeafId}
    case "readThreadTail":
      return result; // {messages, activeLeafId, hasMore?}
    case "latestMessageAts":
      return result?.ats;
    case "threadsReferencing":
      return result?.threads;
    case "searchMessages":
    case "recallMessages":
    case "recentMessages":
    case "recallMemory":
      return result?.hits;
    case "latestSaidByBot":
      return result?.latest;
    case "readMessageText":
      return result?.row ?? null;
    case "workingGoalRunMessages":
      return result?.goals;
    case "readCommandReceipt":
      return result?.receipt ?? null;
    case "chatFollowups":
      return result?.followups;
    case "cancelledChatFollowup":
      return result?.cancelled;
    case "indexedMemoryFiles":
      return result?.files;
    case "recallTerms":
      return result?.terms;
    case "recallMatchTerm":
      return result?.term ?? null;
    default:
      return result;
  }
};

const log = [];
for (const op of ops) {
  const keys = argKeys[op.op];
  if (keys === null) {
    // Local filesystem op — identical for both drivers.
    if (op.op === "writeFile") {
      writeFileSync(join(DATA_DIR, op.path), op.content);
      log.push({ op: op.op, result: true });
    } else {
      log.push({ op: op.op, result: existsSync(join(DATA_DIR, op.path)) });
    }
    continue;
  }
  if (keys === undefined) {
    log.push({ op: op.op, error: "no handler" });
    continue;
  }
  const body = {};
  // jac serving binds absent optional params to their stringified default
  // ('None', '40') — send every declared arg, typed default when absent.
  for (const [src, dst] of Object.entries(keys.map)) {
    body[dst] = op[src] === undefined ? keys.defaults?.[dst] ?? null : op[src];
  }
  try {
    const res = await fetch(`${baseUrl}/function/${endpointFor(op.op)}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const payload = await res.json();
    if (!payload.ok || !payload.data || payload.data.result === undefined) {
      log.push({
        op: op.op,
        error: String(payload.error?.message ?? payload.error ?? JSON.stringify(payload).slice(0, 300)),
      });
    } else {
      log.push({ op: op.op, result: unwrap(op, payload) });
    }
  } catch (e) {
    log.push({ op: op.op, error: String(e) });
  }
}
writeFileSync(logPath, JSON.stringify(log, null, 2));
console.log(`applied ${ops.length} ops`);
