const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const OwnedBytes = struct {
    allocator: Allocator,
    bytes: []u8,

    pub fn clone(alloc: Allocator, bytes: []const u8) Allocator.Error!OwnedBytes {
        return .{
            .allocator = alloc,
            .bytes = try alloc.dupe(u8, bytes),
        };
    }

    pub fn fromOwned(alloc: Allocator, bytes: []u8) OwnedBytes {
        return .{
            .allocator = alloc,
            .bytes = bytes,
        };
    }

    pub fn deinit(self: OwnedBytes) void {
        self.allocator.free(self.bytes);
    }
};

pub const Address = struct {
    kind: []const u8,
    key: []const u8,
};

pub fn allocObjectId(alloc: Allocator, address: Address) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{d}:{s}:{s}", .{ address.kind.len, address.kind, address.key });
}

/// Result of one `Service.decide()` invocation.
///
/// `decide()` runs before duplicate detection and can run again when a caller
/// retries a message ID. A non-null `mutation` opts this attempt into the
/// scoped store's per-actor message-ID deduplication path; a null `mutation`
/// is neither looked up nor recorded, and its reply is returned directly.
/// See docs/deduplication.md for the exact boundary.
pub const Decision = struct {
    /// State-transition bytes to append before live application. When
    /// `appendOnce()` reports a duplicate, these bytes are discarded and
    /// `Service.apply()` is not called for this request attempt.
    mutation: ?OwnedBytes = null,
    /// Optional response bytes. For a newly appended mutation this reply is
    /// stored with the message ID; for a duplicate mutating decision the
    /// runtime discards this value and returns the stored reply. Replies from
    /// decisions without mutations are never stored.
    reply: ?OwnedBytes = null,

    pub fn deinit(self: *Decision) void {
        if (self.mutation) |m| m.deinit();
        if (self.reply) |r| r.deinit();
        self.* = .{};
    }
};

pub const Service = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        destroy: *const fn (ctx: *anyopaque, alloc: Allocator) void,
        load_snapshot: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,
        make_snapshot: *const fn (ctx: *anyopaque, alloc: Allocator) anyerror!OwnedBytes,
        decide: *const fn (ctx: *anyopaque, alloc: Allocator, message: []const u8) anyerror!Decision,
        /// Applies a mutation that is already persisted.
        ///
        /// The runtime invokes this callback after `appendOnce()` commits a
        /// live mutation and again while reconstructing an activation from
        /// its snapshot and mutation log. Implementations must complete
        /// synchronously, be deterministic and replay-safe, mutate only the
        /// service's in-memory state, and perform no externally visible side
        /// effects. Domain rejection belongs in `decide()`.
        ///
        /// For every mutation persisted by compatible service code, `apply()`
        /// is required to succeed. The error union is a containment boundary:
        /// if `apply()` fails after a live append, the runtime discards the
        /// activation without snapshotting it and returns
        /// `Runtime.Error.PostAppendApplyFailed`; if it fails while recovering
        /// durable state, the actor is quarantined and requests return
        /// `Runtime.Error.PoisonedActor` until `Runtime.retryPoisoned()` or a
        /// process restart succeeds.
        apply: *const fn (ctx: *anyopaque, mutation: []const u8) anyerror!void,
    };

    pub fn from(comptime T: type, ptr: *T) Service {
        return .{
            .ptr = ptr,
            .vtable = &struct {
                pub const value: VTable = .{
                    .destroy = struct {
                        fn call(ctx: *anyopaque, alloc: Allocator) void {
                            const self: *T = @ptrCast(@alignCast(ctx));
                            self.destroy(alloc);
                        }
                    }.call,
                    .load_snapshot = struct {
                        fn call(ctx: *anyopaque, bytes: []const u8) anyerror!void {
                            const self: *T = @ptrCast(@alignCast(ctx));
                            try self.loadSnapshot(bytes);
                        }
                    }.call,
                    .make_snapshot = struct {
                        fn call(ctx: *anyopaque, alloc: Allocator) anyerror!OwnedBytes {
                            const self: *T = @ptrCast(@alignCast(ctx));
                            return try self.makeSnapshot(alloc);
                        }
                    }.call,
                    .decide = struct {
                        fn call(ctx: *anyopaque, alloc: Allocator, message: []const u8) anyerror!Decision {
                            const self: *T = @ptrCast(@alignCast(ctx));
                            return try self.decide(alloc, message);
                        }
                    }.call,
                    .apply = struct {
                        fn call(ctx: *anyopaque, mutation: []const u8) anyerror!void {
                            const self: *T = @ptrCast(@alignCast(ctx));
                            try self.apply(mutation);
                        }
                    }.call,
                };
            }.value,
        };
    }

    pub fn destroy(self: Service, alloc: Allocator) void {
        self.vtable.destroy(self.ptr, alloc);
    }

    pub fn loadSnapshot(self: Service, bytes: []const u8) !void {
        try self.vtable.load_snapshot(self.ptr, bytes);
    }

    pub fn makeSnapshot(self: Service, alloc: Allocator) !OwnedBytes {
        return try self.vtable.make_snapshot(self.ptr, alloc);
    }

    pub fn decide(self: Service, alloc: Allocator, message: []const u8) !Decision {
        return try self.vtable.decide(self.ptr, alloc, message);
    }

    pub fn apply(self: Service, mutation: []const u8) !void {
        try self.vtable.apply(self.ptr, mutation);
    }
};

