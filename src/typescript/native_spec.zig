const std = @import("std");

/// C ABI version exported by `aktorz_abi_version` and checked by the TypeScript loader.
/// Keep `typescript/native-spec.ts` in lockstep; `zig build test` verifies the twin.
pub const abi_version: u32 = 3;

pub const NativeTarget = struct {
    key: []const u8,
    zig: []const u8,
    file: []const u8,
};

/// Packaged TypeScript shared-library matrix. Keys and filenames must match
/// `NATIVE_LIBRARY_TARGETS` in `typescript/native-spec.ts`.
pub const targets = [_]NativeTarget{
    .{ .key = "darwin-arm64", .zig = "aarch64-macos", .file = "libaktorz.dylib" },
    .{ .key = "darwin-x64", .zig = "x86_64-macos", .file = "libaktorz.dylib" },
    .{ .key = "linux-arm64-gnu", .zig = "aarch64-linux-gnu.2.17", .file = "libaktorz.so" },
    .{ .key = "linux-x64-gnu", .zig = "x86_64-linux-gnu.2.17", .file = "libaktorz.so" },
    .{ .key = "linux-arm64-musl", .zig = "aarch64-linux-musl", .file = "libaktorz.so" },
    .{ .key = "linux-x64-musl", .zig = "x86_64-linux-musl", .file = "libaktorz.so" },
    .{ .key = "win32-arm64", .zig = "aarch64-windows-gnu", .file = "aktorz.dll" },
    .{ .key = "win32-x64", .zig = "x86_64-windows-gnu", .file = "aktorz.dll" },
};

pub fn targetByKey(key: []const u8) ?NativeTarget {
    for (targets) |target| {
        if (std.mem.eql(u8, target.key, key)) return target;
    }
    return null;
}

test "packaged native target triples parse" {
    for (targets) |target| {
        _ = try std.Target.Query.parse(.{ .arch_os_abi = target.zig });
    }
}
