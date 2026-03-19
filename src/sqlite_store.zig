const std = @import("std");
const durable = @import("durable_actor");
const core = durable;

const c = @cImport({
    @cInclude("sqlite3.h");
});

const Allocator = std.mem.Allocator;
const empty_byte = [_]u8{0};

const schema_sql: [:0]const u8 =
    \\CREATE TABLE IF NOT EXISTS actor_snapshot (
    \\    object_id   TEXT PRIMARY KEY,
    \\    last_seq    INTEGER NOT NULL CHECK(last_seq >= 0),
    \\    snapshot    BLOB NOT NULL
    \\);
    \\ 
    \\CREATE TABLE IF NOT EXISTS actor_wal (
    \\    object_id   TEXT NOT NULL,
    \\    seq         INTEGER NOT NULL CHECK(seq >= 0),
    \\    message_id  BLOB NOT NULL CHECK(length(message_id) = 16),
    \\    mutation    BLOB NOT NULL,
    \\    PRIMARY KEY (object_id, seq),
    \\    UNIQUE (object_id, message_id)
    \\);
    \\ 
    \\CREATE TABLE IF NOT EXISTS actor_seen_message (
    \\    object_id   TEXT NOT NULL,
    \\    message_id  BLOB NOT NULL CHECK(length(message_id) = 16),
    \\    seq         INTEGER NOT NULL CHECK(seq >= 0),
    \\    reply       BLOB,
    \\    PRIMARY KEY (object_id, message_id)
    \\);
;

const sql_load_snapshot =
    "SELECT last_seq, snapshot " ++
    "FROM actor_snapshot " ++
    "WHERE object_id = ?1";

const sql_load_snapshot_bytes =
    "SELECT snapshot " ++
    "FROM actor_snapshot " ++
    "WHERE object_id = ?1";

const sql_replay_after =
    "SELECT seq, mutation " ++
    "FROM actor_wal " ++
    "WHERE object_id = ?1 AND seq > ?2 " ++
    "ORDER BY seq ASC";

const sql_load_seen =
    "SELECT reply " ++
    "FROM actor_seen_message " ++
    "WHERE object_id = ?1 AND message_id = ?2";

const sql_insert_wal =
    "INSERT INTO actor_wal(object_id, seq, message_id, mutation) " ++
    "VALUES (?1, ?2, ?3, ?4)";

const sql_insert_seen =
    "INSERT INTO actor_seen_message(object_id, message_id, seq, reply) " ++
    "VALUES (?1, ?2, ?3, ?4)";

const sql_write_snapshot =
    "INSERT INTO actor_snapshot(object_id, last_seq, snapshot) " ++
    "VALUES (?1, ?2, ?3) " ++
    "ON CONFLICT(object_id) DO UPDATE SET " ++
    "last_seq = excluded.last_seq, " ++
    "snapshot = excluded.snapshot";

const sql_compact_wal =
    "DELETE FROM actor_wal " ++
    "WHERE object_id = ?1 AND seq < ?2";

const sql_count_actor_snapshot =
    "SELECT COUNT(*) " ++
    "FROM actor_snapshot";

const sql_count_actor_wal =
    "SELECT COUNT(*) " ++
    "FROM actor_wal";

const sql_count_actor_wal_for_object =
    "SELECT COUNT(*) " ++
    "FROM actor_wal " ++
    "WHERE object_id = ?1";

const sql_count_actor_seen_message =
    "SELECT COUNT(*) " ++
    "FROM actor_seen_message";

const sql_pragma_wal_autocheckpoint =
    "PRAGMA wal_autocheckpoint;";

