"""Ported invariants from server/team-backup.test.ts.

Annexes team_backup.jac (no self-import). Node's Store is a fake behind the
`store` hook (every bridge call is logged); routines are an in-memory list
behind routines_list / routine_create / routine_remove. The fixture mirrors
the TS fixture: two Engineering bots (Mira is Chief), Ava Chief of
Operations, an archived bot, a project room and two routines.
"""

import re;
import json;

glob NOW: int = 1786874400000;

def _throws(fn: any, pattern: str) -> str {
    try {
        fn();
    } except Exception as e {
        assert re.search(pattern, str(e)), "error " + json.dumps(str(e)) + " does not match " + json.dumps(pattern);
        return str(e);
    }
    raise Exception("expected an exception matching " + pattern);
}

def _msg(id: str, role: str, text: str, at: int, parent: any = None) -> dict[str, any] {
    return {"id": id, "kind": "text", "role": role, "text": text, "at": at, "parentId": parent};
}

# The raw snapshot node's facade would gather from the Store.
def _fixture -> dict[str, any] {
    chief: dict[str, any] = {
        "id": "chief", "name": "Mira", "title": "", "section": "Engineering",
        "description": "Full instructions\n" * 400, "soul": "  Cite sources.\nRespect the user's current request. 🐭\n",
        "color": "green", "chiefOfStaff": True, "hidden": False, "autoApprove": True, "approvalMode": "full",
        "alwaysAllow": ["Bash"], "cwd": "/private/old-workspace", "composio": True,
        "playbooks": [{"key": "research", "name": "Research", "summary": "Find evidence", "triggers": ["research"], "instructions": "Cite sources"}],
        "modelSelection": {"instanceId": "fixture", "model": "fixture-model"},
        "threadId": "c-t3", "createdAt": 10,
        "tasks": [
            {"threadId": "c-t3", "title": "Second conversation", "createdAt": 12, "resumeCursors": {"x": "y"},
             "openedBy": {"botId": "scout", "name": "Scout", "delegationId": "do-not-resume-delegation", "kind": "pair", "at": 99},
             "closedBy": {"botId": "scout", "name": "Scout", "at": 103}},
            {"threadId": "c-t2", "title": "Opened by a deleted bot", "createdAt": 11,
             "openedBy": {"botId": "gone-bot", "name": "Gone", "at": 98},
             "closedBy": {"botId": "gone-bot", "name": "Gone", "at": 102}},
            {"threadId": "c-t1", "title": "First conversation", "createdAt": 10},
        ],
    };
    scout: dict[str, any] = {"id": "scout", "name": "Scout", "title": "", "description": "", "section": "Engineering",
        "color": "blue", "mascotBody": "circle", "chiefOfStaff": False, "hidden": False, "threadId": "s-t1", "createdAt": 20};
    ava: dict[str, any] = {"id": "ava", "name": "Ava", "title": "", "description": "", "section": "Operations",
        "color": "red", "chiefOfStaff": True, "hidden": False, "threadId": "a-t1", "createdAt": 30, "tasks": []};
    archived: dict[str, any] = {"id": "archived", "name": "Archived", "title": "", "description": "",
        "color": "teal", "chiefOfStaff": False, "hidden": True, "threadId": "x-t1", "createdAt": 40};
    group: dict[str, any] = {"id": "room", "name": "Project room", "section": "Engineering", "memberIds": ["chief", "scout"],
        "dm": False, "bulletin": "Build carefully", "defaultResponder": {"kind": "member", "botId": "chief"},
        "threadId": "r-t1", "createdAt": 50,
        "tasks": [{"threadId": "r-t1", "title": "Project room", "createdAt": 50}, {"threadId": "r-t2", "title": "Second room task", "createdAt": 51}]};
    threads: dict[str, any] = {
        "c-t1": {"messages": [
            _msg("q", "user", "Original question", 100), _msg("a", "bot", "Original answer", 101, "q"),
            _msg("e", "user", "Edited question", 102)], "activeLeaf": "a"},
        "c-t3": {"messages": [
            {"id": "m1", "kind": "text", "role": "user", "text": "Current question", "at": 110, "parentId": None, "queued": True, "queueId": "do-not-replay"},
            {"id": "m2", "kind": "options", "role": "bot", "at": 111, "parentId": "m1",
             "card": {"title": "Permission request", "subtitle": "Old approval", "options": ["Allow"], "requestId": "do-not-resume", "allowKey": "Bash"}},
            {"id": "m3", "kind": "text", "role": "user", "text": "An image", "at": 112, "parentId": "m2",
             "attachments": [{"kind": "image", "path": "/private/image.png", "mime": "image/png"}]},
        ], "activeLeaf": "m3"},
        "r-t1": {"messages": [{"id": "rm", "kind": "text", "role": "bot", "text": "Room answer", "at": 120, "parentId": None,
            "from": {"botId": "scout", "name": "Scout", "color": "blue"}, "peerPost": {"unattended": True}}], "activeLeaf": "rm"},
    };
    routines: list[any] = [
        {"id": "r1", "name": "Daily", "prompt": "Report progress", "target": "bot", "botId": "chief", "runOn": "maus",
         "enabled": True, "schedule": {"type": "daily", "time": "09:00", "weekdays": [1, 2, 3, 4, 5]}, "durationMinutes": 30},
        {"id": "r2", "name": "Standup", "prompt": "Discuss progress", "target": "room-goal", "groupId": "room", "botId": "chief",
         "runOn": "maus", "enabled": True, "schedule": {"type": "interval", "everyMinutes": 30, "anchorAt": 0}, "durationMinutes": 30},
    ];
    return {"bots": [chief, scout, ava, archived], "groups": [group], "threads": threads, "memory": {},
            "sections": ["Engineering", "Operations"], "routines": routines};
}

