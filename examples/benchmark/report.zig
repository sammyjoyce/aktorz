const std = @import("std");
const cli = @import("cli.zig");
const micro = @import("micro.zig");
const durable_sqlite = @import("durable_actor_sqlite");

const Allocator = std.mem.Allocator;

pub const SqliteMetrics = struct {
    db_bytes: u64,
    wal_bytes: u64,
    total_bytes: u64,
    row_counts: durable_sqlite.SQLiteNodeStore.TableRowCounts,
    wal_autocheckpoint_pages: u32,
};

pub const MicroSummary = struct {
    scenario: micro.Scenario,
    ops: u64,
    elapsed_ns: u64,
    ns_per_op: f64,
    ops_per_second: f64,
    final_value: u64,
};

pub const ChurnSummary = struct {
    total_ops: u64,
    writes: u64,
    reads: u64,
    writes_per_second: f64,
    reads_per_second: f64,
    p50_latency_ns: u64,
    p95_latency_ns: u64,
    p99_latency_ns: u64,
    actor_count_touched: u64,
    passivation_count: u64,
    passivation_time_ns: u64,
    snapshot_count: u64,
    sqlite: SqliteMetrics,
};

pub const ReactivateSummary = struct {
    cold_activation_count: u64,
    measured_cohort_size: u64,
    total_actor_count: u64,
    p50_latency_ns: u64,
    p95_latency_ns: u64,
    p99_latency_ns: u64,
    avg_replayed_mutations_per_activation: f64,
    snapshot_hit_rate: f64,
    sqlite: SqliteMetrics,
};

pub const SoakSample = struct {
    elapsed_seconds: u64,
    ops: u64,
    ops_per_second: f64,
    p95_latency_ns: u64,
    db_bytes: u64,
    wal_bytes: u64,
    total_bytes: u64,
    actor_snapshot_rows: u64,
    actor_wal_rows: u64,
    actor_seen_message_rows: u64,
};

pub const SoakSummary = struct {
    total_elapsed_seconds: u64,
    error_count: u64,
    final_total_ops: u64,
    final_writes: u64,
    final_reads: u64,
    samples: []SoakSample,
    sqlite: SqliteMetrics,
};

pub const PhaseReport = union(enum) {
    micro: MicroSummary,
    churn: ChurnSummary,
    reactivate: ReactivateSummary,
    soak: SoakSummary,

    pub fn deinit(self: *PhaseReport, alloc: Allocator) void {
        switch (self.*) {
            .soak => |summary| alloc.free(summary.samples),
            else => {},
        }
    }
};

pub const InputSummary = struct {
    scenario: ?micro.Scenario = null,
    ops: ?u64 = null,
    actors: u64,
    duration_seconds: u64,
    write_percent: u8,
    passivate_every: u64,
    snapshot_every: u32,
    history_preload: u64,
    seed: u64,
    sqlite_path: ?[]const u8 = null,
    wal_autocheckpoint_pages: u32,
};

pub const RunReport = struct {
    version: []const u8 = "2026-03-19-sqlite-scale-v1",
    timestamp_unix: i64,
    mode: cli.BenchmarkMode,
    input: InputSummary,
    success: bool = true,
    failure_phase: ?[]const u8 = null,
    failure_reason: ?[]u8 = null,
    phases: []PhaseReport,

    pub fn init(alloc: Allocator, mode: cli.BenchmarkMode, input: InputSummary) !RunReport {
        var input_copy = input;
        if (input.sqlite_path) |path| {
            input_copy.sqlite_path = try alloc.dupe(u8, path);
        }

        return .{
            .timestamp_unix = unixTimestamp(),
            .mode = mode,
            .input = input_copy,
            .phases = try alloc.alloc(PhaseReport, 0),
        };
    }

    pub fn deinit(self: *RunReport, alloc: Allocator) void {
        if (self.input.sqlite_path) |path| alloc.free(path);
        for (self.phases) |*phase| phase.deinit(alloc);
        alloc.free(self.phases);
        if (self.failure_reason) |reason| alloc.free(reason);
        self.* = undefined;
    }
};

pub fn appendPhase(alloc: Allocator, report: *RunReport, phase: PhaseReport) !void {
    const new_len = report.phases.len + 1;
    report.phases = try alloc.realloc(report.phases, new_len);
    report.phases[new_len - 1] = phase;
}

pub fn failReport(alloc: Allocator, report: *RunReport, phase_name: []const u8, err: anyerror) !void {
    report.success = false;
    report.failure_phase = phase_name;
    report.failure_reason = try std.fmt.allocPrint(alloc, "{s}", .{@errorName(err)});
}

