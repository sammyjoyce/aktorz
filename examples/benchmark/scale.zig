const std = @import("std");
const durable = @import("durable_actor");
const durable_sqlite = @import("durable_actor_sqlite");

const cli = @import("cli.zig");
const histogram = @import("histogram.zig");
const instrumentation = @import("instrumentation.zig");
const micro = @import("micro.zig");
const report = @import("report.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const SuitePhaseDurations = struct {
    churn_seconds: u64,
    reactivate_seconds: u64,
    soak_seconds: u64,
};

const workload_seed: u64 = 0xA170_C0DE_5EED_0001;
const wal_autocheckpoint_pages: u32 = 0;
const reactivate_cohort_cap: u64 = 128;
const soak_sample_interval_seconds: u64 = 10;

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

pub fn deriveSuitePhaseDurations(total_seconds: u64) !SuitePhaseDurations {
    if (total_seconds < 90) return error.DurationTooShort;

    if (total_seconds < 105) {
        var result = SuitePhaseDurations{
            .churn_seconds = 30,
            .reactivate_seconds = 30,
            .soak_seconds = 30,
        };
        var remaining = total_seconds - 90;
        const order = [_]enum { churn, reactivate, soak }{ .churn, .churn, .churn, .reactivate, .reactivate, .soak, .soak };
        var index: usize = 0;
        while (remaining > 0) : (remaining -= 1) {
            switch (order[index % order.len]) {
                .churn => result.churn_seconds += 1,
                .reactivate => result.reactivate_seconds += 1,
                .soak => result.soak_seconds += 1,
            }
            index += 1;
        }
        return result;
    }

    var result = SuitePhaseDurations{
        .churn_seconds = (total_seconds * 3) / 7,
        .reactivate_seconds = (total_seconds * 2) / 7,
        .soak_seconds = (total_seconds * 2) / 7,
    };

    var assigned = result.churn_seconds + result.reactivate_seconds + result.soak_seconds;
    const order = [_]*u64{ &result.churn_seconds, &result.reactivate_seconds, &result.soak_seconds };
    var index: usize = 0;
    while (assigned < total_seconds) : (assigned += 1) {
        order[index % order.len].* += 1;
        index += 1;
    }
    return result;
}

pub fn runCommand(alloc: Allocator, io: Io, config: cli.CliConfig) !report.RunReport {
    const resolved_paths = try cli.resolveSqlitePaths(alloc, config);
    defer freeResolvedPaths(alloc, resolved_paths);

    const effective_duration_seconds = switch (config.mode) {
        .sqlite_churn => selectStandaloneDuration(config, 180),
        .sqlite_reactivate => selectStandaloneDuration(config, 120),
        .sqlite_soak => selectStandaloneDuration(config, 120),
        .sqlite_suite, .micro => config.duration_seconds,
    };

    var run_report = try report.RunReport.init(alloc, config.mode, .{
        .scenario = config.scenario,
        .ops = config.ops,
        .actors = config.actors,
        .duration_seconds = effective_duration_seconds,
        .write_percent = config.write_percent,
        .passivate_every = config.passivate_every,
        .snapshot_every = config.snapshot_every,
        .history_preload = config.history_preload,
        .seed = workload_seed,
        .sqlite_path = selectedInputPath(config.mode, resolved_paths),
        .wal_autocheckpoint_pages = wal_autocheckpoint_pages,
    });
    errdefer run_report.deinit(alloc);

    switch (config.mode) {
        .micro => {
            const result = micro.run(alloc, io, .{
                .scenario = config.scenario.?,
                .ops = config.ops.?,
                .sqlite_path = resolved_paths.shared_path,
                .snapshot_every = config.snapshot_every,
            }) catch |err| {
                try report.failReport(alloc, &run_report, "micro", err);
                return run_report;
            };

            try report.appendPhase(alloc, &run_report, .{ .micro = .{
                .scenario = result.scenario,
                .ops = result.ops,
                .elapsed_ns = result.elapsed_ns,
                .ns_per_op = result.nsPerOp(),
                .ops_per_second = result.opsPerSecond(),
                .final_value = result.final_value,
            } });
            return run_report;
        },
        .sqlite_suite => {
            const split = deriveSuitePhaseDurations(effective_duration_seconds) catch |err| {
                try report.failReport(alloc, &run_report, "suite", err);
                return run_report;
            };

            runSqlitePhase(alloc, io, config, resolved_paths.churn_path.?, split.churn_seconds, .churn, &run_report) catch {};
            if (!run_report.success) return run_report;
            runSqlitePhase(alloc, io, config, resolved_paths.reactivate_path.?, split.reactivate_seconds, .reactivate, &run_report) catch {};
            if (!run_report.success) return run_report;
            runSqlitePhase(alloc, io, config, resolved_paths.soak_path.?, split.soak_seconds, .soak, &run_report) catch {};
            return run_report;
        },
        .sqlite_churn => {
            runSqlitePhase(alloc, io, config, resolved_paths.shared_path.?, effective_duration_seconds, .churn, &run_report) catch {};
            return run_report;
        },
        .sqlite_reactivate => {
            runSqlitePhase(alloc, io, config, resolved_paths.shared_path.?, effective_duration_seconds, .reactivate, &run_report) catch {};
            return run_report;
        },
        .sqlite_soak => {
            runSqlitePhase(alloc, io, config, resolved_paths.shared_path.?, effective_duration_seconds, .soak, &run_report) catch {};
            return run_report;
        },
    }
}

