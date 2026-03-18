const std = @import("std");
const durable = @import("core.zig");
const MemoryNodeStore = @import("memory_store.zig").MemoryNodeStore;

const Allocator = std.mem.Allocator;

const Line = struct {
    qty: u32,
    unit_price_cents: u32,
};

pub const CartService = struct {
    alloc: Allocator,
    items: std.StringHashMap(Line),
    checked_out: bool = false,

    pub fn create(alloc: Allocator, address: durable.Address) !*CartService {
        _ = address;
        const self = try alloc.create(CartService);
        self.* = .{
            .alloc = alloc,
            .items = std.StringHashMap(Line).init(alloc),
            .checked_out = false,
        };
        return self;
    }

    pub fn destroy(self: *CartService, alloc: Allocator) void {
        var it = self.items.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }
        self.items.deinit();
        alloc.destroy(self);
    }

    pub fn loadSnapshot(self: *CartService, bytes: []const u8) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const first = lines.first();
        if (std.mem.eql(u8, first, "checked_out=1")) {
            self.checked_out = true;
        } else if (std.mem.eql(u8, first, "checked_out=0")) {
            self.checked_out = false;
        } else if (first.len != 0) {
            return error.InvalidSnapshot;
        }

        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try self.loadLine(line);
        }
    }

    pub fn makeSnapshot(self: *CartService, alloc: Allocator) !durable.OwnedBytes {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);

        try out.appendSlice(alloc, if (self.checked_out) "checked_out=1\n" else "checked_out=0\n");

        var it = self.items.iterator();
        while (it.next()) |entry| {
            var qty_buf: [32]u8 = undefined;
            const qty_txt = try std.fmt.bufPrint(&qty_buf, "{d}", .{entry.value_ptr.qty});

            var price_buf: [32]u8 = undefined;
            const price_txt = try std.fmt.bufPrint(&price_buf, "{d}", .{entry.value_ptr.unit_price_cents});

            try out.appendSlice(alloc, entry.key_ptr.*);
            try out.appendSlice(alloc, "|");
            try out.appendSlice(alloc, qty_txt);
            try out.appendSlice(alloc, "|");
            try out.appendSlice(alloc, price_txt);
            try out.appendSlice(alloc, "\n");
        }

        return .fromOwned(alloc, try out.toOwnedSlice(alloc));
    }

    pub fn decide(self: *CartService, alloc: Allocator, message: []const u8) !durable.Decision {
        var parts = std.mem.splitScalar(u8, message, '|');
        const op = parts.first();

        if (std.mem.eql(u8, op, "get")) {
            return .{ .reply = try self.renderView(alloc) };
        }

        if (std.mem.eql(u8, op, "add")) {
            if (self.checked_out) {
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: cart already checked out\n") };
            }

            const sku = parts.next() orelse return error.InvalidCommand;
            const qty_txt = parts.next() orelse return error.InvalidCommand;
            const price_txt = parts.next() orelse return error.InvalidCommand;
            if (parts.next() != null) return error.InvalidCommand;

            const qty = try std.fmt.parseUnsigned(u32, qty_txt, 10);
            const price = try std.fmt.parseUnsigned(u32, price_txt, 10);

            if (qty == 0) {
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: qty must be > 0\n") };
            }

            return .{
                .mutation = .fromOwned(alloc, try std.fmt.allocPrint(alloc, "item_added|{s}|{d}|{d}", .{ sku, qty, price })),
                .reply = try durable.OwnedBytes.clone(alloc, "ok\n"),
            };
        }

        if (std.mem.eql(u8, op, "checkout")) {
            if (self.checked_out) {
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: already checked out\n") };
            }

            const order_id = parts.next() orelse return error.InvalidCommand;
            if (parts.next() != null) return error.InvalidCommand;

            return .{
                .mutation = .fromOwned(alloc, try std.fmt.allocPrint(alloc, "checked_out|{s}", .{order_id})),
                .reply = try durable.OwnedBytes.clone(alloc, "ok\n"),
            };
        }

        return error.InvalidCommand;
    }

    pub fn apply(self: *CartService, mutation: []const u8) !void {
        var parts = std.mem.splitScalar(u8, mutation, '|');
        const op = parts.first();

        if (std.mem.eql(u8, op, "item_added")) {
            const sku = parts.next() orelse return error.InvalidMutation;
            const qty_txt = parts.next() orelse return error.InvalidMutation;
            const price_txt = parts.next() orelse return error.InvalidMutation;
            if (parts.next() != null) return error.InvalidMutation;

            const qty = try std.fmt.parseUnsigned(u32, qty_txt, 10);
            const price = try std.fmt.parseUnsigned(u32, price_txt, 10);

            if (self.items.getPtr(sku)) |line| {
                line.qty += qty;
            } else {
                try self.items.put(try self.alloc.dupe(u8, sku), .{
                    .qty = qty,
                    .unit_price_cents = price,
                });
            }
            return;
        }

        if (std.mem.eql(u8, op, "checked_out")) {
            if (parts.next() == null) return error.InvalidMutation;
            self.checked_out = true;
            return;
        }

        return error.InvalidMutation;
    }

    fn loadLine(self: *CartService, line: []const u8) !void {
        var parts = std.mem.splitScalar(u8, line, '|');
        const sku = parts.first();
        const qty_txt = parts.next() orelse return error.InvalidSnapshot;
        const price_txt = parts.next() orelse return error.InvalidSnapshot;
        if (parts.next() != null) return error.InvalidSnapshot;

        try self.items.put(try self.alloc.dupe(u8, sku), .{
            .qty = try std.fmt.parseUnsigned(u32, qty_txt, 10),
            .unit_price_cents = try std.fmt.parseUnsigned(u32, price_txt, 10),
        });
    }

    fn renderView(self: *CartService, alloc: Allocator) !durable.OwnedBytes {
        var total_items: u64 = 0;
        var subtotal_cents: u64 = 0;

        var it = self.items.iterator();
        while (it.next()) |entry| {
            total_items += entry.value_ptr.qty;
            subtotal_cents += @as(u64, entry.value_ptr.qty) * @as(u64, entry.value_ptr.unit_price_cents);
        }

        return .fromOwned(alloc, try std.fmt.allocPrint(
            alloc,
            "checked_out={d}\ntotal_items={d}\nsubtotal_cents={d}\n",
            .{ @intFromBool(self.checked_out), total_items, subtotal_cents },
        ));
    }
};

test "cart runtime dedupes writes and survives passivation" {
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();

    var runtime = durable.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 1,
    });
    defer runtime.deinit();

    try runtime.registerFactory("cart", durable.Factory.from(CartService, CartService.create));

    const cart = durable.Address{
        .kind = "cart",
        .key = "acme:customer-42",
    };

    if (try runtime.request(cart, 1001, "add|red-socks|2|1299")) |reply| {
        defer reply.deinit();
        try std.testing.expectEqualStrings("ok\n", reply.bytes);
    } else {
        return error.ExpectedReply;
    }

    try std.testing.expect(try runtime.passivate(cart));

    if (try runtime.request(cart, 1001, "add|red-socks|2|1299")) |reply| {
        defer reply.deinit();
        try std.testing.expectEqualStrings("ok\n", reply.bytes);
    } else {
        return error.ExpectedReply;
    }

    const view = (try runtime.request(cart, 2001, "get")) orelse return error.ExpectedReply;
    defer view.deinit();

    try std.testing.expect(std.mem.indexOf(u8, view.bytes, "checked_out=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, view.bytes, "total_items=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, view.bytes, "subtotal_cents=2598") != null);
}