pub const SQLiteNodeStore = struct {
    alloc: Allocator,
    db: *c.sqlite3,
    config: Config,

    pub const TableRowCounts = struct {
        actor_snapshot: u64,
        actor_wal: u64,
        actor_seen_message: u64,
    };

    pub const Config = struct {
        busy_timeout_ms: u32 = 5_000,
        enable_wal: bool = true,
        synchronous: Synchronous = .full,
        wal_autocheckpoint_pages: ?u32 = null,

        pub const Synchronous = enum {
            off,
            normal,
            full,
            extra,
        };
    };

    pub fn init(alloc: Allocator, path: []const u8, config: Config) !SQLiteNodeStore {
        const path_z = try alloc.dupeZ(u8, path);
        defer alloc.free(path_z);

        var db_opt: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        const open_rc = c.sqlite3_open_v2(path_z.ptr, &db_opt, flags, null);
        if (open_rc != c.SQLITE_OK) {
            if (db_opt) |db| {
                _ = c.sqlite3_close_v2(db);
            }
            return sqliteError(open_rc);
        }

        const db = db_opt orelse return error.SQLiteOpenFailed;
        errdefer _ = c.sqlite3_close_v2(db);

        const timeout_rc = c.sqlite3_busy_timeout(db, try toCInt(config.busy_timeout_ms));
        if (timeout_rc != c.SQLITE_OK) return sqliteError(timeout_rc);

        if (config.enable_wal) {
            try execLiteral(db, "PRAGMA journal_mode=WAL;");
        }

        switch (config.synchronous) {
            .off => try execLiteral(db, "PRAGMA synchronous=OFF;"),
            .normal => try execLiteral(db, "PRAGMA synchronous=NORMAL;"),
            .full => try execLiteral(db, "PRAGMA synchronous=FULL;"),
            .extra => try execLiteral(db, "PRAGMA synchronous=EXTRA;"),
        }

        if (config.wal_autocheckpoint_pages) |pages| {
            try execDynamic(db, alloc, "PRAGMA wal_autocheckpoint={d};", .{pages});
        }

        try execLiteral(db, schema_sql);

        return .{
            .alloc = alloc,
            .db = db,
            .config = config,
        };
    }

    pub fn deinit(self: *SQLiteNodeStore) void {
        _ = c.sqlite3_close_v2(self.db);
        self.* = undefined;
    }

    pub fn sampleTableRowCounts(self: *SQLiteNodeStore) !TableRowCounts {
        return .{
            .actor_snapshot = try querySingleU64(self.db, sql_count_actor_snapshot),
            .actor_wal = try querySingleU64(self.db, sql_count_actor_wal),
            .actor_seen_message = try querySingleU64(self.db, sql_count_actor_seen_message),
        };
    }

    pub fn walAutocheckpointPages(self: *SQLiteNodeStore) !u32 {
        const value = try querySingleU64(self.db, sql_pragma_wal_autocheckpoint);
        return @intCast(value);
    }

    /// Benchmark helper for the counter-service workload in examples/benchmark/scale.zig.
    /// Computes durable state as parsed snapshot value plus unsnapshotted WAL rows.
    pub fn benchmarkCounterValueByObjectId(self: *SQLiteNodeStore, object_id: []const u8) !u64 {
        var snapshot_value: u64 = 0;
        {
            var stmt = try Statement.init(self.db, sql_load_snapshot_bytes);
            defer stmt.deinit();

            try bindText(stmt.ptr, 1, object_id);

            switch (try stmt.step()) {
                .done => {},
                .row => {
                    const bytes = try columnBlobSlice(stmt.ptr, 0, true);
                    snapshot_value = if (bytes.len == 0) 0 else try std.fmt.parseUnsigned(u64, bytes, 10);
                },
            }
        }

        var wal_count: u64 = 0;
        {
            var stmt = try Statement.init(self.db, sql_count_actor_wal_for_object);
            defer stmt.deinit();

            try bindText(stmt.ptr, 1, object_id);

            wal_count = switch (try stmt.step()) {
                .row => try columnU64(stmt.ptr, 0),
                .done => 0,
            };
        }

        return snapshot_value + wal_count;
    }

    pub fn asStoreProvider(self: *SQLiteNodeStore) core.StoreProvider {
        return .{
            .ptr = self,
            .open_fn = openErased,
        };
    }

    fn openErased(ctx: *anyopaque, alloc: Allocator, object_id: []const u8) anyerror!core.ScopedStore {
        const self: *SQLiteNodeStore = @ptrCast(@alignCast(ctx));
        return try self.openScoped(alloc, object_id);
    }

    fn openScoped(self: *SQLiteNodeStore, alloc: Allocator, object_id: []const u8) !core.ScopedStore {
        const scope = try alloc.create(SQLiteScopedStore);
        errdefer alloc.destroy(scope);

        scope.* = .{
            .alloc = alloc,
            .db = self.db,
            .object_id = try alloc.dupe(u8, object_id),
        };
        errdefer alloc.free(scope.object_id);

        return core.ScopedStore.from(SQLiteScopedStore, scope);
    }
};

