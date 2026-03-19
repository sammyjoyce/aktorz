# aktorz

A small Zig package for building lazily activated, single-threaded, stateful services with private durable storage. No external dependencies beyond the Zig standard library (SQLite optional).

## How it works

A `Service` is a user-defined state machine. The `Runtime` activates it on demand, replays its durable log, and then feeds it messages one at a time:

1. `decide()` inspects the current state and message, returning a `Decision` (an optional mutation + optional reply).
2. The mutation is persisted via `appendOnce()` — deduplicated by message ID.
3. Only after the append succeeds does the runtime call `apply()` to update in-memory state.
4. Snapshots are taken periodically and on passivation, compacting the log.

This keeps service logic serialized and retry-safe without locks.

## Quick start

Requires **Zig 0.16.0-dev.2905** or later. A Nix flake is included:

```bash
nix develop          # enter the dev shell
zig build test       # run core + example tests
zig build sqlite-test  # run SQLite-backed tests (needs system sqlite3)
```

Try the cart gateway:

```bash
zig build cart-gateway                # starts on port 7070
printf 'kind: cart\nkey: acme:c-42\nmessage-id: 1\ncontent-length: 20\n\nadd|red-socks|2|1299' | nc localhost 7070
```

## Add to your project

In your `build.zig.zon`, add the dependency:

```zig
.dependencies = .{
    .aktorz = .{ .path = "../aktorz" },
},
```

Then in `build.zig`, import the module:

```zig
const durable_dep = b.dependency("aktorz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("durable_actor", durable_dep.module("durable_actor"));
```

For SQLite persistence, also add:

```zig
exe.root_module.addImport("durable_actor_sqlite", durable_dep.module("durable_actor_sqlite"));
exe.root_module.link_libc = true;
exe.root_module.linkSystemLibrary("sqlite3", .{});
```

## Define a service

Implement five methods and the runtime handles the rest:

```zig
const durable = @import("durable_actor");

pub const MyService = struct {
    // ... your state fields ...

    pub fn create(alloc: Allocator, address: durable.Address) !*MyService { ... }
    pub fn destroy(self: *MyService, alloc: Allocator) void { ... }
    pub fn loadSnapshot(self: *MyService, bytes: []const u8) !void { ... }
    pub fn makeSnapshot(self: *MyService, alloc: Allocator) !durable.OwnedBytes { ... }
    pub fn decide(self: *MyService, alloc: Allocator, message: []const u8) !durable.Decision { ... }
    pub fn apply(self: *MyService, mutation: []const u8) !void { ... }
};
```

Register it with the runtime:

```zig
var store = durable.MemoryNodeStore.init(alloc);
var runtime = durable.Runtime.init(alloc, store.asStoreProvider(), .{ .snapshot_every = 64 });
defer runtime.deinit();
defer runtime.shutdown() catch unreachable;

try runtime.registerFactory("my_kind", durable.Factory.from(MyService, MyService.create));

const reply = (try runtime.request(
    .{ .kind = "my_kind", .key = "tenant:entity-42" }, 1, "some-command|arg",
)).?;
defer reply.deinit();
```

See `examples/cart_example.zig` and `examples/bank_example.zig` for complete working services.

## Key types

| Type | Role |
|---|---|
| `Runtime` | Manages activations, mailboxes, replay, snapshotting, passivation |
| `Service` | Vtable interface for user state machines |
| `Factory` | Creates `Service` instances from an `Address` |
| `StoreProvider` / `ScopedStore` | Pluggable durability boundary (log + snapshots) |
| `Resolver` / `Forwarder` | Optional hooks for routing across nodes |
| `MemoryNodeStore` | In-memory store for tests and demos |
| `SQLiteNodeStore` | SQLite-backed store (separate `durable_actor_sqlite` module) |
| `TinyGateway` / `TcpGateway` | Minimal framed TCP gateway |

## TCP gateway protocol

One connection carries one request.

**Request:**
```text
kind: <service-kind>
key: <service-key>
message-id: <decimal-u128>
content-length: <decimal-usize>

<payload-bytes>
```

**Response:**
```text
status: ok|noreply|error
content-length: <decimal-usize>

<reply-or-error-body>
```

## Examples

| Command | Description |
|---|---|
| `zig build cart-gateway` | In-memory cart service on port 7070 |
| `zig build cart-sqlite-gateway -- actors.sqlite3` | SQLite-backed cart service |
| `zig build bank-gateway` | Bank account with freeze/close lifecycle |
| `zig build -Doptimize=ReleaseFast bench` | Benchmark runner (default: SQLite suite) |

Bank account commands: `deposit|<cents>|<memo>`, `withdraw|<cents>|<memo>`, `set_overdraft|<cents>`, `freeze|<reason>`, `unfreeze`, `close`, `balance`, `statement`.

## Build steps

```bash
zig build test           # core + example tests
zig build sqlite-test    # SQLite + benchmark tests
zig build -Doptimize=ReleaseFast bench                   # default SQLite suite
zig build -Doptimize=ReleaseFast bench -- --mode micro --scenario memory_hot --ops 1000000
```

## Notes

- Call `shutdown()` before `deinit()` to snapshot and passivate active services cleanly. `deinit()` only releases memory.
- `actor_seen_message` is retained so old retries are still recognized as duplicates. Idempotency history grows unless you choose a retention policy.

## Further reading

- [`docs/sqlite_store.md`](docs/sqlite_store.md) — SQLite store design
- [`docs/sqlite_schema.sql`](docs/sqlite_schema.sql) — SQLite schema