# Fake Store behind the bridge hook; `fail` names a call that throws once.
def _harness(f: dict[str, any]) -> dict[str, any] {
    h: dict[str, any] = {"calls": [], "fail": None, "fail_after": False, "n": 0, "ids": 0,
        "bots": {}, "groups": {}, "transcripts": {}, "routines": f["routines"], "removed": []};
    for b in f["bots"] { h["bots"][b["id"]] = b; }
    for g in f["groups"] { h["groups"][g["id"]] = g; }
    def _store(call: str, args: dict[str, any]) -> any {
        h["calls"].append({"call": call, "args": json.loads(json.dumps(args))});
        if h["fail"] == call and not h["fail_after"] {
            h.update({"fail": None});
            raise Exception("fixture " + call + " failure");
        }
        res: any = None;
        if call == "createBot" {
            h["n"] += 1;
            bid = "new-bot-" + str(h["n"]);
            res = dict(args["profile"]);
            res.update({"id": bid, "threadId": bid + "-t"});
            h["bots"][bid] = res;
        } elif call == "patchBot" {
            h["bots"][args["botId"]].update(args["patch"]);
            res = h["bots"][args["botId"]];
        } elif call == "createGroup" {
            h["n"] += 1;
            gid = "new-room-" + str(h["n"]);
            res = dict(args);
            res.update({"id": gid, "threadId": gid + "-t"});
            h["groups"][gid] = res;
        } elif call == "patchGroup" {
            h["groups"][args["groupId"]].update(args["patch"]);
        } elif call == "createGroupTask" {
            h["n"] += 1;
            res = {"threadId": "new-task-" + str(h["n"])};
        } elif call == "setGroupTasks" {
            h["groups"][args["groupId"]]["tasks"] = args["tasks"];
        } elif call == "importTranscript" {
            h["transcripts"][args["threadId"]] = args;
        } elif call == "rollback" {
            for bid in list(h["bots"].keys()) {
                if bid not in args["existingBotIds"] { h["bots"].pop(bid); }
            }
            for gid in list(h["groups"].keys()) {
                if gid not in args["existingGroupIds"] { h["groups"].pop(gid); }
            }
        }
        if h["fail"] == call and h["fail_after"] {
            h.update({"fail": None});
            raise Exception("creation failed before returning");
        }
        return res;
    }
    def _list -> list[any] { return h["routines"]; }
    def _create(input: dict[str, any]) -> dict[str, any] {
        if h["fail"] == "routine" {
            h.update({"fail": None});
            raise Exception("fixture disk failure");
        }
        h["ids"] += 1;
        r = dict(input);
        r.update({"id": "new-routine-" + str(h["ids"]), "nextRunAt": None});
        h["routines"].append(r);
        return r;
    }
    def _remove(rid: str) -> bool {
        h["removed"].append(rid);
        h["routines"] = [r for r in h["routines"] if r["id"] != rid];
        return True;
    }
    def _now -> int { return NOW; }
    def _new_id -> str {
        h["ids"] += 1;
        return "id-" + str(h["ids"]);
    }
    _reset();
    _tb.update({"hooks": {"store": _store, "routines_list": _list, "routine_create": _create,
        "routine_remove": _remove, "now": _now, "new_id": _new_id}});
    return h;
}

