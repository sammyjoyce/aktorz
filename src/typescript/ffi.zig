const std = @import("std");
const core = @import("durable_actor");

const Allocator = std.mem.Allocator;
// ziglint-ignore: Z006 - C ABI constant name is part of the public header contract.
const ABI_VERSION: u32 = 2;
const page_allocator = std.heap.page_allocator;

const Operation = enum(u32) {
    create = 1,
    destroy = 2,
    load_snapshot = 3,
    make_snapshot = 4,
    decide = 5,
    apply = 6,
    get_error = 7,
};

const ResultKind = enum(u32) {
    ok = 0,
    reply = 1,
    no_reply = 2,
    false_value = 3,
    true_value = 4,
    error_value = 255,
};

const DispatchFn = *const fn (
    context: u64,
    operation: u32,
    call_id: u64,
    service_id: u64,
    input1_ptr: ?[*]const u8,
    input1_len: u64,
    input2_ptr: ?[*]const u8,
    input2_len: u64,
    output_ptr: ?[*]u8,
    output_capacity: u64,
) callconv(.c) i64;

const NativeResult = struct {
    kind: ResultKind,
    bytes: []u8,

    fn create(kind: ResultKind, bytes: []const u8) !*NativeResult {
        const created = try page_allocator.create(NativeResult);
        errdefer page_allocator.destroy(created);
        created.* = .{
            .kind = kind,
            .bytes = try page_allocator.dupe(u8, bytes),
        };
        return created;
    }

    fn destroy(self: *NativeResult) void {
        page_allocator.free(self.bytes);
        page_allocator.destroy(self);
    }
};

const Bridge = struct {
    alloc: Allocator,
    dispatch: DispatchFn,
    context: u64,
    next_call_id: u64 = 1,
    last_error: ?[]u8 = null,

    fn init(alloc: Allocator, dispatch: DispatchFn, context: u64) Bridge {
        return .{
            .alloc = alloc,
            .dispatch = dispatch,
            .context = context,
        };
    }

    fn deinit(self: *Bridge) void {
        self.clearLastError();
        self.* = undefined;
    }

    fn clearLastError(self: *Bridge) void {
        if (self.last_error) |message| self.alloc.free(message);
        self.last_error = null;
    }

    fn setLastError(self: *Bridge, message: []const u8) void {
        self.clearLastError();
        self.last_error = self.alloc.dupe(u8, message) catch null;
    }

    fn nextCallId(self: *Bridge) u64 {
        const call_id = self.next_call_id;
        self.next_call_id +%= 1;
        if (self.next_call_id == 0) self.next_call_id = 1;
        return call_id;
    }

    fn call(
        self: *Bridge,
        operation: Operation,
        service_id: u64,
        input1: []const u8,
        input2: []const u8,
    ) !core.OwnedBytes {
        self.clearLastError();
        const call_id = self.nextCallId();
        const required = self.dispatch(
            self.context,
            @intFromEnum(operation),
            call_id,
            service_id,
            optionalConstPointer(input1),
            @intCast(input1.len),
            optionalConstPointer(input2),
            @intCast(input2.len),
            null,
            0,
        );
        if (required < 0) {
            self.captureError(call_id);
            return error.TypeScriptCallbackFailed;
        }

        const required_len = std.math.cast(usize, required) orelse {
            self.setLastError("TypeScript callback output is too large for this platform");
            return error.CallbackOutputTooLarge;
        };
        const bytes = try self.alloc.alloc(u8, required_len);
        errdefer self.alloc.free(bytes);

        if (required_len > 0) {
            const written = self.dispatch(
                self.context,
                @intFromEnum(operation),
                call_id,
                service_id,
                optionalConstPointer(input1),
                @intCast(input1.len),
                optionalConstPointer(input2),
                @intCast(input2.len),
                bytes.ptr,
                @intCast(bytes.len),
            );
            if (written < 0) {
                self.captureError(call_id);
                return error.TypeScriptCallbackFailed;
            }
            if (written != required) {
                self.setLastError("TypeScript callback changed its output length between ABI calls");
                return error.CallbackOutputLengthChanged;
            }
        }

        return .{ .allocator = self.alloc, .bytes = bytes };
    }

    fn captureError(self: *Bridge, call_id: u64) void {
        self.clearLastError();
        const required = self.dispatch(
            self.context,
            @intFromEnum(Operation.get_error),
            call_id,
            0,
            null,
            0,
            null,
            0,
            null,
            0,
        );
        if (required <= 0) {
            self.setLastError("TypeScript actor callback failed");
            return;
        }

        const required_len = std.math.cast(usize, required) orelse {
            self.setLastError("TypeScript callback error is too large for this platform");
            return;
        };
        const message = self.alloc.alloc(u8, required_len) catch {
            self.setLastError("TypeScript actor callback failed (error allocation failed)");
            return;
        };
        const written = self.dispatch(
            self.context,
            @intFromEnum(Operation.get_error),
            call_id,
            0,
            null,
            0,
            null,
            0,
            message.ptr,
            @intCast(message.len),
        );
        if (written != required) {
            self.alloc.free(message);
            self.setLastError("TypeScript actor callback failed (error transfer failed)");
            return;
        }
        self.last_error = message;
    }
};

