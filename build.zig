const std = @import("std");
const ziglint = @import("ziglint");
const native_spec = @import("src/typescript/native_spec.zig");

const sqlite_c_flags = [_][]const u8{
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
    // Keep sqlite3_* out of the shared library's dynamic symbol table so it
    // cannot collide with the host runtime's own SQLite (node:sqlite, bun:sqlite).
    "-fvisibility=hidden",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const typescript_optimize = b.option(
        std.builtin.OptimizeMode,
        "typescript-optimize",
        "Optimize mode for the packaged TypeScript shared library",
    ) orelse .ReleaseFast;
    const typescript_target_key = b.option(
        []const u8,
        "typescript-target",
        "Packaged native key for typescript-native (for example darwin-arm64)",
    );
    const ziglint_dep = b.dependency("ziglint", .{ .optimize = .ReleaseFast });
    const sqlite_source = b.dependency("sqlite3", .{});

    const lint_step = ziglint.addLint(b, ziglint_dep, &.{
        b.path("src"),
        b.path("examples"),
        b.path("build.zig"),
    });
    b.step("lint", "Run ziglint").dependOn(lint_step);

    const sqlite_library = addSqliteLibrary(b, sqlite_source, "sqlite3", target, optimize);
    const durable_module = b.addModule("durable_actor", .{
        .root_source_file = b.path("src/durable_actor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sqlite_module = b.addModule("durable_actor_sqlite", .{
        .root_source_file = b.path("src/sqlite_store.zig"),
        .target = target,
        .optimize = optimize,
    });
    wireSqliteStore(sqlite_module, durable_module, sqlite_source, sqlite_library);

    const typescript_test_module = module(b, "src/typescript/ffi.zig", target, optimize);
    typescript_test_module.addImport("durable_actor", durable_module);
    typescript_test_module.addImport("durable_actor_sqlite", sqlite_module);

    const typescript_step = b.step("typescript-native", "Build the native TypeScript FFI library into native/<key>/");
    addSelectedTypescriptNative(
        b,
        sqlite_source,
        target,
        typescript_optimize,
        typescript_target_key,
        typescript_step,
    );

    const typescript_all_step = b.step(
        "typescript-native-all",
        "Cross-compile the packaged TypeScript FFI library matrix into native/<key>/",
    );
    for (native_spec.targets) |spec| {
        const resolved = resolveNativeQuery(b, spec.zig);
        const library = addTypescriptNativeLibrary(b, sqlite_source, spec.key, resolved, typescript_optimize);
        installTypescriptNative(b, library, spec, typescript_all_step);
    }

    const test_step = b.step("test", "Run unit tests (core + examples + TypeScript ABI)");
    addRunTest(b, test_step, durable_module);
    addRunTest(b, test_step, typescript_test_module);
    addRunTest(b, test_step, module(b, "src/typescript/native_spec.zig", target, optimize));
    addNativeSpecLockstep(b, test_step);
    addImportedTests(b, test_step, "examples/cart_example.zig", target, optimize, durable_module, null);
    addImportedTests(b, test_step, "examples/bank_example.zig", target, optimize, durable_module, null);

    const sqlite_test_step = b.step("sqlite-test", "Run SQLite-backed durable_actor tests");
    addRunTest(b, sqlite_test_step, sqlite_module);
    addImportedTests(b, sqlite_test_step, "examples/benchmark_test.zig", target, optimize, durable_module, sqlite_module);

    const install_examples = b.step("install-examples", "Install example binaries and the benchmark runner");
    addExample(b, .{
        .name = "cart_tcp_gateway",
        .source = "examples/cart_tcp_gateway.zig",
        .step_name = "cart-gateway",
        .step_description = "Run the tiny cart TCP gateway example",
        .durable = durable_module,
        .sqlite = null,
        .target = target,
        .optimize = optimize,
        .install_examples = install_examples,
    });
    addExample(b, .{
        .name = "cart_sqlite_gateway",
        .source = "examples/cart_sqlite_gateway.zig",
        .step_name = "cart-sqlite-gateway",
        .step_description = "Run the cart TCP gateway backed by SQLite",
        .durable = durable_module,
        .sqlite = sqlite_module,
        .target = target,
        .optimize = optimize,
        .install_examples = install_examples,
    });
    addExample(b, .{
        .name = "aktorz_bench",
        .source = "examples/benchmark.zig",
        .step_name = "bench",
        .step_description = "Run the aktorz benchmark scenarios",
        .durable = durable_module,
        .sqlite = sqlite_module,
        .target = target,
        .optimize = optimize,
        .install_examples = install_examples,
    });
    addExample(b, .{
        .name = "bank_tcp_gateway",
        .source = "examples/bank_tcp_gateway.zig",
        .step_name = "bank-gateway",
        .step_description = "Run the bank account TCP gateway example",
        .durable = durable_module,
        .sqlite = null,
        .target = target,
        .optimize = optimize,
        .install_examples = install_examples,
    });
}

const ExampleOptions = struct {
    name: []const u8,
    source: []const u8,
    step_name: []const u8,
    step_description: []const u8,
    durable: *std.Build.Module,
    sqlite: ?*std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    install_examples: *std.Build.Step,
};

fn addExample(b: *std.Build, options: ExampleOptions) void {
    const root = module(b, options.source, options.target, options.optimize);
    root.addImport("durable_actor", options.durable);
    if (options.sqlite) |sqlite_module| {
        root.addImport("durable_actor_sqlite", sqlite_module);
    }

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = root,
    });
    options.install_examples.dependOn(&b.addInstallArtifact(exe, .{}).step);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step(options.step_name, options.step_description).dependOn(&run.step);
}

