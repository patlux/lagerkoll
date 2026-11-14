//! The state file between runs: JSON, written atomically, readable by its owner only.

const std = @import("std");
const check = @import("check.zig");

pub const LoadError = error{ InvalidState, OutOfMemory } || std.Io.Dir.ReadFileAllocError;

/// The stored state, or null when there is none yet. Memory lives in `arena`.
pub fn load(arena: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!?check.State {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    const st = try parse(arena, text);
    return st;
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) error{ InvalidState, OutOfMemory }!check.State {
    const st = std.json.parseFromSliceLeaky(check.State, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidState,
    };
    if (st.version != 1) return error.InvalidState;
    return st;
}

pub fn serialize(gpa: std.mem.Allocator, st: check.State) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(gpa, st, .{ .whitespace = .indent_2 });
}

/// Replaces `path` in one step (temporary file and rename), mode 0600.
pub fn save(gpa: std.mem.Allocator, io: std.Io, path: []const u8, st: check.State) !void {
    const text = try serialize(gpa, st);
    defer gpa.free(text);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = .fromMode(0o600),
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, text);
    try atomic.file.writeStreamingAll(io, "\n");
    try atomic.replace(io);
}

const testing = std.testing;

test "state round-trips and ignores unknown fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = [_]check.ItemState{
        .{ .item_no = "30630088", .available = false, .restock_announced = true },
        .{ .item_no = "80458207", .available = true, .restock_announced = false },
    };
    const st: check.State = .{
        .consecutive_failures = 2,
        .failure_warned = true,
        .last_success_unix = 1763140000,
        .items = &items,
    };
    const text = try serialize(arena, st);
    const back = try parse(arena, text);
    try testing.expectEqual(@as(u32, 2), back.consecutive_failures);
    try testing.expect(back.failure_warned);
    try testing.expectEqual(@as(i64, 1763140000), back.last_success_unix);
    try testing.expectEqualStrings("30630088", back.items[0].item_no);
    try testing.expect(back.items[0].restock_announced);
    try testing.expect(back.items[1].available);

    const later = try parse(arena, "{\"version\":1,\"items\":[],\"something_new\":true}");
    try testing.expectEqual(@as(usize, 0), later.items.len);
    try testing.expectError(error.InvalidState, parse(arena, "{\"version\":2}"));
    try testing.expectError(error.InvalidState, parse(arena, "not json"));
}

test "save writes a private file that load reads back" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const path = try std.Io.Dir.path.join(arena, &.{ dir_path, "state.json" });
    try testing.expect((try load(arena, io, path)) == null);

    const items = [_]check.ItemState{.{ .item_no = "30630088", .available = true, .restock_announced = false }};
    try save(testing.allocator, io, path, .{ .items = &items });
    try save(testing.allocator, io, path, .{ .consecutive_failures = 1, .items = &items });
    const back = (try load(arena, io, path)).?;
    try testing.expectEqual(@as(u32, 1), back.consecutive_failures);
    try testing.expect(back.items[0].available);

    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}
