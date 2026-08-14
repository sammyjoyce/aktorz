# TypeScript bindings

The TypeScript package keeps the actor runtime, mailbox, snapshot cadence, and per-actor mutating-decision deduplication in Zig. TypeScript supplies synchronous actor state-machine callbacks through a small versioned C ABI. Runnable examples live in [`examples/typescript/`](../examples/typescript/).

## Runtime support

- Node.js 18+ uses [Koffi](https://koffi.dev/) to load the shared library and register C callbacks.
- Bun uses `bun:ffi` and `JSCallback` with the same native ABI. Bun currently documents `bun:ffi` as experimental, so Node.js/Koffi is the production-safe default.
- Native artifacts are built for macOS, Linux (glibc and musl), and Windows on x64 and arm64.
- Every packaged native artifact statically includes the SQLite amalgamation used by `Runtime.sqlite()`. Consumers do not need a system SQLite library. The amalgamation is compiled with hidden visibility, so its `sqlite3_*` symbols cannot interpose on `node:sqlite` or `bun:sqlite` in the same process.
- Koffi is pinned to `2.16.3`. Koffi 3.0.0-3.1.2 corrupt AArch64 callback arguments passed on the stack (the 9th argument and beyond), which silently breaks the dispatch callback's output buffer on arm64. The bug is unfixed upstream as of 3.1.2; see [Koromix/koffi#273](https://github.com/Koromix/koffi/issues/273) for a related report. Do not upgrade without verifying arm64 Node callbacks.

The runtime is intentionally synchronous. `create`, `decide`, `apply`, snapshot, and destroy callbacks must not return promises. This matches aktorz's single-threaded, in-order actor execution and means callback exceptions can be returned to the caller without an asynchronous side channel.

## Install and build

From a published package:

```bash
npm install aktorz
```

From a checkout:

```bash
npm install
npm run build
npm run test:node
```

`npm run build:native` builds only the current host (`zig build typescript-native`). `npm run build:native:all` cross-compiles the package artifact matrix (`zig build typescript-native-all`). Both steps write into `native/<platform-key>/`. Set `ZIG` to choose a Zig executable. Packaged libraries are stripped `ReleaseFast` binaries; override with `-Dtypescript-optimize=` if you invoke Zig directly.

On Linux, glibc is selected automatically. Set `AKTORZ_LIBC=musl` for Alpine or another musl host. Set `AKTORZ_LIBRARY_PATH=/absolute/path/to/libaktorz.so` (or `.dylib`/`.dll`) to override the packaged library.

## In-memory runtime

```ts
import { Runtime, utf8 } from "aktorz"

const runtime = Runtime.memory({ snapshotEvery: 64 })

runtime.register("counter", {
  create: () => ({ value: 0 }),
  loadSnapshot(state, bytes) {
    state.value = Number(utf8(bytes))
  },
  makeSnapshot: (state) => String(state.value),
  decide(state, message) {
    const delta = Number(utf8(message))
    return {
      mutation: String(delta),
      reply: String(state.value + delta),
    }
  },
  apply(state, mutation) {
    state.value += Number(utf8(mutation))
  },
})

const reply = runtime.request(
  { kind: "counter", key: "tenant:counter-42" },
  1n,
  "5",
)

console.log(reply && utf8(reply)) // 5
runtime.close()
```

## SQLite runtime

Use the same actor service with a durable local store:

```ts
const runtime = Runtime.sqlite({
  path: "actors.sqlite3",
  snapshotEvery: 64,
  busyTimeoutMs: 5_000,
})
```

`path` is required and its parent directory must exist. `busyTimeoutMs` defaults to `5_000`. SQLite opens in WAL mode with `synchronous=FULL`; schema creation happens before the constructor returns. Native open and schema errors are transferred through the result-handle ABI and surfaced as JavaScript exceptions carrying the underlying error name, such as `SQLiteCantOpen`.

Calling `close()` performs a clean runtime shutdown, snapshots active actors, closes SQLite, unregisters the callback, and unloads the native library. A new `Runtime.sqlite()` pointed at the same path restores snapshots and replays remaining WAL mutations. The SQLite message-ID ledger also survives the reopen.

Multiple runtimes, memory or SQLite, can be open in one process, and closing one does not disturb the others.

## Message IDs and deduplication

`messageId` is a JavaScript `bigint` in the full unsigned 128-bit range and is scoped to one actor address.

When the current `decide()` result contains a mutation, the first occurrence records that mutation and its optional reply. A later attempt with the same actor and message ID that also produces a mutation does not append or live-apply a second mutation; it returns the optional reply stored by the first append.

`decide()` runs before duplicate lookup. A decision without a mutation is not looked up or recorded, so retrying a read re-executes `decide()` and may observe newer state. This is not exactly-once request execution.

Use one message ID for only one logical request to one actor. Reusing it with different payload bytes is invalid and is not currently detected. See [`deduplication.md`](deduplication.md) for the full boundary and retention rules.

## Failure semantics

A thrown `apply()` after the mutation was persisted surfaces as an error whose message is the original thrown message (a later `destroy()` failure during cleanup cannot replace it). The runtime discards the actor instance without snapshotting it; retrying the **same** message ID reconstructs the actor from durable state and returns the stored reply. If recovery itself fails deterministically (a throwing `loadSnapshot` or replay-time `apply`), requests fail with `PoisonedActor` until the service code is fixed and the actor is retried or the process restarts.

## Native ABI ownership

The ABI never exposes Zig-owned reply memory without an explicit result handle. TypeScript copies result bytes, then calls `aktorz_result_destroy`. Callback output uses a two-call size/query protocol: Zig asks for the required byte count, allocates the destination, then asks TypeScript to fill it. Callback and runtime-creation failures are transferred through result handles and surfaced as JavaScript errors.

The current ABI version is `3`, reported by `aktorz_abi_version()`. ABI v3 adds `aktorz_runtime_create_sqlite()` and `aktorz_runtime_create_error()` while retaining the ABI v2 memory-runtime entry points. Full-width `u64` and `u128` values cross the boundary as fixed little-endian byte buffers, avoiding JavaScript number precision loss in Bun FFI. The TypeScript loader rejects a mismatched shared library before creating a runtime.

## Packaging

The package expects self-contained artifacts under:

```text
native/
  darwin-arm64/libaktorz.dylib
  darwin-x64/libaktorz.dylib
  linux-arm64-gnu/libaktorz.so
  linux-arm64-musl/libaktorz.so
  linux-x64-gnu/libaktorz.so
  linux-x64-musl/libaktorz.so
  win32-arm64/aktorz.dll
  win32-x64/aktorz.dll
```

This follows the same separation used by OpenTUI: a narrow Zig shared-library boundary, runtime-specific FFI loading, and a platform artifact build matrix. aktorz keeps the artifacts in one package for now; the layout can later be split into optional per-platform packages without changing the public TypeScript API or C ABI.
