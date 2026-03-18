const std = @import("std");
const durable = @import("durable_actor");
const BankAccountService = @import("bank_example.zig").BankAccountService;

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var store = durable.MemoryNodeStore.init(gpa);
    defer store.deinit();

    var runtime = durable.Runtime.init(gpa, store.asStoreProvider(), .{
        .snapshot_every = 64,
    });
    defer runtime.deinit();
    defer runtime.shutdown() catch unreachable;

    try runtime.registerFactory("bank", durable.Factory.from(BankAccountService, BankAccountService.create));

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
        "bank gateway listening on 0.0.0.0:7070\n" ++
            "protocol:\n" ++
            "  kind: bank\\n\n" ++
            "  key: <account-id>\\n\n" ++
            "  message-id: <id>\\n\n" ++
            "  content-length: <len>\\n\n" ++
            "  \\n\n" ++
            "  <command>\n" ++
            "commands:\n" ++
            "  deposit|<cents>|<memo>\n" ++
            "  withdraw|<cents>|<memo>\n" ++
            "  set_overdraft|<cents>\n" ++
            "  freeze|<reason>\n" ++
            "  unfreeze\n" ++
            "  close\n" ++
            "  balance\n" ++
            "  statement\n" ++
            "example:\n" ++
            "  printf 'kind: bank\\nkey: acme:checking\\nmessage-id: 1\\ncontent-length: 24\\n\\ndeposit|50000|big savings' | nc localhost 7070\n",
        .{},
    );

    try tcp.serveForever(bind);
}
