# Jac harness profiling (2026-10-10)

Branch measured: `jac/codebase-migration` at `9a2057f` (openai-chat + computers
ports in), with some numbers from the earlier tip `a9ca900`. Toolchain: jacup pin
0.37.21. Host: 16 cores, 14 GB RAM, shared with other agents. Load average ran
15–35 for most runs and spiked to 214, with swap 21/23 GB and OOM kills, around
10:35. All wall times are inflated by that load. **CPU seconds** (from
`getrusage`/`process_time` inside the compiler process) are the numbers to
trust; the compile is single-threaded, so on an idle box wall time ≈ CPU time.

## Numbers

| What | Measured | Method |
|---|---|---|
| Cold `jac run` compile, `a9ca900` | 182 s wall (load 15–30) | `jac run --no-client` in a fresh worktree, timed until `routine_state` answered 200 |
| Cold compile, `9a2057f` | **289 s wall / 289 s CPU** (load 17–21); a 2nd run took 442 s wall / 294 s CPU (load 31–56) | same, run in-process via `jac -P` with `compile_progress` hooks |
| Cold compile, `9a2057f`, **test annexes removed** | **126–129 s CPU** (−56%) | copy of `jac/harness` without `*.test.jac` |
| Peak RSS of one cold compile | **3.3 GB** | `ru_maxrss` |
| Warm boot (prepared-app cache hit) | 1.5–2.3 s to first answered op (8 s once at load ~30) | 3× on each base |
| Touch a non-`.jac` file (`conformance/ops.json`) | **full recompile, 352 s** | `touch`, then boot |
| node→Jac trivial op (`health`, `routine_state`, `webhook_list`), node `fetch` the way `jacOpRaw` does it, serial | p50 **39–68 ms**, p95 75–125 ms, ~20 ops/s serial, 25–50 ops/s with 8 in flight | 300–400 calls per op, 4 runs |
| …of which the Jac server's per-request Postgres session setup | **~75–80%** of busy handler time | thread sampler at 5 ms inside the served process |
| Jac→node `driver_event` bridge (driver_stub, 1,000 `content.delta` events, minimal node receiver) | **790–1,280 events/s, 0.8–1.3 ms/event**; ~99% of that is in `urllib` (new TCP connection each time) | `bridge_recv.mjs`, 6 runs |
| Real Claude stream rate | sonnet 30 deltas/s, haiku 35 deltas/s, peaks of ~60/s (15 in 250 ms), about 12 chars each | `claude -p --output-format stream-json --include-partial-messages` |
| Other ops during a 1,000-event burst | `webhook_list` p50 42–48 ms, the same as idle | pinger running beside the burst |
| `driver_claude._handle_line` (text delta, bridge stubbed) | ~38 µs under cProfile, ≤107 µs wall at load; `json.loads` is 3.4 µs | in-process microbench |
| `routines._save` serialization at MAX_RUNS (2,000 runs, 1.6 MB) | **284 ms**, against 29 ms for `json.dumps(indent=2)` | `_js_pretty` microbench |
| `routines._tick_body`, 50 routines, none due, 2,000 terminal runs | **125–227 ms per tick** (2.0 M `dict.get` calls) | microbench + cProfile |

## 1. Compile time: where it goes

**Per module (CPU s, `9a2057f`, with annexes).** Each module is compiled
**twice**. Pass 1 (56 s) is `harness.jac` pulling in its imports. Pass 2
(209 s, 79%) is `compile_application`'s breadth-first walk calling
`program.compile(dep)` again for every import under a per-module
`bind_options` context.

