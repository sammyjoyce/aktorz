const std = @import("std");
const core = @import("core.zig");

const Allocator = std.mem.Allocator;

const SnapshotRecord = struct {
    seq: u64,
    bytes: []u8,
};

const WalEntry = struct {
    seq: u64,
    message_id: u128,
    mutation: []u8,
};

const SeenRecord = struct {
    seq: u64,
    reply: ?[]u8,
};

const StoredObject = struct {
    alloc: Allocator,
    snapshot: ?SnapshotRecord = null,
    wal: std.ArrayList(WalEntry) = .empty,
    seen: std.AutoHashMap(u128, SeenRecord),

    fn init(alloc: Allocator) StoredObject {
        return .{
            .alloc = alloc,
            .snapshot = null,
            .wal = .empty,
            .seen = std.AutoHashMap(u128, SeenRecord).init(alloc),
        };
    }

    fn deinit(self: *StoredObject) void {
        if (self.snapshot) |snapshot| {
            self.alloc.free(snapshot.bytes);
        }

        for (self.wal.items) |entry| {
            self.alloc.free(entry.mutation);
        }
        self.wal.deinit(self.alloc);

        var it = self.seen.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.reply) |reply| {
                self.alloc.free(reply);
            }
        }
        self.seen.deinit();
    }
};

const MemoryScopedStore = struct {
    alloc: Allocator,
    object: *StoredObject,

    fn destroy(self: *MemoryScopedStore, alloc: Allocator) void {
        _ = self.alloc;
        alloc.destroy(self);
    }

    fn loadSnapshot(self: *MemoryScopedStore, alloc: Allocator) !?core.ScopedStore.Snapshot {
        if (self.object.snapshot) |snapshot| {
            return .{
                .last_seq = snapshot.seq,
                .bytes = try core.OwnedBytes.clone(alloc, snapshot.bytes),
            };
        }
        return null;
    }

    fn replayAfter(self: *MemoryScopedStore, after_seq: u64, replay_ctx: *anyopaque, replay_fn: core.ScopedStore.ReplayFn) !void {
        for (self.object.wal.items) |entry| {
            if (entry.seq > after_seq) {
                try replay_fn(replay_ctx, entry.seq, entry.mutation);
            }
        }
    }

    fn appendOnce(self: *MemoryScopedStore, alloc: Allocator, intent: core.ScopedStore.AppendIntent) !core.ScopedStore.AppendResult {
        if (self.object.seen.get(intent.message_id)) |seen| {
            return .{ .duplicate = if (seen.reply) |reply| try core.OwnedBytes.clone(alloc, reply) else null };
        }

        const mutation_copy = try self.object.alloc.dupe(u8, intent.mutation);
        errdefer self.object.alloc.free(mutation_copy);

        const reply_copy = if (intent.reply) |reply| try self.object.alloc.dupe(u8, reply) else null;
        errdefer if (reply_copy) |reply| self.object.alloc.free(reply);

        try self.object.wal.append(self.object.alloc, .{
            .seq = intent.seq,
            .message_id = intent.message_id,
            .mutation = mutation_copy,
        });
        errdefer {
            const removed = self.object.wal.orderedRemove(self.object.wal.items.len - 1);
            self.object.alloc.free(removed.mutation);
        }

        try self.object.seen.put(intent.message_id, .{
            .seq = intent.seq,
            .reply = reply_copy,
        });

        return .inserted;
    }

    fn writeSnapshot(self: *MemoryScopedStore, at_seq: u64, bytes: []const u8) !void {
        const copy = try self.object.alloc.dupe(u8, bytes);
        errdefer self.object.alloc.free(copy);

        if (self.object.snapshot) |old| {
            self.object.alloc.free(old.bytes);
        }

        self.object.snapshot = .{
            .seq = at_seq,
            .bytes = copy,
        };
    }

    fn compactBefore(self: *MemoryScopedStore, first_live_seq: u64) !void {
        while (self.object.wal.items.len > 0 and self.object.wal.items[0].seq < first_live_seq) {
            const removed = self.object.wal.orderedRemove(0);
            self.object.alloc.free(removed.mutation);
        }
    }
};

pub const MemoryNodeStore = struct {
    alloc: Allocator,
    objects: std.StringHashMap(*StoredObject),

    pub fn init(alloc: Allocator) MemoryNodeStore {
        return .{
            .alloc = alloc,
            .objects = std.StringHashMap(*StoredObject).init(alloc),
        };
    }

    pub fn deinit(self: *MemoryNodeStore) void {
        var it = self.objects.iterator();
        while (it.next()) |entry| {
            const object = entry.value_ptr.*;
            object.deinit();
            self.alloc.destroy(object);
            self.alloc.free(entry.key_ptr.*);
        }
        self.objects.deinit();
        self.* = undefined;
    }

    pub fn asStoreProvider(self: *MemoryNodeStore) core.StoreProvider {
        return .{
            .ptr = self,
            .open_fn = openErased,
        };
    }

    fn openErased(ctx: *anyopaque, alloc: Allocator, object_id: []const u8) anyerror!core.ScopedStore {
        const self: *MemoryNodeStore = @ptrCast(@alignCast(ctx));
        return try self.openScoped(alloc, object_id);
    }

    fn openScoped(self: *MemoryNodeStore, alloc: Allocator, object_id: []const u8) !core.ScopedStore {
        const object = try self.getOrCreateObject(object_id);
        const scope = try alloc.create(MemoryScopedStore);
        scope.* = .{
            .alloc = alloc,
            .object = object,
        };
        return core.ScopedStore.from(MemoryScopedStore, scope);
    }

    fn getOrCreateObject(self: *MemoryNodeStore, object_id: []const u8) !*StoredObject {
        if (self.objects.get(object_id)) |object| {
            return object;
        }

        const key = try self.alloc.dupe(u8, object_id);
        errdefer self.alloc.free(key);

        const object = try self.alloc.create(StoredObject);
        errdefer self.alloc.destroy(object);
        object.* = StoredObject.init(self.alloc);
        errdefer object.deinit();

        try self.objects.put(key, object);
        return object;
    }
};
