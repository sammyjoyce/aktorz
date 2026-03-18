const std = @import("std");
const durable = @import("durable_actor");
const MemoryNodeStore = durable.MemoryNodeStore;

const Allocator = std.mem.Allocator;

const Status = enum { active, frozen, closed };

const TxRecord = struct {
    kind: []u8,
    amount_cents: i64,
    memo: []u8,
};

const max_recent: usize = 10;

/// A durable bank account with overdraft protection, freeze/unfreeze,
/// close lifecycle, and a bounded recent-transaction window.
///
/// Commands (pipe-delimited):
///   deposit|<cents>|<memo>
///   withdraw|<cents>|<memo>
///   set_overdraft|<cents>
///   freeze|<reason>
///   unfreeze
///   close
///   balance          (read-only)
///   statement        (read-only)
pub const BankAccountService = struct {
    alloc: Allocator,
    status: Status,
    balance_cents: i64,
    overdraft_limit_cents: i64,
    tx_count: u32,
    recent: std.ArrayList(TxRecord),

    pub fn create(alloc: Allocator, address: durable.Address) !*BankAccountService {
        _ = address;
        const self = try alloc.create(BankAccountService);
        self.* = .{
            .alloc = alloc,
            .status = .active,
            .balance_cents = 0,
            .overdraft_limit_cents = 0,
            .tx_count = 0,
            .recent = .empty,
        };
        return self;
    }

    pub fn destroy(self: *BankAccountService, alloc: Allocator) void {
        for (self.recent.items) |rec| {
            alloc.free(rec.kind);
            alloc.free(rec.memo);
        }
        self.recent.deinit(alloc);
        alloc.destroy(self);
    }

    // ── snapshot ──

    pub fn loadSnapshot(self: *BankAccountService, bytes: []const u8) !void {
        for (self.recent.items) |rec| {
            self.alloc.free(rec.kind);
            self.alloc.free(rec.memo);
        }
        self.recent.shrinkRetainingCapacity(0);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            if (std.mem.startsWith(u8, line, "txe:")) {
                try self.loadEscapedTxLine(line[4..]);
                continue;
            }

            if (std.mem.startsWith(u8, line, "tx:")) {
                try self.loadTxLine(line[3..]);
                continue;
            }

            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSnapshot;
            const key = line[0..eq];
            const val = line[eq + 1 ..];

            if (std.mem.eql(u8, key, "status")) {
                self.status = std.meta.stringToEnum(Status, val) orelse return error.InvalidSnapshot;
            } else if (std.mem.eql(u8, key, "balance")) {
                self.balance_cents = try std.fmt.parseInt(i64, val, 10);
            } else if (std.mem.eql(u8, key, "overdraft")) {
                self.overdraft_limit_cents = try std.fmt.parseInt(i64, val, 10);
            } else if (std.mem.eql(u8, key, "tx_count")) {
                self.tx_count = try std.fmt.parseUnsigned(u32, val, 10);
            }
        }
    }

    pub fn makeSnapshot(self: *BankAccountService, alloc: Allocator) !durable.OwnedBytes {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);

        try appendKeyVal(&out, alloc, "status", @tagName(self.status));

        var buf: [32]u8 = undefined;
        var txt = try std.fmt.bufPrint(&buf, "{d}", .{self.balance_cents});
        try appendKeyVal(&out, alloc, "balance", txt);

        txt = try std.fmt.bufPrint(&buf, "{d}", .{self.overdraft_limit_cents});
        try appendKeyVal(&out, alloc, "overdraft", txt);

        txt = try std.fmt.bufPrint(&buf, "{d}", .{self.tx_count});
        try appendKeyVal(&out, alloc, "tx_count", txt);

        for (self.recent.items) |rec| {
            try appendEscapedTxLine(&out, alloc, rec);
        }

        return .fromOwned(alloc, try out.toOwnedSlice(alloc));
    }

    // ── decide (pure command validation, produces mutation + reply) ──

    pub fn decide(self: *BankAccountService, alloc: Allocator, message: []const u8) !durable.Decision {
        var parts = std.mem.splitScalar(u8, message, '|');
        const op = parts.first();

        if (std.mem.eql(u8, op, "balance")) {
            return .{ .reply = try self.renderBalance(alloc) };
        }

        if (std.mem.eql(u8, op, "statement")) {
            return .{ .reply = try self.renderStatement(alloc) };
        }

        if (std.mem.eql(u8, op, "deposit")) {
            if (self.status == .closed)
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: account closed\n") };
            if (self.status == .frozen)
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: account frozen\n") };

            const amount_txt = parts.next() orelse return error.InvalidCommand;
            const memo = parts.rest();
            if (memo.len == 0) return error.InvalidCommand;

            const amount = try std.fmt.parseUnsigned(u32, amount_txt, 10);
            if (amount == 0)
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: amount must be > 0\n") };

            return .{
                .mutation = .fromOwned(alloc, try std.fmt.allocPrint(alloc, "deposited|{d}|{s}", .{ amount, memo })),
                .reply = try durable.OwnedBytes.clone(alloc, "ok\n"),
            };
        }

        if (std.mem.eql(u8, op, "withdraw")) {
            if (self.status == .closed)
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: account closed\n") };
            if (self.status == .frozen)
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: account frozen\n") };

            const amount_txt = parts.next() orelse return error.InvalidCommand;
            const memo = parts.rest();
            if (memo.len == 0) return error.InvalidCommand;

            const amount = try std.fmt.parseUnsigned(u32, amount_txt, 10);
            if (amount == 0)
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: amount must be > 0\n") };

            const available = self.availableCents();
            if (available < @as(i64, @intCast(amount)))
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: insufficient funds\n") };

            return .{
                .mutation = .fromOwned(alloc, try std.fmt.allocPrint(alloc, "withdrawn|{d}|{s}", .{ amount, memo })),
                .reply = try durable.OwnedBytes.clone(alloc, "ok\n"),
            };
        }

        if (std.mem.eql(u8, op, "set_overdraft")) {
            if (self.status == .closed)
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: account closed\n") };

            const limit_txt = parts.next() orelse return error.InvalidCommand;
            if (parts.next() != null) return error.InvalidCommand;

            const limit = try std.fmt.parseUnsigned(u32, limit_txt, 10);
            return .{
                .mutation = .fromOwned(alloc, try std.fmt.allocPrint(alloc, "overdraft_set|{d}", .{limit})),
                .reply = try durable.OwnedBytes.clone(alloc, "ok\n"),
            };
        }

        if (std.mem.eql(u8, op, "freeze")) {
            const reason = parts.next() orelse return error.InvalidCommand;
            if (parts.next() != null) return error.InvalidCommand;

            if (self.status == .closed)
                return .{ .reply = .fromOwned(alloc, try std.fmt.allocPrint(alloc, "error: cannot freeze, status is {s}\n", .{@tagName(self.status)})) };

            return .{
                .mutation = .fromOwned(alloc, try std.fmt.allocPrint(alloc, "account_frozen|{s}", .{reason})),
                .reply = try durable.OwnedBytes.clone(alloc, "ok\n"),
            };
        }

        if (std.mem.eql(u8, op, "unfreeze")) {
            if (parts.next() != null) return error.InvalidCommand;
            if (self.status == .closed)
                return .{ .reply = .fromOwned(alloc, try std.fmt.allocPrint(alloc, "error: cannot unfreeze, status is {s}\n", .{@tagName(self.status)})) };

            return .{
                .mutation = try durable.OwnedBytes.clone(alloc, "account_unfrozen"),
                .reply = try durable.OwnedBytes.clone(alloc, "ok\n"),
            };
        }

        if (std.mem.eql(u8, op, "close")) {
            if (parts.next() != null) return error.InvalidCommand;
            if (self.status == .frozen)
                return .{ .reply = .fromOwned(alloc, try std.fmt.allocPrint(alloc, "error: cannot close, status is {s}\n", .{@tagName(self.status)})) };
            if (self.status == .active and self.balance_cents != 0)
                return .{ .reply = try durable.OwnedBytes.clone(alloc, "error: balance must be zero to close\n") };

            return .{
                .mutation = try durable.OwnedBytes.clone(alloc, "account_closed"),
                .reply = try durable.OwnedBytes.clone(alloc, "ok\n"),
            };
        }

        return error.InvalidCommand;
    }

    // ── apply (state mutation, called only after durable append succeeds) ──

    pub fn apply(self: *BankAccountService, mutation: []const u8) !void {
        var parts = std.mem.splitScalar(u8, mutation, '|');
        const op = parts.first();

        if (std.mem.eql(u8, op, "deposited")) {
            const amount_txt = parts.next() orelse return error.InvalidMutation;
            const memo = parts.rest();
            if (memo.len == 0) return error.InvalidMutation;

            const amount: i64 = try std.fmt.parseInt(i64, amount_txt, 10);
            self.balance_cents += amount;
            self.tx_count += 1;
            try self.pushRecent("deposited", amount, memo);
            return;
        }

        if (std.mem.eql(u8, op, "withdrawn")) {
            const amount_txt = parts.next() orelse return error.InvalidMutation;
            const memo = parts.rest();
            if (memo.len == 0) return error.InvalidMutation;

            const amount: i64 = try std.fmt.parseInt(i64, amount_txt, 10);
            self.balance_cents -= amount;
            self.tx_count += 1;
            try self.pushRecent("withdrawn", amount, memo);
            return;
        }

        if (std.mem.eql(u8, op, "overdraft_set")) {
            const limit_txt = parts.next() orelse return error.InvalidMutation;
            if (parts.next() != null) return error.InvalidMutation;

            self.overdraft_limit_cents = try std.fmt.parseInt(i64, limit_txt, 10);
            return;
        }

        if (std.mem.eql(u8, op, "account_frozen")) {
            _ = parts.next() orelse return error.InvalidMutation; // reason (audit only)
            if (parts.next() != null) return error.InvalidMutation;
            self.status = .frozen;
            return;
        }

        if (std.mem.eql(u8, op, "account_unfrozen")) {
            if (parts.next() != null) return error.InvalidMutation;
            self.status = .active;
            return;
        }

        if (std.mem.eql(u8, op, "account_closed")) {
            if (parts.next() != null) return error.InvalidMutation;
            self.status = .closed;
            return;
        }

        return error.InvalidMutation;
    }

    // ── private helpers ──

    fn pushRecent(self: *BankAccountService, kind: []const u8, amount: i64, memo: []const u8) !void {
        const kind_dup = try self.alloc.dupe(u8, kind);
        errdefer self.alloc.free(kind_dup);
        const memo_dup = try self.alloc.dupe(u8, memo);
        errdefer self.alloc.free(memo_dup);

        try self.recent.append(self.alloc, .{
            .kind = kind_dup,
            .amount_cents = amount,
            .memo = memo_dup,
        });

        if (self.recent.items.len > max_recent) {
            const evicted = self.recent.orderedRemove(0);
            self.alloc.free(evicted.kind);
            self.alloc.free(evicted.memo);
        }
    }

    fn loadTxLine(self: *BankAccountService, line: []const u8) !void {
        var parts = std.mem.splitScalar(u8, line, '|');
        const kind = parts.first();
        const amount_txt = parts.next() orelse return error.InvalidSnapshot;
        const memo = parts.next() orelse return error.InvalidSnapshot;
        if (parts.next() != null) return error.InvalidSnapshot;

        try self.appendSnapshotTx(kind, amount_txt, memo);
    }

    fn loadEscapedTxLine(self: *BankAccountService, line: []const u8) !void {
        var parts = std.mem.splitScalar(u8, line, '|');
        const kind = parts.first();
        const amount_txt = parts.next() orelse return error.InvalidSnapshot;
        const memo_txt = parts.next() orelse return error.InvalidSnapshot;
        if (parts.next() != null) return error.InvalidSnapshot;

        const memo = try decodeSnapshotMemo(self.alloc, memo_txt);
        defer self.alloc.free(memo);

        try self.appendSnapshotTx(kind, amount_txt, memo);
    }

    fn appendSnapshotTx(self: *BankAccountService, kind: []const u8, amount_txt: []const u8, memo: []const u8) !void {
        const kind_dup = try self.alloc.dupe(u8, kind);
        errdefer self.alloc.free(kind_dup);
        const memo_dup = try self.alloc.dupe(u8, memo);
        errdefer self.alloc.free(memo_dup);

        try self.recent.append(self.alloc, .{
            .kind = kind_dup,
            .amount_cents = try std.fmt.parseInt(i64, amount_txt, 10),
            .memo = memo_dup,
        });
    }

    fn appendEscapedTxLine(out: *std.ArrayList(u8), alloc: Allocator, rec: TxRecord) !void {
        try out.appendSlice(alloc, "txe:");
        try out.appendSlice(alloc, rec.kind);
        try out.appendSlice(alloc, "|");

        var amt_buf: [32]u8 = undefined;
        const amt_txt = try std.fmt.bufPrint(&amt_buf, "{d}", .{rec.amount_cents});
        try out.appendSlice(alloc, amt_txt);
        try out.appendSlice(alloc, "|");
        try appendSnapshotMemo(out, alloc, rec.memo);
        try out.appendSlice(alloc, "\n");
    }

    fn appendSnapshotMemo(out: *std.ArrayList(u8), alloc: Allocator, memo: []const u8) !void {
        for (memo) |byte| {
            switch (byte) {
                '\\' => try out.appendSlice(alloc, "\\\\"),
                '\n' => try out.appendSlice(alloc, "\\n"),
                '\r' => try out.appendSlice(alloc, "\\r"),
                '|' => try out.appendSlice(alloc, "\\p"),
                else => try out.append(alloc, byte),
            }
        }
    }

    fn decodeSnapshotMemo(alloc: Allocator, encoded: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);

        var i: usize = 0;
        while (i < encoded.len) : (i += 1) {
            const byte = encoded[i];
            if (byte != '\\') {
                try out.append(alloc, byte);
                continue;
            }

            i += 1;
            if (i >= encoded.len) return error.InvalidSnapshot;

            switch (encoded[i]) {
                '\\' => try out.append(alloc, '\\'),
                'n' => try out.append(alloc, '\n'),
                'r' => try out.append(alloc, '\r'),
                'p' => try out.append(alloc, '|'),
                else => return error.InvalidSnapshot,
            }
        }

        return try out.toOwnedSlice(alloc);
    }

    fn availableCents(self: *BankAccountService) i64 {
        return if (self.status == .closed) 0 else self.balance_cents + self.overdraft_limit_cents;
    }

    fn renderBalance(self: *BankAccountService, alloc: Allocator) !durable.OwnedBytes {
        return .fromOwned(alloc, try std.fmt.allocPrint(
            alloc,
            "status={s}\nbalance_cents={d}\navailable_cents={d}\n",
            .{ @tagName(self.status), self.balance_cents, self.availableCents() },
        ));
    }

    fn renderStatement(self: *BankAccountService, alloc: Allocator) !durable.OwnedBytes {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);

        const header = try std.fmt.allocPrint(
            alloc,
            "status={s}\nbalance_cents={d}\noverdraft_limit_cents={d}\navailable_cents={d}\ntx_count={d}\n---\n",
            .{
                @tagName(self.status),
                self.balance_cents,
                self.overdraft_limit_cents,
                self.availableCents(),
                self.tx_count,
            },
        );
        defer alloc.free(header);
        try out.appendSlice(alloc, header);

        for (self.recent.items) |rec| {
            const line = try std.fmt.allocPrint(alloc, "{s} {d} {s}\n", .{
                rec.kind,
                rec.amount_cents,
                rec.memo,
            });
            defer alloc.free(line);
            try out.appendSlice(alloc, line);
        }

        return .fromOwned(alloc, try out.toOwnedSlice(alloc));
    }

    fn appendKeyVal(out: *std.ArrayList(u8), alloc: Allocator, key: []const u8, val: []const u8) !void {
        try out.appendSlice(alloc, key);
        try out.appendSlice(alloc, "=");
        try out.appendSlice(alloc, val);
        try out.appendSlice(alloc, "\n");
    }
};