threadlocal var active_bridge: ?*Bridge = null;

const BridgeService = struct {
    bridge: *Bridge,
    service_id: u64,

    pub fn create(alloc: Allocator, address: core.Address) !*BridgeService {
        const bridge = active_bridge orelse return error.MissingTypeScriptBridge;
        const response = try bridge.call(.create, 0, address.kind, address.key);
        defer response.deinit();
        if (response.bytes.len != @sizeOf(u64)) return error.InvalidTypeScriptServiceId;

        const service_id = readU64(response.bytes, 0);
        const service = alloc.create(BridgeService) catch |err| {
            if (bridge.call(.destroy, service_id, &.{}, &.{})) |cleanup| {
                cleanup.deinit();
            } else |_| {}
            return err;
        };
        service.* = .{
            .bridge = bridge,
            .service_id = service_id,
        };
        return service;
    }

    pub fn destroy(self: *BridgeService, alloc: Allocator) void {
        if (self.bridge.call(.destroy, self.service_id, &.{}, &.{})) |response| {
            response.deinit();
        } else |_| {}
        alloc.destroy(self);
    }

    pub fn loadSnapshot(self: *BridgeService, bytes: []const u8) !void {
        const response = try self.bridge.call(.load_snapshot, self.service_id, bytes, &.{});
        defer response.deinit();
        if (response.bytes.len != 0) return error.UnexpectedTypeScriptCallbackOutput;
    }

    pub fn makeSnapshot(self: *BridgeService, alloc: Allocator) !core.OwnedBytes {
        _ = alloc;
        return try self.bridge.call(.make_snapshot, self.service_id, &.{}, &.{});
    }

    pub fn decide(self: *BridgeService, alloc: Allocator, message: []const u8) !core.Decision {
        const response = try self.bridge.call(.decide, self.service_id, message, &.{});
        defer response.deinit();
        return try decodeDecision(alloc, response.bytes);
    }

    pub fn apply(self: *BridgeService, mutation: []const u8) !void {
        const response = try self.bridge.call(.apply, self.service_id, mutation, &.{});
        defer response.deinit();
        if (response.bytes.len != 0) return error.UnexpectedTypeScriptCallbackOutput;
    }
};

