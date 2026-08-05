//! Runtime lifecycle and deduplication-boundary tests.
//!
//! These tests pin the exact guarantee documented in docs/deduplication.md:
//! per-actor mutating-decision deduplication with stored-reply return. They
//! use a deliberately non-idempotent counter fixture (a re-applied duplicate
//! or a recomputed reply changes the observable result), unlike a constant-
//! reply `set` service which passes even when deduplication is broken.

const std = @import("std");
const core = @import("core.zig");
const MemoryNodeStore = @import("memory_store.zig").MemoryNodeStore;

const Allocator = std.mem.Allocator;

/// Test-file-global control block for the counter fixture. Zig tests in one
/// binary run sequentially, and `Factory.from` accepts no user context, so a
/// file-scoped global is the simplest way to observe and fault-inject
/// callbacks. Reset it at the start of every test.
const Control = struct {
    create_calls: u32 = 0,
    decide_calls: u32 = 0,
    apply_calls: u32 = 0,
    load_snapshot_calls: u32 = 0,
    make_snapshot_calls: u32 = 0,
    /// Fails the next N `apply()` invocations (live and replay alike).
    fail_apply_remaining: u32 = 0,
    /// Fails every service `loadSnapshot()` while set.
    fail_load_snapshot: bool = false,
};

var control: Control = .{};

fn resetControl() void {
    control = .{};
}

const CounterService = struct {
    alloc: Allocator,
    value: u64 = 0,

    pub fn create(alloc: Allocator, address: core.Address) !*CounterService {
        _ = address;
        control.create_calls += 1;
        const self = try alloc.create(CounterService);
        self.* = .{ .alloc = alloc };
        return self;
    }

    pub fn destroy(self: *CounterService, alloc: Allocator) void {
        alloc.destroy(self);
    }

    pub fn loadSnapshot(self: *CounterService, bytes: []const u8) !void {
        control.load_snapshot_calls += 1;
        if (control.fail_load_snapshot) return error.SnapshotDecodeFailed;
        self.value = try std.fmt.parseInt(u64, bytes, 10);
    }

    pub fn makeSnapshot(self: *CounterService, alloc: Allocator) !core.OwnedBytes {
        control.make_snapshot_calls += 1;
        return formatValue(alloc, self.value);
    }

    pub fn decide(self: *CounterService, alloc: Allocator, message: []const u8) !core.Decision {
        control.decide_calls += 1;
        if (std.mem.eql(u8, message, "get")) {
            return .{ .reply = try formatValue(alloc, self.value) };
        }
        if (std.mem.eql(u8, message, "inc")) {
            // The reply is the post-increment value computed *before* apply,
            // so a recomputed retry reply differs from the stored one.
            var mutation = try core.OwnedBytes.clone(alloc, "inc");
            errdefer mutation.deinit();
            const reply = try formatValue(alloc, self.value + 1);
            return .{ .mutation = mutation, .reply = reply };
        }
        if (std.mem.eql(u8, message, "inc-no-reply")) {
            return .{ .mutation = try core.OwnedBytes.clone(alloc, "inc") };
        }
        if (std.mem.startsWith(u8, message, "set|")) {
            var mutation = try core.OwnedBytes.clone(alloc, message);
            errdefer mutation.deinit();
            const bytes = try std.fmt.allocPrint(alloc, "set:{s}", .{message[4..]});
            return .{ .mutation = mutation, .reply = core.OwnedBytes.fromOwned(alloc, bytes) };
        }
        if (std.mem.eql(u8, message, "ensure1")) {
            // State-dependent command: once the actor is already at 1, the
            // retry decides no mutation and bypasses the dedup ledger.
            if (self.value == 1) {
                return .{ .reply = try core.OwnedBytes.clone(alloc, "already") };
            }
            var mutation = try core.OwnedBytes.clone(alloc, "set|1");
            errdefer mutation.deinit();
            const reply = try core.OwnedBytes.clone(alloc, "done");
            return .{ .mutation = mutation, .reply = reply };
        }
        return error.UnknownCommand;
    }

    pub fn apply(self: *CounterService, mutation: []const u8) !void {
        control.apply_calls += 1;
        if (control.fail_apply_remaining > 0) {
            control.fail_apply_remaining -= 1;
            return error.ApplyFailed;
        }
        if (std.mem.eql(u8, mutation, "inc")) {
            self.value += 1;
            return;
        }
        if (std.mem.startsWith(u8, mutation, "set|")) {
            self.value = try std.fmt.parseInt(u64, mutation[4..], 10);
            return;
        }
        return error.UnknownMutation;
    }

    fn formatValue(alloc: Allocator, value: u64) !core.OwnedBytes {
        const bytes = try std.fmt.allocPrint(alloc, "{d}", .{value});
        return core.OwnedBytes.fromOwned(alloc, bytes);
    }
};

