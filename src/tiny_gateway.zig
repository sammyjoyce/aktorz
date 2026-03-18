const std = @import("std");
const core = @import("core.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const TinyGateway = struct {
    alloc: Allocator,
    runtime: *core.Runtime,
    max_payload_bytes: usize,

    pub const Config = struct {
        max_payload_bytes: usize = 64 * 1024,
    };

    pub fn init(alloc: Allocator, runtime: *core.Runtime, config: Config) TinyGateway {
        return .{
            .alloc = alloc,
            .runtime = runtime,
            .max_payload_bytes = config.max_payload_bytes,
        };
    }

    /// Handles exactly one request from `reader` and writes exactly one response to `writer`.
    ///
    /// Protocol:
    ///
    /// kind: <service-kind>\n
    /// key: <service-key>\n
    /// message-id: <decimal-u128>\n
    /// content-length: <decimal-usize>\n
    /// \n
    /// <payload-bytes>
    ///
    /// Response:
    ///
    /// status: ok|noreply|error\n
    /// content-length: <decimal-usize>\n
    /// \n
    /// <reply-or-error-body>
    pub fn serveIo(self: *TinyGateway, reader: *Io.Reader, writer: *Io.Writer) !void {
        const response = try self.readAndHandle(reader);
        defer response.deinit();

        try writer.writeAll(response.bytes);
        try writer.flush();
    }

    pub fn handleBytes(self: *TinyGateway, request: []const u8) !core.OwnedBytes {
        var reader = Io.Reader.fixed(request);
        var out: Io.Writer.Allocating = .init(self.alloc);
        errdefer out.deinit();

        try self.serveIo(&reader, &out.writer);
        return .fromOwned(self.alloc, try out.toOwnedSlice());
    }

    fn readAndHandle(self: *TinyGateway, reader: *Io.Reader) !core.OwnedBytes {
        const req = self.readRequest(reader) catch |err| {
            return try encodeResponse(self.alloc, "error", @errorName(err));
        };
        defer req.deinit(self.alloc);

        const maybe_reply = self.runtime.request(.{
            .kind = req.kind,
            .key = req.key,
        }, req.message_id, req.payload) catch |err| {
            return try encodeResponse(self.alloc, "error", @errorName(err));
        };

        if (maybe_reply) |reply| {
            defer reply.deinit();
            return try encodeResponse(self.alloc, "ok", reply.bytes);
        }

        return try encodeResponse(self.alloc, "noreply", "");
    }

    fn readRequest(self: *TinyGateway, reader: *Io.Reader) !OwnedRequest {
        var kind: ?[]u8 = null;
        errdefer if (kind) |value| self.alloc.free(value);

        var key: ?[]u8 = null;
        errdefer if (key) |value| self.alloc.free(value);

        var message_id: ?u128 = null;
        var content_length: ?usize = null;

        while (true) {
            const raw_line = (try reader.takeDelimiter('\n')) orelse return error.UnexpectedEndOfHeaders;
            const line = trimAsciiSpace(raw_line);
            if (line.len == 0) break;

            const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeaderLine;
            const name = trimAsciiSpace(line[0..colon_index]);
            const value = trimAsciiSpace(line[colon_index + 1 ..]);

            if (std.mem.eql(u8, name, "kind")) {
                if (kind != null) return error.DuplicateHeader;
                kind = try self.alloc.dupe(u8, value);
                continue;
            }

            if (std.mem.eql(u8, name, "key")) {
                if (key != null) return error.DuplicateHeader;
                key = try self.alloc.dupe(u8, value);
                continue;
            }

            if (std.mem.eql(u8, name, "message-id")) {
                if (message_id != null) return error.DuplicateHeader;
                message_id = std.fmt.parseUnsigned(u128, value, 10) catch return error.InvalidMessageId;
                continue;
            }

            if (std.mem.eql(u8, name, "content-length")) {
                if (content_length != null) return error.DuplicateHeader;
                const parsed = std.fmt.parseUnsigned(usize, value, 10) catch return error.InvalidContentLength;
                if (parsed > self.max_payload_bytes) return error.PayloadTooLarge;
                content_length = parsed;
                continue;
            }

            // Unknown headers are ignored so callers can extend the protocol.
        }

        const final_kind = kind orelse return error.MissingKind;
        const final_key = key orelse return error.MissingKey;
        const final_message_id = message_id orelse return error.MissingMessageId;
        const final_length = content_length orelse return error.MissingContentLength;

        const payload = try self.alloc.alloc(u8, final_length);
        errdefer self.alloc.free(payload);

        if (payload.len > 0) {
            var vecs: [1][]u8 = .{payload};
            try reader.readVecAll(vecs[0..]);
        }

        return .{
            .kind = final_kind,
            .key = final_key,
            .message_id = final_message_id,
            .payload = payload,
        };
    }
};

