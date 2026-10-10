// The `auto` room responder must load everywhere a room's routing is read or
// written: stored rooms, team backups, packages and legacy team files. Old
// data without it keeps loading unchanged, and a kind this build does not
// know degrades to today's default (the first member as lead) instead of
// refusing the file.
import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { parsePackageDocument } from "../../shared/package-format.ts";
import { parseTeamBackup } from "../../shared/team-backup.ts";
import { selectGroupGoalCoordinator } from "../group-goal-run.ts";
import { createTeamPackageExport } from "../package-export.ts";
import { normalizeGroupDefaultResponder, roomResponders, type BotRecord, type GroupRecord } from "../store.ts";
import { parseTeamManifest } from "../team-manifest.ts";

const FIXTURES = join(import.meta.dirname, "..", "..", "shared", "package-fixtures");
const fixture = (name: string) => JSON.parse(readFileSync(join(FIXTURES, name), "utf8"));
const MEMBERS = [
  { id: "maya", name: "Maya" },
  { id: "theo", name: "Theo" },
  { id: "ravi", name: "Ravi" },
];
const IDS = MEMBERS.map((member) => member.id);

describe("stored rooms", () => {
  it("normalizes auto, keeping a fallback only while it is a member", async () => {
    expect(normalizeGroupDefaultResponder({ kind: "auto" }, IDS)).toEqual({ kind: "auto" });
    expect(normalizeGroupDefaultResponder({ kind: "auto", fallbackBotId: "theo" }, IDS)).toEqual({ kind: "auto", fallbackBotId: "theo" });
    expect(normalizeGroupDefaultResponder({ kind: "auto", fallbackBotId: "gone" }, IDS)).toEqual({ kind: "auto" });
    expect(normalizeGroupDefaultResponder({ kind: "auto" }, IDS, true)).toEqual({ kind: "mentions" });
  });

  it("old rooms without the field, and unknown kinds, get today's default lead", async () => {
    expect(normalizeGroupDefaultResponder(undefined, IDS)).toEqual({ kind: "member", botId: "maya" });
    expect(normalizeGroupDefaultResponder({ kind: "round-robin" }, IDS)).toEqual({ kind: "member", botId: "maya" });
    expect(normalizeGroupDefaultResponder({ kind: "member", botId: "ravi" }, IDS)).toEqual({ kind: "member", botId: "ravi" });
  });

  it("without a decision, Auto answers like lead mode; mentions and @everyone win", async () => {
    expect(roomResponders("the navbar is broken", MEMBERS, { kind: "auto" }).map((m) => m.id)).toEqual(["maya"]);
    expect(roomResponders("the navbar is broken", MEMBERS, { kind: "auto", fallbackBotId: "ravi" }).map((m) => m.id)).toEqual(["ravi"]);
    expect(roomResponders("@Theo the navbar", MEMBERS, { kind: "auto", fallbackBotId: "ravi" }).map((m) => m.id)).toEqual(["theo"]);
    expect(roomResponders("@everyone standup", MEMBERS, { kind: "auto" }).map((m) => m.id)).toEqual(IDS);
    // an archived fallback falls through to the first active member
    const archived = [{ ...MEMBERS[0]!, hidden: true }, ...MEMBERS.slice(1)];
    expect(roomResponders("hi", archived, { kind: "auto", fallbackBotId: "maya" }).map((m) => m.id)).toEqual(["theo"]);
  });

  it("a team goal in an Auto room is led by its fallback", async () => {
    expect(selectGroupGoalCoordinator(MEMBERS, { kind: "auto", fallbackBotId: "ravi" })?.id).toBe("ravi");
    expect(selectGroupGoalCoordinator(MEMBERS, { kind: "auto" })?.id).toBe("maya");
  });
});

