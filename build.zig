const std = @import("std");

fn linkSqlite(mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.linkSystemLibrary("sqlite3", .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/durable_actor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run durable_actor unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const sqlite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sqlite_store.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sqlite_tests.root_module.addImport("durable_actor", durable_module);
    linkSqlite(sqlite_tests.root_module);

    const run_sqlite_tests = b.addRunArtifact(sqlite_tests);
    const sqlite_test_step = b.step("sqlite-test", "Run SQLite-backed durable_actor tests");
    sqlite_test_step.dependOn(&run_sqlite_tests.step);

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
    linkSqlite(sqlite_gateway_example.root_module);
    b.installArtifact(sqlite_gateway_example);

    const run_sqlite_gateway = b.addRunArtifact(sqlite_gateway_example);
    if (b.args) |args| {
        run_sqlite_gateway.addArgs(args);
    }

    const sqlite_gateway_step = b.step("cart-sqlite-gateway", "Run the cart TCP gateway backed by SQLite");
    sqlite_gateway_step.dependOn(&run_sqlite_gateway.step);
}
