import { copyBytes, encodeDecision, encodeUtf8, toBytes, utf8, writeU64, writeU128 } from "./codec.js"
import { NativeRuntimeBinding, type NativeDispatch, type NativeRuntimeOptions } from "./native.js"
import type {
  ActorAddress,
  ActorDecision,
  ActorService,
  BytesLike,
  RuntimeOptions,
  SQLiteRuntimeOptions,
} from "./types.js"

const MAX_U32 = 0xffff_ffff
const MAX_U64 = (1n << 64n) - 1n
const MAX_U128 = (1n << 128n) - 1n
const EMPTY_BYTES = new Uint8Array()

const Operation = {
  create: 1,
  destroy: 2,
  loadSnapshot: 3,
  makeSnapshot: 4,
  decide: 5,
  apply: 6,
  getError: 7,
} as const

type ErasedActorService = {
  create(address: ActorAddress): unknown
  loadSnapshot(state: unknown, snapshot: Uint8Array): void
  makeSnapshot(state: unknown): BytesLike
  decide(state: unknown, message: Uint8Array): ActorDecision
  apply(state: unknown, mutation: Uint8Array): void
  destroy(state: unknown): void
}

type ServiceInstance = {
  readonly service: ErasedActorService
  readonly state: unknown
}

class ServiceBridge {
  readonly #services = new Map<string, ErasedActorService>()
  readonly #instances = new Map<bigint, ServiceInstance>()
  readonly #outputs = new Map<bigint, Uint8Array>()
  readonly #errors = new Map<bigint, Uint8Array>()
  #nextServiceId = 1n
  #dispatchDepth = 0

  get dispatching(): boolean {
    return this.#dispatchDepth > 0
  }

  readonly dispatch: NativeDispatch = (
    _context,
    operation,
    callId,
    serviceId,
    input1,
    input2,
    output,
  ) => {
    if (operation === Operation.getError) {
      return this.#dispatchError(callId, output)
    }

    if (output !== null) {
      return this.#writePendingOutput(callId, output)
    }

    const pending = this.#outputs.get(callId)
    if (pending !== undefined) {
      return pending.byteLength
    }

    try {
      this.#dispatchDepth += 1
      try {
        const result = this.#execute(operation, serviceId, input1, input2)
        if (result.byteLength > 0) {
          this.#outputs.set(callId, result)
        }
        return result.byteLength
      } finally {
        this.#dispatchDepth -= 1
      }
    } catch (error) {
      this.#outputs.delete(callId)
      this.#errors.set(callId, encodeUtf8(errorMessage(error)))
      return -1
    }
  }

  register<State>(kind: string, service: ActorService<State>): () => void {
    const previous = this.#services.get(kind)
    this.#services.set(kind, eraseService(service))
    return () => {
      if (previous === undefined) this.#services.delete(kind)
      else this.#services.set(kind, previous)
    }
  }

