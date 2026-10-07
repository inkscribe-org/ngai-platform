# Phase 0 spike findings — Jac runtime for the harness

Date: 2026-10-07. Branch: `jac/codebase-migration`. Toolchain: `jac` 0.37.21
(jacup install). Submodule: `third_party/jac` @ `7a9d76b17` (upstream `main`).
Spike code: `jac/spike/` (`jac.toml` + `spike.jac`, ~180 lines). Run:
`cd jac/spike && jac run --port 8799`.

## Verdict: GO for phases 1–5

Every phase-0 requirement passed on first exercise. Zero upstream defects hit —
the defect ledger in `2026-10-07-jac-migration.md` stays empty.

| Requirement | How proven | Result |
| --- | --- | --- |
| HTTP + SSE fanout to multiple clients | `def:pub stream(turn_id)` is an async generator; serving layer wraps it in `text/event-stream` automatically. Two concurrent `curl -N` subscribers on one turn both received every event | PASS |
| Spawn engine CLI, stream stdout to SSE topics | `asyncio.create_subprocess_exec("claude", "-p", prompt, "--output-format", "stream-json", "--verbose")`; `async for` over `proc.stdout`; lines published to per-turn `asyncio.Queue` fanout. A real `claude -p` turn (stream-json init/assistant/rate_limit events) was captured live | PASS |
| SQLite state across restarts | stdlib `sqlite3` via free `sv↔py` interop, `check_same_thread=False`. Two turns persisted; `jac run` restarted; `history()` returned both | PASS |
| Survive client disconnect mid-stream | Killed subscriber B mid-stream; subscriber A received all events to `event: end`; server health stayed green. Generator `finally` unsubscribes cleanly | PASS |
| OSP primitives under `jac run` | `node Marker` + `walker:pub mark` (`here ++> Marker(...)` + `[-->][?:Marker]` filter) — served as a REST endpoint, graph intact | PASS |

## Architecture answers the spike was meant to resolve

- **Server model**: `kind = "service"` in `jac.toml`; `def:pub`/`walker:pub`
  become `POST /function/<name>` and `POST /walker/<name>` endpoints.
  Generators/async generators are auto-wrapped as SSE (`event: end` trailer).
  Guest (unauthenticated) calls work — caller falls back to `GUEST`.
- **Concurrency model**: single asyncio event loop, same shape as node.
  `async def`/`async can`, `async for`, `asyncio.create_task` all work.
  `flow`/`wait` gives threads for blocking work.
- **Deployment**: `jac run` (dev), `jac build` → sealed `.jab`, or
  `jac build --as binary` → self-contained executable with the full runtime —
  this is the Electron-embedding path to evaluate in phase 4 packaging.
  `[apps.<name>] kind = "service"` gives multi-process fleets behind one port
  (`--fleet`) — directly usable for the migration's router-seam topology.
- **Persistence**: no built-in SQLite; Python stdlib interop is free
  (`sv↔py` boundary is a direct call, live objects, no marshalling).
  `store()` builtin exists for blob/file storage.
- **Packaging risk items for phase 0 checklist**: `.jab` bundle and
  `--as binary` exist but were not yet exercised for size/AV — deferred to
  the phase-4 packaging spike as the plan already schedules.

## Runtime facts worth remembering (now in AGENTS.md §5)

- Backtick-escape only real Jac keywords (`default`, `wait`, `spawn`); a
  backticked non-keyword is a hard error.
- `glob` is the only globals keyword; functions rebind module-level `glob`
  directly — no `global`/`nonlocal`. But the type checker infers a glob's
  type from its initializer: annotate `: any` (or the real type) when it
  starts `None`.
- `== None` warns; use `is None` / `is not None`.
- `list` in type position needs parameters (`list[any]`); bare `list` in a
  runtime expression is fine.
- Node-type filter syntax is `[-->][?:Type]` — no backticks.
- `with entry` is not async; `await` only inside `async def`/`async can`.

## Notes / watch items

- `jac run` auto-creates an `admin` user with a default password and mounts
  `/admin` observability routes — must be disabled or secured before this
  serves real traffic (phase 1 hardening item).
- Graph persistence for nodes/walkers is a separate subsystem
  (`[scale]` config); the spike used plain SQLite — phase 1 decides whether
  the OSP layer rides jac-scale persistence or the existing `message-db`
  schema.
- `.jac/` (compile cache, `data/jwt_secret`) and `*.db` are runtime
  artifacts; added to `.gitignore`.
