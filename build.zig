const std = @import("std");
const ziglint = @import("ziglint");

fn linkBundledSqlite(mod: *std.Build.Module, sqlite_library: *std.Build.Step.Compile) void {
    mod.link_libc = true;
    mod.linkLibrary(sqlite_library);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ziglint_dep = b.dependency("ziglint", .{ .optimize = .ReleaseFast });
    const sqlite_source = b.dependency("sqlite3", .{});

    const sqlite_library = b.addLibrary(.{
        .name = "sqlite3",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    sqlite_library.root_module.addCSourceFile(.{
        .file = sqlite_source.path("sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
        },
    });

    const lint_step = ziglint.addLint(b, ziglint_dep, &.{
        b.path("src"),
        b.path("examples"),
        b.path("build.zig"),
    });
    b.step("lint", "Run ziglint").dependOn(lint_step);

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
    sqlite_module.addImport("durable_actor", durable_module);
    sqlite_module.addIncludePath(sqlite_source.path(""));

    const typescript_module = b.createModule(.{
        .root_source_file = b.path("src/typescript/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    typescript_module.addImport("durable_actor", durable_module);
    typescript_module.addImport("durable_actor_sqlite", sqlite_module);
    linkBundledSqlite(typescript_module, sqlite_library);

    const typescript_library = b.addLibrary(.{
        .name = "aktorz",
        .linkage = .dynamic,
        .root_module = typescript_module,
    });
    const install_typescript_library = b.addInstallArtifact(typescript_library, .{});
    const typescript_step = b.step("typescript-native", "Build the native TypeScript FFI library");
    typescript_step.dependOn(&install_typescript_library.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/durable_actor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests (core + examples + TypeScript ABI)");
    test_step.dependOn(&run_unit_tests.step);

    const typescript_test_module = b.createModule(.{
        .root_source_file = b.path("src/typescript/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    typescript_test_module.addImport("durable_actor", durable_module);
    typescript_test_module.addImport("durable_actor_sqlite", sqlite_module);
    linkBundledSqlite(typescript_test_module, sqlite_library);
    const typescript_tests = b.addTest(.{ .root_module = typescript_test_module });
    test_step.dependOn(&b.addRunArtifact(typescript_tests).step);

    const cart_example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/cart_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cart_example_tests.root_module.addImport("durable_actor", durable_module);
    test_step.dependOn(&b.addRunArtifact(cart_example_tests).step);

    const bank_example_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/bank_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bank_example_tests.root_module.addImport("durable_actor", durable_module);
    test_step.dependOn(&b.addRunArtifact(bank_example_tests).step);

    const sqlite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sqlite_store.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sqlite_tests.root_module.addImport("durable_actor", durable_module);
    sqlite_tests.root_module.addIncludePath(sqlite_source.path(""));
    linkBundledSqlite(sqlite_tests.root_module, sqlite_library);

    const run_sqlite_tests = b.addRunArtifact(sqlite_tests);
    const sqlite_test_step = b.step("sqlite-test", "Run SQLite-backed durable_actor tests");
    sqlite_test_step.dependOn(&run_sqlite_tests.step);

    const benchmark_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/benchmark_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmark_tests.root_module.addImport("durable_actor", durable_module);
    benchmark_tests.root_module.addImport("durable_actor_sqlite", sqlite_module);
    linkBundledSqlite(benchmark_tests.root_module, sqlite_library);
    sqlite_test_step.dependOn(&b.addRunArtifact(benchmark_tests).step);

    const gateway_example = b.addExecutable(.{
        .name = "cart_tcp_gateway",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/cart_tcp_gateway.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gateway_example.root_module.addImport("durable_actor", durable_module);
    b.installArtifact(gateway_example);

    const run_gateway = b.addRunArtifact(gateway_example);
    if (b.args) |args| {
        run_gateway.addArgs(args);
    }

    const gateway_step = b.step("cart-gateway", "Run the tiny cart TCP gateway example");
    gateway_step.dependOn(&run_gateway.step);

    const sqlite_gateway_example = b.addExecutable(.{
        .name = "cart_sqlite_gateway",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/cart_sqlite_gateway.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sqlite_gateway_example.root_module.addImport("durable_actor", durable_module);
    sqlite_gateway_example.root_module.addImport("durable_actor_sqlite", sqlite_module);
    linkBundledSqlite(sqlite_gateway_example.root_module, sqlite_library);
    b.installArtifact(sqlite_gateway_example);

    const run_sqlite_gateway = b.addRunArtifact(sqlite_gateway_example);
    if (b.args) |args| {
        run_sqlite_gateway.addArgs(args);
    }

    const sqlite_gateway_step = b.step("cart-sqlite-gateway", "Run the cart TCP gateway backed by SQLite");
    sqlite_gateway_step.dependOn(&run_sqlite_gateway.step);

    const benchmark_example = b.addExecutable(.{
        .name = "aktorz_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmark_example.root_module.addImport("durable_actor", durable_module);
    benchmark_example.root_module.addImport("durable_actor_sqlite", sqlite_module);
    linkBundledSqlite(benchmark_example.root_module, sqlite_library);
    b.installArtifact(benchmark_example);

    const run_benchmark = b.addRunArtifact(benchmark_example);
    if (b.args) |args| {
        run_benchmark.addArgs(args);
    }

    const benchmark_step = b.step("bench", "Run the aktorz benchmark scenarios");
    benchmark_step.dependOn(&run_benchmark.step);

    const bank_gateway_example = b.addExecutable(.{
        .name = "bank_tcp_gateway",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/bank_tcp_gateway.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bank_gateway_example.root_module.addImport("durable_actor", durable_module);
    b.installArtifact(bank_gateway_example);

    const run_bank_gateway = b.addRunArtifact(bank_gateway_example);
    if (b.args) |args| {
        run_bank_gateway.addArgs(args);
    }

    const bank_gateway_step = b.step("bank-gateway", "Run the bank account TCP gateway example");
    bank_gateway_step.dependOn(&run_bank_gateway.step);
}
