# Aktorz Consolidated Design Plan

This document consolidates six deep design explorations of the "Implications for
Aktorz" section of [CONTEXT.md](CONTEXT.md) (the celld comparison). Each
exploration was an independent oracle deep-research job run against the pinned
Aktorz sources on 2026-08-05. Immediately required bug fixes extracted from the
same analyses live in [FIX.md](FIX.md) and are prerequisites for everything
here.

| # | Topic | Oracle job id |
|---|-------|---------------|
| 1 | Remote durability proof seam | `ae9ea121-789f-42df-91ac-b3cec4101be2` |
| 2 | Epochs and fencing (distributed package) | `b4751bf2-fed4-492f-a6b9-61b034825497` |
| 3 | Pure lifecycle-core extraction | `850dd5df-38e8-4ac9-bf40-07b47dc60e27` |
| 4 | Per-actor SQLite backend | `d8943bf0-114e-4486-a7d2-f99f19341589` |
| 5 | Post-append `apply()` failure contract | `9b6a91d5-cbf0-4c68-8b97-de6e2580602c` |
| 6 | Deduplication boundary documentation | `59e372a2-bbba-4cbb-9ab0-2aa3c714d1f0` |

Full responses were saved under `/tmp/oracle-<job-id>/response.md` (ephemeral;
this document is the durable synthesis).

---

## 1. Design principles (shared across all six analyses)

1. **Aktorz stays an embeddable durable-actor primitive.** Every extension is
   an optional, composable capability. Nothing forces network latency, epochs,
   catalogs, or async machinery on local/embedded deployments.
2. **Optional capabilities, all-or-none, fail closed.** New store powers are
   optional vtable extensions defaulted to `null`. A store either implements a
   capability completely (comptime-enforced) or not at all. No runtime flag may
   silently bypass a capability a store declares (e.g. ignore a durability
   requirement or downgrade a fence).
3. **The correctness boundary is durable commit + reply release**, not
   in-memory execution. Stale CPU may briefly run; stale *durable writes* and
   stale *replies* must be impossible.
4. **Pure event/effect state machines live at the layer that owns the races.**
   Today no local lifecycle races exist, so the core runtime stays direct and
   imperative; the distributed package (which owns leases, CAS ambiguity,
   timers) is pure-logic from day one.
5. **Name guarantees precisely.** "Per-actor mutating-decision deduplication
   with stored-reply return" — never "exactly-once", "idempotency", or
   "retry-safe" unqualified.
6. **Ambiguity is a first-class result.** External operations distinguish
   *definitely-not-committed* from *may-have-committed* (`CommitKnowledge`,
   `CasOutcome.indeterminate`). Blind retry after ambiguity is always wrong;
   reconciliation is by readback or by the durable dedup ledger.

## 2. Layered architecture

The six explorations converge on five distinct correctness layers. Layers 2–5
are optional; layer 1 is the product.

```
┌────────────────────────────────────────────────────────────────────┐
│ 1. Application state machine   decide()/apply(), snapshots, dedup  │  core (hardened, §3)
├────────────────────────────────────────────────────────────────────┤
│ 2. Durability gating           "is this write recoverable from     │  optional ScopedStore
│                                 the configured authority?"         │  capability (§4)
├────────────────────────────────────────────────────────────────────┤
│ 3. State fencing               "may this epoch commit an append,   │  neutral core token +
│                                 dup lookup, snapshot, compaction?" │  optional store hook (§5)
├────────────────────────────────────────────────────────────────────┤
│ 4. Admission                   "may this runtime execute this      │  optional Runtime hook
│                                 request right now?"                │  (§5)
├────────────────────────────────────────────────────────────────────┤
│ 5. Authority                   "who owns this actor, at what       │  separate distributed
│                                 epoch?" (leases, CAS, reconcile)   │  package (§5)
└────────────────────────────────────────────────────────────────────┘
```

Storage topology (shared SQLite file vs per-actor files, §6) is orthogonal to
all five layers. The pure lifecycle-core extraction (§7) is a *conditional*
refactor of layer 1, triggered only when layers 2–5 introduce genuine
concurrency into the local lifecycle.

---

## 3. Workstream A — Core semantics hardening (jobs 5 + 6)

This is the foundation. It fixes the silent-divergence hole, makes retry
semantics unconditional for recorded messages, and documents the exact
guarantee. Prerequisite: FIX.md items F1–F3 (ownership repairs).

### A1. The `apply()` contract: total-by-contract, fail-stop-by-enforcement

Adopted contract (hybrid of CONTEXT.md options (a) and (b) — one coherent
contract, not two modes):