// ── tests ──

test "bank account snapshots preserve newline memos" {
    const address = durable.Address{ .kind = "bank", .key = "newline-memo" };

    const account = try BankAccountService.create(std.testing.allocator, address);
    defer account.destroy(std.testing.allocator);

    try account.apply("deposited|100|rent\nbalance=0");

    const snapshot = try account.makeSnapshot(std.testing.allocator);
    defer snapshot.deinit();

    const restored = try BankAccountService.create(std.testing.allocator, address);
    defer restored.destroy(std.testing.allocator);

    try restored.loadSnapshot(snapshot.bytes);

    try std.testing.expectEqual(@as(i64, 100), restored.balance_cents);
    try std.testing.expectEqual(@as(u32, 1), restored.tx_count);
    try std.testing.expectEqual(@as(usize, 1), restored.recent.items.len);
    try std.testing.expectEqualStrings("rent\nbalance=0", restored.recent.items[0].memo);
}

test "bank account accepts memos containing pipe delimiters" {
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();

    var runtime = durable.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 64,
    });
    defer runtime.deinit();
    defer runtime.shutdown() catch {};

    try runtime.registerFactory("bank", durable.Factory.from(BankAccountService, BankAccountService.create));

    const acct = durable.Address{ .kind = "bank", .key = "memo-pipes" };

    {
        const r = (try runtime.request(acct, 1, "deposit|100|rent|April")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }
    {
        const r = (try runtime.request(acct, 2, "withdraw|40|groceries|weekly")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }
    {
        const r = (try runtime.request(acct, 3, "statement")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "deposited 100 rent|April") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "withdrawn 40 groceries|weekly") != null);
    }
}

