//! Pushes through an ntfy server (JSON publishing to the server root).

const std = @import("std");
const check = @import("check.zig");

pub const CredentialError = error{
    InvalidCredentials,
    CredentialsReadableByOthers,
    CredentialsNotAFile,
    OutOfMemory,
} || std.Io.Dir.StatFileError || std.Io.Dir.ReadFileAllocError;

/// Reads the credentials file and returns the `Authorization` header value. The file must be
/// a regular file that neither group nor others may read or write.
pub fn loadAuthorization(arena: std.mem.Allocator, io: std.Io, path: []const u8) CredentialError![]const u8 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file) return error.CredentialsNotAFile;
    if (stat.permissions.toMode() & 0o077 != 0) return error.CredentialsReadableByOthers;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidCredentials,
        else => |e| return e,
    };
    return authorization(arena, text);
}

/// `tk_…` (an ntfy access token) → `Bearer tk_…`; `user:password` → `Basic …`.
pub fn authorization(arena: std.mem.Allocator, text: []const u8) error{ InvalidCredentials, OutOfMemory }![]const u8 {
    const secret = std.mem.trim(u8, text, " \t\r\n");
    if (secret.len == 0 or std.mem.findAny(u8, secret, "\r\n") != null) return error.InvalidCredentials;
    if (std.mem.startsWith(u8, secret, "tk_")) {
        if (std.mem.findAny(u8, secret, " \t:") != null) return error.InvalidCredentials;
        return arena.print("Bearer {s}", .{secret});
    }
    const colon = std.mem.findScalar(u8, secret, ':') orelse return error.InvalidCredentials;
    if (colon == 0 or colon == secret.len - 1) return error.InvalidCredentials;
    const enc = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, "Basic ".len + enc.calcSize(secret.len));
    @memcpy(out[0.."Basic ".len], "Basic ");
    _ = enc.encode(out["Basic ".len..], secret);
    return out;
}

const Publish = struct {
    topic: []const u8,
    title: []const u8,
    message: []const u8,
    tags: []const []const u8,
    priority: u8 = 3,
    click: ?[]const u8 = null,
};

pub fn body(arena: std.mem.Allocator, topic: []const u8, msg: check.Message) error{OutOfMemory}![]u8 {
    const tags = try arena.alloc([]const u8, 1);
    tags[0] = msg.tag;
    return std.json.Stringify.valueAlloc(arena, Publish{
        .topic = topic,
        .title = msg.title,
        .message = msg.body,
        .tags = tags,
        .click = msg.click,
    }, .{ .emit_null_optional_fields = false });
}

pub const PublishError = error{HttpStatus} || std.http.Client.FetchError || error{OutOfMemory};

/// POSTs one message and returns ntfy's message id (null if the answer has none). Success means
/// ntfy accepted it, not that a phone shows it.
pub fn publish(
    client: *std.http.Client,
    arena: std.mem.Allocator,
    server: []const u8,
    auth: []const u8,
    user_agent: []const u8,
    topic: []const u8,
    msg: check.Message,
    status_out: *u16,
) PublishError!?[]const u8 {
    const payload = try body(arena, topic, msg);
    var answer: std.Io.Writer.Allocating = .init(arena);
    const url = try arena.print("{s}/", .{server});
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        // Never follow a redirect with the credentials.
        .redirect_behavior = .not_allowed,
        // Not `privileged_headers`: std.http.Client 0.17.1 stores them but never sends them
        // (`Request.sendHead`); the test below catches that.
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = user_agent },
        },
        .response_writer = &answer.writer,
    });
    status_out.* = @backingInt(result.status);
    if (result.status != .ok) return error.HttpStatus;
    return messageId(arena, answer.written());
}

/// The `id` of ntfy's answer, for the log; anything unexpected is no id, not an error.
pub fn messageId(arena: std.mem.Allocator, answer: []const u8) ?[]const u8 {
    const Answer = struct { id: ?[]const u8 = null };
    const parsed = std.json.parseFromSliceLeaky(Answer, arena, answer, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return null;
    const id = parsed.id orelse return null;
    if (id.len == 0 or id.len > 64) return null;
    for (id) |c| if (!std.ascii.isAlphanumeric(c)) return null;
    return id;
}

const testing = std.testing;

test "authorization accepts a token or user:password" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("Bearer tk_abc123", try authorization(arena, "tk_abc123\n"));
    try testing.expectEqualStrings("Basic dXNlcjpwYXNz", try authorization(arena, "user:pass\n"));
    try testing.expectEqualStrings("Basic dTpwOnc=", try authorization(arena, "u:p:w"));
    for ([_][]const u8{ "", "\n", "nocolon", ":pass", "user:", "a:b\nc:d", "tk_a b" }) |bad| {
        try testing.expectError(error.InvalidCredentials, authorization(arena, bad));
    }
}