const SQLiteScopedStore = struct {
    alloc: Allocator,
    db: *c.sqlite3,
    object_id: []u8,

    pub fn destroy(self: *SQLiteScopedStore, alloc: Allocator) void {
        alloc.free(self.object_id);
        alloc.destroy(self);
    }

    pub fn loadSnapshot(self: *SQLiteScopedStore, alloc: Allocator) !?core.ScopedStore.Snapshot {
        var stmt = try Statement.init(self.db, sql_load_snapshot);
        defer stmt.deinit();

        try bindText(stmt.ptr, 1, self.object_id);

        switch (try stmt.step()) {
            .done => return null,
            .row => {
                const last_seq = try columnU64(stmt.ptr, 0);
                const bytes = try copyColumnBlob(alloc, stmt.ptr, 1);
                return .{
                    .last_seq = last_seq,
                    .bytes = .fromOwned(alloc, bytes),
                };
            },
        }
    }

    pub fn replayAfter(self: *SQLiteScopedStore, after_seq: u64, replay_ctx: *anyopaque, replay_fn: core.ScopedStore.ReplayFn) !void {
        var stmt = try Statement.init(self.db, sql_replay_after);
        defer stmt.deinit();

        try bindText(stmt.ptr, 1, self.object_id);
        try bindU64(stmt.ptr, 2, after_seq);

        while (true) {
            switch (try stmt.step()) {
                .done => break,
                .row => {
                    const seq = try columnU64(stmt.ptr, 0);
                    const mutation = try columnBlobSlice(stmt.ptr, 1, true);
                    try replay_fn(replay_ctx, seq, mutation);
                },
            }
        }
    }

    pub fn appendOnce(self: *SQLiteScopedStore, alloc: Allocator, intent: core.ScopedStore.AppendIntent) !core.ScopedStore.AppendResult {
        const message_id_buf = encodeMessageId(intent.message_id);

        try execLiteral(self.db, "BEGIN IMMEDIATE;");
        var in_tx = true;
        errdefer if (in_tx) rollback(self.db);

        var saw_duplicate = false;
        var duplicate_reply_bytes: ?[]u8 = null;
        errdefer if (duplicate_reply_bytes) |bytes| alloc.free(bytes);
        {
            var lookup = try Statement.init(self.db, sql_load_seen);
            defer lookup.deinit();

            try bindText(lookup.ptr, 1, self.object_id);
            try bindBlob(lookup.ptr, 2, message_id_buf[0..]);

            switch (try lookup.step()) {
                .row => {
                    saw_duplicate = true;
                    duplicate_reply_bytes = try copyNullableColumnBlob(alloc, lookup.ptr, 0);
                },
                .done => {},
            }
        }

        if (saw_duplicate) {
            try execLiteral(self.db, "COMMIT;");
            in_tx = false;

            return .{
                .duplicate = if (duplicate_reply_bytes) |bytes| .fromOwned(alloc, bytes) else null,
            };
        }

        {
            var insert_wal = try Statement.init(self.db, sql_insert_wal);
            defer insert_wal.deinit();

            try bindText(insert_wal.ptr, 1, self.object_id);
            try bindU64(insert_wal.ptr, 2, intent.seq);
            try bindBlob(insert_wal.ptr, 3, message_id_buf[0..]);
            try bindBlob(insert_wal.ptr, 4, intent.mutation);

            const rc = c.sqlite3_step(insert_wal.ptr);
            if (rc != c.SQLITE_DONE) {
                if (primaryCode(rc) == c.SQLITE_CONSTRAINT) return error.SequenceConflict;
                return sqliteError(rc);
            }
        }

        {
            var insert_seen = try Statement.init(self.db, sql_insert_seen);
            defer insert_seen.deinit();

            try bindText(insert_seen.ptr, 1, self.object_id);
            try bindBlob(insert_seen.ptr, 2, message_id_buf[0..]);
            try bindU64(insert_seen.ptr, 3, intent.seq);
            try bindNullableBlob(insert_seen.ptr, 4, intent.reply);

            const rc = c.sqlite3_step(insert_seen.ptr);
            if (rc != c.SQLITE_DONE) {
                if (primaryCode(rc) == c.SQLITE_CONSTRAINT) return error.SequenceConflict;
                return sqliteError(rc);
            }
        }

        try execLiteral(self.db, "COMMIT;");
        in_tx = false;
        return .inserted;
    }

    pub fn writeSnapshot(self: *SQLiteScopedStore, at_seq: u64, bytes: []const u8) !void {
        var stmt = try Statement.init(self.db, sql_write_snapshot);
        defer stmt.deinit();

        try bindText(stmt.ptr, 1, self.object_id);
        try bindU64(stmt.ptr, 2, at_seq);
        try bindBlob(stmt.ptr, 3, bytes);

        const rc = c.sqlite3_step(stmt.ptr);
        if (rc != c.SQLITE_DONE) return sqliteError(rc);
    }

    pub fn compactBefore(self: *SQLiteScopedStore, first_live_seq: u64) !void {
        var stmt = try Statement.init(self.db, sql_compact_wal);
        defer stmt.deinit();

        try bindText(stmt.ptr, 1, self.object_id);
        try bindU64(stmt.ptr, 2, first_live_seq);

        const rc = c.sqlite3_step(stmt.ptr);
        if (rc != c.SQLITE_DONE) return sqliteError(rc);
    }
};