test "bank account lifecycle with passivation, dedup, and state guards" {
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();

    var runtime = durable.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 4,
    });
    defer runtime.deinit();

    try runtime.registerFactory("bank", durable.Factory.from(BankAccountService, BankAccountService.create));

    const acct = durable.Address{ .kind = "bank", .key = "acme:checking-001" };

    // ── deposits ──

    {
        const r = (try runtime.request(acct, 1, "deposit|10000|opening deposit")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }
    {
        const r = (try runtime.request(acct, 2, "deposit|5000|paycheck")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }

    // ── balance check ──

    {
        const r = (try runtime.request(acct, 100, "balance")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "balance_cents=15000") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "available_cents=15000") != null);
    }

    // ── set overdraft (seq=3) ──

    {
        const r = (try runtime.request(acct, 3, "set_overdraft|2000")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }

    // ── withdraw into overdraft (seq=4, triggers snapshot at snapshot_every=4) ──

    {
        const r = (try runtime.request(acct, 4, "withdraw|16000|big purchase")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }

    // balance should be -1000, available 1000

    {
        const r = (try runtime.request(acct, 101, "balance")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "balance_cents=-1000") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "available_cents=1000") != null);
    }

    // ── insufficient funds ──

    {
        const r = (try runtime.request(acct, 99, "withdraw|2000|too much")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("error: insufficient funds\n", r.bytes);
    }

    // ── deposit to bring balance back to zero (seq=5) ──

    {
        const r = (try runtime.request(acct, 5, "deposit|1000|top up")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }

    // ── passivate (snapshots dirty state, destroys activation) ──

    try std.testing.expect(try runtime.passivate(acct));

    // ── reactivate via balance: state must survive round-trip ──

    {
        const r = (try runtime.request(acct, 200, "balance")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "balance_cents=0") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "available_cents=2000") != null);
    }

    // ── dedup: re-send msg_id=1 (opening deposit) should NOT add funds ──

    {
        const r = (try runtime.request(acct, 1, "deposit|10000|opening deposit")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }
    {
        const r = (try runtime.request(acct, 201, "balance")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "balance_cents=0") != null);
    }

    // ── freeze lifecycle ──

    {
        const r = (try runtime.request(acct, 6, "freeze|suspicious activity")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }
    {
        const r = (try runtime.request(acct, 6, "freeze|suspicious activity")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }
    {
        const r = (try runtime.request(acct, 7, "withdraw|100|attempt")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("error: account frozen\n", r.bytes);
    }
    {
        const r = (try runtime.request(acct, 8, "deposit|100|attempt")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("error: account frozen\n", r.bytes);
    }

    // cannot close while frozen

    {
        const r = (try runtime.request(acct, 88, "close")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "error: cannot close") != null);
    }

    // ── unfreeze ──

    {
        const r = (try runtime.request(acct, 9, "unfreeze")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }
    {
        const r = (try runtime.request(acct, 9, "unfreeze")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }

    // ── close (balance is 0) ──

    {
        const r = (try runtime.request(acct, 10, "close")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }
    {
        const r = (try runtime.request(acct, 10, "close")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }

    {
        const r = (try runtime.request(acct, 203, "balance")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "status=closed") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "available_cents=0") != null);
    }

    // ── operations on closed account fail ──

    {
        const r = (try runtime.request(acct, 11, "deposit|100|nope")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("error: account closed\n", r.bytes);
    }

    // ── statement shows closed status and recent transactions ──

    {
        const r = (try runtime.request(acct, 202, "statement")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "status=closed") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "balance_cents=0") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "available_cents=0") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "deposited 10000 opening deposit") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "withdrawn 16000 big purchase") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "deposited 1000 top up") != null);
    }
}

