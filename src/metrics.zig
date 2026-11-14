//! Optional run metrics in the Prometheus text format, POSTed after every run to an import
//! endpoint (VictoriaMetrics `/api/v1/import/prometheus`, a Pushgateway `/metrics/job/<job>`, …).
//! They keep a history beyond the scheduler's logs and let an alert notice runs that stop.

const std = @import("std");
const check = @import("check.zig");
const config = @import("config.zig");

pub const Run = struct {
    job: []const u8,
    store_id: []const u8,
    /// Unix seconds of this run.
    now: i64,
    success: bool,
    /// Unix seconds of the last successful run, 0 if none.
    last_success: i64,
    failures: u32,
    /// Null when the run failed before IKEA answered.
    outcome: ?check.Outcome,
    pushed: bool,
    duration_ms: i64,
    cpu_ms: i64,
    maxrss_kib: i64,
};

/// The exposition text for one run. No timestamps: the receiver stamps the samples, which a
/// Pushgateway requires.
pub fn render(arena: std.mem.Allocator, run: Run) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    write(&out.writer, run) catch return error.OutOfMemory;
    return out.written();
}

fn write(w: *std.Io.Writer, run: Run) std.Io.Writer.Error!void {
    var base_buf: [256]u8 = undefined;
    var base_w: std.Io.Writer = .fixed(&base_buf);
    try base_w.print("job=\"{f}\",store=\"{f}\"", .{ escaped(run.job), escaped(run.store_id) });
    const base = base_w.buffered();

    const now: f64 = @floatFromInt(run.now);
    const last: f64 = @floatFromInt(run.last_success);
    const failures: f64 = @floatFromInt(run.failures);
    const duration = @as(f64, @floatFromInt(run.duration_ms)) / 1000.0;
    const cpu = @as(f64, @floatFromInt(run.cpu_ms)) / 1000.0;
    const rss = @as(f64, @floatFromInt(run.maxrss_kib)) * 1024.0;
    try gauge(w, base, "lagerkoll_last_run_timestamp_seconds", "Unix time of the last run.", now);
    try gauge(w, base, "lagerkoll_last_success_timestamp_seconds", "Last successful run, 0 if none.", last);
    try gauge(w, base, "lagerkoll_run_success", "1 if the last run succeeded.", if (run.success) 1 else 0);
    try gauge(w, base, "lagerkoll_consecutive_failures", "Failed runs in a row.", failures);
    try gauge(w, base, "lagerkoll_push_sent", "1 if the last run sent a push.", if (run.pushed) 1 else 0);
    try gauge(w, base, "lagerkoll_run_duration_seconds", "Wall time of the last run.", duration);
    try gauge(w, base, "lagerkoll_run_cpu_seconds", "CPU time of the last run.", cpu);
    try gauge(w, base, "lagerkoll_run_max_rss_bytes", "Peak resident memory of the last run.", rss);

    const outcome = run.outcome orelse return;
    const total: f64 = @floatFromInt(outcome.results.len);
    const available: f64 = @floatFromInt(outcome.availableCount());
    try gauge(w, base, "lagerkoll_articles", "Articles on the list.", total);
    try gauge(w, base, "lagerkoll_articles_available", "Articles with the needed quantity.", available);

    try w.writeAll("# HELP lagerkoll_article_quantity Pieces in stock (absent when IKEA gave no figure).\n");
    try w.writeAll("# TYPE lagerkoll_article_quantity gauge\n");
    for (outcome.results) |r| if (r.quantity) |q| try article(w, "lagerkoll_article_quantity", base, r.item, q);
    try w.writeAll("# HELP lagerkoll_article_needed Pieces needed.\n");
    try w.writeAll("# TYPE lagerkoll_article_needed gauge\n");
    for (outcome.results) |r| try article(w, "lagerkoll_article_needed", base, r.item, r.item.quantity);
}

fn article(w: *std.Io.Writer, name: []const u8, base: []const u8, item: config.Item, value: u32) !void {
    const no = escaped(item.item_no);
    try w.print("{s}{{{s},item_no=\"{f}\",name=\"{f}\"}} {d}\n", .{ name, base, no, escaped(item.name), value });
}

fn gauge(w: *std.Io.Writer, labels: []const u8, name: []const u8, help: []const u8, value: f64) !void {
    try w.print("# HELP {s} {s}\n# TYPE {s} gauge\n{s}{{{s}}} {d}\n", .{ name, help, name, name, labels, value });
}

