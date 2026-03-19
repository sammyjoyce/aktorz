const std = @import("std");

const cli = @import("benchmark/cli.zig");
const micro = @import("benchmark/micro.zig");
const report = @import("benchmark/report.zig");
const scale = @import("benchmark/scale.zig");

pub const BenchmarkMode = cli.BenchmarkMode;
pub const CliConfig = cli.CliConfig;
pub const Config = micro.Config;
pub const Defaults = cli.Defaults;
pub const Result = micro.Result;
pub const RunReport = report.RunReport;
pub const Scenario = micro.Scenario;
pub const SqlitePaths = cli.SqlitePaths;
pub const SuitePhaseDurations = scale.SuitePhaseDurations;

pub const deriveSuitePhaseDurations = scale.deriveSuitePhaseDurations;
pub const parseCliArgs = cli.parseCliArgs;
pub const renderHumanSummary = report.renderHumanSummary;
pub const renderReportJson = report.renderJson;
pub const resolveSqlitePaths = cli.resolveSqlitePaths;
pub const run = micro.run;
pub const runCommand = scale.runCommand;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, std.heap.c_allocator);
    defer args.deinit();

    _ = args.next();

    var raw_args = std.ArrayList([]const u8).empty;
    defer raw_args.deinit(std.heap.c_allocator);
    while (args.next()) |arg| {
        try raw_args.append(std.heap.c_allocator, arg);
    }

    const parsed = parseCliArgs(raw_args.items) catch return usage();
    var run_report = try runCommand(std.heap.c_allocator, init.io, parsed);
    defer run_report.deinit(std.heap.c_allocator);

    report.printHumanSummary(&run_report);

    const json = try renderReportJson(std.heap.c_allocator, &run_report);
    defer std.heap.c_allocator.free(json);
    std.debug.print("{s}\n", .{json});

    if (!run_report.success) return error.BenchmarkFailed;
}

fn usage() error{InvalidArguments}!void {
    std.debug.print(
        "usage: zig build bench -- [--mode <micro|sqlite-suite|sqlite-churn|sqlite-reactivate|sqlite-soak>] [--scenario <memory_hot|memory_cold|sqlite_hot|sqlite_cold>] [--ops <count>] [--sqlite-path <path>]\n",
        .{},
    );
    return error.InvalidArguments;
}
