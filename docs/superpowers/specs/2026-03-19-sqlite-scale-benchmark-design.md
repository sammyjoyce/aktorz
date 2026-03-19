# SQLite Scale Benchmark Design

## Summary

Add a SQLite-focused scale benchmark to `zig build bench` without removing the existing microbenchmark. The benchmark should answer four questions in one local run that fits inside `5–10` minutes:

1. How much mixed SQLite-backed actor traffic can aktorz sustain?
2. How expensive are snapshot-backed cold reactivations after preloaded actor activity?
3. How do the SQLite database and WAL files grow during the run?
4. Does the runtime stay stable under short soak pressure?

The benchmark should keep one entrypoint and use `--mode` to select behavior. `--mode sqlite-suite` becomes the default. `--mode micro` preserves the current single-actor benchmark for low-level comparisons.

For zero-argument usability, `zig build bench` must succeed without user-supplied paths. The implementation should remove the current hard-coded microbenchmark default args and, for SQLite modes, create a temporary database path under `.zig-cache/bench/` when `--sqlite-path` is omitted.

## Goals

Build a repeatable local benchmark that stresses the parts of aktorz that matter most at SQLite-backed scale: activation churn, passivation, replay, snapshots, and file growth.

The benchmark must produce results that are useful for comparison across runs, not just a single headline number. It must emit both human-readable summaries and machine-readable JSON. It must fail loudly if invariants break.

## Non-Goals

This work does not try to build a generic load-testing framework. It does not try to simulate a networked deployment. It does not add concurrency to the runtime, because aktorz is intentionally single-threaded. It does not replace the current microbenchmark.

## Current State

The repository already has a benchmark harness in `examples/benchmark.zig` and a `zig build bench` step. That harness is useful, but it measures one actor at a time. It captures hot and cold behavior for in-memory and SQLite-backed stores, but it does not stress many actor IDs, skewed traffic, long replay chains, or short soak stability.

The runtime path that matters at scale lives in activation lookup and lifecycle handling:

1. `Runtime.request()` resolves the address and queues the message.
2. `getOrActivate()` allocates an object ID, opens the store, loads snapshots, and replays mutations.
3. `processOne()` appends mutations and triggers snapshots.
4. `passivate()` snapshots dirty actors and removes them from the active map.

The scale benchmark should focus on that path.

## Recommended Approach

Keep one benchmark executable and make it support several explicit modes. The executable remains the target behind `zig build bench`.

The top-level modes are:

1. `micro`
2. `sqlite-suite`
3. `sqlite-churn`
4. `sqlite-reactivate`
5. `sqlite-soak`

`sqlite-suite` becomes the default when the user runs `zig build bench` with no extra arguments. It runs three short phases in sequence: `churn`, `reactivate`, and `soak`. The three SQLite-only modes run one phase at a time for tighter investigation loops.

Each `sqlite-suite` phase runs against a fresh SQLite database. That keeps phase results comparable to the standalone phase modes and avoids hidden carry-over state between phases. File-growth metrics are therefore per-phase, not cumulative across the full suite.

Initial default values for the suite are:

1. `--duration-seconds 420`
2. `--actors 10000`
3. `--write-percent 70`
4. Hot-set skew: top `5%` of actor keys receive about `80%` of requests
5. `--passivate-every 64`
6. `--snapshot-every 128`
7. `--history-preload 64`
8. Reactivate preload cohort: `min(actors, 128)` actors

Phase time split for `sqlite-suite` is:

1. `churn`: `180` seconds
2. `reactivate`: `120` seconds
3. `soak`: `120` seconds

Standalone SQLite modes inherit the same phase-local defaults unless the user overrides them explicitly:

1. `sqlite-churn`: `180` seconds
2. `sqlite-reactivate`: `120` seconds
3. `sqlite-soak`: `120` seconds

Those defaults are the first target values, not a promise that total wall-clock completion will stay under `420` seconds on every machine. Final verification and sampling overhead may require post-implementation tuning.

## Benchmark Phases

### Churn