def _existing(h: dict[str, any], f: dict[str, any]) -> dict[str, any] {
    return {
        "bots": [{"id": b["id"], "name": b["name"], "section": b.get("section")} for b in h["bots"].values()],
        "groups": [{"id": g["id"], "name": g["name"], "section": g.get("section")} for g in h["groups"].values()],
        "sections": f["sections"],
    };
}

def _snapshot(h: dict[str, any], f: dict[str, any]) -> dict[str, any] {
    return {"bots": list(h["bots"].values()), "groups": list(h["groups"].values()), "threads": f["threads"], "memory": f["memory"]};
}

def _backup(h: dict[str, any], f: dict[str, any]) -> dict[str, any] {
    return json.loads(json.dumps(create_team_backup(_snapshot(h, f), "My team")));
}

def _import(h: dict[str, any], f: dict[str, any], backup: any) -> dict[str, any] {
    return import_team_backup(backup, {"instanceId": "fixture", "model": "fixture-model"}, _existing(h, f), None);
}

def _created_bot(h: dict[str, any], name: str) -> dict[str, any] {
    for b in h["bots"].values() {
        if b["name"] == name { return b; }
    }
    raise Exception("no bot " + name);
}

def _bk(backup: dict[str, any], key: str) -> dict[str, any] {
    for b in backup["bots"] {
        if b["key"] == key { return b; }
    }
    raise Exception("no backup bot " + key);
}

def _calls(h: dict[str, any], call: str) -> list[any] {
    return [c["args"] for c in h["calls"] if c["call"] == call];
}

test "carries tool restrictions through backup and import without restoring execution grants" {
    f = _fixture();
    scope = {"allow": ["native:read", "mcp:notes:read"], "deny": ["mcp:notes:write"]};
    f["bots"][0]["toolScope"] = scope;
    f["bots"][1]["toolScope"] = {"allow": []};
    h = _harness(f);
    backup = _backup(h, f);
    assert _bk(backup, "chief")["toolScope"] == scope;
    _import(h, f, backup);
    mira = _created_bot(h, "Mira 2");
    assert mira["toolScope"] == scope;
    assert mira["computer"] == "off" and mira["composio"] is False and mira["approvalMode"] == "ask" and mira["connectorTools"] == {};
    assert _created_bot(h, "Scout 2")["toolScope"] == {"allow": []};
    invalid = json.loads(json.dumps(backup));
    invalid["bots"][0]["toolScope"] = {"allow": None};
    def _bad { parse_team_backup(invalid); }
    _throws(_bad, "^Invalid backup: bots.0.toolScope: Invalid tool selection$");
}

test "carries each bot's memory, scrubbed on the way out" {
    f = _fixture();
    key = "sk-ant-api03-" + "k" * 40;
    f["memory"] = {
        "chief": {"file": "- 2026-09-10 · note\n", "topics": [{"name": "deploys.md", "text": "railway up from main\n"},
            {"name": "keys.md", "text": "anthropic: " + key + "\n"}, {"name": "gone.md", "text": None}],
            "logs": [{"name": "2026-09-10.md", "text": "- 12:00 · shipped\n"}]},
        "scout": {"file": "", "topics": [], "logs": []},
    };
    h = _harness(f);
    backup = _backup(h, f);
    exported = _bk(backup, "chief")["memory"];
    assert exported["file"] == "- 2026-09-10 · note\n";
    assert [t["name"] for t in exported["topics"]] == ["deploys.md", "keys.md"];
    assert key not in exported["topics"][1]["text"];
    assert "anthropic: «redacted" in exported["topics"][1]["text"];
    assert exported["logs"] == [{"name": "2026-09-10.md", "text": "- 12:00 · shipped\n"}];
    assert "memory" not in _bk(backup, "scout");
    assert key not in json.dumps(backup);
    _import(h, f, backup);
    restored = _calls(h, "restoreMemory");
    assert len(restored) == 1;
    assert restored[0]["botId"] == _created_bot(h, "Mira 2")["id"];
    assert restored[0]["memory"] == exported;
}