fn selectStandaloneDuration(config: cli.CliConfig, fallback_seconds: u64) u64 {
    if (config.duration_overridden) return config.duration_seconds;
    if (config.duration_seconds != cli.Defaults.suite_duration_seconds) return config.duration_seconds;
    return fallback_seconds;
}

fn runSqlitePhase(
    alloc: Allocator,
    io: Io,
    config: cli.CliConfig,
    sqlite_path: []const u8,
    duration_seconds: u64,
    phase_kind: enum { churn, reactivate, soak },
    run_report: *report.RunReport,
) !void {
    const phase_report = switch (phase_kind) {
        .churn => runChurnPhase(alloc, io, config, sqlite_path, duration_seconds),
        .reactivate => runReactivatePhase(alloc, io, config, sqlite_path, duration_seconds),
        .soak => runSoakPhase(alloc, io, config, sqlite_path, duration_seconds),
    } catch |err| {
        const phase_name = switch (phase_kind) {
            .churn => "churn",
            .reactivate => "reactivate",
            .soak => "soak",
        };
        try report.failReport(alloc, run_report, phase_name, err);
        return err;
    };

    try report.appendPhase(alloc, run_report, phase_report);
}

fn runChurnPhase(alloc: Allocator, io: Io, config: cli.CliConfig, sqlite_path: []const u8, duration_seconds: u64) !report.PhaseReport {
    var store = try durable_sqlite.SQLiteNodeStore.init(alloc, sqlite_path, .{
        .wal_autocheckpoint_pages = wal_autocheckpoint_pages,
    });
    defer store.deinit();

    var collector: instrumentation.Collector = .{};
    var instrumented = instrumentation.Provider.init(alloc, store.asStoreProvider(), &collector);
    var runtime = durable.Runtime.init(alloc, instrumented.asStoreProvider(), .{ .snapshot_every = config.snapshot_every });
    defer runtime.deinit();
    defer runtime.shutdown() catch unreachable;

    try runtime.registerFactory("counter", durable.Factory.from(CounterService, CounterService.create));

    var workload = try Workload.init(alloc, config.actors, workload_seed, config.write_percent);
    defer workload.deinit();

    var latencies = try histogram.LatencyHistogram.init(alloc);
    defer latencies.deinit();

    const start = monotonicNow(io);
    const deadline_ns = duration_seconds * std.time.ns_per_s;
    var writes: u64 = 0;
    var reads: u64 = 0;
    var passivation_count: u64 = 0;
    var passivation_time_ns: u64 = 0;

    while (elapsedNanoseconds(start, monotonicNow(io)) < deadline_ns) {
        const actor_index = workload.selectActor();
        const address = workload.addresses[actor_index];
        const is_write = workload.shouldWrite();
        const passivate_after_write = is_write and config.passivate_every > 0 and ((writes + 1) % config.passivate_every == 0);
        const op_start = monotonicNow(io);

        if (is_write) {
            try runtime.tell(address, workload.message_ids.next(if (passivate_after_write) .passivate_trigger else .measured), "inc");
            workload.recordWrite(actor_index);
            writes += 1;

            if (passivate_after_write) {
                const passivate_start = monotonicNow(io);
                _ = try runtime.passivate(address);
                passivation_time_ns += elapsedNanoseconds(passivate_start, monotonicNow(io));
                passivation_count += 1;
            }
        } else {
            const reply = (try runtime.request(address, workload.message_ids.next(.measured), "get")) orelse return error.ExpectedReply;
            defer reply.deinit();
            const value = try std.fmt.parseUnsigned(u64, reply.bytes, 10);
            if (value != workload.expected[actor_index]) return error.UnexpectedReadValue;
            workload.recordReadVerified(actor_index);
            reads += 1;
        }

        latencies.record(elapsedNanoseconds(op_start, monotonicNow(io)));
    }

    try verifyExpectedValues(&runtime, &workload, .churn);

    const elapsed_ns = elapsedNanoseconds(start, monotonicNow(io));
    const sqlite_metrics = try sampleSqliteMetrics(io, &store, sqlite_path);
    const store_counters = collector.snapshot();

    return .{ .churn = .{
        .total_ops = writes + reads,
        .writes = writes,
        .reads = reads,
        .writes_per_second = ratePerSecond(writes, elapsed_ns),
        .reads_per_second = ratePerSecond(reads, elapsed_ns),
        .p50_latency_ns = latencies.percentile(50),
        .p95_latency_ns = latencies.percentile(95),
        .p99_latency_ns = latencies.percentile(99),
        .actor_count_touched = workload.touchedCount(),
        .passivation_count = passivation_count,
        .passivation_time_ns = passivation_time_ns,
        .snapshot_count = store_counters.snapshot_writes,
        .sqlite = sqlite_metrics,
    } };
}

