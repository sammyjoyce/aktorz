const core = @import("core.zig");

pub const Allocator = core.Allocator;
pub const OwnedBytes = core.OwnedBytes;
pub const Address = core.Address;
pub const allocObjectId = core.allocObjectId;
pub const Decision = core.Decision;
pub const Service = core.Service;
pub const Factory = core.Factory;
pub const ScopedStore = core.ScopedStore;
pub const StoreProvider = core.StoreProvider;
pub const Route = core.Route;
pub const Resolver = core.Resolver;
pub const RemoteRequest = core.RemoteRequest;
pub const Forwarder = core.Forwarder;
pub const Runtime = core.Runtime;

pub const MemoryNodeStore = @import("memory_store.zig").MemoryNodeStore;
pub const TinyGateway = @import("tiny_gateway.zig").TinyGateway;
pub const TcpGateway = @import("tiny_gateway.zig").TcpGateway;

test {
    _ = @import("memory_store.zig");
    _ = @import("tiny_gateway.zig");
}
