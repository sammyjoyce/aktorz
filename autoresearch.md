# Autoresearch: SQLite benchmark performance

## Objective
Reduce end-to-end wall-clock time for the default SQLite benchmark suite (`zig build -Doptimize=ReleaseFast bench -- --mode sqlite-suite`) while preserving benchmark correctness and runtime semantics.

## Metrics
- Primary: Wall-clock benchmark duration (seconds, lower is better)
- Secondary: Churn throughput (`writes_per_second`, `reads_per_second`), reactivate p95 latency (`p95_latency_ns`), soak throughput samples (`ops_per_second`), test pass/fail status

## How To Run
`./autoresearch.sh`

## Files In Scope
- `examples/benchmark/cli.zig` — benchmark argument parsing and path setup
- `examples/benchmark/scale.zig` — suite phase execution and workload behavior
- `examples/benchmark/report.zig` — reporting overhead and output shape
- `examples/benchmark/instrumentation.zig` — benchmark store instrumentation
- `src/sqlite_store.zig` — SQLite store internals used by benchmark runs
- `build.zig` — benchmark wiring only when needed for performance work

## Off Limits
- Public API changes unrelated to benchmark/store performance goals
- New third-party dependencies
- Non-benchmark feature work

## Constraints
- Keep benchmark behavior deterministic and reproducible
- Preserve benchmark correctness checks and failure semantics
- `zig build test` must pass
- `zig build sqlite-test` must pass
- No data-loss shortcuts for user-provided `--sqlite-path`

## What's Been Tried
- Session initialized on branch `autoresearch/sqlite-benchmark-performance-2026-03-19`.
- Baseline (`fbfed46`, no benchmark code changes):
  - Command: `./autoresearch.sh`
  - Result: success
  - Primary metric: `804.491s`
  - Key phase stats: churn `6274 ops`, reactivate `128 cold activations`, soak `5090 ops`
  - Checks: `./autoresearch.checks.sh` passed
- Experiment 1 (`600fc18`, reactivate deadline-aware batching in `examples/benchmark/scale.zig`):
  - Change: stop scheduling new reactivate actors once the phase deadline is reached; measure only actors preloaded in the current batch; remove forced cohort touch-marking.
  - Result: success
  - Primary metric: `493.145s` (**improved by 311.346s, 38.70% faster**)
  - Key phase stats: churn `92652 ops`, reactivate `563 cold activations`, soak `74408 ops`
  - Checks: `./autoresearch.checks.sh` passed
  - Keep decision: **keep**
- Experiment 2 (discarded, uncommitted):
  - Change attempted: add per-write deadline checks inside reactivate preload loop to reduce end-of-phase overrun further.
  - Result: success
  - Primary metric: `524.458s` (**31.313s slower** than kept run)
  - Key phase stats: churn `102654 ops`, reactivate `826 cold activations`, soak `74447 ops`
  - Checks: benchmark run passed
  - Keep decision: **discard** (restored `examples/benchmark/scale.zig` to `HEAD`)
