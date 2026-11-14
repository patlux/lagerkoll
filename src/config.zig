//! The watch list: which store, which articles in which quantity, and where pushes go.

const std = @import("std");

pub const default_market = "de/de";

/// IKEA's API host; a config can point elsewhere for tests.
pub const default_api_url = "https://api.ingka.ikea.com";

/// The client id the IKEA website sends to its availability API (public, not a secret).
pub const default_client_id = "b6c117e5-ae61-4ef5-b4cc-e0b1e37f0631";

pub const Item = struct {
    /// Eight digits after `parse`; the file may use the printed form `306.300.88`.
    item_no: []const u8,
    name: []const u8,
    /// How many pieces are needed.
    quantity: u32,
};

pub const Ntfy = struct {
    /// `https://` server root, without a trailing slash after `parse`.
    url: []const u8,
    topic: []const u8,
    /// A file only its owner may read: `user:password` or an access token `tk_…`.
    credentials_file: []const u8,
};

pub const Config = struct {
    /// IKEA's store number (README: "Finding the store number").
    store_id: []const u8,
    /// Short name for messages, e.g. the town of the store.
    store_name: []const u8,
    /// Country and language of ikea.com for the link in a push, e.g. `de/de`, `at/de`, `gb/en`.
    market: []const u8 = default_market,
    client_id: []const u8 = default_client_id,
    api_url: []const u8 = default_api_url,
    /// Required for real runs; `--dry-run` works without it.
    ntfy: ?Ntfy = null,
    items: []const Item,
};

pub const ParseError = error{ InvalidConfig, OutOfMemory };

/// Parses and validates `source`. Everything lives in `arena`. On `InvalidConfig`,
/// `problem` names the reason.
pub fn parse(arena: std.mem.Allocator, source: []const u8, problem: *[]const u8) ParseError!Config {
    const json_options: std.json.ParseOptions = .{ .allocate = .alloc_always };
    var cfg = std.json.parseFromSliceLeaky(Config, arena, source, json_options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            problem.* = try arena.print("not a valid config ({t})", .{err});
            return error.InvalidConfig;
        },
    };

    if (!isDigits(cfg.store_id) or cfg.store_id.len > 6) {
        problem.* = "store_id must be IKEA's store number, digits only";
        return error.InvalidConfig;
    }
    if (cfg.store_name.len == 0 or cfg.store_name.len > 64) {
        problem.* = "store_name must have 1 to 64 bytes";
        return error.InvalidConfig;
    }
    if (cfg.client_id.len == 0 or !isToken(cfg.client_id)) {
        problem.* = "client_id must be letters, digits and dashes";
        return error.InvalidConfig;
    }
    if (!isMarket(cfg.market)) {
        problem.* = "market must be country/language in lower case, e.g. de/de";
        return error.InvalidConfig;
    }
    cfg.api_url = httpsRoot(cfg.api_url) orelse {
        problem.* = "api_url must be an https:// server root";
        return error.InvalidConfig;
    };
    if (cfg.items.len == 0 or cfg.items.len > 50) {
        problem.* = "items must list 1 to 50 articles (one API request)";
        return error.InvalidConfig;
    }

    const items = try arena.alloc(Item, cfg.items.len);
    for (cfg.items, items, 0..) |raw, *item, i| {
        const number = normalizeItemNo(arena, raw.item_no) catch {
            const why = "items[{d}]: item_no \"{s}\" is not an eight-digit article number";
            problem.* = try arena.print(why, .{ i, raw.item_no });
            return error.InvalidConfig;
        };
        if (raw.name.len == 0 or raw.name.len > 80) {
            problem.* = try arena.print("items[{d}]: name must have 1 to 80 bytes", .{i});
            return error.InvalidConfig;
        }
        if (raw.quantity == 0 or raw.quantity > 999) {
            problem.* = try arena.print("items[{d}]: quantity must be 1 to 999", .{i});
            return error.InvalidConfig;
        }
        for (items[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.item_no, number)) {
                problem.* = try arena.print("items[{d}]: article {s} is listed twice", .{ i, number });
                return error.InvalidConfig;
            }
        }
        item.* = .{ .item_no = number, .name = raw.name, .quantity = raw.quantity };
    }
    cfg.items = items;

    if (cfg.ntfy) |*ntfy| {
        ntfy.url = httpsRoot(ntfy.url) orelse {
            problem.* = "ntfy.url must be an https:// server root, e.g. https://ntfy.example.org";
            return error.InvalidConfig;
        };
        if (ntfy.topic.len == 0 or ntfy.topic.len > 64 or !isToken(ntfy.topic)) {
            problem.* = "ntfy.topic must be 1 to 64 letters, digits, '-' or '_'";
            return error.InvalidConfig;
        }
        if (ntfy.credentials_file.len == 0) {
            problem.* = "ntfy.credentials_file is empty";
            return error.InvalidConfig;
        }
    }
    return cfg;
}