fn runReactivatePhase(alloc: Allocator, io: Io, config: cli.CliConfig, sqlite_path: []const u8, duration_seconds: u64) !report.PhaseReport {
    var store = try durable_sqlite.SQLiteNodeStore.init(alloc, sqlite_path, .{
        .wal_autocheckpoint_pages = wal_autocheckpoint_pages,
    });
    defer store.deinit();

    var collector: instrumentation.Collector = .{};
    var instrumented = instrumentation.Provider.init(alloc, store.asStoreProvider(), &collector);
    var runtime = durable.Runtime.init(alloc, instrumented.asStoreProvider(), .{ .snapshot_every = config.snapshot_every });
    defer runtime.deinit();
    defer runtime.shutdown() catch unreachable;

    try runtime.registerFactory("counter", durable.Factory.from(CounterService, CounterService.create));

    var workload = try Workload.init(alloc, config.actors, workload_seed, 100);
    defer workload.deinit();

    const cohort_size: usize = @intCast(@min(config.actors, reactivate_cohort_cap));
    var latencies = try histogram.LatencyHistogram.init(alloc);
    defer latencies.deinit();

    var measured_store_counters: instrumentation.StoreCounters = .{};
    var cold_activation_count: u64 = 0;

    const start = monotonicNow(io);
    const deadline_ns = duration_seconds * std.time.ns_per_s;
    var measured_cohort_size: usize = 0;

    while (elapsedNanoseconds(start, monotonicNow(io)) < deadline_ns) {
        collector.reset();

        var prepared_actor_count: usize = 0;
        while (prepared_actor_count < cohort_size) : (prepared_actor_count += 1) {
            if (elapsedNanoseconds(start, monotonicNow(io)) >= deadline_ns) break;

            const address = workload.addresses[prepared_actor_count];
            var preload_index: u64 = 0;
            while (preload_index < config.history_preload) : (preload_index += 1) {
                try runtime.tell(address, workload.message_ids.next(.preload), "inc");
                workload.recordWrite(prepared_actor_count);
            }
            _ = try runtime.passivate(address);
        }

        if (prepared_actor_count == 0) break;
        measured_cohort_size = @max(measured_cohort_size, prepared_actor_count);

        collector.reset();
        var actor_index: usize = 0;
        while (actor_index < prepared_actor_count) : (actor_index += 1) {
            const address = workload.addresses[actor_index];
            const op_start = monotonicNow(io);
            const reply = (try runtime.request(address, workload.message_ids.next(.measured), "get")) orelse return error.ExpectedReply;
            defer reply.deinit();
            const value = try std.fmt.parseUnsigned(u64, reply.bytes, 10);
            if (value != workload.expected[actor_index]) return error.UnexpectedReadValue;
            workload.recordReadVerified(actor_index);
            latencies.record(elapsedNanoseconds(op_start, monotonicNow(io)));
            cold_activation_count += 1;
        }

        accumulateStoreCounters(&measured_store_counters, collector.snapshot());
    }

    try verifyExpectedValues(&runtime, &workload, .reactivate);

    const sqlite_metrics = try sampleSqliteMetrics(io, &store, sqlite_path);
    return .{ .reactivate = .{
        .cold_activation_count = cold_activation_count,
        .measured_cohort_size = measured_cohort_size,
        .total_actor_count = config.actors,
        .p50_latency_ns = latencies.percentile(50),
        .p95_latency_ns = latencies.percentile(95),
        .p99_latency_ns = latencies.percentile(99),
        .avg_replayed_mutations_per_activation = if (cold_activation_count == 0)
            0.0
        else
            @as(f64, @floatFromInt(measured_store_counters.replayed_mutations)) / @as(f64, @floatFromInt(cold_activation_count)),
        .snapshot_hit_rate = if (measured_store_counters.snapshot_loads == 0)
            0.0
        else
            @as(f64, @floatFromInt(measured_store_counters.snapshot_hits)) / @as(f64, @floatFromInt(measured_store_counters.snapshot_loads)),
        .sqlite = sqlite_metrics,
    } };
}

