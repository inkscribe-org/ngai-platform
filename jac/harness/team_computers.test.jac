"""Ported invariants from server/team-computers.test.ts.

Annexes team_computers.jac (no self-import). `new TeamComputers(file, env)`
becomes `_open(file, env)`: fresh in-memory state, then the same load.
The zod API-boundary case (teamComputerCreate/teamComputerAssignment) stays
with the schemas in shared/computers.ts; it is not harness logic.
"""

import shutil;
import tempfile;

glob _dirs: list[str] = [];

def _cleanup {
    while len(_dirs) > 0 {
        shutil.rmtree(_dirs.pop(), ignore_errors=True);
    }
}

def _open(file: str, environment_id: str) {
    _reset();
    _tc.update({"file": file});
    tc_load(environment_id);
}

def _fixture -> dict[str, any] {
    _cleanup();
    d = tempfile.mkdtemp(prefix="omb-team-computers-");
    _dirs.append(d);
    f = os.path.join(d, "team-computers.json");
    env = str(uuid.uuid4());
    _open(f, env);
    return {"file": f, "env": env};
}

def _raises(fn: any, pattern: str) -> int {
    try {
        fn();
    } except Exception as e {
        assert re.search(pattern, str(e)) is not None, str(e);
        return _status_of(e);
    }
    assert False, "expected a failure matching " + pattern;
    return 0;
}

test "renames the team label without changing computer identity or merging assignments" {
    fx = _fixture();
    a = tc_create("Desktop A");
    b = tc_create("Desktop B");
    tc_assign(a["id"], "Research");
    tc_assign(b["id"], "Delivery");
    def _merge { tc_rename_section("Research", "Delivery"); }
    _raises(_merge, "already has");
    assert tc_rename_section("Research", "Studio") is True;
    assert tc_for_section("Research") is None;
    _open(fx["file"], fx["env"]);
    got = tc_for_section("Studio");
    assert got["id"] == a["id"] and got["name"] == a["name"];
    assert tc_for_section("Delivery")["id"] == b["id"];
    _cleanup();
}

test "persists unassigned identities before provisioning and retries without a second owner" {
    fx = _fixture();
    request_id = str(uuid.uuid4());
    created = tc_create("Design desktop", request_id);
    assert created["id"] == request_id and created["name"] == "Design desktop" and created["section"] is None;
    assert tc_create("Design desktop", request_id) == created;
    def _other { tc_create("Different name", request_id); }
    _raises(_other, "different computer");
    tc_set_problem(request_id, "Provider unavailable");
    _open(fx["file"], fx["env"]);
    assert len(tc_list()) == 1;
    assert tc_get(request_id)["problem"] == "Provider unavailable";
    again = dict(created);
    again["problem"] = "Provider unavailable";
    assert tc_create("Design desktop", request_id) == again;
    assert len(tc_list()) == 1;
    tc_set_problem(request_id, None);
    _open(fx["file"], fx["env"]);
    assert "problem" not in tc_get(request_id);
    assert os.stat(fx["file"]).st_mode & 0o777 == 0o600;
    _cleanup();
}

test "has one computer per team and requires explicit unassignment before moving" {
    fx = _fixture();
    one = tc_create("One");
    two = tc_create("Two");
    tc_assign(one["id"], "Design");
    def _dup { tc_assign(two["id"], "Design"); }
    _raises(_dup, "already has");
    def _move { tc_assign(one["id"], "Engineering"); }
    _raises(_move, "Unassign");
    tc_assign(one["id"], None);
    tc_assign(two["id"], "Design");
    tc_assign(one["id"], "Engineering");
    _open(fx["file"], fx["env"]);
    assert tc_for_section("Design")["id"] == two["id"];
    _cleanup();
}

test "distinguishes General from unassigned and treats prototype team names as data" {
    _fixture();
    one = tc_create("One");
    two = tc_create("Two");
    assert tc_for_section(None) is None;
    tc_assign(one["id"], "");
    tc_assign(two["id"], "__proto__");
    assert tc_for_section(None)["id"] == one["id"];
    assert tc_for_section("__proto__")["id"] == two["id"];
    _cleanup();
}

