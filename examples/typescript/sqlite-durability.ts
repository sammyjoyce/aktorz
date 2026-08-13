// Durable actors with the SQLite store: state, snapshots, and the
// deduplication ledger survive a runtime restart.
//
// Runtime.sqlite() hosts the exact same ActorService as Runtime.memory() but
// persists snapshots, mutation-log entries, and the per-actor message-ID
// records (with their stored replies) in a single self-contained SQLite file.
// The packaged native library bundles SQLite — no system library needed.
//
// Run from examples/typescript after `npm install`:
//   node sqlite-durability.ts   (Node 23.6+; Node 22.6+ needs --experimental-strip-types)
//   bun sqlite-durability.ts

import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Runtime, utf8, type ActorService } from "aktorz"

// ── A small user-profile actor ──────────────────────────────────────────────

type ProfileCommand =
  | { readonly type: "rename"; readonly name: string }
  | { readonly type: "visit" }
  | { readonly type: "get" }

interface ProfileState {
  name: string
  visits: number
}

const profileService: ActorService<ProfileState> = {
  create: () => ({ name: "anonymous", visits: 0 }),
  makeSnapshot: (state) => JSON.stringify(state),
  loadSnapshot(state, snapshot) {
    Object.assign(state, JSON.parse(utf8(snapshot)) as ProfileState)
  },
  decide(state, message) {
    const command = JSON.parse(utf8(message)) as ProfileCommand
    switch (command.type) {
      case "get":
        return { reply: JSON.stringify(state) }
      case "rename":
        return {
          mutation: JSON.stringify({ rename: command.name }),
          reply: JSON.stringify({ ...state, name: command.name }),
        }
      case "visit":
        return {
          mutation: JSON.stringify({ visit: 1 }),
          reply: JSON.stringify({ ...state, visits: state.visits + 1 }),
        }
    }
  },
  apply(state, mutation) {
    const e = JSON.parse(utf8(mutation)) as { rename?: string; visit?: number }
    if (e.rename !== undefined) state.name = e.rename
    if (e.visit !== undefined) state.visits += e.visit
  },
}

// ── Helpers ─────────────────────────────────────────────────────────────────

const address = { kind: "profile", key: "user:u-1" }

function openRuntime(path: string): Runtime {
  // `path`'s parent directory must already exist. snapshotEvery: 2 keeps the
  // demo's mutation log short; production values are typically larger
  // (default 128). busyTimeoutMs (default 5000) bounds waiting on a locked
  // database file.
  const runtime = Runtime.sqlite({ path, snapshotEvery: 2, busyTimeoutMs: 5_000 })
  runtime.register("profile", profileService)
  return runtime
}

function send(runtime: Runtime, messageId: bigint, command: ProfileCommand): ProfileState {
  const bytes = runtime.request(address, messageId, JSON.stringify(command))
  if (bytes === null) throw new Error("profile replies are never empty")
  return JSON.parse(utf8(bytes)) as ProfileState
}

// ── First process lifetime ──────────────────────────────────────────────────

const dir = mkdtempSync(join(tmpdir(), "aktorz-example-"))
const path = join(dir, "actors.sqlite3")

try {
  console.log(`SQLite store: ${path}`)

  const first = openRuntime(path)
  console.log("rename to Ada     ->", send(first, 1n, { type: "rename", name: "Ada" }))
  console.log("visit             ->", send(first, 2n, { type: "visit" }))
  const secondVisit = send(first, 3n, { type: "visit" })
  console.log("visit             ->", secondVisit)

  // close() snapshots active actors, closes SQLite, and unloads the native
  // library. Everything the actor needs to come back lives in the file now.
  first.close()
  console.log("runtime closed (pretend the process restarted here)")

  // ── Second process lifetime ───────────────────────────────────────────────

  const second = openRuntime(path)

  // The first request reactivates the actor from its snapshot + remaining log.
  console.log("get after reopen  ->", send(second, 4n, { type: "get" }))

  // The dedup ledger survived too: retrying message ID 3 (a mutating visit)
  // does not bump the counter again — the reply stored before the restart
  // comes back and state is unchanged.
  const retried = send(second, 3n, { type: "visit" })
  console.log("retry visit id 3  ->", retried, "(stored reply, no double count)")
  if (retried.visits !== secondVisit.visits) throw new Error("dedup ledger should have survived the restart")

  console.log("new visit         ->", send(second, 5n, { type: "visit" }))
  second.close()

  console.log("sqlite durability example finished")
} finally {
  rmSync(dir, { recursive: true, force: true })
}
