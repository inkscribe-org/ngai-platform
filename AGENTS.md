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
- `glob` is the only globals keyword — functions rebind a `glob` directly (no
  `global`/`nonlocal`). Annotate the glob's type (`: any`, `: int`) when the
  initializer is `None`, else the checker pins it to `NoneType`.
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
