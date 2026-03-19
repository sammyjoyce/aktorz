#!/usr/bin/env bash
set -euo pipefail

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig is not installed or not in PATH" >&2
  exit 127
fi

exec zig build -Doptimize=ReleaseFast bench -- --mode sqlite-suite