const Statement = struct {
    ptr: *c.sqlite3_stmt,

    fn init(db: *c.sqlite3, sql: []const u8) !Statement {
        var stmt_opt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, sql.ptr, try toCInt(sql.len), &stmt_opt, null);
        if (rc != c.SQLITE_OK) return sqliteError(rc);
        return .{ .ptr = stmt_opt orelse return error.SQLitePrepareFailed };
    }

    fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.ptr);
    }

    fn step(self: *Statement) !enum { row, done } {
        const rc = c.sqlite3_step(self.ptr);
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => return sqliteError(rc),
        };
    }
};

fn execLiteral(db: *c.sqlite3, sql: [:0]const u8) !void {
    const rc = c.sqlite3_exec(db, sql.ptr, null, null, null);
    if (rc != c.SQLITE_OK) return sqliteError(rc);
}

fn execDynamic(db: *c.sqlite3, alloc: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const sql = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(sql);

    const sql_z = try alloc.dupeZ(u8, sql);
    defer alloc.free(sql_z);
    try execLiteral(db, sql_z);
}

fn rollback(db: *c.sqlite3) void {
    _ = c.sqlite3_exec(db, "ROLLBACK;", null, null, null);
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, bytes: []const u8) !void {
    const ptr: [*c]const u8 = if (bytes.len == 0) @ptrCast(empty_byte[0..].ptr) else @ptrCast(bytes.ptr);
    const rc = c.sqlite3_bind_text(stmt, index, ptr, try toCInt(bytes.len), null);
    if (rc != c.SQLITE_OK) return sqliteError(rc);
}

fn bindBlob(stmt: *c.sqlite3_stmt, index: c_int, bytes: []const u8) !void {
    const ptr: ?*const anyopaque = if (bytes.len == 0) @ptrCast(empty_byte[0..].ptr) else @ptrCast(bytes.ptr);
    const rc = c.sqlite3_bind_blob(stmt, index, ptr, try toCInt(bytes.len), null);
    if (rc != c.SQLITE_OK) return sqliteError(rc);
}

fn bindNullableBlob(stmt: *c.sqlite3_stmt, index: c_int, maybe_bytes: ?[]const u8) !void {
    if (maybe_bytes) |bytes| {
        try bindBlob(stmt, index, bytes);
        return;
    }

    const rc = c.sqlite3_bind_null(stmt, index);
    if (rc != c.SQLITE_OK) return sqliteError(rc);
}