`churn` measures short-run throughput and latency under many actor IDs. It uses a large actor set, a skewed access distribution, mixed reads and writes, and periodic passivation.

This phase answers whether SQLite-backed aktorz can keep up when actors are constantly revisited and recycled.

`--passivate-every` means: after every `N` successful mutating requests, explicitly passivate the actor that was just written. The benchmark should use that exact rule in `churn` and `soak` so results stay reproducible.

### Reactivate

`reactivate` measures cold activation cost. It runs repeated rounds that preload a bounded cohort of actors, passivate them, and then time the first request sent to each actor after passivation.

This phase answers how expensive snapshot-backed cold activation is in the current aktorz runtime.

The current passivation path snapshots dirty actors and compacts their WAL, so the first implementation should treat `reactivate` as a snapshot-dominant benchmark, not a replay-dominant one. Replay counts should still be measured and reported, but large replay tails are not a first-version goal under the existing runtime semantics.

`history-preload` applies per actor in the preload cohort, not across the entire actor set. The preload cohort defaults to `min(actors, 128)` actors so the benchmark stays inside the `5–10` minute budget.

`reactivate` is a time-budgeted phase, not a single fixed-count sweep. It should repeat preload, passivate, and first-read rounds until the phase budget is consumed.

### Soak

`soak` runs a mixed workload for the remaining minutes in the local budget. It samples throughput, latency, DB size, WAL size, and error counts at fixed intervals.

This phase answers whether the benchmark remains stable instead of drifting, leaking, or degrading sharply after the initial warmup.

## CLI Design

The benchmark continues to run as:

```bash
zig build -Doptimize=ReleaseFast bench -- --mode sqlite-suite
```

Recommended flags:

```text
--mode <micro|sqlite-suite|sqlite-churn|sqlite-reactivate|sqlite-soak>
--scenario <memory_hot|memory_cold|sqlite_hot|sqlite_cold>
--ops <u64>
--actors <u64>
--duration-seconds <u64>
--write-percent <u8>
--passivate-every <u64>
--snapshot-every <u32>
--history-preload <u64>
--sqlite-path <path>
```

Rules:

1. `--mode` is the top-level switch.
2. `sqlite-suite` is the default if no mode is given.
3. If `--sqlite-path` is omitted for a SQLite mode, the benchmark creates a temporary database under `.zig-cache/bench/` and prints the path it used.
4. `micro` keeps the existing argument model as a compatibility alias, and it also becomes reachable through `--mode micro` plus an explicit micro scenario flag.
5. The canonical new interface for micro mode is `--mode micro --scenario <memory_hot|memory_cold|sqlite_hot|sqlite_cold> --ops <u64>`.
6. Positional micro scenarios remain supported for backward compatibility during the transition.
7. In `sqlite-suite`, each phase derives its own fresh database path. If the user passes `--sqlite-path actors-bench.sqlite3`, the suite should create phase-local files such as `actors-bench.churn.sqlite3`, `actors-bench.reactivate.sqlite3`, and `actors-bench.soak.sqlite3`.
8. If the first non-flag argument matches a legacy micro scenario name, parse the command in backward-compatible micro mode.

## Workload Model

The benchmark uses a simple counter service so service logic stays cheap and results mostly reflect aktorz and SQLite behavior.

Because the benchmark service snapshot is effectively constant-size, the first implementation should not claim to measure replay-depth sensitivity or snapshot-size growth. It measures cold activation after preloaded write traffic under current aktorz passivation semantics.

Traffic should not be uniform. The workload should use a skewed key distribution with a hot subset and a long tail. That pattern is closer to a realistic actor workload than a flat random spread.

The default key selector should be deterministic. Use a fixed-seed PRNG and a two-bucket distribution: `80%` of requests choose uniformly from the hot set, and `20%` choose uniformly from the cold set. The default seed should be constant so repeated runs are comparable. If a seed override is added later, the benchmark should print the seed in both text and JSON output.

For small actor counts, the workload should clamp the buckets so both remain valid. The hot set should contain at least one actor, and the cold set should contain at least one actor whenever `actors > 1`.

Operations stay simple:

1. `inc` for writes
2. `get` for reads

