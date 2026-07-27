from __future__ import annotations

import json
import re
from pathlib import Path

root = Path.cwd()


def read(path: str) -> str:
    return (root / path).read_text()


def write(path: str, value: str) -> None:
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(value)


write(
    "typescript/sqlite-options.ts",
    '''import type { RuntimeOptions } from "./types.js";

/** Options for the durable SQLite-backed actor runtime. */
export interface SQLiteRuntimeOptions extends RuntimeOptions {
  /** SQLite database path. Parent directories must already exist. */
  path: string;
  /** SQLite busy timeout in milliseconds. Defaults to 5 seconds. */
  busyTimeoutMs?: number;
}
''',
)

index = read("typescript/index.ts")
export_line = 'export type { SQLiteRuntimeOptions } from "./sqlite-options.js";\n'
if export_line not in index:
    index = index.rstrip() + "\n" + export_line
write("typescript/index.ts", index)

runtime = read("typescript/runtime.ts")
if './sqlite-options.js' not in runtime:
    imports = list(re.finditer(r'^import .*?;\n', runtime, re.M | re.S))
    if not imports:
        raise RuntimeError("runtime.ts imports not found")
    position = imports[-1].end()
    runtime = runtime[:position] + 'import type { SQLiteRuntimeOptions } from "./sqlite-options.js";\n' + runtime[position:]

if "interface InternalRuntimeOptions" not in runtime:
    marker = re.search(r'\nexport class Runtime\b', runtime)
    if marker is None:
        raise RuntimeError("Runtime class not found")
    internal = '''
interface InternalRuntimeOptions extends RuntimeOptions {
  readonly __aktorzSqlite?: {
    readonly path: string;
    readonly busyTimeoutMs: number;
  };
}
'''
    runtime = runtime[: marker.start()] + internal + runtime[marker.start() :]

if "static sqlite(" not in runtime:
    marker = re.search(r'\n  (?:register|request|shutdown|close)\s*\(', runtime)
    if marker is None:
        raise RuntimeError("Runtime method insertion point not found")
    method = '''
  /** Create a durable runtime backed by a SQLite database. */
  static sqlite(options: SQLiteRuntimeOptions): Runtime {
    if (typeof options?.path !== "string" || options.path.length === 0) {
      throw new TypeError("Runtime.sqlite requires a non-empty path");
    }
    const busyTimeoutMs = options.busyTimeoutMs ?? 5_000;
    if (!Number.isInteger(busyTimeoutMs) || busyTimeoutMs < 0 || busyTimeoutMs > 0xffff_ffff) {
      throw new RangeError("busyTimeoutMs must be an unsigned 32-bit integer");
    }
    const { path, busyTimeoutMs: _busyTimeoutMs, ...runtimeOptions } = options;
    return new Runtime({
      ...runtimeOptions,
      __aktorzSqlite: { path, busyTimeoutMs },
    } as InternalRuntimeOptions);
  }
'''
    runtime = runtime[: marker.start()] + method + runtime[marker.start() :]
write("typescript/runtime.ts", runtime)

shared = read("typescript/native-shared.ts")
if "runtimeCreateSQLite" not in shared:
    match = re.search(
        r'(?P<indent>\s*)runtimeCreateMemory\s*\((?P<params>.*?)\)\s*:\s*(?P<ret>[^;]+);',
        shared,
        re.S,
    )
    if match is None:
        raise RuntimeError("RawApi.runtimeCreateMemory signature not found")
    params = match.group("params").rstrip()
    if params and not params.endswith(","):
        params += ","
    addition = (
        match.group(0)
        + "\n"
        + match.group("indent")
        + "runtimeCreateSQLite("
        + params
        + "\n"
        + match.group("indent")
        + "  path: string,\n"
        + match.group("indent")
        + "  busyTimeoutMs: number,\n"
        + match.group("indent")
        + "): "
        + match.group("ret").strip()
        + ";\n"
        + match.group("indent")
        + "runtimeLastCreateError(): string | null;"
    )
    shared = shared[: match.start()] + addition + shared[match.end() :]