test "round-trips all bots, sections, Chiefs, rooms, tasks and branches without changing originals" {
    f = _fixture();
    h = _harness(f);
    originals = json.loads(json.dumps(list(h["bots"].values())));
    backup = _backup(h, f);
    result = _import(h, f, backup);
    assert len(result["bot_ids"]) == 4;
    assert len(result["group_ids"]) == 1;
    for b in originals { assert h["bots"][b["id"]] == b; }
    mira = _created_bot(h, "Mira 2");
    scout = _created_bot(h, "Scout 2");
    assert mira["soul"] == f["bots"][0]["soul"];
    assert mira["section"] == "Engineering 2" and mira["chiefOfStaff"] is True;
    assert mira["composio"] is False and mira["browser"] is False and mira["autoApprove"] is False;
    assert mira["playbooks"] == f["bots"][0]["playbooks"];
    assert _created_bot(h, "Ava 2")["section"] == "Operations 2";
    assert _created_bot(h, "Archived 2")["hidden"] is True;
    assert "cwd" not in mira and "alwaysAllow" not in mira;
    assert mira["modelSelection"] == {"instanceId": "fixture", "model": "fixture-model"};
    assert all([t["activity"] == "idle" and t["busy"] is False and t["unread"] is False and "modelSelection" not in t for t in mira["tasks"]]);
    assert scout["mascotBody"] == "circle";
    room = h["groups"][result["group_ids"][0]];
    assert room["name"] == "Project room 2" and room["section"] == "Engineering 2";
    assert room["memberIds"] == [mira["id"], scout["id"]];
    assert room["defaultResponder"] == {"kind": "member", "botId": mira["id"]};
    assert [[t["title"], t["createdAt"]] for t in room["tasks"]] == [["Project room", 50], ["Second room task", 51]];
    room_msg = h["transcripts"][room["threadId"]]["messages"][0];
    assert room_msg["text"] == "Room answer" and room_msg["from"]["botId"] == scout["id"] and room_msg["peerPost"] == {"unattended": True};
    assert all([r["enabled"] is False and r["nextRunAt"] is None for r in result["routines"]]);
    goal = [r for r in result["routines"] if r["target"] == "room-goal"][0];
    assert goal["botId"] == mira["id"] and goal["groupId"] == room["id"];
    by_title: dict[str, any] = {};
    for t in mira["tasks"] { by_title[t["title"]] = t; }
    assert by_title["Second conversation"]["openedBy"] == {"botId": scout["id"], "name": "Scout", "at": 99, "kind": "pair"};
    assert "openedBy" not in by_title["Opened by a deleted bot"];
    assert "openedBy" not in by_title["First conversation"];
    assert by_title["Second conversation"]["closedBy"] == {"botId": scout["id"], "name": "Scout", "at": 103};
    assert "closedBy" not in by_title["Opened by a deleted bot"];
    first = h["transcripts"][by_title["First conversation"]["threadId"]];
    assert [m["text"] for m in first["messages"]] == ["Original question", "Original answer", "Edited question"];
    assert first["messages"][1]["parentId"] == first["messages"][0]["id"];
    assert first["messages"][2]["parentId"] is None;
    assert first["activeLeafId"] == first["messages"][1]["id"];
    assert mira["threadId"] == by_title["Second conversation"]["threadId"];
    history = h["transcripts"][mira["threadId"]]["messages"];
    assert all([m["kind"] == "text" and "queued" not in m and "card" not in m for m in history]);
    assert "Permission request" in history[1]["text"];
    assert "file not included" in history[2]["text"];
    assert not re.search(r"do-not-replay|do-not-resume|/private/image|/private/old-workspace|alwaysAllow|autoApprove|modelSelection|delegationId", json.dumps(backup));
    # Re-import makes another independent set.
    snapshot_mira = json.loads(json.dumps(mira));
    _import(h, f, backup);
    again = _created_bot(h, "Mira 3");
    assert again["section"] == "Engineering 3" and again["chiefOfStaff"] is True;
    assert _created_bot(h, "Mira 2") == snapshot_mira;
}

