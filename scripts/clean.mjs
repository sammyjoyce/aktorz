import { rmSync } from "node:fs"

for (const path of ["dist", "native", "zig-out/native"]) {
  rmSync(path, { recursive: true, force: true })
}