test "only Auto without explicit VPS inherits" {
    _fixture();
    c = tc_create("Shared desktop");
    tc_assign(c["id"], "Design");
    assert tc_for_bot({"section": "Design"})["id"] == c["id"];
    assert tc_for_bot({"section": "Design", "cloudBackend": "box"})["id"] == c["id"];
    for mode in ["cloud", "local", "vm", "off", "browser"] {
        assert tc_for_bot({"section": "Design", "computer": mode}) is None;
    }
    assert tc_for_bot({"section": "Design", "cloudBackend": "vps"}) is None;
    assert tc_for_bot({"section": "Other"}) is None;
    _cleanup();
}

test "fails closed for malformed durable data" {
    for contents in ["{bad", "[]", json.dumps({"version": 2, "computers": []})] {
        fx = _fixture();
        with open(fx["file"], "w") as fh { fh.write(contents); }
        _open(fx["file"], fx["env"]);
        assert _raises(tc_list, "could not be loaded") == 503;
        def _create { tc_create("Replacement"); }
        _raises(_create, "could not be loaded");
        def _for_bot { tc_for_bot({"section": "Design"}); }
        _raises(_for_bot, "could not be loaded");
        with open(fx["file"]) as fh { assert fh.read() == contents; }
        # node's mirror sees the problem, not an empty pool
        assert "could not be loaded" in _view()["problem"];
    }
    _cleanup();
}

test "rejects duplicate identities, team assignments and another workspace's registry" {
    fx = _fixture();
    tc_create("One");
    with open(fx["file"]) as fh { saved = json.loads(fh.read()); }
    first = saved["computers"][0];
    def _write(computers: list[any]) {
        body = dict(saved);
        body["computers"] = computers;
        with open(fx["file"], "w") as fh { fh.write(json.dumps(body)); }
    }
    _write([first, first]);
    _open(fx["file"], fx["env"]);
    _raises(tc_list, "duplicate computer");
    a = dict(first);
    a["section"] = "Design";
    b = dict(first);
    b["id"] = str(uuid.uuid4());
    b["section"] = "Design";
    _write([a, b]);
    _open(fx["file"], fx["env"]);
    _raises(tc_list, "more than one");
    _write([first]);
    _open(fx["file"], str(uuid.uuid4()));
    _raises(tc_list, "another workspace");
    _cleanup();
}

test "does not follow a registry symlink or return writable internal entries" {
    fx = _fixture();
    original = tc_create("One");
    tc_list()[0]["section"] = "Unconsented";
    assert tc_get(original["id"])["section"] is None;
    link = fx["file"] + ".link";
    os.symlink(fx["file"], link);
    _open(link, fx["env"]);
    _raises(tc_list, "unsafe registry");
    _cleanup();
}

test "writes compact JSON.stringify bytes in schema key order" {
    fx = _fixture();
    _tc["now_ms"] = 1786874400000;
    c = tc_create("  Padded  ", "5c57ceec-f5aa-4d79-a9c7-0e1f93875e70");
    assert c["name"] == "Padded";
    tc_assign(c["id"], " Design ");
    tc_set_problem(c["id"], "x" * 600);
    with open(fx["file"]) as fh { text = fh.read(); }
    want = '{"version":1,"environmentId":"' + fx["env"] + '","computers":[{"id":"5c57ceec-f5aa-4d79-a9c7-0e1f93875e70","name":"Padded","section":"Design","createdAt":1786874400000,"problem":"' + ("x" * 500) + '"}]}';
    assert text == want;
    _cleanup();
}

test "def:pub surface reloads for its workspace and answers envelopes" {
    fx = _fixture();
    _tc["loaded"] = False;
    made = team_computer_create(environment_id=fx["env"], name="One", id=None);
    assert made["computer"]["name"] == "One";
    assert made["view"]["computers"][0]["id"] == made["computer"]["id"];
    bad = team_computer_assign(environment_id=fx["env"], id="missing", section=None);
    assert bad["ok"] is False and bad["status"] == 404;
    assert team_computer_list(environment_id=None)["status"] == 400;
    _cleanup();
}
