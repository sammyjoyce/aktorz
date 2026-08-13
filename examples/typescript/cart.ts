// A shopping cart actor driven by structured JSON commands.
//
// TypeScript port of `examples/cart_example.zig`. Payloads, mutations,
// replies, and snapshots are all opaque bytes to the runtime, so a service is
// free to pick its own encoding — this example uses JSON with a typed
// command/event split:
//
//   commands  what callers ask for; validated by decide()
//   events    what actually happened; persisted as the mutation, then folded
//             into state by apply() (and re-folded during log replay)
//
// Run from examples/typescript after `npm install`:
//   node cart.ts     (Node 23.6+; Node 22.6+ needs --experimental-strip-types)
//   bun cart.ts

import { Runtime, utf8, type ActorService } from "aktorz"

// ── Protocol ────────────────────────────────────────────────────────────────

type CartCommand =
  | { readonly type: "add"; readonly sku: string; readonly qty: number; readonly unitPriceCents: number }
  | { readonly type: "remove"; readonly sku: string }
  | { readonly type: "checkout"; readonly orderId: string }
  | { readonly type: "get" }

type CartEvent =
  | { readonly type: "item-added"; readonly sku: string; readonly qty: number; readonly unitPriceCents: number }
  | { readonly type: "item-removed"; readonly sku: string }
  | { readonly type: "checked-out"; readonly orderId: string }

interface Line {
  qty: number
  unitPriceCents: number
}

interface CartState {
  items: Map<string, Line>
  checkedOut: boolean
  orderId: string | null
}

interface CartView {
  readonly items: readonly { sku: string; qty: number; unitPriceCents: number }[]
  readonly totalCents: number
  readonly checkedOut: boolean
  readonly orderId: string | null
}

type CartReply = { readonly ok: true; readonly view: CartView } | { readonly ok: false; readonly error: string }

// ── Service ─────────────────────────────────────────────────────────────────

const cartService: ActorService<CartState> = {
  create: () => ({ items: new Map(), checkedOut: false, orderId: null }),

  makeSnapshot(state) {
    return JSON.stringify({
      items: [...state.items.entries()],
      checkedOut: state.checkedOut,
      orderId: state.orderId,
    })
  },
  loadSnapshot(state, snapshot) {
    const parsed = JSON.parse(utf8(snapshot)) as {
      items: [string, Line][]
      checkedOut: boolean
      orderId: string | null
    }
    state.items = new Map(parsed.items)
    state.checkedOut = parsed.checkedOut
    state.orderId = parsed.orderId
  },

  // decide() validates the command against current state. Domain failures are
  // ordinary error replies without a mutation; only accepted commands produce
  // an event to persist. Throwing here also works — it surfaces to the caller
  // as a thrown Error — but replies keep failures data, not control flow.
  decide(state, message) {
    const command = JSON.parse(utf8(message)) as CartCommand

    switch (command.type) {
      case "get":
        // Read-only decision: reply, no mutation, nothing persisted.
        return { reply: view(state) }

      case "add": {
        if (state.checkedOut) return { reply: fail("cart already checked out") }
        if (!Number.isSafeInteger(command.qty) || command.qty <= 0) {
          return { reply: fail("qty must be a positive integer") }
        }
        if (!Number.isSafeInteger(command.unitPriceCents) || command.unitPriceCents < 0) {
          return { reply: fail("unitPriceCents must be a non-negative integer") }
        }
        const e: CartEvent = {
          type: "item-added",
          sku: command.sku,
          qty: command.qty,
          unitPriceCents: command.unitPriceCents,
        }
        return { mutation: event(e), reply: view(applied(state, e)) }
      }

      case "remove": {
        if (state.checkedOut) return { reply: fail("cart already checked out") }
        if (!state.items.has(command.sku)) return { reply: fail(`unknown sku "${command.sku}"`) }
        const e: CartEvent = { type: "item-removed", sku: command.sku }
        return { mutation: event(e), reply: view(applied(state, e)) }
      }

      case "checkout": {
        if (state.checkedOut) return { reply: fail("already checked out") }
        if (state.items.size === 0) return { reply: fail("cart is empty") }
        const e: CartEvent = { type: "checked-out", orderId: command.orderId }
        return { mutation: event(e), reply: view(applied(state, e)) }
      }
    }
  },

  // apply() is the single place state changes. It runs for live requests after
  // the event was persisted, and again when replaying the log on activation,
  // so it must accept any event decide() ever persisted.
  apply(state, mutation) {
    applyEvent(state, JSON.parse(utf8(mutation)) as CartEvent)
  },
}

