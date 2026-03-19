const std = @import("std");
const durable = @import("durable_actor");

const Allocator = std.mem.Allocator;

pub const StoreCounters = struct {
    activations: u64 = 0,
    snapshot_loads: u64 = 0,
    snapshot_hits: u64 = 0,
    replayed_mutations: u64 = 0,
    snapshot_writes: u64 = 0,
};

pub const Collector = struct {
    counters: StoreCounters = .{},

    pub fn reset(self: *Collector) void {
        self.counters = .{};
    }

    pub fn snapshot(self: *const Collector) StoreCounters {
        return self.counters;
    }
};

pub const Provider = struct {
    alloc: Allocator,
    inner: durable.StoreProvider,
    collector: *Collector,

    pub fn init(alloc: Allocator, inner: durable.StoreProvider, collector: *Collector) Provider {
        return .{
            .alloc = alloc,
            .inner = inner,
            .collector = collector,
        };
    }

    pub fn asStoreProvider(self: *Provider) durable.StoreProvider {
        return .{
            .ptr = self,
            .open_fn = openErased,
        };
    }

    fn openErased(ctx: *anyopaque, alloc: Allocator, object_id: []const u8) anyerror!durable.ScopedStore {
        const self: *Provider = @ptrCast(@alignCast(ctx));
        const scope = try alloc.create(InstrumentedScope);
        errdefer alloc.destroy(scope);

        scope.* = .{
            .alloc = alloc,
            .inner = try self.inner.open(alloc, object_id),
            .collector = self.collector,
        };
        self.collector.counters.activations += 1;
        return durable.ScopedStore.from(InstrumentedScope, scope);
    }
};

const InstrumentedScope = struct {
    alloc: Allocator,
    inner: durable.ScopedStore,
    collector: *Collector,

    pub fn destroy(self: *InstrumentedScope, alloc: Allocator) void {
        self.inner.destroy(alloc);
        alloc.destroy(self);
    }

    pub fn loadSnapshot(self: *InstrumentedScope, alloc: Allocator) !?durable.ScopedStore.Snapshot {
        self.collector.counters.snapshot_loads += 1;
        const snapshot = try self.inner.loadSnapshot(alloc);
        if (snapshot != null) self.collector.counters.snapshot_hits += 1;
        return snapshot;
    }

    pub fn replayAfter(self: *InstrumentedScope, after_seq: u64, replay_ctx: *anyopaque, replay_fn: durable.ScopedStore.ReplayFn) !void {
        var wrapped = ReplayWrapper{
            .collector = self.collector,
            .replay_ctx = replay_ctx,
            .replay_fn = replay_fn,
        };
        try self.inner.replayAfter(after_seq, &wrapped, ReplayWrapper.call);
    }

    pub fn appendOnce(self: *InstrumentedScope, alloc: Allocator, intent: durable.ScopedStore.AppendIntent) !durable.ScopedStore.AppendResult {
        return try self.inner.appendOnce(alloc, intent);
    }

    pub fn writeSnapshot(self: *InstrumentedScope, at_seq: u64, bytes: []const u8) !void {
        self.collector.counters.snapshot_writes += 1;
        try self.inner.writeSnapshot(at_seq, bytes);
    }

    pub fn compactBefore(self: *InstrumentedScope, first_live_seq: u64) !void {
        try self.inner.compactBefore(first_live_seq);
    }
};

const ReplayWrapper = struct {
    collector: *Collector,
    replay_ctx: *anyopaque,
    replay_fn: durable.ScopedStore.ReplayFn,

    fn call(ctx: *anyopaque, seq: u64, mutation: []const u8) anyerror!void {
        const self: *ReplayWrapper = @ptrCast(@alignCast(ctx));
        self.collector.counters.replayed_mutations += 1;
        try self.replay_fn(self.replay_ctx, seq, mutation);
    }
};