pub const Factory = struct {
    create_fn: *const fn (alloc: Allocator, address: Address) anyerror!Service,

    pub fn from(comptime T: type, comptime create_typed: *const fn (alloc: Allocator, address: Address) anyerror!*T) Factory {
        return .{
            .create_fn = struct {
                fn call(alloc: Allocator, address: Address) anyerror!Service {
                    return Service.from(T, try create_typed(alloc, address));
                }
            }.call,
        };
    }

    pub fn create(self: Factory, alloc: Allocator, address: Address) !Service {
        return try self.create_fn(alloc, address);
    }
};

/// Per-actor durability boundary.
///
/// Store callbacks are non-reentrant with respect to the runtime: an
/// implementation must not call back into `Runtime` (request, tell,
/// passivate) from any vtable method, mirroring the reentrancy rule for
/// `Service.decide()`.
pub const ScopedStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Snapshot = struct {
        last_seq: u64,
        bytes: OwnedBytes,
    };

    pub const AppendIntent = struct {
        message_id: u128,
        seq: u64,
        mutation: []const u8,
        reply: ?[]const u8 = null,
    };

    pub const AppendResult = union(enum) {
        inserted,
        duplicate: ?OwnedBytes,
    };

    pub const ReplayFn = *const fn (ctx: *anyopaque, seq: u64, mutation: []const u8) anyerror!void;

    pub const VTable = struct {
        destroy: *const fn (ctx: *anyopaque, alloc: Allocator) void,
        load_snapshot: *const fn (ctx: *anyopaque, alloc: Allocator) anyerror!?Snapshot,
        replay_after: *const fn (ctx: *anyopaque, after_seq: u64, replay_ctx: *anyopaque, replay_fn: ReplayFn) anyerror!void,
        append_once: *const fn (ctx: *anyopaque, alloc: Allocator, intent: AppendIntent) anyerror!AppendResult,
        write_snapshot: *const fn (ctx: *anyopaque, at_seq: u64, bytes: []const u8) anyerror!void,
        compact_before: *const fn (ctx: *anyopaque, first_live_seq: u64) anyerror!void,
    };

    pub fn from(comptime T: type, ptr: *T) ScopedStore {
        return .{
            .ptr = ptr,
            .vtable = &struct {
                pub const value: VTable = .{
                    .destroy = struct {
                        fn call(ctx: *anyopaque, alloc: Allocator) void {
                            const self: *T = @ptrCast(@alignCast(ctx));
                            self.destroy(alloc);
                        }
                    }.call,
                    .load_snapshot = struct {
                        fn call(ctx: *anyopaque, alloc: Allocator) anyerror!?Snapshot {
                            const self: *T = @ptrCast(@alignCast(ctx));
                            return try self.loadSnapshot(alloc);
                        }
                    }.call,
                    .replay_after = struct {
                        fn call(ctx: *anyopaque, after_seq: u64, replay_ctx: *anyopaque, replay_fn: ReplayFn) anyerror!void {
                            const self: *T = @ptrCast(@alignCast(ctx));
                            try self.replayAfter(after_seq, replay_ctx, replay_fn);
                        }
                    }.call,
                    .append_once = struct {
                        fn call(ctx: *anyopaque, alloc: Allocator, intent: AppendIntent) anyerror!AppendResult {
                            const self: *T = @ptrCast(@alignCast(ctx));
                            return try self.appendOnce(alloc, intent);
                        }
                    }.call,
                    .write_snapshot = struct {
                        fn call(ctx: *anyopaque, at_seq: u64, bytes: []const u8) anyerror!void {
                            const self: *T = @ptrCast(@alignCast(ctx));
                            try self.writeSnapshot(at_seq, bytes);
                        }
                    }.call,
                    .compact_before = struct {
                        fn call(ctx: *anyopaque, first_live_seq: u64) anyerror!void {
                            const self: *T = @ptrCast(@alignCast(ctx));
                            try self.compactBefore(first_live_seq);
                        }
                    }.call,
                };
            }.value,
        };
    }

    pub fn destroy(self: ScopedStore, alloc: Allocator) void {
        self.vtable.destroy(self.ptr, alloc);
    }

    pub fn loadSnapshot(self: ScopedStore, alloc: Allocator) !?Snapshot {
        return try self.vtable.load_snapshot(self.ptr, alloc);
    }

    pub fn replayAfter(self: ScopedStore, after_seq: u64, replay_ctx: *anyopaque, replay_fn: ReplayFn) !void {
        try self.vtable.replay_after(self.ptr, after_seq, replay_ctx, replay_fn);
    }

    /// Atomically records one mutation and its optional reply for this scope.
    ///
    /// `intent.message_id` is a per-actor deduplication key; the same numeric
    /// ID may be used independently by another actor. Returns `.inserted`
    /// only when the mutation was newly recorded. If the message ID is
    /// already retained, returns `.duplicate` with the stored optional reply
    /// and must not append a second mutation. The original request payload is
    /// not stored or compared, so conflicting payload reuse is not detected.
    ///
    /// The built-in stores return an error only when the append definitely
    /// did not commit. A store that cannot promise that must document its
    /// failures as ambiguous: the caller then retries the same message ID and
    /// the deduplication ledger reconciles the outcome.
    pub fn appendOnce(self: ScopedStore, alloc: Allocator, intent: AppendIntent) !AppendResult {
        return try self.vtable.append_once(self.ptr, alloc, intent);
    }

    pub fn writeSnapshot(self: ScopedStore, at_seq: u64, bytes: []const u8) !void {
        try self.vtable.write_snapshot(self.ptr, at_seq, bytes);
    }

    /// Removes mutation-log records below `first_live_seq`.
    ///
    /// Compaction must not remove the last representation required to recover
    /// any mutation covered by the current snapshot, and it deliberately does
    /// not touch the deduplication ledger: seen-message records outlive their
    /// compacted mutations so duplicate suppression survives snapshotting.
    pub fn compactBefore(self: ScopedStore, first_live_seq: u64) !void {
        try self.vtable.compact_before(self.ptr, first_live_seq);
    }
};