write("typescript/native-shared.ts", shared)

native = read("typescript/native.ts")
native = re.sub(r'export const ABI_VERSION\s*=\s*2\b', 'export const ABI_VERSION = 3', native)
if "interface InternalRuntimeOptions" not in native:
    marker = re.search(r'\nexport (?:class|function|const)\b', native)
    if marker is None:
        raise RuntimeError("native.ts export marker not found")
    internal = '''
interface InternalRuntimeOptions extends RuntimeOptions {
  readonly __aktorzSqlite?: {
    readonly path: string;
    readonly busyTimeoutMs: number;
  };
}
'''
    native = native[: marker.start()] + internal + native[marker.start() :]

if "runtimeCreateSQLite(" not in native:
    match = re.search(
        r'(?P<prefix>const\s+(?P<handle>[A-Za-z_$][\w$]*)\s*=\s*)(?P<api>[A-Za-z_$][\w$]*)\.runtimeCreateMemory\((?P<args>.*?)\);',
        native,
        re.S,
    )
    if match is None:
        raise RuntimeError("native runtime creation assignment not found")
    options_name = "options"
    before = native[max(0, match.start() - 2000) : match.start()]
    params = list(re.finditer(r'([A-Za-z_$][\w$]*)\s*:\s*RuntimeOptions', before))
    if params:
        options_name = params[-1].group(1)
    arguments = match.group("args").rstrip().rstrip(",")
    replacement = (
        match.group("prefix")
        + "(() => {\n"
        + f"      const sqlite = ({options_name} as InternalRuntimeOptions).__aktorzSqlite;\n"
        + "      if (sqlite === undefined) {\n"
        + f"        return {match.group('api')}.runtimeCreateMemory({match.group('args')});\n"
        + "      }\n"
        + f"      return {match.group('api')}.runtimeCreateSQLite({arguments}, sqlite.path, sqlite.busyTimeoutMs);\n"
        + "    })();"
    )
    native = native[: match.start()] + replacement + native[match.end() :]
    null_block = re.search(
        r'if\s*\(\s*' + re.escape(match.group("handle")) + r'\s*={2,3}\s*null\s*\)\s*\{(?P<body>.*?)\}',
        native,
        re.S,
    )
    if null_block is not None and "runtimeLastCreateError" not in null_block.group("body"):
        body = re.sub(
            r'throw\s+new\s+Error\((?P<msg>.*?)\);',
            f"throw new Error({match.group('api')}.runtimeLastCreateError() ?? \\g<msg>);",
            null_block.group("body"),
            count=1,
            flags=re.S,
        )
        native = native[: null_block.start("body")] + body + native[null_block.end("body") :]
write("typescript/native.ts", native)


def extract_property(text: str, name: str):
    match = re.search(r'(?m)^(?P<indent>\s*)' + re.escape(name) + r'\s*:\s*', text)
    if match is None:
        return None
    start = match.start()
    expression_start = match.end()
    depth = 0
    quote = None
    escape = False
    index = expression_start
    while index < len(text):
        char = text[index]
        if quote is not None:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == quote:
                quote = None
        else:
            if char in "'\"`":
                quote = char
            elif char in "([{":
                depth += 1
            elif char in ")]}" :
                depth -= 1
            elif char == "," and depth == 0:
                return match, start, index + 1, text[start : index + 1], text[expression_start:index]
        index += 1
    raise RuntimeError(f"could not extract property {name}")