pub fn renderJson(alloc: Allocator, report: *const RunReport) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var json_writer: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try json_writer.beginObject();
    try json_writer.objectField("version");
    try json_writer.write(report.version);
    try json_writer.objectField("timestamp_unix");
    try json_writer.write(report.timestamp_unix);
    try json_writer.objectField("mode");
    try json_writer.write(cli.modeName(report.mode));
    try json_writer.objectField("success");
    try json_writer.write(report.success);

    if (report.failure_phase) |phase_name| {
        try json_writer.objectField("failure_phase");
        try json_writer.write(phase_name);
    }
    if (report.failure_reason) |reason| {
        try json_writer.objectField("failure_reason");
        try json_writer.write(reason);
    }

    try json_writer.objectField("input");
    try writeInputJson(&json_writer, report.input);

    try json_writer.objectField("phases");
    try json_writer.beginArray();
    for (report.phases) |phase| {
        try writePhaseJson(&json_writer, phase);
    }
    try json_writer.endArray();
    try json_writer.endObject();

    return try out.toOwnedSlice();
}

pub fn renderHumanSummary(alloc: Allocator, report: *const RunReport) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    if (report.input.sqlite_path) |path| {
        try out.writer.print("sqlite_path={s}\n", .{path});
    }

    for (report.phases) |phase| {
        switch (phase) {
            .micro => |summary| try out.writer.print(
                "micro scenario={s} ops={d} ns_per_op={d:.2} ops_per_sec={d:.2} final_value={d}\n",
                .{ @tagName(summary.scenario), summary.ops, summary.ns_per_op, summary.ops_per_second, summary.final_value },
            ),
            .churn => |summary| try out.writer.print(
                "churn ops={d} writes/s={d:.2} reads/s={d:.2} p95_ns={d} passivations={d} total_bytes={d}\n",
                .{ summary.total_ops, summary.writes_per_second, summary.reads_per_second, summary.p95_latency_ns, summary.passivation_count, summary.sqlite.total_bytes },
            ),
            .reactivate => |summary| try out.writer.print(
                "reactivate cold_activations={d} cohort={d}/{d} p95_ns={d} snapshot_hit_rate={d:.2} total_bytes={d}\n",
                .{ summary.cold_activation_count, summary.measured_cohort_size, summary.total_actor_count, summary.p95_latency_ns, summary.snapshot_hit_rate, summary.sqlite.total_bytes },
            ),
            .soak => |summary| try out.writer.print(
                "soak elapsed_s={d} total_ops={d} samples={d} total_bytes={d}\n",
                .{ summary.total_elapsed_seconds, summary.final_total_ops, summary.samples.len, summary.sqlite.total_bytes },
            ),
        }
    }

    return try out.toOwnedSlice();
}

pub fn printHumanSummary(report: *const RunReport) void {
    const summary = renderHumanSummary(std.heap.page_allocator, report) catch return;
    defer std.heap.page_allocator.free(summary);
    std.debug.print("{s}", .{summary});
}

fn writeInputJson(jw: *std.json.Stringify, input: InputSummary) !void {
    try jw.beginObject();
    if (input.scenario) |scenario| {
        try jw.objectField("scenario");
        try jw.write(@tagName(scenario));
    }
    if (input.ops) |ops| {
        try jw.objectField("ops");
        try jw.write(ops);
    }
    try jw.objectField("actors");
    try jw.write(input.actors);
    try jw.objectField("duration_seconds");
    try jw.write(input.duration_seconds);
    try jw.objectField("write_percent");
    try jw.write(input.write_percent);
    try jw.objectField("passivate_every");
    try jw.write(input.passivate_every);
    try jw.objectField("snapshot_every");
    try jw.write(input.snapshot_every);
    try jw.objectField("history_preload");
    try jw.write(input.history_preload);
    try jw.objectField("seed");
    try jw.write(input.seed);
    try jw.objectField("wal_autocheckpoint_pages");
    try jw.write(input.wal_autocheckpoint_pages);
    if (input.sqlite_path) |path| {
        try jw.objectField("sqlite_path");
        try jw.write(path);
    }
    try jw.endObject();
}

