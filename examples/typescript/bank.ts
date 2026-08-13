// A bank account actor: message-ID deduplication as retry protection.
//
// TypeScript port of `examples/bank_example.zig`, focused on aktorz's
// deduplication contract (docs/deduplication.md):
//
//   * `messageId` is a caller-chosen bigint (full unsigned 128-bit range),
//     scoped to one actor address. Use one ID per logical request.
//   * When decide() returns a mutation, the first append records the mutation
//     and its optional reply. A retried mutating attempt with the same ID
//     appends nothing, applies nothing, and returns the stored reply.
//   * Decisions WITHOUT a mutation (reads, domain rejections) are neither
//     looked up nor recorded — retrying them re-runs decide() against
//     current state. This is not exactly-once request execution.
//
// Run from examples/typescript after `npm install`:
//   node bank.ts     (Node 23.6+; Node 22.6+ needs --experimental-strip-types)
//   bun bank.ts

import { Runtime, utf8, type ActorService } from "aktorz"

// ── Protocol ────────────────────────────────────────────────────────────────

type BankCommand =
  | { readonly type: "deposit"; readonly amountCents: number; readonly memo: string }
  | { readonly type: "withdraw"; readonly amountCents: number; readonly memo: string }
  | { readonly type: "set-overdraft"; readonly limitCents: number }
  | { readonly type: "freeze"; readonly reason: string }
  | { readonly type: "unfreeze" }
  | { readonly type: "balance" }

type BankEvent =
  | { readonly type: "deposited"; readonly amountCents: number; readonly memo: string }
  | { readonly type: "withdrew"; readonly amountCents: number; readonly memo: string }
  | { readonly type: "overdraft-set"; readonly limitCents: number }
  | { readonly type: "frozen"; readonly reason: string }
  | { readonly type: "unfrozen" }

interface BankState {
  status: "active" | "frozen"
  balanceCents: number
  overdraftLimitCents: number
  txCount: number
}

type BankReply =
  | { readonly ok: true; readonly txNumber: number | null; readonly balanceCents: number; readonly status: string }
  | { readonly ok: false; readonly error: string }

// ── Service ─────────────────────────────────────────────────────────────────

const accountService: ActorService<BankState> = {
  create: () => ({ status: "active", balanceCents: 0, overdraftLimitCents: 0, txCount: 0 }),

  makeSnapshot: (state) => JSON.stringify(state),
  loadSnapshot(state, snapshot) {
    Object.assign(state, JSON.parse(utf8(snapshot)) as BankState)
  },

  decide(state, message) {
    const command = JSON.parse(utf8(message)) as BankCommand

    switch (command.type) {
      case "balance":
        // Read-only: no mutation, so this decision never joins the
        // deduplication ledger and a retried read can observe newer state.
        return { reply: receipt(state, null) }

      case "deposit": {
        const invalid = invalidAmount(command.amountCents)
        if (invalid) return { reply: fail(invalid) }
        if (state.status === "frozen") return { reply: fail("account is frozen") }
        return {
          // The reply stored alongside this mutation is what a retry of the
          // same message ID gets back: the ORIGINAL receipt.
          mutation: event({ type: "deposited", amountCents: command.amountCents, memo: command.memo }),
          reply: receipt(
            { ...state, balanceCents: state.balanceCents + command.amountCents },
            state.txCount + 1,
          ),
        }
      }

      case "withdraw": {
        const invalid = invalidAmount(command.amountCents)
        if (invalid) return { reply: fail(invalid) }
        if (state.status === "frozen") return { reply: fail("account is frozen") }
        if (state.balanceCents - command.amountCents < -state.overdraftLimitCents) {
          // Rejection without a mutation: nothing is recorded for this
          // message ID, so a later retry re-decides against current state
          // (and may then succeed).
          return { reply: fail("insufficient funds") }
        }
        return {
          mutation: event({ type: "withdrew", amountCents: command.amountCents, memo: command.memo }),
          reply: receipt(
            { ...state, balanceCents: state.balanceCents - command.amountCents },
            state.txCount + 1,
          ),
        }
      }

      case "set-overdraft": {
        if (!Number.isSafeInteger(command.limitCents) || command.limitCents < 0) {
          return { reply: fail("overdraft limit must be a non-negative integer") }
        }
        return {
          mutation: event({ type: "overdraft-set", limitCents: command.limitCents }),
          reply: receipt({ ...state, overdraftLimitCents: command.limitCents }, state.txCount + 1),
        }
      }

      case "freeze":
        if (state.status === "frozen") return { reply: fail("already frozen") }
        return {
          mutation: event({ type: "frozen", reason: command.reason }),
          reply: receipt({ ...state, status: "frozen" }, state.txCount + 1),
        }

      case "unfreeze":
        if (state.status !== "frozen") return { reply: fail("not frozen") }
        return {
          mutation: event({ type: "unfrozen" }),
          reply: receipt({ ...state, status: "active" }, state.txCount + 1),
        }
    }
  },

  apply(state, mutation) {
    const e = JSON.parse(utf8(mutation)) as BankEvent
    state.txCount += 1
    switch (e.type) {
      case "deposited":
        state.balanceCents += e.amountCents
        break
      case "withdrew":
        state.balanceCents -= e.amountCents
        break
      case "overdraft-set":
        state.overdraftLimitCents = e.limitCents
        break
      case "frozen":
        state.status = "frozen"
        break
      case "unfrozen":
        state.status = "active"
        break
    }
  },
}

