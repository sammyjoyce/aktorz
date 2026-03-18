# SQLite Scale Benchmark Design

## Summary

Add a SQLite-focused scale benchmark to `zig build bench` without removing the existing microbenchmark. The benchmark should answer four questions in one local run that fits inside `5–10` minutes:

1. How much mixed SQLite-backed actor traffic can aktorz sustain?
2. How expensive are cold reactivations as actor count and history grow?
3. How do the SQLite database and WAL files grow during the run?
4. Does the runtime stay stable under short soak pressure?

The benchmark should keep one entrypoint and use `--mode` to select behavior. `--mode sqlite-suite` becomes the default. `--mode micro` preserves the current single-actor benchmark for low-level comparisons.

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

`sqlite-suite` becomes the default when the user runs `zig build bench` with no extra arguments. It runs three short phases in sequence: `churn`, `reactivate`, and `soak-short`. The three SQLite-only modes run one phase at a time for tighter investigation loops.

## Benchmark Phases

### Churn

`churn` measures short-run throughput and latency under many actor IDs. It uses a large actor set, a skewed access distribution, mixed reads and writes, and periodic passivation.

This phase answers whether SQLite-backed aktorz can keep up when actors are constantly revisited and recycled.

### Reactivate

`reactivate` measures cold activation cost. It first preloads actors with configurable write history, passivates them, and then times a read-heavy or mixed workload that forces SQLite-backed reactivation.

This phase answers how replay and snapshot behavior scale as historical state grows.

### Soak-Short

`soak-short` runs a mixed workload for the remaining minutes in the local budget. It samples throughput, latency, DB size, WAL size, and error counts at fixed intervals.

This phase answers whether the benchmark remains stable instead of drifting, leaking, or degrading sharply after the initial warmup.

## CLI Design

The benchmark continues to run as:

```bash
zig build -Doptimize=ReleaseFast bench -- --mode sqlite-suite
```

Recommended flags:

```text
--mode <micro|sqlite-suite|sqlite-churn|sqlite-reactivate|sqlite-soak>
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
3. `--sqlite-path` is required for all SQLite modes.
4. `micro` keeps the existing argument model, but it should also be reachable through `--mode micro`.
5. Mode-specific defaults should be sensible so `sqlite-suite` can run with only `--sqlite-path`.

## Workload Model

The benchmark uses a simple counter service so service logic stays cheap and results mostly reflect aktorz and SQLite behavior.

Traffic should not be uniform. The workload should use a skewed key distribution with a hot subset and a long tail. That pattern is closer to a realistic actor workload than a flat random spread.

Operations stay simple:

1. `inc` for writes
2. `get` for reads

Passivation happens on a configurable cadence. Reactivation pressure comes from revisiting passivated actor IDs. History growth comes from preloading a configurable number of writes before the measured phase begins.

## Metrics

Each phase should emit a compact text summary and a JSON summary.

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

### Reactivate Metrics

1. Cold activation count
2. p50 reactivation latency
3. p95 reactivation latency
4. p99 reactivation latency
5. Average replayed mutations per activation
6. Snapshot hit rate
7. Final database size
8. Final WAL size

### Soak-Short Metrics

1. Total elapsed time
2. Periodic throughput samples
3. Periodic p95 latency samples
4. Periodic database size samples
5. Periodic WAL size samples
6. Error count
7. Final operation totals

## Output Format

The benchmark should print a short human-readable summary after each phase. It should also print one JSON block that captures the full run.

The JSON should include:

1. Benchmark version
2. Timestamp
3. Mode
4. Input parameters
5. Per-phase summaries
6. Aggregate success or failure state

The JSON should be easy to redirect into a file for comparison between runs.

## Failure Semantics

The benchmark must exit non-zero if any of these occur:

1. A request returns an unexpected error.
2. Final counter totals do not match expected values.
3. SQLite setup or write operations fail.
4. Duplicate detection behaves unexpectedly.
5. Output invariants for a phase cannot be computed.

The benchmark should not quietly report partial success. A failed phase should clearly identify the phase and reason.

## Implementation Structure

Keep one benchmark source file as the public entrypoint, but split the logic into smaller internal units. The important boundaries are:

1. CLI parsing and mode selection
2. Workload generation
3. Counter service and benchmark actions
4. Phase runners
5. Metrics and histograms
6. SQLite file-size sampling
7. Human-readable reporting
8. JSON reporting

This keeps the benchmark legible and makes it easier to extend without turning `examples/benchmark.zig` into one large file.

## Compatibility

Preserve the current microbenchmark. It remains useful for low-level comparisons and should stay available behind `--mode micro`.

The new SQLite scale suite becomes the default benchmark path because it better reflects the user’s current performance question.

## Verification Plan

Add benchmark-focused tests that cover:

1. Mode parsing
2. Required SQLite path validation
3. Basic churn execution with a tiny actor count
4. Basic reactivation execution with preloaded history
5. JSON emission shape

Verification commands after implementation:

```bash
zig build test
zig build sqlite-test
zig build -Doptimize=ReleaseFast bench -- --mode micro
zig build -Doptimize=ReleaseFast bench -- --mode sqlite-suite --sqlite-path actors-bench.sqlite3
zig build -Doptimize=ReleaseFast bench -- --mode sqlite-reactivate --actors 1000 --history-preload 256 --sqlite-path actors-bench.sqlite3
```

## Open Defaults To Finalize During Implementation

These values can start conservative and be tuned with real measurements:

1. Default actor count for `sqlite-suite`
2. Default duration split across the three phases
3. Default hot-set skew
4. Default passivation cadence
5. Default history preload depth

The implementation should keep these values centralized so they are easy to tune after the first real runs.
