# A1 spike — desktop app topology (2026-10-11)

Status: **findings recorded; spike partially blocked upstream** (see F5/F6).
Pin: jac **0.37.25** (jacup, sealed install). Machine: 16-core/14 GB Linux
x86_64. Workspace: `/home/jac/a1-spike/` (desktop + web-app + service apps;
hello-world exercising every sv capability we need).

## Findings

**F1 — every sv capability the harness needs works on 0.37.25.** Proven
against `jac run harness` (direct) and, except where noted, through a
colocated gateway: `def:pub` endpoints (enveloped JSON); module globals
mutated by a request visible to the next (`bumps` 0→1→2 across POSTs);
persistent graph walkers (`Tick` nodes under `root` via `++>`, traversal
`[root -->][?:Tick]`); SSE via `async def` generator (auto
`text/event-stream` + `event: end` trailer); long-running subprocess with
stdout streamed incrementally over SSE (`asyncio.create_subprocess_exec` +
`async for` on `proc.stdout`); static `@schedule(trigger=STATIC, interval=2)`
fired 153× in ~5 min without APScheduler (dynamic scheduling needs the
`scheduler` capability).

**F2 — REST surface: `@restspec` is real but has a colocation gap.**
`@restspec(method=HTTPMethod.GET, path="/spike/items/{item_id}")` mounts
custom methods + path params on `walker:pub`/`def:pub` (`envelope=False` and
`produces=` for verbatim bodies), and works on a directly-served app (GET and
DELETE verified). **Gap:** under colocation the custom path is served nowhere
— neither `/api/<svc>/spike/items/7` nor bare `/spike/items/7` (only
`/function/` and `/walker/` are re-prefixed). C0's planned fallback (a single
Jac dispatcher endpoint mapping today's paths onto `def:pub`s) is required,
not optional. File upstream. Also noted: GET on a default `/walker/<name>`
path answers 200 (GET side effects possible) — review for C1 security.

**F3 — dev colocation (topology (c) works in dev).** `[apps.backend]
kind="web-app"` + `[apps.harness] kind="service"`: `jac run backend` logs
`✔ colocated service 'harness'` and serves `/api/backend/function/*` and
`/api/harness/function/*` from one process/port; SSE streams through the
gateway; module globals are app-local (per apps.md, colocated apps get
distinct copies of shared-source modules).

**F4 — release colocation + numbers.** `jac build backend` →
`dist/a1spike.jab` (134,532 bytes; runtime external to the artifact). The
sealed image colocates the service (`jac run dist/a1spike.jab`):
`/api/harness/function/*` answers, module-global persistence holds. Numbers
(quiet 16-core box, machine-warm embedded Postgres): **warm launch to first
200: 2.3 s**; trivial op (`POST /function/backend_hello` round-trip):
**p50 26.6 ms / p95 30.2 ms** — includes envelope + fresh route dispatch;
consistent with #9959's per-request embedded-PG overhead (fix upstream).
Offline first run **not yet proven**: first run logs `postgres 19 not yet
published to the embedded channel; using 18 (set JAC_PG_DIST to override)` —
the embedded PG comes from a downloaded distribution (#9944). JAC_PG_DIST
provisioning is A2 spike scope (a).

**F5 — desktop builds crash on multi-app workspaces (upstream defect, fix in
flight).** `jac build` / `jac run desktop` (dev AND release):
`AttributeError: 'AppConfig' object has no attribute 'has_server'` at
`jaclang/client/targets/desktop/desktop_build.jac:287` (`serving_app_for`)
— `has_server` lives on `KindSpec`, not `AppConfig`; use
`kind_has_server(chosen.kind)`. Reproduced in dev and build; blocks every
desktop run for a workspace with a backend app. Fix PR'd upstream
(agents/UpstreamDesktopFix; update link on merge). **Sealed installs cannot
be source-patched**: the runtime serves only `_precompiled/*.jir`;
`JAC_NO_SEAL=1` is rejected ("sealed installs have no source fallback tier").
Consequence: toolchain fixes reach us only via upstream releases or a local
source build of jac.

**F6 — topology (a) (desktop + service only) is impossible on 0.37.25, even
with F5 fixed — #9946 confirmed with code refs.** Two independent gates:
1. `jaclang/dist/seal.jac:85-89` (`build_serve_manifest`): colocated service
   apps are prepared only when the *selected* app `has_server`; desktop
   `has_server=False` → no services prepared.
2. `desktop_build.jac serving_app_for`: the embedded-backend fallback picks
   the default app if it has a server, else the first **`web-app`** sibling
   (loop checks `kind == "web-app"` only), else the desktop app itself. A
   declared `service` app is never chosen.

**F7 — ports.** `-p` is ignored for workspace app runs (binds 8001). The
plan's deterministic per-app port (§2.1) needs upstream support or a
`[serve] port` per app — verify `[apps.<name>.serve] port` overlay works;
fold into #9946 work.

**F8 — native seal requires `with entry`.** `jac build` of an app whose entry
lacks a `with entry { }` block fails native compilation ("No entry point
found"). Our sv entries need one.

**F9 — first-run data locations.** The jab run wrote under the machine jac
dirs (`~/.cache/jac/...`; embedded PG cluster shared machine-wide at
`~/.cache/jac/pg/main`). Per-app isolation is exactly #9944; A2(b) must set
`JAC_PG_DIST` + cluster dir via the host.

## Decision input (plan §2.1 / §17)

- Adopt **topology (c)** as the working A1 layout: `app/` workspace with a
  thin `web-app` backend (has_server) + `harness` service colocated under it
  + `desktop` app whose host picks the backend. All Phase C ports target this
  shape; it works in dev and release today (F3/F4) once F5's fix lands.
- Revisit (a) when #9946 lands (U2) — desktop-native serving of service apps.

## Still open for A1's "done when"

- Release binary runs from CI artifacts on Linux x86_64 and macOS arm64
  (blocked on F5's fix + a CI runner; macOS needs signing env).
- dev ≡ build scripted check (do after F5 lands).
- Offline first run (A2(a), JAC_PG_DIST), localStorage persistence, cold
  first launch < 20 s incl. Postgres init, first-token latency, idle RSS.
- The cl page calling colocated endpoints (client bundling worked — Vite
  2.8 s; the cross-app call from `cl` is E0 scope).
