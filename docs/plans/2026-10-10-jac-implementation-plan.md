# Jac migration — detailed implementation plan (from 2026-10-10 onward)

Companion to `2026-10-07-jac-migration.md` (the "why" and the decision log).
This document is the "how, in what order, and when is it done". It is
written so that each workstream (§6–§13) can be handed to one engineer or
one agent as a self-contained brief: scope, target design, dependencies,
acceptance, and which tests port or die.

Inputs: the four inventories taken on 2026-10-10 (server/index.ts map, the
rest of server/, client + Electron + companion + enterprise, and the
jac-desktop platform research against the vendored jac source at
11d33c9ff), the profiling report (`2026-10-10-jac-profiling.md`), and CI
runs 3–4 of PR #1. Numbers below are from those, not estimates, unless
marked ~.

---

## 0. How to use this plan

- **Work in order of the phases (§4).** A workstream may start when every
  item in its *Depends on* line is done or explicitly waived.
- **Port to the end-state shape, never to the seam.** Since 2026-10-10 the
  shipped app is one Jac desktop binary (§2). The node↔Jac bridge
  (`jacOp`, `/api/internal/routine-bridge`, sync mirrors) is scaffolding:
  new work must not add bridge ops or mirrors except as a short-lived shim
  that a named later workstream deletes.
- **Every workstream ends by deleting the TS it replaced** (and its unit
  tests), keeping only `shared/` wire types still consumed by unported
  code. A workstream that leaves both implementations live is not done.
- **Heavy test runs happen in GitHub Actions, not locally** (the dev
  machine is RAM-constrained: 16 cores / 14 GB, shared). Locally: `jac
  check` on touched modules, `tsc`, lint, single vitest files. Push to the
  PR branch and read CI.
- **Upstream-first (AGENTS §3).** A jac/jaseci defect or missing capability
  becomes an upstream issue (or PR) before any workaround; record it in
  §14 and the migration plan's defect ledger.
- Status of each workstream is tracked in the table in §15; update it in
  the same PR that changes the status.

---

## 1. Ground truth snapshot (2026-10-10, branch `jac/codebase-migration` @ PR #1)

### 1.1 What is in Jac today

`jac/harness/` — 55,779 LOC including tests (`emoji_rgi.jac` alone is 3,830
generated lines). Runs as a sidecar (`jac run`, `kind = "service"`)
supervised by node; node answers every client request.

| Jac module(s) | Replaces | Status |
|---|---|---|
| db, messages, memory, sessions, checkpoints, lease, graph, store (`message_db.jac`) | message-db.ts, store.ts, sessions.ts, checkpoints.ts, memory file ops | **Dual implementation** — node is still the live writer for all of these (4,526 TS LOC); Jac serves conformance and Jac-side subsystems only |
| routines | RoutineManager | Live; TS deleted (`server/routines.ts` keeps wire types + `nextOccurrence`) |
| webhooks | WebhookManager | Live; ingress listener stays node |
| connectors | composio.ts, connector-verdict/-scope-hint | Live; `connector-proxy.ts` (stdio) + relay audit stay node |
| mcp_oauth | mcp-oauth*.ts | Live; MCP registry/gate/probe/http stay TS |
| workspace_backup, team_backup | workspace-backup.ts, team-backup.ts | Live; HTTP streaming + maintenance gate stay node |
| computer_control, team_computers, shared_computers, container_computer, local_computer | computer-control, team-/shared-computers, container I/O | Live; pure contract (`container-computer.ts`, `local-computer.ts`) duplicated in TS |
| drivers, driver_claude*, driver_codex*, driver_openai_chat* | claude.ts, codex.ts, openai-chat runtime | **Behind `OMB_JAC_DRIVERS` — TS drivers are still the default** |
| common | shared helpers (guard, bridge, atomic write, redact, …) | Live |

### 1.2 What is still TypeScript

| Area | Size | Notes |
|---|---|---|
| `server/index.ts` | 25,923 LOC; ~313 endpoints (~281 inline + ~32 in route modules); `handleRequest` alone 9,435 LOC | The monolith (map: §3) |
| other `server/` (non-test) | 336 files, 90,956 LOC — 74,020 TS-only, 14,437 partially ported, 2,499 Jac seams | §3.2 |
| of which deferred hosted tier + voice/phone | 11,542 LOC | boat, vps, cloud-*, lending, fleet, tunnel, tts, live calls |
| drivers without a Jac port | 15 of 18 kinds, ~15.4k LOC | acp/core + 10 ACP kinds, pi, antigravity, 4 openai-compat derivatives |
| stdio helper processes (node) | 14 files, 2,684 LOC | spawned by engines/drivers — **even the Jac claude driver spawns node helpers** |
| `src/` React client | 791 files, ~124k impl LOC, 353 test files | single 4,112-LOC store, no router, one SSE feed |
| `electron/` | 73 impl files, 18,816 LOC (+15.9k vendored updater) | ~94 IPC handlers; `window.ogb` used from 76 client files |
| `companion/` | ~4,000 LOC (+5.4k tests) | phone relay sidecar |
| `enterprise/` | 960 LOC | licence + hosted sign-in; imports core auth |
| `shared/` | 61 files, 6,205 LOC | wire contracts |
| server tests | 473 files, 144,540 LOC (101 e2e) | most die with their subsystem |

### 1.3 CI baseline (PR #1, run 4)

| Job | Status | Cause |
|---|---|---|
| typecheck + lint | pass | |
| jac harness warm compile | pass (cold compile 148 s on a GitHub runner) | |
| jac conformance | 1408/1409 Jac tests on run 3 (MCP cancel test race — fixed) | conformance steps not yet reached |
| behavior evals | 3 fail: `lazy-claim-rejection`, `lazy-claim-screenless`, `lazy-computer-claim` ("no computer mount in dump") | likely computers-port regression (WS-B3) |
| vitest (ubuntu) | ~95 e2e failures on 2 shards | e2e fixture servers start **without a jac binary** → "routines unavailable" 503 (WS-B1) |
| vitest (windows/mac) | not yet examined | no jac on those runners |
| renderer smoke | pass (run 4) | fixed by giving the job the warm harness (`.github/actions/jac-harness`) |
| packaged server smoke ×2, macOS smokes, package + smoke | fail by design | Electron bundle has no harness; retired with the Electron packaging (WS-F) |

Known pre-existing `index.test.ts` failures with TS drivers (AGENTS §9):
"reports a failed routine once, not twice", "stops a local bot's exact
channel and routine work through the emergency endpoint", "tells the
desktop whether to hold the computer awake for a routine due within the
hour"; "rejects overlapping provider configuration writes" is flaky. With
`OMB_JAC_DRIVERS=all`: 11 failures, 7 Jac-specific (WS-D1).

---

## 2. Target architecture (end state)

### 2.1 Shape

One Jac **workspace** in a new top-level `app/` directory (name TBD in
WS-A1), built by `jac build` into one native desktop binary per platform:

```
app/
  jac.toml                 # [apps.desktop] kind="desktop"; [apps.harness] kind="service" (or folded — WS-A1)
  core/                    # shared OSP model + pure logic (placement solved per app)
    model/                 # node/edge archetypes: Bot, Thread, Message, Room, Task, Routine, Computer, ...
    ...
  harness/                 # sv: walkers, def:pub endpoints, engines, scheduler, subprocesses
  ui/                      # cl: components (ported from src/), pages/, state
  desktop/                 # desktop app entry + [desktop] config
```

- **Runtime:** the desktop host boots the fused Jac runtime on an embedded
  CPython, runs one `JacAPIServer` on loopback (deterministic per-app port),
  colocates service apps under `/api/<app>`, and renders the `cl` bundle in
  the OS webview (WebKitGTK / WKWebView) or CEF.
- **No** node, Electron, sidecar supervision, bridge ops, sync mirrors or
  op queues. Calls are in-process walkers/functions; the UI calls them over
  loopback HTTP via the generated RPC stubs.