fn bindU64(stmt: *c.sqlite3_stmt, index: c_int, value: u64) !void {
    if (value > std.math.maxInt(i64)) return error.SequenceTooLarge;
    const rc = c.sqlite3_bind_int64(stmt, index, @as(c.sqlite3_int64, @intCast(value)));
    if (rc != c.SQLITE_OK) return sqliteError(rc);
}

fn columnU64(stmt: *c.sqlite3_stmt, col: c_int) !u64 {
    const value = c.sqlite3_column_int64(stmt, col);
    if (value < 0) return error.InvalidSequence;
    return @intCast(value);
}

fn querySingleU64(db: *c.sqlite3, sql: []const u8) !u64 {
    var stmt = try Statement.init(db, sql);
    defer stmt.deinit();

    return switch (try stmt.step()) {
        .row => try columnU64(stmt.ptr, 0),
        .done => error.MissingQueryRow,
    };
}

fn copyColumnBlob(alloc: Allocator, stmt: *c.sqlite3_stmt, col: c_int) ![]u8 {
    const blob = try columnBlobSlice(stmt, col, true);
    return try alloc.dupe(u8, blob);
}

fn copyNullableColumnBlob(alloc: Allocator, stmt: *c.sqlite3_stmt, col: c_int) !?[]u8 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    return try copyColumnBlob(alloc, stmt, col);
}

fn columnBlobSlice(stmt: *c.sqlite3_stmt, col: c_int, required: bool) ![]const u8 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) {
        if (required) return error.UnexpectedNullBlob;
        return &.{};
    }

    const len_i = c.sqlite3_column_bytes(stmt, col);
    if (len_i < 0) return error.SQLite;
    const len: usize = @intCast(len_i);
    if (len == 0) return &.{};

    const raw = c.sqlite3_column_blob(stmt, col) orelse return error.SQLite;
    const ptr: [*]const u8 = @ptrCast(raw);
    return ptr[0..len];
}

fn encodeMessageId(id: u128) [16]u8 {
    var out: [16]u8 = undefined;
    var value = id;
    var i: usize = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast(value & 0xff);
        value >>= 8;
    }
    return out;
}

fn primaryCode(rc: c_int) c_int {
    return rc & 0xff;
}

fn sqliteError(rc: c_int) anyerror {
    return switch (primaryCode(rc)) {
        c.SQLITE_BUSY => error.SQLiteBusy,
        c.SQLITE_LOCKED => error.SQLiteLocked,
        c.SQLITE_READONLY => error.SQLiteReadOnly,
        c.SQLITE_CONSTRAINT => error.SQLiteConstraint,
        c.SQLITE_IOERR => error.SQLiteIo,
        c.SQLITE_CORRUPT => error.SQLiteCorrupt,
        c.SQLITE_FULL => error.SQLiteFull,
        c.SQLITE_TOOBIG => error.SQLiteTooBig,
        c.SQLITE_RANGE => error.SQLiteRange,
        else => error.SQLite,
    };
}

fn toCInt(value: anytype) !c_int {
    const v: u64 = switch (@typeInfo(@TypeOf(value))) {
        .comptime_int => value,
        .int => @intCast(value),
        else => @compileError("toCInt expects an integer value"),
    };
    if (v > std.math.maxInt(c_int)) return error.ValueTooLarge;
    return @intCast(v);
}

