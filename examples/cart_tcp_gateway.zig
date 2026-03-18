const std = @import("std");
const durable = @import("durable_actor");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var store = durable.MemoryNodeStore.init(gpa);
    defer store.deinit();

    var runtime = durable.Runtime.init(gpa, store.asStoreProvider(), .{
        .snapshot_every = 64,
    });
    defer runtime.deinit();
    defer runtime.shutdown() catch unreachable;

    try runtime.registerFactory("cart", durable.Factory.from(durable.CartService, durable.CartService.create));

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var gateway = durable.TinyGateway.init(gpa, &runtime, .{
        .max_payload_bytes = 64 * 1024,
    });

    var tcp = durable.TcpGateway.init(gpa, io, &gateway, .{});
    const bind = std.Io.net.IpAddress{
        .ip4 = std.Io.net.Ip4Address.unspecified(7000),
    };

    std.debug.print(
        "cart gateway listening on 0.0.0.0:7000\n" ++
            "protocol:\n" ++
            "  kind: cart\\n" ++
            "  key: acme:customer-42\\n" ++
            "  message-id: 1\\n" ++
            "  content-length: 20\\n" ++
            "  \\n" ++
            "  add|red-socks|2|1299\n",
        .{},
    );

    try tcp.serveForever(bind);
}