/// Fault-injecting store wrapper used to distinguish *storage* failures
/// (transient; must not poison) from *service* failures (deterministic;
/// poison), and to exercise snapshot-failure paths.
const FlakyControl = struct {
    fail_replay_remaining: u32 = 0,
    fail_write_snapshot_remaining: u32 = 0,
};

var flaky_control: FlakyControl = .{};

const FlakyScopedStore = struct {
    inner: core.ScopedStore,

    pub fn destroy(self: *FlakyScopedStore, alloc: Allocator) void {
        self.inner.destroy(alloc);
        alloc.destroy(self);
    }

    pub fn loadSnapshot(self: *FlakyScopedStore, alloc: Allocator) !?core.ScopedStore.Snapshot {
        return try self.inner.loadSnapshot(alloc);
    }

    pub fn replayAfter(self: *FlakyScopedStore, after_seq: u64, replay_ctx: *anyopaque, replay_fn: core.ScopedStore.ReplayFn) !void {
        if (flaky_control.fail_replay_remaining > 0) {
            flaky_control.fail_replay_remaining -= 1;
            return error.StoreUnavailable;
        }
        try self.inner.replayAfter(after_seq, replay_ctx, replay_fn);
    }

    pub fn appendOnce(self: *FlakyScopedStore, alloc: Allocator, intent: core.ScopedStore.AppendIntent) !core.ScopedStore.AppendResult {
        return try self.inner.appendOnce(alloc, intent);
    }

    pub fn writeSnapshot(self: *FlakyScopedStore, at_seq: u64, bytes: []const u8) !void {
        if (flaky_control.fail_write_snapshot_remaining > 0) {
            flaky_control.fail_write_snapshot_remaining -= 1;
            return error.SnapshotWriteFailed;
        }
        try self.inner.writeSnapshot(at_seq, bytes);
    }

    pub fn compactBefore(self: *FlakyScopedStore, first_live_seq: u64) !void {
        try self.inner.compactBefore(first_live_seq);
    }
};

const FlakyStoreProvider = struct {
    inner: core.StoreProvider,

    fn asStoreProvider(self: *FlakyStoreProvider) core.StoreProvider {
        return .{
            .ptr = self,
            .open_fn = openErased,
        };
    }

    fn openErased(ctx: *anyopaque, alloc: Allocator, object_id: []const u8) anyerror!core.ScopedStore {
        const self: *FlakyStoreProvider = @ptrCast(@alignCast(ctx));
        const inner_scope = try self.inner.open(alloc, object_id);
        errdefer inner_scope.destroy(alloc);

        const scope = try alloc.create(FlakyScopedStore);
        scope.* = .{ .inner = inner_scope };
        return core.ScopedStore.from(FlakyScopedStore, scope);
    }
};

const counter_addr = core.Address{ .kind = "counter", .key = "a" };

fn registerCounter(runtime: *core.Runtime) !void {
    try runtime.registerFactory("counter", core.Factory.from(CounterService, CounterService.create));
}

fn expectReply(runtime: *core.Runtime, addr: core.Address, message_id: u128, payload: []const u8, expected: []const u8) !void {
    const reply = (try runtime.request(addr, message_id, payload)) orelse return error.ExpectedReply;
    defer reply.deinit();
    try std.testing.expectEqualStrings(expected, reply.bytes);
}

test "mutating retry returns stored reply and applies once" {
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{});
    defer runtime.deinit();
    try registerCounter(&runtime);

    try expectReply(&runtime, counter_addr, 100, "inc", "1");
    // The retry re-runs decide() (which recomputes "2"), but the stored
    // reply from the first append wins and apply() does not run again.
    try expectReply(&runtime, counter_addr, 100, "inc", "1");
    try expectReply(&runtime, counter_addr, 900, "get", "1");

    try std.testing.expectEqual(@as(u32, 3), control.decide_calls);
    try std.testing.expectEqual(@as(u32, 1), control.apply_calls);
}

test "read-only retry re-executes decide and can observe newer state" {
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{});
    defer runtime.deinit();
    try registerCounter(&runtime);

    try expectReply(&runtime, counter_addr, 200, "get", "0");
    try expectReply(&runtime, counter_addr, 201, "inc", "1");
    // Reads are not recorded: the same ID re-executes decide() and sees the
    // newer state. Message IDs do not memoize reads.
    try expectReply(&runtime, counter_addr, 200, "get", "1");
}