pub const StoreProvider = struct {
    ptr: *anyopaque,
    open_fn: *const fn (ctx: *anyopaque, alloc: Allocator, object_id: []const u8) anyerror!ScopedStore,
    /// Optional existence probe. Backends that can answer without
    /// materializing state should implement it; the default keeps existing
    /// initializers valid and reports `ObjectProbeUnsupported`.
    probe_fn: ?*const fn (ctx: *anyopaque, object_id: []const u8) anyerror!bool = null,

    pub const ProbeError = error{ObjectProbeUnsupported};

    pub fn open(self: StoreProvider, alloc: Allocator, object_id: []const u8) !ScopedStore {
        return try self.open_fn(self.ptr, alloc, object_id);
    }

    /// Reports whether the object has durable state or durable retry history.
    ///
    /// Never creates or materializes the object. This is the supported
    /// existence check; `open()` followed by `loadSnapshot()` is not, because
    /// backends such as `MemoryNodeStore` materialize an empty entry on open.
    pub fn probeObject(self: StoreProvider, object_id: []const u8) !bool {
        const probe = self.probe_fn orelse return ProbeError.ObjectProbeUnsupported;
        return try probe(self.ptr, object_id);
    }
};

pub const Route = union(enum) {
    local,
    remote: []const u8,
};

