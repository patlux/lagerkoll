//! One check: compare the store's stock with the list and the last run, decide what to push.
//! Pure: no I/O, so every rule has a test.

const std = @import("std");
const config = @import("config.zig");
const ikea = @import("ikea.zig");

pub const Status = enum {
    /// At least the needed quantity.
    available,
    /// Some, but fewer than needed.
    short,
    out,
    /// The answer had no figure for the article (missing, or not in the store's range).
    unknown,
};

/// What the next run needs to know about one article.
pub const ItemState = struct {
    item_no: []const u8,
    available: bool,
    restock_announced: bool,
};

/// The state file. Unknown fields are ignored on load, so later versions can add some.
pub const State = struct {
    version: u32 = 1,
    consecutive_failures: u32 = 0,
    failure_warned: bool = false,
    last_success_unix: i64 = 0,
    items: []const ItemState = &.{},
};

pub const ItemResult = struct {
    item: config.Item,
    status: Status,
    quantity: ?u32,
    restock: ?ikea.Restock,
    became_available: bool,
    restock_new: bool,
};

pub const Outcome = struct {
    results: []const ItemResult,
    /// No earlier successful run: send the overview instead of changes.
    first_run: bool,
    /// The item states to store; the failure fields are the caller's.
    items: []const ItemState,

    pub fn availableCount(o: Outcome) usize {
        var n: usize = 0;
        for (o.results) |r| n += @intFromBool(r.status == .available);
        return n;
    }
};

pub fn evaluate(
    arena: std.mem.Allocator,
    items: []const config.Item,
    observations: []const ikea.Observation,
    previous: ?State,
) error{OutOfMemory}!Outcome {
    const prev_items: []const ItemState = if (previous) |p| p.items else &.{};
    const first_run = prev_items.len == 0;
    const results = try arena.alloc(ItemResult, items.len);
    const states = try arena.alloc(ItemState, items.len);

    for (items, results, states) |item, *result, *state| {
        const obs = find(ikea.Observation, observations, item.item_no);
        const quantity: ?u32 = if (obs) |o| o.quantity else null;
        const status: Status = if (quantity) |q|
            (if (q >= item.quantity) .available else if (q == 0) .out else .short)
        else
            .unknown;
        const restock: ?ikea.Restock = if (obs) |o| o.restock else null;
        const prev = find(ItemState, prev_items, item.item_no);

        if (status == .unknown) {
            // A gap in the answer is no change: keep what the last run knew, so the
            // next good answer does not announce an article that never left.
            state.* = prev orelse .{ .item_no = item.item_no, .available = false, .restock_announced = false };
            result.* = .{
                .item = item,
                .status = status,
                .quantity = null,
                .restock = restock,
                .became_available = false,
                .restock_new = false,
            };
            continue;
        }

        const available = status == .available;
        const announced = !available and restock != null;
        state.* = .{ .item_no = item.item_no, .available = available, .restock_announced = announced };
        result.* = .{
            .item = item,
            .status = status,
            .quantity = quantity,
            .restock = restock,
            // An article added to the list later has no history: no event for it.
            .became_available = available and prev != null and !prev.?.available,
            .restock_new = announced and prev != null and !prev.?.restock_announced,
        };
    }
    return .{ .results = results, .first_run = first_run, .items = states };
}

fn find(comptime T: type, list: []const T, item_no: []const u8) ?T {
    for (list) |entry| if (std.mem.eql(u8, entry.item_no, item_no)) return entry;
    return null;
}

pub const Message = struct {
    title: []const u8,
    body: []const u8,
    tag: []const u8,
    click: ?[]const u8 = null,
};

/// ntfy stores at most 4096 bytes of message text.
pub const max_body = 4000;

/// What a push is about; the first that applies wins.
const Kind = enum { overview, available, restock };

