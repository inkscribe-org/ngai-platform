# Working Agreement

## 1. Never push to `main` without review

All changes go on a feature branch with a PR for Human to review first — **including** small fixes, follow-ups, and tweaks to already-merged work.

- Before any `git push`, check the current branch.
- If it's `main`, stop: create a feature branch, push that, and open a PR instead.
- PR-then-merge is the rule, not a convention of convenience.

## 3. Don't work around jac/jaseci bugs — fix them upstream

When a reasonable Jac idiom — especially Object-Spatial Programming (OSP) constructs — fails, errors, or behaves unexpectedly:

1. First verify it's actually a jac/jaseci defect, not a misuse (check docs/examples/tests in the submodule).
2. If it is the language/runtime, **pause the affected work and create a proper upstream fix**: isolate a minimal repro, fix the root cause on a feature branch based on upstream `jac` main, add regression coverage, and run the relevant checks.
3. Push the fix and open a PR against `jaseci-labs/jac` main. This workflow is authorized without asking for separate permission for each defect. Report the issue, validation results, and PR link.
4. **Resume the original ngai work using the locally fixed compiler/runtime** while the PR awaits review. Do not wait for the upstream merge unless it is technically necessary. Keep track of the local compiler patches required for validation.
5. Do **not** rewrite engine code to avoid the construct. If an upstream fix or PR cannot be completed, explain the concrete blocker and continue any independent work that remains possible.

The point is to drive fixes upstream, not to route around them.

## 4. Prefer Jac's Object-Spatial features wherever natural

Use Jac's Object-Spatial Programming (OSP) features — nodes, edges, walkers, abilities, and graph traversal — everywhere they're a natural fit for the project, rather than falling back to plain procedural or object-oriented code.

- Model state and relationships as graphs (nodes + edges) when the domain is spatial or relational.
- Express traversal and behavior as walkers and abilities rather than hand-rolled loops over data structures.
- Reach for OSP first when designing new features; only drop to non-OSP code when OSP genuinely doesn't fit.

## 5. Jac toolchain notes (0.37.x)

Learned during the phase-0 spike (`jac/spike/`); keep updated as we hit more:

- Toolchain: `jac` binary via jacup (`~/.local/share/jacup/versions/`). Upstream
  source is the `third_party/jac` submodule (jaseci-labs/jac `main`).
- `jac.toml`: `kind = "service"` + `entry-point` makes `jac run` serve HTTP;
  `walker:pub` → `POST /walker/<name>`, `def:pub` → `POST /function/<name>`.
  A walker/def returning a generator or async generator is auto-wrapped as SSE
  (`text/event-stream`, `event: end` trailer) — that is the SSE mechanism.
- Guest (unauthenticated) calls are allowed; caller falls back to `GUEST`.
- Python interop is free (`sv↔py` is a direct call): `import asyncio`,
  `import sqlite3`, `import from subprocess { Popen }` just work, including
  `asyncio.create_subprocess_exec` + `async for` over `proc.stdout`.
