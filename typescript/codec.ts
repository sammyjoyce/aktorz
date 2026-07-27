import type { ActorDecision, BytesLike } from "./types.js"

const encoder = new TextEncoder()
const decoder = new TextDecoder()

export function toBytes(value: BytesLike): Uint8Array {
  if (typeof value === "string") {
    return encoder.encode(value)
  }
  if (value instanceof Uint8Array) {
    return value
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value)
  }
  return new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
}

export function utf8(value: Uint8Array): string {
  return decoder.decode(value)
}

export function encodeUtf8(value: string): Uint8Array {
  return encoder.encode(value)
}

export function readU64(bytes: Uint8Array, offset = 0): bigint {
  requireRange(bytes, offset, 8)
  return new DataView(bytes.buffer, bytes.byteOffset + offset, 8).getBigUint64(0, true)
}

export function writeU64(value: bigint): Uint8Array {
  const bytes = new Uint8Array(8)
  new DataView(bytes.buffer).setBigUint64(0, value, true)
  return bytes
}

export function encodeDecision(decision: ActorDecision): Uint8Array {
  const mutation = decision.mutation == null ? null : toBytes(decision.mutation)
  const reply = decision.reply == null ? null : toBytes(decision.reply)
  const mutationLength = mutation?.byteLength ?? 0
  const replyLength = reply?.byteLength ?? 0
  const bytes = new Uint8Array(17 + mutationLength + replyLength)
  const view = new DataView(bytes.buffer)

  bytes[0] = (mutation === null ? 0 : 1) | (reply === null ? 0 : 2)
  view.setBigUint64(1, BigInt(mutationLength), true)
  view.setBigUint64(9, BigInt(replyLength), true)

  let offset = 17
  if (mutation !== null) {
    bytes.set(mutation, offset)
    offset += mutationLength
  }
  if (reply !== null) {
    bytes.set(reply, offset)
  }
  return bytes
}

export function copyBytes(value: Uint8Array): Uint8Array {
  return value.slice()
}

function requireRange(bytes: Uint8Array, offset: number, length: number): void {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset + length > bytes.byteLength) {
    throw new RangeError(`Expected ${length} bytes at offset ${offset}, received ${bytes.byteLength}`)
  }
}