| module | base lines | test lines | pass1 | pass2 | total | ms/line |
|---|---|---|---|---|---|---|
| routines | 4354 | 3498 | 7.8 | 36.1 | 43.8 | 5.6 |
| container_computer | 1380 | 1029 | 6.5 | 22.1 | 28.5 | 11.9 |
| connectors | 2328 | 1217 | 4.6 | 20.7 | 25.3 | 7.1 |
| driver_openai_chat | 1441 | 2313 | 7.6 | 15.0 | 22.6 | 6.0 |
| workspace_backup | 2357 | 795 | 4.1 | 17.6 | 21.7 | 6.9 |
| driver_codex | 1566 | 1878 | 4.5 | 15.1 | 19.6 | 5.7 |
| team_backup | 1117 | 524 | 4.3 | 13.0 | 17.3 | 10.5 |
| mcp_oauth | 1484 | 1145 | 2.9 | 9.4 | 12.3 | 4.7 |
| webhooks | 947 | 400 | 3.2 | 8.7 | 11.8 | 8.8 |
| driver_claude_support | 1457 | 0 | – | 11.8 | 11.8 | 8.1 |
| driver_claude | 1995 | 0 | 2.1 | 8.0 | 10.1 | 5.1 |
| 15 smaller modules | | | | | ~37 | 2–6 |

The same table without annexes: routines 17.2, workspace_backup 11.4,
connectors 9.6, container_computer 9.0. Base code costs about **4 ms CPU per
line**. Test-annex code costs about **7–19 ms per line**.

**Superlinear or not?** No per-module superlinearity: the largest module
(routines, 7.8k lines) is 5.6 ms/line, and the worst per line is a 2.4k-line
module. The whole build tracks reachable lines, with annex lines weighted about
2×:

- `a9ca900`: ~30.7k lines took ≤182 s.
- `9a2057f`: 42.1k lines (28.1k base + 14.0k annex) took 289 s CPU.

The two new ports added 11.3k lines, 40% of them tests, which explains most of
the jump. The reported 581 s was taken while the machine was swapping (load
>100). At similar load our CPU-time measurement is 289 s. Modules that
`harness.jac` does not import (store, emoji_rgi, memory, sessions, checkpoints,
lease: 13.9k lines) are not compiled at boot.

**Where the compiler spends its time.** From 1,425 stack samples at 200 ms
(`9a2057f`):

| Phase / cost | Share |
|---|---|
| analysis (type checker) | 51% |
| codegen | 13% |
| ir | 12.5% |
| parse | 10% |
| boundaries | 8% |
| Inside the analysis phase: `get_type_of_expression` | 35% |
| Inside the analysis phase: `load_dependency_module` (type-checking imports) | 16% |

- 44% of samples have the Jac OSP runtime as the leaf (`hop0`,
  `light_connect`, `next_slot`): compiler passes run as walkers, and the
  traversal overhead dominates.
- 8% are filesystem stats (`realpath`, `isfile`, `exists`, `iterdir`).

These are upstream compiler costs, not ngai constructs.

**What invalidates the cache**
(`jaclang/compiler/driver/application.jac::_prepare`):

- The prepared-application key includes `_inventory(root)`: the
  `(mtime_ns, size)` of **every file under `jac/harness`** except `.jac/`,
  dot-dirs, `*.db` and `*.log`. That includes `conformance/*.mjs`,
  `fixtures/*.ombbackup` and the test annexes.
- Any edit or `touch`, a `git checkout`, a fresh worktree, or a CI checkout
  (git does not preserve mtimes) is a miss.
- A miss reruns **the whole** compile. The per-module `.jir` files in
  `.jac/cache/<gen>/` did not shorten it: touching one non-Jac file cost 352 s.
- The key also includes the compiler generation, so changing the jacup pin
  forces a recompile.

