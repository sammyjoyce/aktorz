import assert from "node:assert/strict"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Runtime, utf8 } from "../dist/index.js"

const root = mkdtempSync(join(tmpdir(), "aktorz-sqlite-"))
const database = join(root, "actors.sqlite3")
const address = { kind: "counter", key: "durable" }

function registerCounter(runtime) {
  runtime.register("counter", {
    create: () => ({ value: 0 }),
    loadSnapshot(state, snapshot) {
      state.value = Number(utf8(snapshot))
    },
    makeSnapshot: (state) => String(state.value),
    decide(state, message) {
      const delta = Number(utf8(message))
      return { mutation: String(delta), reply: String(state.value + delta) }
    },
    apply(state, mutation) {
      state.value += Number(utf8(mutation))
    },
  })
}

try {
  let runtime = Runtime.sqlite({ path: database, snapshotEvery: 2, busyTimeoutMs: 1_000 })
  registerCounter(runtime)

  assert.equal(utf8(runtime.request(address, 1n, "2")), "2")
  assert.equal(utf8(runtime.request(address, 2n, "3")), "5")
  runtime.close()

  runtime = Runtime.sqlite({ path: database, snapshotEvery: 2 })
  registerCounter(runtime)
  assert.equal(
    utf8(runtime.request(address, 1n, "99")),
    "2",
    "a duplicate message reuses its persisted reply after reopen",
  )
  assert.equal(utf8(runtime.request(address, 3n, "1")), "6", "state replays after reopen")
  assert.equal(runtime.passivate(address), true)
  runtime.close()

  runtime = Runtime.sqlite({ path: database })
  registerCounter(runtime)
  assert.equal(utf8(runtime.request(address, 4n, "1")), "7", "passivated state survives a second reopen")
  runtime.shutdown()
  runtime.close()

  assert.throws(
    () => Runtime.sqlite({ path: join(root, "missing-parent", "actors.sqlite3") }),
    /SQLite|CantOpen|OpenFailed/,
    "native SQLite creation errors are surfaced to TypeScript",
  )
} finally {
  rmSync(root, { recursive: true, force: true })
}

console.log("aktorz TypeScript SQLite smoke test passed")
