# AGENTS.md — aktorz

## Build & Test (Zig ≥ 0.16.0-dev.2905, Nix flake included)
- Build: `zig build`
- All core + example tests: `zig build test`
- SQLite + benchmark tests: `zig build sqlite-test` (compiles the bundled SQLite amalgamation)
- Run a single test file: add it as a test step in `build.zig`; there is no built-in single-test flag.
- Benchmarks: `zig build bench`

## Architecture
Durable actor framework: lazy activation, single-threaded message processing, pluggable storage.
- `src/core.zig` — core types (`Service` vtable, `Runtime`, `Decision`, `StoreProvider`, `Resolver`, `Forwarder`).
- `src/durable_actor.zig` — public API module re-exporting core + `MemoryNodeStore` + `TinyGateway`.
- `src/memory_store.zig` — in-memory `StoreProvider` for tests/demos.
- `src/sqlite_store.zig` — SQLite-backed store (separate `durable_actor_sqlite` module; links libc + the bundled SQLite amalgamation).
- `src/tiny_gateway.zig` — framed TCP gateway (`TinyGateway`, `TcpGateway`).
- `examples/` — `cart_example`, `bank_example`, TCP gateways, benchmarks; `examples/typescript/` holds runnable TS examples (own npm package, `aktorz` via `file:../..`, run with `node <file>.ts` on Node 23.6+ or Bun, typecheck with `npm run check`).

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

### Zig 0.16 Stdlib API Gaps
- `std.fmt.allocPrintZ` does not exist — use `std.fmt.allocPrint` then `dupeZ` if a sentinel-terminated slice is needed.
- `std.c.time(null)` is unavailable — use `std.posix.gettimeofday()` and read `.sec` from the `timeval`.
- `fstatat` returns void for errno — use `std.fs.Dir.cwd().statFile(path)` instead for file size queries.

### Histogram / Bucket Math
- Bucket index → upper bound must use `(index + 1) * bucket_width`, not `index * bucket_width`. Off-by-one here silently under-reports all percentile latencies.

### Merge Conflict Strategy
- When merging `origin/main` into a feature branch, keep HEAD (feature branch) versions of refactored/simplified files. The feature branch represents the latest intentional state.
- After resolving conflicts, grep for dead code left behind by the losing side (unused structs, functions, imports) and remove it.

### Documentation (Diataxis)
- README should be a **landing page** (navigational), not a reference dump. Route readers to examples, docs, and API instead of mixing tutorial/reference/explanation.
- AGENTS.md stays concise (~30 lines core); use subdirectory AGENTS.md for subsystem-specific guidance.

### Actor Existence Checks: Use StoreProvider.probeObject
- `MemoryNodeStore.openScoped` calls `getOrCreateObject`, which materializes an empty entry even for non-existent actors. `StoreProvider.open().loadSnapshot()` is therefore **not safe as an existence probe** — it will succeed (with no snapshot) and silently create the object.
- Use `StoreProvider.probeObject(object_id)` instead: it never materializes state, reports presence when durable state or retry history exists (memory + SQLite implement it), and returns `error.ObjectProbeUnsupported` for providers without `probe_fn`.

### Downstream Dependency Integration (Zig Package)
- `zig fetch --save` in Zig 0.16-dev incorrectly writes `.path = <tarball_url>` instead of `.url`/`.hash` for remote URLs. Always verify `build.zig.zon` manually after running `zig fetch --save`.
- Correct `build.zig.zon` format for consuming aktorz remotely:
  ```zig
  .aktorz = .{
      .url = "https://github.com/sammyjoyce/aktorz/archive/<commit>.tar.gz",
      .hash = "<hash-from-zig-fetch>",
  },
  ```
- Consumers import modules as: `aktorz.module("durable_actor")` and optionally `aktorz.module("durable_actor_sqlite")`, which links the bundled SQLite amalgamation itself.

### Runtime Thread Safety
- `Runtime.request()` is **not proven thread-safe**. Multi-threaded consumers (e.g. a TCP server with thread-per-connection) must serialize all `runtime.request()` / `runtime.passivate()` calls behind a mutex. A CAS spinlock (`std.atomic.Value(u32)` with `cmpxchgWeak`) is the simplest correct approach — coarse-grained but avoids deadlocks.
- The runtime rejects reentrant requests with `Error.ReentrantRequest` — an actor's `decide` callback must not call back into the runtime.