Passivation happens on a configurable cadence. Reactivation pressure comes from revisiting passivated actor IDs. History growth comes from preloading a bounded actor cohort before the measured phase begins.

The benchmark should treat `history-preload` as a workload-shaping knob, not as a proxy metric. The actual measured cold-start cost must be described with recorded snapshot loads and replayed mutations.

For correctness, the benchmark should keep an in-memory expected counter for every actor it mutates during a measured phase. Final verification runs after the timer stops and is not included in throughput or latency metrics. Each touched actor should be read back and compared against its expected value before the phase is marked successful.

For `reactivate`, the first measured request must be `get`. That keeps the phase focused on cold activation cost instead of mixing in SQLite write-path cost.

Message IDs must also be deterministic and globally unique within a run. The benchmark should use a phase-scoped monotonic `u128` counter with disjoint ranges for preload traffic, measured traffic, passivation-triggering requests, and final verification reads so duplicates cannot silently corrupt results.

For `reactivate`, correctness tracking must include the preload writes that establish actor state before the first measured `get`. Final verification for that phase should therefore compare the measured cohort against preload-derived expected values, not just against traffic issued during the timed window.

## Metrics

Each phase should emit a compact text summary. The benchmark should emit one final JSON document that contains the summaries for all completed phases.

### Churn Metrics

1. Total operations
2. Writes per second
3. Reads per second
4. p50 latency
5. p95 latency
6. p99 latency
7. Actor count touched
8. Passivation count
9. Snapshot count
10. Final database size
11. Final WAL size
12. Final combined database plus WAL size
13. Row counts for `actor_snapshot`, `actor_wal`, and `actor_seen_message`

### Reactivate Metrics

1. Cold activation count
2. p50 reactivation latency
3. p95 reactivation latency
4. p99 reactivation latency
5. Average replayed mutations per activation
6. Snapshot hit rate
7. Final database size
8. Final WAL size
9. Final combined database plus WAL size
10. Row counts for `actor_snapshot`, `actor_wal`, and `actor_seen_message`

### Soak Metrics

1. Total elapsed time
2. Periodic throughput samples
3. Periodic p95 latency samples
4. Periodic database size samples
5. Periodic WAL size samples
6. Periodic combined database plus WAL size samples
7. Periodic row-count samples for `actor_snapshot`, `actor_wal`, and `actor_seen_message`
8. Error count
9. Final operation totals

## Output Format

The benchmark should print a short human-readable summary after each phase. It should also print one JSON block that captures the full run.

The JSON should include:

1. Benchmark version
2. Timestamp
3. Mode
4. Input parameters
5. Per-phase summaries
6. Aggregate success or failure state

When file-size metrics are reported, the JSON should also include the SQLite table row counts so database growth can be interpreted correctly. This is important because `actor_seen_message` retention is intentionally part of the current store design and may dominate file growth.

The JSON should be easy to redirect into a file for comparison between runs.

## Failure Semantics

The benchmark must exit non-zero if any of these occur:

1. A request returns an unexpected error.
2. Final counter totals do not match expected values.
3. SQLite setup or write operations fail.
4. Output invariants for a phase cannot be computed.

The benchmark should not quietly report partial success. A failed phase should clearly identify the phase and reason.

Duplicate detection should remain covered by correctness tests. It is not a primary scale-benchmark failure condition unless the benchmark later adds an explicit duplicate-injection validation mode.

For `reactivate`, the primary latency metric is end-to-end latency of the first request sent to an actor after passivation. Store-level submetrics such as snapshot-load time and replay count come from the instrumentation layer and should be reported separately.

When `--passivate-every` triggers an explicit `runtime.passivate()` call, that passivation work is part of the triggering benchmark step. Its cost should therefore be included in the latency of that step and in phase wall-clock throughput. The benchmark should also report passivation count and cumulative passivation time as separate auxiliary metrics.

When `sqlite-reactivate` runs with `--actors` greater than the default preload cohort size, the first implementation still measures only `min(actors, 128)` preloaded actors. The output must report both the total actor count and the measured reactivation cohort so the cap is visible.

