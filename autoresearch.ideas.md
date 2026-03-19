# Deferred Ideas

- Add explicit per-phase wall-clock metrics (`phase_elapsed_seconds`) to the JSON report so wall-time regressions can be attributed to timed workload vs post-phase verification overhead.
- Prototype a benchmark-only verification mode that compares expected counters against persisted state in bulk (store-side aggregation) to quantify potential verification-time savings before considering any semantics change.
- Add an optional `--verify-level` flag (`strict`, `smart`) where `strict` keeps current behavior and `smart` uses optimized verification; keep `strict` as default unless data shows no correctness tradeoff.
