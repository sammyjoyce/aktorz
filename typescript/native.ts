import { existsSync } from "node:fs"
import { fileURLToPath } from "node:url"

import { utf8 } from "./codec.js"
import { loadBunApi } from "./native-bun.js"
import { loadNodeApi } from "./native-node.js"
import {
  EMPTY_BYTES,
  toSafeLength,
  type NativeDispatch,
  type Pointer,
  type RawApi,
  type RegisteredDispatch,
} from "./native-shared.js"

export type { NativeDispatch } from "./native-shared.js"

const ABI_VERSION = 1

const ResultKind = {
  ok: 0,
  reply: 1,
  noReply: 2,
  false: 3,
  true: 4,
  error: 255,
} as const

export class NativeRuntimeBinding {
  readonly #api: RawApi
  readonly #dispatch: RegisteredDispatch
  readonly #handle: Pointer
  #closed = false

  constructor(dispatch: NativeDispatch, snapshotEvery: number, libraryPath?: string) {
    this.#api = loadRawApi(resolveNativeLibraryPath(libraryPath))
    try {
      if (this.#api.abiVersion() !== ABI_VERSION) {
        throw new Error(`Unsupported aktorz native ABI: expected ${ABI_VERSION}`)
      }

      this.#dispatch = this.#api.createDispatch(dispatch)
      const handle = this.#api.runtimeCreateMemory(this.#dispatch.pointer, 1n, snapshotEvery)
      if (handle == null) {
        this.#dispatch.close()
        throw new Error("Failed to create the native aktorz runtime")
      }
      this.#handle = handle
    } catch (error) {
      this.#api.close()
      throw error
    }
  }

  register(kind: Uint8Array): void {
    this.#expectOk(this.#api.runtimeRegister(this.#requireOpen(), kind), "register actor kind")
  }

  request(
    kind: Uint8Array,
    key: Uint8Array,
    messageHigh: bigint,
    messageLow: bigint,
    payload: Uint8Array,
  ): Uint8Array | null {
    const result = this.#readResult(
      this.#api.runtimeRequest(this.#requireOpen(), kind, key, messageHigh, messageLow, payload),
      "request actor",
    )
    if (result.kind === ResultKind.reply) return result.bytes
    if (result.kind === ResultKind.noReply) return null
    throw new Error(`Unexpected native result kind ${result.kind} while requesting actor`)
  }

  tell(
    kind: Uint8Array,
    key: Uint8Array,
    messageHigh: bigint,
    messageLow: bigint,
    payload: Uint8Array,
  ): void {
    this.#expectOk(
      this.#api.runtimeTell(this.#requireOpen(), kind, key, messageHigh, messageLow, payload),
      "tell actor",
    )
  }

  passivate(kind: Uint8Array, key: Uint8Array): boolean {
    const result = this.#readResult(
      this.#api.runtimePassivate(this.#requireOpen(), kind, key),
      "passivate actor",
    )
    if (result.kind === ResultKind.true) return true
    if (result.kind === ResultKind.false) return false
    throw new Error(`Unexpected native result kind ${result.kind} while passivating actor`)
  }

  passivateIdle(minimumIdleTicks: bigint): void {
    this.#expectOk(
      this.#api.runtimePassivateIdle(this.#requireOpen(), minimumIdleTicks),
      "passivate idle actors",
    )
  }

  shutdown(): void {
    this.#expectOk(this.#api.runtimeShutdown(this.#requireOpen()), "shut down actor runtime")
  }

  close(): void {
    if (this.#closed) return
    this.#closed = true

    try {
      this.#api.runtimeDestroy(this.#handle)
    } finally {
      try {
        this.#dispatch.close()
      } finally {
        this.#api.close()
      }
    }
  }

  #requireOpen(): Pointer {
    if (this.#closed) throw new Error("The aktorz runtime is closed")
    return this.#handle
  }

  #expectOk(resultPointer: Pointer | null, action: string): void {
    const result = this.#readResult(resultPointer, action)
    if (result.kind !== ResultKind.ok) {
      throw new Error(`Unexpected native result kind ${result.kind} while trying to ${action}`)
    }
  }

  #readResult(resultPointer: Pointer | null, action: string): { kind: number; bytes: Uint8Array } {
    if (resultPointer == null) {
      throw new Error(`Native aktorz allocation failed while trying to ${action}`)
    }

    try {
      const kind = this.#api.resultKind(resultPointer)
      const length = toSafeLength(this.#api.resultLength(resultPointer), "native result")
      const data = this.#api.resultData(resultPointer)
      const bytes = length === 0 ? EMPTY_BYTES : data == null ? null : this.#api.read(data, length)
      if (bytes == null) {
        throw new Error(`Native aktorz returned a null pointer for a ${length}-byte result`)
      }
      if (kind === ResultKind.error) {
        throw new Error(utf8(bytes) || `Native aktorz failed while trying to ${action}`)
      }
      return { kind, bytes }
    } finally {
      this.#api.resultDestroy(resultPointer)
    }
  }
}

function loadRawApi(path: string): RawApi {
  return typeof process.versions.bun === "string" ? loadBunApi(path) : loadNodeApi(path)
}

function resolveNativeLibraryPath(override?: string): string {
  const configured = override ?? process.env.AKTORZ_LIBRARY_PATH
  if (configured !== undefined && configured !== "") {
    if (!existsSync(configured)) {
      throw new Error(`AKTORZ_LIBRARY_PATH does not exist: ${configured}`)
    }
    return configured
  }

  const target = currentNativeTarget()
  const path = fileURLToPath(new URL(`../native/${target.key}/${target.file}`, import.meta.url))
  if (!existsSync(path)) {
    throw new Error(
      `No packaged aktorz native library for ${target.key}. Run \"npm run build:native\" or set AKTORZ_LIBRARY_PATH.`,
    )
  }
  return path
}

function currentNativeTarget(): { key: string; file: string } {
  const platform = process.platform
  const arch = process.arch
  if (arch !== "x64" && arch !== "arm64") {
    throw new Error(`Unsupported aktorz architecture: ${arch}`)
  }

  if (platform === "darwin") return { key: `darwin-${arch}`, file: "libaktorz.dylib" }
  if (platform === "win32") return { key: `win32-${arch}`, file: "aktorz.dll" }
  if (platform === "linux") {
    const libc = detectLinuxLibc()
    return { key: `linux-${arch}-${libc}`, file: "libaktorz.so" }
  }
  throw new Error(`Unsupported aktorz platform: ${platform}`)
}

function detectLinuxLibc(): "gnu" | "musl" {
  const configured = process.env.AKTORZ_LIBC
  if (configured !== undefined && configured !== "") {
    if (configured === "gnu" || configured === "glibc") return "gnu"
    if (configured === "musl") return "musl"
    throw new Error(`AKTORZ_LIBC must be \"gnu\", \"glibc\", or \"musl\", got ${JSON.stringify(configured)}`)
  }

  const header = process.report?.getReport().header
  if (header?.glibcVersionRuntime !== undefined) return "gnu"
  if (header?.musl !== undefined) return "musl"
  return "gnu"
}