/// A label value with `\`, `"` and newlines escaped (Prometheus text format).
fn escaped(s: []const u8) std.fmt.Alt([]const u8, writeEscaped) {
    return .{ .data = s };
}

fn writeEscaped(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(c),
    };
}

pub const SendError = error{HttpStatus} || std.http.Client.FetchError;

/// POSTs the text; any 2xx answer counts as accepted.
pub fn send(
    client: *std.http.Client,
    url: []const u8,
    user_agent: []const u8,
    text: []const u8,
    status_out: *u16,
) SendError!void {
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = text,
        .redirect_behavior = .not_allowed,
        .headers = .{
            .content_type = .{ .override = "text/plain; version=0.0.4" },
            .user_agent = .{ .override = user_agent },
        },
    });
    status_out.* = @backingInt(result.status);
    if (result.status.class() != .success) return error.HttpStatus;
}

const testing = std.testing;
const ikea = @import("ikea.zig");

test "render writes the run gauges and one line per article" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = [_]config.Item{
        .{ .item_no = "30630088", .name = "Flisberget \"Tür\"", .quantity = 9 },
        .{ .item_no = "70589416", .name = "Översidan 46cm", .quantity = 4 },
    };
    const obs = [_]ikea.Observation{
        .{ .item_no = "30630088", .quantity = 0, .restock = null },
        .{ .item_no = "70589416", .quantity = null, .restock = null },
    };
    const outcome = try check.evaluate(arena, &items, &obs, null);
    const text = try render(arena, .{
        .job = "lagerkoll",
        .store_id = "326",
        .now = 1763199000,
        .success = true,
        .last_success = 1763199000,
        .failures = 0,
        .outcome = outcome,
        .pushed = true,
        .duration_ms = 150,
        .cpu_ms = 5,
        .maxrss_kib = 3400,
    });
    const expected_lines = [_][]const u8{
        "lagerkoll_last_run_timestamp_seconds{job=\"lagerkoll\",store=\"326\"} 1763199000\n",
        "lagerkoll_run_success{job=\"lagerkoll\",store=\"326\"} 1\n",
        "lagerkoll_push_sent{job=\"lagerkoll\",store=\"326\"} 1\n",
        "lagerkoll_run_duration_seconds{job=\"lagerkoll\",store=\"326\"} 0.15\n",
        "lagerkoll_run_max_rss_bytes{job=\"lagerkoll\",store=\"326\"} 3481600\n",
        "lagerkoll_articles{job=\"lagerkoll\",store=\"326\"} 2\n",
        "lagerkoll_articles_available{job=\"lagerkoll\",store=\"326\"} 0\n",
        "lagerkoll_article_quantity{job=\"lagerkoll\",store=\"326\"," ++
            "item_no=\"30630088\",name=\"Flisberget \\\"Tür\\\"\"} 0\n",
        "lagerkoll_article_needed{job=\"lagerkoll\",store=\"326\",item_no=\"70589416\",name=\"Översidan 46cm\"} 4\n",
        "# TYPE lagerkoll_run_success gauge\n",
    };
    for (expected_lines) |line| {
        if (std.mem.find(u8, text, line) == null) {
            std.debug.print("missing line: {s}in:\n{s}\n", .{ line, text });
            return error.TestUnexpectedResult;
        }
    }
    // No figure from IKEA: no quantity sample for that article.
    const absent = "lagerkoll_article_quantity{job=\"lagerkoll\",store=\"326\",item_no=\"70589416\"";
    try testing.expect(std.mem.find(u8, text, absent) == null);
}

test "render of a failed run has no article samples" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const text = try render(arena_state.allocator(), .{
        .job = "lagerkoll",
        .store_id = "326",
        .now = 100,
        .success = false,
        .last_success = 0,
        .failures = 3,
        .outcome = null,
        .pushed = false,
        .duration_ms = 3,
        .cpu_ms = 1,
        .maxrss_kib = 1,
    });
    const failures = "lagerkoll_consecutive_failures{job=\"lagerkoll\",store=\"326\"} 3\n";
    try testing.expect(std.mem.find(u8, text, failures) != null);
    try testing.expect(std.mem.find(u8, text, "lagerkoll_article") == null);
}
