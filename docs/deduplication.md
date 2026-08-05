# Deduplication semantics

Aktorz provides **per-actor mutating-decision deduplication with stored-reply
return**. With a persistent backend such as SQLite, the message-ID ledger is
durable across passivation and process restart.

This is a guarantee about mutation records written through
`ScopedStore.appendOnce()`. It is **not** generic exactly-once request
execution, and it is not read idempotency.

## Request flow

For a locally processed request, the runtime:

1. activates or finds the addressed actor;
2. calls `decide()` with the current payload;
3. returns the newly computed reply directly when the decision has no
   mutation; or
4. calls `appendOnce()` when the decision contains a mutation.

For a new `(actor, message ID)`, `appendOnce()` records the mutation and
optional reply in one atomic transaction; only then does the runtime call
`apply()` and return that reply.

For an existing `(actor, message ID)`, `appendOnce()` does not append another
mutation. The runtime skips the live `apply()` call, discards the reply
computed by the current `decide()` invocation, and returns the optional reply
stored with the first recorded mutation.

## Important boundary

Duplicate lookup occurs **after** `decide()` and only when the current
decision contains a mutation.

A repeated message ID therefore receives the stored reply only when the
repeated attempt also produces a mutation. If the repeated attempt produces no
mutation — for example because the actor is now already in the requested state
— the ledger is not consulted and the newly computed reply is returned.

`decide()` runs on every request attempt, including attempts whose mutation is
later identified as a duplicate. Duplicate delivery is not duplicate-free
execution: parsing, validation, and decision computation happen again.

## Decision matrix

| Current decision | Deduplication behavior |
|---|---|
| Mutation and reply | Record both on the first occurrence; later mutating occurrences return the first stored reply without a second append or live `apply()` |
| Mutation and no reply | Record the mutation and an absent reply; later mutating occurrences return no reply |
| No mutation and reply | Do not read or write a message-ID record; return the current reply |
| No mutation and no reply | Do not read or write a message-ID record |
| `decide()` error | Return the error before duplicate lookup |

An empty reply is distinct from no reply: an empty byte string is stored and
returned as zero-length bytes, while an absent reply stays absent.

## Message-ID scope

A message ID is scoped to one actor address. The built-in stores key the
ledger by the actor's internal `object_id` and the `u128` message ID, so the
same numeric ID may be used independently by different actors.

Within one actor, a message ID must identify one logical request with stable
payload bytes for the full deduplication-retention horizon.

## Reusing an ID with a different payload

Reusing the same actor and message ID with a different payload is a client
bug. Aktorz does not currently detect it. The new payload is still passed to
`decide()`:

- if it produces a mutation, the first stored reply is returned and the newly
  computed mutation and reply are discarded;
- if it produces no mutation, the ledger is bypassed and the newly computed
  reply is returned;
- if `decide()` fails, that error is returned.

Applications must not rely on these conflicting-reuse behaviors.

## Snapshots, passivation, and restart

Snapshots compact mutation-log entries but never remove message-ID records.
Passivation destroys the in-memory activation, not its stored deduplication
history. A later activation of the same actor still recognizes a repeated
mutating decision.

`MemoryNodeStore` retains records for the lifetime of that store instance.
`SQLiteNodeStore` retains them across runtime close and process restart when
the same database is reopened.

Remote routes are handed to the configured `Forwarder`; the forwarding
implementation is responsible for preserving equivalent semantics.

## Retention

`SQLiteNodeStore` currently retains `actor_seen_message` rows indefinitely.
There is no automatic pruning policy: storage grows by one ledger row per
unique mutating message ID, including the optional stored reply, and snapshot
cadence does not bound this growth.

Any future retention policy must be explicit. Once a record is removed, an old
retry is outside the guarantee and may be applied as a new mutation.

## Failure interactions

The mutation and its reply are committed *before* the live `apply()` call:

- If `apply()` fails after the append, the runtime discards the activation
  without snapshotting it and returns `PostAppendApplyFailed`. The mutation is
  durable; retrying the **same** message ID first reconstructs the actor from
  its snapshot and log (replaying the mutation once) and then returns the
  stored reply. Retrying with a *new* message ID may append a second mutation
  and is incorrect.
- If recovery itself fails deterministically (snapshot decode or replay
  `apply()` rejection), the actor is quarantined: requests return
  `PoisonedActor` — including retries whose stored reply exists — until
  `retryPoisoned()` or a process restart succeeds. A stored reply is returned
  only after recovery proves the mutation is present in memory.

## What is not provided

- **Exactly-once request execution.** `decide()` runs before duplicate
  lookup, non-mutating decisions are re-executed, and `apply()` also runs
  during activation replay.
- **Retry-stable reads.** Retrying a read with the same ID re-evaluates it
  against current state.
- **At-least-once delivery.** Aktorz accepts caller-supplied message IDs;
  delivery, retry scheduling, and backoff are transport or application
  concerns.
- **Payload conflict detection.** The original request payload is neither
  stored nor compared.

## Caller rules

1. Use a fresh message ID for each logical request to an actor.
2. Reuse that ID only when retrying the same payload and operation.
3. Do not expect non-mutating replies to be stable across retries.
4. Keep IDs unique for at least the backend's documented retention horizon.
5. Treat `decide()` as repeatable and `apply()` as deterministic, replay-safe,
   and free of externally visible side effects.
