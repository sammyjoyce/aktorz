const std = @import("std");
const micro = @import("micro.zig");

const Allocator = std.mem.Allocator;

pub const BenchmarkMode = enum {
    micro,
    sqlite_suite,
    sqlite_churn,
    sqlite_reactivate,
    sqlite_soak,
};

pub const Defaults = struct {
    pub const suite_duration_seconds: u64 = 420;
    pub const actors: u64 = 10_000;
    pub const write_percent: u8 = 70;
    pub const passivate_every: u64 = 64;
    pub const snapshot_every: u32 = 128;
    pub const history_preload: u64 = 64;
};

pub const CliConfig = struct {
    mode: BenchmarkMode = .sqlite_suite,
    scenario: ?micro.Scenario = null,
    ops: ?u64 = null,
    actors: u64 = Defaults.actors,
    duration_seconds: u64 = Defaults.suite_duration_seconds,
    duration_overridden: bool = false,
    write_percent: u8 = Defaults.write_percent,
    passivate_every: u64 = Defaults.passivate_every,
    snapshot_every: u32 = Defaults.snapshot_every,
    history_preload: u64 = Defaults.history_preload,
    sqlite_path: ?[]const u8 = null,
};

pub const SqlitePaths = struct {
    base_path: ?[]const u8 = null,
    shared_path: ?[]const u8 = null,
    churn_path: ?[]const u8 = null,
    reactivate_path: ?[]const u8 = null,
    soak_path: ?[]const u8 = null,
    auto_generated: bool = false,
};

var auto_path_counter: u64 = 0;

pub fn parseCliArgs(args: []const []const u8) !CliConfig {
    if (args.len > 0 and !std.mem.startsWith(u8, args[0], "-")) {
        if (std.meta.stringToEnum(micro.Scenario, args[0])) |scenario| {
            if (args.len < 2 or args.len > 3) return error.InvalidArguments;

            return .{
                .mode = .micro,
                .scenario = scenario,
                .ops = try parseU64(args[1]),
                .sqlite_path = if (args.len == 3) args[2] else null,
            };
        }
    }

    var parsed = CliConfig{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.mode = parseMode(args[i]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--scenario")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.scenario = std.meta.stringToEnum(micro.Scenario, args[i]) orelse return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ops")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.ops = try parseU64(args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--actors")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.actors = try parseU64(args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--duration-seconds")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.duration_seconds = try parseU64(args[i]);
            parsed.duration_overridden = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--write-percent")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.write_percent = try parseU8(args[i]);
            if (parsed.write_percent > 100) return error.InvalidArguments;
            continue;
        }
        if (std.mem.eql(u8, arg, "--passivate-every")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.passivate_every = try parseU64(args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--snapshot-every")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.snapshot_every = try parseU32(args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--history-preload")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.history_preload = try parseU64(args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--sqlite-path")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.sqlite_path = args[i];
            continue;
        }

        return error.InvalidArguments;
    }

    if (parsed.mode == .micro) {
        if (parsed.scenario == null or parsed.ops == null) return error.InvalidArguments;
    }

    if (parsed.actors == 0) return error.InvalidArguments;
    return parsed;
}

pub fn resolveSqlitePaths(alloc: Allocator, config: CliConfig) !SqlitePaths {
    switch (config.mode) {
        .micro => {
            const scenario = config.scenario orelse return error.InvalidArguments;
            if (!isSqliteScenario(scenario)) return .{};

            const shared_path = if (config.sqlite_path) |path|
                try prepareUserPath(alloc, path)
            else
                try makeAutoPath(alloc, "micro");

            return .{
                .shared_path = shared_path,
                .auto_generated = config.sqlite_path == null,
            };
        },
        .sqlite_suite => {
            const base_path = if (config.sqlite_path) |path|
                try alloc.dupe(u8, path)
            else
                try makeAutoPath(alloc, "sqlite-suite");

            const churn_path = try derivePhasePath(alloc, base_path, "churn");
            errdefer alloc.free(churn_path);
            const reactivate_path = try derivePhasePath(alloc, base_path, "reactivate");
            errdefer alloc.free(reactivate_path);
            const soak_path = try derivePhasePath(alloc, base_path, "soak");
            errdefer alloc.free(soak_path);

            try ensureSuitePhasePathsAreFresh(base_path);

            return .{
                .base_path = base_path,
                .churn_path = churn_path,
                .reactivate_path = reactivate_path,
                .soak_path = soak_path,
                .auto_generated = config.sqlite_path == null,
            };
        },
        .sqlite_churn, .sqlite_reactivate, .sqlite_soak => {
            const tag = switch (config.mode) {
                .sqlite_churn => "sqlite-churn",
                .sqlite_reactivate => "sqlite-reactivate",
                .sqlite_soak => "sqlite-soak",
                else => unreachable,
            };

            const shared_path = if (config.sqlite_path) |path|
                try prepareUserPath(alloc, path)
            else
                try makeAutoPath(alloc, tag);

            return .{
                .shared_path = shared_path,
                .auto_generated = config.sqlite_path == null,
            };
        },
    }
}