test "bank account: two independent accounts do not interfere" {
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();

    var runtime = durable.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 64,
    });
    defer runtime.deinit();
    defer runtime.shutdown() catch {};

    try runtime.registerFactory("bank", durable.Factory.from(BankAccountService, BankAccountService.create));

    const alice = durable.Address{ .kind = "bank", .key = "alice" };
    const bob = durable.Address{ .kind = "bank", .key = "bob" };

    {
        const r = (try runtime.request(alice, 1, "deposit|5000|seed")) orelse return error.ExpectedReply;
        defer r.deinit();
    }
    {
        const r = (try runtime.request(bob, 1, "deposit|9999|seed")) orelse return error.ExpectedReply;
        defer r.deinit();
    }

    // Alice's balance is 5000

    {
        const r = (try runtime.request(alice, 100, "balance")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "balance_cents=5000") != null);
    }

    // Bob's balance is 9999

    {
        const r = (try runtime.request(bob, 100, "balance")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "balance_cents=9999") != null);
    }
}

test "bank account: recent transactions bounded to 10" {
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();

    var runtime = durable.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 64,
    });
    defer runtime.deinit();
    defer runtime.shutdown() catch {};

    try runtime.registerFactory("bank", durable.Factory.from(BankAccountService, BankAccountService.create));

    const acct = durable.Address{ .kind = "bank", .key = "flood" };

    // Push 12 deposits (exceeds max_recent=10)
    for (0..12) |i| {
        const r = (try runtime.request(acct, @as(u128, @intCast(i + 1)), "deposit|100|tx")) orelse return error.ExpectedReply;
        defer r.deinit();
    }

    // Statement should still work, balance 1200
    {
        const r = (try runtime.request(acct, 500, "statement")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "balance_cents=1200") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "tx_count=12") != null);
    }

    // Passivate and reactivate: snapshot round-trips the bounded list
    try std.testing.expect(try runtime.passivate(acct));
    {
        const r = (try runtime.request(acct, 501, "balance")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.bytes, "balance_cents=1200") != null);
    }
}

