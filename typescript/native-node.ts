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

// Pinned to 2.16.3: koffi 3.0.0-3.1.2 corrupt AArch64 callback arguments passed on the
// stack (9th argument and beyond). arm64.cc CallData::Relay reads stack args via
// `in_ptr = sp + 48` with offsets `19 * 8 + k` (= sp+200), but arm64_asm.S places them
// at sp+208. Our DispatchFn takes 10 arguments, so output_ptr/output_capacity land in
// the corrupted slots. Unfixed on codeberg master as of 3.1.2 (2026-07-21).
// Related (different bug, same workaround): https://github.com/Koromix/koffi/issues/273
const requireModule = createRequire(import.meta.url)

type KoffiType = unknown

type KoffiLibrary = {
  func(name: string, result: KoffiType, arguments_: readonly KoffiType[]): (...args: unknown[]) => unknown
  unload(): void
}

type KoffiModule = {
  load(path: string): KoffiLibrary
  proto(name: string, result: KoffiType, arguments_: readonly KoffiType[]): KoffiType
  pointer(type: KoffiType): KoffiType
  register(callback: (...args: unknown[]) => unknown, type: KoffiType): Pointer
  unregister(callback: Pointer): void
  view(pointer: Pointer, length: number): ArrayBuffer
}

export function loadNodeApi(path: string): RawApi {
  let koffi: KoffiModule
  try {
    const loaded = requireModule("koffi") as KoffiModule | { default: KoffiModule }
    koffi = "default" in loaded ? loaded.default : loaded
  } catch (error) {
    throw new Error('Node.js bindings require the "koffi" package', { cause: error })
  }

  const library = koffi.load(path)
  const dispatchType = koffi.proto("AktorzDispatch", "int64_t", [
    "uint64_t",
    "uint32_t",
    "uint64_t",
    "uint64_t",
    "const uint8_t *",
    "uint64_t",
    "const uint8_t *",
    "uint64_t",
    "uint8_t *",
    "uint64_t",
  ])
  const dispatchPointerType = koffi.pointer(dispatchType)

  const abiVersion = library.func("aktorz_abi_version", "uint32_t", [])
  const runtimeCreateMemory = library.func("aktorz_runtime_create_memory", "void *", [
    dispatchPointerType,
    "uint64_t",
    "uint32_t",
  ])
  const runtimeDestroy = library.func("aktorz_runtime_destroy", "void", ["void *"])
  const runtimeRegister = library.func("aktorz_runtime_register", "void *", [
    "void *",
    "const uint8_t *",
    "uint64_t",
  ])
  const runtimeRequest = library.func("aktorz_runtime_request", "void *", [
    "void *",
    "const uint8_t *",
    "uint64_t",
    "const uint8_t *",
    "uint64_t",
    "const uint8_t *",
    "uint64_t",
    "const uint8_t *",
    "uint64_t",
  ])
  const runtimeTell = library.func("aktorz_runtime_tell", "void *", [
    "void *",
    "const uint8_t *",
    "uint64_t",
    "const uint8_t *",
    "uint64_t",
    "const uint8_t *",
    "uint64_t",
    "const uint8_t *",
    "uint64_t",
  ])
  const runtimePassivate = library.func("aktorz_runtime_passivate", "void *", [
    "void *",
    "const uint8_t *",
    "uint64_t",
    "const uint8_t *",
    "uint64_t",
  ])
  const runtimePassivateIdle = library.func("aktorz_runtime_passivate_idle", "void *", [
    "void *",
    "const uint8_t *",
    "uint64_t",
  ])
  const runtimeShutdown = library.func("aktorz_runtime_shutdown", "void *", ["void *"])
  const resultKind = library.func("aktorz_result_kind", "uint32_t", ["void *"])
  const resultData = library.func("aktorz_result_data", "void *", ["void *"])
  const resultLength = library.func("aktorz_result_length", "uint64_t", ["void *"])
  const resultDestroy = library.func("aktorz_result_destroy", "void", ["void *"])

  const read = (pointer: Pointer, length: number): Uint8Array => new Uint8Array(koffi.view(pointer, length)).slice()
  const view = (pointer: Pointer, length: number): Uint8Array => new Uint8Array(koffi.view(pointer, length))
  const input = (bytes: Uint8Array): Uint8Array | null => (bytes.byteLength === 0 ? null : bytes)

  return {
    abiVersion: () => Number(abiVersion()),
    createDispatch(dispatch) {
      const callback = koffi.register(
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
        dispatchPointerType,
      )
      return { pointer: callback, close: () => koffi.unregister(callback) }
    },
    runtimeCreateMemory: (dispatch, context, snapshotEvery) =>
      normalizePointer(runtimeCreateMemory(dispatch, context, snapshotEvery)),
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
    close: () => library.unload(),
  }
}
