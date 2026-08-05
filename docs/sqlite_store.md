# SQLite store

SQLite-backed store implementation lives in `src/sqlite_store.zig`.

The SQLite pieces live in a separate Zig module named `durable_actor_sqlite` so projects that only want the pure-Zig runtime do not have to pull SQLite headers and linker flags into every build.

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

`message_id` is stored as a 16-byte blob, preserving the runtime's full-width `u128` per-actor deduplication key.

## Deduplication ledger

`actor_seen_message` contains records created by `appendOnce()`, so it covers only decisions that contain mutations. It is keyed by `(object_id, message_id)`: the same numeric message ID may be used independently by different actors.

On a duplicate, SQLite returns the optional reply stored by the first append. It does not store or compare the original request payload, and it does not compare the newly computed mutation. See [`deduplication.md`](deduplication.md) for the runtime-level boundary, including the fact that `decide()` runs before this lookup and that decisions without mutations bypass it entirely.

## Why `BEGIN IMMEDIATE`

This backend uses one write transaction for `appendOnce()`. That keeps the mutation-log insert and its corresponding deduplication record atomic.

Using `BEGIN IMMEDIATE` asks SQLite for the write lock at transaction start instead of halfway through the write path. That makes lock contention fail earlier and more predictably than a deferred lock upgrade in the middle of an append.

## Build/link requirements

Adding the module is all a consumer needs:

```zig
exe.root_module.addImport("durable_actor_sqlite", durable_dep.module("durable_actor_sqlite"));
```

The module compiles the SQLite amalgamation fetched by `build.zig.zon` and propagates libc plus the static library to dependents, so no system `sqlite3` is involved.

## Schema

The schema is in `docs/sqlite_schema.sql` and also embedded in `SQLiteNodeStore.init()`, which runs it on first open.

## Retention caveat

`actor_seen_message` is not compacted with `actor_wal`. This preserves duplicate suppression for old mutating message IDs even after their mutation-log rows have been covered by a snapshot and removed.

The default retention horizon is therefore the lifetime of the database, and the table grows by one row per unique mutating message ID, including any stored reply. Aktorz currently has no pruning policy. Any future bounded-retention option must state that, after a record is removed, an old retry can be accepted as a new mutation.

## Failure knowledge

`appendOnce()` returns an error only when the append definitely did not commit: the transaction rolls back, leaving neither the WAL row nor the seen-message row. A custom store that cannot make that promise must document its failures as ambiguous, in which case callers retry the same message ID and the deduplication ledger reconciles the outcome.
