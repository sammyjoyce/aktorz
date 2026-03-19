const std = @import("std");
const durable = @import("durable_actor");
const durable_sqlite = @import("durable_actor_sqlite");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Scenario = enum {
    memory_hot,
    memory_cold,
    sqlite_hot,
    sqlite_cold,
};

const Mode = enum {
    hot,
    cold,
};

pub const Config = struct {
    scenario: Scenario,
    ops: u64,
    sqlite_path: ?[]const u8 = null,
    snapshot_every: u32 = 128,
};

pub const Result = struct {
    scenario: Scenario,
    ops: u64,
    elapsed_ns: u64,
    final_value: u64,

    pub fn nsPerOp(self: Result) f64 {
        return @as(f64, @floatFromInt(self.elapsed_ns)) / @as(f64, @floatFromInt(self.ops));
    }

    pub fn opsPerSecond(self: Result) f64 {
        return (@as(f64, @floatFromInt(self.ops)) * @as(f64, std.time.ns_per_s)) /
            @as(f64, @floatFromInt(self.elapsed_ns));
    }
};

const CounterService = struct {
    alloc: Allocator,
    value: u64,

    pub fn create(alloc: Allocator, address: durable.Address) !*CounterService {
        _ = address;
        const self = try alloc.create(CounterService);
        self.* = .{ .alloc = alloc, .value = 0 };
        return self;
    }

    pub fn destroy(self: *CounterService, alloc: Allocator) void {
        _ = self.alloc;
        alloc.destroy(self);
    }

    pub fn loadSnapshot(self: *CounterService, bytes: []const u8) !void {
        if (bytes.len == 0) {
            self.value = 0;
            return;
        }

        self.value = try std.fmt.parseUnsigned(u64, bytes, 10);
    }

    pub fn makeSnapshot(self: *CounterService, alloc: Allocator) !durable.OwnedBytes {
        return .fromOwned(alloc, try std.fmt.allocPrint(alloc, "{d}", .{self.value}));
    }

    pub fn decide(self: *CounterService, alloc: Allocator, message: []const u8) !durable.Decision {
        if (std.mem.eql(u8, message, "inc")) {
            return .{ .mutation = try durable.OwnedBytes.clone(alloc, "inc") };
        }

        if (std.mem.eql(u8, message, "get")) {
            return .{ .reply = .fromOwned(alloc, try std.fmt.allocPrint(alloc, "{d}", .{self.value})) };
        }

        return error.InvalidCommand;
    }

    pub fn apply(self: *CounterService, mutation: []const u8) !void {
        if (!std.mem.eql(u8, mutation, "inc")) return error.InvalidMutation;
        self.value += 1;
    }
};

pub fn run(alloc: Allocator, io: Io, config: Config) !Result {
    if (config.ops == 0) return error.InvalidOps;

    return switch (config.scenario) {
        .memory_hot => runMemory(alloc, io, config, .hot),
        .memory_cold => runMemory(alloc, io, config, .cold),
        .sqlite_hot => runSqlite(alloc, io, config, .hot),
        .sqlite_cold => runSqlite(alloc, io, config, .cold),
    };
}

fn runMemory(alloc: Allocator, io: Io, config: Config, mode: Mode) !Result {
    var store = durable.MemoryNodeStore.init(alloc);
    defer store.deinit();

    return runWithStore(alloc, io, store.asStoreProvider(), config, mode);
}

fn runSqlite(alloc: Allocator, io: Io, config: Config, mode: Mode) !Result {
    const sqlite_path = config.sqlite_path orelse return error.SQLitePathRequired;

    var store = try durable_sqlite.SQLiteNodeStore.init(alloc, sqlite_path, .{});
    defer store.deinit();

    return runWithStore(alloc, io, store.asStoreProvider(), config, mode);
}

fn runWithStore(
    alloc: Allocator,
    io: Io,
    store_provider: durable.StoreProvider,
    config: Config,
    mode: Mode,
) !Result {
    var runtime = durable.Runtime.init(alloc, store_provider, .{ .snapshot_every = config.snapshot_every });
    defer runtime.deinit();
    defer runtime.shutdown() catch unreachable;

    try runtime.registerFactory("counter", durable.Factory.from(CounterService, CounterService.create));

    const address = durable.Address{
        .kind = "counter",
        .key = switch (config.scenario) {
            .memory_hot => "bench:memory-hot",
            .memory_cold => "bench:memory-cold",
            .sqlite_hot => "bench:sqlite-hot",
            .sqlite_cold => "bench:sqlite-cold",
        },
    };

    try runtime.tell(address, 1, "inc");
    if (mode == .cold) {
        _ = try runtime.passivate(address);
    }

    const start = monotonicNow(io);
    var i: u64 = 0;
    while (i < config.ops) : (i += 1) {
        try runtime.tell(address, @as(u128, i) + 2, "inc");
        if (mode == .cold) {
            _ = try runtime.passivate(address);
        }
    }

    const elapsed_ns = elapsedNanoseconds(start, monotonicNow(io));

    const reply = (try runtime.request(address, @as(u128, config.ops) + 2, "get")) orelse return error.ExpectedReply;
    defer reply.deinit();

    const final_value = try std.fmt.parseUnsigned(u64, reply.bytes, 10);
    if (final_value != config.ops + 1) return error.UnexpectedFinalValue;

    return .{
        .scenario = config.scenario,
        .ops = config.ops,
        .elapsed_ns = elapsed_ns,
        .final_value = final_value,
    };
}

fn monotonicNow(io: Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

fn elapsedNanoseconds(start: std.Io.Timestamp, finish: std.Io.Timestamp) u64 {
    const elapsed = start.durationTo(finish).toNanoseconds();
    const min_elapsed: i96 = 1;
    return @intCast(@max(elapsed, min_elapsed));
}
