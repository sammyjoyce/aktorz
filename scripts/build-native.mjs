import { spawnSync } from "node:child_process"
import { dirname, resolve } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const entrypoint = process.argv[1]

if (entrypoint !== undefined && import.meta.url === pathToFileURL(resolve(entrypoint)).href) {
  main()
}

export function buildNativeZigArgs(
  args,
  { platform = process.platform, arch = process.arch, libc = process.env.AKTORZ_LIBC } = {},
) {
  if (args.includes("--spec")) return ["build", "typescript-native-spec"]
  if (args.includes("--all")) return ["build", "typescript-native-all"]

  const zigArgs = ["build", "typescript-native"]
  const targetIndex = args.indexOf("--target")
  if (targetIndex !== -1) {
    const key = args[targetIndex + 1]
    if (key === undefined) throw new Error("--target requires a platform key")
    zigArgs.push(`-Dtypescript-target=${key}`)
    return zigArgs
  }

  const key = configuredLinuxTarget(platform, arch, libc)
  if (key !== null) zigArgs.push(`-Dtypescript-target=${key}`)
  return zigArgs
}

function main() {
  const zig = process.env.ZIG ?? "zig"
  let zigArgs
  try {
    zigArgs = buildNativeZigArgs(process.argv.slice(2))
  } catch (error) {
    fail(error instanceof Error ? error.message : String(error))
  }

  console.log(`Running aktorz Zig step (${zig} ${zigArgs.join(" ")})`)
  const result = spawnSync(zig, zigArgs, { cwd: root, stdio: "inherit" })
  if (result.error !== undefined) throw result.error
  if (result.status !== 0) process.exit(result.status ?? 1)
}

function configuredLinuxTarget(platform, arch, configured) {
  if (platform !== "linux" || configured === undefined || configured === "") return null
  if (arch !== "x64" && arch !== "arm64") throw new Error(`Unsupported architecture: ${arch}`)

  if (configured === "musl") return `linux-${arch}-musl`
  if (configured === "gnu" || configured === "glibc") return `linux-${arch}-gnu`
  throw new Error(`AKTORZ_LIBC must be "gnu", "glibc", or "musl", got ${JSON.stringify(configured)}`)
}

function fail(message) {
  console.error(message)
  process.exit(1)
}
