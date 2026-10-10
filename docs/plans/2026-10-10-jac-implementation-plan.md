# Jac migration — detailed implementation plan (from 2026-10-10 onward)

Companion to `2026-10-07-jac-migration.md` (the "why" and the decision log).
This document is the "how, in what order, and when is it done". It is
written so that each workstream (§6–§13b) can be handed to one engineer or
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

- **Work in order of the phases (§5).** A workstream may start when every
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
| `enterprise/` | 346 impl LOC (788 with tests) | licence + hosted sign-in; imports core auth |
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
- **Persistence (decided 2026-10-10, WS-A2): the Jac graph store on
  Postgres is the source of truth** — the domain model is persistent OSP
  (nodes, edges, walkers over `root`). Today's files (bots.json,
  groups.json, routines.json, webhooks.json, `messages.db`, …) become
  *import/export formats*, read once by a migration importer (WS-C2a) and
  written only by export/backup. Consequences carried through this plan:
  Postgres must ship inside the app and be per-app (upstream #9944 is now
  blocking, WS-F2); Windows Postgres becomes required in WS-U1; every
  request is a SERIALIZABLE transaction replayed on conflict, so engine
  subprocesses, streaming and other side effects stay outside transactions
  (`on_commit`); workspace backup/restore must capture the database
  (WS-C2b); the per-request Postgres session setup cost (40–60 ms/op in
  profiling) must be fixed upstream (§14).
- **Engines:** engine CLIs (claude, codex, pi, ACP agents, …) are spawned
  from sv code exactly as today's Jac drivers do. The stdio helper
  processes engines need (permission proxy, MCP gate, agents MCP, hooks,
  connector proxy, computer bridges) must stop being node scripts (WS-D3).
- **Platforms:** jac-desktop supports **Linux and macOS (arm64) only** in
  code today. **No Electron fallback (decided 2026-10-10):** Windows and
  Intel macOS reach the Jac app by us contributing that support upstream
  (WS-U1, §14 #9943). Much of the groundwork exists upstream (a PE/COFF
  linker in the native backend, Windows host detection); the gaps are the
  WebView2 desktop host, a Windows runtime artifact, and Windows support in
  the Postgres helper.

### 2.2 OSP model (target)

Nodes: `Bot`, `Thread`, `Task`, `Room`, `Message`, `TurnEvent`, `Routine`,
`RoutineRun`, `Webhook`, `Computer` (+ control/lease records, already
graph-modelled in computer_control.jac), `McpServer`, `Connection`,
`Skill`, `MemoryEntry`, `Delegation`, `Card` (approval/question/proposal).

Edges: `Member` (bot↔room), `Owns` (bot→thread/task), `Next`
(message order), `Contains`, `AttachedTo` (bot↔computer), `Grants`
(connection↔bot, server↔bot), `Delegates` (thread→thread), `Schedules`
(routine→bot/room), `Answers` (card→message), `Has` (bot→skill,
bot→memory entry), `Reports` (incident→Chief bot).

Also: `Incident` node (C4), `Principal`/`Device`/`Session` nodes (C1,
A2(h)), `Config` node (C6). Every persisted archetype carries an explicit
`@archetype_alias` from day one (A2(i)).

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

1. **Faithful port, then improve.** Behaviour parity first (wire shapes,
   error texts/status codes, event order; on-disk bytes now hold at the
   import/export boundary — the graph is the store, A2), proven by ported
   tests; refactor only after parity is green. Known TS bugs found during the port are
   fixed in a separate commit, named in the PR.
2. **One writer per file/table/node type at all times** (migration plan seam rule 1).
   When a workstream moves a writer from node to Jac (e.g. the store), it
   flips in one commit and deletes the node writer.
2a. **Persistent OSP (A2):** domain state is nodes/edges under the
   owner's root in the graph store; module globals hold only live,
   non-durable things (subprocess handles, open streams, caches) keyed by
   node ids, and are rebuilt on restart from the graph. Side effects inside
   a request go through `on_commit` (requests replay on conflict).
3. **Module layout:** one Jac module per subsystem in the target `app/`
   layout (§2.1); `common.jac` for shared helpers (do not re-copy guard,
   atomic write, redact, uuid, time — the 2026-10-10 review consolidated
   them).
4. **Test annexes:** `<module>.test.jac`, never importing its own base;
   helper names must not shadow base defs; a checker error in a test annex
   breaks `jac run`. Until upstream decides on test annexes at boot
   (profiling: 56 % of compile time), keep annexes lean.
5. **Errors:** `common.fail(status, msg)`; validation messages the client
   displays keep today's text (originally zod's) for parity — produced by
   Jac validation, not zod.
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

