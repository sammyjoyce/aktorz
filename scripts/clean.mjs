import { rmSync } from "node:fs"

for (const path of ["dist", "native", "zig-out/typescript"]) {
  rmSync(path, { recursive: true, force: true })
}
