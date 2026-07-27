import type { RuntimeOptions } from "./types.js";

/** Options for the durable SQLite-backed actor runtime. */
export interface SQLiteRuntimeOptions extends RuntimeOptions {
  /** SQLite database path. Parent directories must already exist. */
  path: string;
  /** SQLite busy timeout in milliseconds. Defaults to the native store default. */
  busyTimeoutMs?: number;
}
