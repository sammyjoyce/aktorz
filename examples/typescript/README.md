# TypeScript examples

Runnable, self-contained examples for the [aktorz](../../README.md) TypeScript
bindings. Each file imports from the `aktorz` package exactly the way a
consumer would and prints a narrated walkthrough.

| Example | What it shows |
| --- | --- |
| [`counter.ts`](counter.ts) | Getting started: `Runtime.memory()`, registering an `ActorService`, `request()`/`tell()`, actor isolation by key, passivation and snapshot reload. |
| [`cart.ts`](cart.ts) | A shopping cart with typed JSON commands and events — the decide/apply split, domain error replies vs. thrown errors, per-key actor state. TypeScript port of [`cart_example.zig`](../cart_example.zig). |
| [`bank.ts`](bank.ts) | Message-ID deduplication as retry protection for money movement, including the exact boundary: only mutating decisions are recorded, so this is not exactly-once execution. Port of [`bank_example.zig`](../bank_example.zig). |
| [`sqlite-durability.ts`](sqlite-durability.ts) | `Runtime.sqlite()`: state, snapshots, and the deduplication ledger surviving a close/reopen cycle. |

## Run

From a repo checkout, first build the library and the native artifact for your
host (requires Zig, see the [root README](../../README.md)):

```bash
npm install        # repo root
npm run build      # tsc -> dist/ and the native library -> native/<host>/
```

Then install and run the examples:

```bash
cd examples/typescript
npm install        # links aktorz from the repo root (file:../..)

npm run counter
npm run cart
npm run bank
npm run sqlite-durability
npm run all        # everything in sequence
```

The examples are plain ES modules with erasable-only TypeScript syntax, so
they run directly:

- **Node 23.6+** — `node counter.ts` (Node 22.6+ needs `node --experimental-strip-types counter.ts`)
- **Bun** — `bun counter.ts`

Type-check them with `npm run check`.

In your own project, replace the `file:../..` dependency with the published
package (`npm install aktorz`); the imports stay the same.

## Where to go next

- [`docs/typescript.md`](../../docs/typescript.md) — callback contract, SQLite options, failure semantics, ABI and packaging details.
- [`docs/deduplication.md`](../../docs/deduplication.md) — the full message-ID scope, lifecycle, and retention rules demonstrated in `bank.ts`.
- [`typescript/types.ts`](../../typescript/types.ts) — the complete typed API surface (`ActorService`, `ActorDecision`, runtime options).