test "same message id with different mutating payload returns first stored reply" {
    // Documented client bug: conflicting payload reuse is not detected. If
    // strict payload binding ever ships, this test should expect a
    // MessageIdConflict-style error instead.
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{});
    defer runtime.deinit();
    try registerCounter(&runtime);

    try expectReply(&runtime, counter_addr, 300, "set|5", "set:5");
    try expectReply(&runtime, counter_addr, 300, "set|9", "set:5");
    try expectReply(&runtime, counter_addr, 901, "get", "5");
}

test "recorded message id is bypassed when the retry decides no mutation" {
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{});
    defer runtime.deinit();
    try registerCounter(&runtime);

    try expectReply(&runtime, counter_addr, 400, "ensure1", "done");
    // The retry sees the actor already at 1, decides no mutation, never
    // consults the ledger, and returns the freshly computed reply instead of
    // the stored "done". This is the exact deduplication boundary.
    try expectReply(&runtime, counter_addr, 400, "ensure1", "already");
    // Reusing the recorded ID with a read payload also bypasses the ledger:
    // the fresh read result wins over the stored "done".
    try expectReply(&runtime, counter_addr, 400, "get", "1");
}

test "same message id is independent across actors" {
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{});
    defer runtime.deinit();
    try registerCounter(&runtime);

    const addr_b = core.Address{ .kind = "counter", .key = "b" };
    try expectReply(&runtime, counter_addr, 500, "inc", "1");
    try expectReply(&runtime, addr_b, 500, "inc", "1");
    try expectReply(&runtime, counter_addr, 902, "get", "1");
    try expectReply(&runtime, addr_b, 903, "get", "1");
}

test "duplicate mutation without reply returns null and applies once" {
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{});
    defer runtime.deinit();
    try registerCounter(&runtime);

    try std.testing.expect((try runtime.request(counter_addr, 600, "inc-no-reply")) == null);
    try std.testing.expect((try runtime.request(counter_addr, 600, "inc-no-reply")) == null);
    try expectReply(&runtime, counter_addr, 904, "get", "1");
    try std.testing.expectEqual(@as(u32, 1), control.apply_calls);
}

test "dedup survives passivation after wal compaction" {
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 1,
    });
    defer runtime.deinit();
    try registerCounter(&runtime);

    try expectReply(&runtime, counter_addr, 700, "inc", "1");
    try std.testing.expect(try runtime.passivate(counter_addr));
    // The mutation log was compacted behind the snapshot, but the seen
    // ledger survives both compaction and passivation.
    try expectReply(&runtime, counter_addr, 700, "inc", "1");
    try expectReply(&runtime, counter_addr, 905, "get", "1");
    try std.testing.expectEqual(@as(u32, 1), control.apply_calls);
}

test "post-append apply failure discards activation and rebuilds" {
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{});
    defer runtime.deinit();
    try registerCounter(&runtime);

    control.fail_apply_remaining = 1;
    try std.testing.expectError(
        core.Runtime.Error.PostAppendApplyFailed,
        runtime.request(counter_addr, 800, "inc"),
    );

    // The mutation and reply are durable; the next request rebuilds from the
    // log and replays it exactly once.
    try expectReply(&runtime, counter_addr, 801, "get", "1");
    try std.testing.expectEqual(@as(u32, 2), control.create_calls);
    try std.testing.expectEqual(@as(u32, 2), control.apply_calls);

    // The same-ID retry returns the stored reply against converged state.
    try expectReply(&runtime, counter_addr, 800, "inc", "1");
    // A later mutation uses the next sequence without a SequenceConflict.
    try expectReply(&runtime, counter_addr, 802, "inc", "2");
}

test "post-append apply failure never snapshots suspect state" {
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 100,
    });
    defer runtime.deinit();
    try registerCounter(&runtime);

    try expectReply(&runtime, counter_addr, 1, "inc", "1");
    control.fail_apply_remaining = 1;
    try std.testing.expectError(
        core.Runtime.Error.PostAppendApplyFailed,
        runtime.request(counter_addr, 2, "inc"),
    );

    // The dirty activation was discarded, not passivated: nothing remains to
    // snapshot, so the suspect in-memory state can never be captured under
    // an earlier sequence label.
    try std.testing.expect(!(try runtime.passivate(counter_addr)));
    try std.testing.expectEqual(@as(u32, 0), control.make_snapshot_calls);

    // Recovery replays both durable mutations.
    try expectReply(&runtime, counter_addr, 3, "get", "2");
}