**Precompile or packaging step.** `jac build -a sealed|jab` produces a sealed
image. `prepare_application` takes the `_prepare_sealed` path ("Loading sealed
application artifacts") with no compile and no mtime key. **Not measured:** the
build was SIGKILLed under memory pressure and runs were then halted. The CI job
below measures it.

## 2. Op round trip: where the 40–60 ms goes

Instrumenting `PgStore._run` showed what every `def:pub` call does, including
`health`, which touches no graph:

- **2 serializable transactions per request**: BEGIN, SET LOCAL, 2 doc
  SELECTs, 2 root-id SELECTs, COMMIT.
- **BEGIN costs 12–22 ms.** Sampling attributes ~85% of that to
  `PgStore._ensure_ready → PgRuntime.ensure()`, which on every request:
  1. stats the pidfile;
  2. opens a fresh connection (`_wait_ready`);
  3. opens an **admin** connection;
  4. writes `record_database`.
- The cause: `Session.postinit` (`server/impl/session.impl.jac:336`) builds a
  **new `PgStore` per session with `ensure_cb=runtime.ensure`**, and the
  `_ready` memo lives on that short-lived store.
- Setting `JAC_DB_URL` skips this path, but `conninfo_from_url` cannot express
  the embedded daemon's unix socket, so that is not a usable app-side
  workaround today.

HTTP plus JSON in node is a small part of the time: the client's p50 roughly
equals the server-logged handler time. Our own code (`_guard`, the op body) is
in the noise for these ops. **Projected after an upstream fix**, without the
per-request ensure: about 10–14 ms per op (estimate, not measured).

## 3. Jac→node bridge

- Each event takes about 1 ms on the Jac side. Event construction, `uuid` and
  `createdAt` together cost about 8 µs; nearly all of the time is in
  `urllib.request.urlopen`, which builds an opener and opens a new TCP
  connection per POST.
- Capacity is 800–1,300 events/s from one turn, against Claude's 30–35/s
  average and ~60/s peak: **15–40× headroom, so the per-event POST is not a
  bottleneck**. It also did not slow other ops during a burst.
- **Not measured:** node's real `/api/internal/routine-bridge` handler plus the
  EventBus/SSE fold per event. We used a minimal receiver; the real handler is
  JSON parse, token compare and listener dispatch.
- **Bug found:** `drivers._now_iso` combines `time.gmtime()` (seconds) with a
  *second* `time.time()` call for the milliseconds. When the two straddle a
  second boundary, `createdAt` is ~1 s **earlier** than the real time. We saw
  a lag max of exactly 1001 ms in every run, so event timestamps can go
  backwards.

## 4. Python hot paths

- **`routines._tick_body` step 3 is O(runs²).** For each run id it linearly
  rescans `_state["runs"]` to find the run, even when nothing is queued. At
  2,000 runs a tick costs 125–227 ms, and it runs every 10 s while holding the
  GIL (other sync handlers stall).
- **`routines._save` → `_js_pretty` takes 284 ms at 2,000 runs** (10× slower
  than `json.dumps`). The time goes to `jsutil.js_string`'s per-character
  `ord` loop. `_save` runs on every mutation (17 call sites). Webhook
  enqueue/receive goes through routines' state too, so it pays the same cost
  (inferred, not separately measured).
- `driver_claude._handle_line` takes ~40 µs per line and is not a concern.

## Recommendations (ranked by impact / effort)

1. **Stop compiling test annexes at boot: −56% cold compile CPU (289 → 128 s)
   and less peak RSS.**
   - Effort: low to medium.
   - Evidence: the no-annex run above.
   - Options:
     - Move `*.test.jac` out of the served project root, e.g. into
       `jac/harness-tests/` with a stub base, as AGENTS.md §5 already describes
       for cross-module tests.
     - Or fix upstream so `jac run`/`compile_application` skips annexes whose
       name matches a test pattern.

   Moving them also stops test edits from invalidating the serve cache.
2. **Ship a precompiled sealed image instead of compiling at boot.**
   - Effort: medium.
   - Evidence: a cache miss on every checkout, `_prepare_sealed` skips the
     compile, and warm boot is 1.5–2.3 s against 289 s.
   - In CI/packaging, run `jac build -a sealed` once per commit. Have
     `jac-routines.ts` spawn `jac run <image>` when one is present for the
     current tree hash.
   - Also narrow the cache inventory: keep non-Jac files (`conformance/`,
     `fixtures/`) out of `jac/harness`, or fix upstream to key by content hash
     of the imported sources, not every file's mtime.
3. **Upstream jaclang fix: memoize embedded-PG `ensure()` per process (or
   share one `PgStore`/pool across sessions).**
   - Effort: low upstream.
   - Evidence: ~75–80% of every op's latency, 12–22 ms per BEGIN times two.
   - Expected: ~40–60 ms → ~10–14 ms per op; jacOp serial throughput ~20 →
     ~70–100 ops/s.
   - This is a jac defect under AGENTS.md §3: a minimal repro is any
     `def:pub` that returns a constant.
   - Also ask why a stateless `def:pub` opens two transactions.
4. **Upstream compiler: stop the second per-module compile in
   `compile_application`.**
   - Effort: medium, upstream.
   - Evidence: pass 2 is 79% of compile CPU and recompiles modules that pass 1
     already loaded.
   - If pass 2 cannot reuse pass-1 modules (different context key from
     `bind_options`), roughly halving cold compile looks plausible (estimate).
     The OSP-walker pass overhead (44% of samples) is a longer-term upstream
     item.
5. **Fix two O(n) costs in `routines.jac`.**
   - Effort: low.
   - Evidence: the microbenchmarks above.
   - In tick step 3, iterate a snapshot list of runs and skip non-queued runs
     before any lookup.
   - Make `js_string` fast-path ASCII strings without control characters (for
     example, `json.dumps`, with the JS-escaping differences handled
     separately) so `_save` stays byte-identical.
   - Also fix the `_now_iso` timestamp bug (one `time.time()` call).

   The bridge (one POST per event) should stay as it is. If it is ever
   revisited, reuse a keep-alive `http.client` connection rather than adding
   batching.

## Gaps (not measured) and the CI job that would measure them

Not measured locally (machine out of RAM; runs halted by request):

- `jac build -a sealed` time and the boot time from the sealed image;
- cold compile on an idle machine;
- whether editing one `.jac` file vs one `.test.jac` file differs (expected to
  be the same full recompile, given the inventory key);
- the cost of node's real bridge handler;
- op latency after an upstream PG fix.

A `workflow_dispatch` job (`ubuntu-latest`, 4 vCPU / 16 GB, idle) would cover
most of them:

1. Check out the branch. Install jacup 0.37.21. Cache `~/.cache/jac/rt` and
   `~/.cache/jac/pg`, keyed on the pin.
2. `cd jac/harness && /usr/bin/time -v jac run --no-client -p 47400` with
   `OMB_DATA_DIR=$RUNNER_TEMP/d`; poll `POST /function/routine_state` until it
   answers 200. Record wall, CPU (user+sys) and max RSS. That is the cold
   compile.
3. Restart and record time to first 200. That is the warm boot.
4. `touch jac/harness/webhooks.test.jac`, restart, record. That is
   annex-edit invalidation.
5. `jac build -a sealed -o $RUNNER_TEMP/img` under `/usr/bin/time -v`, then
   `jac run $RUNNER_TEMP/img/... --no-client` and record time to first 200.
   That covers the precompile build time and the sealed boot.
6. Run step 2 again with `jac/harness/*.test.jac` deleted. That gives the
   no-annex compile on an idle runner.
7. Run `node opbench.mjs` (300 calls each of `health`, `routine_state`,
   `webhook_list`) and `bridge_recv.mjs` (1,000 events) against the warm
   harness.
8. Upload all timings as a JSON artifact.

The scratch scripts used here (`compile_prof.py`: per-module compile hooks
through `compile_progress`; `serve_prof.py`: in-process thread sampler plus
`PgStore._run` counter; `opbench.mjs`; `bridge_recv*.mjs`; `hotpaths.py`;
`routinebench.py`) are in the session scratchpad and not committed. They run
inside the jac binary via `jac -P <script>`, since `py-spy` could not keep up
with the jac binary (it lagged hundreds of seconds behind) and the `ptrace`
scope blocks attaching.
