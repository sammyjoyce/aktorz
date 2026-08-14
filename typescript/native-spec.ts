export const ABI_VERSION = 3

export type NativeLibraryTarget = {
  readonly key: string
  readonly file: string
}

// Keep `src/typescript/native_spec.zig` in lockstep; `zig build test` verifies the twin.
export const NATIVE_LIBRARY_TARGETS = [
  { key: "darwin-arm64", file: "libaktorz.dylib" },
  { key: "darwin-x64", file: "libaktorz.dylib" },
  { key: "linux-arm64-gnu", file: "libaktorz.so" },
  { key: "linux-x64-gnu", file: "libaktorz.so" },
  { key: "linux-arm64-musl", file: "libaktorz.so" },
  { key: "linux-x64-musl", file: "libaktorz.so" },
  { key: "win32-arm64", file: "aktorz.dll" },
  { key: "win32-x64", file: "aktorz.dll" },
] as const satisfies readonly NativeLibraryTarget[]