- **Server push:** one `async def:pub` returning an **async generator**
  (SSE) replaces `/api/events` (never a sync generator — it stalls the
  server loop; research R4). The `cl` side reads it with
  `fetch().body.getReader()` (RPC stubs buffer; EventSource is GET-only).
- **Persistence:** decided in WS-A2. Default assumption: keep our on-disk
  formats (bots.json/groups.json/config.json, `messages.db`, routines.json,
  webhooks.json, …) as plain files/sqlite under the app data dir, with the
  OSP graph used for in-memory relationships and derived state — because
  the Jac graph store is always the machine-wide embedded Postgres
  (downloaded on first run, POSIX-only; research §4/R2), which would make
  offline installs fail and changes every user's data format.
- **Engines:** engine CLIs (claude, codex, pi, ACP agents, …) are spawned
  from sv code exactly as today's Jac drivers do. The stdio helper
  processes engines need (permission proxy, MCP gate, agents MCP, hooks,
  connector proxy, computer bridges) must stop being node scripts (WS-D3).
- **Platforms:** jac-desktop supports **Linux and macOS (arm64) only** in
  code today; Windows and Intel macOS are blocked upstream (§14). The
  Electron app keeps shipping to Windows/Intel-mac users until that lands
  (WS-F4 bridge strategy).

### 2.2 OSP model (target)

Nodes: `Bot`, `Thread`, `Task`, `Room`, `Message`, `TurnEvent`, `Routine`,
`RoutineRun`, `Webhook`, `Computer` (+ control/lease records, already
graph-modelled in computer_control.jac), `McpServer`, `Connection`,
`Skill`, `MemoryEntry`, `Delegation`, `Card` (approval/question/proposal).

Edges: `Member` (bot↔room), `Owns` (bot→thread/task), `Next`
(message order), `Contains`, `AttachedTo` (bot↔computer), `Grants`
(connection↔bot, server↔bot), `Delegates` (thread→thread), `Schedules`
(routine→bot/room), `Answers` (card→message).