> `apply()` handles an event that is already durable. It must be a
> synchronous, deterministic, replay-safe, state-only transition that succeeds
> for every compatible persisted mutation. If it returns an error after a live
> append, Aktorz treats the mutation as committed, returns
> `error.PostAppendApplyFailed`, discards the activation **without
> snapshotting it**, and reconstructs the actor before later work. A same-ID
> retry returns the recorded reply only after recovery proves the event is
> present in memory. If snapshot loading or mutation replay fails, the actor
> is quarantined and requests return `error.PoisonedActor` until an explicit
> retry or runtime restart succeeds.

Governing invariant:

> A request may run `decide()`, return a stored duplicate reply, or create a
> snapshot only after the in-memory activation is known to include every
> persisted mutation through the relevant sequence.

Rationale highlights:
- The mutation and reply are committed *before* `apply()` runs; unlike
  Cloudflare DO's transaction rollback, Aktorz cannot un-commit. The safe
  action is discard-and-reconstruct from durable truth (Akka precedent:
  recovery failure stops the persistent actor).
- A post-append failure must make the activation **snapshot-ineligible**:
  otherwise later passivation/shutdown writes a snapshot labelled `s-1` that
  may contain partial effects of event `s` (see FIX.md F4 for the corruption
  path).
- Option (c) (narrow error type) adds mapping work without solving lifecycle;
  arbitrary TS thrown values never fit a closed set.

### A2. Actor slot lifecycle

Replace `activations: StringHashMap(*Activation)` values with a tagged slot;
the **map owns the `object_id` allocation** (so failure metadata can outlive
the activation):

```zig
const ActorSlot = union(enum) {
    recovering,                       // guard; reentrant request -> ReentrantRequest
    active: *Activation,
    recovery_required: ActorFailure,  // discarded after post-append failure; next request recovers
    poisoned: ActorFailure,           // recovery callback failed; requests -> PoisonedActor
};

pub const ActorFailure = struct {
    phase: enum { post_append_apply, load_snapshot, replay_apply, store_invariant },
    source: anyerror,
    seq: ?u64 = null,
    message_id: ?u128 = null,
};
```

Rules:
- Post-append `apply()` failure: destroy activation (no snapshot), slot becomes
  `.recovery_required`, request returns `PostAppendApplyFailed` (caller knows
  the mutation committed; retry same message id).
- Recovery-time callback failure (`loadSnapshot` or replay `apply`): slot
  becomes `.poisoned` with phase + seq; requests return `PoisonedActor`
  immediately — **no per-request recovery retry loop** (poison-loop guard).
- Storage/I-O failures during recovery are transient request errors, never
  poison. `ReplayContext` carries a `failure: ?ActorFailure` field so a
  service-callback failure is distinguishable from a store error with the same
  Zig error name.
- Poison is **process-local** (not persisted): `retryPoisoned(address)` makes
  exactly one new attempt; replacing the factory + retry lets an operator fix
  code without restart; a process restart naturally retries once.
- Passivation: `.recovery_required`/`.poisoned` return `false` (never silently
  clear quarantine); `shutdown()` snapshots only `.active` slots.
- Deploy incompatibility fails closed: no skipping records, no automatic
  ignore-snapshot fallback (WAL before the snapshot boundary is already
  compacted — ignoring the snapshot can make recovery impossible). Upgrade
  contract: new code must read every retained snapshot and apply every
  retained mutation; removing old decoders requires a deliberate migration
  (dual readers → rewrite snapshots → verify all actors crossed → remove).
- Never hold a `StringHashMap` value pointer across service callbacks
  (reentrant activation of *another* actor can rehash the map); re-fetch by
  map-owned key after callbacks.

### A3. Preflight deduplication and `SeenMessage`

Job 6 proved the current boundary is conditional: `decide()` runs before
duplicate lookup, and the ledger is consulted only when the *current* decision
contains a mutation — so a retry whose new decision is a no-op (state already
changed) bypasses the ledger and returns a freshly computed reply. Job 5 showed
the same gap makes ordering A dangerous (stored reply returned against a stale
activation).

Change:

```zig
pub const SeenMessage = struct { seq: u64, reply: ?OwnedBytes };

// ScopedStore.VTable additions/changes:
lookup_seen_message: *const fn (ctx, alloc, message_id: u128) anyerror!?SeenMessage,
// AppendResult.duplicate now carries SeenMessage (seq + reply), not just ?OwnedBytes.
```

`processOne()` order becomes: **preflight lookup → (hit: validate
`seen.seq < activation.next_seq`, return stored reply, never call `decide()`)
→ (miss: decide → append → apply)**. A seen record at/ahead of `next_seq`
quarantines with `.store_invariant` — the ledger claims an event recovery has
not incorporated. `appendOnce()`'s internal duplicate check remains as the
final atomic authority (two runtimes racing one backend).

This makes dedup unconditional for recorded message IDs without turning
first-time reads into recorded requests. SQLite already stores `seq` in
`actor_seen_message` (change `SELECT reply` → `SELECT seq, reply`); the memory
store already retains both fields.

