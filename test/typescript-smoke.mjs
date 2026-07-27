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

const fullWidthMessageId = 0x0123456789abcdef_fedcba9876543210n
assert.equal(utf8(runtime.request(address, fullWidthMessageId, "2")), "2")
assert.equal(
  utf8(runtime.request(address, fullWidthMessageId + 1n, "3")),
  "5",
  "adjacent full-width message identifiers remain distinct",
)
assert.equal(
  utf8(runtime.request(address, fullWidthMessageId, "99")),
  "2",
  "duplicate messages reuse the stored reply",
)
runtime.passivateIdle((1n << 64n) - 1n)
assert.equal(destroyed, 0, "full-width idle thresholds are not truncated")
assert.throws(() => runtime.request(address, 3n, "boom"), /counter exploded/)
assert.equal(runtime.passivate(address), true)
assert.equal(destroyed, 1)
assert.equal(utf8(runtime.request(address, 4n, "4")), "9", "passivated state reloads from its snapshot")

runtime.register("closing-counter", {
  create: () => ({}),
  loadSnapshot() {},
  makeSnapshot: () => "",
  decide() {
    runtime.close()
    return { reply: "unreachable" }
  },
  apply() {},
})
assert.throws(
  () => runtime.request({ kind: "closing-counter", key: "primary" }, 1n, "close"),
  /Cannot close the aktorz runtime from inside an actor callback/,
)

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