Walkers: `StartTurn` (unifies today's `startTurn` + `runGroupMemberTurn`,
§3.1 surprise #2), `FoldEvent` (the runtime-event fold), `ScheduleTick`,
`DeliverDelegation`, `AnswerCard`, `SweepRetention`.

Rule from AGENTS §4: use nodes/edges/walkers where the domain is
relational (rooms, delegation, grants, computers, turns); plain functions
for pure transforms (prompt building, parsing, redaction).

### 2.3 What disappears

`server/index.ts`, all `server/jac-*.ts` seams, `routineBridgeOps`,
`/api/internal/routine-bridge`, the sync mirrors, `jacOp`/`jacOpUnordered`/
`jacLongOp`, harness spawn/health/respawn, `electron/` (except the WS-F4
bridge release), the esbuild server bundle, `scripts/bundle-server.mjs`,
electron-builder packaging, the Electron-era CI smokes, and the node
stdio proxies.

---

## 3. Principles and conventions (apply to every workstream)

1. **Faithful port, then improve.** Behaviour parity first (on-disk bytes,
   error texts/status codes, event order), proven by ported tests; refactor
   only after parity is green. Known TS bugs found during the port are
   fixed in a separate commit, named in the PR.
2. **One writer per file/table at all times** (migration plan seam rule 1).
   When a workstream moves a writer from node to Jac (e.g. the store), it
   flips in one commit and deletes the node writer.
3. **Module layout:** one Jac module per subsystem in the target `app/`
   layout (§2.1); `common.jac` for shared helpers (do not re-copy guard,
   atomic write, redact, uuid, time — the 2026-10-10 review consolidated
   them).
4. **Test annexes:** `<module>.test.jac`, never importing its own base;
   helper names must not shadow base defs; a checker error in a test annex
   breaks `jac run`. Until upstream decides on test annexes at boot
   (profiling: 56 % of compile time), keep annexes lean.
5. **Errors:** `common.fail(status, msg)`; zod messages reproduced
   faithfully where the client displays them.
6. **Concurrency:** sv `def:pub`s run on an 8-thread pool; module state
   touched from more than one endpoint or thread is locked
   (`threading.RLock`) — see the review commit list for the pattern.
7. **No new bridge ops / mirrors** (§0). If a shim is unavoidable, it is
   annotated `# SHIM: removed by WS-xx` and listed in §15.
8. **CI is the test runner.** Every workstream PR must leave CI no worse
   than its base (compare failing-test sets, not counts).

---
## 4. Inventory reference (condensed; full reports are the 2026-10-10 inventories)

### 4.1 `server/index.ts` sections (line ranges at commit 361a7a5)

| Lines | Section | LOC | Target workstream |
|---|---|---|---|
| 649–870 | config/bootstrap, data-dir lease, restore, sessions, `cfg`, registry | 220 | C6, C1 |
| 872–1452 | identity + Cloud-home ownership/lending | 580 | G (deferred), C1 |
| 1453–1667 | bot visibility | 215 | C1 |
| 1668–1912 | admin audit, usage booking | 245 | C13 |
| 1913–2182 | provider auth, MCP OAuth, Electron parentPort channel, bus | 270 | C6, F1, C3 |
| 2183–2560 | internal capability tokens (per turn-generation bearers) | 380 | C12 |
| 2561–3069 | direct-turn dispatch claims, turn resources | 510 | C3 |
| 3070–3204 | browser runtime, per-turn integrations | 135 | C10, C3 |
| 3205–3340 | computer control glue | 135 | C11 |
| 3341–3773 | model selection, engines, packages | 430 | C6, C9 |
| 3774–3851 | store construction and boot | 80 | C2 |
| 3852–4592 | wire projections, approval modes, `handleDesktopTrustedApprovalMessage` (~400) | 740 | C2, C5, F1 |
| 4593–5468 | rooms/groups state | 875 | C3 |
| 5469–5857 | store→SSE bridge, message pages, SSE fan-out (`broadcast` 5808; 55 call sites) | 385 | C3 (event feed) |
| 5858–6112 | fold helpers, card answers | 255 | C3, C5 |
| 6113–6655 | watchdog, bus subscribers, engine hooks, digests | 545 | C3 |
| 6656–7537 | computers (≈40 % Boat/VPS) | 880 | C11, G |
| 7538–8279 | **the fold** (`handleRuntimeEvent`, awaits a Jac op per event) | 740 | C3 |
| 8280–8964 | delegation and handoffs | 685 | C4 |
| 8965–9400 | steer-queue drain, direct sends (`acceptDirectSend`) | 435 | C3 |
| 9401–9583 | live screen poller, titles | 180 | C11, C3 |
| 9584–11087 | **`startTurn`** (~1,500) | 1,500 | C3 |
| 11088–11656 | routine helpers + **Jac→node bridge ops** | 570 | C3 / deleted in H |
| 11657–12487 | boot recovery, card-proposal services, `deleteBotWithLifecycle` | 830 | C5, C2 |
| 12488–12509 | webhooks (ingress listener) | 22 | C14 |
| 12510–14414 | **group turn engine** (`runGroupMemberTurn` ~1,055, `startGroupTurn`) | 1,905 | C3 |
| 14415–15408 | calendar calls, cards and resumes | 995 | C5, G (calls) |
| 15409–15943 | settings surface (`configStatus`) | 535 | C6 |
| 15944–16199 | HTTP plumbing, static serving | 255 | C0 |
| 16200–25635 | **`handleRequest`** (9,435): public 11 · sessions 15 · internal 50 · public API ~202 | 9,435 | per route group, §4.2 |
| 25637–25923 | boot order, timers, shutdown | 287 | C0 |

### 4.2 Route groups → workstream

| Route prefix | ~Endpoints | WS |
|---|---|---|
| /api/auth/*, /api/pair, /api/settings/custom-domain, sessions | 26 | C1 |
| /api/internal/* (capability bearer, called by engine MCP proxies) | 50 | C12 |
| /api/bots (create/edit/delete/model/profile/soul/history/requests/messages/queue/compact/branch/respond/interrupt), projects/tasks | ~45 | C2, C3, C5 |
| /api/threads, /api/attachments, /api/files, /api/search | 11 | C2 |
| /api/groups | 13 | C3 |
| /api/events (SSE) | 1 | C3 |
| /api/routines, /api/routine-runs, /api/calendar-calls | 13 | C14, G |
| /api/webhooks | 5 | C14 |
| /api/teams, /api/team-library, /api/org-library, /api/bot-defaults, /api/sidebar-sections | 20 | C9, C2 |
| skills, skills-library | 11 | C7 |
| /api/team-memory, /api/section-context, bot memory routes | ~16 | C8 |
| /api/team-computers, /api/local-computer, bot computer, boxes/vps | ~24 | C11, G |
| /api/instances, /api/cli-*, /api/mcp/servers, /api/config | ~22 | C6 |
| /api/connectors, connector/secret cards | 11 | C5, C14 |
| usage, plan-usage, keys, decisions, admin-activity, activity, outbound | 10 | C13 |
| /api/tts, /api/live, /api/fleet, hosted | ~20 | G |
| health, brand, edition, browser-engine install, team-map | ~6 | C0, C10 |

### 4.3 Surprises to fix during the port (do not carry over)

1. A Jac round-trip on **every** runtime event: the fold awaits
   `routine_runtime_event` on the global serialized chain (index.ts:7609),
   including merged text deltas. → C3 makes the fold in-process.
2. Two parallel turn-dispatch implementations (`startTurn` 9584,
   `runGroupMemberTurn` 12659; ~2,550 LOC). → one `StartTurn` walker (C3).
3. Three card-answer paths (`respondToCard` 5988, `POST /api/bots/:id/respond`
   22882, `POST /api/threads/:id/respond` 22965). → one (C5).
4. Route duplication (`/api/bots/:id`, `/api/groups/:id` matched twice;
   public + authed `/api/health`, `/api/brand`). → one table (C0).
5. Hosted-tier code interleaved into core (`CLOUD_HOME` ×85, lending ×68,
   boat ×66, …). → explicit extension points (G).
6. `serveStatic` sanitizes paths with `path.replace(/\.\./g, "")` only
   (index.ts:15955) — audit for traversal now (WS-B5), replaced by the
   desktop host's static serving later.
7. Dead in production: `model-catalog/catalog.ts` + `presets.ts` (687 LOC,
   tests only), `computer-observation.ts` (81, bench only). → delete (WS-B4).
8. Docs overstate the openai-chat port: only `openai-compat` is registered
   in Jac, not cerebras/mistral/minimax/grok (AGENTS §7). → fix now (WS-B4).

---

## 5. Phases and dependency graph

```
Phase A  Spikes & decisions (gate everything)        A1 A2 A3 A4 A5 A6
            │
Phase B  Stabilize the branch (CI green on what exists)  B1..B6   (parallel with A)
            │
Phase C  Server core into Jac sv (index.ts decomposed)   C0..C14
            │            ╲
Phase D  Drivers + stdio helpers in Jac                  D1..D4  (D1 needs C3; D3 needs A3)
            │
Phase E  Client into Jac cl                              E0..E9  (needs C-feeds: C3 event feed, A4)
            │
Phase F  Desktop shell, companion, enterprise, release   F1..F6  (needs A1, upstream §14)
            │
Phase G  Hosted tier: re-scope or port                   G1..G3  (decision-gated)
            │
Phase H  Decommission node/Electron/seams; CI rewrite    H1..H4
```

Critical path: **A1 → C0 → C2 → C3 → E0/E1 → F2 → F4 → H**. Upstream items
(§14) gate F (tray, updater, deep links, single-instance, signing,
Windows) and A2 (Postgres). Everything in C except C0/C2/C3 can run in
parallel once C0 lands.

## 6. Phase A — spikes and decisions (gate the rest)

Each spike produces a short write-up in `docs/plans/spikes/` (create the
dir) with the evidence, and a decision recorded in §17. Spikes run in CI or
on a disposable machine/VM, not on the shared dev box.

### A1. Desktop app topology (the critical one)
- **Question:** in a workspace with `[apps.desktop] kind="desktop"` plus our
  harness as `[apps.harness] kind="service"`, does the *release* build
  (`jac build desktop`) boot with the harness colocated and precompiled,
  matching `jac run --dev desktop`? Upstream code suggests the release
  build seals `default-app` / first web-app / the desktop app, and only
  precompiles services when the sealed app `has_server` (desktop has
  `has_server=False`) — upstream #9946.
- **Try, in order:** (a) desktop + service, `default-app` = desktop;
  (b) `default-app = "harness"`; (c) a thin `web-app` backend app + service;
  (d) single-app: sv code directly in the desktop app.
- **Build a hello-world that exercises our real needs:** one `async def:pub`
  SSE async generator; one walker over a node graph; one sv endpoint that
  spawns a long-running subprocess and streams its stdout; a `cl` page that
  calls them; a module global survives across requests; a scheduled
  `@schedule` function fires.
- **Also record:** binary size, first-launch time (jab materialization +
  Postgres fetch), warm launch time, where data lands
  (`JAC_DATA_PATH`/app_data — upstream #9947), localStorage persistence
  across launches (token), behaviour with no network on first run.
- **Decision:** the workspace layout (§2.1) and the build invocation used
  by every later workstream. **Done when:** the hello-world release binary
  runs on Linux x86_64 and macOS arm64 from CI artifacts, and dev ≡ build
  behaviour is shown by one scripted check.

### A2. Persistence
- **Question:** what holds our state in the desktop app? The Jac graph
  store is always the machine-wide embedded Postgres (downloaded from Maven
  Central on first run; POSIX only; shared with any developer `jac`
  install) — upstream #9944.
- **Options:** (1) keep files + sqlite (today's formats) as the source of
  truth, graph in memory only; (2) graph-persisted with Postgres bundled via
  `JAC_PG_DIST` from the app; (3) hybrid — durable domain records in
  files/sqlite, ephemeral relationships in the graph.
- **Recommendation:** (1)/(3) until #9944 lands, because it keeps every
  existing user's data and backups (`.ombbackup`) valid with no migration,
  works offline, and matches what M1–M4 already ported byte-for-byte.
- **Done when:** decision recorded; if (2), a measured offline-install test.

### A3. Child processes from the desktop binary
- **Question:** engines spawn helper processes by *command line* (MCP
  servers in `--mcp-config`, Claude hooks, the permission proxy). Today
  they are `node <script>.ts`. In a node-less app, what command do we give
  the engine? Candidates: (a) the desktop binary itself with a subcommand
  (`<app> --proxy permission <args>`) — needs host support for an alternate
  entry; (b) Python scripts run by the embedded interpreter — needs a
  Python executable path inside the bundle; (c) a separately built small
  `jac build --native` helper binary per proxy; (d) in-process MCP over a
  local socket where the engine supports URL MCP servers (HTTP/SSE MCP).
- **Also:** child-process lifetime when the window closes (host calls
  `Py_Finalize`; nothing reaps children — research §5), SIGCHLD/killpg
  behaviour on a non-main-thread loop, process-group spawn on macOS.
- **Done when:** one proxy (the permission proxy) runs from a release
  binary without node, round-trips a permission ask, and dies with the app.

### A4. Event feed prototype
- `async def:pub events(since: str)` returning an async generator fed by an
  `asyncio.Queue` (`loop.call_soon_threadsafe` from worker threads); replay
  buffer + cursor semantics of today's `/api/events` (`hello`, `ping`,
  `since=<stream>:<seq>`, 500-frame replay); `cl` reader with reconnect,
  40 s stale detection (port of `src/lib/live-events.ts`).
- Measure: 1,000 frames/s fan-out to 3 clients without stalling other
  endpoints (profiling: Claude peaks ~60 deltas/s).
- Check the client endpoint cache (research R6: 60 s LRU for "reader"
  endpoints) does not cache status reads — declare `effects` where needed.
- **Done when:** prototype + numbers; becomes the C3 event-feed design.

### A5. Compile cost
- Test annexes are 56 % of cold compile (profiling); a `.test.jac` edit
  invalidates its base module. Ask upstream whether serve/build should skip
  annexes (file it if A1 confirms the sealed image still references them).
- Measure the release build's compile on CI and wire caching like the
  current `jac-warm` job.
- Delete `emoji_rgi.jac` generation from the compiled set if it can be
  data (3,830 generated lines) — load a JSON table at runtime instead.

### A6. Platform policy (decided by product; recorded here)
- jac-desktop builds/runs only on Linux and macOS arm64 (upstream main,
  2026-10-10); Windows and Intel macOS need upstream #9943.
- **Working assumption:** retire Electron per platform. Linux + Apple
  Silicon move to the Jac app first; Windows and Intel macOS stay on the
  Electron app (frozen except security fixes) until #9943 lands. The
  Electron app keeps talking to the same on-disk data format (A2 option 1),
  so a later switch is a binary swap.

---

## 7. Phase B — stabilize the branch (parallel with A)

### B1. e2e fixture environment (≈95 CI failures)
- One helper (`server/testing/fixture-env.ts`) that every spawned fixture
  server uses: `OMB_JAC_BIN` from `operatorJacEnv`, `XDG_CACHE_HOME`,
  `TMPDIR` for the shared Postgres socket, `OMB_JAC_DRIVERS` passthrough.
  Replace the ad-hoc env objects in `server/*.e2e.test.ts` and
  `scripts/control-omb.ts` (`verificationServerEnvironment`).
- Decide whether bot deletion should hard-fail when the harness is down
  (`DELETE /api/bots/:id` → 503 today because routines disable runs first).
- **Done when:** ubuntu vitest shards have no "routines unavailable"
  failures; remaining failures listed with causes.

### B2. Windows/macOS CI shards
- They have no jac. Until Windows has a Jac app (A6), mark harness-needing
  e2e tests `skipIf(!jacAvailable())` on those runners, with a counter in
  the CI summary so the skipped set stays visible.

### B3. Computer-claim regressions
- Behavior evals `lazy-claim-rejection`, `lazy-claim-screenless`,
  `lazy-computer-claim` fail with "no computer mount in dump" since the
  computers port. Reproduce in CI, fix in `computer_control.jac` /
  `jac-computers.ts`.
- Plus the computers agent's room race: a late `turn.completed` releases
  the *current* speaker's resources (`handleRuntimeEvent` room branch) —
  fix to release only the owner whose turn completed.

### B4. Truth in docs and dead code
- AGENTS.md §7: openai-compat derivatives are **not** registered in Jac;
  fix the text.
- Delete dead code: `server/model-catalog/catalog.ts`, `presets.ts` (+
  their tests; keep `trim.ts`), `server/computer-observation.ts` (+ bench).
- Reconcile the restored TS CUA descriptor reader (`server/local-computer.ts`)
  with the end state: it is deleted in F when the packaged smoke moves to
  the Jac app; until then note the duplication in §15.

### B5. Static file serving audit
- `serveStatic` strips `..` with a regex only (index.ts:15955). Write a
  test with encoded/overlapping traversal sequences; fix by resolving and
  checking the prefix. (Replaced by the desktop host later, but node still
  ships to Windows users per A6.)

### B6. Pre-existing routine failures
- The 3 routine `index.test.ts` failures that predate the webhooks port;
  root-cause each now that the test harness boots Jac.

---
## 8. Phase C — server core into Jac sv

Common to every C workstream:
- Target is the `app/` workspace from A1, sv placement. Endpoints are
  `def:pub` / `walker:pub` with the **same JSON shapes** as today's routes
  (the client keeps working against them until E replaces it; a thin
  path-compat layer maps `/api/...` to the new endpoints during the overlap,
  see C0).
- While node still serves (before H), a ported route is removed from
  `handleRequest` and served by Jac through C0's router — **not** by adding
  a bridge op.
- Tests: port the TS unit tests' invariants to `.test.jac`; e2e coverage
  stays in `index.test.ts` / `*.e2e.test.ts` (pointed at the Jac routes) until
  E/H retire them.

### C0. Router and request plumbing (first; unblocks all of C)
- **Scope:** `handleRequest` skeleton (16200–16460: hosted gate, public
  routes, auth gate, visibility, audit hook, maintenance counter,
  `dispatchRoutes`), `routes/table.ts`, `harness/http.ts`, `serveStatic`,
  `/api/health`, `/api/brand`, `/api/edition`, boot order (25637–25923),
  graceful shutdown.
- **Design:** during the overlap, node becomes a reverse proxy for a
  growing set of path prefixes owned by Jac (one table: prefix → owner).
  This replaces the "Jac sidecar called through jacOp" model: the client's
  request goes to Jac directly; node only forwards. One table in one file;
  each later workstream flips its prefixes. After E, the desktop host
  serves everything and node is gone.
- Auth in Jac must reproduce `RequestAuth` (C1) before any non-public
  prefix flips.
- **Done when:** proxy table exists with `/api/health` + `/api/brand` owned
  by Jac; boot order documented in Jac; route duplication (§4.3 #4) gone.

### C1. Auth, sessions, visibility
- **Scope (TS):** request-auth.ts 556, sessions.ts 641 (Jac copy exists),
  bot-visibility.ts 489, decision-log.ts 341, auto-approve.ts 203,
  command-allowlist.ts 154, environment.ts 142, external-runtime.ts 77,
  account-signin.ts 116 (hosted-ish); index.ts sections D (visibility),
  G (capability tokens → C12), session routes (16463–16660, 26 endpoints).
- **Design:** `auth.jac` produces the same `RequestAuth` union (loopback
  owner / service; session via bearer|cookie|stream-ticket; scopes
  admin|client), member visibility (`visibleTo`, `memberFrame`), pairing
  codes, email sign-in. On the desktop the loopback owner is the default
  principal; paired phones/devices arrive through the companion (F3).
  Jac's own `__guest__`/user model is not used for our principals (it
  would put identity in Postgres — A2); our session store stays a file.
- **Note:** the `/__jac/` desktop broker's SSO targets a remote Jac server
  with scale SSO (research §6) — not our model; ignore for now.
- **Done when:** all 26 session/auth endpoints served by Jac with the TS
  tests' invariants ported (request-auth, sessions, bot-visibility,
  decision-log, auto-approve, command-allowlist tests).

### C2. Store, bots, threads, tasks, messages — single writer flip
- **Scope (TS):** store.ts 2,951, message-db.ts 892, attachments.ts 724,
  message-file.ts 475, checkpoints.ts 670, bot-folder.ts 102,
  thread-starters.ts 84, profile-*.ts, bot-profile.ts, new-bot-defaults.ts,
  bot-overview.ts, thread-events.ts, thread-title.ts, message-search*.ts
  (worker thread), commands.ts; index.ts sections L, M (wire projections),
  O (message pages), routes: /api/bots (create/edit/delete/model/profile/
  soul/history/projects/tasks), /api/threads, /api/attachments,
  /api/files, /api/search, /api/sidebar-sections, /api/bot-defaults.
- **Key step:** flip the writer. Jac already has `store.jac`, `messages.jac`,
  `db.jac`, `checkpoints.jac` byte-faithful (conformance-proven). Flip:
  Jac becomes the only writer of bots.json/groups.json/messages.db/
  checkpoints; node's `Store` becomes a read-only client over C0's proxy
  for whatever node code remains, then disappears.
- **OSP:** `Bot`, `Thread`, `Task`, `Message` nodes as the in-memory model
  hydrated from the files (graph.jac already hydrates threads); `Owns`,
  `Next`, `Contains` edges. Store change events become event-feed frames
  (C3) instead of `store.onChange → broadcast`.
- **Done when:** node no longer writes any of these files; store/message-db
  TS deleted; conformance corpora still byte-identical; `store.test.ts`
  (2,532 LOC) invariants ported.

### C3. Turn pipeline, rooms, event feed (the heart)
- **Scope (TS):** index.ts sections H (dispatch claims/resources), N (rooms
  state), P (SSE fan-out), Q–S (fold helpers, watchdog, subscribers,
  digests), U (**fold**), W (steer/aside/direct sends), Y (**startTurn**),
  AE (**group turn engine**), boot recovery of queues; server/:
  contracts.ts 591, harness/bus.ts, aside-queue, delta-context, steer-queue,
  channel-queue, admission, turn-dispatch-guard, system-prompt,
  turn-continuation, digest, turn-images, turn-resources, notify,
  turn-context, turn-watchdog, context-rebuild, send-idempotency,
  compaction-summary, sse-fanout, guarded-requests, repeat-detector,
  replies, context-budget, turn-log, automatic-recovery, room-*.ts,
  decider/*, group-goal-run, member-turn, section-context, recent-work,
  activity; routes /api/groups (13), /api/events, bot messages/queue/
  compact/branch/interrupt.
- **Design:**
  - **One `StartTurn` walker** for direct and room turns (§4.3 #2), with an
    integration-builder per surface (agents, hooks, connected apps,
    computers, browser, control) — no duplicated dispatch.
  - **In-process fold:** drivers (already Jac) call `emit_event` →
    `FoldEvent` walker directly (no bridge, no per-event Jac op from node —
    §4.3 #1). Routine run updates are a direct call into routines.jac.
  - **Event feed:** A4's async-generator SSE replaces `broadcast`; frames
    keep today's `ServerFrame` union (`shared/wire.ts:751`) so the React
    client works unchanged during the overlap.
  - **Rooms:** `Room` node, `Member` edges, the routing decider
    (decider/*) as plain functions; room handoff timer as a scheduled task.
  - Driver ops lose their node shim: `jac-drivers.ts` is deleted once the
    registry (C6) and fold live in Jac.
- **Size:** largest workstream (~10k index.ts LOC + ~4.4k server LOC +
  rooms/decider ~2k). Split into PRs: (1) event feed + fold, (2) direct
  turns, (3) rooms/group turns, (4) queues/steer/aside, (5) watchdog,
  digests, recovery.
- **Depends on:** A1, A4, C0, C2, D-registry part of C6.
- **Done when:** golden replay passes with Jac as the only turn pipeline;
  `index.test.ts` turn/room cases pass against Jac; Jac-driver suite no
  longer has the 7 Jac-specific failures (they are pipeline-ordering issues
  that disappear or get fixed here — re-check each).

### C4. Delegation, handoffs, peers
- **Scope:** delegations.ts 1,107, peer-roster.ts 441, room-handoffs.ts 433,
  peer-approval.ts 295, comms-visibility 158, incidents 149,
  chief-of-staff 69, peer-delivery/-provenance/-approval-key; index.ts
  section V (8280–8964); internal routes ask-bot, delegate-bot,
  coordinate-bots, post-to-room, room-targets, delegations/:id,
  retry-thread.
- **OSP:** `Delegation` node + `Delegates` edges thread→thread; delivery as
  a walker; incidents as nodes the Chief's walker reads.
- **Depends on:** C3. **Done when:** delegation e2e (delta-context,
  room-recovery, post-to-room, trust-controls) pass on Jac.

### C5. Cards, requests, approvals
- **Scope:** routine-requests.ts 1,539, profile-requests 447,
  model-requests 326, team-setup-requests 401, outbound-requests/-counts,
  options-card, credential cards, connector cards, skill request cards,
  approval modes (index.ts 4057–4547 incl. the trusted-approval handler),
  the three card-answer paths (§4.3 #3), phone secret submissions (F3).
- **Design:** one `Card` node type with kinds; one `AnswerCard` walker.
  The trusted-approval bridge (desktop-only "full/custom" mode set via
  native IPC) needs a desktop-side equivalent: a plugin-gated call or a
  user-gesture token issued by the host (F1).
- **Depends on:** C3 (cards live in turns). **Done when:** all card kinds
  answered through one path; routine-requests tests (2,027 LOC) ported.

### C6. Config, settings, engines/instances, MCP registry
- **Scope:** config.ts 1,842 (63 importers — port last within C6, keep a
  Jac `config.jac` reading/writing the same config.json), harness/registry.ts
  318, engine-install, provider-auth-sessions, provider-key-check,
  claude-accounts, claude-update, default-model-selection, plan-usage 907,
  harness-capabilities, key-rejections, mcp-registry 424, mcp-probe,
  mcp-http, mcp-trim, mcp-tool-schema, mcp-tool-images, brand.ts; index.ts
  AH (settings surface, `configStatus`), F (provider auth); routes
  /api/config (PUT ~545 LOC), /api/instances, /api/cli-*, /api/mcp/servers,
  /api/keys/test.
- **Note:** the provider **registry** moves here (driver instances become
  Jac-native, removing `jacifyDrivers` and the TS driver shells' declarative
  half for ported kinds: catalog, metadata, decodeConfig, auth/login flows).
- **Depends on:** C0, C1. **Done when:** config.json written only by Jac;
  `config.test.ts` invariants ported; settings routes on Jac.

### C7. Skills
- skills.ts 1,513, skill-library 399, skill-fetch 268,
  skills-library-migration 251, skill-learn 84; routes skills,
  skills-library, skill-template, internal skills/stage. `Skill` node +
  `Has` edges. Depends on C2.

### C8. Memory
- workspace.ts 713 (partially ported), memory-upkeep 526, memory-journal
  503, memory-store 397 (partial), team-memory 254, routes/bot-memory 235,
  memory-capture 220, recall 194, memory-topics/-entries (partial),
  memory-tidy, profile-learned, memory-organize, recall-disclosure; routes
  /api/team-memory, /api/section-context, bot memory. Scheduled upkeep →
  `@schedule`. Depends on C2, C3 (capture subscribes to turns).

### C9. Packages, presets, org library, teams
- org-library 1,173, package-export 896, presets 612, package-import 596,
  project-scout 371, team-manifest 326, managed-desktop 265, enterprise.ts
  247 (hook point), team-library 241, bot-directory, managed-policy,
  bot-package, package-parts, published-teams, installed-playbooks; routes
  /api/teams, /api/team-library, /api/org-library, /api/bot-presets.
  Depends on C2, C6.

### C10. Browser
- browser-engine 608, browser-live 587, browser-runtime 553,
  browser-lifecycle-cleanup 394, browser-tool-shape, browser-engine-release,
  browser-bundle-release; routes /api/bots/:id/browser/{live,action},
  /api/browser-engine/install, internal browser/mcp. The agent-browser
  sidecar is spawned by sv (no change); its bundling/signing is F/#9958.
  Depends on C3.

### C11. Computers (remainder)
- surface.ts, routes/desktop-viewer (RFB/WebSocket upgrade — **note:** no
  WebSocket in the embedded backend, upstream #9948; noVNC needs a
  websocket → keep a raw-socket listener in sv or wait), local-vm-*
  (seat pool, inventory, lease, idle, stop reason), auto-vm-claims,
  computer-selection, screen-frame-*, private-screen-capture,
  local-routing, desktop-viewer-targets, control-client,
  computer-engine-removal, computer-wait; index.ts T (non-Boat/VPS half),
  X (screen poller); routes /api/local-computer, /api/team-computers,
  bot local-computer, internal computer/*. Also B3's fixes.
  Depends on C3.

### C12. Internal capability API (engine-facing)
- index.ts G (capability tokens) + the 50 `/api/internal/*` endpoints.
  These are what the stdio proxies (D3) call. Keep the HTTP surface (the
  proxies are separate processes) but serve it from Jac; tokens are minted
  per turn generation in `StartTurn` (C3).
- Depends on C3; pairs with D3.

### C13. Usage, spend, audit, logs
- usage-ledger 355, spend 197, model-prices 164, prices 38,
  group-thread-usage 94, admin-activity 480, decision-log (C1),
  thread-log-rotation 98, thread-retention 64; index.ts E; routes usage,
  plan-usage, decisions(.csv), admin-activity(.csv), activity, outbound.
  Retention/rotation timers → `@schedule`. Depends on C2, C3.

### C14. Routines/webhooks finish
- Already in Jac; remove their node seams: `jac-routines.ts` mirror and
  facade, `jac-webhooks.ts`, `webhook-ingress.ts` (the webhook listener
  becomes an sv listener on `WEBHOOK_PORT` — a raw `asyncio` HTTP server
  in sv, since the embedded backend has no webhook extension, #9948),
  `routine-requests.ts` (→ C5), calendar calls (G or here if kept),
  routes /api/routines, /api/routine-runs, /api/webhooks.
- Depends on C0, C3.

---
## 9. Phase D — drivers and engine helper processes

### D1. Make Jac drivers the only drivers for ported kinds
- Kinds: `claudeAgent`, `codex`, `openai-compat`. Gate today:
  `OMB_JAC_DRIVERS`; 7 Jac-specific `index.test.ts` failures remain
  (steering a paired person's message, room Local VM refusal, goal-run
  park race, failed credential-card continuation, two Boat key/journal
  cases, pinned-computer dispatch).
- After C3 (the fold and dispatch are in Jac), re-run; fix what remains;
  delete the TS adapters (`claude.ts` turn path, `codex.ts`,
  `openai-chat.ts` runtime) and their tests; declarative parts move to C6.
- **Done when:** golden replay + `index.test.ts` driver cases pass with no
  TS adapter for these kinds.

### D2. Remaining 15 kinds
| Kind(s) | TS | Approach |
|---|---|---|
| grok (xAI API), minimax, mistral, cerebras | 65–136 LOC each, on the openai-chat runtime | `_<kind>_options` + `chat_runtime_impl` registration in `driver_openai_chat.jac` — small |
| ACP family: acp/core 2,340 + grokAgent, opencodeGo, kimiAgent, hermesAgent, cursorAgent, droidAgent, qwenAgent, geminiAgent, customAcp | ~3.5k kinds + core | port `acp/core` once as `driver_acp.jac` (JSON-RPC over stdio, like codex's app-server reader), then each kind is config; fake: `server/testing/fake-acp-cli.ts` |
| antigravityAgent | 1,927 (on acp/core) | after ACP core |
| piAgent | pi.ts 1,406 + pi-mcp-extension 705 | the extension runs *inside* the pi CLI (TS, loaded via `-e`) — it stays TS as an asset shipped with the app, spawned by pi, not by us; port the driver only |
- Priority by usage (plan "Decided scope": claude, codex, openai-chat, pi,
  grok first). Each kind ends with its TS driver deleted and its
  `*.test.ts` invariants ported against the existing fake CLI.

### D3. Engine helper processes without node (depends on A3)
| Helper (TS) | LOC | Spawned by | Plan |
|---|---|---|---|
| permission-proxy.ts | 258 | claude (TS + Jac) | A3 mechanism; MCP stdio server forwarding to the in-app broker |
| mcp-gate.ts | 323 | every driver via mcp-gate-config | same mechanism; wraps a bot's MCP servers |
| drivers/dweb-proxy.ts | 196 | claude, pi | same |
| hooks/omb-hook.ts | 98 | Claude Code hooks | script/command for hooks |
| drivers/agents-proxy.ts (+ agents-call 1,287, agents-catalog 990, agents-client, agents-result) | ~2.4k | index (agents MCP) | the agents MCP server; calls C12 |
| harness-mcp-proxy.ts | 132 | browser + cloud computer tools | same |
| connector-proxy.ts | 264 | connectors | same |
| container-mcp.ts, local-computer-proxy.ts, mcp-remote-proxy.ts | 152 | computers, MCP | same |
| mcp-bridge.ts (shared stdio bridge) | 373 | all of the above | becomes the shared Jac MCP-stdio module |
| message-search.worker.ts | 20 | worker thread | a Python thread |
| drivers/phone-proxy.ts, vps-container-mcp.ts | 444 | phone, VPS | G (deferred) |
- Where an engine supports URL (HTTP/SSE) MCP servers, prefer serving the
  MCP endpoint in-process over loopback instead of a stdio child.

### D4. Shared driver infrastructure
- local-inject 422 (13 importers), device-auth 369, prompt-split, retry,
  session-idle, procs.ts 236 (process spawning — already reimplemented in
  driver_claude.jac; consolidate into `common` or a `procs.jac`),
  env-path.ts 395 (PATH augmentation; partly duplicated in
  container_computer.jac), redact.ts (consolidated in common.jac),
  tool-summary.ts. Port as the D2 kinds need them; delete duplicates.

---

## 10. Phase E — client into Jac `cl`

### E0. Foundations (depends on A1, A4)
- `cl` project inside `app/` (`ui/`), npm deps in `jac.toml`
  (`[dependencies.npm]`): react-markdown, remark-gfm/math, rehype-katex,
  katex, shiki, mermaid, @tanstack/react-virtual, @novnc/novnc,
  lucide-react, qrcode.react, papaparse, posthog-js, clsx, tailwind-merge,
  zod (wire), yaml. Tailwind v4 via `[client.vite] plugins`.
- **i18n:** no built-in facility; port `src/lib/i18n.ts` (84 LOC, hand
  written) as-is + the 11 catalogs and `generate-locale.mjs --check`.
- **Wire:** keep the `ServerFrame` union and route shapes; generate Jac
  `obj` types for the wire from `shared/wire.ts` (or hand-port; 778 LOC).
- **Live events:** port `src/lib/live-events.ts` (395) onto the A4 reader.
- **api():** replace the `fetch` wrapper (~300 call sites) with typed RPC
  stubs as each endpoint lands in Jac; keep a raw-fetch shim meanwhile.
- **Testing:** no DOM test harness for `cl` upstream (bun runs logic
  tests). Keep logic tests as `cl` tests; keep the existing
  `scripts/testing/*-ui.e2e.test.ts` (Playwright-style, drive the loopback
  origin — research §8) as the UI regression suite against the Jac app.
- **Watch:** the client endpoint cache (60 s for "reader" endpoints) —
  declare `effects` on status reads; a 401 from our own endpoints clears
  the token and reloads the window (research R10) — design auth errors
  accordingly.

### E1. State store (critical)
- `src/state/store.tsx` (4,112 LOC; `useReducer` + `AppState` + a big
  `Action` union + `handleFrame` + `loadAll` + `api()`), `bot-patch-queue.ts`
  (301). Port as a `cl` module with the same reducer semantics; `has`
  fields map to `useState`, but a reducer this size should stay a reducer
  (`useReducer` via npm React interop) — do not explode it into hooks.
- Contexts: DesktopCapabilities, ThreadRefs, BotEditorContext, ChatView-
  local, ChatMarkdown. localStorage prefs modules (`lib/*-preferences.ts`,
  drafts, skins, fonts, language, feature flags) port unchanged.

### E2–E9. Feature areas (order chosen so each lands usable)
| # | Area | Files / LOC | Notes |
|---|---|---|---|
| E2 | App shell, sidebar, routing-by-state, onboarding gate | App.tsx 422, Sidebar 2,898 + 13, main.tsx, lazy-screens | no router — keep the state-driven view switch; pages/ routing optional later |
| E3 | Chat / transcript / composer | 58 files, 13,493 | ChatView 1,778, Composer 1,272, ChatMarkdown 1,037, attachments 902+901, cards |
| E4 | Bots / bot settings | 52 files, 10,369 | bot-settings/* 36 files, ModelPicker 1,309 |
| E5 | Rooms / groups / teams | 15 files, 4,413 | GroupView 1,472, TeamMap, TeamCanvas |
| E6 | Settings / engines / usage / MCP & plugins / connectors | 39 + 9 files, ~10.4k | SettingsModal 1,243, PluginsPanel 1,102, McpServersPanel 1,014 |
| E7 | Computers (local VM, CUA, viewer, browser panel, Android) | 36 files, 10,716 | noVNC needs a WebSocket → C11 note; desktop viewer window → #9954 |
| E8 | Routines, webhooks, activity/inspector, backups, org library | ~32 files, ~7.4k | RoutineCalendarPage 2,112 |
| E9 | Onboarding/tours, pairing pages, phone setup, cloud/remote | ~54 files, ~10k | phone/cloud parts gated by G/F3 |
- Voice/live calls/TTS UI (15 files, 3,894) follows G.
- Each area: port components, port their tests (logic → cl tests; DOM →
  UI e2e), delete the `src/` originals when the area ships in the Jac app.

### E10. `window.ogb` replacement map
- 76 files / ~45 preload methods. Each method gets one destination:
  `@jac/desktop` plugin (fs, dialog, clipboard, notification, app_window,
  shell, path), an sv endpoint (most: environments, companion, routines
  wake, localControl, androidDevice, computerSharing, cloudAccount, org,
  backups), a `cl`-only replacement, or an upstream-blocked item (§14).
  Build the table in E0 from `src/types/ogb.d.ts` (405 LOC) and keep it in
  this plan's appendix.

---
## 11. Phase F — desktop shell, companion, enterprise, release

### F1. Desktop app and capability map (depends on A1)
Electron capability → jac-desktop destination (from the 2026-10-10
inventory; upstream issue numbers in §14):

| Capability (Electron today) | Destination |
|---|---|
| main window title/size/fullscreen/quit | `app_window` plugin |
| frameless chrome, min/max/restore, maximize events, bounds restore, caption colours | upstream #9951; meanwhile native chrome |
| splash while server boots | gone (in-process) — `cl` loading state |
| secondary windows (noVNC viewer), embedded WebContentsViews | upstream #9954; meanwhile in-page panels |
| external links / window.open policy | #9954; sv `webbrowser.open` |
| reveal in folder, open OS settings panes | sv subprocess (`open -R`, `xdg-open`) |
| app menu, context menu | upstream #9950; move actions into the UI |
| tray (Windows only today) + lending indicator | upstream #9936 |
| dock/taskbar badge | upstream #9952 |
| auto-update (+ legacy updater mirror) | upstream #9937 + F4 bridge release |
| deep links `openmausbot://` | upstream #9938 |
| single instance + argv forwarding | upstream #9940 |
| autostart | not used today (#9939 for later) |
| relaunch | with #9937 |
| notifications (+ click → thread) | `notification` plugin (click callback: #9955) |
| save/open dialogs, message box | `dialog` plugin; folder picker + multi-button: #9953 |
| clipboard text | `clipboard` plugin; image/file paste: webview |
| dropped-file real paths | #9956; meanwhile upload bytes |
| OS keychain (safeStorage `credentials.bin`) | sv `keyring` (#9957 for a plugin); **migration of existing blobs only Electron can decrypt → F4** |
| power-save blocking, battery check | sv (`caffeinate`, `systemd-inhibit`, ctypes; `psutil`) |
| server spawn/supervision/boot probe | gone |
| data-dir lease | sv (lease.jac) — still needed vs CLI/headless instances |
| per-launch owner auth header | gone — loopback principal (C1) |
| remote environments (window loads a remote server's UI) | needs design: `[desktop] backend` URL or a `cl` server switch; spike in F1 |
| CUA helpers, Linux CUA runtime, macOS speech helper, adb, shared terminal, cloudflared, companion | sv subprocesses; bundling + signing: #9958, #9941 |
| screen capture (`desktopCapturer`, getDisplayMedia), mic (`getUserMedia`) | upstream #9955; fallback CUA/OS screenshot in sv |
| Chromium permission policy, downloads | #9955 |
| GPU workaround | CEF env flag / n.a. for native |
| crash log, diagnostics export | sv logging + `dialog.save_file` |
| telemetry (posthog) | npm dep in `cl` |
| trusted approval bridge (native-only mode switch) | redesign: host-issued user-gesture token or plugin-gated call (#9945 would allow a custom plugin) |
| cloud account, org enrollment, company backups, cloud move, lending, org library relay | sv (C9/G); secrets → keyring |

- Enable plugins explicitly: in code every built-in plugin defaults **off**
  (docs say on — #9949).
- Set `JAC_DATA_PATH` to the platform data dir (Linux default is beside the
  binary — #9947) and keep `~/.openmausbot` semantics for our own files.

### F2. Package the Jac app (Linux + macOS arm64)
- Build in CI from the A1 layout; artifacts per platform. Until #9941:
  Linux tarball/AppImage built by our own script; macOS `.app` signed and
  notarized by our existing release workflow steps applied to the Jac
  bundle (codesign/notarytool/staple) — validate that the grafted runtime
  and webview library sign cleanly.
- Python deps must be vendored into the bundle (the launcher's relative
  `.jac/venv` path breaks relocation — #9947).
- New CI: build + smoke the Jac app (launch, `/api/health`, one scripted
  turn with a fake engine via `JAC_DESKTOP_SERVING` loopback origin);
  replaces packaged-server smoke, macOS smokes, package + smoke for these
  platforms.

### F3. Companion (phone relay)
- `companion/` (~4k LOC): port to sv as an in-process listener (its own
  port, route allowlist, device tokens, HPKE relay, mDNS). The managed
  route (cloudflared + guardian + gateway on :8812) becomes sv
  subprocesses. phone-secret.ts 464, cli-phone-setup.ts with it.
- Depends on C1 (devices/sessions), C12.

### F4. Bridge release and data/secret migration
- Installed Electron builds can only auto-update to an Electron build. Ship
  one final Electron release per platform that, on next launch:
  1. decrypts `credentials.bin` (safeStorage — only Electron can) and
     re-stores the secrets in the OS keychain the Jac app reads;
  2. downloads + verifies the Jac app, installs it, migrates the
     single-instance/deep-link registration, and launches it;
  3. leaves the data dir untouched (same formats — A2).
- Windows / Intel macOS: per A6, not until #9943; those users keep the
  Electron app.
- Legacy updater mirror (`openmausbot-releases` for builds ≤ 0.1.46)
  carries the bridge release too.

### F5. Enterprise
- `enterprise/` (960 LOC): licence verification (Ed25519) and hosted
  workspace sign-in; ports with C1 (it imports request-auth, sessions,
  hosted-contract). Keep the `OMB_ENTERPRISE_DIR` hook semantics as a Jac
  module that is absent in the open-source edition.

### F6. CLI and service mode
- `cli.ts` 1,288, cli-setup, cli-prompts, cli-api-setup, service-unit,
  service-cli, openmausbot.ts entry: the headless `openmausbot` command
  (server without the window, systemd/launchd unit). Becomes a Jac CLI
  entry that runs the same workspace headless (`jac run` service mode) —
  the Docker/self-hosted image uses it.

---

## 12. Phase G — hosted tier (decision-gated)

- 11,542 LOC deferred (boat, vps, cloud-home/owner/lending/move, fleet,
  tunnel, caddy, custom-domain, tailscale, voice/live calls/TTS, phone
  proxy) and interleaved into core (§4.3 #5).
- **G1 (now, cheap):** carve explicit extension points where core calls
  into hosted code (`startTurn` surface mounts, `CLOUD_HOME` branches,
  `create_task` bridge op, `included-services.ts` used by decider/tts,
  `cloud-home.ts` imported by codex and opencode-go). Without these, C3
  cannot drop the hosted branches cleanly.
- **G2 (decision):** for each hosted feature: port, keep on a separate TS
  server, or drop. Record in §17.
- **G3:** execute G2.

---

## 13. Phase H — decommission

- H1: delete `server/index.ts` and every `server/jac-*.ts` seam,
  `routineBridgeOps`, mirrors, `jacOp*`, harness supervision.
- H2: delete `electron/` (except the frozen Windows/Intel-mac line per A6)
  and electron-builder packaging for migrated platforms.
- H3: delete `src/`, the node build (`bundle-server.mjs`, tsconfig.server),
  and node-only tests; `shared/` keeps only what Workers/docs need.
- H4: CI rewrite: Jac app build + `jac test` + UI e2e against the app;
  drop vitest shards for deleted code; keep `cloudflare/` Workers and
  `apps/docs` jobs (they stay TS per the migration plan).

---
## 14. Upstream dependency map (jaseci-labs/jac)

| Issue | Gap | Blocks | Workaround while open |
|---|---|---|---|
| #9943 | Windows (WebView2) + Intel macOS desktop hosts | F2/F4 on those platforms | Electron line stays for them (A6) |
| #9944 | bundled/offline, per-app embedded DB | A2 option 2 | files + sqlite (A2 option 1) |
| #9945 | app-supplied native capability plugins | many F1 rows | sv-side Python where possible |
| #9946 | release build may omit colocated service apps | A1, all of C in the shipped app | A1 topology options (b)–(d) |
| #9947 | non-relocatable release (venv path; Linux data dir) | F2 | vendor deps; set `JAC_DATA_PATH` |
| #9948 | embedded backend has no WebSocket/Events/Jobs/Webhooks extensions | C11 (noVNC websocket), C14 (webhook listener) | sv raw-socket listeners |
| #9949 | docs drift (plugin defaults, placement, Windows, #6436) | — | trust code (§1/R11) |
| #9936 | tray | F1 (Windows-only today) | none needed on Linux/mac at first |
| #9937 | auto-update | F4 (and every later release) | manual download; Electron bridge |
| #9938 | deep links / URL scheme | org enrollment, cloud, package install links | paste-a-link UI |
| #9939 | autostart | not used today | — |
| #9940 | single instance + argv forwarding | deep links, data-dir safety | data-dir lease refuses a 2nd instance |
| #9941 | installers + signing/notarization | F2 | our own packaging + release workflow signing |
| #9950 | app/context menus | F1 | UI actions |
| #9951 | window chrome + events | F1 | native chrome |
| #9952 | badge count | unread badge | none |
| #9953 | folder picker, multi-button dialogs | pick folder, confirms | `cl` modals |
| #9954 | multiple windows, window.open policy | desktop viewer window | in-page panel |
| #9955 | webview media + permissions, downloads | voice/live calls, screen preview | sv-side capture |
| #9956 | dropped-file paths | attachments by path | upload bytes |
| #9957 | keychain plugin | secrets | sv `keyring` |
| #9958 | bundle sidecar binaries/resources | CUA, browser engine, cloudflared, speech helper | post-build copy step |
| #9934 | checker: `raise <any>` is E1090 | — | `err: Exception = x; raise err;` |
| #6675 | positional-only args across `@jac/desktop` | F1 | pass positionally |
| #9683 | compile cache keyed on mtime | CI warm cache | pin mtimes in CI (done) |
| #8805 | Intel macOS build broken/non-blocking | #9943 | — |

Also from profiling (file if not yet): every module compiled twice (79 %
of compile CPU); Postgres setup on every request (40–60 ms/op) — not
relevant if A2 keeps us off the graph store, still worth filing.

---

## 15. Status tracker

| WS | Title | Status | Owner | PR |
|---|---|---|---|---|
| A1 | Desktop topology spike | not started | | |
| A2 | Persistence decision | not started | | |
| A3 | Helper processes without node | not started | | |
| A4 | Event feed prototype | not started | | |
| A5 | Compile cost | partial (CI warm cache + mtime pin done) | | #1 |
| A6 | Platform policy | proposed (§6) | product | |
| B1 | e2e fixture env | not started | | |
| B2 | Windows/mac CI shards | not started | | |
| B3 | Computer-claim regressions + room race | not started | | |
| B4 | Docs truth + dead code | partial (AGENTS §7 corrected) | | |
| B5 | Static serving audit | not started | | |
| B6 | Pre-existing routine failures | not started | | |
| C0–C14 | Server core | not started (M1–M4 ports exist as sidecar subsystems) | | |
| D1 | Jac drivers default (claude, codex, openai-compat) | blocked on C3 | | |
| D2–D4 | Remaining drivers, helpers, infra | not started | | |
| E0–E10 | Client | not started | | |
| F1–F6 | Desktop, companion, enterprise, release | not started | | |
| G1–G3 | Hosted tier | not started | | |
| H1–H4 | Decommission | not started | | |

Shims in flight (must be deleted by the named WS): the node↔Jac seam
(`server/jac-*.ts`, bridge ops, mirrors) → H1; `server/local-computer.ts`
TS descriptor reader duplicate → F2; `container-computer.ts` pure
contract duplicate → C11; dual store/message-db writers → C2.

---

## 16. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| A1 shows the release build can't host our service app | blocks everything shipped | options (b)–(d); upstream #9946; single-app fallback |
| Embedded Postgres becomes unavoidable | offline installs fail; data migration | A2 option 1; #9944 |
| Compile time grows with every port (~148 s CI cold today; minutes locally) | slow dev loop, CI cost | A5; keep annexes lean; data-ify generated modules; upstream double-compile issue |
| `cl` has no DOM test harness | UI regressions | UI e2e suite against the loopback origin (E0) |
| No WebSocket in the embedded backend | noVNC viewer, webhook listener | sv raw listeners; #9948 |
| Windows/Intel-mac users stranded on Electron | two codebases for longer | freeze Electron line; shared data format; #9943 |
| Electron-only secrets (safeStorage) | lost credentials on switch | F4 bridge release migrates them |
| Hosted code interleaved into core | C3 stalls | G1 extension points first |
| Agent-written ports diverge in style/helpers | rework | §3 conventions, `common.jac`, review checklist per PR |
| Docs vs code drift upstream | wrong assumptions | trust code; re-verify on the pin (0.37.21) — bump the pin deliberately |

---

## 17. Decisions needed from product

1. **A6 platform policy** — confirm: Linux + Apple Silicon first; Windows
   and Intel macOS stay on Electron until #9943.
2. **A2 persistence** — confirm files + sqlite remain the source of truth.
3. **G2 hosted tier** — per feature: port / separate TS server / drop
   (boat, VPS, cloud home/lending/move, fleet, tunnel, custom domain,
   voice/live calls/TTS, phone).
4. **Remote environments** (desktop window loading a remote server's UI) —
   keep, redesign, or drop for the Jac app.
5. **Pin bump** — stay on 0.37.21 until A1, or move to 0.37.25+ (fixes the
   dict-slot narrowing quirk and likely the stringified-default defect;
   costs a full re-verification).

---

## 18. Sizing (rough, for sequencing — not commitments)

| Phase | TS LOC to replace (excl. tests) | Notes |
|---|---|---|
| A | — | 6 spikes; A1 + A3 are the risky ones |
| B | small | mostly test infra and fixes |
| C | ~26k (index.ts) + ~45k (server core in scope) | C3 is ~⅓ of it |
| D | ~15.4k drivers + ~2.7k helpers | ACP core unlocks 10 kinds |
| E | ~124k client | biggest by volume; mechanical per area |
| F | ~19k Electron + ~4k companion + ~1k enterprise + packaging | upstream-gated |
| G | ~11.5k | decision-gated |
| H | deletions | |

Parallelism: after C0 + C2, C4–C14 run in parallel (separate modules);
E areas run in parallel after E0/E1; D2 kinds run in parallel after the
ACP core. Use worktrees and the §3 conventions; merge through PR #1's
branch (or per-workstream PRs into it) with CI as the gate.