pub const TcpGateway = struct {
    alloc: Allocator,
    io: Io,
    gateway: *TinyGateway,
    read_buffer_len: usize,
    write_buffer_len: usize,

    pub const Config = struct {
        read_buffer_len: usize = 4 * 1024,
        write_buffer_len: usize = 4 * 1024,
    };

    pub fn init(alloc: Allocator, io: Io, gateway: *TinyGateway, config: Config) TcpGateway {
        return .{
            .alloc = alloc,
            .io = io,
            .gateway = gateway,
            .read_buffer_len = config.read_buffer_len,
            .write_buffer_len = config.write_buffer_len,
        };
    }

    /// Sequential, single-threaded accept loop. One request per connection.
    pub fn serveForever(self: *TcpGateway, address: Io.net.IpAddress) !void {
        var server = try address.listen(self.io, .{
            .reuse_address = true,
        });
        defer server.deinit(self.io);

        while (true) {
            var stream = try server.accept(self.io);
            defer stream.close(self.io);
            try self.serveAccepted(stream);
        }
    }

    pub fn serveAccepted(self: *TcpGateway, stream: Io.net.Stream) !void {
        const read_buf = try self.alloc.alloc(u8, self.read_buffer_len);
        defer self.alloc.free(read_buf);

        const write_buf = try self.alloc.alloc(u8, self.write_buffer_len);
        defer self.alloc.free(write_buf);

        var reader = stream.reader(self.io, read_buf);
        var writer = stream.writer(self.io, write_buf);
        try self.gateway.serveIo(&reader.interface, &writer.interface);
    }
};

const OwnedRequest = struct {
    kind: []u8,
    key: []u8,
    message_id: u128,
    payload: []u8,

    fn deinit(self: OwnedRequest, alloc: Allocator) void {
        alloc.free(self.kind);
        alloc.free(self.key);
        alloc.free(self.payload);
    }
};

fn trimAsciiSpace(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r");
}

fn encodeResponse(alloc: Allocator, status: []const u8, body: []const u8) !core.OwnedBytes {
    var out: Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.print("status: {s}\ncontent-length: {d}\n\n", .{ status, body.len });
    try out.writer.writeAll(body);

    return .fromOwned(alloc, try out.toOwnedSlice());
}

test "tiny gateway returns protocol errors as framed responses" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    var store = @import("memory_store.zig").MemoryNodeStore.init(std.testing.allocator);
    defer store.deinit();

    var runtime = core.Runtime.init(std.testing.allocator, store.asStoreProvider(), .{});
    defer runtime.deinit();

    var gateway = TinyGateway.init(std.testing.allocator, &runtime, .{
        .max_payload_bytes = 8,
    });

    var reader = Io.Reader.fixed(
        "kind: cart\n" ++
            "key: x\n" ++
            "message-id: 1\n" ++
            "content-length: 99\n" ++
            "\n",
    );

    try gateway.serveIo(&reader, &out.writer);
    try std.testing.expectEqualStrings(
        "status: error\ncontent-length: 15\n\nPayloadTooLarge",
        out.written(),
    );
}