/// `306.300.88` or `30630088` → `30630088`.
pub fn normalizeItemNo(arena: std.mem.Allocator, raw: []const u8) error{ InvalidItemNo, OutOfMemory }![]const u8 {
    var digits: [8]u8 = undefined;
    var n: usize = 0;
    for (raw) |c| switch (c) {
        '.', ' ' => {},
        '0'...'9' => {
            if (n == digits.len) return error.InvalidItemNo;
            digits[n] = c;
            n += 1;
        },
        else => return error.InvalidItemNo,
    };
    if (n != digits.len) return error.InvalidItemNo;
    return arena.dupe(u8, &digits);
}

/// `https://host[:port][/]` → without the trailing slash; anything else → null.
fn httpsRoot(url: []const u8) ?[]const u8 {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, url, scheme)) return null;
    const root = std.mem.trimEnd(u8, url, "/");
    if (root.len <= scheme.len) return null;
    if (std.mem.findScalarPos(u8, root, scheme.len, '/') != null) return null;
    if (std.mem.findAny(u8, root, "?#@ \\") != null) return null;
    return root;
}

fn isMarket(s: []const u8) bool {
    if (s.len != 5 or s[2] != '/') return false;
    for ([_]u8{ s[0], s[1], s[3], s[4] }) |c| if (!std.ascii.isLower(c)) return false;
    return true;
}

fn isDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isToken(s: []const u8) bool {
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

const testing = std.testing;

test "parse normalizes article numbers and the ntfy url" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var problem: []const u8 = "";
    const cfg = try parse(arena_state.allocator(),
        \\{"store_id": "326", "store_name": "Teststadt", "market": "at/de",
        \\ "ntfy": {"url": "https://ntfy.example.org/", "topic": "ikea", "credentials_file": "/tmp/c"},
        \\ "items": [{"item_no": "306.300.88", "name": "Flisberget", "quantity": 9},
        \\           {"item_no": "70589416", "name": "Översidan 46 cm", "quantity": 4}]}
    , &problem);
    try testing.expectEqualStrings("30630088", cfg.items[0].item_no);
    try testing.expectEqualStrings("70589416", cfg.items[1].item_no);
    try testing.expectEqual(@as(u32, 9), cfg.items[0].quantity);
    try testing.expectEqualStrings("https://ntfy.example.org", cfg.ntfy.?.url);
    try testing.expectEqualStrings(default_client_id, cfg.client_id);
    try testing.expectEqualStrings(default_api_url, cfg.api_url);
    try testing.expectEqualStrings("at/de", cfg.market);
}

test "parse rejects bad entries with a reason" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const one_item =
        \\"items":[{"item_no":"30630088","name":"a","quantity":1}]}
    ;
    const cases = [_]struct { json: []const u8, needle: []const u8 }{
        .{ .json = "{\"store_id\":\"32x\",\"store_name\":\"F\"," ++ one_item, .needle = "store_id" },
        .{ .json = "{\"store_id\":\"326\",\"store_name\":\"F\",\"items\":[]}", .needle = "items" },
        .{ .json =
        \\{"store_id":"326","store_name":"F","items":[{"item_no":"3063008","name":"a","quantity":1}]}
        , .needle = "eight-digit" },
        .{ .json =
        \\{"store_id":"326","store_name":"F","items":[{"item_no":"30630088","name":"a","quantity":0}]}
        , .needle = "quantity" },
        .{ .json =
        \\{"store_id":"326","store_name":"F","items":[{"item_no":"30630088","name":"a","quantity":1},
        \\ {"item_no":"306.300.88","name":"b","quantity":1}]}
        , .needle = "twice" },
        .{ .json =
        \\{"store_id":"326","store_name":"F",
        \\ "ntfy":{"url":"http://x","topic":"t","credentials_file":"/c"},
        ++ one_item, .needle = "https" },
        .{ .json =
        \\{"store_id":"326","store_name":"F",
        \\ "ntfy":{"url":"https://x/pi","topic":"t","credentials_file":"/c"},
        ++ one_item, .needle = "root" },
        .{ .json =
        \\{"store_id":"326","store_name":"F",
        \\ "ntfy":{"url":"https://x","topic":"a/b","credentials_file":"/c"},
        ++ one_item, .needle = "topic" },
        .{ .json =
        \\{"store_id":"326","store_name":"F","api_url":"http://x",
        ++ one_item, .needle = "api_url" },
        .{ .json =
        \\{"store_id":"326","store_name":"F","market":"DE",
        ++ one_item, .needle = "market" },
        .{ .json = "{\"store_id\":\"326\"", .needle = "not a valid config" },
    };
    for (cases) |case| {
        var problem: []const u8 = "";
        try testing.expectError(error.InvalidConfig, parse(arena, case.json, &problem));
        if (std.mem.find(u8, problem, case.needle) == null) {
            std.debug.print("problem \"{s}\" lacks \"{s}\"\n", .{ problem, case.needle });
            return error.TestUnexpectedResult;
        }
    }
}
