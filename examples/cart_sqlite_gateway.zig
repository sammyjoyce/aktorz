const std = @import("std");
const durable = @import("durable_actor");
const durable_sqlite = @import("durable_actor_sqlite");
const CartService = @import("cart_example.zig").CartService;

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args_it = std.process.Args.Iterator.init(init.args);
    _ = args_it.next(); // skip program name
    const db_path = args_it.next() orelse "actors.sqlite3";

    var store = try durable_sqlite.SQLiteNodeStore.init(gpa, db_path, .{
        .busy_timeout_ms = 5_000,
        .enable_wal = true,
        .synchronous = .full,
    });
    defer store.deinit();

    var runtime = durable.Runtime.init(gpa, store.asStoreProvider(), .{
        .snapshot_every = 64,
    });
    defer runtime.deinit();
    defer runtime.shutdown() catch unreachable;

    try runtime.registerFactory("cart", durable.Factory.from(CartService, CartService.create));

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var gateway = durable.TinyGateway.init(gpa, &runtime, .{
        .max_payload_bytes = 64 * 1024,
    });

    var tcp = durable.TcpGateway.init(gpa, io, &gateway, .{});
    const bind = std.Io.net.IpAddress{
        .ip4 = std.Io.net.Ip4Address.unspecified(7070),
    };

    std.debug.print(
        "cart gateway listening on 0.0.0.0:7070 using SQLite db {s}\n" ++
            "protocol:\n" ++
            "  kind: cart\\n" ++
            "  key: acme:customer-42\\n" ++
            "  message-id: 1\\n" ++
            "  content-length: 20\\n" ++
            "  \\n" ++
            "  add|red-socks|2|1299\n",
        .{db_path},
    );

    try tcp.serveForever(bind);
}