fn runSoakPhase(alloc: Allocator, io: Io, config: cli.CliConfig, sqlite_path: []const u8, duration_seconds: u64) !report.PhaseReport {
    var store = try durable_sqlite.SQLiteNodeStore.init(alloc, sqlite_path, .{
        .wal_autocheckpoint_pages = wal_autocheckpoint_pages,
    });
    defer store.deinit();

    var collector: instrumentation.Collector = .{};
    var instrumented = instrumentation.Provider.init(alloc, store.asStoreProvider(), &collector);
    var runtime = durable.Runtime.init(alloc, instrumented.asStoreProvider(), .{ .snapshot_every = config.snapshot_every });
    defer runtime.deinit();
    defer runtime.shutdown() catch unreachable;

    try runtime.registerFactory("counter", durable.Factory.from(CounterService, CounterService.create));

    var workload = try Workload.init(alloc, config.actors, workload_seed, config.write_percent);
    defer workload.deinit();

    var interval_latencies = try histogram.LatencyHistogram.init(alloc);
    defer interval_latencies.deinit();

    var samples = std.ArrayList(report.SoakSample).empty;
    defer samples.deinit(alloc);

    const start = monotonicNow(io);
    const deadline_ns = duration_seconds * std.time.ns_per_s;
    var next_sample_seconds = soak_sample_interval_seconds;
    var writes: u64 = 0;
    var reads: u64 = 0;
    var interval_ops: u64 = 0;
    var interval_start_ns: u64 = 0;

    while (elapsedNanoseconds(start, monotonicNow(io)) < deadline_ns) {
        const actor_index = workload.selectActor();
        const address = workload.addresses[actor_index];
        const is_write = workload.shouldWrite();
        const passivate_after_write = is_write and config.passivate_every > 0 and ((writes + 1) % config.passivate_every == 0);
        const op_start = monotonicNow(io);

        if (is_write) {
            try runtime.tell(address, workload.message_ids.next(if (passivate_after_write) .passivate_trigger else .measured), "inc");
            workload.recordWrite(actor_index);
            writes += 1;
            if (passivate_after_write) {
                _ = try runtime.passivate(address);
            }
        } else {
            const reply = (try runtime.request(address, workload.message_ids.next(.measured), "get")) orelse return error.ExpectedReply;
            defer reply.deinit();
            const value = try std.fmt.parseUnsigned(u64, reply.bytes, 10);
            if (value != workload.expected[actor_index]) return error.UnexpectedReadValue;
            workload.recordReadVerified(actor_index);
            reads += 1;
        }

        interval_ops += 1;
        interval_latencies.record(elapsedNanoseconds(op_start, monotonicNow(io)));

        const elapsed_seconds = elapsedNanoseconds(start, monotonicNow(io)) / std.time.ns_per_s;
        if (elapsed_seconds >= next_sample_seconds) {
            const sqlite_metrics = try sampleSqliteMetrics(io, &store, sqlite_path);
            const interval_elapsed_seconds = elapsed_seconds - interval_start_ns;
            try samples.append(alloc, .{
                .elapsed_seconds = elapsed_seconds,
                .ops = interval_ops,
                .ops_per_second = if (interval_elapsed_seconds == 0)
                    0.0
                else
                    @as(f64, @floatFromInt(interval_ops)) / @as(f64, @floatFromInt(interval_elapsed_seconds)),
                .p95_latency_ns = interval_latencies.percentile(95),
                .db_bytes = sqlite_metrics.db_bytes,
                .wal_bytes = sqlite_metrics.wal_bytes,
                .total_bytes = sqlite_metrics.total_bytes,
                .actor_snapshot_rows = sqlite_metrics.row_counts.actor_snapshot,
                .actor_wal_rows = sqlite_metrics.row_counts.actor_wal,
                .actor_seen_message_rows = sqlite_metrics.row_counts.actor_seen_message,
            });
            interval_start_ns = elapsed_seconds;
            interval_ops = 0;
            interval_latencies.reset();
            next_sample_seconds += soak_sample_interval_seconds;
        }
    }

    try verifyExpectedValues(&runtime, &workload, .soak);
    const sqlite_metrics = try sampleSqliteMetrics(io, &store, sqlite_path);
    return .{ .soak = .{
        .total_elapsed_seconds = duration_seconds,
        .error_count = 0,
        .final_total_ops = writes + reads,
        .final_writes = writes,
        .final_reads = reads,
        .samples = try samples.toOwnedSlice(alloc),
        .sqlite = sqlite_metrics,
    } };
}