### A4. Error taxonomy and TypeScript ABI v4

- New core errors: `PostAppendApplyFailed` (mutation committed; retry same id),
  `PoisonedActor` (request never reached `decide()`), plus
  `SeenMessageAheadOfActivation` → `.store_invariant` quarantine.
- Snapshot failure *after* a successful apply is a distinct
  committed-command maintenance error — never poison, never
  `PostAppendApplyFailed` (state is consistent; prefer returning the reply and
  retrying snapshotting later; at minimum document the distinction).
- TypeScript: `AktorzError { code: "POST_APPEND_APPLY_FAILED" | "POISONED_ACTOR"
  | "NATIVE_ERROR", committed: boolean, phase?, sequence?, source? }`. Bump ABI
  3 → 4 with opaque-result accessors (`error_code`, `flags`, `failure_phase`,
  `sequence`) rather than exposed struct layout; add
  `aktorz_runtime_retry_poisoned` / `runtime.retryPoisoned(address)`.
- Bridge error lifecycle becomes **first-error-wins** (FIX.md F6) so a
  `destroy()` during discard cannot erase the original apply message. The
  original JS exception object cannot cross the C ABI; promise stable code +
  metadata, not class/stack preservation.
- `requireSynchronous` cannot un-run an async callback's synchronous prefix;
  document that a thenable-returning `apply` is classified as a post-append
  failure and already-launched async work cannot be cancelled.

### A5. Deduplication semantics: terminology and documentation (job 6)

Canonical term: **per-actor mutating-decision deduplication with stored-reply
return** (prefix "durable" only for backends persisting the ledger across
restart). Rejected: "command deduplication" (classification happens only after
`decide()` — until A3 lands), "idempotency", "retry-safe", "exactly-once".

Key propositions to document (full list + paste-ready text in the job-6
response; delivery tracked in FIX.md F8):
- `decide()` runs on every attempt; duplicate delivery ≠ duplicate-free
  execution. (After A3: not for recorded IDs.)
- Ledger scope is `(object_id, message_id)`; same numeric id is independent
  across actors. Payload is neither stored nor compared — same-id/different-
  payload is a **client bug**, documented as invalid, not detected today.
  Do not ship a partial append-time fingerprint check (it would miss the
  no-mutation bypass and create a new misleading boundary); strict detection
  only as a coherent pre-decision + atomic-append feature.
- `NULL` reply ≠ empty reply. Ledger survives compaction, passivation,
  restart; **unbounded by default** — future opt-in retention is count-based
  (`keep_last_mutations`, prune only rows covered by a snapshot with compacted
  WAL), never TTL (core has no clock contract). After pruning, an old retry is
  outside the guarantee.
- The ledger proves *recorded*, not *successfully applied* (until A1 lands the
  distinction is critical; after A1 the recovery invariant closes it).
- No automatic read dedup. Future explicit feature name: *durable result
  memoization* (opt-in, visibly write-producing). Future probe API name:
  `StoreProvider.lookupRecordedMessage()` (non-materializing; never
  `wasApplied()`); actor existence remains a separate seam (§6, `probe_fn`).
- Remote routes bypass all of this — the `Forwarder` owns equivalent
  semantics (§5).

---

## 4. Workstream B — Remote durability proof seam (job 1)