test "carries connector grants in the private backup but lands imported bots grant-less" {
    f = _fixture();
    f["bots"][0]["connectorTools"] = {"gmail": {"tools": ["GMAIL_SEND_EMAIL"]}};
    h = _harness(f);
    backup = _backup(h, f);
    assert _bk(backup, "chief")["connectorTools"] == {"gmail": {"tools": ["GMAIL_SEND_EMAIL"]}};
    _import(h, f, backup);
    mira = _created_bot(h, "Mira 2");
    assert mira["composio"] is False and mira["connectorTools"] == {};
    tampered = json.loads(json.dumps(backup));
    tampered["bots"][0]["connectorTools"] = {"gmail": {"tools": []}};
    def _bad { parse_team_backup(tampered); }
    _throws(_bad, "connectorTools.gmail.tools: Too small: expected array to have >=1 items");
}

test "keeps first-message title markers armed-once through backup and restore" {
    f = _fixture();
    f["bots"][0]["tasks"].append({"threadId": "c-t4", "title": "Audit the payroll export", "createdAt": 13, "titleFromFirstMessage": True});
    f["groups"][0]["tasks"].append({"threadId": "r-t3", "title": "Plan the launch review", "createdAt": 52, "titleFromFirstMessage": True});
    h = _harness(f);
    backup = _backup(h, f);
    assert [t for t in _bk(backup, "chief")["tasks"] if t["key"] == "c-t4"][0]["titleFromFirstMessage"] is True;
    assert [t for t in backup["groups"][0]["tasks"] if t["key"] == "r-t3"][0]["titleFromFirstMessage"] is True;
    result = _import(h, f, backup);
    mira = _created_bot(h, "Mira 2");
    assert [t for t in mira["tasks"] if t["title"] == "Audit the payroll export"][0]["titleFromFirstMessage"] is True;
    assert "titleFromFirstMessage" not in [t for t in mira["tasks"] if t["title"] == "First conversation"][0];
    room = h["groups"][result["group_ids"][0]];
    assert [t for t in room["tasks"] if t["title"] == "Plan the launch review"][0]["titleFromFirstMessage"] is True;
}

test "keeps a conversation's longer turn limit through backup and restore" {
    f = _fixture();
    f["groups"][0]["tasks"][1]["turnTimeoutMinutes"] = 30;
    f["groups"].append({"id": "dm", "name": "Direct", "memberIds": ["chief", "scout"], "dm": True, "bulletin": "",
        "defaultResponder": {"kind": "everyone"}, "threadId": "d-t1", "createdAt": 60, "turnTimeoutMinutes": 45,
        "tasks": [{"threadId": "d-t1", "title": "Direct", "createdAt": 60}]});
    h = _harness(f);
    backup = _backup(h, f);
    room_task = [t for t in backup["groups"][0]["tasks"] if t["key"] == "r-t2"][0];
    assert room_task["turnTimeoutMinutes"] == 30;
    assert backup["groups"][1]["tasks"][0]["turnTimeoutMinutes"] == 45;
    assert all([all(["turnTimeoutMinutes" not in t for t in b["tasks"]]) for b in backup["bots"]]);
    result = _import(h, f, backup);
    room = h["groups"][result["group_ids"][0]];
    assert [t for t in room["tasks"] if t["title"] == "Second room task"][0]["turnTimeoutMinutes"] == 30;
    dm = h["groups"][result["group_ids"][1]];
    assert dm["turnTimeoutMinutes"] == 45 and dm["dm"] is True;
    # a direct-message room keeps its one task: never renamed, no task list rewrite
    assert all([c["groupId"] != dm["id"] for c in _calls(h, "renameGroupTask") + _calls(h, "setGroupTasks")]);
}

test "rejects corrupted backups before any writes" {
    for corruption in ["unknown-version", "duplicate-bot", "cycle", "dangling-room", "dangling-task", "duplicate-chief", "oversized-soul"] {
        f = _fixture();
        h = _harness(f);
        backup = _backup(h, f);
        source = _bk(backup, "chief");
        if corruption == "unknown-version" { backup["version"] = 2; }
        if corruption == "duplicate-bot" { backup["bots"].append(source); }
        if corruption == "cycle" { source["tasks"][2]["messages"][0]["parentId"] = source["tasks"][2]["messages"][0]["id"]; }
        if corruption == "dangling-room" { backup["groups"][0]["memberIds"].append("missing"); }
        if corruption == "dangling-task" { source["activeTask"] = "missing"; }
        if corruption == "duplicate-chief" { _bk(backup, "scout")["chiefOfStaff"] = True; }
        if corruption == "oversized-soul" { source["soul"] = "🐭" * 6001; }
        def _go { _import(h, f, backup); }
        _throws(_go, "Invalid backup");
        assert h["calls"] == [], corruption;
    }
}

