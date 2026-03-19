const std = @import("std");
const bench = @import("benchmark.zig");
const cli = @import("benchmark/cli.zig");
const histogram = @import("benchmark/histogram.zig");
const scale = @import("benchmark/scale.zig");

test "parseCliArgs defaults to sqlite suite" {
    const parsed = try bench.parseCliArgs(&.{});

    try std.testing.expectEqual(bench.BenchmarkMode.sqlite_suite, parsed.mode);
    try std.testing.expectEqual(@as(u64, 420), parsed.duration_seconds);
    try std.testing.expectEqual(@as(u64, 10_000), parsed.actors);
    try std.testing.expect(parsed.sqlite_path == null);
}

test "parseCliArgs supports canonical micro mode" {
    const parsed = try bench.parseCliArgs(&.{
        "--mode",
        "micro",
        "--scenario",
        "sqlite_hot",
        "--ops",
        "42",
        "--sqlite-path",
        "actors.sqlite3",
    });

    try std.testing.expectEqual(bench.BenchmarkMode.micro, parsed.mode);
    try std.testing.expectEqual(bench.Scenario.sqlite_hot, parsed.scenario.?);
    try std.testing.expectEqual(@as(u64, 42), parsed.ops.?);
    try std.testing.expectEqualStrings("actors.sqlite3", parsed.sqlite_path.?);
}

test "parseCliArgs keeps legacy positional micro scenarios" {
    const parsed = try bench.parseCliArgs(&.{ "memory_cold", "17" });

    try std.testing.expectEqual(bench.BenchmarkMode.micro, parsed.mode);
    try std.testing.expectEqual(bench.Scenario.memory_cold, parsed.scenario.?);
    try std.testing.expectEqual(@as(u64, 17), parsed.ops.?);
}

test "resolveSqlitePaths auto generates suite paths in cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const paths = try bench.resolveSqlitePaths(arena.allocator(), .{
        .mode = .sqlite_suite,
    });

    try std.testing.expect(paths.base_path != null);
    try std.testing.expect(std.mem.startsWith(u8, paths.base_path.?, ".zig-cache/bench/"));
    try std.testing.expect(paths.churn_path != null);
    try std.testing.expect(paths.reactivate_path != null);
    try std.testing.expect(paths.soak_path != null);
    try std.testing.expect(!std.mem.eql(u8, paths.churn_path.?, paths.reactivate_path.?));
    try std.testing.expect(!std.mem.eql(u8, paths.reactivate_path.?, paths.soak_path.?));
}

test "auto-generated suite phase paths must also be fresh" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/bench.sqlite3",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(base_path);

    const churn_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/bench.churn.sqlite3",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(churn_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = churn_path, .data = "stale" });

    try std.testing.expectError(
        error.SQLitePathExists,
        cli.ensureSuitePhasePathsAreFresh(base_path),
    );
}

test "deriveSuitePhaseDurations keeps the approved split" {
    const default_split = try bench.deriveSuitePhaseDurations(420);
    try std.testing.expectEqual(@as(u64, 180), default_split.churn_seconds);
    try std.testing.expectEqual(@as(u64, 120), default_split.reactivate_seconds);
    try std.testing.expectEqual(@as(u64, 120), default_split.soak_seconds);

    const minimum_split = try bench.deriveSuitePhaseDurations(90);
    try std.testing.expectEqual(@as(u64, 30), minimum_split.churn_seconds);
    try std.testing.expectEqual(@as(u64, 30), minimum_split.reactivate_seconds);
    try std.testing.expectEqual(@as(u64, 30), minimum_split.soak_seconds);
}

test "reactivate cohorts rotate across the full actor set" {
    try std.testing.expectEqual(@as(usize, 126), scale.nextReactivateActorIndex(256, 126, 0));
    try std.testing.expectEqual(@as(usize, 127), scale.nextReactivateActorIndex(256, 126, 1));
    try std.testing.expectEqual(@as(usize, 0), scale.nextReactivateActorIndex(256, 126, 130));
    try std.testing.expectEqual(@as(usize, 128), scale.nextReactivateCohortStart(256, 0, 128));
    try std.testing.expectEqual(@as(usize, 0), scale.nextReactivateCohortStart(256, 128, 128));
}

test "latency histogram percentile does not under-report linear buckets" {
    var latencies = try histogram.LatencyHistogram.init(std.testing.allocator);
    defer latencies.deinit();

    latencies.record(1_500);

    try std.testing.expect(latencies.percentile(50) >= 1_500);
}

