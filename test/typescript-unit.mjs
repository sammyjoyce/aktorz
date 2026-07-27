import assert from "node:assert/strict"

import { encodeDecision, readU64, writeU64, writeU128 } from "../dist/codec.js"

assert.deepEqual(
  [...writeU128(0x0123456789abcdef_fedcba9876543210n)],
  [
    0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
    0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
  ],
)
assert.equal(readU64(writeU64(0xfedcba9876543210n)), 0xfedcba9876543210n)
assert.deepEqual([...encodeDecision({ mutation: new Uint8Array(), reply: new Uint8Array() })], [3, ...new Array(16).fill(0)])

console.log("aktorz TypeScript unit test passed")
