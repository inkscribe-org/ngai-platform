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
- The jacup binary unpacks jaclang sources to `~/.cache/jac/rt/<hash>/site/`;
  patching those files patches the served runtime (cache dirs are
  regenerated — treat as scratch).
- `def init` compiles to the module's `__init__` (invisible to callers) —
  name it `init_<thing>` or re-export: `glob init: any = init;` after the def.
- `<base>.test.jac` annexes onto `<base>.jac` — the module is the merge of
  both, so a test file must NOT `import` its own base (self-import = the
  partially-initialized module). For cross-module tests, create a stub
  `<base>.jac` and keep `import` statements in the annex only.