pub const Resolver = struct {
    ptr: *anyopaque,
    resolve_fn: *const fn (ctx: *anyopaque, address: Address) anyerror!Route,

    pub fn resolve(self: Resolver, address: Address) !Route {
        return try self.resolve_fn(self.ptr, address);
    }
};

pub const RemoteRequest = struct {
    destination: []const u8,
    address: Address,
    message_id: u128,
    payload: []const u8,
};

pub const Forwarder = struct {
    ptr: *anyopaque,
    forward_fn: *const fn (ctx: *anyopaque, alloc: Allocator, req: RemoteRequest) anyerror!?OwnedBytes,

    pub fn forward(self: Forwarder, alloc: Allocator, req: RemoteRequest) !?OwnedBytes {
        return try self.forward_fn(self.ptr, alloc, req);
    }
};

const QueuedMessage = struct {
    message_id: u128,
    payload: OwnedBytes,
};

const Activation = struct {
    kind: []u8,
    key: []u8,
    object_id: []u8,
    service: Service,
    store: ScopedStore,
    mailbox: std.ArrayList(QueuedMessage) = .empty,
    running: bool = false,
    next_seq: u64 = 1,
    dirty_ops: u32 = 0,
    last_touched: u64 = 0,

    fn destroy(self: *Activation, alloc: Allocator) void {
        for (self.mailbox.items) |item| {
            item.payload.deinit();
        }
        self.mailbox.deinit(alloc);
        self.store.destroy(alloc);
        self.service.destroy(alloc);
        alloc.free(self.kind);
        alloc.free(self.key);
        alloc.free(self.object_id);
        alloc.destroy(self);
    }
};