test "accepts legacy backups without soul and enforces its UTF-8 byte cap" {
    f = _fixture();
    h = _harness(f);
    backup = _backup(h, f);
    for b in backup["bots"] { b.pop("soul", None); }
    _import(h, f, backup);
    assert all(["soul" not in c["profile"] for c in _calls(h, "createBot")]);
    backup["bots"][0]["soul"] = "🐭" * 6000;
    assert parse_team_backup(backup)["bots"][0]["soul"] == backup["bots"][0]["soul"];
    backup["bots"][0]["soul"] += "!";
    def _bad { parse_team_backup(backup); }
    _throws(_bad, "24000 bytes");
}

test "strips injected permissions, IDs and live actions from untrusted files" {
    f = _fixture();
    h = _harness(f);
    backup = _backup(h, f);
    source = _bk(backup, "chief");
    source.update({"id": "chief", "threadId": "c-t3", "cwd": "/tmp", "composio": True, "approvalMode": "full",
        "autoApprove": True, "browser": True, "computer": "local", "resumeCursors": {"fixture": "secret-session"}});
    source["tasks"][0]["messages"][0].update({"kind": "options", "queued": True, "card": {"requestId": "live-approval"},
        "attachments": [{"path": "/etc/passwd"}]});
    _import(h, f, backup);
    mira = _created_bot(h, "Mira 2");
    assert mira["id"] != "chief" and mira["threadId"] != "c-t3";
    assert mira["approvalMode"] == "ask";
    assert not re.search(r"live-approval|secret-session|/etc/passwd|approvalMode", json.dumps(parse_team_backup(backup)));
}

test "rolls back fresh bots, rooms and routines after a late failure" {
    f = _fixture();
    h = _harness(f);
    before_bots = list(h["bots"].keys());
    backup = _backup(h, f);
    h["fail"] = "routine";
    def _go { _import(h, f, backup); }
    _throws(_go, "fixture disk failure");
    rollback = _calls(h, "rollback");
    assert len(rollback) == 1;
    assert rollback[0]["existingBotIds"] == before_bots;
    assert rollback[0]["existingGroupIds"] == ["room"];
    assert sorted(rollback[0]["sections"]) == ["Engineering 2", "Imported bots", "Operations 2"];
    assert list(h["bots"].keys()) == before_bots;
    assert [r["id"] for r in h["routines"]] == ["r1", "r2"];
}

test "also rolls back a creation that throws before returning its new record" {
    f = _fixture();
    h = _harness(f);
    before_bots = list(h["bots"].keys());
    backup = _backup(h, f);
    h["fail"] = "createBot";
    h["fail_after"] = True;
    def _go { _import(h, f, backup); }
    _throws(_go, "creation failed");
    assert len(_calls(h, "rollback")) == 1;
    assert list(h["bots"].keys()) == before_bots;
}

test "keeps case-distinct sections and their Chiefs separate" {
    f = _fixture();
    f["bots"].append({"id": "other", "name": "Another chief", "title": "", "description": "", "section": "engineering",
        "color": "pink", "chiefOfStaff": True, "hidden": False, "threadId": "o-t1", "createdAt": 70});
    f["sections"].append("engineering");
    h = _harness(f);
    _import(h, f, _backup(h, f));
    mira = _created_bot(h, "Mira 2");
    other = _created_bot(h, "Another chief 2");
    assert mira["chiefOfStaff"] is True and other["chiefOfStaff"] is True;
    assert mira["section"].lower() != other["section"].lower();
}

test "backs up room history even when old deletions left dangling memberships and routines" {
    f = _fixture();
    f["groups"].append({"id": "olddm", "name": "Old direct message", "memberIds": ["chief", "scout"], "dm": True, "bulletin": "",
        "defaultResponder": {"kind": "everyone"}, "threadId": "od-t1", "createdAt": 80, "tasks": []});
    f["threads"]["od-t1"] = {"messages": [{"id": "old", "kind": "text", "role": "bot", "text": "Keep this old reply", "at": 130,
        "parentId": None, "from": {"botId": "chief", "name": "Mira", "color": "green"}}], "activeLeaf": "old"};
    f["bots"] = f["bots"][1:];
    h = _harness(f);
    backup = _backup(h, f);
    assert len(backup["warnings"]) == 4;
    assert backup["routines"] == [];
    room = [g for g in backup["groups"] if g["key"] == "room"][0];
    assert room["memberIds"] == ["scout"] and room["defaultResponder"] == {"kind": "mentions"};
    assert [g for g in backup["groups"] if g["key"] == "olddm"][0]["dm"] is False;
    result = _import(h, f, backup);
    olddm = [g for g in h["groups"].values() if g["name"] == "Old direct message 2"][0];
    assert h["transcripts"][olddm["threadId"]]["messages"][0]["text"] == "Mira:\nKeep this old reply";
    assert h["groups"]["room"]["memberIds"] == ["chief", "scout"];
}