describe("packages", () => {
  it("old packages still load unchanged", async () => {
    expect(parsePackageDocument(fixture("legacy-team.v1.json")).package.rooms?.[0]?.defaultResponder).toEqual({ kind: "agent", agent: "scout" });
    expect(parsePackageDocument(fixture("full-team.v2.json")).package.rooms?.[0]?.defaultResponder).toEqual({ kind: "agent", agent: "lead" });
  });

  it("reads auto, and degrades an unknown kind to the first member as lead", async () => {
    const withResponder = (defaultResponder: unknown) => {
      const doc = fixture("full-team.v2.json");
      doc.package.rooms[0].defaultResponder = defaultResponder;
      return doc;
    };
    const members: string[] = fixture("full-team.v2.json").package.rooms[0].members;
    expect(parsePackageDocument(withResponder({ kind: "auto", agent: members.at(-1) })).package.rooms?.[0]?.defaultResponder)
      .toEqual({ kind: "auto", agent: members.at(-1) });
    expect(parsePackageDocument(withResponder({ kind: "round-robin" })).package.rooms?.[0]?.defaultResponder)
      .toEqual({ kind: "agent", agent: members[0] });
    expect(() => parsePackageDocument(withResponder({ kind: "auto", agent: "nobody-here" }))).toThrow(/default responder/);
    expect(() => parsePackageDocument(withResponder({ kind: 42 }))).toThrow();
  });

  it("an Auto room is exported as its lead, which every older app can open", async () => {
    const bot = (id: string, name: string): BotRecord => ({
      id, threadId: `thread-${id}`, name, title: "", description: "", notifications: true, color: "green", unread: false,
      modelSelection: { instanceId: "engine", model: "model" }, resumeCursors: {}, createdAt: 1, section: "Desk",
    });
    const room = (defaultResponder: GroupRecord["defaultResponder"]): GroupRecord => ({
      id: "room", threadId: "room-thread", name: "Desk room", memberIds: ["a", "b"], defaultResponder, bulletin: "",
      unread: false, createdAt: 1, section: "Desk",
    });
    const exported = (defaultResponder: GroupRecord["defaultResponder"]) => createTeamPackageExport({
      team: "Desk", authorName: "Mira", bots: [bot("a", "Ada"), bot("b", "Bea")], groups: [room(defaultResponder)], routines: [],
      published: null, skillsByBot: new Map(), mcpServers: {}, avatars: {},
    }).document.package.rooms?.[0]?.defaultResponder;
    expect(exported({ kind: "auto", fallbackBotId: "b" })).toEqual({ kind: "agent", agent: "bea" });
    expect(exported({ kind: "auto" })).toEqual({ kind: "agent", agent: "ada" });
  });
});

// The export/import round trip of an Auto room is a Jac invariant now
// (jac/harness/team_backup.test.jac); the shared schema the client also
// parses with is checked here.
describe("team backups", () => {
  const task = { key: "t", title: "Room", createdAt: 1, activeLeafId: null, messages: [] };
  const backup = (defaultResponder: unknown) => ({
    format: "openmaus.backup", version: 1, name: "Team", exportedAt: 1, warnings: [],
    bots: ["ada", "bea"].map((key) => ({
      key, name: key, activeTask: "t", tasks: [task], title: "", description: "", color: "green",
      chiefOfStaff: false, hidden: false, playbooks: [],
    })),
    groups: [{ key: "room", name: "Room", activeTask: "t", tasks: [task], memberIds: ["ada", "bea"], dm: false, bulletin: "", defaultResponder }],
    routines: [],
  });

  it("keeps an Auto room's fallback", () => {
    expect(parseTeamBackup(backup({ kind: "auto", fallbackBotId: "bea" })).groups[0]!.defaultResponder).toEqual({ kind: "auto", fallbackBotId: "bea" });
  });

  it("restores an unknown kind as the first member leading", () => {
    expect(parseTeamBackup(backup({ kind: "round-robin" })).groups[0]!.defaultResponder).toEqual({ kind: "member", botId: "ada" });
  });
});

describe("legacy team files", () => {
  const manifest = (defaultResponder: Record<string, string>) => ({
    format: "openmaus.team",
    version: 1,
    team: {
      name: "Research",
      members: [{ key: "analyst", name: "Ada", appearance: { color: "green" } }],
      room: { name: "Research", bulletin: "", defaultResponder },
    },
  });

  it("read auto and never refuse an unknown kind", async () => {
    expect(parseTeamManifest(manifest({ kind: "auto", member: "analyst" })).team.room?.defaultResponder).toEqual({ kind: "auto", member: "analyst" });
    expect(() => parseTeamManifest(manifest({ kind: "round-robin" }))).not.toThrow();
    expect(() => parseTeamManifest(manifest({ kind: "auto", member: "missing" }))).toThrow("Unknown default responder");
  });
});