/// Minimal service for store tests. Accepts "set|<value>" and "get" commands.
const KvService = struct {
    alloc: Allocator,
    value: ?[]u8 = null,

    pub fn create(alloc: Allocator, address: core.Address) !*KvService {
        _ = address;
        const self = try alloc.create(KvService);
        self.* = .{ .alloc = alloc };
        return self;
    }

    pub fn destroy(self: *KvService, alloc: Allocator) void {
        if (self.value) |v| alloc.free(v);
        alloc.destroy(self);
    }

    pub fn loadSnapshot(self: *KvService, bytes: []const u8) !void {
        if (self.value) |v| self.alloc.free(v);
        self.value = try self.alloc.dupe(u8, bytes);
    }

    pub fn makeSnapshot(self: *KvService, alloc: Allocator) !core.OwnedBytes {
        return core.OwnedBytes.clone(alloc, self.value orelse "");
    }

    pub fn decide(self: *KvService, alloc: Allocator, message: []const u8) !core.Decision {
        if (std.mem.eql(u8, message, "get")) {
            return .{ .reply = try core.OwnedBytes.clone(alloc, self.value orelse "") };
        }
        if (std.mem.startsWith(u8, message, "set|")) {
            const val = message[4..];
            return .{
                .mutation = try core.OwnedBytes.clone(alloc, val),
                .reply = try core.OwnedBytes.clone(alloc, "ok\n"),
            };
        }
        return error.InvalidCommand;
    }

    pub fn apply(self: *KvService, mutation: []const u8) !void {
        if (self.value) |v| self.alloc.free(v);
        self.value = try self.alloc.dupe(u8, mutation);
    }
};

test "sqlite store dedupes writes and survives passivation" {
    var store = try SQLiteNodeStore.init(std.testing.allocator, ":memory:", .{});
    defer store.deinit();

    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 1,
    });
    defer runtime.deinit();

    try runtime.registerFactory("kv", core.Factory.from(KvService, KvService.create));

    const addr = core.Address{ .kind = "kv", .key = "item-42" };

    const first = (try runtime.request(addr, 1001, "set|hello")) orelse return error.ExpectedReply;
    defer first.deinit();
    try std.testing.expectEqualStrings("ok\n", first.bytes);

    try std.testing.expect(try runtime.passivate(addr));

    const duplicate = (try runtime.request(addr, 1001, "set|hello")) orelse return error.ExpectedReply;
    defer duplicate.deinit();
    try std.testing.expectEqualStrings("ok\n", duplicate.bytes);

    const view = (try runtime.request(addr, 2001, "get")) orelse return error.ExpectedReply;
    defer view.deinit();
    try std.testing.expectEqualStrings("hello", view.bytes);
}

test "sqlite store snapshots on shutdown and reopens from durable state" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa.deinit();
    const alloc = gpa.allocator();

    var rng = std.Random.DefaultCsprng.init(.{0} ** 32);
    const tmp_name = try std.fmt.allocPrint(alloc, "durable-actor-sqlite-test-{x}.db", .{rng.random().int(u64)});
    defer {
        const z = @as([*:0]const u8, @ptrCast(tmp_name.ptr));
        _ = std.c.unlink(z);
    }

    {
        var store = try SQLiteNodeStore.init(std.testing.allocator, tmp_name, .{});
        defer store.deinit();

        var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
            .snapshot_every = 64,
        });
        defer runtime.deinit();
        defer runtime.shutdown() catch unreachable;

        try runtime.registerFactory("kv", core.Factory.from(KvService, KvService.create));

        const addr = core.Address{ .kind = "kv", .key = "item-99" };

        const reply = (try runtime.request(addr, 1, "set|persisted-value")) orelse return error.ExpectedReply;
        defer reply.deinit();
        try std.testing.expectEqualStrings("ok\n", reply.bytes);
    }

    {
        var store = try SQLiteNodeStore.init(std.testing.allocator, tmp_name, .{});
        defer store.deinit();

        var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
            .snapshot_every = 64,
        });
        defer runtime.deinit();

        try runtime.registerFactory("kv", core.Factory.from(KvService, KvService.create));

        const addr = core.Address{ .kind = "kv", .key = "item-99" };

        const view = (try runtime.request(addr, 2, "get")) orelse return error.ExpectedReply;
        defer view.deinit();
        try std.testing.expectEqualStrings("persisted-value", view.bytes);
    }
}

test "sqlite store applies explicit wal autocheckpoint config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sqlite_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/wal-config.sqlite3",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(sqlite_path);

    var store = try SQLiteNodeStore.init(std.testing.allocator, sqlite_path, .{
        .wal_autocheckpoint_pages = 0,
    });
    defer store.deinit();

    try std.testing.expectEqual(@as(u32, 0), try store.walAutocheckpointPages());
}
