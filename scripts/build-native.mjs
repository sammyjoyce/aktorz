import { spawnSync } from "node:child_process"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const args = process.argv.slice(2)
const zig = process.env.ZIG ?? "zig"
const zigArgs = ["build"]

if (args.includes("--all")) {
  zigArgs.push("typescript-native-all")
} else {
  zigArgs.push("typescript-native")
  const targetIndex = args.indexOf("--target")
  if (targetIndex !== -1) {
    const key = args[targetIndex + 1]
    if (key === undefined) fail("--target requires a platform key")
    zigArgs.push(`-Dtypescript-target=${key}`)
  }
}

console.log(`Building aktorz native library (${zig} ${zigArgs.join(" ")})`)
const result = spawnSync(zig, zigArgs, { cwd: root, stdio: "inherit" })
if (result.error !== undefined) throw result.error
if (result.status !== 0) process.exit(result.status ?? 1)

function fail(message) {
  console.error(message)
  process.exit(1)
}