test "sqlite churn mode runs with a tiny actor set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sqlite_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/scale-churn.sqlite3",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(sqlite_path);

    var report = try bench.runCommand(std.testing.allocator, std.testing.io, .{
        .mode = .sqlite_churn,
        .duration_seconds = 1,
        .actors = 16,
        .write_percent = 70,
        .passivate_every = 2,
        .snapshot_every = 4,
        .history_preload = 4,
        .sqlite_path = sqlite_path,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.success);
    try std.testing.expectEqual(@as(usize, 1), report.phases.len);

    const churn = report.phases[0].churn;
    try std.testing.expect(churn.total_ops > 0);
    try std.testing.expect(churn.passivation_count > 0);
    try std.testing.expect(churn.actor_count_touched > 0);
    try std.testing.expect(churn.sqlite.total_bytes >= churn.sqlite.db_bytes);
}

test "sqlite reactivate mode measures cold gets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sqlite_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/scale-reactivate.sqlite3",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(sqlite_path);

    var report = try bench.runCommand(std.testing.allocator, std.testing.io, .{
        .mode = .sqlite_reactivate,
        .duration_seconds = 1,
        .actors = 12,
        .snapshot_every = 4,
        .history_preload = 4,
        .sqlite_path = sqlite_path,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.success);
    try std.testing.expectEqual(@as(usize, 1), report.phases.len);

    const reactivate = report.phases[0].reactivate;
    try std.testing.expect(reactivate.cold_activation_count > 0);
    try std.testing.expect(reactivate.measured_cohort_size > 0);
    try std.testing.expect(reactivate.snapshot_hit_rate >= 0.0);
    try std.testing.expect(reactivate.snapshot_hit_rate <= 1.0);
}

test "renderReportJson includes mode and phase summaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sqlite_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/scale-json.sqlite3",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(sqlite_path);

    var report = try bench.runCommand(std.testing.allocator, std.testing.io, .{
        .mode = .sqlite_churn,
        .duration_seconds = 1,
        .actors = 8,
        .write_percent = 60,
        .passivate_every = 2,
        .snapshot_every = 4,
        .history_preload = 2,
        .sqlite_path = sqlite_path,
    });
    defer report.deinit(std.testing.allocator);

    const json = try bench.renderReportJson(std.testing.allocator, &report);
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("sqlite-churn", parsed.value.object.get("mode").?.string);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("phases").?.array.items.len);
}

test "renderHumanSummary includes sqlite path for sqlite runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sqlite_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/scale-summary.sqlite3",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(sqlite_path);

    var report = try bench.runCommand(std.testing.allocator, std.testing.io, .{
        .mode = .sqlite_churn,
        .duration_seconds = 1,
        .actors = 8,
        .write_percent = 60,
        .passivate_every = 2,
        .snapshot_every = 4,
        .history_preload = 2,
        .sqlite_path = sqlite_path,
    });
    defer report.deinit(std.testing.allocator);

    const summary = try bench.renderHumanSummary(std.testing.allocator, &report);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "sqlite_path=") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, sqlite_path) != null);
}

test "memory hot benchmark reports the measured counter" {
    const result = try bench.run(std.testing.allocator, std.testing.io, .{
        .scenario = .memory_hot,
        .ops = 8,
    });

    try std.testing.expectEqual(bench.Scenario.memory_hot, result.scenario);
    try std.testing.expectEqual(@as(u64, 9), result.final_value);
    try std.testing.expect(result.elapsed_ns > 0);
    try std.testing.expect(result.nsPerOp() > 0);
    try std.testing.expect(result.opsPerSecond() > 0);
}

test "memory cold benchmark reactivates and still reaches the expected value" {
    const result = try bench.run(std.testing.allocator, std.testing.io, .{
        .scenario = .memory_cold,
        .ops = 8,
    });

    try std.testing.expectEqual(bench.Scenario.memory_cold, result.scenario);
    try std.testing.expectEqual(@as(u64, 9), result.final_value);
    try std.testing.expect(result.elapsed_ns > 0);
}

test "sqlite hot benchmark writes durable state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sqlite_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/bench.sqlite3",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(sqlite_path);

    const result = try bench.run(std.testing.allocator, std.testing.io, .{
        .scenario = .sqlite_hot,
        .ops = 4,
        .sqlite_path = sqlite_path,
    });

    try std.testing.expectEqual(bench.Scenario.sqlite_hot, result.scenario);
    try std.testing.expectEqual(@as(u64, 5), result.final_value);
    try std.testing.expect(result.elapsed_ns > 0);
}

test "sqlite scenarios require a database path" {
    try std.testing.expectError(
        error.SQLitePathRequired,
        bench.run(std.testing.allocator, std.testing.io, .{
            .scenario = .sqlite_cold,
            .ops = 1,
        }),
    );
}
