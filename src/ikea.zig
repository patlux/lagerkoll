//! IKEA's availability API, the one the product pages of ikea.com use.
//! Not documented by IKEA: the field meanings come from the field names and from
//! comparing answers with the website.

const std = @import("std");
const config = @import("config.zig");

pub const Restock = struct {
    /// `YYYY-MM-DD`
    earliest: []const u8,
    latest: []const u8,
};

pub const Observation = struct {
    item_no: []const u8,
    /// Pieces for cash & carry in the store; null when the store has no figure
    /// (article not in its range, or no cash & carry data).
    quantity: ?u32,
    /// The earliest announced delivery, if any.
    restock: ?Restock,
};

/// The request URL for all items of the list in one store.
pub fn availabilityUrl(
    gpa: std.mem.Allocator,
    api_url: []const u8,
    store_id: []const u8,
    items: []const config.Item,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    w.print("{s}/cia/availabilities/sto/{s}?itemNos=", .{ api_url, store_id }) catch return error.OutOfMemory;
    for (items, 0..) |item, i| {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.writeAll(item.item_no) catch return error.OutOfMemory;
    }
    w.writeAll("&expand=Restocks") catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

pub const FetchError = error{ HttpStatus, ResponseTooLarge } || std.http.Client.FetchError || error{OutOfMemory};

/// GETs `url` and returns the body (caller frees). Any status other than 200 is `HttpStatus`.
pub fn fetch(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    url: []const u8,
    client_id: []const u8,
    user_agent: []const u8,
    status_out: *u16,
) FetchError![]u8 {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const extra = [_]std.http.Header{
        .{ .name = "X-Client-Id", .value = client_id },
        .{ .name = "Accept", .value = "application/json;version=2" },
    };
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = &extra,
        .response_writer = &body.writer,
    });
    status_out.* = @backingInt(result.status);
    if (result.status != .ok) return error.HttpStatus;
    if (body.written().len > 4 * 1024 * 1024) return error.ResponseTooLarge;
    return body.toOwnedSlice();
}

const Wire = struct {
    availabilities: []const Availability = &.{},

    const Availability = struct {
        itemKey: ItemKey,
        classUnitKey: ClassUnitKey,
        buyingOption: ?BuyingOption = null,
    };
    const ItemKey = struct { itemNo: []const u8 };
    const ClassUnitKey = struct { classUnitCode: []const u8, classUnitType: []const u8 };
    const BuyingOption = struct { cashCarry: ?CashCarry = null };
    const CashCarry = struct {
        range: ?Range = null,
        availability: ?Stock = null,
    };
    const Range = struct { inRange: bool = false };
    const Stock = struct {
        quantity: ?i64 = null,
        restocks: ?[]const WireRestock = null,
    };
    const WireRestock = struct {
        earliestDate: []const u8,
        latestDate: []const u8,
    };
};

pub const ParseError = error{ InvalidResponse, OutOfMemory };

/// The observations for `store_id`, in the order of the answer. Items the answer does
/// not mention are missing from the result.
pub fn parseAvailability(arena: std.mem.Allocator, body: []const u8, store_id: []const u8) ParseError![]Observation {
    const wire = std.json.parseFromSliceLeaky(Wire, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };

    var list: std.ArrayList(Observation) = .empty;
    for (wire.availabilities) |a| {
        if (!std.mem.eql(u8, a.classUnitKey.classUnitType, "STO")) continue;
        if (!std.mem.eql(u8, a.classUnitKey.classUnitCode, store_id)) continue;
        for (list.items) |seen| {
            if (std.mem.eql(u8, seen.item_no, a.itemKey.itemNo)) break;
        } else try list.append(arena, try observe(a));
    }
    return list.toOwnedSlice(arena);
}

