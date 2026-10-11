# A2 spike — persistence on the graph store (2026-10-11, part 1)

Status: **(a) and (b) proven; (c) measured against thresholds — fails without
upstream fixes; (d)–(k) open** (schema-dependent items move to C2-model).
Pin: jac 0.37.25, sealed install. Machine: 16-core/14 GB Linux x86_64, NVMe.
Test vehicle: `~/a1-spike` jab with colocated service, fully isolated
`JAC_CACHE_HOME` (empty at start) + `JAC_PG_DIST` (pre-provisioned dist).

## (a) Offline first run — PASS

`JAC_CACHE_HOME=<app-data>/jac-cache` (fresh) + `JAC_PG_DIST=<dist>` +
private `TMPDIR`: **cold first launch to first 200 = 12.0 s** (< 20 s budget).
Log contains zero fetch/download lines; the runtime re-extracts from the
binary payload (no network), initdb runs from `JAC_PG_DIST`, the cluster lands
in `<JAC_CACHE_HOME>/pg/main`. The `postgres 19 not yet published` warning
disappears when the dist is pinned. **F2 requirement met app-side today:
bundle the dist, set `JAC_PG_DIST` + `JAC_CACHE_HOME` from the host/launcher.**

## (b) Per-app isolation — PASS with a cost; precise #9944 ask identified

- The pg bucket (`jaclang/cache/registry.jac` Bucket name="pg") has **no
  `root_env` override** → the cluster is always `<cache_home>/pg/main`
  (`session.impl.jac shared_pg_data_dir = dirname(dist_cache_dir())/main`),
  one cluster machine-wide, databases namespaced per project
  (`jac_<safe>_<sha1[:8]>`).
- The only working isolation lever is **`JAC_CACHE_HOME`**
  (`jac0core/cache_paths.py get_cache_home`: `JAC_CACHE_HOME` → `XDG_CACHE_HOME/jac`
  → platform default). Proven: private cluster + private socket dir
  (`<TMPDIR>/jacpg-<sha1(data_dir)[:10]>`) under app data.
- **Cost:** the same root holds the runtime extraction (~830 MB) and
  toolchains — per-app `JAC_CACHE_HOME` duplicates them per app.
- **Upstream ask (add to #9944):** a `root_env` on the pg bucket (e.g.
  `JAC_PG_DATA_DIR`) so the cluster + socket live under the app data dir
  while the runtime cache stays shared. Everything else (fetch fallback,
  lock file `<data_dir>.lock`, `dist_cache_dir()/dist`) already keys off the
  data dir or dist env.

## (c) Write throughput at turn-event rates — FAILS thresholds on 0.37.25

Thresholds (plan §6 A2): append p95 < 25 ms at 60 events/s sustained 10 min,
< 1 % conflict replays. Measured:

- **Per-request floor:** sequential trivial write (`bump`, one transaction,
  no traversal) **p50 29.7 ms / max 66 ms** — the per-request embedded-PG
  setup + envelope cost (#9959: `ensure()` re-runs per request, two
  transactions; #9411: walker requests commit three times, re-hashing every
  loaded anchor). The floor alone exceeds the p95 budget.
- **Sustained ~60/s walker appends** (fresh cluster, `Tick` node + edge per
  request, `len([root -->])` read per request): latency climbs 50 → 300 ms →
  seconds within ~40 s; curl 5 s timeouts by request ~90. Queue collapse,
  not errors — the server drains slower than 60/s once the root
  neighborhood grows (the per-request O(n) traversal is ours; a real C2
  schema would not scan).

**Conclusions:** (1) #9959 + #9411 are hard blockers for the graph store on
the streaming-turn hot path — they were already U2 targets; this quantifies
them (≈30 ms floor vs 25 ms budget). (2) C2's schema must keep appends
O(1) (tail-pointer `Next` edges, no root scans) and coalesce commits per
message, never per delta (plan §6 A2(g) already says this — now measured).
(3) Re-measure after the U2 fixes; only then expect the threshold.

## (d)–(k) — open, sequenced into C2-model

(d) 100k-message thread pages/search latency — needs the C2 node/edge schema
+ importer; (f) messages.db FTS → Postgres FTS vs derived sqlite — decide in
C2-model with (d)'s numbers; (g) commit API for out-of-request writers
(driver reader threads, `@schedule`) — design with (c)'s numbers;
(h) roots/principals — decided (§17 #8, one workspace root); (i) schema
evolution — aliases on every persisted archetype from day one (§2.2);
(j) files on disk canonical — decided (A2(j)); (k) bundled PG lifecycle
(pg_upgrade across app updates, vacuum) — design with F2.

## Machine-room notes for F2

- The launcher/host must set, before the store boots: `JAC_PG_DIST`
  (bundled dist), `JAC_CACHE_HOME` or the #9944 pg override (cluster under
  app data), `TMPDIR` (socket dir derivation uses it).
- `jac db` CLI subcommands exist (`cli/commands/impl/db.impl.jac`) — likely
  useful for backups (C2b) and maintenance; inventory later.
