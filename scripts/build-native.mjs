import { cpSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")

const targets = [
  { key: "darwin-arm64", zig: "aarch64-macos", file: "libaktorz.dylib" },
  { key: "darwin-x64", zig: "x86_64-macos", file: "libaktorz.dylib" },
  { key: "linux-arm64-gnu", zig: "aarch64-linux-gnu.2.17", file: "libaktorz.so" },
  { key: "linux-x64-gnu", zig: "x86_64-linux-gnu.2.17", file: "libaktorz.so" },
  { key: "linux-arm64-musl", zig: "aarch64-linux-musl", file: "libaktorz.so" },
  { key: "linux-x64-musl", zig: "x86_64-linux-musl", file: "libaktorz.so" },
  { key: "win32-arm64", zig: "aarch64-windows-gnu", file: "aktorz.dll" },
  { key: "win32-x64", zig: "x86_64-windows-gnu", file: "aktorz.dll" },
]

const requested = selectTargets(process.argv.slice(2))
for (const target of requested) buildTarget(target)

function selectTargets(args) {
  if (args.includes("--all")) return targets

  const targetIndex = args.indexOf("--target")
  if (targetIndex !== -1) {
    const key = args[targetIndex + 1]
    if (key === undefined) fail("--target requires a platform key")
    const target = targets.find((candidate) => candidate.key === key)
    if (target === undefined) fail(`Unknown native target ${JSON.stringify(key)}. Expected one of: ${targets.map(({ key }) => key).join(", ")}`)
    return [target]
  }

  const host = hostTarget()
  const target = targets.find((candidate) => candidate.key === host)
  if (target === undefined) fail(`Unsupported host target: ${host}`)
  return [target]
}

function hostTarget() {
  if (process.arch !== "x64" && process.arch !== "arm64") {
    fail(`Unsupported architecture: ${process.arch}`)
  }
  if (process.platform === "darwin" || process.platform === "win32") {
    return `${process.platform}-${process.arch}`
  }
  if (process.platform === "linux") {
    const configured = process.env.AKTORZ_LIBC
    const libc = configured === "musl" ? "musl" : configured === "gnu" || configured === "glibc" ? "gnu" : detectLinuxLibc()
    return `linux-${process.arch}-${libc}`
  }
  fail(`Unsupported platform: ${process.platform}`)
}

function detectLinuxLibc() {
  const header = process.report?.getReport().header
  return header?.glibcVersionRuntime === undefined ? "musl" : "gnu"
}

function buildTarget(target) {
  const prefix = join(root, "zig-out", "typescript", target.key)
  rmSync(prefix, { recursive: true, force: true })
  mkdirSync(prefix, { recursive: true })

  console.log(`Building aktorz native library for ${target.key}`)
  const result = spawnSync(
    process.env.ZIG ?? "zig",
    [
      "build",
      "typescript-native",
      `-Dtarget=${target.zig}`,
      "-Doptimize=ReleaseFast",
      "--prefix",
      prefix,
    ],
    { cwd: root, stdio: "inherit" },
  )
  if (result.error !== undefined) throw result.error
  if (result.status !== 0) process.exit(result.status ?? 1)

  const built = findFile(prefix, target.file)
  if (built === null) fail(`Zig completed without producing ${target.file} under ${prefix}`)

  const destination = join(root, "native", target.key, target.file)
  mkdirSync(dirname(destination), { recursive: true })
  cpSync(built, destination)
  console.log(`Wrote ${destination}`)
}

function findFile(directory, filename) {
  if (!existsSync(directory)) return null
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name)
    if (entry.isFile() && entry.name === filename) return path
    if (entry.isDirectory()) {
      const nested = findFile(path, filename)
      if (nested !== null) return nested
    }
  }
  return null
}

function fail(message) {
  console.error(message)
  process.exit(1)
}