The **§ letters** are the section ids the C workstreams cite ("index.ts
section Y"); section A is lines 1–648 (imports).

| § | Lines | Section | LOC | Target workstream |
|---|---|---|---|---|
| B | 649–870 | config/bootstrap, data-dir lease, restore, sessions, `cfg`, registry | 220 | C6, C1 |
| C | 872–1452 | identity + Cloud-home ownership/lending | 580 | G (deferred), C1 |
| D | 1453–1667 | bot visibility | 215 | C1 |
| E | 1668–1912 | admin audit, usage booking | 245 | C13 |
| F | 1913–2182 | provider auth, MCP OAuth, Electron parentPort channel, bus | 270 | C6, F1, C3 |
| G | 2183–2560 | internal capability tokens (per turn-generation bearers) | 380 | C12 |
| H | 2561–3069 | direct-turn dispatch claims, turn resources | 510 | C3 |
| I | 3070–3204 | browser runtime, per-turn integrations | 135 | C10, C3 |
| J | 3205–3340 | computer control glue | 135 | C11 |
| K | 3341–3773 | model selection, engines, packages | 430 | C6, C9 |
| L | 3774–3851 | store construction and boot | 80 | C2 |
| M | 3852–4592 | wire projections, approval modes, `handleDesktopTrustedApprovalMessage` (~400) | 740 | C2, C5, F1 |
| N | 4593–5468 | rooms/groups state | 875 | C3 |
| O, P | 5469–5857 | store→SSE bridge, message pages, SSE fan-out (`broadcast` 5808; 55 call sites) | 385 | C3 (event feed) |
| Q | 5858–6112 | fold helpers, card answers | 255 | C3, C5 |
| R, S | 6113–6655 | watchdog, bus subscribers, engine hooks, digests | 545 | C3 |
| T | 6656–7537 | computers (≈40 % Boat/VPS) | 880 | C11, G |
| U | 7538–8279 | **the fold** (`handleRuntimeEvent`, awaits a Jac op per event) | 740 | C3 |
| V | 8280–8964 | delegation and handoffs | 685 | C4 |
| W | 8965–9400 | steer-queue drain, direct sends (`acceptDirectSend`) | 435 | C3 |
| X | 9401–9583 | live screen poller, titles | 180 | C11, C3 |
| Y | 9584–11087 | **`startTurn`** (~1,500) | 1,500 | C3 |
| Z, AA | 11088–11656 | routine helpers + **Jac→node bridge ops** | 570 | C3 / deleted in H |
| AB, AC | 11657–12487 | boot recovery, card-proposal services, `deleteBotWithLifecycle` | 830 | C5, C2 |
| AD | 12488–12509 | webhooks (ingress listener) | 22 | C14 |
| AE | 12510–14414 | **group turn engine** (`runGroupMemberTurn` ~1,055, `startGroupTurn`) | 1,905 | C3 |
| AF, AG | 14415–15408 | calendar calls, cards and resumes | 995 | C5, G (calls) |
| AH | 15409–15943 | settings surface (`configStatus`) | 535 | C6 |
| AI | 15944–16199 | HTTP plumbing, static serving | 255 | C0 |
| AJ | 16200–25635 | **`handleRequest`** (9,435): public 11 · sessions 15 · internal 50 · public API ~202 | 9,435 | per route group, §4.2 |
| AK | 25637–25923 | boot order, timers, shutdown | 287 | C0 |

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
Phase U  Upstream PRs we author: U2 in Phase A; U1 after F2 (U1.3 early)
            │
Phase B  Stabilize the branch (CI green on what exists)  B1..B8   (parallel with A)
            │
Phase C  Server core into Jac sv (index.ts decomposed)   C0..C15 (C2 = model+C2a+C2b, cutover with C3)
            │            ╲
Phase D  Drivers + stdio helpers in Jac                  D1..D4  (D1 needs C3; D3 needs A3)
            │
Phase E  Client into Jac cl                              E0..E9  (needs C-feeds: C3 event feed, A4)
            │
Phase F  Desktop shell, companion, enterprise, release   F1..F7  (needs A1, upstream §14)
Phase X  Cross-cutting (observability, a11y, telemetry, docs) X1..X4 (alongside C–F)
            │
Phase G  Hosted tier: re-scope or port                   G1..G3  (decision-gated)
            │
Phase H  Decommission node/Electron/seams; CI rewrite    H1..H4
```

Critical path: **§17 pin decision → A1 → A2 spike (+U2) → C0 → C1 →
C2-model → G1 → C3 (with C2-cutover) → C12 + A3/D3 → E0/E1 → E2…E9 → F2 →
F4 → H.** A shipped node-less app needs C12 and D3; C3 transitively needs
C1, C2-model and the registry part of C6. Upstream items (§14) gate F
(tray, updater, deep links, single-instance, signing, Windows) and A2/F2
(Postgres: #9944, #9959).

Parallelism: C6, C7 (model parts), C15 and the C2a importer can run beside
C3 once C2-model lands; C4, C5, C8, C10–C14 need C3. E areas run in
parallel after E0/E1. D2 kinds run in parallel after the ACP core.

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
  Postgres start), warm launch time, where data lands
  (`JAC_DATA_PATH`/app_data — upstream #9947), localStorage persistence
  across launches (token), behaviour with no network on first run.
- **REST surface:** can JacAPIServer serve custom method + path routes
  (GET/DELETE, path params, multipart upload, CSV and streaming downloads)
  or only `POST /function/<name>` and `/walker/<name>`? External clients
  depend on today's REST shapes (companion, `scripts/mcp-server.ts`, the
  CLI, Cloudflare Workers). If not supported, file upstream and decide the
  compat layer for C0.
- **Performance budgets** (recorded here, enforced in F2 acceptance): cold
  first launch, warm launch, trivial op p50/p95, first-token latency of a
  scripted turn, idle RSS.
- **Depends on:** §17 decision 5 (pin) — A1 binaries and every later
  number depend on the toolchain version.
- **Decision:** the workspace layout (§2.1) and the build invocation used
  by every later workstream. **Done when:** the hello-world release binary
  runs on Linux x86_64 and macOS arm64 from CI artifacts, and dev ≡ build
  behaviour is shown by one scripted check.

### A2. Persistence
- **Question:** what holds our state in the desktop app? The Jac graph
  store is always the machine-wide embedded Postgres (downloaded from Maven
  Central on first run; POSIX only; shared with any developer `jac`
  install) — upstream #9944.
- **Decision (2026-10-10): option (2) — graph store on Postgres is the
  source of truth**, chosen so the domain is genuinely OSP (persistent
  nodes/edges/walkers), not files with an in-memory graph.
- **Spike scope now:** (a) bundle Postgres with the app via `JAC_PG_DIST`
  set by the host/launcher and prove an **offline first run** works;
  (b) per-app isolation — the app must not share the machine-wide cluster
  at `~/.cache/jac/pg/main` with developer `jac` installs (database name is
  keyed by base path, but the cluster, socket dir and versions are shared
  — #9944); (c) write throughput for streaming turns: message appends +
  TurnEvent nodes at Claude's peak (~60 events/s) inside per-request
  transactions, with conflict-replay rates measured; (d) graph size at a
  heavy user's scale (100k+ messages) — query latency for thread pages and
  search; (e) how long-lived turn state (subprocess handles, open
  streams) lives *outside* the graph (module state keyed by node id) and
  reconciles on restart; (f) whether `messages.db` full-text search moves
  to Postgres FTS or stays a derived sqlite index;
  (g) **writes outside a request** — driver reader threads, `@schedule`
  ticks and subprocess callbacks have no HTTP request around them: define
  the commit API they use (`runtime.commit` / `on_commit`), coalescing
  (commit per message, never per delta), and what a conflict replay does to
  side effects;
  (h) **roots and principals** — the owner, members, paired phones,
  companion requests, the CLI and guests: one workspace root with access
  control in our code (C1 visibility rules), or per-user roots (Jac's
  default, which partitions data). Recommendation: one workspace root,
  every walker bound to it explicitly; disable Jac's `__guest__` fallback
  for our endpoints;
  (i) **schema evolution** — persistent type identity follows the module
  path (`serializer.impl.jac:679` refuses path-derived `_jac_app_*` keys;
  `@archetype_alias` and `__jac_schema__` drift rules in
  `jaclang/cli/docs/reference/persistence.md`). Moving code from
  `jac/harness/` to `app/core/model/` changes identities, so: explicit
  aliases on every persisted archetype from day one, a schema-version
  policy, a migration fixture per release, back up the database before
  migrating, refuse to run an older app on a newer schema;
  (j) **what stays on disk** — engines read bot folders, CLAUDE.md, memory
  markdown, skills dirs and attachments from the filesystem; those stay
  canonical on disk and the graph holds their metadata only (C2a must not
  import their contents);
  (k) **bundled Postgres lifecycle** — major-version upgrades of the
  shipped distribution (`pg_upgrade` or dump/restore across app updates),
  vacuum and disk growth, cluster backup; whether `JAC_PG_DIST` can be set
  before the store boots or needs host support (#9944).
- **Thresholds (pass/fail):** append p95 < 25 ms at 60 events/s sustained
  for 10 min with < 1 % conflict replays; thread page (50 messages) p95 <
  100 ms at 100k messages; offline first run succeeds with networking
  disabled; cold first launch including Postgres init < 20 s on CI
  runners. Adjust only with a recorded reason.
- **Done when:** spike write-up with numbers for (a)–(k) against the
  thresholds; the persisted node/edge schema for C2 drafted with aliases
  (§2.2); decisions for (g), (h), (j) recorded in §17.

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
- **Node for engines:** several engines are themselves node CLIs and
  `engine-install.ts` installs them with `npm install -g` (needs npm on
  PATH); today some helpers lean on Electron's node. Decide the end state:
  require the user's node, offer a managed node download, or bundle node.
- **Done when:** one proxy (the permission proxy) runs from a release
  binary without our node, round-trips a permission ask, and dies with the
  app; the node-for-engines decision is recorded in §17.

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

### A6. Platform policy (decided 2026-10-10)
- jac-desktop builds/runs only on Linux and macOS arm64 today (upstream
  main); Windows and Intel macOS need upstream work (#9943).
- **Decision: no Electron fallback.** Electron is retired, not kept alive
  per platform. Windows (and Intel macOS) support is driven upstream
  through our own PRs (WS-U1), scheduled after the Linux/Apple Silicon app
  works. Until those PRs land, the Jac app ships on Linux and Apple
  Silicon only; existing Windows/Intel-mac Electron installs are not
  updated further; when U1 lands they install the Jac app and the C2a
  importer brings their data dir into the graph.

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
- They have no jac. Until WS-U1 lands, mark harness-needing e2e tests
  `skipIf(!jacAvailable())` on those runners, with a counter in the CI
  summary so the skipped set stays visible; drop the Windows/mac vitest
  matrix entries entirely once the node server is retired (H4).

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
  checking the prefix. (Replaced by the desktop host later; fix it now
  because the node server ships until H.)

### B6. Pre-existing routine failures
- The 3 routine `index.test.ts` failures that predate the webhooks port;
  root-cause each now that the test harness boots Jac.

### B7. Retarget evals and verification at the Jac app
- `evals/runners` boot the node server; golden replay (C3/D1 acceptance),
  behavior evals, skill-bench, `scripts/control-omb.ts` and
  `scripts/verify-*.ts` must target the Jac app in headless mode (F6)
  before C3 can use them as a gate. Until F6 exists they target node with
  `OMB_JAC_DRIVERS=all`.
- **Depends on:** F6 headless entry (can be pulled forward as a dev-only
  `jac run` of the workspace).

### B8. Windows CI for sv code
- A Windows job running `jac check` + `jac test` on our sv modules (needs a
  Windows jac — until U1 lands, run `jac check` via the source build or
  skip with a visible counter) so app code stays Windows-clean (U1 note).


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
- **Mechanics:** the prefix table lives in one file
  (`server/jac-routes.ts`, deleted in H1); node forwards method, path,
  query, headers (incl. auth cookie/bearer) and body unchanged, and streams
  responses (SSE and downloads) through. The REST→Jac translation happens
  **in Jac**, per A1's REST finding: either custom method+path routes, or a
  single Jac dispatcher endpoint that maps today's paths onto `def:pub`s.
  Node does no translation.
- **Depends on:** A1 (incl. its REST finding).
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
  Principals, sessions and paired devices are graph nodes under the
  workspace root (A2(h)); Jac's built-in user model and `__guest__`
  fallback are not used for our principals.
- **Security (required before any non-public prefix flips):**
  - loopback is not a trust boundary on a desktop (any local process or web
    page can reach the port): require a host-issued per-launch secret on
    every request (replacing today's Electron owner header) plus Host/
    Origin checks against DNS rebinding;
  - disable Jac's auto-created `admin` user and `/admin` routes and the
    guest fallback (AGENTS §5);
  - SSRF review of skill-fetch, mcp-http, connector and webhook outbound
    calls; static-serving audit of the desktop host (B5 covers node).
- **Note:** the `/__jac/` desktop broker's SSO targets a remote Jac server
  with scale SSO (research §6) — not our model; ignore for now.
- **Done when:** all 26 session/auth endpoints served by Jac with the TS
  tests' invariants ported (request-auth, sessions, bot-visibility,
  decision-log, auto-approve, command-allowlist tests).

### C2. Store, bots, threads, tasks, messages — graph model, importer, cutover
- **Scope (TS):** store.ts 2,951, message-db.ts 892, attachments.ts 724,
  message-file.ts 475, checkpoints.ts 670, bot-folder.ts 102,
  thread-starters.ts 84, profile-*.ts, bot-profile.ts, new-bot-defaults.ts,
  bot-overview.ts, thread-events.ts, thread-title.ts, message-search*.ts
  (worker thread), commands.ts; index.ts sections L, M (wire projections),
  O (message pages), routes: /api/bots (create/edit/delete/model/profile/
  soul/history/projects/tasks), /api/threads, /api/attachments,
  /api/files, /api/search, /api/sidebar-sections, /api/bot-defaults.
- **Split (sequencing):** index.ts makes ~1,052 synchronous `store.*`
  calls and the node turn pipeline lives until C3, so the store cannot flip
  ahead of C3 without a sync mirror (§0 forbids new ones).
  - **C2-model (before C3):** persisted node/edge schema with aliases
    (A2(i)), the C2a importer and C2b export, round-trip tests, read-only
    endpoints on Jac. Node keeps writing files; no flip.
  - **C2-cutover (lands with C3 PRs (1)–(2), behind one flag):** the graph
    becomes the live store in the same release that moves the turn
    pipeline; node's `Store` is deleted, not mirrored.
- **Key step (graph store, A2):** persist `Bot`, `Thread`, `Task`,
  `Room`, `Message` as nodes under the workspace root (A2(h)). The
  byte-faithful file modules from M1 (`store.jac`, `messages.jac`,
  `db.jac`) become the **importer's readers** (C2a) and the export writers.
- **C2a. Migration importer:** first launch of the Jac app (and the F4
  bridge) imports an existing `~/.openmausbot` data dir — bots.json,
  groups.json, config.json, messages.db, routines.json, webhooks.json,
  team-computers.json, mcp-oauth.json, thread-starters, memory *metadata*,
  attachments *index* — into the graph. Files the engines read stay
  canonical on disk (A2(j)); only their metadata is imported.
  - Idempotency: every imported node carries its source id
    (`source: {file, key}`); re-import upserts by source id and never
    overwrites a field changed in the Jac app after import (the receipt
    records the import timestamp per node; later edits win).
  - Receipt: `<data dir>/.jac-import/receipt.json` (source file hashes,
    counts, per-file status); a partial failure resumes from the first
    unfinished file.
  - Conformance corpora become importer fixtures: import → export must
    reproduce today's bytes.
- **C2b. Backups on the graph:** `.ombbackup` export/restore and team
  backups read/write the graph (export via the same writers as C2a, plus
  attachments/workspace files); restore = import into a fresh database.
  Keeps old `.ombbackup` files restorable.
- **OSP:** persistent `Bot`, `Thread`, `Task`, `Room`, `Message` nodes with
  `Owns`, `Next`, `Contains`, `Member` edges; graph.jac's file hydration is
  retired. Graph change events become event-feed frames (C3) instead of
  `store.onChange → broadcast`.
- **Depends on:** A2 spike (schema, thresholds), C0, C1.
- **Done when:** the graph is the only live store; node no longer writes
  any of these files; store/message-db TS deleted; import→export of the
  conformance corpora is byte-identical; `store.test.ts` (2,532 LOC)
  invariants ported against the graph.

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
- **Depends on:** A1, A4, C0, C1, C2-model (cutover lands with this WS), G1 (hosted extension points), registry part of C6.
- **PRs (each its own status row in §15, each with its own acceptance):**
  C3.1 event feed + in-process fold (+ C2-cutover behind the flag);
  C3.2 direct turns (`StartTurn`); C3.3 rooms/group turns;
  C3.4 queues/steer/aside; C3.5 watchdog, digests, recovery.
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
- **Scope:** config.ts 1,842 (63 importers — port last within C6; config
  becomes a graph node (A2), config.json is import/export only via C2a/C2b), harness/registry.ts
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
- **Depends on:** C0, C1. **Done when:** config lives in the graph (config.json only imported/exported);
  `config.test.ts` invariants ported; settings routes on Jac.

### C7. Skills
- skills.ts 1,513, skill-library 399, skill-fetch 268,
  skills-library-migration 251, skill-learn 84; routes skills,
  skills-library, skill-template, internal skills/stage. `Skill` node +
  `Has` edges. Depends on C2, C3.
- **Done when:** skills routes + internal skills/stage on Jac; skills dirs
  stay canonical on disk (A2(j)) with `Skill` nodes as metadata;
  `skills.test.ts` (1,206 LOC) invariants ported; skills*.ts deleted.

### C8. Memory
- workspace.ts 713 (partially ported), memory-upkeep 526, memory-journal
  503, memory-store 397 (partial), team-memory 254, routes/bot-memory 235,
  memory-capture 220, recall 194, memory-topics/-entries (partial),
  memory-tidy, profile-learned, memory-organize, recall-disclosure; routes
  /api/team-memory, /api/section-context, bot memory. Scheduled upkeep →
  `@schedule`. Depends on C2, C3 (capture subscribes to turns).
- **Done when:** memory routes on Jac; MEMORY.md and topic files stay
  canonical on disk (A2(j)) with graph metadata; upkeep/tidy run as
  `@schedule`; memory*.ts, recall*.ts, team-memory.ts deleted with their
  tests' invariants ported.

### C9. Packages, presets, org library, teams
- org-library 1,173, package-export 896, presets 612, package-import 596,
  project-scout 371, team-manifest 326, managed-desktop 265, enterprise.ts
  247 (hook point), team-library 241, bot-directory, managed-policy,
  bot-package, package-parts, published-teams, installed-playbooks; routes
  /api/teams, /api/team-library, /api/org-library, /api/bot-presets.
  Depends on C2, C3, C6.
- **Done when:** team/org-library/preset routes on Jac; package export →
  import round-trips (`shared/package-format.ts` fixtures); org-library
  test invariants (29) ported; package*.ts, presets.ts, org-library.ts
  deleted.

### C10. Browser
- browser-engine 608, browser-live 587, browser-runtime 553,
  browser-lifecycle-cleanup 394, browser-tool-shape, browser-engine-release,
  browser-bundle-release; routes /api/bots/:id/browser/{live,action},
  /api/browser-engine/install, internal browser/mcp. The agent-browser
  sidecar is spawned by sv (no change); its bundling/signing is F/#9958.
  Depends on C3.
- **Done when:** browser routes + internal browser/mcp on Jac; browser
  e2e cases pass against Jac; browser-*.ts deleted.

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
- **Done when:** computer routes on Jac; behavior evals lazy-claim
  scenarios and computer e2e (group-local-vm, surface-pins, openai-compat-
  vm) pass; the `container-computer.ts` contract duplicate deleted.

### C12. Internal capability API (engine-facing)
- index.ts G (capability tokens) + the 50 `/api/internal/*` endpoints.
  These are what the stdio proxies (D3) call. Keep the HTTP surface (the
  proxies are separate processes) but serve it from Jac; tokens are minted
  per turn generation in `StartTurn` (C3).
- Depends on C3; pairs with D3.
- **Done when:** all 50 `/api/internal/*` endpoints served by Jac with
  per-turn-generation tokens minted in `StartTurn`; token kind/path checks
  and revocation tests ported.

### C13. Usage, spend, audit, logs
- usage-ledger 355, spend 197, model-prices 164, prices 38,
  group-thread-usage 94, admin-activity 480, decision-log (C1),
  thread-log-rotation 98, thread-retention 64; index.ts E; routes usage,
  plan-usage, decisions(.csv), admin-activity(.csv), activity, outbound.
  Retention/rotation timers → `@schedule`. Depends on C2, C3.
- **Done when:** usage/audit routes (incl. CSV) on Jac; ledgers as graph
  nodes or append-only files (decide in A2(j)); usage-ledger/spend tests
  ported; the TS files deleted.

### C14. Routines/webhooks finish
- Already in Jac; remove their node seams: `jac-routines.ts` mirror and
  facade, `jac-webhooks.ts`, `webhook-ingress.ts` (the webhook listener
  becomes an sv listener on `WEBHOOK_PORT` — a raw `asyncio` HTTP server
  in sv, since the embedded backend has no webhook extension, #9948),
  `routine-requests.ts` (→ C5), calendar calls (G or here if kept),
  routes /api/routines, /api/routine-runs, /api/webhooks.
- Depends on C0, C3.

### C15. Re-home the M1–M4 Jac subsystems onto the graph
- routines, webhooks, connectors, mcp_oauth, computers (control/team/
  shared), workspace/team backup and the drivers keep state today as
  file-backed module globals (routines.json, webhooks.json, …). Under A2
  they become persistent nodes (`Routine`, `RoutineRun`, `Webhook`,
  `McpServer` sign-in records, …); their files become C2a/C2b formats.
- Also owns the profiling bugs: `routines._tick_body` rescans the run list
  per run (O(n²); 125–227 ms per tick at 2,000 runs); `_js_pretty` /
  `js_string` escaping (284 ms per save at 2,000 runs — moot once routines
  are nodes, keep for export); `_now_iso` timestamps (fixed in common.jac —
  verify).
- **Depends on:** C2-model. **Done when:** none of these modules writes its
  JSON file in normal operation; their Jac tests pass against the graph.

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
- **Fallback order** (until A3 decides): (1) in-process URL MCP where the
  engine supports it; (2) the A3 mechanism (alternate entry of the app
  binary or a small native helper); (3) the existing node script against
  the user's node (temporary; tracked as a shim in §15).
- **Contract per helper** (write it down in D3's first PR): argv, env vars
  the engine passes (`OMB_*` tokens, socket paths), stdin/stdout framing
  (MCP JSON-RPC), the `/api/internal/*` endpoints it calls (C12), and its
  lifetime (dies with the turn / with the app).

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
  yaml (no zod — wire types are Jac `obj`s). Tailwind v4 via
  `[client.vite] plugins`.
- **i18n:** no built-in facility; port `src/lib/i18n.ts` (84 LOC, hand
  written) as-is + the 10 catalogs and `generate-locale.mjs --check`.
- **Wire (decided 2026-10-10: Jac only, no zod):** the wire contract —
  `ServerFrame` union, request/response shapes, package/backup formats —
  is defined once as Jac `obj`/enum types in `app/core/wire/`, validated
  in Jac. No zod schemas are kept or added. Remaining TS consumers (the
  React client during the overlap, the Cloudflare Workers, `apps/docs`)
  get **generated** TS types from the Jac definitions — a small generator
  in `scripts/` (Jac type → `.d.ts`) until jaclang offers codegen (file
  upstream). `shared/*.ts` zod files are replaced area by area as their
  Jac `obj` lands, and `zod` leaves `package.json` at H3.
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
  §19 (appendix). Owners for the "needs design" rows: remote environments
  and the trusted-approval bridge → F1 lead; cloud/org flows → F7.

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
- **Sidecar pipeline:** `scripts/prepare-cua*.mjs`, `cua-*-release`,
  `prepare-browser.mjs`, `prepare-cloudflared.mjs`,
  `prepare-android-tools.mjs`, the macOS speech helper build — staged,
  verified and signed into the Jac bundle (#9958, #9941); after-pack checks
  ported.
- **Acceptance includes A1's performance budgets.**
- **Postgres ships in the app** (A2): bundle the platform Postgres
  distribution, point `JAC_PG_DIST` at it from the host/launcher, keep the
  cluster under the app data dir (not the shared `~/.cache/jac/pg/main`),
  and prove offline first launch in CI. Blocked/eased by #9944.
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
  3. leaves the data dir untouched; the Jac app's first launch runs the
     C2a importer into its graph (the files stay as the rollback copy).
- **Rollback promise:** the C2b export writes the old file formats, so a
  user can return to the last Electron build with data created in the Jac
  app (export → old data dir). Documented and tested once per release.
- Windows / Intel macOS: no bridge release until WS-U1 lands (A6); then
  the same bridge flow (secrets migration needs the Electron-side decrypt,
  so the Windows bridge release ships from the last Electron build).
- Legacy updater mirror (`openmausbot-releases` for builds ≤ 0.1.46)
  carries the bridge release too.

### F5. Enterprise
- `enterprise/` (346 impl LOC): licence verification (Ed25519) and hosted
  workspace sign-in; ports with C1 (it imports request-auth, sessions,
  hosted-contract). Keep the `OMB_ENTERPRISE_DIR` hook semantics as a Jac
  module that is absent in the open-source edition.

### F6. CLI and service mode
- `cli.ts` 1,288, cli-setup, cli-prompts, cli-api-setup, service-unit,
  service-cli, openmausbot.ts entry: the headless `openmausbot` command
  (server without the window, systemd/launchd unit). Becomes a Jac CLI
  entry that runs the same workspace headless (`jac run` service mode) —
  the Docker/self-hosted image uses it.
- **Distribution channels** (each decided and owned here): the
  `Dockerfile` (two targets: tenant and cloud-home) with Postgres inside
  the image, linux-arm64; `deploy/` (fly, podman, compose, Caddy); the npm
  package (`scripts/build-npm-package.mjs`, `npx openmausbot serve`) —
  keep (wrapping the Jac binary) or retire; the external MCP server
  (`scripts/mcp-server.ts`); `pair-cli`, `fleet-cli` (G).
- **Done when:** the headless Jac app serves the API and event feed with no
  window; the Docker image builds and passes a smoke in CI.

### F7. Cloud and organization clients
- Electron-side clients of the Cloudflare Workers and hosted services move
  to sv, each with a named owner: `control-plane-client.mjs`,
  cloud-account, org enrollment and branding, company backups (+schedule),
  the managed-companion guardian and tunnel (cloudflared), the
  composio-broker credential rotation, org-library relay, cloud move,
  lending. The Workers themselves stay TS (no change).
- Secrets they hold move to the keychain (F1). **Depends on:** C1, F1, G2
  for the hosted parts.

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
- H2: delete `electron/` and electron-builder packaging (no fallback line
  — A6). Keep only what the Windows/Intel-mac bridge release (F4) needs,
  on a release branch, until WS-U1 ships.
- H3: delete `src/`, the node build (`bundle-server.mjs`, tsconfig.server),
  and node-only tests; `shared/` is deleted — the Workers and docs consume
  TS generated from the Jac wire types; `zod` is removed.
- H4: CI rewrite: Jac app build + `jac test` + UI e2e against the app;
  drop vitest shards for deleted code; keep `cloudflare/` Workers and
  `apps/docs` jobs (they stay TS per the migration plan).

---
## 13a. Phase X — cross-cutting (alongside C–F)

- **X1 Observability:** log locations under the app data dir, turn logs
  (thread NDJSON tee), crash capture for the sv process and webview, the
  diagnostics export (redacted bundle) — parity with today's
  `diagnostics.mjs` and thread-log rotation.
- **X2 Accessibility:** every E area's acceptance requires keyboard and
  ARIA parity with the React original; a11y checks in the UI e2e suite.
- **X3 Telemetry and consent:** port `src/lib/analytics.ts` (PostHog,
  app_open, opt-out) with identical consent semantics; no new telemetry
  without a product decision.
- **X4 Docs:** `apps/docs` updates per release — install per platform,
  data location (graph DB + canonical files), the Windows/Intel-mac status
  (WS-U1), self-hosting with the headless image, migration from the
  Electron app.

## 13b. Phase U — upstream contributions we own

### U1. Windows (and Intel macOS) for jac-desktop — our PRs to jaseci-labs/jac
Evidence (upstream main, 2026-10-10): the native backend already has a
COFF/PE linker (`jaclang/compiler/backends/native/pe_linker.jac`) and
`toolchains/host.jac` recognises Windows; what is missing:
1. **WebView2 desktop host** — `toolchains/system.jac ensure_desktop_host`
   raises for non-Linux/macOS; add the Windows branch: WebView2 SDK/loader
   provisioning, build of the webview library (webview.h supports WebView2)
   with MSVC or clang-cl, the host's Windows message loop.
2. **Windows runtime artifact** — the desktop build grafts the runtime from
   the running `jac` binary; jaseci publishes no Windows `jac`. Needs the
   Windows build of the fused runtime in jaseci's release pipeline (and the
   Intel-mac build: #8805 — about release gating — is closed, yet v0.37.25
   still ships no `macos-x86_64` asset; file the build failure itself as its
   own issue).
3. **Postgres helper on Windows (required — A2 uses the graph store)** —
   `data/impl/pgembed.impl.jac` `_platform_slug` knows only Linux/Darwin
   and locks with `fcntl`; add the `windows-amd64` zonky slug, a Windows
   file lock (`msvcrt.locking`), and Windows socket/port handling.
4. Path/data-dir and process differences surfaced by our app (process
   groups → job objects for engine CLIs, `killpg` → `TerminateJobObject`).
- **Process:** AGENTS §3 — minimal repro per gap, feature branch off
  upstream main, tests, PRs against jaseci-labs/jac; track here and in
  #9943. Our own app code must be Windows-clean as we write it (no POSIX-
  only calls without a Windows branch) so the app is ready when U1 lands.
- **When:** after F2 (the Linux/Apple Silicon app ships). Requires the
  `workflow` token scope for pushing to the fork (see #9934 note).
- **Done when:** `jac build --platform windows` of our app produces a
  working binary in CI on a Windows runner, upstream PRs merged.

---

### U2. Upstream fixes on the critical path — our PRs (Phase A, not later)
- #9959 memoize embedded-PG `ensure()` per process (low effort; every op).
- #9944 per-app, offline embedded Postgres for desktop apps (A2, F2).
- #9946 release topology: service apps colocated in desktop release builds
  (A1).
- Process as U1 (AGENTS §3); start as soon as A1/A2 confirm each problem
  on the pin. Track each PR in §14.

### U1 timing note
U1.3 (pgembed on Windows) is small and independent — start it in Phase A.
Add a Windows CI job in Phase B that runs `jac check` and `jac test` on our
sv modules, so "app code stays Windows-clean" is checked continuously
rather than discovered when U1 lands.

---

## 14. Upstream dependency map (jaseci-labs/jac)

| Issue | Gap | Blocks | Workaround while open |
|---|---|---|---|
| #9943 | Windows (WebView2) + Intel macOS desktop hosts | F2/F4 on those platforms | **we implement it upstream (WS-U1)**; no Electron fallback (A6) |
| #9944 | bundled/offline, per-app embedded DB | **A2 (decided: graph store) and F2 — blocking** | bundle PG ourselves via `JAC_PG_DIST`; separate cluster dir; send the fix upstream |
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
| #6675 | positional-only args across `@jac/desktop` — **closed NOT_PLANNED by the stale bot (2026-09-04), not fixed** | F1 | pass positionally; re-check on the pin, then reopen or send a PR (AGENTS §3) |
| #9683 | compile cache keyed on mtime | CI warm cache | pin mtimes in CI (done) |
| #8805 | (closed 2026-08-31; was about release gating) Intel-mac binary still absent in v0.37.25 | #9943 | file the abort as its own issue (U1) |
| #9959 | embedded PG `ensure()` re-runs every request: no-op `def:pub` 40–60 ms, two transactions | every UI call + streamed-turn write (A2) | none app-side (`JAC_DB_URL` can't address the embedded socket); fix upstream |
| #9164 | redundant compilation (we added: every module compiled twice, pass 2 = 79 % of cold compile) | A5, dev loop, CI | CI warm cache |
| #9411 | three commits per walker request, each re-hashing every loaded anchor | walker-heavy endpoints (A2 throughput) | — |

Profiling findings are tracked as #9959 (per-request Postgres setup —
**now on our hot path** since A2 chose the graph store) and #9164
(double compile; our numbers added).

---

## 15. Status tracker

| WS | Title | Status | Owner | PR |
|---|---|---|---|---|
| A1 | Desktop topology spike | not started | | |
| A2 | Persistence | decided: graph store on Postgres; spike (a)–(f) not started | | |
| A3 | Helper processes without node | not started | | |
| A4 | Event feed prototype | not started | | |
| A5 | Compile cost | partial (CI warm cache + mtime pin done) | | #1 |
| A6 | Platform policy | decided: no Electron fallback; Windows via upstream PRs | product | |
| U1 | Upstream Windows (+ Intel macOS) desktop support | planned after F2 | | |
| B1 | e2e fixture env | not started | | |
| B2 | Windows/mac CI shards | not started | | |
| B3 | Computer-claim regressions + room race | not started | | |
| B4 | Docs truth + dead code | partial (AGENTS §7 corrected) | | |
| B5 | Static serving audit | not started | | |
| B6 | Pre-existing routine failures | not started | | |
| C0, C1 | Router, auth + security | not started | | |
| C2-model | Graph schema (aliases) + read-only endpoints | not started | | |
| C2a | Importer (receipts, idempotent) | not started | | |
| C2b | Backups/export through the graph | not started | | |
| C3.1–C3.5 | Event feed+fold (+C2-cutover), direct turns, rooms, queues, watchdog/recovery | not started | | |
| C4–C14 | Remaining server core | not started (M1–M4 ports exist as sidecar subsystems) | | |
| C15 | Re-home M1–M4 subsystems onto the graph | not started | | |
| B7, B8 | Evals retarget; Windows CI for sv | not started | | |
| U2 | Upstream PRs #9959, #9944, #9946 | not started | | |
| X1–X4 | Cross-cutting | not started | | |
| D1 | Jac drivers default (claude, codex, openai-compat) | blocked on C3 | | |
| D2–D4 | Remaining drivers, helpers, infra | not started | | |
| E0, E1 | Client foundations + state store | not started | | |
| E2–E9 | Client feature areas (E3, E4, E6, E7 split into sub-PRs of ≤3k LOC) | not started | | |
| E10 | `window.ogb` replacement map (§19) | not started | | |
| F1–F7 | Desktop, companion, enterprise, release, CLI/distribution, cloud clients | not started | | |
| G1–G3 | Hosted tier | not started | | |
| H1–H4 | Decommission | not started | | |

Shims in flight (must be deleted by the named WS): the node↔Jac seam
(`server/jac-*.ts`, bridge ops, mirrors) → H1; `server/local-computer.ts`
TS descriptor reader duplicate → F2; `container-computer.ts` pure
contract duplicate → C11; dual store/message-db writers → C2-cutover;
the C0 node reverse proxy + prefix table → H1; the E0 raw-fetch shim →
E2–E9 (per area); D3 fallback (3) node scripts → D3.

---

## 16. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| A1 shows the release build can't host our service app | blocks everything shipped | options (b)–(d); upstream #9946; single-app fallback |
| Graph store on Postgres (A2) | offline first run, shared cluster, per-request latency, conflict replays under streaming load, data migration of every existing user | A2 spike (a)–(f); bundle PG (F2); C2a importer with receipts; upstream #9944 + per-request setup fix |
| Compile time grows with every port (~148 s CI cold today; minutes locally) | slow dev loop, CI cost | A5; keep annexes lean; data-ify generated modules; upstream double-compile issue |
| `cl` has no DOM test harness | UI regressions | UI e2e suite against the loopback origin (E0) |
| No WebSocket in the embedded backend | noVNC viewer, webhook listener | sv raw listeners; #9948 |
| Windows/Intel-mac users have no Jac app until our upstream PRs land | a platform gap, no fallback | WS-U1 scheduled right after F2; shared data format makes the later move a fresh install |
| Electron-only secrets (safeStorage) | lost credentials on switch | F4 bridge release migrates them |
| Hosted code interleaved into core | C3 stalls | G1 extension points first |
| Agent-written ports diverge in style/helpers | rework | §3 conventions, `common.jac`, review checklist per PR |
| Docs vs code drift upstream | wrong assumptions | trust code; re-verify on the pin (0.37.21) — bump the pin deliberately |

---

## 17. Decisions needed from product

1. ~~A6 platform policy~~ **decided 2026-10-10:** no Electron fallback;
   Windows/Intel macOS via our upstream PRs (WS-U1).
2. ~~A2 persistence~~ **decided 2026-10-10:** the Jac graph store on
   Postgres is the source of truth (persistent OSP); files become
   import/export formats (C2a, C2b).
3. **G2 hosted tier** — per feature: port / separate TS server / drop
   (boat, VPS, cloud home/lending/move, fleet, tunnel, custom domain,
   voice/live calls/TTS, phone).
4. **Remote environments** (desktop window loading a remote server's UI) —
   keep, redesign, or drop for the Jac app.
5. **Pin bump — decide before A1** — stay on 0.37.21, or move to 0.37.25+
   (fixes the dict-slot narrowing quirk and likely the stringified-default
   defect; fixes for #9959/#9944/#9946 will only land on newer versions;
   costs a full re-verification).
6. ~~Wire source of truth~~ **decided 2026-10-10: Jac only, no zod.** Jac
   `obj` types are the single definition; TS consumers get generated
   types (E0).
7. **Node for engines** (A3) — require the user's node, managed download,
   or bundle.
8. **Roots/principals** (A2(h)) — proposed: one workspace root, access
   control in our code.

---

## 18. Sizing (rough, for sequencing — not commitments)

| Phase | TS LOC to replace (excl. tests) | Notes |
|---|---|---|
| A | — | 6 spikes; A1 + A3 are the risky ones |
| B | small | mostly test infra and fixes |
| C | ~26k (index.ts) + ~45k (server core in scope) | C3 is ~⅓ of it |
| D | ~15.4k drivers + ~2.7k helpers | ACP core unlocks 10 kinds |
| E | ~124k client | biggest by volume; mechanical per area |
| F | ~19k Electron + ~4k companion + ~0.35k enterprise + packaging | upstream-gated |
| G | ~11.5k | decision-gated |
| H | deletions | |

Parallelism: see §5 (C4, C5, C8, C10–C14 wait for C3; E areas after
E0/E1; D2 kinds after the ACP core). Use worktrees and the §3 conventions; merge through PR #1's
branch (or per-workstream PRs into it) with CI as the gate.

---

## 19. Appendix — `window.ogb` replacement map (filled in E0/E10)

| `ogb` member | Destination (`@jac/desktop` plugin / sv endpoint / `cl`-only / upstream #) | Owner | Status |
|---|---|---|---|
| _(to be generated from `src/types/ogb.d.ts` in E0)_ | | | |

