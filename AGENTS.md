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