fn addSelectedTypescriptNative(
    b: *std.Build,
    sqlite_source: *std.Build.Dependency,
    fallback_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    typescript_target_key: ?[]const u8,
    typescript_step: *std.Build.Step,
) void {
    if (typescript_target_key) |key| {
        const spec = native_spec.targetByKey(key) orelse {
            typescript_step.dependOn(&b.addFail(
                b.fmt("unknown -Dtypescript-target={s}", .{key}),
            ).step);
            return;
        };
        const resolved = resolveNativeQuery(b, spec.zig);
        const library = addTypescriptNativeLibrary(b, sqlite_source, spec.key, resolved, optimize);
        installTypescriptNative(b, library, spec, typescript_step);
        return;
    }

    const library = addTypescriptNativeLibrary(b, sqlite_source, "host", fallback_target, optimize);
    if (packagedNativeTarget(fallback_target.result)) |spec| {
        installTypescriptNative(b, library, spec, typescript_step);
    } else {
        typescript_step.dependOn(&b.addInstallArtifact(library, .{}).step);
    }
}

fn addTypescriptNativeLibrary(
    b: *std.Build,
    sqlite_source: *std.Build.Dependency,
    name_suffix: []const u8,
    resolved: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const durable = module(b, "src/durable_actor.zig", resolved, optimize);
    const sqlite_library = addSqliteLibrary(
        b,
        sqlite_source,
        b.fmt("sqlite3_{s}", .{name_suffix}),
        resolved,
        optimize,
    );
    const sqlite = module(b, "src/sqlite_store.zig", resolved, optimize);
    wireSqliteStore(sqlite, durable, sqlite_source, sqlite_library);

    const root = b.createModule(.{
        .root_source_file = b.path("src/typescript/ffi.zig"),
        .target = resolved,
        .optimize = optimize,
        .strip = true,
        .pic = true,
    });
    root.addImport("durable_actor", durable);
    root.addImport("durable_actor_sqlite", sqlite);

    return b.addLibrary(.{
        .name = b.fmt("aktorz-{s}", .{name_suffix}),
        .linkage = .dynamic,
        .root_module = root,
    });
}

fn installTypescriptNative(
    b: *std.Build,
    library: *std.Build.Step.Compile,
    spec: native_spec.NativeTarget,
    group: *std.Build.Step,
) void {
    const prefix_install = b.addInstallArtifact(library, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("native/{s}", .{spec.key}) } },
        .dest_sub_path = spec.file,
        .dylib_symlinks = false,
        .pdb_dir = .disabled,
        .h_dir = .disabled,
        .implib_dir = .disabled,
    });
    group.dependOn(&prefix_install.step);

    const package_tree = b.addUpdateSourceFiles();
    package_tree.addCopyFileToSource(
        library.getEmittedBin(),
        b.fmt("native/{s}/{s}", .{ spec.key, spec.file }),
    );
    group.dependOn(&package_tree.step);
}