function invalidAmount(amountCents: number): string | null {
  if (!Number.isSafeInteger(amountCents) || amountCents <= 0) return "amount must be a positive integer"
  return null
}

function event(e: BankEvent): string {
  return JSON.stringify(e)
}

function receipt(state: BankState, txNumber: number | null): string {
  const reply: BankReply = { ok: true, txNumber, balanceCents: state.balanceCents, status: state.status }
  return JSON.stringify(reply)
}

function fail(error: string): string {
  const reply: BankReply = { ok: false, error }
  return JSON.stringify(reply)
}

// ── Drive it ────────────────────────────────────────────────────────────────

const runtime = Runtime.memory({ snapshotEvery: 16 })
runtime.register("account", accountService)

const account = { kind: "account", key: "acct-1001" }

function send(messageId: bigint, command: BankCommand): BankReply {
  const bytes = runtime.request(account, messageId, JSON.stringify(command))
  if (bytes === null) throw new Error("account replies are never empty")
  return JSON.parse(utf8(bytes)) as BankReply
}

function show(label: string, reply: BankReply): void {
  if (reply.ok) {
    const tx = reply.txNumber === null ? "read" : `tx #${reply.txNumber}`
    console.log(`${label.padEnd(38)} -> ${tx}, balance ${money(reply.balanceCents)}, ${reply.status}`)
  } else {
    console.log(`${label.padEnd(38)} -> error: ${reply.error}`)
  }
}

function money(cents: number): string {
  const sign = cents < 0 ? "-" : ""
  return `${sign}$${(Math.abs(cents) / 100).toFixed(2)}`
}

// Message IDs are idempotency keys owned by the caller. Give each logical
// request its own ID and reuse that exact ID (with identical payload bytes)
// only to retry that request.
const DEPOSIT_PAYCHECK = 1n
const WITHDRAW_RENT = 2n
const SET_OVERDRAFT = 3n
const WITHDRAW_TV = 4n
const FREEZE_CARD_LOST = 5n
const WITHDRAW_WHILE_FROZEN = 6n

console.log("── happy path ──")
show("deposit $1000 paycheck", send(DEPOSIT_PAYCHECK, { type: "deposit", amountCents: 100_000, memo: "paycheck" }))
show("withdraw $300 rent", send(WITHDRAW_RENT, { type: "withdraw", amountCents: 30_000, memo: "rent" }))

console.log("── retrying a mutating request is safe ──")
// Imagine the first reply was lost and the caller retries. Same address, same
// message ID, same payload: decide() runs again and still wants to mutate, so
// the ledger is consulted — the withdrawal is NOT applied a second time and
// the receipt stored by the first attempt comes back (same tx #2, not tx #3).
show("retry withdraw $300 rent", send(WITHDRAW_RENT, { type: "withdraw", amountCents: 30_000, memo: "rent" }))
show("balance check ($700, not $400)", send(100n, { type: "balance" }))

console.log("── rejected decisions are not recorded ──")
show("withdraw $900 TV", send(WITHDRAW_TV, { type: "withdraw", amountCents: 90_000, memo: "TV" }))
show("set overdraft to $500", send(SET_OVERDRAFT, { type: "set-overdraft", limitCents: 50_000 }))
// The rejection above produced no mutation, so WITHDRAW_TV was never
// recorded. Retrying it re-runs decide() against the new overdraft limit and
// this time it succeeds (and is recorded).
show("retry withdraw $900 TV", send(WITHDRAW_TV, { type: "withdraw", amountCents: 90_000, memo: "TV" }))
// The boundary cuts both ways: this ID is now in the ledger, but dedup is
// only reached when the CURRENT attempt also produces a mutation. At balance
// -$200 another $900 would breach the overdraft, so decide() rejects without
// a mutation, the ledger is bypassed, and an error returns instead of the
// stored receipt. This is why aktorz is not exactly-once request execution.
show("retry again at -$200 (re-decides)", send(WITHDRAW_TV, { type: "withdraw", amountCents: 90_000, memo: "TV" }))
show("balance check", send(101n, { type: "balance" }))

console.log("── freeze ──")
show("freeze (card lost)", send(FREEZE_CARD_LOST, { type: "freeze", reason: "card lost" }))
show("withdraw while frozen", send(WITHDRAW_WHILE_FROZEN, { type: "withdraw", amountCents: 1_000, memo: "coffee" }))

runtime.close()
console.log("bank example finished")