test "loadAuthorization refuses a file others can read" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const open_path = try std.Io.Dir.path.join(arena, &.{ dir_path, "open" });
    try tmp.dir.writeFile(io, .{ .sub_path = "open", .data = "u:p\n" });
    try tmp.dir.setFilePermissions(io, "open", .fromMode(0o644), .{});
    try testing.expectError(error.CredentialsReadableByOthers, loadAuthorization(arena, io, open_path));

    const private_path = try std.Io.Dir.path.join(arena, &.{ dir_path, "private" });
    try tmp.dir.writeFile(io, .{ .sub_path = "private", .data = "u:p\n" });
    try tmp.dir.setFilePermissions(io, "private", .fromMode(0o600), .{});
    try testing.expectEqualStrings("Basic dTpw", try loadAuthorization(arena, io, private_path));

    try testing.expectError(error.FileNotFound, loadAuthorization(arena, io, "/nonexistent/lagerkoll-credentials"));
}

test "messageId takes a plain id and nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("hR3x9", messageId(arena, "{\"id\":\"hR3x9\",\"time\":1,\"event\":\"message\"}").?);
    try testing.expect(messageId(arena, "{\"time\":1}") == null);
    try testing.expect(messageId(arena, "{\"id\":\"a\\nb\"}") == null);
    try testing.expect(messageId(arena, "not json") == null);
}

test "body is ntfy's JSON publish format" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json = try body(arena, "ikea", .{ .title = "T", .body = "a\n\"b\"", .tag = "truck" });
    try testing.expectEqualStrings(
        \\{"topic":"ikea","title":"T","message":"a\n\"b\"","tags":["truck"],"priority":3}
    , json);
    const with_click = try body(arena, "ikea", .{ .title = "T", .body = "m", .tag = "x", .click = "https://e.org" });
    try testing.expect(std.mem.find(u8, with_click, "\"click\":\"https://e.org\"") != null);
}

/// What the loopback server in the test below received.
const Seen = struct {
    method: std.http.Method = .GET,
    target_buf: [64]u8 = undefined,
    target_len: usize = 0,
    auth_buf: [128]u8 = undefined,
    auth_len: usize = 0,
    type_buf: [64]u8 = undefined,
    type_len: usize = 0,
    body_buf: [1024]u8 = undefined,
    body_len: usize = 0,
    failed: bool = false,

    fn keep(buf: []u8, len: *usize, value: []const u8) void {
        const n = @min(buf.len, value.len);
        @memcpy(buf[0..n], value[0..n]);
        len.* = n;
    }
};

fn serveOnce(io: std.Io, server: *std.Io.net.Server, seen: *Seen, status: std.http.Status) void {
    serveOnceInner(io, server, seen, status) catch {
        seen.failed = true;
    };
}

fn serveOnceInner(io: std.Io, server: *std.Io.net.Server, seen: *Seen, status: std.http.Status) !void {
    const stream = try server.accept(io);
    defer stream.close(io);
    var read_buf: [8192]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try http_server.receiveHead();
    seen.method = request.head.method;
    Seen.keep(&seen.target_buf, &seen.target_len, request.head.target);
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) Seen.keep(&seen.auth_buf, &seen.auth_len, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) Seen.keep(&seen.type_buf, &seen.type_len, h.value);
    }
    var body_buf: [1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buf);
    const n = try body_reader.readSliceShort(&seen.body_buf);
    seen.body_len = n;
    try request.respond("{\"id\":\"test\"}", .{ .status = status, .keep_alive = false });
}

test "publish posts the JSON with the credentials to the server root" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const url = try arena.print("http://127.0.0.1:{d}", .{server.socket.address.getPort()});

    var seen: Seen = .{};
    const thread = try std.Thread.spawn(.{}, serveOnce, .{ io, &server, &seen, std.http.Status.ok });
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var status: u16 = 0;
    const msg: check.Message = .{
        .title = "IKEA Teststadt: Flisberget verfügbar",
        .body = "Jetzt da",
        .tag = "white_check_mark",
    };
    const result = publish(&client, arena, url, "Bearer tk_test", "lagerkoll/test", "ikea", msg, &status);
    thread.join();
    try testing.expectEqualStrings("test", (try result).?);

    try testing.expect(!seen.failed);
    try testing.expectEqual(@as(u16, 200), status);
    try testing.expectEqual(std.http.Method.POST, seen.method);
    try testing.expectEqualStrings("/", seen.target_buf[0..seen.target_len]);
    try testing.expectEqualStrings("Bearer tk_test", seen.auth_buf[0..seen.auth_len]);
    try testing.expectEqualStrings("application/json", seen.type_buf[0..seen.type_len]);
    try testing.expectEqualStrings(try body(arena, "ikea", msg), seen.body_buf[0..seen.body_len]);
}

test "publish reports a refusal as HttpStatus" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const url = try arena.print("http://127.0.0.1:{d}", .{server.socket.address.getPort()});

    var seen: Seen = .{};
    const thread = try std.Thread.spawn(.{}, serveOnce, .{ io, &server, &seen, std.http.Status.forbidden });
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var status: u16 = 0;
    const msg: check.Message = .{ .title = "T", .body = "B", .tag = "x" };
    const result = publish(&client, arena, url, "Basic dTpw", "lagerkoll/test", "ikea", msg, &status);
    thread.join();
    try testing.expectError(error.HttpStatus, result);
    try testing.expectEqual(@as(u16, 403), status);
}