const RuntimeHandle = struct {
    bridge: Bridge,
    store: core.MemoryNodeStore,
    runtime: core.Runtime,
};

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_abi_version() u32 {
    return ABI_VERSION;
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_runtime_create_memory(
    dispatch: ?DispatchFn,
    context: u64,
    snapshot_every: u32,
) ?*RuntimeHandle {
    const callback = dispatch orelse return null;
    const handle = page_allocator.create(RuntimeHandle) catch return null;
    handle.bridge = Bridge.init(page_allocator, callback, context);
    handle.store = core.MemoryNodeStore.init(page_allocator);
    handle.runtime = core.Runtime.init(
        page_allocator,
        handle.store.asStoreProvider(),
        .{ .snapshot_every = snapshot_every },
    );
    return handle;
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_runtime_destroy(handle: ?*RuntimeHandle) void {
    const runtime_handle = handle orelse return;
    const previous_bridge = active_bridge;
    active_bridge = &runtime_handle.bridge;
    defer active_bridge = previous_bridge;

    runtime_handle.runtime.shutdown() catch {};
    runtime_handle.runtime.deinit();
    runtime_handle.store.deinit();
    runtime_handle.bridge.deinit();
    page_allocator.destroy(runtime_handle);
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_runtime_register(
    handle: ?*RuntimeHandle,
    kind_ptr: ?[*]const u8,
    kind_len: u64,
) ?*NativeResult {
    const runtime_handle = handle orelse return null;
    runtime_handle.bridge.clearLastError();
    const kind = inputSlice(kind_ptr, kind_len) catch |err| return resultFromError(runtime_handle, err);
    runtime_handle.runtime.registerFactory(kind, core.Factory.from(BridgeService, BridgeService.create)) catch |err| {
        return resultFromError(runtime_handle, err);
    };
    return result(.ok, &.{});
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_runtime_request(
    handle: ?*RuntimeHandle,
    kind_ptr: ?[*]const u8,
    kind_len: u64,
    key_ptr: ?[*]const u8,
    key_len: u64,
    message_id_ptr: ?[*]const u8,
    message_id_len: u64,
    payload_ptr: ?[*]const u8,
    payload_len: u64,
) ?*NativeResult {
    const runtime_handle = handle orelse return null;
    runtime_handle.bridge.clearLastError();
    const kind = inputSlice(kind_ptr, kind_len) catch |err| return resultFromError(runtime_handle, err);
    const key = inputSlice(key_ptr, key_len) catch |err| return resultFromError(runtime_handle, err);
    const message_id_bytes = inputSlice(message_id_ptr, message_id_len) catch |err| return resultFromError(runtime_handle, err);
    const message_id = decodeMessageId(message_id_bytes) catch |err| return resultFromError(runtime_handle, err);
    const payload = inputSlice(payload_ptr, payload_len) catch |err| return resultFromError(runtime_handle, err);

    const previous_bridge = active_bridge;
    active_bridge = &runtime_handle.bridge;
    defer active_bridge = previous_bridge;

    const reply = runtime_handle.runtime.request(
        .{ .kind = kind, .key = key },
        message_id,
        payload,
    ) catch |err| return resultFromError(runtime_handle, err);

    if (reply) |owned_reply| {
        defer owned_reply.deinit();
        return result(.reply, owned_reply.bytes);
    }
    return result(.no_reply, &.{});
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_runtime_tell(
    handle: ?*RuntimeHandle,
    kind_ptr: ?[*]const u8,
    kind_len: u64,
    key_ptr: ?[*]const u8,
    key_len: u64,
    message_id_ptr: ?[*]const u8,
    message_id_len: u64,
    payload_ptr: ?[*]const u8,
    payload_len: u64,
) ?*NativeResult {
    const runtime_handle = handle orelse return null;
    runtime_handle.bridge.clearLastError();
    const kind = inputSlice(kind_ptr, kind_len) catch |err| return resultFromError(runtime_handle, err);
    const key = inputSlice(key_ptr, key_len) catch |err| return resultFromError(runtime_handle, err);
    const message_id_bytes = inputSlice(message_id_ptr, message_id_len) catch |err| return resultFromError(runtime_handle, err);
    const message_id = decodeMessageId(message_id_bytes) catch |err| return resultFromError(runtime_handle, err);
    const payload = inputSlice(payload_ptr, payload_len) catch |err| return resultFromError(runtime_handle, err);

    const previous_bridge = active_bridge;
    active_bridge = &runtime_handle.bridge;
    defer active_bridge = previous_bridge;

    runtime_handle.runtime.tell(
        .{ .kind = kind, .key = key },
        message_id,
        payload,
    ) catch |err| return resultFromError(runtime_handle, err);
    return result(.ok, &.{});
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_runtime_passivate(
    handle: ?*RuntimeHandle,
    kind_ptr: ?[*]const u8,
    kind_len: u64,
    key_ptr: ?[*]const u8,
    key_len: u64,
) ?*NativeResult {
    const runtime_handle = handle orelse return null;
    runtime_handle.bridge.clearLastError();
    const kind = inputSlice(kind_ptr, kind_len) catch |err| return resultFromError(runtime_handle, err);
    const key = inputSlice(key_ptr, key_len) catch |err| return resultFromError(runtime_handle, err);

    const previous_bridge = active_bridge;
    active_bridge = &runtime_handle.bridge;
    defer active_bridge = previous_bridge;

    const passivated = runtime_handle.runtime.passivate(.{ .kind = kind, .key = key }) catch |err| {
        return resultFromError(runtime_handle, err);
    };
    return result(if (passivated) .true_value else .false_value, &.{});
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_runtime_passivate_idle(
    handle: ?*RuntimeHandle,
    minimum_idle_ticks_ptr: ?[*]const u8,
    minimum_idle_ticks_len: u64,
) ?*NativeResult {
    const runtime_handle = handle orelse return null;
    runtime_handle.bridge.clearLastError();
    const minimum_idle_ticks_bytes = inputSlice(minimum_idle_ticks_ptr, minimum_idle_ticks_len) catch |err| {
        return resultFromError(runtime_handle, err);
    };
    const minimum_idle_ticks = decodeU64(minimum_idle_ticks_bytes) catch |err| {
        return resultFromError(runtime_handle, err);
    };

    const previous_bridge = active_bridge;
    active_bridge = &runtime_handle.bridge;
    defer active_bridge = previous_bridge;

    runtime_handle.runtime.passivateIdle(minimum_idle_ticks) catch |err| {
        return resultFromError(runtime_handle, err);
    };
    return result(.ok, &.{});
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_runtime_shutdown(handle: ?*RuntimeHandle) ?*NativeResult {
    const runtime_handle = handle orelse return null;
    runtime_handle.bridge.clearLastError();

    const previous_bridge = active_bridge;
    active_bridge = &runtime_handle.bridge;
    defer active_bridge = previous_bridge;

    runtime_handle.runtime.shutdown() catch |err| return resultFromError(runtime_handle, err);
    return result(.ok, &.{});
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_result_kind(native_result: ?*const NativeResult) u32 {
    const value = native_result orelse return @intFromEnum(ResultKind.error_value);
    return @intFromEnum(value.kind);
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_result_data(native_result: ?*const NativeResult) ?[*]const u8 {
    const value = native_result orelse return null;
    return optionalConstPointer(value.bytes);
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_result_length(native_result: ?*const NativeResult) u64 {
    const value = native_result orelse return 0;
    return @intCast(value.bytes.len);
}

// ziglint-ignore: Z001 - C ABI symbol name; renaming would break the ABI.
pub export fn aktorz_result_destroy(native_result: ?*NativeResult) void {
    const value = native_result orelse return;
    value.destroy();
}

fn result(kind: ResultKind, bytes: []const u8) ?*NativeResult {
    return NativeResult.create(kind, bytes) catch null;
}

fn resultFromError(handle: *RuntimeHandle, err: anyerror) ?*NativeResult {
    const message = if (handle.bridge.last_error) |callback_error| callback_error else @errorName(err);
    const native_result = result(.error_value, message);
    handle.bridge.clearLastError();
    return native_result;
}

fn inputSlice(pointer: ?[*]const u8, length: u64) ![]const u8 {
    const native_length = std.math.cast(usize, length) orelse return error.InputTooLarge;
    if (native_length == 0) return &.{};
    const bytes = pointer orelse return error.NullInputPointer;
    return bytes[0..native_length];
}

fn optionalConstPointer(bytes: []const u8) ?[*]const u8 {
    return if (bytes.len == 0) null else bytes.ptr;
}

fn joinMessageId(high: u64, low: u64) u128 {
    return (@as(u128, high) << 64) | @as(u128, low);
}

fn decodeMessageId(bytes: []const u8) !u128 {
    if (bytes.len != @sizeOf(u128)) return error.InvalidMessageIdLength;
    return joinMessageId(readU64(bytes, 8), readU64(bytes, 0));
}

fn decodeU64(bytes: []const u8) !u64 {
    if (bytes.len != @sizeOf(u64)) return error.InvalidU64Length;
    return readU64(bytes, 0);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

fn decodeDecision(alloc: Allocator, bytes: []const u8) !core.Decision {
    if (bytes.len < 17) return error.InvalidTypeScriptDecision;
    const flags = bytes[0];
    if ((flags & ~@as(u8, 0b11)) != 0) return error.InvalidTypeScriptDecision;

    const mutation_len = std.math.cast(usize, readU64(bytes, 1)) orelse return error.InvalidTypeScriptDecision;
    const reply_len = std.math.cast(usize, readU64(bytes, 9)) orelse return error.InvalidTypeScriptDecision;
    const payload_len = bytes.len - 17;
    if (mutation_len > payload_len) return error.InvalidTypeScriptDecision;
    if (reply_len > payload_len - mutation_len) return error.InvalidTypeScriptDecision;
    if (mutation_len + reply_len != payload_len) return error.InvalidTypeScriptDecision;

    const has_mutation = (flags & 0b01) != 0;
    const has_reply = (flags & 0b10) != 0;
    if (!has_mutation and mutation_len != 0) return error.InvalidTypeScriptDecision;
    if (!has_reply and reply_len != 0) return error.InvalidTypeScriptDecision;

    var decision: core.Decision = .{};
    errdefer decision.deinit();
    if (has_mutation) {
        decision.mutation = try core.OwnedBytes.clone(alloc, bytes[17 .. 17 + mutation_len]);
    }
    if (has_reply) {
        const reply_start = 17 + mutation_len;
        decision.reply = try core.OwnedBytes.clone(alloc, bytes[reply_start .. reply_start + reply_len]);
    }
    return decision;
}

test "message identifiers retain all 128 bits" {
    const bytes = [_]u8{
        0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
        0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01,
    };
    try std.testing.expectEqual(
        @as(u128, 0x0123456789abcdef_fedcba9876543210),
        try decodeMessageId(&bytes),
    );
}

test "decision envelopes preserve empty present values" {
    var bytes = [_]u8{0} ** 17;
    bytes[0] = 0b11;
    var decision = try decodeDecision(std.testing.allocator, &bytes);
    defer decision.deinit();
    try std.testing.expect(decision.mutation != null);
    try std.testing.expect(decision.reply != null);
    try std.testing.expectEqual(@as(usize, 0), decision.mutation.?.bytes.len);
    try std.testing.expectEqual(@as(usize, 0), decision.reply.?.bytes.len);
}
