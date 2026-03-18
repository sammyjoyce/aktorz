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

pub const Decision = struct {
    mutation: ?OwnedBytes = null,
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

    pub fn appendOnce(self: ScopedStore, alloc: Allocator, intent: AppendIntent) !AppendResult {
        return try self.vtable.append_once(self.ptr, alloc, intent);
    }

    pub fn writeSnapshot(self: ScopedStore, at_seq: u64, bytes: []const u8) !void {
        try self.vtable.write_snapshot(self.ptr, at_seq, bytes);
    }

    pub fn compactBefore(self: ScopedStore, first_live_seq: u64) !void {
        try self.vtable.compact_before(self.ptr, first_live_seq);
    }
};

pub const StoreProvider = struct {
    ptr: *anyopaque,
    open_fn: *const fn (ctx: *anyopaque, alloc: Allocator, object_id: []const u8) anyerror!ScopedStore,

    pub fn open(self: StoreProvider, alloc: Allocator, object_id: []const u8) !ScopedStore {
        return try self.open_fn(self.ptr, alloc, object_id);
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

    pub const Config = struct {
        resolver: ?Resolver = null,
        forwarder: ?Forwarder = null,
        snapshot_every: u32 = 128,
    };

    pub const Error = error{
        UnknownKind,
        MissingForwarder,
        ReentrantRequest,
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
        try activation.mailbox.append(self.alloc, .{
            .message_id = message_id,
            .payload = try OwnedBytes.clone(self.alloc, payload),
        });

        return try self.processMailbox(activation);
    }

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

    pub fn deinit(self: *Runtime) void {
        var activation_it = self.activations.iterator();
        while (activation_it.next()) |entry| {
            entry.value_ptr.*.destroy(self.alloc);
        }
        self.activations.deinit();

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
        errdefer self.alloc.free(object_id);

        if (self.activations.get(object_id)) |activation| {
            self.alloc.free(object_id);
            return activation;
        }

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
        errdefer self.alloc.free(key_copy);

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
        errdefer activation.destroy(self.alloc);

        if (try activation.store.loadSnapshot(self.alloc)) |snapshot| {
            defer snapshot.bytes.deinit();
            try activation.service.loadSnapshot(snapshot.bytes.bytes);
            activation.next_seq = snapshot.last_seq + 1;
        }

        var replay_ctx = ReplayContext{ .activation = activation };
        try activation.store.replayAfter(activation.next_seq - 1, &replay_ctx, ReplayContext.call);

        try self.activations.put(activation.object_id, activation);
        return activation;
    }

    fn processMailbox(self: *Runtime, activation: *Activation) !?OwnedBytes {
        activation.running = true;
        defer activation.running = false;

        var first_reply: ?OwnedBytes = null;

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

        if (decision.mutation) |mutation| {
            const append_result = try activation.store.appendOnce(self.alloc, .{
                .message_id = item.message_id,
                .seq = activation.next_seq,
                .mutation = mutation.bytes,
                .reply = if (final_reply) |reply| reply.bytes else null,
            });

            switch (append_result) {
                .inserted => {
                    try activation.service.apply(mutation.bytes);
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

    fn snapshotActivation(self: *Runtime, activation: *Activation) !void {
        const snapshot = try activation.service.makeSnapshot(self.alloc);
        defer snapshot.deinit();

        try activation.store.writeSnapshot(activation.next_seq - 1, snapshot.bytes);
        try activation.store.compactBefore(activation.next_seq);
        activation.dirty_ops = 0;
    }

    fn passivateByObjectId(self: *Runtime, object_id: []const u8) !bool {
        if (self.activations.get(object_id)) |activation| {
            if (activation.running) return Error.ReentrantRequest;
        }

        if (self.activations.fetchRemove(object_id)) |kv| {
            const activation = kv.value;
            if (activation.dirty_ops > 0) {
                try self.snapshotActivation(activation);
            }
            activation.destroy(self.alloc);
            return true;
        }

        return false;
    }
};

const ReplayContext = struct {
    activation: *Activation,

    fn call(ctx: *anyopaque, seq: u64, mutation: []const u8) anyerror!void {
        const self: *ReplayContext = @ptrCast(@alignCast(ctx));
        try self.activation.service.apply(mutation);
        if (self.activation.next_seq <= seq) {
            self.activation.next_seq = seq + 1;
        }
    }
};