pub const Runtime = struct {
    alloc: Allocator,
    store_provider: StoreProvider,
    resolver: ?Resolver,
    forwarder: ?Forwarder,
    snapshot_every: u32,
    tick: u64,
    factories: std.StringHashMap(Factory),
    activations: std.StringHashMap(*Activation),
    /// Process-local quarantine tombstones, keyed by owned object IDs. An
    /// entry means recovery failed deterministically for that actor; requests
    /// return `Error.PoisonedActor` without re-running recovery.
    poisoned: std.StringHashMap(void),

    pub const Config = struct {
        resolver: ?Resolver = null,
        forwarder: ?Forwarder = null,
        snapshot_every: u32 = 128,
    };

    pub const Error = error{
        UnknownKind,
        MissingForwarder,
        ReentrantRequest,
        /// This request's mutation and optional reply were already committed
        /// by `appendOnce()`, but the in-memory `apply()` failed. The
        /// activation has been discarded without snapshotting; retry the same
        /// message ID to recover and receive the stored reply. This error
        /// value is reserved by the runtime: services should not return it
        /// from their own callbacks.
        PostAppendApplyFailed,
        /// Recovery (snapshot decode or mutation replay) failed before this
        /// request reached `decide()`; no mutation was appended. Requests
        /// keep failing without re-running recovery until `retryPoisoned()`
        /// or a process restart succeeds. Poison is process-local and never
        /// persisted.
        PoisonedActor,
    };

    pub fn init(alloc: Allocator, store_provider: StoreProvider, config: Config) Runtime {
        return .{
            .alloc = alloc,
            .store_provider = store_provider,
            .resolver = config.resolver,
            .forwarder = config.forwarder,
            .snapshot_every = config.snapshot_every,
            .tick = 0,
            .factories = std.StringHashMap(Factory).init(alloc),
            .activations = std.StringHashMap(*Activation).init(alloc),
            .poisoned = std.StringHashMap(void).init(alloc),
        };
    }

    pub fn registerFactory(self: *Runtime, kind: []const u8, factory: Factory) !void {
        if (self.factories.getPtr(kind)) |value_ptr| {
            value_ptr.* = factory;
            return;
        }

        const key = try self.alloc.dupe(u8, kind);
        errdefer self.alloc.free(key);
        try self.factories.put(key, factory);
    }

    /// Processes one request for an actor and returns an optional owned
    /// reply. The caller owns the reply and must call `deinit()` on it.
    ///
    /// `decide()` runs for every locally processed attempt. When the current
    /// decision contains a mutation, `message_id` is a per-actor
    /// deduplication key: a new ID records the mutation and optional reply
    /// before `apply()` runs, while an already recorded ID skips the second
    /// append and live `apply()` and returns the first stored optional
    /// reply. Decisions without mutations are neither looked up nor
    /// recorded, even when the same message ID previously recorded a
    /// mutation, so read-style retries may observe newer state. Use one
    /// `(address, message_id)` pair for one logical request with stable
    /// payload bytes; conflicting payload reuse is not detected. Remote
    /// routes delegate these semantics to the configured `Forwarder`.
    pub fn request(self: *Runtime, address: Address, message_id: u128, payload: []const u8) !?OwnedBytes {
        self.tick +%= 1;

        switch (try self.resolveRoute(address)) {
            .local => {},
            .remote => |destination| {
                const forwarder = self.forwarder orelse return Error.MissingForwarder;
                return try forwarder.forward(self.alloc, .{
                    .destination = destination,
                    .address = address,
                    .message_id = message_id,
                    .payload = payload,
                });
            },
        }

        const activation = try self.getOrActivate(address);
        if (activation.running) return Error.ReentrantRequest;

        activation.last_touched = self.tick;
        var payload_copy: ?OwnedBytes = try OwnedBytes.clone(self.alloc, payload);
        errdefer if (payload_copy) |copy| copy.deinit();
        try activation.mailbox.append(self.alloc, .{
            .message_id = message_id,
            .payload = payload_copy.?,
        });
        // The mailbox owns the clone now; processMailbox frees it with the
        // queued item, so the errdefer must not fire past this point.
        payload_copy = null;

        return self.processMailbox(activation) catch |err| {
            if (err == Error.PostAppendApplyFailed) {
                // The mutation is durable but in-memory state is suspect:
                // discard without snapshotting so the next request rebuilds
                // from the snapshot and mutation log.
                self.discardActivation(activation);
            }
            return err;
        };
    }

    /// Equivalent to `request()` with the same deduplication boundary, but
    /// discards and frees any returned reply.
    pub fn tell(self: *Runtime, address: Address, message_id: u128, payload: []const u8) !void {
        if (try self.request(address, message_id, payload)) |reply| {
            reply.deinit();
        }
    }

    pub fn passivate(self: *Runtime, address: Address) !bool {
        const object_id = try allocObjectId(self.alloc, address);
        defer self.alloc.free(object_id);
        return try self.passivateByObjectId(object_id);
    }

    pub fn passivateIdle(self: *Runtime, min_idle_ticks: u64) !void {
        var doomed = std.ArrayList([]const u8).empty;
        defer doomed.deinit(self.alloc);

        var it = self.activations.iterator();
        while (it.next()) |entry| {
            const activation = entry.value_ptr.*;
            if (activation.running) continue;
            if ((self.tick - activation.last_touched) >= min_idle_ticks) {
                try doomed.append(self.alloc, activation.object_id);
            }
        }

        for (doomed.items) |object_id| {
            _ = try self.passivateByObjectId(object_id);
        }
    }

    pub fn shutdown(self: *Runtime) !void {
        var doomed = std.ArrayList([]const u8).empty;
        defer doomed.deinit(self.alloc);

        var it = self.activations.iterator();
        while (it.next()) |entry| {
            try doomed.append(self.alloc, entry.key_ptr.*);
        }

        for (doomed.items) |object_id| {
            _ = try self.passivateByObjectId(object_id);
        }
    }

    /// Clears a poison tombstone and makes exactly one new recovery attempt.
    ///
    /// Returns false when the actor is not poisoned. On success the actor is
    /// active again; when recovery fails again the actor is re-poisoned and
    /// the recovery error is returned. Re-register a corrected factory first
    /// to deploy a fix without restarting the runtime.
    pub fn retryPoisoned(self: *Runtime, address: Address) !bool {
        const object_id = try allocObjectId(self.alloc, address);
        defer self.alloc.free(object_id);

        const removed = self.poisoned.fetchRemove(object_id) orelse return false;
        self.alloc.free(removed.key);

        _ = try self.getOrActivate(address);
        return true;
    }

    pub fn deinit(self: *Runtime) void {
        var activation_it = self.activations.iterator();
        while (activation_it.next()) |entry| {
            entry.value_ptr.*.destroy(self.alloc);
        }
        self.activations.deinit();

        var poisoned_it = self.poisoned.iterator();
        while (poisoned_it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.poisoned.deinit();

        var factory_it = self.factories.iterator();
        while (factory_it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.factories.deinit();

        self.* = undefined;
    }

    fn resolveRoute(self: *Runtime, address: Address) !Route {
        if (self.resolver) |resolver| {
            return try resolver.resolve(address);
        }
        return .local;
    }

    fn getOrActivate(self: *Runtime, address: Address) !*Activation {
        const object_id = try allocObjectId(self.alloc, address);
        var object_id_owned = true;
        defer if (object_id_owned) self.alloc.free(object_id);

        if (self.activations.get(object_id)) |activation| {
            return activation;
        }

        if (self.poisoned.contains(object_id)) return Error.PoisonedActor;

        const activation = try self.allocateActivation(address, object_id);
        // The activation owns object_id from here; exactly one cleanup owner.
        object_id_owned = false;
        var activation_owned = true;
        defer if (activation_owned) activation.destroy(self.alloc);

        try self.recoverActivation(activation);

        try self.activations.put(activation.object_id, activation);
        activation_owned = false;
        return activation;
    }

    /// Creates the service, opens the scoped store, and initializes the
    /// activation struct. Takes ownership of `object_id` only on success; no
    /// fallible operation runs after the ownership transfer, so the caller
    /// owns cleanup through exactly one mechanism (`Activation.destroy`).
    fn allocateActivation(self: *Runtime, address: Address, object_id: []u8) !*Activation {
        const factory = self.factories.get(address.kind) orelse return Error.UnknownKind;

        const service = try factory.create(self.alloc, address);
        errdefer service.destroy(self.alloc);

        const store = try self.store_provider.open(self.alloc, object_id);
        errdefer store.destroy(self.alloc);

        const activation = try self.alloc.create(Activation);
        errdefer self.alloc.destroy(activation);

        const kind_copy = try self.alloc.dupe(u8, address.kind);
        errdefer self.alloc.free(kind_copy);

        const key_copy = try self.alloc.dupe(u8, address.key);

        activation.* = .{
            .kind = kind_copy,
            .key = key_copy,
            .object_id = object_id,
            .service = service,
            .store = store,
            .mailbox = .empty,
            .running = false,
            .next_seq = 1,
            .dirty_ops = 0,
            .last_touched = self.tick,
        };
        return activation;
    }

    /// Rebuilds in-memory state from the scoped store.
    ///
    /// A *service* callback failure (snapshot decode or replay `apply()`)
    /// quarantines the actor and returns `Error.PoisonedActor`: durable data
    /// exists that the current code cannot load, and retrying every request
    /// would replay the same deterministic failure. *Storage* errors
    /// propagate unchanged and are transient: the next request retries
    /// recovery from scratch.
    fn recoverActivation(self: *Runtime, activation: *Activation) !void {
        if (try activation.store.loadSnapshot(self.alloc)) |snapshot| {
            defer snapshot.bytes.deinit();
            activation.service.loadSnapshot(snapshot.bytes.bytes) catch {
                self.markPoisoned(activation.object_id);
                return Error.PoisonedActor;
            };
            activation.next_seq = snapshot.last_seq + 1;
        }

        var replay_ctx = ReplayContext{ .activation = activation };
        activation.store.replayAfter(activation.next_seq - 1, &replay_ctx, ReplayContext.call) catch |err| {
            if (replay_ctx.service_apply_failed) {
                self.markPoisoned(activation.object_id);
                return Error.PoisonedActor;
            }
            return err;
        };
    }

    /// Best-effort tombstone insertion. On allocation failure the tombstone
    /// is skipped: the actor degrades to retrying recovery on each request
    /// instead of failing fast, which is safe.
    fn markPoisoned(self: *Runtime, object_id: []const u8) void {
        if (self.poisoned.contains(object_id)) return;
        const key = self.alloc.dupe(u8, object_id) catch return;
        self.poisoned.put(key, {}) catch self.alloc.free(key);
    }

    /// Destroys an activation without snapshotting it. Used when in-memory
    /// state can no longer be trusted (post-append `apply()` failure): a
    /// snapshot taken now could capture partial effects of the failed event
    /// under an earlier sequence label. The next request reconstructs the
    /// actor from its snapshot and mutation log.
    fn discardActivation(self: *Runtime, activation: *Activation) void {
        if (self.activations.fetchRemove(activation.object_id)) |removed| {
            removed.value.destroy(self.alloc);
        }
    }

    fn processMailbox(self: *Runtime, activation: *Activation) !?OwnedBytes {
        activation.running = true;
        defer activation.running = false;

        var first_reply: ?OwnedBytes = null;
        errdefer if (first_reply) |reply| reply.deinit();

        while (activation.mailbox.items.len > 0) {
            var item = activation.mailbox.orderedRemove(0);
            defer item.payload.deinit();

            if (try self.processOne(activation, item)) |reply| {
                if (first_reply == null) {
                    first_reply = reply;
                } else {
                    reply.deinit();
                }
            }
        }

        return first_reply;
    }

    fn processOne(self: *Runtime, activation: *Activation, item: QueuedMessage) !?OwnedBytes {
        var decision = try activation.service.decide(self.alloc, item.payload.bytes);
        defer decision.deinit();

        var final_reply = decision.reply;
        decision.reply = null;
        errdefer if (final_reply) |reply| reply.deinit();

        if (decision.mutation) |mutation| {
            const append_result = try activation.store.appendOnce(self.alloc, .{
                .message_id = item.message_id,
                .seq = activation.next_seq,
                .mutation = mutation.bytes,
                .reply = if (final_reply) |reply| reply.bytes else null,
            });

            switch (append_result) {
                .inserted => {
                    // The mutation and reply are already durable. A failed
                    // apply() leaves in-memory state unknown (old, partial,
                    // or fully mutated), so the caller must discard this
                    // activation rather than let it serve reads, snapshot,
                    // or advance its sequence.
                    activation.service.apply(mutation.bytes) catch {
                        return Error.PostAppendApplyFailed;
                    };
                    activation.next_seq += 1;
                    activation.dirty_ops += 1;
                },
                .duplicate => |stored_reply| {
                    if (final_reply) |reply| reply.deinit();
                    final_reply = stored_reply;
                },
            }
        }

        if (self.snapshot_every > 0 and activation.dirty_ops >= self.snapshot_every) {
            try self.snapshotActivation(activation);
        }

        return final_reply;
    }

    /// Writes a snapshot at the last applied sequence and compacts the log.
    ///
    /// A failure here after a successful `apply()` is a committed-command
    /// maintenance error, distinct from `Error.PostAppendApplyFailed`: the
    /// command is durable and in-memory state is consistent, so the
    /// activation stays mapped and usable and snapshotting is retried later.
    fn snapshotActivation(self: *Runtime, activation: *Activation) !void {
        const snapshot = try activation.service.makeSnapshot(self.alloc);
        defer snapshot.deinit();

        try activation.store.writeSnapshot(activation.next_seq - 1, snapshot.bytes);
        try activation.store.compactBefore(activation.next_seq);
        activation.dirty_ops = 0;
    }

    fn passivateByObjectId(self: *Runtime, object_id: []const u8) !bool {
        const activation = self.activations.get(object_id) orelse return false;
        if (activation.running) return Error.ReentrantRequest;

        // Snapshot before unmapping: a snapshot failure must leave the
        // activation reachable and usable, not removed-but-undestroyed.
        if (activation.dirty_ops > 0) {
            try self.snapshotActivation(activation);
        }

        const removed = self.activations.fetchRemove(object_id).?;
        removed.value.destroy(self.alloc);
        return true;
    }
};

const ReplayContext = struct {
    activation: *Activation,
    /// Distinguishes a service `apply()` rejection (deterministic; poisons
    /// the actor) from a storage error that happens to carry the same Zig
    /// error name (transient; recovery is retried on the next request).
    service_apply_failed: bool = false,

    fn call(ctx: *anyopaque, seq: u64, mutation: []const u8) anyerror!void {
        const self: *ReplayContext = @ptrCast(@alignCast(ctx));
        self.activation.service.apply(mutation) catch |err| {
            self.service_apply_failed = true;
            return err;
        };
        if (self.activation.next_seq <= seq) {
            self.activation.next_seq = seq + 1;
        }
    }
};
