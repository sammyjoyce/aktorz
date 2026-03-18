# aktorz

`aktorz` is a small Zig package for building lazily activated, single-threaded, stateful services with private durable storage.

It keeps the transport and storage details pluggable:

- `Runtime` manages activations, mailboxes, replay, snapshotting, and passivation.
- `Service` is the user-defined state machine.
- `StoreProvider` / `ScopedStore` define the durability boundary.
- `Resolver` / `Forwarder` are optional hooks for global routing.
- `MemoryNodeStore` is included for tests and local demos.
- `TinyGateway` and `TcpGateway` provide a minimal framed TCP gateway.
- `CartService` is included as a concrete example service.
- `BankAccountService` is a richer example with state-machine transitions, overdraft logic, and bounded transaction history.
- `SQLiteNodeStore` lives in the separate `durable_actor_sqlite` module.

## What the runtime guarantees

For a given local service instance, messages are processed one at a time.

A mutable command is handled in this order:

1. `decide()` computes a durable mutation from current state + message.
2. The mutation is appended with `appendOnce(message_id, seq, ...)`.
3. Only after the append succeeds does the runtime call `apply()`.
4. Snapshots are produced periodically or on passivation.

That means service logic stays serialized and retry-safe without lock confetti.

## Requirements

Zig 0.16.0-dev.2905 or later. A nix flake is included for convenience:

```bash
nix develop
```

## Add it to another Zig project

`build.zig.zon`:

```zig
.{
    .name = .my_app,
    .fingerprint = 0x<your_fingerprint>,
    .version = "0.1.0",
    .dependencies = .{
        .aktorz = .{
            .path = "../aktorz",
        },
    },
    .paths = .{ "" },
}
```

### Pure Zig runtime only

`build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const durable_dep = b.dependency("aktorz", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("durable_actor", durable_dep.module("durable_actor"));
    b.installArtifact(exe);
}
```

### With SQLite persistence

`build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const durable_dep = b.dependency("aktorz", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("durable_actor", durable_dep.module("durable_actor"));
    exe.root_module.addImport("durable_actor_sqlite", durable_dep.module("durable_actor_sqlite"));
    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("sqlite3", .{});

    b.installArtifact(exe);
}
```

`src/main.zig`:

```zig
const durable = @import("durable_actor");
const durable_sqlite = @import("durable_actor_sqlite");
const std = @import("std");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var store = try durable_sqlite.SQLiteNodeStore.init(gpa, "actors.sqlite3", .{});
    defer store.deinit();

    var runtime = durable.Runtime.init(gpa, store.asStoreProvider(), .{
        .snapshot_every = 64,
    });
    defer runtime.deinit();
    defer runtime.shutdown() catch unreachable;

    // Define your own service or copy one from the examples/ directory.
    // See examples/cart_example.zig and examples/bank_example.zig.
    const MyService = @import("my_service.zig").MyService;

    try runtime.registerFactory("my_kind", durable.Factory.from(MyService, MyService.create));

    const addr = durable.Address{
        .kind = "my_kind",
        .key = "tenant:entity-42",
    };

    const reply = (try runtime.request(addr, 1, "some-command|arg")).?;
    defer reply.deinit();

    std.debug.print("{s}", .{reply.bytes});
}
```

## Tiny framed gateway

The package includes a tiny framed gateway that is generic across service kinds.

Request frame:

```text
kind: <service-kind>
key: <service-key>
message-id: <decimal-u128>
content-length: <decimal-usize>

<payload-bytes>
```

Response frame:

```text
status: ok|noreply|error
content-length: <decimal-usize>

<reply-or-error-body>
```

One connection carries one request. That keeps the gateway small enough to embed in tests, TCP listeners, and local tools without summoning a cathedral of networking abstractions.

## Included examples

In-memory cart gateway (listens on port 7070):

```bash
zig build cart-gateway
```

SQLite-backed cart gateway (listens on port 7070):

```bash
zig build cart-sqlite-gateway -- actors.sqlite3
```

Pass the DB path as the first argument. Defaults to `actors.sqlite3`.

Test with `nc`:

```bash
printf 'kind: cart\nkey: acme:customer-42\nmessage-id: 1\ncontent-length: 20\n\nadd|red-socks|2|1299' | nc localhost 7070
```

### Bank account gateway

A richer example that exercises state-machine transitions (active/frozen/closed),
overdraft protection, bounded recent-transaction history, and snapshot round-trips.

```bash
zig build bank-gateway
```

Commands: `deposit|<cents>|<memo>`, `withdraw|<cents>|<memo>`,
`set_overdraft|<cents>`, `freeze|<reason>`, `unfreeze`, `close`,
`balance`, `statement`.

```bash
printf 'kind: bank\nkey: acme:checking\nmessage-id: 1\ncontent-length: 24\n\ndeposit|50000|big savings' | nc localhost 7070
```

## SQLite module

SQLite support lives in a separate module so projects that only want the pure-Zig runtime do not need SQLite headers or linker flags.

Module name:

```zig
@import("durable_actor_sqlite")
```

Main type:

```zig
const durable_sqlite = @import("durable_actor_sqlite");
var store = try durable_sqlite.SQLiteNodeStore.init(gpa, "actors.sqlite3", .{});
```

The schema is created on first open.

Included docs:

- `docs/sqlite_schema.sql`
- `docs/sqlite_store.md`

## Build steps

Pure Zig tests:

```bash
zig build test
```

SQLite-backed tests:

```bash
zig build sqlite-test
```

## Notes

`deinit()` only releases in-memory resources. Call `shutdown()` first when you want active services snapshotted and passivated cleanly.

`actor_seen_message` is intentionally retained so old retries are still recognized as duplicates. Idempotency history grows over time unless you pick a retention policy.