fn verifyExpectedValues(runtime: *durable.Runtime, workload: *Workload, comptime phase_tag: MessageIds.PhaseTag) !void {
    var actor_index: usize = 0;
    while (actor_index < workload.addresses.len) : (actor_index += 1) {
        if (!workload.needs_verify[actor_index]) continue;

        const reply = (try runtime.request(workload.addresses[actor_index], workload.message_ids.next(.verify), "get")) orelse return error.ExpectedReply;
        defer reply.deinit();
        const value = try std.fmt.parseUnsigned(u64, reply.bytes, 10);
        if (value != workload.expected[actor_index]) return error.UnexpectedFinalValue;
    }
    _ = phase_tag;
}

fn sampleSqliteMetrics(io: Io, store: *durable_sqlite.SQLiteNodeStore, sqlite_path: []const u8) !report.SqliteMetrics {
    const db_bytes = try fileSize(io, sqlite_path, false);
    const wal_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}-wal", .{sqlite_path});
    defer std.heap.page_allocator.free(wal_path);

    const wal_bytes = try fileSize(io, wal_path, true);
    return .{
        .db_bytes = db_bytes,
        .wal_bytes = wal_bytes,
        .total_bytes = db_bytes + wal_bytes,
        .row_counts = try store.sampleTableRowCounts(),
        .wal_autocheckpoint_pages = try store.walAutocheckpointPages(),
    };
}

fn fileSize(io: Io, path: []const u8, treat_missing_as_zero: bool) !u64 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => if (treat_missing_as_zero) return 0 else return err,
        else => return err,
    };
    return @intCast(stat.size);
}

fn ratePerSecond(count: u64, elapsed_ns: u64) f64 {
    if (elapsed_ns == 0) return 0.0;
    return (@as(f64, @floatFromInt(count)) * @as(f64, std.time.ns_per_s)) / @as(f64, @floatFromInt(elapsed_ns));
}

