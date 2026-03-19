# AGENTS.md — aktorz

## Build & Test (Zig ≥ 0.16.0-dev.2905, Nix flake included)
- Build: `zig build`
- All core + example tests: `zig build test`
- SQLite + benchmark tests: `zig build sqlite-test` (links system `sqlite3` via libc)
- Run a single test file: add it as a test step in `build.zig`; there is no built-in single-test flag.
- Benchmarks: `zig build bench`

## Architecture
Durable actor framework: lazy activation, single-threaded message processing, pluggable storage.
- `src/core.zig` — core types (`Service` vtable, `Runtime`, `Decision`, `StoreProvider`, `Resolver`, `Forwarder`).
- `src/durable_actor.zig` — public API module re-exporting core + `MemoryNodeStore` + `TinyGateway`.
- `src/memory_store.zig` — in-memory `StoreProvider` for tests/demos.
- `src/sqlite_store.zig` — SQLite-backed store (separate `durable_actor_sqlite` module, links libc+sqlite3).
- `src/tiny_gateway.zig` — framed TCP gateway (`TinyGateway`, `TcpGateway`).
- `examples/` — `cart_example`, `bank_example`, TCP gateways, benchmarks.

## Code Style
- Pure Zig, no third-party deps. Follow stdlib conventions: `snake_case` functions/vars, `PascalCase` types.
- Errors: return `anyerror` from vtable fns; use Zig error unions, not sentinels.
- Use `Allocator` parameter passing (no globals). Free resources with `deinit` methods.
- Keep `Service` implementations as comptime-generic vtable adapters (see `Service.from`).

## Testing & Verification
- Always run `zig build test` (core) **and** `zig build sqlite-test` (SQLite + benchmarks) before committing.
- For benchmark changes, do a short ReleaseFast smoke test:
  `zig build -Doptimize=ReleaseFast bench -- --mode sqlite-churn --duration-seconds 1 --num-actors 100`
- When adding new reporting/output functions, add a corresponding test that exercises the render path.

## Lessons Learned

### Zig Memory Safety
- When a loop allocates slices (e.g. hash-map keys), `errdefer` must free **all prior loop allocations**, not just the container. Walk the loop and free each element.
- Always pair `init`/`deinit`; prefer `defer obj.deinit()` immediately after creation.

### Histogram / Bucket Math
- Bucket index → upper bound must use `(index + 1) * bucket_width`, not `index * bucket_width`. Off-by-one here silently under-reports all percentile latencies.

### Merge Conflict Strategy
- When merging `origin/main` into a feature branch, keep HEAD (feature branch) versions of refactored/simplified files. The feature branch represents the latest intentional state.
- After resolving conflicts, grep for dead code left behind by the losing side (unused structs, functions, imports) and remove it.

### Documentation (Diataxis)
- README should be a **landing page** (navigational), not a reference dump. Route readers to examples, docs, and API instead of mixing tutorial/reference/explanation.
- AGENTS.md stays concise (~30 lines core); use subdirectory AGENTS.md for subsystem-specific guidance.

### PR & CI Workflow
- This repo has **no GitHub Actions CI**. Rely on local `zig build test` / `zig build sqlite-test` and external bot checks (Mesa, Sentry, Gemini).
- PR body: write to a temp file (`/tmp/pr-body.md`) and pass `--body-file` to avoid shell escaping issues.
- Commit messages: use Conventional Commits (`feat(scope)`, `fix(scope)`, `docs(scope)`).
