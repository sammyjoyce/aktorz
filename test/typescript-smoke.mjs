import assert from "node:assert/strict"

import { Runtime, utf8 } from "../dist/index.js"

const runtime = Runtime.memory({ snapshotEvery: 2 })
const address = { kind: "counter", key: "primary" }
let destroyed = 0

runtime.register("counter", {
  create() {
    return { value: 0 }
  },
  loadSnapshot(state, snapshot) {
    state.value = Number(utf8(snapshot))
  },
  makeSnapshot(state) {
    return String(state.value)
  },
  decide(state, message) {
    const text = utf8(message)
    if (text === "boom") throw new Error("counter exploded")
    const delta = Number(text)
    return { mutation: text, reply: String(state.value + delta) }
  },
  apply(state, mutation) {
    state.value += Number(utf8(mutation))
  },
  destroy() {
    destroyed += 1
  },
})

assert.equal(utf8(runtime.request(address, 1n, "2")), "2")
assert.equal(utf8(runtime.request(address, 1n, "99")), "2", "duplicate messages reuse the stored reply")
assert.equal(utf8(runtime.request(address, 2n, "3")), "5")
assert.throws(() => runtime.request(address, 3n, "boom"), /counter exploded/)
assert.equal(runtime.passivate(address), true)
assert.equal(destroyed, 1)
assert.equal(utf8(runtime.request(address, 4n, "4")), "9", "passivated state reloads from its snapshot")

runtime.register("async-counter", {
  create: () => ({ value: 0 }),
  loadSnapshot() {},
  makeSnapshot: () => "0",
  async decide() {
    return { reply: "not supported" }
  },
  apply() {},
})
assert.throws(
  () => runtime.request({ kind: "async-counter", key: "primary" }, 1n, "1"),
  /ActorService\.decide must not return a Promise/,
)

runtime.shutdown()
assert.equal(destroyed, 2)
runtime.close()
runtime.close()

console.log("aktorz TypeScript smoke test passed")
