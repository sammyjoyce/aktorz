// The Node-level durability contract a SQLite runtime must satisfy:
//
//  1. create a SQLite runtime at a temporary path
//  2. register a test service
//  3. apply a mutating request and save its reply
//  4. shut down and close the runtime
//  5. open a new runtime against the same database
//  6. register the service and verify state reconstruction
//  7. resend the original message ID and payload
//  8. verify the original reply is returned and the mutation is not applied twice
//  9. passivate, reopen, and repeat the verification

import assert from "node:assert/strict"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Runtime, utf8 } from "../dist/index.js"

const root = mkdtempSync(join(tmpdir(), "aktorz-durability-"))
const database = join(root, "durability.sqlite3")
const address = { kind: "ledger", key: "acct-1" }

// A ledger records every applied entry so a double-apply is observable in the
// state itself, not only in the reply.
function registerLedger(runtime) {
  runtime.register("ledger", {
    create: () => ({ balance: 0, entries: [] }),
    loadSnapshot(state, snapshot) {
      const restored = JSON.parse(utf8(snapshot))
      state.balance = restored.balance
      state.entries = restored.entries
    },
    makeSnapshot: (state) => JSON.stringify({ balance: state.balance, entries: state.entries }),
    decide(state, message) {
      const entry = JSON.parse(utf8(message))
      return {
        mutation: JSON.stringify(entry),
        reply: JSON.stringify({ balance: state.balance + entry.amount, applied: state.entries.length + 1 }),
      }
    },
    apply(state, mutation) {
      const entry = JSON.parse(utf8(mutation))
      state.balance += entry.amount
      state.entries.push(entry.id)
    },
  })
}

function open(options = {}) {
  const runtime = Runtime.sqlite({ path: database, snapshotEvery: 64, ...options })
  registerLedger(runtime)
  return runtime
}

const originalMessageId = 0x0123_4567_89ab_cdef_fedc_ba98_7654_3210n
const originalPayload = JSON.stringify({ id: "entry-1", amount: 250 })

try {
  // Steps 1-3: create, register, mutate, save the reply.
  let runtime = open()
  const originalReply = utf8(runtime.request(address, originalMessageId, originalPayload))
  assert.deepEqual(JSON.parse(originalReply), { balance: 250, applied: 1 })

  // Step 4: shut down and close.
  runtime.shutdown()
  runtime.close()

  // Steps 5-6: reopen and verify state reconstruction through a fresh mutation.
  runtime = open()
  assert.deepEqual(
    JSON.parse(utf8(runtime.request(address, 2n, JSON.stringify({ id: "entry-2", amount: 50 })))),
    { balance: 300, applied: 2 },
    "state is reconstructed from the durable log after reopen",
  )

  // Steps 7-8: resend the original message ID and payload.
  assert.equal(
    utf8(runtime.request(address, originalMessageId, originalPayload)),
    originalReply,
    "a duplicate message ID returns the persisted reply",
  )
  assert.deepEqual(
    JSON.parse(utf8(runtime.request(address, 3n, JSON.stringify({ id: "probe-1", amount: 0 })))),
    { balance: 300, applied: 3 },
    "the deduplicated mutation was not applied twice",
  )

  // Step 9: passivate, reopen, and repeat the verification.
  assert.equal(runtime.passivate(address), true)
  assert.equal(
    utf8(runtime.request(address, originalMessageId, originalPayload)),
    originalReply,
    "deduplication survives passivation within one process",
  )
  runtime.close()

  runtime = open()
  assert.equal(
    utf8(runtime.request(address, originalMessageId, originalPayload)),
    originalReply,
    "deduplication survives passivation and reopen",
  )
  assert.deepEqual(
    JSON.parse(utf8(runtime.request(address, 4n, JSON.stringify({ id: "probe-2", amount: 0 })))),
    { balance: 300, applied: 4 },
    "the passivated snapshot carries exactly the applied entries",
  )

  // A different payload under the same message ID is still deduplicated by the
  // native runtime. Callers that must distinguish payloads have to fold a
  // payload digest into the message ID they derive.
  assert.equal(
    utf8(runtime.request(address, originalMessageId, JSON.stringify({ id: "entry-1", amount: 999_999 }))),
    originalReply,
    "native deduplication is keyed on the message ID alone",
  )

  runtime.shutdown()
  runtime.close()
} finally {
  rmSync(root, { recursive: true, force: true })
}

console.log("aktorz TypeScript SQLite durability contract test passed")