An optional, all-or-none capability letting replicated stores define
durability as *remote recoverability* (celld's output gate) while local stores
pay one null-pointer branch.

### B1. API shape

`StoreProvider` unchanged. `ScopedStore.VTable` gains
`durability: ?*const DurabilityVTable = null`:

```zig
pub const DurabilityPosition = struct { raw: u128 };       // opaque; generation + offset by convention
pub const DurabilityRequirement = union(enum) { satisfied, position: DurabilityPosition };
pub const AppendReceipt = struct { result: AppendResult, durability: DurabilityRequirement = .satisfied };

pub const DurabilityVTable = struct {
    append_once:      fn (...) anyerror!AppendReceipt,      // atomic with local commit
    recovery_barrier: fn (ctx) anyerror!DurabilityRequirement,
    wait_until_durable: fn (ctx, alloc, position, options) anyerror!void, // synchronous, idempotent
};
```

- `ScopedStore.from` enforces all-or-none at comptime; partial implementations
  are compile errors.
- For proof-capable stores the adapter synthesizes legacy `append_once` as
  append + wait, so direct `appendOnce()` users cannot silently bypass proof.
- Runtime config gains `durability_wait: DurabilityWaitOptions` (timeout);
  there is **no** flag to ignore a store's returned position.
- Proof success must mean a fresh store instance, configured with the same
  replica authority and *without* local files, can recover the ordered
  mutation, the dedup record, **and the exact stored reply** (retry semantics
  depend on reply recoverability). A `.duplicate` receipt must carry the
  original (or covering) position, or retries would bypass the gate.

### B2. Gate placement and the recovery barrier

Request path: `appendOnceWithDurability → install token → apply() →
waitUntilDurable → snapshot/compact → reply`.

- `apply()` runs **before** the wait: on timeout, in-memory state stays aligned
  with the local WAL; the pending token blocks replies, later same-actor
  requests (preflight before enqueue), snapshots, and passivation until
  proven. Retrying uses the same message id; all post-append errors are
  ambiguous acknowledgements (documented: retrying with a *new* id is
  incorrect).
- **An append token alone is insufficient.** Crash after local commit →
  restart replays WAL → a read-only request would expose unproven state
  without ever appending. Hence `recovery_barrier`: activation publication is
  gated on proving all locally visible snapshot/WAL/dedup state.
- A snapshot may never cover an unproven position; `compactBefore()` contract
  gains: compaction must not remove the last representation required to
  recover any proven mutation from the configured authority. Stores must
  persist an actor recovery frontier independent of compacted WAL.
- Passivation proves outstanding positions before snapshot + removal;
  `deinit()` remains forced teardown (no wait — nothing was acknowledged).

### B3. Failure matrix (abbreviated)

| Failure | Behavior |
|---|---|
| Append fails pre-commit | no token/apply/dedup record |
| Crash post-commit, pre-apply | restart replays; publication gated by barrier |
| `apply()` fails post-append | poison/discard per §3 (never bypasses barrier) |
| Proof timeout | state applied, token pending; error returned; actor output blocked |
| Ack lost after remote commit | repeated `waitUntilDurable` reconciles idempotently |
| Local disk lost pre-proof | write never acknowledged; retry same id appends anew or restores |
| Local disk lost post-proof | replica restores state + dedup reply — the defining guarantee |

### B4. Implementation phases

1. **Seam only** (no networking): types, comptime detection, runtime gate +
   activation `pending_durability`, recovery/passivation gates, deterministic
   `GatedMemoryNodeStore` test double (condition-variable proof controller),
   nine core tests (delayed proof, timeout, read isolation, duplicate proof,
   crash/recovery, poisoning, leak checks). Memory/SQLite stores: zero code
   change.
2. **Reference replicated store** (separate module): SQLite durable-outbox
   schema (`replication_meta/outbox/frontier/message_durability`) committed in
   the *same* `BEGIN IMMEDIATE` transaction as WAL + seen rows; injected
   `ReplicaSink`; idempotent prefix upload; ambiguous-ack reconciliation;
   delete-local-database restore tests.

---

## 5. Workstream C — Distributed authority package (job 2)

`durable_actor_distributed`: an optional first-party module in this repo
(follows the `durable_actor_sqlite` packaging pattern). Dependency-heavy
authority backends (S3, etcd) live in separate repos. **Honest scope claim:**
without the durable state-store fence, this package provides discovery and
failover *routing* — it must not claim exclusive distributed ownership.

### C1. Why Resolver/Forwarder alone are insufficient

Today `Route.local` and `RemoteRequest` carry no epoch, `getOrActivate()`
never revalidates authority for a cached activation, `processOne()` has no
ownership check, the store vtable has no fence, and passivation snapshots
before destruction (a stale write after authority loss). A Resolver-only
integration can route correctly at t₀, lose ownership at t₁, and keep serving
from the cached activation indefinitely.

### C2. Contract essentials

- **Identity**: `Epoch` (u64, starts at 1, never wraps — overflow fails
  closed), `NodeId` + `NodeGeneration` (restart ⇒ new generation ⇒ must
  acquire E+1; a restarted process never inherits its predecessor's
  authority), `OwnershipRecord { owner: ?NodeInstance, epoch }` (release sets
  owner null but *preserves* epoch), `NodeLeaseRecord` (endpoint, protocol
  version, lease sequence, wall-clock expiry). Wire format is versioned
  canonical encoding, never Zig memory layout.
- **Two lease kinds** (celld's distinction): one renewed TTL *node lease*
  backs all actors on a node (no per-actor renewal traffic); the per-actor
  *owner lease* is a derived in-memory capability (owner record + epoch +
  version token + live node lease) with no independent stored expiry.
- **`AuthorityStore`**: the true minimum is linearizable per-key `get` +
  `compare_exchange` with a three-way `CasOutcome`:
  `applied(new_version) | rejected | indeterminate`. Indeterminate mandates
  reconciliation by exact-version readback — never blind retry, never serving
  on a guess. No delete/list/watch/TTL/multi-key in v1. Backends: S3
  conditional puts (ETags), shared SQLite version-counter table, etcd
  revisions, in-memory test double — all must pass one conformance suite.
- **Neutral core fence**: `FenceToken { order: u64, holder: u128 }` (order =
  epoch, holder = generation) with monotonic install rules; equal-order claims
  idempotent only for the exact holder. Core additions: fenced
  `Route.local/remote`, `RemoteRequest.expected_fence`, optional
  `Admission` hook, activation-bound fence (an activation never changes fence
  in place — different fence ⇒ destroy and rebuild), `request_expected()`
  (forwarded ingress: executes only under the exact held lease, never
  re-resolves or acquires), and `discard` (destroy without snapshot) distinct
  from `passivate` (shared with §3).
- **Fenced store hook**: optional `ScopedStore.claim_fence`; after success,
  append, **duplicate lookup** (a stale owner must not return a stored
  reply), snapshot, and compaction all check the exact token atomically
  (SQLite: `actor_fence` table checked inside the existing `BEGIN IMMEDIATE`,
  fence check *before* dup lookup). A distributed-safe runtime refuses to
  initialize on an unfenced store. AuthorityStore ≠ fencing: owner records
  alone cannot stop stale local commits on node-local databases.
- **Admission at four points** in `processOne` (before decide / before append
  or read-reply / before snapshot / before reply): a lease can expire during a
  long `decide()`; no algorithm preempts non-cooperative code, so the boundary
  is durable commit + reply release.
- **Clocks**: wall time serialized for *others* to judge expiry; monotonic
  self-fence locally, derived from renewal *start* (a slow response shortens
  usable authority, never lengthens it). Safety bound `M + G ≥ 2S + ε`
  (self-fence margin + takeover grace vs skew). Renewal ≤ TTL/3 with jitter;
  indeterminate renewal never extends the local deadline. Host-driven
  `Coordinator.poll(now_wall, now_mono)` — no internal thread required.
- **Split-brain hierarchy**: linearizable owner record → admission +
  self-fencing → epoch-carrying forwarding → fenced durable writes →
  (optional) same-fence durability proof before mutating replies. The durable
  theorem: once `claim_fence(F₂)` commits, no later durable write under
  F₁ < F₂ can commit. Under *violated* clock bounds, fenced writes stay safe
  but a stale node could compute a read from old in-memory state — a stricter
  linearizable-read mode (authority check per response) is explicit and
  optional.
- **Protocol**: do **not** extend TinyGateway (it ignores unknown headers —
  an old peer would silently bypass the fence). Separate `DistributedGateway`
  with mandatory `protocol: aktorz-distributed/1`, expected epoch +
  generation, structured statuses (`stale-epoch`, `wrong-generation`,
  `not-owner`, `node-fenced`, `peer-incompatible`, ...). A live-but-
  incompatible peer is *unavailable*, never presumed dead (no takeover).
  Epochs fence; they do not authenticate — the transport must authenticate
  node identity.
- **Pure logic from day one**: `distributed/logic.zig` has no I/O, clocks,
  randomness, locks, or runtime imports; per-actor ownership and node-lease
  state machines consume events / emit effects; every async completion echoes
  an `OperationId` (+ generation) so stale completions are ignored
  deterministically. Deterministic multi-node simulator with seeded traces;
  16 named invariants (epoch monotonicity, CAS-only changes, no guessed
  acquisition, generation isolation, self-fence finality, publication
  ordering, exact forwarding, activation immutability, fence monotonicity,
  fenced durability, stale-write exclusion, no stale duplicate reply, reply
  safety, stale-completion immunity, incompatibility ≠ expiry, release is
  one-way) checked after every transition; ~20 adversarial scenarios
  including CAS-applied-response-lost, renewal-after-self-fence, epoch-N
  append racing epoch-N+1 fence, and stale forwarded requests.
- **Reconciliation state machines**: ambiguous owner CAS → readback of exact
  candidate vs exact original version vs other (four-way table); exhausted
  budget → `AcquireIndeterminate`, remain dormant. Release is one-way:
  `owned → draining → finish request → snapshot/prove under E → discard →
  CAS owner to null preserving E`; an indeterminate release stays fenced until
  reconciled (the release may already have landed and another node acquired
  E+1).

### C3. Phases

0. Contract + executable pure model + memory authority store + simulator
   (acceptance: broken protocol variants are caught).
1. Neutral core fence plumbing (`FenceToken`, fenced routes, `Admission`,
   `claim_fence`, `request_expected`, discard-without-snapshot); embedded mode
   unchanged when no fence supplied.
2. Coordinator + strict peer gateway + manual release/drain (memory +
   shared-SQLite authority backends only; no placement/capacity).
3. Shared-SQLite distributed profile + conformance suites + multi-process
   tests.
4. Remote authority adapters (separate packages) + integration with the
   durability seam (§4): replica fence at E+1 rejects epoch-E uploads/proofs;
   restore from replica on takeover.
5. Operational hardening (authenticated transport, metrics, drain tooling,
   TS bindings) — only then consider placement/pressure.

---

## 6. Workstream D — Per-actor SQLite backend (job 4)

`SQLitePerActorNodeStore`: an experimental, opt-in backend inside the existing
`durable_actor_sqlite` module (re-exported from `sqlite_store.zig`; no second
SQLite-linked module). Positioning: an **isolation and operability** topology
(per-actor backup/restore/migration, corruption blast radius, independent
replication units, cross-actor write parallelism across *multiple* runtimes) —
not a general performance upgrade. Shared store remains the default.

### D1. Five non-negotiable properties

1. `openScoped()` is **non-materializing** (parse + hash only; no mkdir, no
   open, no catalog row). This is what actually fixes the phantom-object
   problem — a naive CREATE-on-open would swap phantom map entries for
   phantom files.
2. Actor-local schema (`actor_meta` with raw `object_id`/`kind` +
   random 128-bit `database_id` lineage; snapshot/WAL/seen tables without the
   redundant `object_id` columns). Shared *mechanics* (`sqlite_support.zig`:
   open/pragmas/statements/transactions/errors), separate *schema*.
3. Connections via a strictly bounded **per-operation leased LRU cache**
   (default budget 32, wait 5 s → `ConnectionBudgetExhausted`; never exceed
   the budget silently). An activation never pins a connection; scope holds
   only digests. Cache lock never held across open/close/SQL.
4. `catalog.sqlite3` is a **rebuildable enumeration index**, never part of
   actor commit atomicity or the durability authority. Requests always derive
   the path from `object_id` — actors stay addressable with a missing/stale
   catalog.
5. First durable operation commits identity + WAL + dedup ledger atomically in
   the actor file.

**Post-commit rule (correctness, not preference):** once the actor transaction
commits, no catalog/checkpoint/cache error may surface as an `appendOnce()`
error — otherwise the live activation skips `apply()` while a retry returns
`.duplicate` (also not applying) and the actor silently serves stale state
until restart.

### D2. Layout, identity, lifecycle

- Path = hash, not escaping: `actors/v1-f1/k-<sha256(kind)>/<2hex>/<62hex>.sqlite3`
  with domain-separated versioned digests (`"aktorz-kind-path-v1\0" || kind`),
  1-byte fanout default (layout option `f2` is an offline migration).
  Kind length prefix parsed as *byte* length; no Unicode normalization.
- `actor_meta` verified **byte-for-byte on every open**; mismatch (collision,
  operator copy error, wrong restore) fails closed. `SQLITE_OPEN_NOFOLLOW`;
  never rely on `SQLITE_OPEN_EXCLUSIVE` for first-writer arbitration.
- "Exists" = committed `actor_meta` + ≥1 durable row, never "pathname exists"
  (interrupted creation leaves unmaterialized files; reconciliation may remove
  only files with no recognized committed identity — unknown content is
  quarantined, never repurposed).
- Pragmas: WAL + `synchronous=FULL` parity with the shared store;
  `wal_autocheckpoint_pages=64` proposed (benchmark 16/64/256/1000);
  correctness never depends on passivation checkpointing (`destroy()` returns
  void and cannot report failure) — rely on autocheckpoint + last-close
  checkpoint on eviction + explicit maintenance ops (`checkpoint_object`,
  `prepare_backup`). Never manually delete `-wal`/`-shm` files.
- Catalog: `pending → ready` row protocol with a full crash-point table;
  startup reconciles only *pending* rows (O(unfinished), not O(actors));
  `ready`-with-missing-file surfaces as data loss, never silent removal;
  `visit_object_ids(kind, ...)` replaces downstream SQL enumeration;
  `rebuild_catalog()` is the explicit full repair. If creation storms make the
  catalog hot, shard it by hash prefix — never weaken the actor transaction.

### D3. Core API addition: existence probe

Adds the AGENTS.md-requested existence check as an optional provider
capability (defaulted, source-compatible):

```zig
// StoreProvider gains:
probe_fn: ?*const fn (ctx, object_id: []const u8) anyerror!bool = null,
// probe_object(): error.ObjectProbeUnsupported when absent.
```

"Present" = durable state or durable retry history exists. On the *provider*
(not `ScopedStore`) so probing cannot materialize state. Implementations:
memory (lookup without `getOrCreateObject`), shared SQLite (three-table
query), per-actor (path absent → false; present → open without CREATE +
validate identity + require ≥1 row; corrupt/mismatched → error, never false).

### D4. Operability

- `zig build sqlite-layout -- split|merge|verify|rebuild-catalog` (offline
  first; staging root + verification hashes + `MIGRATION_COMPLETE` marker;
  never mutate the source; shared→per-actor→shared round-trip equality is a
  test).
- Per-actor online backup via SQLite backup API under a connection lease; raw
  file copy only after passivate + drain + checkpoint + close. Restore
  requires the actor inactive and re-validates identity.
- Replication: one multiplexed replicator over actor files (not one process
  per actor); durability position embeds
  `{object_digest, database_id, generation, position}` so stale
  acknowledgements after restore/replacement are rejected — composes with §4.
  Catalog needs no replication (rebuildable). Live root must be a local
  filesystem (WAL shm coordination; no NFS/object-store mounts).
- Honest cost table documented: worse for many tiny actors, cross-actor
  analytics, atomic whole-node backup; write-parallelism wins require multiple
  runtimes on disjoint actors (a single non-thread-safe `Runtime` cannot
  demonstrate them — the benchmark matrix includes multi-worker runs).

### D5. Phases

0. Conformance tests vs Memory + shared SQLite; benchmark baselines.
1. Extract `sqlite_support.zig` (no behavior change).
2. `probe_fn` on all stores.
3. Correctness-first backend (open/close per op, directory-scan enumeration,
   full parity + crash tests) — LRU deliberately deferred for auditable
   ownership.
4. Catalog + crash reconciliation + fault-injection tests.
5. Bounded LRU + checkpoint policy + budget benchmarks.
6. Admin tool, backup/restore, TS constructor
   (`Runtime.sqlitePerActor({...})`), docs.
7. Replication proof integration (after §4 exists).

Ship criteria include: no file/catalog row from read-only access; catalog
failure can never become an append error; cache never exceeds budget;
migration round-trips all three tables; benchmarks publish where per-actor
*loses*.

---

## 7. Workstream E — Pure lifecycle core (job 3): extract at trigger, not now

**Decision rule:** extract when, for one actor, this stops being true:

> The runtime starts one lifecycle operation, waits for its definitive result
> on the same call stack, and only then admits the next lifecycle event.

Equivalently: when a lifecycle state can have more than one valid next
external event, or an observed failure leaves external state unknown.

- **Triggers**: a non-blocking/asynchronous durability proof (§4 kept
  synchronous avoids this), ownership/lease operations with ambiguous CAS
  (§5 — but its races live in the *package's* pure logic, not core),
  runtime-owned timers/alarms, admission that waits, overlapping background
  snapshot/passivation, epoch-fenced completions arriving across activation
  generations.
- **Non-triggers**: new synchronous stores, the per-actor backend (§6),
  poison-and-rebuild (§3), snapshot policies, caller-driven `passivateIdle`,
  a *blocking* durability proof with definitive results.
- Cost honesty: extraction ≈ 2–3× the current 134-line lifecycle (20–25
  events, 15–18 effects, 10–12 phases, resource tables, executor pump); the
  13-line persist-before-apply proof becomes five separated transitions. Not
  justified while everything runs inline on one stack.
- **Do now regardless** (Phase A, folded into FIX.md): characterization tests
  for activation/replay/append/apply/snapshot/passivation ordering and reply
  ownership on every failure path; the ownership/contract fixes; and a store
  failure-knowledge contract (declare current providers' errors
  definitely-not-committed, or treat unclassified failures as unknown ⇒
  discard/recover).
- Design ready on the shelf: per-activation `LifecycleCore` (map stays an
  executor index; `phase` is the authority), events/effects as tagged unions
  carrying opaque handles (`BlobRef`, `ServiceRef`, ... — never slices,
  allocators, or `anyerror`; executor keeps `FailureRef` + semantic class +
  `CommitKnowledge`), copy-then-commit `step()` (allocation failure must not
  strand a phase whose effect was never emitted), explicit
  `Progress { snapshot_seq ≤ applied_seq ≤ durable_seq }`, `AfterSnapshot`
  continuations, `OperationId` + activation-generation fencing on every
  completion. Don't port the mailbox (the supported contract is one request;
  the ArrayList cannot actually queue same-actor work today). SQLite replay
  blobs are statement-scoped — clone or finish apply before crossing an event
  boundary. Simulation: five crash points per effect, ~17 invariants.
- Migration when triggered: characterize → introduce internal event/effect
  types + port `processOne` as **one short PR stack** (no long-lived shadow
  machine) → port activation/passivation → only then add distributed features
  as events. Public API unchanged throughout.

---

## 8. Cross-workstream reconciliation

Decisions where the six analyses touch the same code, resolved:

1. **`ScopedStore.VTable` evolution** (one coordinated plan, all optional
   fields defaulted so manual initializers stay valid):
   - A3 (required): `lookup_seen_message`; `AppendResult.duplicate` becomes
     `SeenMessage { seq, reply }`.
   - B (optional): `durability: ?*const DurabilityVTable = null`.
   - C (optional): `claim_fence: ?*const fn (...) = null`.
   - D adds `StoreProvider.probe_fn: ?... = null` (provider-level, not scope).
   Sequence them in this order; land A3 before B so `AppendReceipt` wraps the
   *new* duplicate shape (a duplicate receipt carries both the stored
   `SeenMessage` and its covering durability position).
2. **Discard vs passivate** (§3/§5 agree): one core primitive
   `discard`/`invalidate_activation` that destroys without snapshotting and
   never calls `makeSnapshot`. Used by post-append apply failure (A2), stale
   fence / authority loss (C), and future pressure release. `passivate`
   remains the graceful, snapshot-while-authorized path and must
   snapshot-before-unmap (FIX.md F3).
3. **Fence × durability position** (jobs 1+2): when both are enabled, the
   position is bound to the fence (conceptually
   `DurabilityPosition { fence, position }`); a proof for epoch E cannot
   authorize a reply after the replica authority advances to E+1; new-owner
   restore claims the remote fence at E+1 *before* reading. Fenced dup lookup
   (C) and barrier-gated recovery (B) compose: stale owners can neither reply
   from the ledger nor expose unproven local tails.
4. **Preflight ordering with gates**: per-request order once all features
   exist — admission (fence) → outstanding-durability preflight →
   `lookup_seen_message` (validated) → decide → admission → append (fenced,
   receipt) → apply → wait durable → snapshot policy → admission → reply.
   Each check is skipped when its capability is absent; the embedded runtime
   reduces to preflight-dedup → decide → append → apply → snapshot → reply.
5. **Pure-logic placement** (jobs 2+3 agree): distributed `logic.zig` is pure
   from day one (it owns the races); core stays direct until an §7 trigger.
   If §4 Phase 2's replicated store ever needs a non-blocking proof, that is
   the §7 trigger — extract first, then make the proof asynchronous.
6. **Poisoning is one mechanism** (jobs 1/3/5): the A2 `ActorSlot` states are
   the single design; B's proof failures do *not* poison (transient,
   token-pending), C's stale-fence errors discard without poisoning (recovery
   under the new fence is expected), only recovery-callback failures poison.
