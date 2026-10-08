// Conformance driver: replays ops.json against server/message-db.ts.
// Usage: OMB_DATA_DIR=<dir> node --experimental-strip-types apply-node.ts <ops.json> <out-log>
// Writes a JSON log of every op's result; the DB itself is compared by run.sh.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

import * as mdb from "../../../server/message-db.ts";
import type { Message } from "../../../server/store.ts";
import type { ChatFollowup } from "../../../server/message-db.ts";

interface Op {
  op: string;
  [key: string]: unknown;
}
interface OpLogEntry {
  op: string;
  result?: unknown;
  error?: string;
}

const [opsPath, logPath] = process.argv.slice(2);
const { ops } = JSON.parse(readFileSync(opsPath, "utf8")) as { ops: Op[] };
const DATA_DIR = process.env.OMB_DATA_DIR!;
const legacy = (threadId: string) => join(DATA_DIR, `messages-${threadId}.json`);

// Narrowing helpers keep each handler typed without 28 payload interfaces —
// corpus fields are trusted test input, not untrusted data.
const s = (op: Op, key: string): string => op[key] as string;
const n = (op: Op, key: string): number => op[key] as number;
const sOrNull = (op: Op, key: string): string | null => (op[key] ?? null) as string | null;
const sList = (op: Op, key: string): string[] => op[key] as string[];
const message = (op: Op): Message => op.message as Message;
const range = (op: Op): mdb.RecallRange | undefined => op.range as mdb.RecallRange | undefined;
const mode = (op: Op): mdb.SearchMode => (op.mode ?? "all") as mdb.SearchMode;

const handlers: Record<string, (op: Op) => unknown> = {
  writeFile: (op) => {
    writeFileSync(join(DATA_DIR, s(op, "path")), s(op, "content"));
    return true;
  },
  fileExists: (op) => existsSync(join(DATA_DIR, s(op, "path"))),
  appendMessage: (op) => (mdb.appendMessage(s(op, "threadId"), message(op)), true),
  insertMessage: (op) => (mdb.insertMessage(s(op, "threadId"), message(op)), true),
  updateMessage: (op) => (mdb.updateMessage(s(op, "threadId"), message(op)), true),
  importThread: (op) => {
    try {
      mdb.importThread(s(op, "threadId"), op.messages as Message[], sOrNull(op, "activeLeafId"));
      return true;
    } catch (e) {
      return { error: String(e) };
    }
  },
  readThread: (op) => mdb.readThread(s(op, "threadId"), legacy(s(op, "threadId"))),
  readThreadTail: (op) => mdb.readThreadTail(s(op, "threadId"), legacy(s(op, "threadId")), n(op, "limit")),
  setActiveLeaf: (op) => (mdb.setActiveLeaf(s(op, "threadId"), sOrNull(op, "leafId")), true),
  deleteThread: (op) => (mdb.deleteThread(s(op, "threadId")), true),
  latestMessageAts: (op) => Object.fromEntries(mdb.latestMessageAts(sList(op, "threadIds"))),
  threadsReferencing: (op) => mdb.threadsReferencing(s(op, "fragment")),
  searchMessages: (op) =>
    mdb.searchMessages(s(op, "query"), (op.limit as number) ?? 40, op.threadId as string | undefined),
  recallMessages: (op) =>
    mdb.recallMessages(s(op, "query"), sList(op, "threadIds"), (op.limit as number) ?? 12, range(op), mode(op)),
  recentMessages: (op) =>
    mdb.recentMessages(sList(op, "threadIds"), range(op)!, (op.limit as number) ?? 12),
  latestSaidByBot: (op) =>
    mdb.latestSaidByBot(sList(op, "threadIds"), s(op, "botId"), n(op, "since"), (op.limit as number) ?? 20),
  readMessageText: (op) => mdb.readMessageText(s(op, "threadId"), s(op, "messageId")),
  workingGoalRunMessages: () => mdb.workingGoalRunMessages(),
  readCommandReceipt: (op) => mdb.readCommandReceipt(s(op, "kind"), s(op, "key")),
  saveChatFollowup: (op) => (mdb.saveChatFollowup(op.followup as Omit<ChatFollowup, "status">), true),
  settleChatFollowups: (op) =>
    (mdb.settleChatFollowups(sList(op, "ids"), op.status as mdb.FollowupStatus | null ?? null), true),
  chatFollowups: (op) => mdb.chatFollowups(op.kind as ChatFollowup["kind"] | undefined),
  cancelledChatFollowup: (op) =>
    mdb.cancelledChatFollowup(
      op.kind as ChatFollowup["kind"],
      s(op, "ownerId"),
      s(op, "threadId"),
      s(op, "sendId"),
    ),
  indexMemoryFile: (op) =>
    (mdb.indexMemoryFile(s(op, "botId"), s(op, "path"), s(op, "text"), op.stat as { mtimeMs: number; bytes: number }), true),
  removeMemoryFile: (op) => (mdb.removeMemoryFile(s(op, "botId"), s(op, "path")), true),
  indexedMemoryFiles: (op) => mdb.indexedMemoryFiles(s(op, "botId")),
  recallMemory: (op) => mdb.recallMemory(s(op, "query"), s(op, "botId"), (op.limit as number) ?? 12, mode(op)),
  recallTerms: (op) => mdb.recallTerms(s(op, "query")),
  recallMatchTerm: (op) => mdb.recallMatchTerm(s(op, "term")),
};

const log: OpLogEntry[] = [];
for (const op of ops) {
  const handler = handlers[op.op];
  if (!handler) {
    log.push({ op: op.op, error: "no handler" });
    continue;
  }
  try {
    log.push({ op: op.op, result: handler(op) });
  } catch (e) {
    log.push({ op: op.op, error: String(e) });
  }
}
writeFileSync(logPath, JSON.stringify(log, null, 2));
console.log(`applied ${ops.length} ops`);
