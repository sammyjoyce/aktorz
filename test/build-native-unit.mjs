import assert from "node:assert/strict"

import { buildNativeZigArgs } from "../scripts/build-native.mjs"

assert.deepEqual(buildNativeZigArgs([], { platform: "darwin", arch: "arm64", libc: "" }), [
  "build",
  "typescript-native",
])
assert.deepEqual(buildNativeZigArgs([], { platform: "linux", arch: "x64", libc: "musl" }), [
  "build",
  "typescript-native",
  "-Dtypescript-target=linux-x64-musl",
])
assert.deepEqual(buildNativeZigArgs([], { platform: "linux", arch: "arm64", libc: "glibc" }), [
  "build",
  "typescript-native",
  "-Dtypescript-target=linux-arm64-gnu",
])
assert.deepEqual(
  buildNativeZigArgs(["--target", "win32-x64"], { platform: "linux", arch: "x64", libc: "musl" }),
  ["build", "typescript-native", "-Dtypescript-target=win32-x64"],
)
assert.deepEqual(buildNativeZigArgs(["--all"], { platform: "linux", arch: "x64", libc: "musl" }), [
  "build",
  "typescript-native-all",
])
assert.deepEqual(buildNativeZigArgs(["--spec"]), ["build", "typescript-native-spec"])
assert.throws(() => buildNativeZigArgs(["--target"]), /--target requires a platform key/)
assert.throws(
  () => buildNativeZigArgs([], { platform: "linux", arch: "x64", libc: "uclibc" }),
  /AKTORZ_LIBC must be/,
)
assert.throws(
  () => buildNativeZigArgs([], { platform: "linux", arch: "riscv64", libc: "musl" }),
  /Unsupported architecture/,
)

console.log("aktorz native build argument test passed")
