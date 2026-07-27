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

  const second = Runtime.sqlite({ path: join(root, "second.sqlite3") })
  registerCounter(second)
  assert.equal(utf8(second.request(address, 1n, "10")), "10", "runtimes coexist in one process")
  second.close()
  assert.equal(utf8(runtime.request(address, 5n, "1")), "8", "closing one runtime leaves the others usable")

  runtime.shutdown()
  runtime.close()

  assert.throws(
    () => Runtime.sqlite({ path: join(root, "missing-parent", "actors.sqlite3") }),
    /SQLiteCantOpen/,
    "native SQLite creation errors are surfaced to TypeScript",
  )
  assert.throws(() => Runtime.sqlite({}), /path must be a string/)
  assert.throws(() => Runtime.sqlite({ path: 5 }), /path must be a string/)
  assert.throws(() => Runtime.sqlite({ path: "" }), /path must not be empty/)
  assert.throws(
    () => new Runtime({ path: 5 }),
    /path must be a string/,
    "a non-string path is rejected by the constructor, not just the sqlite() factory",
  )
  assert.throws(
    () => Runtime.memory({ path: database }),
    /use Runtime\.sqlite/,
    "a path passed to Runtime.memory() is rejected instead of silently creating a SQLite store",
  )
  assert.throws(
    () => Runtime.sqlite({ path: `${database}\u0000extra` }),
    /SQLitePathContainsNul/,
    "embedded NUL bytes are rejected instead of silently truncating the path",
  )

  await assertHostSQLiteStillWorks(join(root, "host.sqlite3"))
} finally {
  rmSync(root, { recursive: true, force: true })
}

// The bundled amalgamation is compiled with hidden visibility so it cannot
// interpose on the host runtime's own SQLite. Skipped where neither is available.
async function assertHostSQLiteStillWorks(path) {
  const host = await openHostSQLite(path)
  if (host === null) return
  host.exec("CREATE TABLE probe(value TEXT)")
  host.prepare("INSERT INTO probe VALUES (?)").run("intact")

  const runtime = Runtime.sqlite({ path: `${path}.actors` })
  registerCounter(runtime)
  assert.equal(utf8(runtime.request(address, 1n, "3")), "3")
  assert.equal(host.prepare("SELECT value FROM probe").get().value, "intact")
  runtime.close()
  host.close()
}

async function openHostSQLite(path) {
  try {
    if (typeof process.versions.bun === "string") {
      const { Database } = await import("bun:sqlite")
      return new Database(path)
    }
    const { DatabaseSync } = await import("node:sqlite")
    return new DatabaseSync(path)
  } catch {
    return null
  }
}

console.log("aktorz TypeScript SQLite smoke test passed")