node_path = root / "typescript/native-node.ts"
node = node_path.read_text()
if "runtimeCreateSQLite" not in node:
    found = extract_property(node, "runtimeCreateMemory")
    if found is None:
        raise RuntimeError("Node runtimeCreateMemory property not found")
    match, start, end, prop, expression = found
    sqlite_expression = expression.replace("aktorz_runtime_create_memory", "aktorz_runtime_create_sqlite")
    if re.search(r'aktorz_runtime_create_sqlite\([^\"]*\)', sqlite_expression):
        sqlite_expression = re.sub(
            r'(aktorz_runtime_create_sqlite\([^\"]*?)(\))',
            r'\1, str, uint32_t\2',
            sqlite_expression,
            count=1,
        )
    else:
        close = sqlite_expression.rfind("]")
        if close < 0:
            raise RuntimeError("Node runtimeCreateMemory argument array not found")
        prefix = sqlite_expression[:close].rstrip()
        separator = "" if prefix.endswith("[") else ", "
        sqlite_expression = prefix + separator + '"str", "uint32"' + sqlite_expression[close:]
    library_match = re.search(r'([A-Za-z_$][\w$]*)\.func\s*\(', expression)
    if library_match is None:
        raise RuntimeError("Node Koffi library variable not found")
    library = library_match.group(1)
    insert = (
        prop
        + "\n"
        + match.group("indent")
        + "runtimeCreateSQLite: "
        + sqlite_expression.strip()
        + ",\n"
        + match.group("indent")
        + f'runtimeLastCreateError: {library}.func("aktorz_runtime_last_create_error", "str", []),'
    )
    node = node[:start] + insert + node[end:]
node_path.write_text(node)


def balanced_block(text: str, start: int) -> int:
    depth = 0
    quote = None
    escape = False
    for index in range(start, len(text)):
        char = text[index]
        if quote is not None:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == quote:
                quote = None
        else:
            if char in "'\"`":
                quote = char
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    cursor = index + 1
                    while cursor < len(text) and text[cursor].isspace():
                        cursor += 1
                    if cursor < len(text) and text[cursor] == ",":
                        cursor += 1
                    return cursor
    raise RuntimeError("unbalanced block")

bun_path = root / "typescript/native-bun.ts"
bun = bun_path.read_text()
if "runtimeCreateSQLite" not in bun:
    symbol = re.search(r'(?m)^(?P<indent>\s*)aktorz_runtime_create_memory\s*:\s*\{', bun)
    if symbol is None:
        raise RuntimeError("Bun native symbol definition not found")
    symbol_end = balanced_block(bun, bun.find("{", symbol.start()))
    block = bun[symbol.start() : symbol_end]
    sqlite_block = block.replace("aktorz_runtime_create_memory", "aktorz_runtime_create_sqlite")
    arguments = re.search(r'args\s*:\s*\[(?P<body>.*?)\]', sqlite_block, re.S)
    if arguments is None:
        raise RuntimeError("Bun args array not found")
    argument_body = arguments.group("body").rstrip()
    separator = "" if not argument_body else ", "
    sqlite_block = (
        sqlite_block[: arguments.start("body")]
        + argument_body
        + separator
        + "FFIType.ptr, FFIType.u32"
        + sqlite_block[arguments.end("body") :]
    )
    last_error_block = symbol.group("indent") + "aktorz_runtime_last_create_error: { args: [], returns: FFIType.ptr },\n"
    bun = bun[:symbol_end] + sqlite_block + last_error_block + bun[symbol_end:]
    found = extract_property(bun, "runtimeCreateMemory")
    if found is None:
        raise RuntimeError("Bun runtimeCreateMemory mapping not found")
    match, start, end, prop, expression = found
    symbols_match = re.search(r'([A-Za-z_$][\w$]*)\.aktorz_runtime_create_memory', expression)
    if symbols_match is None:
        raise RuntimeError("Bun symbols variable not found")
    symbols = symbols_match.group(1)
    wrappers = (
        prop
        + "\n"
        + match.group("indent")
        + "runtimeCreateSQLite(dispatch, context, snapshotEvery, path, busyTimeoutMs) {\n"
        + match.group("indent")
        + "  const pathBytes = new TextEncoder().encode(`${path}\\0`);\n"
        + match.group("indent")
        + f"  return {symbols}.aktorz_runtime_create_sqlite(dispatch, context, snapshotEvery, pathBytes, busyTimeoutMs);\n"
        + match.group("indent")
        + "},\n"
        + match.group("indent")
        + "runtimeLastCreateError() {\n"
        + match.group("indent")
        + f"  const pointer = {symbols}.aktorz_runtime_last_create_error();\n"
        + match.group("indent")
        + "  return pointer == null ? null : new CString(pointer).toString();\n"
        + match.group("indent")
        + "},"
    )
    bun = bun[:start] + wrappers + bun[end:]