test "deterministic replay failure poisons actor without repeated recovery" {
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 100,
    });
    defer runtime.deinit();
    try registerCounter(&runtime);

    try expectReply(&runtime, counter_addr, 910, "inc", "1");
    control.fail_apply_remaining = 100;
    try std.testing.expectError(
        core.Runtime.Error.PostAppendApplyFailed,
        runtime.request(counter_addr, 911, "inc"),
    );

    // The next request makes exactly one recovery attempt, hits the same
    // deterministic replay failure, and quarantines the actor.
    try std.testing.expectError(
        core.Runtime.Error.PoisonedActor,
        runtime.request(counter_addr, 912, "get"),
    );
    const creates_after_poison = control.create_calls;

    // Poisoned actors fail fast: no factory create, snapshot load, or replay
    // reruns on later requests.
    try std.testing.expectError(
        core.Runtime.Error.PoisonedActor,
        runtime.request(counter_addr, 913, "get"),
    );
    try std.testing.expectError(
        core.Runtime.Error.PoisonedActor,
        runtime.request(counter_addr, 914, "get"),
    );
    try std.testing.expectEqual(creates_after_poison, control.create_calls);

    // Passivation reports false and does not silently clear the quarantine.
    try std.testing.expect(!(try runtime.passivate(counter_addr)));
    try std.testing.expectError(
        core.Runtime.Error.PoisonedActor,
        runtime.request(counter_addr, 915, "get"),
    );

    // An explicit retry that fails re-poisons the actor.
    try std.testing.expectError(
        core.Runtime.Error.PoisonedActor,
        runtime.retryPoisoned(counter_addr),
    );
    try std.testing.expectEqual(creates_after_poison + 1, control.create_calls);

    // After the (simulated) code fix, one explicit retry recovers the actor.
    control.fail_apply_remaining = 0;
    try std.testing.expect(try runtime.retryPoisoned(counter_addr));
    try expectReply(&runtime, counter_addr, 916, "get", "2");
    // A healthy actor is not poisoned; retryPoisoned reports false.
    try std.testing.expect(!(try runtime.retryPoisoned(counter_addr)));
}

test "snapshot decode failure quarantines actor until explicit retry" {
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 1,
    });
    defer runtime.deinit();
    try registerCounter(&runtime);

    try expectReply(&runtime, counter_addr, 1, "inc", "1");
    try std.testing.expect(try runtime.passivate(counter_addr));

    control.fail_load_snapshot = true;
    try std.testing.expectError(
        core.Runtime.Error.PoisonedActor,
        runtime.request(counter_addr, 2, "get"),
    );
    const creates_after_poison = control.create_calls;
    try std.testing.expectError(
        core.Runtime.Error.PoisonedActor,
        runtime.request(counter_addr, 3, "get"),
    );
    try std.testing.expectEqual(creates_after_poison, control.create_calls);

    control.fail_load_snapshot = false;
    try std.testing.expect(try runtime.retryPoisoned(counter_addr));
    try expectReply(&runtime, counter_addr, 4, "get", "1");
}

test "storage replay error is transient and does not poison" {
    resetControl();
    flaky_control = .{};
    var inner = MemoryNodeStore.init(std.testing.allocator);
    defer inner.deinit();
    var flaky = FlakyStoreProvider{ .inner = inner.asStoreProvider() };
    var runtime = core.Runtime.init(std.testing.allocator, flaky.asStoreProvider(), .{
        .snapshot_every = 100,
    });
    defer runtime.deinit();
    try registerCounter(&runtime);

    try expectReply(&runtime, counter_addr, 1, "inc", "1");
    try std.testing.expect(try runtime.passivate(counter_addr));

    flaky_control.fail_replay_remaining = 1;
    try std.testing.expectError(error.StoreUnavailable, runtime.request(counter_addr, 2, "get"));

    // A storage failure is retried on the next request, never quarantined.
    try expectReply(&runtime, counter_addr, 3, "get", "1");
    try std.testing.expect(!(try runtime.retryPoisoned(counter_addr)));
}

test "snapshot failure during passivation keeps activation usable" {
    resetControl();
    flaky_control = .{};
    var inner = MemoryNodeStore.init(std.testing.allocator);
    defer inner.deinit();
    var flaky = FlakyStoreProvider{ .inner = inner.asStoreProvider() };
    var runtime = core.Runtime.init(std.testing.allocator, flaky.asStoreProvider(), .{
        .snapshot_every = 100,
    });
    defer runtime.deinit();
    try registerCounter(&runtime);

    try expectReply(&runtime, counter_addr, 1, "inc", "1");

    flaky_control.fail_write_snapshot_remaining = 1;
    try std.testing.expectError(error.SnapshotWriteFailed, runtime.passivate(counter_addr));

    // The activation stays mapped, reachable, and consistent.
    try expectReply(&runtime, counter_addr, 2, "get", "1");
    try std.testing.expect(try runtime.passivate(counter_addr));
    try expectReply(&runtime, counter_addr, 3, "get", "1");
}