### No Built-in Actor Deletion
- `Runtime` has `passivate(address)` (removes from memory) but no `destroyActor`/`deleteActor`. Store data persists after passivation.
- To "delete" an actor: send a command that resets state to blank → `passivate` → remove from any external tracking (e.g. token store). Test that re-creating with the same ID starts fresh.

### Object ID Format
- Internal object IDs follow `{kind.len}:{kind}:{key}` (e.g. `10:dtw_thread:T-uuid`). Consumers can use this format for direct SQLite queries (`actor_snapshot`/`actor_wal` tables) when enumerating actors.

### Downstream Consumer Integration Patterns
- **Decide/Apply pattern**: actor `decide(alloc, message)` returns `Decision { .mutation, .reply }`; `apply(mutation)` mutates state. Use full state replacement for most commands; incremental mutations (append-only) for high-frequency operations like message appends.
- **State serialization**: line-oriented `key:hex-value` format is a proven pattern for binary-safe durable state (hex-encode JSON/binary fields per line).
- **Actor existence tracking**: since `MemoryNodeStore.openScoped` creates phantom objects (see above), consumers should maintain a separate tracking structure (e.g. `TokenStore` / `known_threads` map) rather than probing the runtime.
- **Test harnesses**: use `MemoryNodeStore` for unit tests and `SQLiteNodeStore` with temp files for persistence/restart tests. Wire with `snapshot_every = 1` for deterministic snapshots.

### Zig 0.16 Time and Formatting
- No high-level timestamp API in stdlib — use `std.os.linux.clock_gettime(.REALTIME, &ts)` for wall-clock time.
- Epoch → ISO 8601 formatting requires a custom `formatEpochISO8601` using `std.time.epoch` (no stdlib formatter exists).

### Deduplication Boundary (never overclaim)
- Deduplication is per actor and only reached for decisions with a mutation: retries re-run `decide()`, reply-only decisions are not recorded, and a retry whose new decision has no mutation bypasses the ledger. Docs must never describe this as generic or exactly-once request execution. Reference: `docs/deduplication.md`.

### Post-Append apply() Failure Contract
- `apply()` must be deterministic, replay-safe, state-only, and effectively infallible for compatible persisted mutations. If it fails after `appendOnce()` committed, the runtime discards the activation without snapshotting and returns `error.PostAppendApplyFailed` — retry the **same** message id. If recovery (snapshot decode or replay apply) fails deterministically, requests return `error.PoisonedActor` until `Runtime.retryPoisoned()` or restart; poison is process-local.
- A snapshot failure after a successful apply is a committed-command maintenance error: the activation stays mapped and usable; never treat it as state divergence.

### Reply Ownership and Cleanup
- `Runtime.request()` returns `?OwnedBytes`. The caller **owns** the reply and must call `reply.deinit()` — use `defer reply.deinit()` immediately after the null check. Forgetting this leaks the reply's backing allocation.
- Pattern: `const reply = (try runtime.request(addr, id, payload)) orelse return error.ExpectedReply; defer reply.deinit();`

### SQLite Restart Enumeration
- On startup, consumers must rebuild their known-actor index by scanning SQLite: `SELECT DISTINCT object_id FROM actor_snapshot WHERE object_id LIKE '{kind_len}:{kind}:%' UNION SELECT DISTINCT object_id FROM actor_wal WHERE object_id LIKE '{kind_len}:{kind}:%'`.
- This is necessary because the runtime has no built-in actor registry — passivated actors exist only in the store.

### Snapshot Encoding Verbosity
- Each `decide*` method in a consumer typically encodes the full state struct (~20+ fields) manually. This is repetitive but intentional — it keeps the serialization explicit and avoids hidden coupling to struct layout.
- If adding a snapshot helper to aktorz, it should be opt-in (comptime generic) and not impose a serialization format on consumers.

### Platform-Specific Time APIs
- `std.os.linux.clock_gettime(.REALTIME, &ts)` only works on Linux — returns 0 on other platforms. Consumers needing cross-platform wall-clock time should use `std.posix.gettimeofday()` (works on Linux + macOS) or `std.time.nanoTimestamp()` for monotonic time.

### PR & CI Workflow
- CI lives in `.github/workflows/ci.yml`: Zig tests, Node on three OSes, Bun bindings, and cross-platform package artifacts. Still run `zig build test` / `zig build sqlite-test` locally first.
- PR body: write to a temp file (`/tmp/pr-body.md`) and pass `--body-file` to avoid shell escaping issues.
- Commit messages: use Conventional Commits (`feat(scope)`, `fix(scope)`, `docs(scope)`).
