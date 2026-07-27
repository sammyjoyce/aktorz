export type BytesLike = Uint8Array | ArrayBuffer | ArrayBufferView | string

export interface ActorAddress {
  readonly kind: string
  readonly key: string
}

export interface ActorDecision {
  readonly mutation?: BytesLike | null
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
  loadSnapshot(state: State, snapshot: Uint8Array): void
  makeSnapshot(state: State): BytesLike
  decide(state: State, message: Uint8Array): ActorDecision
  apply(state: State, mutation: Uint8Array): void
  destroy?(state: State): void
}

export interface RuntimeOptions {
  /** Snapshot after this many persisted mutations. Defaults to 128. */
  readonly snapshotEvery?: number
  /** Override the packaged native library. Also available as AKTORZ_LIBRARY_PATH. */
  readonly libraryPath?: string
}
