# SQLite store

The package now includes a real SQLite-backed store implementation in `src/sqlite_store.zig`.

The SQLite pieces live in a **separate Zig module** named `durable_actor_sqlite` so projects that only want the pure-Zig runtime do not have to pull SQLite headers and linker flags into every build.

## What it implements

`SQLiteNodeStore` implements the existing `StoreProvider` / `ScopedStore` seam.

For one logical actor instance (`object_id`), it maps the runtime hooks like this:

- `loadSnapshot()`
  - `SELECT last_seq, snapshot FROM actor_snapshot WHERE object_id = ?`
- `replayAfter(after_seq)`
  - `SELECT seq, mutation FROM actor_wal WHERE object_id = ? AND seq > ? ORDER BY seq ASC`
- `appendOnce(intent)`
  - `BEGIN IMMEDIATE`
  - read `actor_seen_message` for `(object_id, message_id)`
  - if found, return the stored reply blob as a duplicate result
  - otherwise insert into `actor_wal`
  - insert into `actor_seen_message`
  - `COMMIT`
- `writeSnapshot(at_seq, bytes)`
  - upsert into `actor_snapshot`
- `compactBefore(first_live_seq)`
  - delete older WAL rows for that actor

`message_id` is stored as a 16-byte blob so the runtime keeps its `u128` idempotency key semantics intact.

## Why `BEGIN IMMEDIATE`

This backend uses one write transaction for `appendOnce()`. That keeps idempotency and WAL append atomic.

Using `BEGIN IMMEDIATE` asks SQLite for the write lock at transaction start instead of halfway through the write path. That makes lock contention fail earlier and more predictably, which is less gremlin-friendly than a deferred upgrade in the middle of your append.

## Build/link requirements

Consumers using `durable_actor_sqlite` need:

- `@import("durable_actor_sqlite")`
- `root_module.link_libc = true`
- `root_module.linkSystemLibrary("sqlite3", .{})`

The package build already wires that up for:

- `zig build sqlite-test`
- `zig build cart-sqlite-gateway`

## Schema

The canonical schema is in `docs/sqlite_schema.sql` and is also embedded directly into `SQLiteNodeStore.init()` for automatic bootstrapping.

## Caveat

`actor_seen_message` is intentionally not compacted away, because doing so would weaken duplicate suppression for old retries. That is the correct default for safety, but it means idempotency history grows unless you design a retention policy that matches your product semantics.