fn monotonicNow(io: Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

fn elapsedNanoseconds(start: std.Io.Timestamp, finish: std.Io.Timestamp) u64 {
    const elapsed = start.durationTo(finish).toNanoseconds();
    return @intCast(@max(elapsed, @as(i96, 1)));
}

fn accumulateStoreCounters(target: *instrumentation.StoreCounters, delta: instrumentation.StoreCounters) void {
    target.activations += delta.activations;
    target.snapshot_loads += delta.snapshot_loads;
    target.snapshot_hits += delta.snapshot_hits;
    target.replayed_mutations += delta.replayed_mutations;
    target.snapshot_writes += delta.snapshot_writes;
}

fn freeResolvedPaths(alloc: Allocator, paths: cli.SqlitePaths) void {
    inline for (.{ paths.base_path, paths.shared_path, paths.churn_path, paths.reactivate_path, paths.soak_path }) |maybe_path| {
        if (maybe_path) |path| alloc.free(path);
    }
}

fn selectedInputPath(mode: cli.BenchmarkMode, paths: cli.SqlitePaths) ?[]const u8 {
    return switch (mode) {
        .micro, .sqlite_churn, .sqlite_reactivate, .sqlite_soak => paths.shared_path,
        .sqlite_suite => paths.base_path,
    };
}

const Workload = struct {
    alloc: Allocator,
    addresses: []durable.Address,
    expected: []u64,
    touched: []bool,
    needs_verify: []bool,
    prng: std.Random.DefaultPrng,
    write_percent: u8,
    hot_count: usize,
    message_ids: MessageIds,

    pub fn init(alloc: Allocator, actor_count: u64, seed: u64, write_percent: u8) !Workload {
        const count: usize = @intCast(actor_count);
        const addresses = try alloc.alloc(durable.Address, count);
        errdefer alloc.free(addresses);

        for (addresses, 0..) |*address, index| {
            const key = try std.fmt.allocPrint(alloc, "bench:actor-{d}", .{index});
            address.* = .{ .kind = "counter", .key = key };
        }

        const expected = try alloc.alloc(u64, count);
        errdefer alloc.free(expected);
        @memset(expected, 0);

        const touched = try alloc.alloc(bool, count);
        errdefer alloc.free(touched);
        @memset(touched, false);

        const needs_verify = try alloc.alloc(bool, count);
        errdefer alloc.free(needs_verify);
        @memset(needs_verify, false);

        return .{
            .alloc = alloc,
            .addresses = addresses,
            .expected = expected,
            .touched = touched,
            .needs_verify = needs_verify,
            .prng = std.Random.DefaultPrng.init(seed),
            .write_percent = write_percent,
            .hot_count = hotSetCount(count),
            .message_ids = .{},
        };
    }

    pub fn deinit(self: *Workload) void {
        for (self.addresses) |address| self.alloc.free(address.key);
        self.alloc.free(self.addresses);
        self.alloc.free(self.expected);
        self.alloc.free(self.touched);
        self.alloc.free(self.needs_verify);
        self.* = undefined;
    }

    pub fn shouldWrite(self: *Workload) bool {
        return self.prng.random().uintLessThan(u8, 100) < self.write_percent;
    }

    pub fn selectActor(self: *Workload) usize {
        if (self.addresses.len == 1) return 0;

        if (self.prng.random().uintLessThan(u8, 100) < 80) {
            return self.prng.random().uintLessThan(usize, self.hot_count);
        }

        const cold_count = self.addresses.len - self.hot_count;
        return self.hot_count + self.prng.random().uintLessThan(usize, cold_count);
    }

    pub fn recordWrite(self: *Workload, actor_index: usize) void {
        self.expected[actor_index] += 1;
        self.touched[actor_index] = true;
        self.needs_verify[actor_index] = true;
    }

    pub fn recordReadVerified(self: *Workload, actor_index: usize) void {
        self.needs_verify[actor_index] = false;
    }

    pub fn touchedCount(self: *const Workload) u64 {
        var count: u64 = 0;
        for (self.touched) |touched| {
            if (touched) count += 1;
        }
        return count;
    }
};

fn hotSetCount(actor_count: usize) usize {
    if (actor_count <= 1) return 1;

    const desired = @max(@as(usize, 1), actor_count / 20);
    return @min(desired, actor_count - 1);
}

const MessageIds = struct {
    counters: [4]u64 = [_]u64{0} ** 4,

    const Segment = enum(u8) {
        preload = 1,
        measured = 2,
        passivate_trigger = 3,
        verify = 4,
    };

    const PhaseTag = enum {
        churn,
        reactivate,
        soak,
    };

    fn next(self: *MessageIds, segment: Segment) u128 {
        const index: usize = @intFromEnum(segment) - 1;
        self.counters[index] += 1;
        return (@as(u128, @intFromEnum(segment)) << 112) | @as(u128, self.counters[index]);
    }
};
