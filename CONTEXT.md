# Architectural Context: celld and Aktorz

## Purpose

This document preserves a source-backed comparison between [denoland/celld](https://github.com/denoland/celld) and Aktorz. It records where their approaches overlap, where they operate at different layers, and which celld ideas may be useful to Aktorz without changing Aktorz from an embeddable durable-actor primitive into an operational platform.

The comparison is pinned to:

- celld [`553ae73f83c87c3f7c7a5f73c32c2211d9d7341f`](https://github.com/denoland/celld/commit/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f), released as `v0.1.0`
- Aktorz [`471e94124ede5e268cadcba5d63196d81adfdd64`](https://github.com/sammyjoyce/aktorz/commit/471e94124ede5e268cadcba5d63196d81adfdd64)

celld is an early and evolving implementation with documented compatibility and operational limits. This document describes the pinned implementation rather than assuming future behavior.

## Executive summary

celld and Aktorz share a broad mental model:

- stateful objects are addressed by stable identity;
- objects activate lazily;
- one logical writer processes an object's work at a time;
- durable state outlives the in-memory activation;
- idle objects can be passivated or hibernated and later restored.

They nevertheless operate at different architectural layers:

- **celld is a distributed application platform.** It self-hosts a subset of Cloudflare Workers and Durable Objects and includes V8 execution, HTTP and RPC, WebSockets, alarms, deployment, ownership, replication, failover, admission control, and fleet operations.
- **Aktorz is an embeddable durable state-machine kernel.** It supplies explicit `decide`/`apply` semantics, mutation logging, snapshots, retry deduplication, pluggable storage, TypeScript bindings, and thin routing hooks.

The closest common denominator is lazy activation plus serialized per-identity execution. Beyond that, celld is a batteries-included distributed platform while Aktorz is deliberately a reusable building block. Matching celld wholesale would require Aktorz to adopt product and operational responsibilities that are currently outside its scope.

## Request lifecycle

### Aktorz

A local request follows a compact application-level event-sourcing path:

1. An optional `Resolver` chooses a local or remote route. A `Forwarder` handles a remote route.
2. Local activation creates the service, opens its scoped store, loads a snapshot, and replays later mutation records.
3. The runtime invokes `decide()` with the current state and message.
4. If the decision contains a mutation, `appendOnce()` persists the mutation, message ID, and optional reply.
5. Only after persistence succeeds does the runtime invoke `apply()` to update in-memory state.
6. Periodic or passivation snapshots compact the recovery log.

The activation path is implemented by [`Runtime.getOrActivate()`](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/core.zig#L446-L503). Persistence-before-apply and snapshot compaction are implemented by [`processOne()` and `snapshotActivation()`](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/core.zig#L527-L568).

### celld

A cold cell request traverses a distributed infrastructure lifecycle:

1. Read `cells/<cell>/own.json` and, when necessary, the owner's node lease.
2. Route to the current owner or conditionally acquire ownership with a new epoch.
3. Restore the cell's SQLite database from a preserved local hibernation image or the newest LTX replica in the shared bucket.
4. Start the cell runtime and publish that exact epoch for request dispatch. The pinned implementation spawns a named thread for each resident cell runtime.
5. Run the Worker or Durable Object handler.
6. If the handler committed a write, withhold its response until replication proves that write recoverable from the bucket.
7. Before hibernation, prove durability again, stop the runtime, and preserve or discard the local database according to whether ownership is retained or handed back to the fleet.

Ownership resolution is modeled in [`crates/logic/lib.rs`](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/logic/lib.rs#L2762-L2865). CAS completion drives restore, runtime startup, and publication through explicit phases in [the same decision core](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/logic/lib.rs#L3091-L3269). Runtime creation occurs in [`start_cell()`](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/celld/runtime.rs#L534-L574).

## Major contrasts

### Application programming model

Aktorz requires an explicit state machine. A service supplies snapshot serialization plus `decide()` and `apply()` through a narrow vtable ([source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/core.zig#L48-L119)). Domain mutations are first-class recovery records, although the framework treats their bytes as opaque and may compact them after a snapshot.

celld runs ordinary Durable Object code. Applications mutate private SQLite-backed storage directly from async HTTP, RPC, alarm, or WebSocket handlers. Its counter example simply loads and writes `"n"` through `state.storage` ([source](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/examples/counter/index.js#L1-L14)).

The resulting persistence models differ:

- Aktorz's recovery log contains application-defined mutations replayed through `apply()`.
- celld's LTX stream is physical SQLite replication rather than a domain event log.
- Aktorz reconstructs service state by loading a snapshot and semantically replaying mutations.
- celld restores the database and reconstructs the JavaScript object around that durable storage.

### Concurrency semantics

celld implements asynchronous Durable Object semantics. Each cell executes on one thread, but another event can interleave while the first handler awaits; local storage operations themselves remain synchronous ([documentation](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/docs/README.md#L8-L17)). The V8 run loop explicitly services reentrant jobs while a promise is pending ([source](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/celld/js.rs#L1020-L1052)). Different resident cells can execute concurrently on different runtime threads.

Aktorz is synchronous and non-interleaving. `Runtime.request()` directly processes the activation mailbox and rejects a reentrant request ([source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/core.zig#L358-L384)). TypeScript actor callbacks must not return promises ([source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/typescript/types.ts#L13-L27)), and the built-in TCP gateway has a sequential accept loop ([source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/tiny_gateway.zig#L171-L195)).

Aktorz's model is easier to reason about and replay, but celld naturally accommodates async network applications and parallel execution across cells.

### Storage topology

celld physically shards by object. Each cell owns a separate SQLite file and a replicated, epoch-fenced bucket prefix ([source](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/celld/storage.rs#L3-L11)). This isolates contention, corruption, restore cost, and blast radius.

Aktorz's built-in SQLite backend physically shares one database. `SQLiteNodeStore` owns one `sqlite3*`, and every `SQLiteScopedStore` receives that same pointer plus an `object_id` ([store source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/sqlite_store.zig#L91-L158), [scoping source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/sqlite_store.zig#L178-L200)). This layout is an implementation choice rather than a core requirement because `StoreProvider` permits alternative backends ([source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/core.zig#L139-L249)).

### Durability boundary

celld defines durability as remote recoverability. Local SQLite runs with `synchronous=NORMAL` because local fsync is not the final acknowledgement boundary ([source](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/celld/storage.rs#L113-L122)). A write response is held until LTX replication completes:

- response gating: [`main.rs`](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/celld/main.rs#L2225-L2272)
- durability ticket and coalesced upload: [`ltx_repl.rs`](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/celld/ltx_repl.rs#L251-L288)
- final hibernation synchronization: [`ltx_repl.rs`](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/celld/ltx_repl.rs#L290-L333)

An acknowledged write is therefore intended to survive loss of the serving node, at the cost of object-store latency.

Aktorz defines durability through the selected `StoreProvider`. Its built-in SQLite backend defaults to WAL plus `synchronous=FULL` ([source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/sqlite_store.zig#L102-L145)). `appendOnce()` atomically writes the actor WAL and durable deduplication ledger using `BEGIN IMMEDIATE` ([source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/sqlite_store.zig#L253-L322)). The core does not currently provide remote replication or an output gate.

### Idempotency

Aktorz has a persistent `u128` message ID and stored reply for every mutating decision. Retrying that command returns the original persisted reply without applying the mutation again.

celld instead supplies single-owner execution, fencing, and durable acknowledged writes. Generic request retry deduplication remains an application concern that can be implemented inside the cell's SQLite database.

Aktorz's deduplication is specifically inside the `decision.mutation` branch, so read-only decisions are not recorded or deduplicated ([source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/core.zig#L527-L553)). Its semantics should therefore be described as durable retry deduplication for mutating decisions rather than generic exactly-once request execution.

### Distribution and ownership

celld supplies a distributed authority protocol with:

- owner records and monotonically advancing epochs;
- expiring node leases;
- conditional object-store writes;
- reconciliation of ambiguous CAS outcomes;
- local and remote routing;
- restore and stale-owner fencing;
- capacity-aware placement and pressure-driven release.

celld's claim that it has no consensus service means it does not operate a membership or consensus system itself. Authority is externalized to object-store conditional writes and ETags. The primitive is explicit in [`Bucket.put_cas()`](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/celld/bucket.rs#L204-L225), and owner records use it directly ([source](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/celld/ownership_store.rs#L293-L311)). The self-hosted correctness path is bucket-coordinated even though the repository also contains optional managed-service integration.

Aktorz exposes `Resolver` and `Forwarder` interfaces ([source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/core.zig#L251-L279)). These are useful extension seams, but they do not themselves establish exclusive ownership, epochs, leases, fencing, failover, or remote durability. A production multi-node integration must supply those guarantees outside the core.

## Architectural inversion

The most interesting difference is where each project places its strongest state-machine boundary.

celld makes the **infrastructure lifecycle** a pure event/effect state machine while allowing application code to use ordinary mutable JavaScript. The workspace declares that `crates/logic` owns behavioral state and decisions while `crates/celld` executes effects ([source](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/Cargo.toml#L1-L5)). The logic crate has no async, I/O, clocks, randomness, locks, or dependencies ([source](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/crates/logic/Cargo.toml#L1-L10)). This permits deterministic simulation of crashes, lease races, ambiguous writes, clock drift, and ownership handoffs ([testing design](https://github.com/denoland/celld/blob/553ae73f83c87c3f7c7a5f73c32c2211d9d7341f/docs/testing.md#L33-L60)).

Aktorz keeps the **application lifecycle** explicit through `decide()` and `apply()`, while the runtime lifecycle is implemented directly and imperatively. This makes business-state transitions, persistence ordering, and replay straightforward, but it would become harder to validate if the runtime accumulated distributed leases, fencing, timers, pressure policy, and asynchronous effect races.

The two projects therefore apply similar state-machine discipline at different layers:

- celld applies it to distributed infrastructure coordination;
- Aktorz applies it to user-defined durable state transitions.

## Implications for Aktorz

The following celld ideas could deepen Aktorz without requiring it to become a Workers platform.

### Add a remote durability proof seam

A replicated `StoreProvider` needs a way to distinguish:

1. a mutation committed to the local store; and
2. that mutation being recoverable from the configured replica authority.

A future append API could return a durability position or token. The runtime could then await a store-specific durability proof before releasing the reply. Local stores could resolve the proof immediately; replicated stores could implement an output gate similar to celld's.

This should remain optional so Aktorz does not impose network latency on local and embedded deployments.

### Put epochs and fencing in an optional distributed package

`Resolver` and `Forwarder` should remain small core seams. A separate distributed package could define:

- ownership records;
- monotonically increasing epochs;
- owner and node leases;
- stale-owner fences;
- ambiguous-acquire reconciliation;
- a forwarding protocol carrying the expected epoch.

This would make the distributed correctness contract explicit instead of allowing a routing implementation to appear correct while lacking exclusive ownership.

### Extract a pure lifecycle core if distributed behavior grows

The current direct runtime is appropriate for a small synchronous package. If Aktorz adds leases, failover, alarms, activation admission, or pressure shedding, those decisions should move into a pure event/effect state machine before asynchronous races become embedded in network and storage callbacks.

celld's split is especially valuable because stale completions, ambiguous writes, and fencing are represented as versioned events rather than hidden executor behavior.

### Consider an optional per-actor SQLite backend

The shared SQLite backend is simple and useful. A separate one-file-per-actor backend could support workloads that value:

- actor-level migration or backup;
- reduced shared-write contention;
- smaller restore units;
- isolated corruption and blast radius;
- independent replication.

It should be an alternative backend, not a replacement for the current shared-file store. Per-actor databases introduce their own file-descriptor, connection, checkpoint, and lifecycle costs.

### Tighten the post-append `apply()` failure contract

Aktorz persists the mutation and then invokes the fallible `apply()` callback ([source](https://github.com/sammyjoyce/aktorz/blob/471e94124ede5e268cadcba5d63196d81adfdd64/src/core.zig#L534-L546)). If `apply()` fails after `appendOnce()` commits, the current path does not automatically discard and rebuild the activation. The persisted sequence may then be ahead of the in-memory state.

Aktorz should choose and document one of these contracts:

- `apply()` is required to be effectively infallible for every valid persisted mutation; or
- an `apply()` failure poisons the activation, which is destroyed and reconstructed from snapshot plus log before later work; or
- `apply()` receives a narrower error type whose failures are classified as fatal runtime corruption.

The second option preserves the existing fallible API while giving the runtime a deterministic recovery path.

### Document the exact deduplication boundary

Because `appendOnce()` runs only for decisions containing a mutation, the durable message ledger does not cover read-only replies. Documentation should continue to state that Aktorz deduplicates persisted mutations and returns their stored replies, rather than implying that every request is generically deduplicated.

## Choosing between the approaches

celld is the better fit when a system needs:

- self-hosted Cloudflare Durable Object compatibility;
- HTTP, RPC, WebSockets, alarms, and Worker bundles;
- built-in cross-node ownership and failover;
- acknowledged-write RPO=0 against serving-node loss;
- an operational fleet rather than an embedded component.

Aktorz is the better fit when a system needs:

- an embeddable Zig or Node/Bun component;
- explicit domain mutation and replay semantics;
- durable command retry deduplication;
- local SQLite or a custom storage implementation;
- control over transport, placement, and operational architecture;
- a small primitive that downstream applications can compose.

## Working conclusion

celld should be treated as evidence for how much machinery is required to provide a complete distributed Durable Objects product, not as a drop-in alternative implementation of the same abstraction as Aktorz.

Aktorz's strongest differentiation is its explicit, compact application state-machine contract. The most valuable lessons from celld are below that application API—durability gating, epoch fencing, pure lifecycle decisions, and physical storage isolation. Those ideas should be introduced through optional and composable primitives so that the core remains useful as a small embedded runtime.