/// The push for this outcome, or null when nothing changed that is worth one.
/// `market` is ikea.com's country/language path for the link, e.g. `de/de`.
pub fn compose(
    arena: std.mem.Allocator,
    store_name: []const u8,
    market: []const u8,
    outcome: Outcome,
) error{OutOfMemory}!?Message {
    var became: usize = 0;
    var restocked: usize = 0;
    var first_became: ?ItemResult = null;
    for (outcome.results) |r| {
        if (r.became_available) {
            became += 1;
            if (first_became == null) first_became = r;
        }
        restocked += @intFromBool(r.restock_new);
    }
    const kind: Kind = if (outcome.first_run)
        .overview
    else if (became > 0)
        .available
    else if (restocked > 0)
        .restock
    else
        return null;

    const title, const tag = switch (kind) {
        .overview => .{ try arena.print("IKEA {s}: Überwachung aktiv", .{store_name}), "eyes" },
        .available => .{
            if (became == 1)
                try arena.print("IKEA {s}: {s} verfügbar", .{ store_name, first_became.?.item.name })
            else
                try arena.print("IKEA {s}: {d} Artikel verfügbar", .{ store_name, became }),
            "white_check_mark",
        },
        .restock => .{ try arena.print("IKEA {s}: Nachlieferung angekündigt", .{store_name}), "truck" },
    };

    var body: std.Io.Writer.Allocating = .init(arena);
    writeBody(&body.writer, kind, outcome) catch return error.OutOfMemory;
    var text = body.written();
    if (text.len > max_body) {
        const cut = std.mem.findScalarLast(u8, text[0..max_body], '\n') orelse max_body;
        text = try arena.print("{s}\n…", .{text[0..cut]});
    }
    const click: ?[]const u8 = if (kind == .available and became == 1)
        try arena.print("https://www.ikea.com/{s}/search/?q={s}", .{ market, first_became.?.item.item_no })
    else
        null;
    return .{ .title = title, .body = text, .tag = tag, .click = click };
}

fn writeBody(w: *std.Io.Writer, kind: Kind, outcome: Outcome) std.Io.Writer.Error!void {
    const total = outcome.results.len;
    const available = outcome.availableCount();
    switch (kind) {
        .overview => try w.print("{d} von {d} Artikeln sind in der nötigen Menge da.", .{ available, total }),
        .available => {
            try w.writeAll("Jetzt da:");
            for (outcome.results) |r| if (r.became_available) {
                try w.print("\n- {s}: {d} Stück (du brauchst {d})", .{ r.item.name, r.quantity.?, r.item.quantity });
            };
        },
        .restock => {
            try w.writeAll("Nachlieferung angekündigt:");
            for (outcome.results) |r| if (r.restock_new) {
                try w.print("\n- {s}: {f}", .{ r.item.name, fmtRange(r.restock.?) });
            };
        },
    }

    // What is still missing, so every push tells whether the trip is worth it.
    if (available == total) return w.writeAll("\n\nAlles auf der Liste ist verfügbar.");
    try w.writeAll("\n\nNoch offen:");
    for (outcome.results) |r| if (r.status != .available) {
        try w.print("\n- {s}: {f}/{d}", .{ r.item.name, fmtQuantity(r.quantity), r.item.quantity });
        if (r.restock) |rs| try w.print(", Nachlieferung {f}", .{fmtRange(rs)});
    };
}

pub fn failureMessage(arena: std.mem.Allocator, failures: u32, err_name: []const u8) error{OutOfMemory}!Message {
    const text = "Die letzten {d} Abfragen sind fehlgeschlagen ({s}). Details im Log von lagerkoll.";
    return .{
        .title = "IKEA-Prüfung gestört",
        .body = try arena.print(text, .{ failures, err_name }),
        .tag = "warning",
    };
}

pub const recovery_message: Message = .{
    .title = "IKEA-Prüfung läuft wieder",
    .body = "Die Abfrage klappt wieder. Änderungen meldet sie wie gewohnt.",
    .tag = "white_check_mark",
};

/// `2026-11-19`/`2026-11-26` → `19.11.–26.11.`, one date when both are equal.
pub fn fmtRange(r: ikea.Restock) std.fmt.Alt(ikea.Restock, writeRange) {
    return .{ .data = r };
}

fn writeRange(r: ikea.Restock, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeDate(r.earliest, w);
    if (!std.mem.eql(u8, r.earliest, r.latest)) {
        try w.writeAll("–");
        try writeDate(r.latest, w);
    }
}

fn writeDate(iso: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // ikea.parseAvailability only lets valid YYYY-MM-DD through.
    try w.print("{s}.{s}.", .{ iso[8..10], iso[5..7] });
}

pub fn fmtQuantity(q: ?u32) std.fmt.Alt(?u32, writeQuantity) {
    return .{ .data = q };
}

