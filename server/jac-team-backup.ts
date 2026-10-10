// Node-side seam for portable team backups (phase 4 of the Jac migration).
// The backup logic — what a conversation turns into, which routines travel,
// the format's validation, the import plan and its rollback — lives in
// jac/harness/team_backup.jac. The Store is still node's, so:
//   export: this facade gathers a raw snapshot (records, transcripts, active
//           leaves, unscrubbed memory texts) and Jac builds the document;
//   import: Jac orchestrates and calls back through the `team_store` bridge
//           op for every store mutation (teamStoreCall below — synchronous
//           Store calls only; a bridge handler must never await jacOp).
// Both ops hold the op chain (jacLongOp serialize) so routine traffic cannot
// interleave with an import's in-process routine creation.

import type { ModelSelection } from "./contracts.ts";
import { botMascotBody } from "../shared/mascot-bodies.ts";
import type { TeamBackup } from "../shared/team-backup.ts";
import type { BotVisibility } from "../shared/wire.ts";
import type { BotRecord, GroupRecord, GroupTaskRecord, Message, Store } from "./store.ts";
import type { Routine } from "./routines.ts";
import { jacLongOp, mirrorApplyFrame } from "./jac-routines.ts";
import {
  listMemoryLogs, listMemoryTopics, readMemoryFile, readMemoryLog, readMemoryTopic,
  writeMemoryFile, writeMemoryLog, writeMemoryTopic,
} from "./workspace.ts";

type MemoryDocument = NonNullable<TeamBackup["bots"][number]["memory"]>;

/** The raw Store view create_team_backup works from. Memory is unscrubbed
 * here; the Jac side redacts it on the way out. */
function snapshot(store: Store) {
  const threads: Record<string, { messages: Message[]; activeLeaf: string | null }> = {};
  const memory: Record<string, { file: string; topics: Array<{ name: string; text: string | null }>; logs: Array<{ name: string; text: string | null }> }> = {};
  const owners: Array<BotRecord | GroupRecord> = [...store.bots, ...store.groups];
  for (const record of owners) {
    const ids = record.tasks?.length ? record.tasks.map((task) => task.threadId) : [record.threadId];
    for (const threadId of ids) threads[threadId] = { messages: store.messagesFor(threadId), activeLeaf: store.activeLeaf(threadId) };
  }
  for (const bot of store.bots) {
    memory[bot.id] = {
      file: readMemoryFile(bot.id).text,
      topics: listMemoryTopics(bot.id).map((topic) => ({ name: topic.name, text: readMemoryTopic(bot.id, topic.name) })),
      logs: listMemoryLogs(bot.id).map((name) => ({ name, text: readMemoryLog(bot.id, name) })),
    };
  }
  return { bots: store.bots, groups: store.groups, threads, memory };
}

export async function createTeamBackup(store: Store, name: string): Promise<TeamBackup> {
  const { backup } = await jacLongOp<{ backup: TeamBackup }>("team_backup_create", { snapshot: snapshot(store), name }, { serialize: true });
  return backup;
}

export interface ImportedTeam {
  name: string;
  bots: BotRecord[];
  groups: GroupRecord[];
  routines: Routine[];
}

/** Additive import. The result's records are the live Store records the
 * import created (the same objects the TS importer returned). */
export async function importTeamBackup(store: Store, input: unknown, selection: ModelSelection, options: { visibility?: BotVisibility } = {}): Promise<ImportedTeam> {
  const existing = {
    bots: store.bots.map((bot) => ({ id: bot.id, name: bot.name, section: bot.section })),
    groups: store.groups.map((group) => ({ id: group.id, name: group.name, section: group.section })),
    sections: store.sections,
  };
  freshIds.clear();
  const { imported } = await jacLongOp<{ imported: { name: string; bot_ids: string[]; group_ids: string[]; routines: Routine[] } }>(
    "team_backup_import",
    { input, selection, existing, visibility: options.visibility ?? null },
    { serialize: true },
  ).finally(() => freshIds.clear());
  for (const routine of imported.routines) mirrorApplyFrame({ kind: "routine", routine });
  return {
    name: imported.name,
    bots: imported.bot_ids.map((id) => store.bot(id)).filter((bot): bot is BotRecord => Boolean(bot)),
    groups: imported.group_ids.map((id) => store.group(id)).filter((group): group is GroupRecord => Boolean(group)),
    routines: imported.routines,
  };
}