test "bank account: close with non-zero balance fails" {
    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();

    var runtime = durable.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 64,
    });
    defer runtime.deinit();
    defer runtime.shutdown() catch {};

    try runtime.registerFactory("bank", durable.Factory.from(BankAccountService, BankAccountService.create));

    const acct = durable.Address{ .kind = "bank", .key = "noclose" };

    {
        const r = (try runtime.request(acct, 1, "deposit|500|seed")) orelse return error.ExpectedReply;
        defer r.deinit();
    }

    {
        const r = (try runtime.request(acct, 2, "close")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("error: balance must be zero to close\n", r.bytes);
    }

    // Withdraw all, then close succeeds
    {
        const r = (try runtime.request(acct, 3, "withdraw|500|drain")) orelse return error.ExpectedReply;
        defer r.deinit();
    }
    {
        const r = (try runtime.request(acct, 4, "close")) orelse return error.ExpectedReply;
        defer r.deinit();
        try std.testing.expectEqualStrings("ok\n", r.bytes);
    }
}

test "bank gateway round-trips requests" {
    const TinyGateway = durable.TinyGateway;

    var store = MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();

    var runtime = durable.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{
        .snapshot_every = 64,
    });
    defer runtime.deinit();
    defer runtime.shutdown() catch {};

    try runtime.registerFactory("bank", durable.Factory.from(BankAccountService, BankAccountService.create));

    var gateway = TinyGateway.init(std.testing.allocator, &runtime, .{});

    // Deposit via gateway

    const deposit_req =
        "kind: bank\n" ++
        "key: acme:savings\n" ++
        "message-id: 1\n" ++
        "content-length: 25\n" ++
        "\n" ++
        "deposit|50000|big savings";

    const deposit_resp = try gateway.handleBytes(deposit_req);
    defer deposit_resp.deinit();
    try std.testing.expectEqualStrings("status: ok\ncontent-length: 3\n\nok\n", deposit_resp.bytes);

    // Balance via gateway

    const balance_req =
        "kind: bank\n" ++
        "key: acme:savings\n" ++
        "message-id: 2\n" ++
        "content-length: 7\n" ++
        "\n" ++
        "balance";

    const balance_resp = try gateway.handleBytes(balance_req);
    defer balance_resp.deinit();
    try std.testing.expect(std.mem.startsWith(u8, balance_resp.bytes, "status: ok\ncontent-length: "));
    try std.testing.expect(std.mem.indexOf(u8, balance_resp.bytes, "balance_cents=50000") != null);
}