fn addSqliteLibrary(
    b: *std.Build,
    sqlite_source: *std.Build.Dependency,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const library = b.addLibrary(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // The amalgamation is linked into the shared TypeScript library, and
            // musl targets do not default to PIC the way glibc ones do.
            .pic = true,
        }),
    });
    library.root_module.addCSourceFile(.{
        .file = sqlite_source.path("sqlite3.c"),
        .flags = &sqlite_c_flags,
    });
    return library;
}

fn wireSqliteStore(
    sqlite_module: *std.Build.Module,
    durable_module: *std.Build.Module,
    sqlite_source: *std.Build.Dependency,
    sqlite_library: *std.Build.Step.Compile,
) void {
    sqlite_module.addImport("durable_actor", durable_module);
    // The store links the bundled amalgamation, so importing this module is
    // enough: dependents inherit the include path, libc, and the SQLite library.
    sqlite_module.addIncludePath(sqlite_source.path(""));
    sqlite_module.link_libc = true;
    sqlite_module.linkLibrary(sqlite_library);
}

fn addImportedTests(
    b: *std.Build,
    group: *std.Build.Step,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    durable_module: *std.Build.Module,
    sqlite_module: ?*std.Build.Module,
) void {
    const root = module(b, path, target, optimize);
    root.addImport("durable_actor", durable_module);
    if (sqlite_module) |sqlite| {
        root.addImport("durable_actor_sqlite", sqlite);
    }
    addRunTest(b, group, root);
}

fn addRunTest(b: *std.Build, group: *std.Build.Step, root: *std.Build.Module) void {
    group.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);
}

fn module(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

fn addNativeSpecLockstep(b: *std.Build, group: *std.Build.Step) void {
    const ts = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "typescript/native-spec.ts",
        b.allocator,
        .unlimited,
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => std.debug.panic("unable to read typescript/native-spec.ts: {s}", .{@errorName(err)}),
    };

    var abi_needle: [64]u8 = undefined;
    const abi_line = std.fmt.bufPrint(
        &abi_needle,
        "export const ABI_VERSION = {d}",
        .{native_spec.abi_version},
    ) catch unreachable;
    if (std.mem.indexOf(u8, ts, abi_line) == null) {
        group.dependOn(&b.addFail("typescript/native-spec.ts ABI_VERSION drifted from src/typescript/native_spec.zig").step);
        return;
    }

    for (native_spec.targets) |spec| {
        var row_needle: [128]u8 = undefined;
        const row = std.fmt.bufPrint(
            &row_needle,
            "{{ key: \"{s}\", file: \"{s}\" }}",
            .{ spec.key, spec.file },
        ) catch unreachable;
        if (std.mem.indexOf(u8, ts, row) == null) {
            group.dependOn(&b.addFail(b.fmt(
                "typescript/native-spec.ts is missing packaged target {s}",
                .{spec.key},
            )).step);
            return;
        }
    }
}

fn resolveNativeQuery(b: *std.Build, zig_triple: []const u8) std.Build.ResolvedTarget {
    const query = std.Target.Query.parse(.{ .arch_os_abi = zig_triple }) catch
        std.debug.panic("invalid packaged native target {s}", .{zig_triple});
    return b.resolveTargetQuery(query);
}

fn packagedNativeTarget(result: std.Target) ?native_spec.NativeTarget {
    var key_buf: [32]u8 = undefined;
    const arch = switch (result.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => return null,
    };
    const key = switch (result.os.tag) {
        .macos => std.fmt.bufPrint(&key_buf, "darwin-{s}", .{arch}) catch return null,
        .windows => std.fmt.bufPrint(&key_buf, "win32-{s}", .{arch}) catch return null,
        .linux => blk: {
            const libc = if (result.abi.isMusl())
                "musl"
            else if (result.abi.isGnu())
                "gnu"
            else
                return null;
            break :blk std.fmt.bufPrint(&key_buf, "linux-{s}-{s}", .{ arch, libc }) catch return null;
        },
        else => return null,
    };
    return native_spec.targetByKey(key);
}