test "reply is released when a periodic snapshot fails after apply" {
    resetControl();
    flaky_control = .{};
    var inner = MemoryNodeStore.init(std.testing.allocator);
    defer inner.deinit();
    var flaky = FlakyStoreProvider{ .inner = inner.asStoreProvider() };
    var runtime = core.Runtime.init(std.testing.allocator, flaky.asStoreProvider(), .{
        .snapshot_every = 1,
    });
    defer runtime.deinit();
    try registerCounter(&runtime);

    // Snapshot failure after a successful apply is a committed-command
    // maintenance error: the reply is freed (std.testing.allocator would
    // fail this test on a leak), the activation stays usable, and the retry
    // returns the stored reply.
    flaky_control.fail_write_snapshot_remaining = 1;
    try std.testing.expectError(error.SnapshotWriteFailed, runtime.request(counter_addr, 1, "inc"));
    try expectReply(&runtime, counter_addr, 2, "get", "1");
    try expectReply(&runtime, counter_addr, 1, "inc", "1");
}

test "activation and request survive allocation failure at every point" {
    // Sweeps an injected OutOfMemory across every allocation in the
    // activation + request path (factory create, store open, activation
    // struct, kind/key copies, activations.put, decision buffers, mailbox
    // clone, reply handling). The single-owner cleanup in getOrActivate must
    // free everything exactly once at each failure point;
    // std.testing.allocator fails this test on any leak or double free.
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();

    var fail_index: usize = 0;
    var succeeded = false;
    while (fail_index < 256) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var runtime = core.Runtime.init(failing.allocator(), store.asStoreProvider(), .{});
        defer runtime.deinit();

        registerCounter(&runtime) catch continue;
        const reply = runtime.request(counter_addr, 5000 + @as(u128, fail_index), "inc") catch continue;
        if (reply) |owned| owned.deinit();
        succeeded = true;
        break;
    }
    try std.testing.expect(succeeded);
}

test "memory store rejects duplicate and regressing sequences" {
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    const provider = store.asStoreProvider();

    const scope = try provider.open(std.testing.allocator, "7:counter:seq");
    defer scope.destroy(std.testing.allocator);

    _ = try scope.appendOnce(std.testing.allocator, .{ .message_id = 1, .seq = 1, .mutation = "inc" });
    try std.testing.expectError(error.SequenceConflict, scope.appendOnce(std.testing.allocator, .{
        .message_id = 2,
        .seq = 1,
        .mutation = "inc",
    }));
    try std.testing.expectError(error.SequenceConflict, scope.appendOnce(std.testing.allocator, .{
        .message_id = 3,
        .seq = 0,
        .mutation = "inc",
    }));
    _ = try scope.appendOnce(std.testing.allocator, .{ .message_id = 4, .seq = 2, .mutation = "inc" });
}

test "probe reports absence without materializing and presence after writes" {
    resetControl();
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    const provider = store.asStoreProvider();

    try std.testing.expect(!(try provider.probeObject("7:counter:x")));

    // openScoped materializes a phantom entry; the probe still reports
    // absent because the entry has no durable state or retry history.
    const scope = try provider.open(std.testing.allocator, "7:counter:x");
    scope.destroy(std.testing.allocator);
    try std.testing.expect(!(try provider.probeObject("7:counter:x")));

    var runtime = core.Runtime.init(std.testing.allocator, provider, .{});
    defer runtime.deinit();
    try registerCounter(&runtime);
    const addr = core.Address{ .kind = "counter", .key = "x" };

    // A read-only request activates the actor but records nothing durable.
    try expectReply(&runtime, addr, 1, "get", "0");
    try std.testing.expect(!(try provider.probeObject("7:counter:x")));

    try expectReply(&runtime, addr, 2, "inc", "1");
    try std.testing.expect(try provider.probeObject("7:counter:x"));
}

test "probe is unsupported for providers without probe_fn" {
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();
    var provider = store.asStoreProvider();
    provider.probe_fn = null;

    try std.testing.expectError(error.ObjectProbeUnsupported, provider.probeObject("7:counter:x"));
}