In `sqlite-reactivate`, `--actors` therefore means keyspace size, not measured cold-activation breadth.

## Implementation Structure

Keep one benchmark source file as the public entrypoint, but split the logic into smaller internal units. The important boundaries are:

1. CLI parsing and mode selection
2. Workload generation
3. Counter service and benchmark actions
4. Instrumentation around `StoreProvider` and `ScopedStore` so activation counts, snapshot loads, replay counts, and snapshot writes can be measured explicitly
5. Phase runners
6. Metrics and histograms
7. SQLite file-size and row-count sampling
8. Human-readable reporting
9. JSON reporting

This keeps the benchmark legible and makes it easier to extend without turning `examples/benchmark.zig` into one large file.

The implementation also needs one small SQLite-store addition: benchmark code must be able to set a fixed `wal_autocheckpoint` policy on the same SQLite connection the store uses. The cleanest path is a small `SQLiteNodeStore.Config` expansion for benchmark-only pragmas.

## Compatibility

Preserve the current microbenchmark. It remains useful for low-level comparisons and should stay available behind `--mode micro`.

The current positional micro scenarios should keep working for backward compatibility, but documentation should shift to the new `--mode micro --scenario ...` form.

The new SQLite scale suite becomes the default benchmark path because it better reflects the user’s current performance question.

## Verification Plan

Add benchmark-focused tests that cover:

1. Mode parsing
2. Temporary SQLite path creation when no path is provided
3. Basic churn execution with a tiny actor count
4. Basic reactivation execution with preloaded history
5. JSON emission shape
6. Backward-compatible micro scenario parsing

Verification commands after implementation:

```bash
zig build test
zig build sqlite-test
zig build -Doptimize=ReleaseFast bench
zig build -Doptimize=ReleaseFast bench -- --mode micro --scenario memory_hot --ops 1000000
zig build -Doptimize=ReleaseFast bench -- --mode sqlite-suite --sqlite-path actors-bench.sqlite3
zig build -Doptimize=ReleaseFast bench -- --mode sqlite-reactivate --actors 1000 --history-preload 256 --sqlite-path actors-bench.sqlite3
```

The implementation should keep the default values centralized so they are easy to tune after the first real runs.

If the user overrides `--duration-seconds` for `sqlite-suite`, phase durations should scale proportionally to the default `3:2:2` split for `churn`, `reactivate`, and `soak`. The benchmark should round to whole seconds and guarantee at least `30` seconds per phase.

If `sqlite-suite` receives `--duration-seconds` lower than `90`, it should reject the run with a clear error instead of violating the minimum per-phase duration.

When the user supplies a duration between `90` and the exact proportional threshold, the `30`-second minimum per phase overrides strict proportionality. Any remaining seconds should then be distributed in `3:2:2` order across `churn`, `reactivate`, and `soak`.

## SQLite Sampling Rules

File-size metrics need stable collection rules. The benchmark should:

1. Sample file sizes while the SQLite handle is open.
2. Report missing WAL files as `0` bytes instead of treating them as errors.
3. Set a fixed checkpoint policy for benchmark runs by forcing `PRAGMA wal_autocheckpoint=0` and reporting that policy in the output.
4. Avoid manual checkpoints during measured phases unless a future mode explicitly tests checkpoint behavior.
5. Report `db_bytes`, `wal_bytes`, and `total_bytes` together.
6. At the start of each phase, begin from a freshly created database so file-growth metrics start from a known baseline.
7. Use a fresh unique SQLite path for every auto-generated run.
8. If the user supplies `--sqlite-path` and the database, WAL, or SHM files already exist, refuse to run and ask for a fresh path instead of deleting user data automatically.

## Soak Sampling Rules

The `soak` phase should sample every `10` seconds. Throughput and p95 latency samples should describe the immediately preceding interval, not the full run-so-far, so short-term drift stays visible.

Sampling work should happen at interval boundaries. Sampling queries and file stats should be excluded from latency histograms, but they remain part of the phase wall-clock time so interval throughput reflects observer overhead as well as workload cost.
