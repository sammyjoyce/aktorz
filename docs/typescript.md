# TypeScript bindings

The TypeScript package keeps the actor runtime, mailbox, snapshot cadence, and idempotency implementation in Zig. TypeScript supplies synchronous actor state-machine callbacks through a small versioned C ABI.

## Runtime support

- Node.js 18+ uses [Koffi](https://koffi.dev/) to load the shared library and register C callbacks.
- Bun uses `bun:ffi` and `JSCallback` with the same native ABI. Bun currently documents `bun:ffi` as experimental, so Node.js/Koffi is the production-safe default.
- Native artifacts are built for macOS, Linux (glibc and musl), and Windows on x64 and arm64.

The runtime is intentionally synchronous. `create`, `decide`, `apply`, snapshot, and destroy callbacks must not return promises. This matches aktorz's single-threaded, in-order service execution and means callback exceptions can be returned to the caller without an asynchronous side channel.

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

`npm run build:native` builds only the current host. `npm run build:native:all` cross-compiles the package artifact matrix. Set `ZIG` to choose a Zig executable.

On Linux, glibc is selected automatically. Set `AKTORZ_LIBC=musl` for Alpine or another musl host. Set `AKTORZ_LIBRARY_PATH=/absolute/path/to/libaktorz.so` (or `.dylib`/`.dll`) to override the packaged library.

## Actor service

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

`messageId` is a JavaScript `bigint` in the full unsigned 128-bit range. When a decision persists a mutation, reusing its message ID for the same actor returns the previously persisted reply and does not apply the mutation again.

## Native ABI ownership

The ABI never exposes Zig-owned reply memory without an explicit result handle. TypeScript copies result bytes, then calls `aktorz_result_destroy`. Callback output uses a two-call size/query protocol: Zig asks for the required byte count, allocates the destination, then asks TypeScript to fill it. Callback failures are transferred through the same protocol and surfaced as JavaScript errors.

The current ABI version is `2`, reported by `aktorz_abi_version()`. Full-width `u64` and `u128` values cross the boundary as fixed little-endian byte buffers, avoiding JavaScript number precision loss in Bun FFI. The TypeScript loader rejects a mismatched shared library before creating a runtime.

## Packaging

The package expects artifacts under:

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