fn writeQuantity(q: ?u32, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (q) |n| try w.print("{d}", .{n}) else try w.writeAll("?");
}

const testing = std.testing;

const test_list = [_]config.Item{
    .{ .item_no = "30630088", .name = "Flisberget", .quantity = 9 },
    .{ .item_no = "70589416", .name = "Översidan 46 cm", .quantity = 4 },
    .{ .item_no = "80458207", .name = "Korpus 1m", .quantity = 1 },
};

fn observed(item_no: []const u8, quantity: ?u32, restock: ?ikea.Restock) ikea.Observation {
    return .{ .item_no = item_no, .quantity = quantity, .restock = restock };
}

const flis_restock: ikea.Restock = .{ .earliest = "2026-11-19", .latest = "2026-11-26" };

/// The answer for the three test articles: Flisberget, Översidan, Korpus.
fn snapshot(
    flis: ?u32,
    flis_rs: ?ikea.Restock,
    over: ?u32,
    over_rs: ?ikea.Restock,
    korpus: ?u32,
) [3]ikea.Observation {
    return .{
        observed("30630088", flis, flis_rs),
        observed("70589416", over, over_rs),
        observed("80458207", korpus, null),
    };
}

fn withItems(items: []const ItemState) State {
    return .{ .items = items };
}

test "first run sends the overview with what is missing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const now = snapshot(0, flis_restock, 0, null, 174);
    const outcome = try evaluate(arena, &test_list, &now, null);
    try testing.expect(outcome.first_run);
    try testing.expectEqual(@as(usize, 1), outcome.availableCount());
    const msg = (try compose(arena, "Teststadt", "de/de", outcome)).?;
    try testing.expectEqualStrings("IKEA Teststadt: Überwachung aktiv", msg.title);
    try testing.expectEqualStrings(
        \\1 von 3 Artikeln sind in der nötigen Menge da.
        \\
        \\Noch offen:
        \\- Flisberget: 0/9, Nachlieferung 19.11.–26.11.
        \\- Översidan 46 cm: 0/4
    , msg.body);
    try testing.expect(msg.click == null);
    try testing.expect(outcome.items[0].restock_announced);
    try testing.expect(!outcome.items[0].available);
    try testing.expect(outcome.items[2].available);
}

test "an article that reaches the needed quantity is announced once" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = [_]ItemState{
        .{ .item_no = "30630088", .available = false, .restock_announced = true },
        .{ .item_no = "70589416", .available = false, .restock_announced = false },
        .{ .item_no = "80458207", .available = true, .restock_announced = false },
    };
    const now = snapshot(72, null, 2, null, 170);
    const outcome = try evaluate(arena, &test_list, &now, withItems(&before));
    try testing.expect(!outcome.first_run);
    try testing.expect(outcome.results[0].became_available);
    try testing.expectEqual(Status.short, outcome.results[1].status);
    const msg = (try compose(arena, "Teststadt", "de/de", outcome)).?;
    try testing.expectEqualStrings("IKEA Teststadt: Flisberget verfügbar", msg.title);
    try testing.expectEqualStrings(
        \\Jetzt da:
        \\- Flisberget: 72 Stück (du brauchst 9)
        \\
        \\Noch offen:
        \\- Översidan 46 cm: 2/4
    , msg.body);
    try testing.expectEqualStrings("white_check_mark", msg.tag);
    try testing.expectEqualStrings("https://www.ikea.com/de/de/search/?q=30630088", msg.click.?);

    // The next run with the same stock stays quiet.
    const again = try evaluate(arena, &test_list, &now, withItems(outcome.items));
    try testing.expect((try compose(arena, "Teststadt", "de/de", again)) == null);
}

test "several articles at once, and the list complete" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = [_]ItemState{
        .{ .item_no = "30630088", .available = false, .restock_announced = true },
        .{ .item_no = "70589416", .available = false, .restock_announced = false },
        .{ .item_no = "80458207", .available = true, .restock_announced = false },
    };
    const now = snapshot(9, null, 45, null, 1);
    const msg = (try compose(arena, "Teststadt", "de/de", try evaluate(arena, &test_list, &now, withItems(&before)))).?;
    try testing.expectEqualStrings("IKEA Teststadt: 2 Artikel verfügbar", msg.title);
    try testing.expectEqualStrings(
        \\Jetzt da:
        \\- Flisberget: 9 Stück (du brauchst 9)
        \\- Översidan 46 cm: 45 Stück (du brauchst 4)
        \\
        \\Alles auf der Liste ist verfügbar.
    , msg.body);
    try testing.expect(msg.click == null);
}

