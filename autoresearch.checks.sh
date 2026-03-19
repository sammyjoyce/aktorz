#!/usr/bin/env bash
set -euo pipefail

zig build test >/dev/null
zig build sqlite-test >/dev/null