fn writePhaseJson(jw: *std.json.Stringify, phase: PhaseReport) !void {
    try jw.beginObject();
    switch (phase) {
        .micro => |summary| {
            try jw.objectField("kind");
            try jw.write("micro");
            try jw.objectField("scenario");
            try jw.write(@tagName(summary.scenario));
            try jw.objectField("ops");
            try jw.write(summary.ops);
            try jw.objectField("elapsed_ns");
            try jw.write(summary.elapsed_ns);
            try jw.objectField("ns_per_op");
            try jw.write(summary.ns_per_op);
            try jw.objectField("ops_per_second");
            try jw.write(summary.ops_per_second);
            try jw.objectField("final_value");
            try jw.write(summary.final_value);
        },
        .churn => |summary| {
            try jw.objectField("kind");
            try jw.write("churn");
            try jw.objectField("total_ops");
            try jw.write(summary.total_ops);
            try jw.objectField("writes");
            try jw.write(summary.writes);
            try jw.objectField("reads");
            try jw.write(summary.reads);
            try jw.objectField("writes_per_second");
            try jw.write(summary.writes_per_second);
            try jw.objectField("reads_per_second");
            try jw.write(summary.reads_per_second);
            try jw.objectField("p50_latency_ns");
            try jw.write(summary.p50_latency_ns);
            try jw.objectField("p95_latency_ns");
            try jw.write(summary.p95_latency_ns);
            try jw.objectField("p99_latency_ns");
            try jw.write(summary.p99_latency_ns);
            try jw.objectField("actor_count_touched");
            try jw.write(summary.actor_count_touched);
            try jw.objectField("passivation_count");
            try jw.write(summary.passivation_count);
            try jw.objectField("passivation_time_ns");
            try jw.write(summary.passivation_time_ns);
            try jw.objectField("snapshot_count");
            try jw.write(summary.snapshot_count);
            try jw.objectField("sqlite");
            try writeSqliteJson(jw, summary.sqlite);
        },
        .reactivate => |summary| {
            try jw.objectField("kind");
            try jw.write("reactivate");
            try jw.objectField("cold_activation_count");
            try jw.write(summary.cold_activation_count);
            try jw.objectField("measured_cohort_size");
            try jw.write(summary.measured_cohort_size);
            try jw.objectField("total_actor_count");
            try jw.write(summary.total_actor_count);
            try jw.objectField("p50_latency_ns");
            try jw.write(summary.p50_latency_ns);
            try jw.objectField("p95_latency_ns");
            try jw.write(summary.p95_latency_ns);
            try jw.objectField("p99_latency_ns");
            try jw.write(summary.p99_latency_ns);
            try jw.objectField("avg_replayed_mutations_per_activation");
            try jw.write(summary.avg_replayed_mutations_per_activation);
            try jw.objectField("snapshot_hit_rate");
            try jw.write(summary.snapshot_hit_rate);
            try jw.objectField("sqlite");
            try writeSqliteJson(jw, summary.sqlite);
        },
        .soak => |summary| {
            try jw.objectField("kind");
            try jw.write("soak");
            try jw.objectField("total_elapsed_seconds");
            try jw.write(summary.total_elapsed_seconds);
            try jw.objectField("error_count");
            try jw.write(summary.error_count);
            try jw.objectField("final_total_ops");
            try jw.write(summary.final_total_ops);
            try jw.objectField("final_writes");
            try jw.write(summary.final_writes);
            try jw.objectField("final_reads");
            try jw.write(summary.final_reads);
            try jw.objectField("samples");
            try jw.beginArray();
            for (summary.samples) |sample| {
                try writeSoakSampleJson(jw, sample);
            }
            try jw.endArray();
            try jw.objectField("sqlite");
            try writeSqliteJson(jw, summary.sqlite);
        },
    }
    try jw.endObject();
}

fn writeSqliteJson(jw: *std.json.Stringify, sqlite: SqliteMetrics) !void {
    try jw.beginObject();
    try jw.objectField("db_bytes");
    try jw.write(sqlite.db_bytes);
    try jw.objectField("wal_bytes");
    try jw.write(sqlite.wal_bytes);
    try jw.objectField("total_bytes");
    try jw.write(sqlite.total_bytes);
    try jw.objectField("wal_autocheckpoint_pages");
    try jw.write(sqlite.wal_autocheckpoint_pages);
    try jw.objectField("row_counts");
    try jw.beginObject();
    try jw.objectField("actor_snapshot");
    try jw.write(sqlite.row_counts.actor_snapshot);
    try jw.objectField("actor_wal");
    try jw.write(sqlite.row_counts.actor_wal);
    try jw.objectField("actor_seen_message");
    try jw.write(sqlite.row_counts.actor_seen_message);
    try jw.endObject();
    try jw.endObject();
}

fn writeSoakSampleJson(jw: *std.json.Stringify, sample: SoakSample) !void {
    try jw.beginObject();
    try jw.objectField("elapsed_seconds");
    try jw.write(sample.elapsed_seconds);
    try jw.objectField("ops");
    try jw.write(sample.ops);
    try jw.objectField("ops_per_second");
    try jw.write(sample.ops_per_second);
    try jw.objectField("p95_latency_ns");
    try jw.write(sample.p95_latency_ns);
    try jw.objectField("db_bytes");
    try jw.write(sample.db_bytes);
    try jw.objectField("wal_bytes");
    try jw.write(sample.wal_bytes);
    try jw.objectField("total_bytes");
    try jw.write(sample.total_bytes);
    try jw.objectField("actor_snapshot_rows");
    try jw.write(sample.actor_snapshot_rows);
    try jw.objectField("actor_wal_rows");
    try jw.write(sample.actor_wal_rows);
    try jw.objectField("actor_seen_message_rows");
    try jw.write(sample.actor_seen_message_rows);
    try jw.endObject();
}

fn unixTimestamp() i64 {
    var tv = std.mem.zeroes(std.c.timeval);
    return switch (std.c.errno(std.c.gettimeofday(&tv, null))) {
        .SUCCESS => @intCast(tv.sec),
        else => 0,
    };
}