if "new CString(" in bun and "CString" not in bun.split("from \"bun:ffi\"")[0]:
    bun = bun.replace('import { dlopen, FFIType } from "bun:ffi";', 'import { CString, dlopen, FFIType } from "bun:ffi";')
    bun = bun.replace('import { dlopen, FFIType, suffix } from "bun:ffi";', 'import { CString, dlopen, FFIType, suffix } from "bun:ffi";')
bun_path.write_text(bun)

package_path = root / "package.json"
package = json.loads(package_path.read_text())
package["version"] = "0.4.0"
scripts = package.setdefault("scripts", {})
scripts["test:sqlite"] = "node test/typescript-sqlite.mjs"
if "test:node" in scripts and "test:sqlite" not in scripts["test:node"]:
    scripts["test:node"] = scripts["test:node"].rstrip() + " && npm run test:sqlite"
package_path.write_text(json.dumps(package, indent=2) + "\n")

lock_path = root / "package-lock.json"
lock = json.loads(lock_path.read_text())
lock["version"] = "0.4.0"
if isinstance(lock.get("packages"), dict) and "" in lock["packages"]:
    lock["packages"][""]["version"] = "0.4.0"
lock_path.write_text(json.dumps(lock, indent=2) + "\n")

zon = read("build.zig.zon")
zon = re.sub(r'\.version\s*=\s*"0\.3\.0"', '.version = "0.4.0"', zon, count=1)
if ".sqlite3" not in zon:
    dependency_marker = re.search(r'\.dependencies\s*=\s*\.\{', zon)
    if dependency_marker is None:
        raise RuntimeError("build.zig.zon dependencies not found")
    dependency = '''
        .sqlite3 = .{
            .url = "https://sqlite.org/2026/sqlite-amalgamation-3530200.zip",
            .hash = "N-V-__8AALc_rgC04POe18O0LKFRm4ouQpLtL3riscEmWp-Q",
        },'''
    zon = zon[: dependency_marker.end()] + dependency + zon[dependency_marker.end() :]
write("build.zig.zon", zon)

write(
    "test/typescript-sqlite.mjs",
    r'''import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Runtime } from "../dist/index.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const directory = mkdtempSync(join(tmpdir(), "aktorz-sqlite-"));
const database = join(directory, "actors.sqlite3");
const address = { kind: "counter", key: "persistent" };

const service = {
  create() {
    return { value: 0 };
  },
  loadSnapshot(state, bytes) {
    state.value = Number(decoder.decode(bytes));
  },
  makeSnapshot(state) {
    return encoder.encode(String(state.value));
  },
  decide(state, message) {
    const next = state.value + Number(decoder.decode(message));
    const bytes = encoder.encode(String(next));
    return { mutation: bytes, reply: bytes };
  },
  apply(state, mutation) {
    state.value = Number(decoder.decode(mutation));
  },
};

function open() {
  return Runtime.sqlite({ path: database, busyTimeoutMs: 1_000, snapshotEvery: 1 }).register("counter", service);
}

try {
  const first = open();
  assert.equal(decoder.decode(first.request(address, 1n, encoder.encode("2"))), "2");
  assert.equal(decoder.decode(first.request(address, 2n, encoder.encode("3"))), "5");
  first.shutdown();
  first.close();

  const second = open();
  assert.equal(decoder.decode(second.request(address, 1n, encoder.encode("99"))), "2", "duplicate reply survives reopen");
  assert.equal(decoder.decode(second.request(address, 3n, encoder.encode("4"))), "9");
  second.passivate(address);
  second.shutdown();
  second.close();

  const third = open();
  assert.equal(decoder.decode(third.request(address, 3n, encoder.encode("999"))), "9", "dedupe survives passivation and reopen");
  assert.equal(decoder.decode(third.request(address, 4n, encoder.encode("1"))), "10");
  third.shutdown();
  third.close();
} finally {
  rmSync(directory, { recursive: true, force: true });
}
''',
)
