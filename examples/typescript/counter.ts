// Getting started: an in-memory counter actor.
//
// An actor kind is a synchronous state machine registered with the runtime:
//
//   decide()  inspects current state plus one message and returns a Decision
//             (optional mutation bytes + optional reply bytes). It must not
//             mutate state itself.
//   apply()   folds an already-persisted mutation into in-memory state. It
//             also runs while replaying the log during activation, so it must
//             be deterministic, synchronous, and free of I/O.
//
// The runtime activates actors lazily, processes their messages one at a
// time, persists each mutation before applying it, and snapshots
// periodically (here: every 4 mutations) and on passivation.
//
// Run from examples/typescript after `npm install`:
//   node counter.ts     (Node 23.6+; Node 22.6+ needs --experimental-strip-types)
//   bun counter.ts

import { Runtime, utf8, type ActorService } from "aktorz"

interface CounterState {
  value: number
}

const counterService: ActorService<CounterState> = {
  create: () => ({ value: 0 }),

  // Snapshots are opaque bytes chosen by the service.
  makeSnapshot: (state) => String(state.value),
  loadSnapshot(state, snapshot) {
    state.value = Number(utf8(snapshot))
  },

  decide(state, message) {
    const delta = Number(utf8(message))
    if (!Number.isSafeInteger(delta)) {
      // Domain rejection belongs in decide(): reply without a mutation, so
      // nothing is persisted and state stays untouched.
      return { reply: "error: message must be an integer" }
    }
    return { mutation: String(delta), reply: String(state.value + delta) }
  },

  apply(state, mutation) {
    state.value += Number(utf8(mutation))
  },
}

const runtime = Runtime.memory({ snapshotEvery: 4 })
runtime.register("counter", counterService)

const address = { kind: "counter", key: "tenant-a:counter-1" }

// request() processes one message synchronously and returns the reply bytes
// (or null when the decision carried no reply). Message IDs are caller-chosen
// bigints, scoped per actor address; see bank.ts for their deduplication role.
let reply = runtime.request(address, 1n, "5")
console.log("add 5                  ->", reply && utf8(reply)) // 5

reply = runtime.request(address, 2n, "3")
console.log("add 3                  ->", reply && utf8(reply)) // 8

// tell() has identical semantics but discards the reply.
runtime.tell(address, 3n, "10")

reply = runtime.request(address, 4n, "0")
console.log("add 0 (after tell 10)  ->", reply && utf8(reply)) // 18

reply = runtime.request(address, 5n, "not-a-number")
console.log("invalid message        ->", reply && utf8(reply))

// Actors with different keys are fully isolated; the same message ID may be
// reused freely across addresses.
reply = runtime.request({ kind: "counter", key: "tenant-b:counter-1" }, 1n, "100")
console.log("tenant-b, add 100      ->", reply && utf8(reply)) // 100

// passivate() snapshots the actor and evicts it from memory. The next request
// transparently reactivates it from its snapshot + remaining log.
runtime.passivate(address)
reply = runtime.request(address, 6n, "1")
console.log("add 1 after passivate  ->", reply && utf8(reply)) // 19

// close() shuts the runtime down cleanly. Runtime.memory() state is gone after
// this; see sqlite-durability.ts for state that survives restarts.
runtime.close()
console.log("counter example finished")
