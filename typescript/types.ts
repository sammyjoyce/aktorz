export type BytesLike = Uint8Array | ArrayBuffer | ArrayBufferView | string

export interface ActorAddress {
  readonly kind: string
  readonly key: string
}

/**
 * The result of one synchronous `ActorService.decide()` invocation.
 *
 * `decide()` runs before duplicate detection and can run again when a caller
 * retries a message ID. See docs/deduplication.md for the exact boundary.
 */
export interface ActorDecision {
  /**
   * State-transition bytes to persist and then apply.
   *
   * A non-null mutation opts this attempt into per-actor message-ID
   * deduplication. When omitted or null, the request is not looked up or
   * recorded in the deduplication ledger.
   */
  readonly mutation?: BytesLike | null
  /**
   * Optional response bytes.
   *
   * For a newly persisted mutation, this reply is stored with the message ID;
   * a later mutating attempt with that ID returns the first stored reply.
   * Replies from decisions without mutations are never stored.
   */
  readonly reply?: BytesLike | null
}

/**
 * A synchronous state machine hosted by the native aktorz runtime.
 *
 * Callbacks run while the Zig runtime is processing a request. Returning a
 * Promise is not supported because the native runtime deliberately preserves
 * single-threaded, in-order actor execution.
 */
export interface ActorService<State> {
  create(address: ActorAddress): State
  /**
   * Loads a retained snapshot into a fresh state instance.
   *
   * Throwing prevents activation and quarantines the actor, because compacted
   * history may make recovery without the snapshot impossible.
   */
  loadSnapshot(state: State, snapshot: Uint8Array): void
  makeSnapshot(state: State): BytesLike
  /**
   * Decides one request attempt against the current state.
   *
   * Invoked before duplicate lookup, so it may run again for a retried
   * message ID, including when its mutation is later suppressed as a
   * duplicate.
   */
  decide(state: State, message: Uint8Array): ActorDecision
  /**
   * Applies an already-persisted mutation to in-memory state.
   *
   * Also runs while reconstructing an activation from durable state.
   * Implementations must complete synchronously, be deterministic and
   * replay-safe, mutate only `state`, and perform no I/O or other externally
   * visible side effects; they must not be `async` or return a thenable (an
   * already-started async prefix cannot be cancelled). Domain rejection
   * belongs in `decide()`. Throwing after a live append makes the runtime
   * discard this actor instance without snapshotting it; throwing during
   * recovery quarantines the actor.
   */
  apply(state: State, mutation: Uint8Array): void
  destroy?(state: State): void
}

export interface RuntimeOptions {
  /** Snapshot after this many persisted mutations. Defaults to 128. */
  readonly snapshotEvery?: number
  /** Override the packaged native library. Also available as AKTORZ_LIBRARY_PATH. */
  readonly libraryPath?: string
}

export interface SQLiteRuntimeOptions extends RuntimeOptions {
  /** SQLite database path. Parent directories must already exist. */
  readonly path: string
  /** Time to wait for a locked database before failing. Defaults to 5 seconds. */
  readonly busyTimeoutMs?: number
}