pub fn modeName(mode: BenchmarkMode) []const u8 {
    return switch (mode) {
        .micro => "micro",
        .sqlite_suite => "sqlite-suite",
        .sqlite_churn => "sqlite-churn",
        .sqlite_reactivate => "sqlite-reactivate",
        .sqlite_soak => "sqlite-soak",
    };
}

fn parseMode(text: []const u8) ?BenchmarkMode {
    inline for (std.meta.fields(BenchmarkMode)) |field| {
        const mode = @field(BenchmarkMode, field.name);
        if (std.mem.eql(u8, text, modeName(mode))) return mode;
    }
    return null;
}

fn isSqliteScenario(scenario: micro.Scenario) bool {
    return switch (scenario) {
        .sqlite_hot, .sqlite_cold => true,
        .memory_hot, .memory_cold => false,
    };
}

fn parseU8(text: []const u8) !u8 {
    return try std.fmt.parseUnsigned(u8, text, 10);
}

fn parseU32(text: []const u8) !u32 {
    return try std.fmt.parseUnsigned(u32, text, 10);
}

fn parseU64(text: []const u8) !u64 {
    return try std.fmt.parseUnsigned(u64, text, 10);
}

fn prepareUserPath(alloc: Allocator, path: []const u8) ![]const u8 {
    try ensureUserPathIsFresh(path);
    return try alloc.dupe(u8, path);
}

pub fn ensureSuitePhasePathsAreFresh(base_path: []const u8) !void {
    const alloc = std.heap.page_allocator;
    const churn_path = try derivePhasePath(alloc, base_path, "churn");
    defer alloc.free(churn_path);
    const reactivate_path = try derivePhasePath(alloc, base_path, "reactivate");
    defer alloc.free(reactivate_path);
    const soak_path = try derivePhasePath(alloc, base_path, "soak");
    defer alloc.free(soak_path);

    try ensureUserPathIsFresh(churn_path);
    try ensureUserPathIsFresh(reactivate_path);
    try ensureUserPathIsFresh(soak_path);
}

fn ensureUserPathIsFresh(path: []const u8) !void {
    if (try sqliteArtifactExists(path)) return error.SQLitePathExists;
}

fn makeAutoPath(alloc: Allocator, tag: []const u8) ![]const u8 {
    try ensureBenchCacheDir();

    while (true) {
        auto_path_counter += 1;
        const candidate = try std.fmt.allocPrint(
            alloc,
            ".zig-cache/bench/{s}-{d}-{d}.sqlite3",
            .{ tag, std.c.getpid(), auto_path_counter },
        );
        errdefer alloc.free(candidate);

        if (!try sqliteArtifactExists(candidate)) return candidate;
    }
}

fn sqliteArtifactExists(path: []const u8) !bool {
    if (try pathExists(path)) return true;

    const wal_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}-wal", .{path});
    defer std.heap.page_allocator.free(wal_path);
    if (try pathExists(wal_path)) return true;

    const shm_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}-shm", .{path});
    defer std.heap.page_allocator.free(shm_path);
    return try pathExists(shm_path);
}

fn pathExists(path: []const u8) !bool {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);

    switch (std.c.errno(std.c.faccessat(std.c.AT.FDCWD, path_z.ptr, 0, 0))) {
        .SUCCESS => return true,
        .NOENT => return false,
        else => return error.PathProbeFailed,
    }
}

fn derivePhasePath(alloc: Allocator, base_path: []const u8, phase_name: []const u8) ![]const u8 {
    const extension_index = lastExtensionIndex(base_path);
    if (extension_index) |index| {
        return try std.fmt.allocPrint(
            alloc,
            "{s}.{s}{s}",
            .{ base_path[0..index], phase_name, base_path[index..] },
        );
    }

    return try std.fmt.allocPrint(alloc, "{s}.{s}.sqlite3", .{ base_path, phase_name });
}

fn lastExtensionIndex(path: []const u8) ?usize {
    const dot_index = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    const slash_index = blk: {
        const forward = std.mem.lastIndexOfScalar(u8, path, '/');
        const backward = std.mem.lastIndexOfScalar(u8, path, '\\');
        break :blk switch ((forward != null) or (backward != null)) {
            false => null,
            true => @max(forward orelse 0, backward orelse 0),
        };
    };

    if (slash_index) |index| {
        if (dot_index <= index) return null;
    }
    return dot_index;
}

fn ensureBenchCacheDir() !void {
    try mkdirIfNeeded(".zig-cache");
    try mkdirIfNeeded(".zig-cache/bench");
}

fn mkdirIfNeeded(path: []const u8) !void {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);

    switch (std.c.errno(std.c.mkdir(path_z.ptr, 0o755))) {
        .SUCCESS, .EXIST => return,
        else => return error.CreateBenchDirectoryFailed,
    }
}