function applyEvent(state: CartState, e: CartEvent): void {
  switch (e.type) {
    case "item-added": {
      const line = state.items.get(e.sku)
      if (line === undefined) {
        state.items.set(e.sku, { qty: e.qty, unitPriceCents: e.unitPriceCents })
      } else {
        line.qty += e.qty
        line.unitPriceCents = e.unitPriceCents
      }
      break
    }
    case "item-removed":
      state.items.delete(e.sku)
      break
    case "checked-out":
      state.checkedOut = true
      state.orderId = e.orderId
      break
  }
}

// decide() must not mutate state, so replies that want to show the
// post-command cart render from a scratch copy instead.
function applied(state: CartState, e: CartEvent): CartState {
  const copy: CartState = {
    items: new Map([...state.items.entries()].map(([sku, line]) => [sku, { ...line }])),
    checkedOut: state.checkedOut,
    orderId: state.orderId,
  }
  applyEvent(copy, e)
  return copy
}

function event(e: CartEvent): string {
  return JSON.stringify(e)
}

function view(state: CartState): string {
  const items = [...state.items.entries()]
    .map(([sku, line]) => ({ sku, qty: line.qty, unitPriceCents: line.unitPriceCents }))
    .sort((a, b) => a.sku.localeCompare(b.sku))
  const totalCents = items.reduce((sum, item) => sum + item.qty * item.unitPriceCents, 0)
  const reply: CartReply = {
    ok: true,
    view: { items, totalCents, checkedOut: state.checkedOut, orderId: state.orderId },
  }
  return JSON.stringify(reply)
}

function fail(error: string): string {
  const reply: CartReply = { ok: false, error }
  return JSON.stringify(reply)
}

// ── Drive it ────────────────────────────────────────────────────────────────

const runtime = Runtime.memory({ snapshotEvery: 8 })
runtime.register("cart", cartService)

// In a real system the message ID comes from the caller's request identity
// (an idempotency key), so retries of the same logical request deduplicate.
// This demo just counts upward; bank.ts explores retries in depth.
let nextMessageId = 1n

function send(key: string, command: CartCommand): CartReply {
  const bytes = runtime.request({ kind: "cart", key }, nextMessageId++, JSON.stringify(command))
  if (bytes === null) throw new Error("cart replies are never empty")
  return JSON.parse(utf8(bytes)) as CartReply
}

function show(label: string, reply: CartReply): void {
  if (reply.ok) {
    const { view } = reply
    const items = view.items.map((item) => `${item.sku} x${item.qty} @ ${money(item.unitPriceCents)}`)
    const status = view.checkedOut ? `checked out as ${view.orderId}` : "open"
    console.log(`${label.padEnd(24)} -> [${items.join(", ")}] total ${money(view.totalCents)} (${status})`)
  } else {
    console.log(`${label.padEnd(24)} -> error: ${reply.error}`)
  }
}

function money(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`
}

const cart = "acme:c-42"

show("add red-socks x2", send(cart, { type: "add", sku: "red-socks", qty: 2, unitPriceCents: 12_99 }))
show("add blue-shirt x1", send(cart, { type: "add", sku: "blue-shirt", qty: 1, unitPriceCents: 29_50 }))
show("add red-socks x1 more", send(cart, { type: "add", sku: "red-socks", qty: 1, unitPriceCents: 12_99 }))
show("remove blue-shirt", send(cart, { type: "remove", sku: "blue-shirt" }))
show("remove unknown sku", send(cart, { type: "remove", sku: "green-hat" }))
show("checkout", send(cart, { type: "checkout", orderId: "order-9001" }))
show("add after checkout", send(cart, { type: "add", sku: "green-hat", qty: 1, unitPriceCents: 9_99 }))
show("get", send(cart, { type: "get" }))

// A different key is a different actor with independent state.
show("other cart, get", send("acme:c-43", { type: "get" }))

runtime.close()
console.log("cart example finished")