test "zod-faithful parse messages, shape-ordered output and trimmed names" {
    f = _fixture();
    h = _harness(f);
    base = _backup(h, f);
    cases = [
        ["notobj", "file: Invalid input: expected object, received number"],
        ["fmt", "format: Invalid input: expected \"openmaus.backup\""],
        ["nameEmpty", "name: Too small: expected string to have >=1 characters"],
        ["color", "bots.0.color: Invalid option: expected one of \"green\"|\"blue\"|\"red\"|\"orange\"|\"purple\"|\"cyan\"|\"pink\"|\"yellow\"|\"teal\"|\"coral\""],
        ["missingKey", "bots.0.key: Invalid input: expected string, received undefined"],
        ["slug", "bots.0.connectorTools.Bad: Invalid key in record"],
        ["respKind", "groups.0.defaultResponder.kind: Invalid discriminator value. Expected 'member' | 'everyone' | 'mentions' | 'auto'"],
        ["toolsNum", "bots.0.connectorTools.gmail.tools: Invalid input"],
        ["ttm", "bots.0.tasks.0.turnTimeoutMinutes: Too small: expected number to be >=1"],
        ["exportedStr", "exportedAt: Invalid input: expected number, received string"],
    ];
    for c in cases {
        b = json.loads(json.dumps(base));
        k = c[0];
        if k == "fmt" { b["format"] = "x"; }
        if k == "nameEmpty" { b["name"] = "  "; }
        if k == "color" { b["bots"][0]["color"] = "black"; }
        if k == "missingKey" { b["bots"][0].pop("key"); }
        if k == "slug" { b["bots"][0]["connectorTools"] = {"Bad": {"tools": "*"}}; }
        if k == "respKind" { b["groups"][0]["defaultResponder"] = {"kind": 5}; }
        if k == "toolsNum" { b["bots"][0]["connectorTools"] = {"gmail": {"tools": 5}}; }
        if k == "ttm" { b["bots"][0]["tasks"][0]["turnTimeoutMinutes"] = 0; }
        if k == "exportedStr" { b["exportedAt"] = "1"; }
        def _go { parse_team_backup(5 if k == "notobj" else b); }
        msg = _throws(_go, "^Invalid backup: ");
        assert msg == "Invalid backup: " + c[1], msg;
    }
    b = json.loads(json.dumps(base));
    b["name"] = "  Spaced ﻿";
    b["extra"] = True;
    b["groups"][0]["defaultResponder"] = {"kind": "future"};
    parsed = parse_team_backup(b);
    assert parsed["name"] == "Spaced";
    assert "extra" not in parsed;
    assert list(parsed.keys()) == ["format", "version", "name", "exportedAt", "warnings", "bots", "groups", "routines"];
    assert parsed["groups"][0]["defaultResponder"] == {"kind": "member", "botId": "chief"};
}

test "take_import_name suffixes case-insensitively within the length cap" {
    taken: set[str] = set(["mira", "mira 2"]);
    assert take_import_name(" Mira ", taken) == "Mira 3";
    assert take_import_name("x" * 60, set(["x" * 60]), 60) == "x" * 58 + " 2";
}

test "round-trips an Auto room with its fallback mapped to the imported bot" {
    f = _fixture();
    f["groups"][0]["defaultResponder"] = {"kind": "auto", "fallbackBotId": "scout"};
    h = _harness(f);
    backup = _backup(h, f);
    assert backup["groups"][0]["defaultResponder"] == {"kind": "auto", "fallbackBotId": "scout"};
    result = _import(h, f, backup);
    room = h["groups"][result["group_ids"][0]];
    assert room["defaultResponder"] == {"kind": "auto", "fallbackBotId": _created_bot(h, "Scout 2")["id"]};
}