test "a newly announced delivery is pushed, the same one again is not" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = [_]ItemState{
        .{ .item_no = "30630088", .available = false, .restock_announced = true },
        .{ .item_no = "70589416", .available = false, .restock_announced = false },
        .{ .item_no = "80458207", .available = true, .restock_announced = false },
    };
    const same_day: ikea.Restock = .{ .earliest = "2026-12-01", .latest = "2026-12-01" };
    const now = snapshot(0, flis_restock, 0, same_day, 3);
    const outcome = try evaluate(arena, &test_list, &now, withItems(&before));
    const msg = (try compose(arena, "Teststadt", "de/de", outcome)).?;
    try testing.expectEqualStrings("IKEA Teststadt: Nachlieferung angekündigt", msg.title);
    try testing.expectEqualStrings(
        \\Nachlieferung angekündigt:
        \\- Översidan 46 cm: 01.12.
        \\
        \\Noch offen:
        \\- Flisberget: 0/9, Nachlieferung 19.11.–26.11.
        \\- Översidan 46 cm: 0/4, Nachlieferung 01.12.
    , msg.body);
    try testing.expectEqualStrings("truck", msg.tag);
    const repeat = try evaluate(arena, &test_list, &now, withItems(outcome.items));
    try testing.expect((try compose(arena, "Teststadt", "de/de", repeat)) == null);
}

test "a gap in the answer keeps the last state and announces nothing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = [_]ItemState{
        .{ .item_no = "30630088", .available = false, .restock_announced = true },
        .{ .item_no = "70589416", .available = false, .restock_announced = false },
        .{ .item_no = "80458207", .available = true, .restock_announced = false },
    };
    // Korpus missing from the answer, Översidan not in the range.
    const gap = [_]ikea.Observation{ observed("30630088", 0, flis_restock), observed("70589416", null, null) };
    const outcome = try evaluate(arena, &test_list, &gap, withItems(&before));
    try testing.expectEqual(Status.unknown, outcome.results[1].status);
    try testing.expectEqual(Status.unknown, outcome.results[2].status);
    try testing.expect(outcome.items[2].available);
    try testing.expect((try compose(arena, "Teststadt", "de/de", outcome)) == null);

    // Back again: no "verfügbar" push for an article that never left.
    const back = snapshot(0, flis_restock, 0, null, 170);
    const again = try evaluate(arena, &test_list, &back, withItems(outcome.items));
    try testing.expect((try compose(arena, "Teststadt", "de/de", again)) == null);
}

test "an article that falls short and comes back is announced again" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const start = snapshot(0, null, 0, null, 2);
    const first = try evaluate(arena, &test_list, &start, null);
    const gone = snapshot(0, null, 0, null, 0);
    const second = try evaluate(arena, &test_list, &gone, withItems(first.items));
    try testing.expect((try compose(arena, "Teststadt", "de/de", second)) == null);
    const back = try evaluate(arena, &test_list, &start, withItems(second.items));
    const msg = (try compose(arena, "Teststadt", "de/de", back)).?;
    try testing.expectEqualStrings("IKEA Teststadt: Korpus 1m verfügbar", msg.title);
}

test "an article added to the list later brings no event of its own" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = [_]ItemState{
        .{ .item_no = "30630088", .available = false, .restock_announced = true },
        .{ .item_no = "70589416", .available = false, .restock_announced = false },
    };
    const now = snapshot(0, flis_restock, 0, null, 174);
    const outcome = try evaluate(arena, &test_list, &now, withItems(&before));
    try testing.expect(!outcome.results[2].became_available);
    try testing.expect((try compose(arena, "Teststadt", "de/de", outcome)) == null);
    try testing.expect(outcome.items[2].available);
}

test "failure message names the count and the error" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const msg = try failureMessage(arena_state.allocator(), 3, "HttpStatus");
    try testing.expectEqualStrings(
        "Die letzten 3 Abfragen sind fehlgeschlagen (HttpStatus). Details im Log von lagerkoll.",
        msg.body,
    );
}
