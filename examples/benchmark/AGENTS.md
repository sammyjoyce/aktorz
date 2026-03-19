# AGENTS.md — examples/benchmark/

## Structure
- `benchmark.zig` — entry point, delegates to `cli`, `micro`, `scale`, `report`.
- `cli.zig` — CLI arg parsing (`--mode`, `--duration-seconds`, `--num-actors`, etc.).
- `micro.zig` — micro-benchmark (fast in-memory operations).
- `scale.zig` — SQLite scale suite (churn / reactivate / soak phases).
- `histogram.zig` — latency histogram with percentile reporting.
- `report.zig` — human + JSON output rendering.
- `instrumentation.zig` — timing and metrics collection.

## Key Conventions
- `--mode micro` is backward-compatible; `--mode sqlite-churn|sqlite-reactivate|sqlite-soak` for individual phases.
- Workload uses fixed-seed skewed distribution (80% hot / 20% cold actors).
- Suite auto-creates DB paths under `.zig-cache/bench/`; rejects existing DB/WAL/SHM files.
- Post-run verification: in-memory expected counters vs DB actuals.

## Common Pitfalls
- **Histogram bucket bounds**: `bucketUpperBoundNs` must use `(index + 1) * width`, not `index * width`. The off-by-one silently under-reports p50/p95/p99 by ~1µs.
- **Loop allocation errdefer**: `scale.zig` `Workload.init` allocates keys in a loop. `errdefer` must walk and free all prior allocations, not just the container slice.
- **WAL growth**: With `wal_autocheckpoint=0`, WAL grows unbounded (~800MB+ for 180s churn). This is expected during benchmarks.

## Verification
- `zig build sqlite-test` runs all benchmark tests.
- Short smoke: `zig build -Doptimize=ReleaseFast bench -- --mode sqlite-churn --duration-seconds 1 --num-actors 100`
- When adding new report output, always add a test in `benchmark_test.zig` for the render path.
