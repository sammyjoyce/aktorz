export const EMPTY_BYTES = new Uint8Array()

export type NativeDispatch = (
  context: bigint,
  operation: number,
  callId: bigint,
  serviceId: bigint,
  input1: Uint8Array,
  input2: Uint8Array,
  output: Uint8Array | null,
) => bigint

export type Pointer = unknown

export type RegisteredDispatch = {
  readonly pointer: Pointer
  close(): void
}

export type RawApi = {
  abiVersion(): number
  createDispatch(dispatch: NativeDispatch): RegisteredDispatch
  runtimeCreateMemory(dispatch: Pointer, context: bigint, snapshotEvery: number): Pointer | null
  runtimeDestroy(runtime: Pointer): void
  runtimeRegister(runtime: Pointer, kind: Uint8Array): Pointer | null
  runtimeRequest(
    runtime: Pointer,
    kind: Uint8Array,
    key: Uint8Array,
    messageHigh: bigint,
    messageLow: bigint,
    payload: Uint8Array,
  ): Pointer | null
  runtimeTell(
    runtime: Pointer,
    kind: Uint8Array,
    key: Uint8Array,
    messageHigh: bigint,
    messageLow: bigint,
    payload: Uint8Array,
  ): Pointer | null
  runtimePassivate(runtime: Pointer, kind: Uint8Array, key: Uint8Array): Pointer | null
  runtimePassivateIdle(runtime: Pointer, minimumIdleTicks: bigint): Pointer | null
  runtimeShutdown(runtime: Pointer): Pointer | null
  resultKind(result: Pointer): number
  resultData(result: Pointer): Pointer | null
  resultLength(result: Pointer): bigint
  resultDestroy(result: Pointer): void
  read(pointer: Pointer, length: number): Uint8Array
  close(): void
}

export function normalizePointer(value: unknown): Pointer | null {
  return value == null || value === 0 || value === 0n ? null : value
}

export function toBigInt(value: number | bigint): bigint {
  return typeof value === "bigint" ? value : BigInt(value)
}

export function toSafeLength(value: number | bigint, label: string): number {
  const integer = toBigInt(value)
  if (integer < 0n || integer > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new RangeError(`${label} length is outside JavaScript's safe integer range`)
  }
  return Number(integer)
}

export function decodeCallbackInput(
  pointer: Pointer | null,
  lengthValue: number | bigint,
  read: (pointer: Pointer, length: number) => Uint8Array,
): Uint8Array {
  const length = toSafeLength(lengthValue, "callback input")
  if (length === 0) return EMPTY_BYTES
  if (pointer == null) throw new Error("Native aktorz passed a null callback input pointer")
  return read(pointer, length)
}

export function decodeCallbackOutput(
  pointer: Pointer | null,
  capacityValue: number | bigint,
  view: (pointer: Pointer, length: number) => Uint8Array,
): Uint8Array | null {
  const capacity = toSafeLength(capacityValue, "callback output")
  if (pointer == null) {
    if (capacity !== 0) throw new Error("Native aktorz passed a null callback output pointer")
    return null
  }
  return view(pointer, capacity)
}
