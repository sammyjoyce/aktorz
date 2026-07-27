import { createRequire } from "node:module"

import {
  decodeCallbackInput,
  decodeCallbackOutput,
  normalizePointer,
  toBigInt,
  type NativeDispatch,
  type Pointer,
  type RawApi,
} from "./native-shared.js"

const requireModule = createRequire(import.meta.url)

type BunCallback = {
  readonly ptr: Pointer | null
  close(): void
}

type BunLibrary = {
  readonly symbols: Record<string, (...args: unknown[]) => unknown>
  close(): void
}

type BunFfiModule = {
  dlopen(path: string, symbols: Record<string, { args: readonly string[]; returns: string }>): BunLibrary
  JSCallback: new (
    callback: (...args: unknown[]) => unknown,
    definition: { args: readonly string[]; returns: string },
  ) => BunCallback
  ptr(value: ArrayBufferLike | ArrayBufferView): Pointer
  toArrayBuffer(pointer: Pointer, offset: number, length: number): ArrayBuffer
}

export function loadBunApi(path: string): RawApi {
  const bun = requireModule("bun:ffi") as BunFfiModule
  const library = bun.dlopen(path, {
    aktorz_abi_version: { args: [], returns: "u32" },
    aktorz_runtime_create_memory: { args: ["ptr", "u64", "u32"], returns: "ptr" },
    aktorz_runtime_create_sqlite: {
      args: ["ptr", "u64", "u32", "ptr", "u64", "u32"],
      returns: "ptr",
    },
    aktorz_runtime_create_error: { args: [], returns: "ptr" },
    aktorz_runtime_destroy: { args: ["ptr"], returns: "void" },
    aktorz_runtime_register: { args: ["ptr", "ptr", "u64"], returns: "ptr" },
    aktorz_runtime_request: {
      args: ["ptr", "ptr", "u64", "ptr", "u64", "ptr", "u64", "ptr", "u64"],
      returns: "ptr",
    },
    aktorz_runtime_tell: {
      args: ["ptr", "ptr", "u64", "ptr", "u64", "ptr", "u64", "ptr", "u64"],
      returns: "ptr",
    },
    aktorz_runtime_passivate: { args: ["ptr", "ptr", "u64", "ptr", "u64"], returns: "ptr" },
    aktorz_runtime_passivate_idle: { args: ["ptr", "ptr", "u64"], returns: "ptr" },
    aktorz_runtime_shutdown: { args: ["ptr"], returns: "ptr" },
    aktorz_result_kind: { args: ["ptr"], returns: "u32" },
    aktorz_result_data: { args: ["ptr"], returns: "ptr" },
    aktorz_result_length: { args: ["ptr"], returns: "u64" },
    aktorz_result_destroy: { args: ["ptr"], returns: "void" },
  })
  const symbol = (name: string): ((...args: unknown[]) => unknown) => {
    const value = library.symbols[name]
    if (value === undefined) throw new Error(`Missing native aktorz symbol: ${name}`)
    return value
  }

  const abiVersion = symbol("aktorz_abi_version")
  const runtimeCreateMemory = symbol("aktorz_runtime_create_memory")
  const runtimeCreateSQLite = symbol("aktorz_runtime_create_sqlite")
  const runtimeCreateError = symbol("aktorz_runtime_create_error")
  const runtimeDestroy = symbol("aktorz_runtime_destroy")
  const runtimeRegister = symbol("aktorz_runtime_register")
  const runtimeRequest = symbol("aktorz_runtime_request")
  const runtimeTell = symbol("aktorz_runtime_tell")
  const runtimePassivate = symbol("aktorz_runtime_passivate")
  const runtimePassivateIdle = symbol("aktorz_runtime_passivate_idle")
  const runtimeShutdown = symbol("aktorz_runtime_shutdown")
  const resultKind = symbol("aktorz_result_kind")
  const resultData = symbol("aktorz_result_data")
  const resultLength = symbol("aktorz_result_length")
  const resultDestroy = symbol("aktorz_result_destroy")

  const read = (pointer: Pointer, length: number): Uint8Array =>
    new Uint8Array(bun.toArrayBuffer(pointer, 0, length)).slice()
  const view = (pointer: Pointer, length: number): Uint8Array =>
    new Uint8Array(bun.toArrayBuffer(pointer, 0, length))
  const input = (bytes: Uint8Array): Pointer | null => (bytes.byteLength === 0 ? null : bun.ptr(bytes))

  return {
    abiVersion: () => Number(abiVersion()),
    createDispatch(dispatch) {
      const callback = new bun.JSCallback(
        (...args: unknown[]) => {
          const [context, operation, callId, serviceId, input1Pointer, input1Length, input2Pointer, input2Length, outputPointer, outputCapacity] = args as [
            number | bigint,
            number,
            number | bigint,
            number | bigint,
            Pointer | null,
            number | bigint,
            Pointer | null,
            number | bigint,
            Pointer | null,
            number | bigint,
          ]
          return dispatch(
            toBigInt(context),
            operation,
            toBigInt(callId),
            toBigInt(serviceId),
            decodeCallbackInput(normalizePointer(input1Pointer), input1Length, read),
            decodeCallbackInput(normalizePointer(input2Pointer), input2Length, read),
            decodeCallbackOutput(normalizePointer(outputPointer), outputCapacity, view),
          )
        },
        {
          returns: "i64",
          args: ["u64", "u32", "u64", "u64", "ptr", "u64", "ptr", "u64", "ptr", "u64"],
        },
      )
      const callbackPointer = normalizePointer(callback.ptr)
      if (callbackPointer == null) {
        callback.close()
        throw new Error("Bun failed to allocate the aktorz FFI callback")
      }
      return { pointer: callbackPointer, close: () => callback.close() }
    },
    runtimeCreateMemory: (dispatch, context, snapshotEvery) =>
      normalizePointer(runtimeCreateMemory(dispatch, context, snapshotEvery)),
    runtimeCreateSQLite: (dispatch, context, snapshotEvery, pathBytes, busyTimeoutMs) =>
      normalizePointer(
        runtimeCreateSQLite(
          dispatch,
          context,
          snapshotEvery,
          input(pathBytes),
          BigInt(pathBytes.byteLength),
          busyTimeoutMs,
        ),
      ),
    runtimeCreateError: () => normalizePointer(runtimeCreateError()),
    runtimeDestroy: (runtime) => void runtimeDestroy(runtime),
    runtimeRegister: (runtime, kind) =>
      normalizePointer(runtimeRegister(runtime, input(kind), BigInt(kind.byteLength))),
    runtimeRequest: (runtime, kind, key, messageId, payload) =>
      normalizePointer(
        runtimeRequest(
          runtime,
          input(kind),
          BigInt(kind.byteLength),
          input(key),
          BigInt(key.byteLength),
          input(messageId),
          BigInt(messageId.byteLength),
          input(payload),
          BigInt(payload.byteLength),
        ),
      ),
    runtimeTell: (runtime, kind, key, messageId, payload) =>
      normalizePointer(
        runtimeTell(
          runtime,
          input(kind),
          BigInt(kind.byteLength),
          input(key),
          BigInt(key.byteLength),
          input(messageId),
          BigInt(messageId.byteLength),
          input(payload),
          BigInt(payload.byteLength),
        ),
      ),
    runtimePassivate: (runtime, kind, key) =>
      normalizePointer(
        runtimePassivate(
          runtime,
          input(kind),
          BigInt(kind.byteLength),
          input(key),
          BigInt(key.byteLength),
        ),
      ),
    runtimePassivateIdle: (runtime, ticks) =>
      normalizePointer(runtimePassivateIdle(runtime, input(ticks), BigInt(ticks.byteLength))),
    runtimeShutdown: (runtime) => normalizePointer(runtimeShutdown(runtime)),
    resultKind: (result) => Number(resultKind(result)),
    resultData: (result) => normalizePointer(resultData(result)),
    resultLength: (result) => toBigInt(resultLength(result) as number | bigint),
    resultDestroy: (result) => void resultDestroy(result),
    read,
    close: () => library.close(),
  }
}