- Backtick only real Jac keywords as identifiers (`default=`, `` `wait() ``);
  a backticked non-keyword is a hard error, not a no-op.
- `glob` declares module state but functions CANNOT rebind the name —
  `x = v` inside a `def` creates a local (reads then see the module
  default, or UnboundLocalError if a local assign comes after a local
  read). Mutate through a dict/field (`_state["h"] = c`) or
  `globals()["x"] = v`. Annotate the glob's type (`: any`, `: int`) when
  the initializer is `None`, else the checker pins it to `NoneType`.
- `is None` / `is not None`, never `== None` (checker warning).
- Node-type filter: `[-->][?:Type]` — backticks in filter syntax are errors.
- `with entry` is not async; `await` lives in `async def`/`async can`. Drive
  coroutines from `with entry` via `asyncio.run(...)`.
- `asyncio.create_task` needs a running loop — call it from `async def:pub`,
  not sync `def:pub` endpoints.
- `jac run` auto-creates an `admin` user (default password) and mounts `/admin`
  routes — secure or disable before real traffic.
- Runtime drops `.jac/` (compile cache, jwt secret) beside the project;
  both `.jac/` and `jac/**/*.db` are gitignored.
- Bare `dict`/`list`/`tuple`/`set` annotations are errors — always
  `dict[str, any]`, `list[any]`. `match`, `entry`, `hash` are keywords
  (rename or backtick-escape). In-function docstrings are bare-expression
  errors — use `#` comments. `for (k, v) in d.items()` needs parens.
- `def:pub`/`walker:pub` optional params bind the *stringified* default
  when the request omits them ('None', '40' — jaclang defect; fix in
  flight upstream). Until patched, callers must send explicit values.
- `jac run` inside a `kind = "service"` project always serves; to execute
  module code ad hoc, run via the meta-importer from a Python with
  jaclang installed (`/tmp/jacvenv`):
  `sys.meta_path.insert(0, jaclang.meta_importer.JacMetaImporter())` then
  `import <module>` with the harness dir on `sys.path`.
- Typed traversal filter: `[n ->:EdgeType:->][?:NodeType]`; typed connect
  `a +>:E:+> b`; disconnect `a del ->:E:-> b`; spawn `w spawn n`.
- sqlite_master.sql stores CREATE text verbatim (minus IF NOT EXISTS) —
  `.dump` parity requires byte-identical DDL whitespace.
- The jacup binary unpacks jaclang sources to `~/.cache/jac/rt/<hash>/site/`,
  but serves them from `_precompiled/**/*.jir` bundles when those exist —
  **editing the `.jac` source under `site/` does nothing at runtime**;
  the impl annexes are fused into the base module's jir
  (`server/impl/server.impl.jac` → `server/server.jir`), keyed by manifest
  sha256 that does not track annex contents. Until a fixed jacup lands,
  the durable mitigation is app-side: treat any optional `def:pub` arg
  that is not the expected type as absent (`isinstance(x, dict)` /
  `isinstance(x, int)` guards in the public wrappers), since the fused
  binary binds the *stringified* default (`'None'`, `'40'`) when the
  request omits the kwarg. `routines.jac` does this for `req`-style
  request objects and `int|None` bounds.
- `def init` compiles to the module's `__init__` (invisible to callers) —
  name it `init_<thing>` or re-export: `glob init: any = init;` after the def.
- `<base>.test.jac` annexes onto `<base>.jac` — the module is the merge of
  both, so a test file must NOT `import` its own base (self-import = the
  partially-initialized module). For cross-module tests, create a stub
  `<base>.jac` and keep `import` statements in the annex only.


## 6. Routines on Jac (phase 2, done 2026-10-08)

- `jac/harness/routines.jac` is the scheduler; `server/routines.ts` is now
  types + `nextOccurrence` only. `server/jac-routines.ts` is the seam:
  serialized ops over `jacOp`, a sync mirror fed by emit frames, spawn +
  health supervision with restart backoff, and a shared-secret bridge.
- Jac→node bridge: jac POSTs `{op, ...payload}` to
  `/api/internal/routine-bridge` with snake_case top-level keys; node
  normalizes `bot_id/group_id/thread_id/run_on` to camel at the boundary
  and answers with both `threadId` and `thread_id` present.
- Jac's embedded Postgres daemon is shared machine-wide and listens under
  `<TMPDIR>/jacpg-<digest>`; the spawned harness overrides `TMPDIR` to
  `<XDG_CACHE_HOME|HOME/.cache>/jac/tmp` so fixture teardown cannot orphan
  the daemon's socket. Fixture verification environments forward the
  operator's `XDG_CACHE_HOME` so the ~830MB runtime extraction is reused.
- `scripts/verify-routines.ts` parks serving on success (Ctrl-C to stop;
  `timeout` exit 124 after printing the summary JSON is a pass). Fixture
  dataDirs self-clean; `OMB_VERIFY_KEEP_DATA=1` preserves them for
  post-mortems. `OMB_VERIFY_STEP_MS` widens the per-step wait.

## 7. Drivers on Jac (phase 3, done 2026-10-10)

- `server/jac-drivers.ts` is the seam: a shim `ProviderDriver` whose
  `create()` keeps the TS driver's declarative surface (kind, metadata,
  install, catalog, decodeConfig, auth) and swaps only the adapter for a
  facade over serialized `jacOp` calls (`driver_send_turn` →
  `driver_*` ops in `jac/harness/drivers.jac`). `respondToRequest`
  fails closed (`"unavailable"`) when the harness is down.
- Gating: `OMB_JAC_DRIVERS` is a comma list of kinds or `all`; unset
  means the TS drivers run unchanged. `scripts/control-omb.ts`
  forwards `OMB_JAC_DRIVERS` into verification fixture children, and
  `resolveJacBinary` prefers the jacup version pinned by
  `jac/harness/jac.toml` (`jac-version`). The old newest-jacup
  fallback silently picked 0.37.25 whose compiler generation has a
  cold prepare-cache slot — every fixture sidecar recompiled ~2 min
  and blew the golden eval's 20 s step budget. If a boot ever prints
  `[jac] Compiling server modules...` again, suspect a version or
  source-stamp mismatch, not the eval.
