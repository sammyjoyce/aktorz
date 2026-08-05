# Required Fixes (independent of the roadmap)

Defects and gaps identified during the six oracle design explorations
(2026-08-05, job ids in [PLAN.md](PLAN.md)) that must be fixed **regardless**
of which PLAN.md workstreams are ever built. All code claims below were
re-verified against the current working tree (`src/core.zig`,
`src/memory_store.zig`) before writing this list.

Ordering is by severity. Each item: what/where, why it matters, the fix, and
how to verify. "Found by" cites the oracle job(s).

> **Status (2026-08-05): all items addressed.**
> F1–F6 implemented in `src/core.zig`, `src/memory_store.zig`,
> `src/sqlite_store.zig`, `src/typescript/ffi.zig`; F7/F9 documentation landed
> (`docs/deduplication.md` new, README/docs/typescript.md/docs/sqlite_store.md
> reworded, Zig doc comments, TS JSDoc, AGENTS.md lessons); F8 tests added in
> `src/core_test.zig` (16 tests incl. the non-idempotent counter fixture and
> FlakyStore fault injection), `src/sqlite_store.zig` (restart retry,
> post-append failure across restart, SequenceConflict parity, probe), and
> `test/typescript-durability.mjs` (apply-throws + first-error-wins step); F10
> shipped as `StoreProvider.probe_fn`/`probeObject()` with memory + SQLite
> implementations. The F4 remediation uses the minimum contract from this file
> (discard-without-snapshot + `PostAppendApplyFailed`) plus the poison-loop
> guard (`PoisonedActor`, `retryPoisoned()`); the fuller PLAN §3 items
> (preflight dedup lookup, TS ABI v4 error codes) remain PLAN work.
> Verified: `zig build test`, `zig build sqlite-test`, `zig build lint`,
> `npm run test:node`, `npm run test:bun`, ReleaseFast `sqlite-churn` bench
> smoke, and a mutation check (intentionally breaking the duplicate branch
> fails the new tests).

Baseline verification for every item: `zig build test` and
`zig build sqlite-test` must pass; use `std.testing.allocator` so leaks and
double-frees fail tests.

---

## F1. Double-free in `getOrActivate()` cleanup (memory safety)

- **Where:** `src/core.zig`, `getOrActivate()` — the per-component
  `errdefer`s (`service.destroy`, `store.destroy`, `alloc.destroy(activation)`,
  `free(kind_copy)`, `free(key_copy)`, `free(object_id)`) remain registered
  *after* `errdefer activation.destroy(self.alloc)` is added post-init.
- **Why:** if `loadSnapshot()`, service `loadSnapshot()`, `replayAfter()`, or
  `activations.put()` fails, `activation.destroy()` frees service, store,
  kind, key, object_id, and the activation — then the earlier errdefers run
  again in reverse order and free/destroy the same resources a second time.
  Double-free → panic under a checking allocator, memory corruption in
  unchecked builds. This is the path every replay-failure feature would
  exercise more often.
- **Fix:** split allocation from recovery. `allocate_activation()` registers
  component errdefers and performs **no fallible operation after** ownership
  transfers into the initialized struct; the caller then owns cleanup through
  exactly one mechanism (e.g. `var owned = true; defer if (owned)
  activation.destroy(alloc);`). Never register both component errdefers and
  `activation.destroy()` in the same scope.
- **Verify:** new test — replay `apply()` fails during cold activation;
  assert the error propagates, no activation is retained, and
  `std.testing.allocator` reports no double free or leak. Also cover
  `activations.put()` OOM via a failing allocator.
- **Found by:** job 5 (§1); job 3 flagged the surrounding characterization
  gap.

## F2. Reply ownership leaks on error paths

- **Where:** `src/core.zig` — `processOne()` moves `decision.reply` into
  `final_reply` with no `errdefer`; `processMailbox()` accumulates
  `first_reply` with no `errdefer`.