fn observe(a: Wire.Availability) ParseError!Observation {
    var obs: Observation = .{ .item_no = a.itemKey.itemNo, .quantity = null, .restock = null };
    const cc = (a.buyingOption orelse return obs).cashCarry orelse return obs;
    const in_range = if (cc.range) |r| r.inRange else false;
    const stock = cc.availability orelse return obs;
    if (!in_range) return obs;
    if (stock.quantity) |q| obs.quantity = std.math.cast(u32, q) orelse return error.InvalidResponse;
    if (stock.restocks) |restocks| for (restocks) |r| {
        if (!isIsoDate(r.earliestDate) or !isIsoDate(r.latestDate)) return error.InvalidResponse;
        // ISO dates compare as strings.
        if (obs.restock == null or std.mem.order(u8, r.earliestDate, obs.restock.?.earliest) == .lt)
            obs.restock = .{ .earliest = r.earliestDate, .latest = r.latestDate };
    };
    return obs;
}

pub fn isIsoDate(s: []const u8) bool {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return false;
    for (s, 0..) |c, i| {
        if (i == 4 or i == 7) continue;
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

const testing = std.testing;

test "availabilityUrl lists every article once" {
    const items = [_]config.Item{
        .{ .item_no = "30630088", .name = "a", .quantity = 9 },
        .{ .item_no = "70589416", .name = "b", .quantity = 4 },
    };
    const url = try availabilityUrl(testing.allocator, config.default_api_url, "326", &items);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://api.ingka.ikea.com/cia/availabilities/sto/326?itemNos=30630088,70589416&expand=Restocks",
        url,
    );
}

test "parseAvailability reads stock, range and the earliest restock of the store" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const obs = try parseAvailability(arena_state.allocator(), @embedFile("testdata/availability.json"), "326");
    try testing.expectEqual(@as(usize, 4), obs.len);

    try testing.expectEqualStrings("30630088", obs[0].item_no);
    try testing.expectEqual(@as(?u32, 0), obs[0].quantity);
    try testing.expectEqualStrings("2026-11-19", obs[0].restock.?.earliest);
    try testing.expectEqualStrings("2026-11-26", obs[0].restock.?.latest);

    try testing.expectEqualStrings("70589416", obs[1].item_no);
    try testing.expectEqual(@as(?u32, 0), obs[1].quantity);
    try testing.expect(obs[1].restock == null);

    try testing.expectEqualStrings("80458207", obs[2].item_no);
    try testing.expectEqual(@as(?u32, 174), obs[2].quantity);

    // Not in the store's range: no figure.
    try testing.expectEqualStrings("10604165", obs[3].item_no);
    try testing.expectEqual(@as(?u32, null), obs[3].quantity);
}

test "parseAvailability ignores other stores and rejects nonsense" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The fixture carries one entry of store 063 for an article of the list.
    const other = try parseAvailability(arena, @embedFile("testdata/availability.json"), "063");
    try testing.expectEqual(@as(usize, 1), other.len);
    try testing.expectEqual(@as(?u32, 56), other[0].quantity);
    try testing.expect(other[0].restock == null);
    const none = try parseAvailability(arena, @embedFile("testdata/availability.json"), "999");
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expectError(error.InvalidResponse, parseAvailability(arena, "<html>", "326"));
    try testing.expectError(error.InvalidResponse, parseAvailability(arena,
        \\{"availabilities":[{"itemKey":{"itemNo":"1"},"classUnitKey":{"classUnitCode":"326","classUnitType":"STO"},
        \\ "buyingOption":{"cashCarry":{"range":{"inRange":true},"availability":{"quantity":-3}}}}]}
    , "326"));
    try testing.expectError(error.InvalidResponse, parseAvailability(arena,
        \\{"availabilities":[{"itemKey":{"itemNo":"1"},"classUnitKey":{"classUnitCode":"326","classUnitType":"STO"},
        \\ "buyingOption":{"cashCarry":{"range":{"inRange":true},"availability":{"quantity":0,
        \\ "restocks":[{"earliestDate":"19.11.","latestDate":"2026-11-26"}]}}}}]}
    , "326"));
}