- Events flow Jac → node: `emit_event` in `drivers.jac` bridges
  `driver_event` ops to `/api/internal/routine-bridge`; the shim
  adapter re-emits into the unchanged bus (stamping, delta-merge,
  SSE). `hasSession` mirrors live turns off the event stream because
  the Jac side owns the live processes.
- `jac/harness/driver_claude.jac` (+ `_broker`/`_support`) is the full
  claudeAgent port: version-floor argv gating, MCP config file (0600)
  + ogb permission-proxy mount, AF_UNIX permission broker
  (`driver_claude_broker.jac`), process-group spawn/kill, stream-json
  parsing, argsKey warm-reuse, retry + resume-recovery,
  steered-continuation grace/silence timers. Login/device auth stays
  node-side (shim keeps the inner TS instance's auth methods).
  `driver_stub` in `drivers.jac` is the seam fixture (fake-CLI
  analogue), not dead code.
- 0.37.21 quirks hit by the port (workarounds in-tree; the first is a
  real defect fixed upstream by 0.37.25 — bump the pin to shed the
  rest deliberately, not by accident):
  - `glob _s: dict[str, any] = {"k": None}` narrows the slot to
    NoneType — `_s["k"] = "str"` is E1001 at compile. Workaround:
    `_state.update({...})` (see `drivers.jac _resolve_bridge_url`).
  - No lambda, no backslash line continuations, no `pass` statement;
    conditional expressions reject a middle `is not None` test;
    tuple unpacking `a, b = f()` is a parse error (index instead);
    `os.killpg(pid, sig)` fails E1053 on the int param (route the
    int through a nested def); reserved words beyond the documented
    set: `entry`, `own`, `obj`, `root`.
## 8. Porting a phase-4 subsystem (recipe, from webhooks 2026-10-10)

Webhooks (`jac/harness/webhooks.jac` + `server/jac-webhooks.ts`) is the
reference port. For each subsystem:

- **Jac module** `jac/harness/<name>.jac`: faithful port of the TS manager.
  Same on-disk files byte-for-byte where feasible (`_js_pretty` from
  routines.jac = `JSON.stringify(_, null, 2)`; tmp + `os.replace`, mode
  0600). Module state in one `glob _x: dict[str, any]` mutated via
  `.update()` / item assignment. Every TS options callback becomes an entry
  in a hook table (`_x["hooks"]`): node-side callbacks are bridge ops
  (`routines._bridge(op, {snake_case...})`), Jac-side ones are direct calls
  (e.g. webhooks → `routines._enqueue_webhook`). Errors are
  `_fail(status, msg)` (empty Exception subclass + `setattr(err, "status")`).
  zod messages: reproduce zod 4's first issue text (`path message`), probe
  real strings with a throwaway node script before porting.
- **HTTP surface**: `def:pub <name>_<op>(…, omb_token: any = None)` wrapped
  in `_invoke` (guard → fn → `{ok:false,status,error}`); re-bind each on
  `harness.jac` as a glob. Optional kwargs: type-check before use (fused
  binary stringifies omitted defaults).
- **Tests** `jac/harness/<name>.test.jac` (annex, no self-import): port the
  TS test invariants against fake hooks. `jac run` type-checks annexes
  too — a checker error in a test file breaks harness boot.
- **Node seam** `server/jac-<name>.ts`: async facade over `jacOp`, plus a
  sync mirror fed by emit frames (routines' `emit` bridge op forwards
  non-routine frames to each mirror) for call sites that cannot await.
  Transport that must stay in node until phase 5 (HTTP listeners) talks to
  the facade through a narrow interface.
- **Delete** the TS manager and its unit tests; keep shared wire types in
  `shared/`. `index.test.ts` end-to-end tests exercise the real harness
  (its `beforeAll` waits for `/api/routines` to answer 200).
- `jac test` waits 60s then fails on Postgres unless run with
  `TMPDIR=~/.cache/jac/tmp` (the shared daemon's socket dir).
- Validate: `jac check` + `jac test` on the pin (0.37.21), `tsc -p
  tsconfig.server.json`, affected vitest files, one live `jac run` smoke.