7. **Phantom objects / existence** (jobs 4+6): `StoreProvider.probe_fn` is
   the actor-existence seam; `lookupRecordedMessage` (future) is the
   message-outcome seam; neither may materialize state; they are distinct
   APIs.

## 9. Unified roadmap

Ordered to keep every stage shippable and the core always releasable:

| Stage | Content | Source |
|---|---|---|
| 0 | FIX.md F1–F10: ownership/memory-safety repairs, passivation ordering, characterization tests, doc corrections | jobs 3/5/6 |
| 1 | Workstream A: `ActorSlot` lifecycle, apply() contract, preflight dedup + `SeenMessage`, error taxonomy, TS ABI v4, dedup docs | jobs 5/6 |
| 2 | Workstream B Phase 1: durability seam + gated test store (no networking) | job 1 |
| 3 | Workstream D Phases 1–3: `sqlite_support` extraction, `probe_fn`, correctness-first per-actor backend (parallelizable with 2) | job 4 |
| 4 | Workstream D Phases 4–6: catalog, LRU, tooling, TS bindings | job 4 |
| 5 | Workstream C Phases 0–1: pure distributed model + simulator; neutral core fence plumbing | job 2 |
| 6 | Workstream C Phases 2–3: coordinator, strict gateway, shared-SQLite profile | job 2 |
| 7 | Workstream B Phase 2 × C Phase 4: replicated store, remote authority, fence-bound proofs, restore-from-replica | jobs 1/2 |
| — | Workstream E: only at its trigger (most likely entering stage 7 with an async proof) | job 3 |

Every stage: `zig build test` + `zig build sqlite-test` + ReleaseFast bench
smoke per AGENTS.md; stages 2+ add their own suites (gated-store tests,
conformance suites, simulator, multi-process tests).

## 10. What not to build (merged)

- In core: event loops, futures, background tasks, hidden retries or message
  re-execution, automatic rollback of committed-but-unproven mutations,
  application-visible proof tokens, epochs/leases/placement, LTX/object-store
  clients, credentials/metrics/control-plane config.
- In the distributed package v1: placement policy, capacity
  advertisements/reservations, pressure-shedding *policy* (the manual
  release/drain primitive ships; policy later), rebalancing, live migration,
  authority-store list/watch/TTL, consensus/membership services, multi-region,
  transparent protocol downgrade, forced takeover of live nodes.
- In dedup: generic exactly-once claims, automatic read dedup, partial
  payload-conflict detection, TTL-based retention.
- In the per-actor backend: catalog as authority, per-actor replication
  processes, network-filesystem roots, silent budget overruns.
- Anywhere: a mode that *looks* like exclusive ownership or remote durability
  without the corresponding fence/proof actually enforced.