  #execute(operation: number, serviceId: bigint, input1: Uint8Array, input2: Uint8Array): Uint8Array {
    switch (operation) {
      case Operation.create:
        return this.#create(input1, input2)
      case Operation.destroy:
        this.#destroy(serviceId)
        return EMPTY_BYTES
      case Operation.loadSnapshot: {
        const instance = this.#instance(serviceId)
        instance.service.loadSnapshot(instance.state, copyBytes(input1))
        return EMPTY_BYTES
      }
      case Operation.makeSnapshot: {
        const instance = this.#instance(serviceId)
        return copyBytes(toBytes(instance.service.makeSnapshot(instance.state)))
      }
      case Operation.decide: {
        const instance = this.#instance(serviceId)
        return encodeDecision(instance.service.decide(instance.state, copyBytes(input1)))
      }
      case Operation.apply: {
        const instance = this.#instance(serviceId)
        instance.service.apply(instance.state, copyBytes(input1))
        return EMPTY_BYTES
      }
      default:
        throw new Error(`Unknown native aktorz callback operation: ${operation}`)
    }
  }

  #create(kindBytes: Uint8Array, keyBytes: Uint8Array): Uint8Array {
    const kind = utf8(kindBytes)
    const key = utf8(keyBytes)
    const service = this.#services.get(kind)
    if (service === undefined) throw new Error(`No TypeScript actor service is registered for kind ${JSON.stringify(kind)}`)

    const state = service.create({ kind, key })
    const serviceId = this.#nextServiceId
    this.#nextServiceId += 1n
    this.#instances.set(serviceId, { service, state })
    return writeU64(serviceId)
  }

  #destroy(serviceId: bigint): void {
    const instance = this.#instances.get(serviceId)
    if (instance === undefined) return
    try {
      instance.service.destroy(instance.state)
    } finally {
      this.#instances.delete(serviceId)
    }
  }

  #instance(serviceId: bigint): ServiceInstance {
    const instance = this.#instances.get(serviceId)
    if (instance === undefined) throw new Error(`Unknown TypeScript actor service instance: ${serviceId}`)
    return instance
  }

  #writePendingOutput(callId: bigint, output: Uint8Array): number {
    const pending = this.#outputs.get(callId)
    if (pending === undefined) {
      this.#errors.set(callId, encodeUtf8(`No pending callback output for call ${callId}`))
      return -1
    }
    if (output.byteLength < pending.byteLength) {
      this.#outputs.delete(callId)
      this.#errors.set(
        callId,
        encodeUtf8(`Callback output buffer is ${output.byteLength} bytes; ${pending.byteLength} bytes are required`),
      )
      return -1
    }

    output.set(pending)
    this.#outputs.delete(callId)
    return pending.byteLength
  }

  #dispatchError(callId: bigint, output: Uint8Array | null): number {
    const error = this.#errors.get(callId)
    if (error === undefined) return 0
    if (output === null) return error.byteLength
    if (output.byteLength < error.byteLength) return -1

    output.set(error)
    this.#errors.delete(callId)
    return error.byteLength
  }
}

/** A TypeScript façade over the Zig aktorz runtime. */
export class Runtime {
  readonly #bridge: ServiceBridge
  readonly #native: NativeRuntimeBinding
  #closed = false

  /** Creates an in-memory runtime unless SQLite options are supplied. */
  constructor(options: RuntimeOptions | SQLiteRuntimeOptions = {}) {
    requireObject(options, "options")
    this.#bridge = new ServiceBridge()
    this.#native = new NativeRuntimeBinding(
      this.#bridge.dispatch,
      nativeOptionsFrom(options),
      options.libraryPath,
    )
  }

  /**
   * Creates an in-memory runtime. State and deduplication records survive
   * actor passivation but are lost when the runtime closes or the process
   * exits.
   */
  static memory(options: RuntimeOptions = {}): Runtime {
    requireObject(options, "options")
    if (isSQLiteRuntimeOptions(options)) {
      throw new TypeError("Runtime.memory() does not accept a path; use Runtime.sqlite() for durability")
    }
    return new Runtime(options)
  }

  /**
   * Creates a runtime that persists snapshots, mutation-log entries, and the
   * per-actor deduplication records and optional replies created by mutating
   * decisions.
   */
  static sqlite(options: SQLiteRuntimeOptions): Runtime {
    requireObject(options, "options")
    requireString(options.path, "path")
    return new Runtime(options)
  }

  register<State>(kind: string, service: ActorService<State>): this {
    this.#requireOpen()
    requireString(kind, "kind")
    const rollback = this.#bridge.register(kind, service)
    try {
      this.#native.register(encodeUtf8(kind))
      return this
    } catch (error) {
      rollback()
      throw error
    }
  }

  /**
   * Processes one request synchronously.
   *
   * `messageId` is scoped to `address` and participates in deduplication only
   * when the current `decide()` result contains a mutation: a later mutating
   * attempt with the same ID skips the second append and live `apply()` and
   * returns the first stored optional reply. Decisions without mutations are
   * not looked up or recorded, and `decide()` runs before duplicate
   * detection, so this is not exactly-once request execution. Reusing the
   * same actor and message ID with a different payload is invalid and is not
   * currently detected. See docs/deduplication.md.
   */
  request(address: ActorAddress, messageId: bigint, payload: BytesLike): Uint8Array | null {
    this.#requireOpen()
    const normalized = normalizeAddress(address)
    return this.#native.request(
      encodeUtf8(normalized.kind),
      encodeUtf8(normalized.key),
      encodeMessageId(messageId),
      toBytes(payload),
    )
  }

  /**
   * Processes a request with the same deduplication semantics as `request()`
   * and discards any returned reply.
   */
  tell(address: ActorAddress, messageId: bigint, payload: BytesLike): void {
    this.#requireOpen()
    const normalized = normalizeAddress(address)
    this.#native.tell(
      encodeUtf8(normalized.kind),
      encodeUtf8(normalized.key),
      encodeMessageId(messageId),
      toBytes(payload),
    )
  }

  passivate(address: ActorAddress): boolean {
    this.#requireOpen()
    const normalized = normalizeAddress(address)
    return this.#native.passivate(encodeUtf8(normalized.kind), encodeUtf8(normalized.key))
  }

  passivateIdle(minimumIdleTicks: bigint): void {
    this.#requireOpen()
    requireU64(minimumIdleTicks, "minimumIdleTicks")
    this.#native.passivateIdle(writeU64(minimumIdleTicks))
  }

  shutdown(): void {
    this.#requireOpen()
    this.#native.shutdown()
  }

  close(): void {
    if (this.#closed) return
    if (this.#bridge.dispatching) {
      throw new Error("Cannot close the aktorz runtime from inside an actor callback")
    }
    this.#closed = true
    this.#native.close()
  }

  #requireOpen(): void {
    if (this.#closed) throw new Error("The aktorz runtime is closed")
  }
}