/** Restore a bot's memory into its fresh workspace with the same writers the
 * tool and editor use (0700 folders, 0600 files, scrub, search index). */
function restoreMemory(botId: string, memory: MemoryDocument): void {
  if (memory.file) writeMemoryFile(botId, memory.file);
  for (const topic of memory.topics) writeMemoryTopic(botId, topic.name, topic.text);
  for (const log of memory.logs) writeMemoryLog(botId, log.name, log.text);
}

type Args = Record<string, unknown>;
/** Records the running import created, including one whose creation threw
 * after the Store added it. Rollback deletes only these — never a bot or room
 * another request made while the import's bridge calls were in flight (the
 * TS importer was synchronous and could assume no other writer). */
const freshIds = new Set<string>();
function tracking<T>(ids: () => string[], create: () => T): T {
  const before = new Set(ids());
  try { return create(); }
  finally { for (const id of ids()) if (!before.has(id)) freshIds.add(id); }
}
const need = <T>(value: T | null | undefined, what: string): T => {
  if (value === null || value === undefined) throw new Error(`team import: ${what} was not created`);
  return value;
};

/** The `team_store` bridge op: one synchronous Store call per Jac request.
 * Payloads are trusted in-process RPC from the harness (unchecked casts). */
export function teamStoreCall(store: Store, payload: Record<string, unknown>): { result: unknown } {
  const args = (payload.args ?? {}) as Args;
  switch (payload.call) {
    case "createBot": {
      const profile = { ...(args.profile as Args) };
      profile.mascotBody = botMascotBody(profile.mascotBody);
      return { result: tracking(() => store.bots.map((bot) => bot.id),
        () => store.createBot(profile as Parameters<Store["createBot"]>[0], { seedMessages: false })) };
    }
    case "patchBot":
      return { result: need(store.patchBot(String(args.botId), args.patch as Partial<BotRecord>), "bot") };
    case "restoreMemory":
      restoreMemory(String(args.botId), args.memory as MemoryDocument);
      return { result: true };
    case "importTranscript":
      store.importTranscript(String(args.threadId), args.messages as Message[], (args.activeLeafId as string | null) ?? null);
      return { result: true };
    case "createGroup":
      return { result: tracking(() => store.groups.map((group) => group.id),
        () => store.createGroup(String(args.name), args.memberIds as string[], args.dm === true, args.section as string | undefined)) };
    case "patchGroup":
      return { result: need(store.patchGroup(String(args.groupId), args.patch as Parameters<Store["patchGroup"]>[1]), "room") };
    case "renameGroupTask":
      return { result: store.renameGroupTask(String(args.groupId), String(args.threadId), String(args.title)) };
    case "createGroupTask":
      return { result: need(store.createGroupTask(String(args.groupId), String(args.title), false), "room task") };
    case "setGroupTasks": {
      const group = need(store.group(String(args.groupId)), "room");
      group.tasks = args.tasks as GroupTaskRecord[];
      store.switchGroupTask(group.id, String(args.activeThreadId));
      return { result: true };
    }
    case "rollback": {
      // Every fresh id, even a record whose creation threw before returning;
      // never one that existed when the import began.
      const bots = new Set(args.existingBotIds as string[]);
      const groups = new Set(args.existingGroupIds as string[]);
      for (const group of [...store.groups]) if (!groups.has(group.id) && freshIds.has(group.id)) store.deleteGroup(group.id);
      for (const bot of [...store.bots]) if (!bots.has(bot.id) && freshIds.has(bot.id)) store.deleteBot(bot.id);
      for (const section of args.sections as string[]) {
        if (store.sections.includes(section)) store.changeEmptySection(section, null);
      }
      return { result: true };
    }
    default:
      throw new Error(`unknown team_store call: ${String(payload.call)}`);
  }
}