- **Why:** any failure after the detach (`appendOnce`, `apply`,
  `snapshotActivation`; or a later mailbox item's error) leaks the reply's
  backing allocation. Becomes a routine leak once post-append failures are a
  normal contained path (PLAN A1) or a durability wait can fail (PLAN B).
- **Fix:** `errdefer if (final_reply) |r| r.deinit();` immediately after the
  detach in `processOne()`; equivalent `errdefer` for `first_reply` in
  `processMailbox()`; on activation invalidation, free any captured reply and
  let `Activation.destroy()` drain remaining mailbox payloads.
- **Verify:** tests with a decision containing both mutation and reply where
  (a) `appendOnce` fails, (b) `apply` fails, (c) `snapshotActivation` fails —
  no leak under `std.testing.allocator`.
- **Found by:** jobs 3 and 5 independently.

## F3. `passivateByObjectId()` removes the activation before snapshotting

- **Where:** `src/core.zig`, `passivateByObjectId()` — `fetchRemove()` runs
  first; `snapshotActivation()` failures then propagate with the activation
  already out of the map and never destroyed.
- **Why:** a snapshot/compaction error leaves the activation unreachable
  (leak; store scope never closed) and, worse, the actor silently loses its
  in-memory state ownership path. Affects `passivate()`, `passivateIdle()`,
  `shutdown()`, and TS `close()`.
- **Fix:** reorder — look up, reject if `running`, snapshot if dirty, and
  only after the snapshot succeeds `fetchRemove` + `destroy`. On snapshot
  failure return the error with the activation still mapped and usable.
- **Verify:** test — store `writeSnapshot` fails during passivation; assert
  the error is returned, the actor remains mapped, a later request works, and
  nothing leaks.
- **Found by:** jobs 1, 3, and 5 independently (job 1 also reorders this path
  for durability gating).

## F4. Post-append `apply()` failure: silent divergence and contaminated snapshots

- **Where:** `src/core.zig`, `processOne()` — after `appendOnce()` returns
  `.inserted`, `try activation.service.apply(...)` propagates the error while
  the mutation **and its reply are already durably committed**; `next_seq` is
  not advanced and the activation stays mapped.
- **Why (three compounding hazards):**
  1. *Divergence:* durable seq `s` is committed; in-memory state is unknown
     (old / partial / full). Read-only requests keep serving from it.
  2. *Contaminated snapshot:* `snapshotActivation()` labels the snapshot
     `next_seq - 1 = s - 1` while serializing state that may include event
     `s`'s effects → recovery replays `s` over them (double-apply) — reachable
     via later passivation/shutdown/`close()` whenever `dirty_ops > 0`.
  3. *Unsafe stored reply:* a same-id retry re-runs `decide()`; if it emits a
     mutation, `appendOnce` returns the stored success reply against the
     stale activation.
- **Minimum required fix (regardless of PLAN):** on post-append `apply()`
  failure, destroy the activation **without snapshotting**, mark the actor so
  the next request recovers from snapshot+WAL, and return a distinct error
  (`error.PostAppendApplyFailed`) instead of the raw callback error. The full
  contract (actor slots, poison-loop guard, preflight dedup, TS error codes)
  is PLAN §3; the discard-without-snapshot + distinct-error core is not
  optional.
- **Verify:** tests — (a) apply fails once → activation discarded, no
  snapshot written, retry recovers and converges with the mutation applied
  exactly once; (b) with `dirty_ops > 0`, passivation/shutdown after the
  failure never calls the failed instance's `makeSnapshot`; (c) same-id retry
  returns the stored reply only after recovery succeeded; (d) deterministic
  replay failure does not re-run recovery on every request (guard).
- **Found by:** job 5 (full analysis); flagged by CONTEXT.md and jobs 1/3/6.

## F5. `MemoryNodeStore.appendOnce()` does not enforce sequence uniqueness

- **Where:** `src/memory_store.zig`, `appendOnce()` — checks only
  `seen(message_id)`, then appends to the WAL list without any `seq` conflict
  check. SQLite, by contrast, has `PRIMARY KEY (object_id, seq)` and surfaces
  `error.SequenceConflict`.
- **Why:** after any bug (e.g. F4) leaves `next_seq` un-advanced, a second
  mutation reuses seq `s`: SQLite fails loudly; memory silently records two
  WAL entries at the same sequence → malformed replay history. The two
  built-in stores disagree on a core invariant, so memory-backed tests cannot
  catch sequence bugs (job 3: "do not use MemoryNodeStore alone as the oracle
  for sequence conflicts").
- **Fix:** reject an append whose `seq` already exists (or `<=` last WAL seq)
  with `error.SequenceConflict`, matching the SQLite behavior.
- **Verify:** parity test run against both stores: append seq `s` twice with
  different message ids → both stores return `SequenceConflict`; replay
  yields strictly increasing sequences.
- **Found by:** job 5; job 3 (parity warning).

## F6. TypeScript bridge erases the primary callback error

- **Where:** `src/typescript` bridge (`Bridge.call()` clears `last_error` at
  the start of **every** callback invocation) + `BridgeService.destroy()`
  itself going through `Bridge.call`.
- **Why:** during cleanup after a failure (already reachable today via replay
  cleanup; routine once F4's discard lands), a successful `destroy()` erases
  the original `apply`/`loadSnapshot` message and a failing `destroy()`
  replaces it — the caller gets a cleanup message instead of the root cause.
- **Fix:** first-error-wins lifecycle — clear `last_error` once at the start
  of each exported runtime operation, never inside `Bridge.call()`; callback
  error capture keeps the first error; clear only after the native result has
  copied the message.
- **Verify:** Node + Bun tests — `apply` throws `"boom"`, `destroy` also
  throws during cleanup; caller's error message is `"boom"`.
- **Found by:** job 5 (§2).

## F7. Documentation corrections: deduplication wording (audit)

- **Where/what:** no literal "exactly-once" claim exists, but ~15 locations
  use misleading or under-qualified wording. Highest-value corrections:
  - `README.md`: "deduplicated by message ID" / "retry-safe" → per-actor,
    mutating-decision-only wording; move retention detail off the landing
    page; add a routed "Deduplication semantics" section.
  - `docs/typescript.md`: "idempotency implementation", "persisted message
    IDs continue to deduplicate retries" → scoped wording + a full
    "Message IDs and deduplication" section (decide-runs-first, no-mutation
    retries bypass the ledger, not exactly-once).
  - `docs/sqlite_store.md`: "u128 idempotency key semantics" / "keeps
    idempotency and WAL append atomic" / "idempotency history grows" →
    per-actor dedup key, mutation-log + dedup-record atomicity, retention
    caveat incl. consequence of any future pruning.
  - `typescript/types.ts` / `runtime.ts`: JSDoc for `ActorDecision.mutation`
    (presence gates persistence + dedup), `decide` (may re-run),
    `apply` (deterministic, replay-safe, also a replay callback),
    `request`/`tell` (`messageId` scope + conflicting-payload rule).
  - `src/core.zig`: doc comments on `Decision`, `appendOnce`
    (per-scope key; retention horizon; no payload comparison),
    `Runtime.request`.
  - New `docs/deduplication.md` as the reference page; README/docs link to it.
  - `AGENTS.md` lesson: "Deduplication is per actor and only reached for
    decisions with a mutation: retries re-run `decide()`, reply-only
    decisions are not recorded, and docs must never describe this as generic
    or exactly-once request execution."
  Paste-ready text for all of the above is in the job-6 response (PLAN §3.A5
  holds the semantic summary).
- **Also document while touching these files:** same-id/different-payload is
  a client bug (undetected today); `NULL` vs empty reply distinction; ledger
  unbounded by default; remote routes delegate all of this to `Forwarder`.
- **Verify:** grep the repo for `idempot`, `retry-safe`, `exactly` after the
  edit; each remaining hit must be a deliberate, qualified use.
- **Found by:** job 6 (full audit table with line references).

## F8. Test-suite gaps that let the above go unnoticed

- **Where/why:**
  - The existing SQLite dedup test retries `set|hello` — an idempotent
    command with a constant `"ok"` reply — so it passes even if duplicates
    re-apply or the stored reply is ignored.
  - The restart test never retries a message id across the reopen, so the
    durable-ledger promise is untested.
  - There are no direct `Runtime` lifecycle tests in `src/core.zig` (cold
    activation order, replay order, failure-path ownership) and no
    `MemoryNodeStore` tests.
- **Fix:** add a deliberately non-idempotent fixture (`inc`, `get`,
  `set|<v>`, `inc-no-reply`) with `decide_calls`/`apply_calls` counters, then
  pin the boundary:
  1. mutating retry returns the *first* reply and applies once
     (`decide_calls == 2`);
  2. read-only retry re-executes and may observe newer state;
  3. same id, different mutating payload → first stored result (comment: flips
     to `MessageIdConflict` if strict binding ever ships);
  4. recorded id bypassed when the retry decides no mutation (both the
     conflicting-payload and the state-dependent `ensure-closed` variants);
  5. same id independent across actors;
  6. mutation-without-reply duplicates return null and apply once;
  7. dedup survives passivation after WAL compaction
     (`snapshot_every = 1`; assert snapshot=1/WAL=0/seen=1 rows);
  8. SQLite: duplicate returns stored reply after full runtime+store restart;
  plus the F1–F5 failure-path characterization tests (activation order,
  reply ownership on every failure, passivation snapshot-failure behavior).
- **Verify:** mutate the runtime intentionally (e.g. skip the duplicate
  branch) and confirm the new tests fail.
- **Found by:** job 6 (fixture analysis); job 3 (characterization phase A).

## F9. Contract documentation gaps in core APIs

Document now so later features do not reinterpret behavior:

1. **Store failure knowledge:** state explicitly that the built-in stores
   return an `appendOnce()` error only when the append definitely did not
   commit; any future store that cannot promise this must be treated as
   ambiguous (caller retries same id; ledger reconciles). (Job 3 §9; job 5's
   orderings depend on it.)
2. **`compactBefore()`:** compaction must not remove the last representation
   required to recover any mutation covered by the current snapshot; the
   dedup ledger is deliberately *not* compacted. (Jobs 1 and 6.)
3. **Snapshot failure after successful `apply()`:** a committed-command
   maintenance error, distinct from F4's divergence — never poison the actor
   for it; prefer returning the computed reply and retrying snapshotting
   later, or at minimum name the error distinctly. (Job 5 §10.)
4. **Store callbacks are non-reentrant** with respect to the runtime (must not
   call back into `Runtime`), matching the existing reentrancy rule for
   `decide()`. (Job 1.)
5. **`apply()` doc comment** (PLAN §3.A1 wording): deterministic, replay-safe,
   state-only, effectively infallible for compatible persisted mutations;
   the error union is a containment boundary. Mirror in
   `typescript/types.ts` (incl. "must not be `async`; an already-started
   async prefix cannot be cancelled").
- **Verify:** doc comments compile (`zig build test` builds docs paths);
  README/docs cross-links resolve.
- **Found by:** jobs 1, 3, 5, 6.

## F10. Known-but-unfixed API gap: actor existence probing (tracking)

- **Where:** `MemoryNodeStore.openScoped` materializes phantom objects;
  downstream consumers hand-roll existence probes (AGENTS.md lesson).
- **Status:** the agreed remedy is `StoreProvider.probe_fn` (optional,
  provider-level, non-materializing — PLAN §6.D3). Listed here because the
  *interim* rule must stay documented until it ships:
  `open().loadSnapshot()` is **not** an existence probe and will create the
  object.
- **Verify (when shipped):** probes create no state; memory phantom entries
  report absent; snapshot-only / WAL-only / seen-only states report present.
- **Found by:** job 4 (design); AGENTS.md (original report); job 6 (probe
  naming constraints).

---

## Suggested landing order

1. F1 + F2 (pure ownership repairs; no behavior change) — one PR.
2. F3 (passivation reorder) — small PR with its test.
3. F8 fixture + characterization tests (lock current behavior before changing
   it).
4. F4 minimum fix + F5 parity + F6 bridge lifecycle — the behavior-changing
   PR, tests from F8 updated intentionally.
5. F7 + F9 documentation pass (can parallel any of the above).
6. F10 tracks into PLAN stage 3.

Per AGENTS.md, every PR: `zig build test`, `zig build sqlite-test`, and for
anything touching the hot path a ReleaseFast bench smoke
(`zig build -Doptimize=ReleaseFast bench -- --mode sqlite-churn
--duration-seconds 1 --num-actors 100`).