function eraseService<State>(service: ActorService<State>): ErasedActorService {
  return {
    create(address) {
      return requireSynchronous(service.create(address), "ActorService.create")
    },
    loadSnapshot(state, snapshot) {
      requireSynchronous(service.loadSnapshot(state as State, snapshot), "ActorService.loadSnapshot")
    },
    makeSnapshot(state) {
      return requireSynchronous(service.makeSnapshot(state as State), "ActorService.makeSnapshot")
    },
    decide(state, message) {
      return requireSynchronous(service.decide(state as State, message), "ActorService.decide")
    },
    apply(state, mutation) {
      requireSynchronous(service.apply(state as State, mutation), "ActorService.apply")
    },
    destroy(state) {
      requireSynchronous(service.destroy?.(state as State), "ActorService.destroy")
    },
  }
}

function requireSynchronous<T>(value: T, callback: string): T {
  if (
    value !== null &&
    (typeof value === "object" || typeof value === "function") &&
    typeof (value as { then?: unknown }).then === "function"
  ) {
    throw new TypeError(`${callback} must not return a Promise`)
  }
  return value
}

function normalizeAddress(address: ActorAddress): ActorAddress {
  requireObject(address, "address")
  requireString(address.kind, "address.kind")
  requireString(address.key, "address.key")
  return address
}

function encodeMessageId(messageId: bigint): Uint8Array {
  if (typeof messageId !== "bigint") throw new TypeError("messageId must be a bigint")
  if (messageId < 0n || messageId > MAX_U128) {
    throw new RangeError("messageId must be an unsigned 128-bit integer")
  }
  return writeU128(messageId)
}

function nativeOptionsFrom(options: RuntimeOptions | SQLiteRuntimeOptions): NativeRuntimeOptions {
  const snapshotEvery = requireU32(options.snapshotEvery ?? 128, "snapshotEvery")
  if (!isSQLiteRuntimeOptions(options)) return { kind: "memory", snapshotEvery }
  return {
    kind: "sqlite",
    snapshotEvery,
    path: encodeUtf8(requireString(options.path, "path")),
    busyTimeoutMs: requireU32(options.busyTimeoutMs ?? 5_000, "busyTimeoutMs"),
  }
}

function isSQLiteRuntimeOptions(options: RuntimeOptions | SQLiteRuntimeOptions): options is SQLiteRuntimeOptions {
  return "path" in options
}

function requireObject(value: unknown, label: string): asserts value is object {
  if (value === null || typeof value !== "object") throw new TypeError(`${label} must be an object`)
}

function requireString(value: unknown, label: string): string {
  if (typeof value !== "string") throw new TypeError(`${label} must be a string`)
  if (value.length === 0) throw new RangeError(`${label} must not be empty`)
  return value
}

function requireU32(value: number, label: string): number {
  if (!Number.isInteger(value) || value < 0 || value > MAX_U32) {
    throw new RangeError(`${label} must be an unsigned 32-bit integer`)
  }
  return value
}

function requireU64(value: bigint, label: string): void {
  if (typeof value !== "bigint") throw new TypeError(`${label} must be a bigint`)
  if (value < 0n || value > MAX_U64) throw new RangeError(`${label} must be an unsigned 64-bit integer`)
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  return String(error)
}
