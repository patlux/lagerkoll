//! lagerkoll: watch the stock of a shopping list in one IKEA store and push changes
//! through ntfy. One run per call; a scheduler (launchd) calls it regularly.

const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");
const ikea = @import("ikea.zig");
const check = @import("check.zig");
const builtin = @import("builtin");
const state_file = @import("state.zig");
const ntfy = @import("ntfy.zig");
const metrics = @import("metrics.zig");

/// Failed runs in a row before one warning push.
pub const failure_threshold = 3;

const user_agent = "lagerkoll/" ++ build_options.version;

const usage =
    \\Usage: lagerkoll check --config FILE --state FILE [--dry-run]
    \\       lagerkoll --version
    \\
    \\check      Ask IKEA for the stock of the listed articles in one store, compare it with
    \\           the last run (the state file) and push what changed through ntfy.
    \\--dry-run  Print the report and the push it would send; send nothing, write no state.
    \\
;

const CheckOptions = struct {
    config_path: []const u8,
    state_path: []const u8,
    dry_run: bool,
};

const Command = union(enum) {
    check: CheckOptions,
    version,
    help,
};

fn parseArgs(args: []const []const u8) error{Usage}!Command {
    if (args.len == 0) return error.Usage;
    if (args.len == 1 and std.mem.eql(u8, args[0], "--version")) return .version;
    if (args.len == 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) return .help;
    if (!std.mem.eql(u8, args[0], "check")) return error.Usage;
    var opts: CheckOptions = .{ .config_path = "", .state_path = "", .dry_run = false };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "--state")) {
            if (i + 1 >= args.len or args[i + 1].len == 0) return error.Usage;
            i += 1;
            if (arg[2] == 'c') opts.config_path = args[i] else opts.state_path = args[i];
        } else return error.Usage;
    }
    if (opts.config_path.len == 0 or opts.state_path.len == 0) return error.Usage;
    return .{ .check = opts };
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};
    var err_buf: [1024]u8 = undefined;
    var err_w = std.Io.File.stderr().writer(io, &err_buf);
    const log = &err_w.interface;
    defer log.flush() catch {};

    const cmd = parseArgs(args[1..]) catch {
        try log.writeAll(usage);
        return 2;
    };
    switch (cmd) {
        .version => {
            try out.print("lagerkoll {s}\n", .{build_options.version});
            return 0;
        },
        .help => {
            try out.writeAll(usage);
            return 0;
        },
        .check => |opts| {
            var ctx: Run = .{ .gpa = init.gpa, .arena = arena, .io = io, .opts = opts, .out = out };
            return ctx.run();
        },
    }
}

const Sender = struct {
    server: []const u8,
    topic: []const u8,
    auth: []const u8,
};

/// The last line of every run, `key=value`, so one grep over the logs shows what each run did.
const Summary = struct {
    result: enum { ok, failed } = .failed,
    err: ?[]const u8 = null,
    push: enum { none, sent, failed, dry_run } = .none,
    ntfy_id: ?[]const u8 = null,
    available: ?usize = null,
    total: ?usize = null,
    new_available: usize = 0,
    new_restock: usize = 0,
    failures: ?u32 = null,
    metrics: enum { off, sent, failed, skipped } = .off,
};

const Run = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    opts: CheckOptions,
    /// Everything a run reports goes here, errors as `error: …`, so the log reads in order.
    out: *std.Io.Writer,
    summary: Summary = .{},
    // What the metrics need, filled in as the run gets there.
    now: i64 = 0,
    cfg: ?config.Config = null,
    outcome: ?check.Outcome = null,
    last_success: i64 = 0,

    fn run(r: *Run) !u8 {
        const started = std.Io.Clock.awake.now(r.io);
        const code = r.checkOnce() catch |err| {
            r.summary.err = @errorName(err);
            try r.finish(started, 1);
            return err;
        };
        try r.finish(started, code);
        return code;
    }

    fn finish(r: *Run, started: std.Io.Timestamp, code: u8) !void {
        if (code == 0) r.summary.result = .ok;
        const elapsed = started.durationTo(std.Io.Clock.awake.now(r.io));
        const duration_ms: i64 = @intCast(@divTrunc(elapsed.toNanoseconds(), std.time.ns_per_ms));
        try r.sendMetrics(duration_ms);
        try r.writeSummary(duration_ms);
    }

    /// Best effort: a failed metrics request is logged and named in the summary, nothing else.
    fn sendMetrics(r: *Run, duration_ms: i64) !void {
        const cfg = r.cfg orelse return;
        const m = cfg.metrics orelse return;
        if (r.opts.dry_run) {
            r.summary.metrics = .skipped;
            return;
        }
        const ru = resourceUsage();
        const text = try metrics.render(r.arena, .{
            .job = m.job,
            .store_id = cfg.store_id,
            .now = r.now,
            .success = r.summary.result == .ok,
            .last_success = r.last_success,
            .failures = r.summary.failures orelse 0,
            .outcome = r.outcome,
            .pushed = r.summary.push == .sent,
            .duration_ms = duration_ms,
            .cpu_ms = ru.cpu_ms,
            .maxrss_kib = ru.maxrss_kib,
        });
        var client: std.http.Client = .{ .allocator = r.gpa, .io = r.io };
        defer client.deinit();
        var status: u16 = 0;
        metrics.send(&client, m.url, user_agent, text, &status) catch |err| {
            r.summary.metrics = .failed;
            if (err == error.HttpStatus)
                try r.out.print("error: metrics: HTTP {d}\n", .{status})
            else
                try r.out.print("error: metrics: {t}\n", .{err});
            return;
        };
        r.summary.metrics = .sent;
    }

    fn checkOnce(r: *Run) !u8 {
        const now = std.Io.Clock.real.now(r.io).toSeconds();
        r.now = now;
        try writeTimestamp(r.out, now);
        try r.out.print(" lagerkoll {s}{s}\n", .{ build_options.version, if (r.opts.dry_run) " --dry-run" else "" });

        const cwd = std.Io.Dir.cwd();
        const cfg_text = cwd.readFileAlloc(r.io, r.opts.config_path, r.arena, .limited(1 << 20)) catch |err| {
            try r.out.print("error: config {s}: {t}\n", .{ r.opts.config_path, err });
            r.summary.err = "config";
            return 1;
        };
        var problem: []const u8 = "";
        const cfg = config.parse(r.arena, cfg_text, &problem) catch |err| switch (err) {
            error.InvalidConfig => {
                try r.out.print("error: config {s}: {s}\n", .{ r.opts.config_path, problem });
                r.summary.err = "config";
                return 1;
            },
            error.OutOfMemory => return err,
        };
        r.cfg = cfg;
        const previous = state_file.load(r.arena, r.io, r.opts.state_path) catch |err| {
            // A broken state file needs a look; overwriting it would hide that.
            try r.out.print("error: state {s}: {t}\n", .{ r.opts.state_path, err });
            r.summary.err = "state";
            return 1;
        };
        try writeState(r.out, previous);
        if (previous) |p| r.last_success = p.last_success_unix;

        var sender: ?Sender = null;
        if (!r.opts.dry_run) {
            const n = cfg.ntfy orelse {
                try r.out.writeAll("error: config: a real run needs the ntfy section (or use --dry-run)\n");
                r.summary.err = "config";
                return 1;
            };
            const auth = ntfy.loadAuthorization(r.arena, r.io, n.credentials_file) catch |err| {
                try r.out.print("error: ntfy credentials {s}: {t}\n", .{ n.credentials_file, err });
                r.summary.err = "credentials";
                return 1;
            };
            sender = .{ .server = n.url, .topic = n.topic, .auth = auth };
        }

        var client: std.http.Client = .{ .allocator = r.gpa, .io = r.io };
        defer client.deinit();

        const observations = r.fetchObservations(&client, cfg) catch |err| {
            r.summary.err = @errorName(err);
            return r.failed(&client, sender, previous, err);
        };
        const outcome = try check.evaluate(r.arena, cfg.items, observations, previous);
        try report(r.out, cfg, outcome);
        r.outcome = outcome;
        r.summary.available = outcome.availableCount();
        r.summary.total = outcome.results.len;
        for (outcome.results) |res| {
            r.summary.new_available += @intFromBool(res.became_available);
            r.summary.new_restock += @intFromBool(res.restock_new);
        }

        const msg = try check.compose(r.arena, cfg.store_name, cfg.market, outcome);
        const was_warned = if (previous) |p| p.failure_warned else false;
        if (r.opts.dry_run) {
            if (msg) |m| {
                r.summary.push = .dry_run;
                try r.out.print("push: dry run, not sent: {s}\n{s}\n", .{ m.title, m.body });
            } else try r.out.writeAll("push: none\n");
            if (was_warned) try r.out.print("push: dry run, not sent: {s}\n", .{check.recovery_message.title});
            return 0;
        }

        const s = sender.?;
        var next: check.State = .{ .items = outcome.items, .last_success_unix = now };
        if (msg) |m| {
            r.send(&client, s, m) catch {
                // Keep the old item states, so the next run finds the same change and tries again.
                r.summary.push = .failed;
                r.summary.err = "ntfy";
                var st = previous orelse check.State{};
                st.consecutive_failures +|= 1;
                r.summary.failures = st.consecutive_failures;
                const line = "push: failed, the next run tries again (failures in a row: {d})\n";
                try r.out.print(line, .{st.consecutive_failures});
                try r.saveState(st);
                return 1;
            };
        } else try r.out.writeAll("push: none\n");
        // A failed recovery push is tried again next time.
        if (was_warned) next.failure_warned = if (r.send(&client, s, check.recovery_message)) |_| false else |_| true;
        r.summary.failures = 0;
        r.last_success = now;
        try r.saveState(next);
        return 0;
    }

    fn fetchObservations(r: *Run, client: *std.http.Client, cfg: config.Config) ![]const ikea.Observation {
        const url = try ikea.availabilityUrl(r.arena, cfg.api_url, cfg.store_id, cfg.items);
        var status: u16 = 0;
        const body = ikea.fetch(client, r.gpa, url, cfg.client_id, user_agent, &status) catch |err| {
            if (err == error.HttpStatus)
                try r.out.print("error: IKEA: HTTP {d}\n", .{status})
            else
                try r.out.print("error: IKEA: {t}\n", .{err});
            return err;
        };
        defer r.gpa.free(body);
        const observations = ikea.parseAvailability(r.arena, body, cfg.store_id) catch |err| {
            try r.out.print("error: IKEA: unexpected answer ({t})\n", .{err});
            return err;
        };
        var oldest: ?[]const u8 = null;
        var newest: ?[]const u8 = null;
        for (observations) |o| if (o.updated) |u| {
            if (oldest == null or std.mem.order(u8, u, oldest.?) == .lt) oldest = u;
            if (newest == null or std.mem.order(u8, u, newest.?) == .gt) newest = u;
        };
        const line = "IKEA: HTTP {d}, {d} of {d} articles in the answer";
        try r.out.print(line, .{ status, observations.len, cfg.items.len });
        if (oldest) |o| try r.out.print(", figures updated {s} to {s}", .{ o, newest.? });
        try r.out.writeByte('\n');
        return observations;
    }

    /// Counts the failed run; the third in a row sends one warning.
    fn failed(r: *Run, client: *std.http.Client, sender: ?Sender, previous: ?check.State, err: anyerror) !u8 {
        const s = sender orelse return 1; // --dry-run
        var st = previous orelse check.State{};
        st.consecutive_failures +|= 1;
        r.summary.failures = st.consecutive_failures;
        const line = "failures in a row: {d} (one warning push from {d})\n";
        try r.out.print(line, .{ st.consecutive_failures, failure_threshold });
        if (st.consecutive_failures >= failure_threshold and !st.failure_warned) {
            const m = try check.failureMessage(r.arena, st.consecutive_failures, @errorName(err));
            st.failure_warned = if (r.send(client, s, m)) |_| true else |_| false;
        }
        try r.saveState(st);
        return 1;
    }

    fn send(r: *Run, client: *std.http.Client, s: Sender, msg: check.Message) !void {
        var status: u16 = 0;
        const id = ntfy.publish(client, r.arena, s.server, s.auth, user_agent, s.topic, msg, &status) catch |err| {
            if (err == error.HttpStatus)
                try r.out.print("error: ntfy: HTTP {d} for \"{s}\"\n", .{ status, msg.title })
            else
                try r.out.print("error: ntfy: {t} for \"{s}\"\n", .{ err, msg.title });
            return err;
        };
        r.summary.push = .sent;
        r.summary.ntfy_id = id;
        try r.out.print("push: sent \"{s}\" (ntfy id {s})\n", .{ msg.title, id orelse "?" });
    }

    fn saveState(r: *Run, st: check.State) !void {
        state_file.save(r.gpa, r.io, r.opts.state_path, st) catch |err| {
            try r.out.print("error: state {s}: not saved ({t})\n", .{ r.opts.state_path, err });
            r.summary.result = .failed;
            r.summary.err = "state";
            return;
        };
        const line = "state: saved ({d} articles, failures in a row {d})\n";
        try r.out.print(line, .{ st.items.len, st.consecutive_failures });
    }

    fn writeSummary(r: *Run, duration_ms: i64) !void {
        const sum = r.summary;
        try r.out.print("summary result={t} push={t}", .{ sum.result, sum.push });
        if (sum.ntfy_id) |id| try r.out.print(" ntfy_id={s}", .{id});
        if (sum.err) |e| try r.out.print(" error={s}", .{e});
        if (sum.available) |a| try r.out.print(" available={d}/{d}", .{ a, sum.total.? });
        try r.out.print(" new_available={d} new_restock={d}", .{ sum.new_available, sum.new_restock });
        if (sum.failures) |f| try r.out.print(" failures={d}", .{f});
        if (sum.metrics != .off) try r.out.print(" metrics={t}", .{sum.metrics});
        const ru = resourceUsage();
        try r.out.print(" duration_ms={d} cpu_ms={d} maxrss_kib={d}\n", .{
            duration_ms,
            ru.cpu_ms,
            ru.maxrss_kib,
        });
    }
};

/// CPU time and peak resident memory of this process, for the summary line.
fn resourceUsage() struct { cpu_ms: i64, maxrss_kib: i64 } {
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    const ms = (ru.utime.sec + ru.stime.sec) * 1000 + @divTrunc(ru.utime.usec + ru.stime.usec, 1000);
    // Linux reports kilobytes, macOS bytes.
    const rss: i64 = if (builtin.os.tag.isDarwin()) @divTrunc(ru.maxrss, 1024) else ru.maxrss;
    return .{ .cpu_ms = ms, .maxrss_kib = rss };
}

fn writeState(w: *std.Io.Writer, previous: ?check.State) !void {
    const st = previous orelse return w.writeAll("state: none, first run\n");
    try w.print("state: {d} articles, failures in a row {d}, warned {}, last success ", .{
        st.items.len,
        st.consecutive_failures,
        st.failure_warned,
    });
    if (st.last_success_unix > 0) try writeTimestamp(w, st.last_success_unix) else try w.writeAll("never");
    try w.writeByte('\n');
}

fn report(w: *std.Io.Writer, cfg: config.Config, outcome: check.Outcome) !void {
    try w.print("IKEA {s} ({s}): {d} of {d} available\n", .{
        cfg.store_name,
        cfg.store_id,
        outcome.availableCount(),
        outcome.results.len,
    });
    for (outcome.results) |res| {
        const label = switch (res.status) {
            .available => "ok   ",
            .short => "short",
            .out => "out  ",
            .unknown => "?    ",
        };
        var qbuf: [24]u8 = undefined;
        const q = try std.mem.print(&qbuf, "{f}/{d}", .{ check.fmtQuantity(res.quantity), res.item.quantity });
        try w.print("  {s}  {s}  {s:>9}  {s}", .{ label, res.item.item_no, q, res.item.name });
        if (res.restock) |rs| {
            if (res.status != .available) try w.print("  (delivery {f})", .{check.fmtRange(rs)});
        }
        if (res.became_available) try w.writeAll("  NEW: available");
        if (res.restock_new) try w.writeAll("  NEW: delivery announced");
        try w.writeByte('\n');
    }
}

/// `2026-11-15T09:30:00Z `
fn writeTimestamp(w: *std.Io.Writer, unix: i64) !void {
    const secs = std.math.cast(u64, unix) orelse 0;
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      @as(u8, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

const testing = std.testing;

test {
    _ = config;
    _ = ikea;
    _ = check;
    _ = state_file;
    _ = ntfy;
    _ = metrics;
}

test "parseArgs" {
    const ok = try parseArgs(&.{ "check", "--config", "c.json", "--state", "s.json", "--dry-run" });
    try testing.expectEqualStrings("c.json", ok.check.config_path);
    try testing.expectEqualStrings("s.json", ok.check.state_path);
    try testing.expect(ok.check.dry_run);
    try testing.expectEqual(Command.version, try parseArgs(&.{"--version"}));
    for ([_][]const []const u8{
        &.{},
        &.{"check"},
        &.{ "check", "--config", "c.json" },
        &.{ "check", "--config", "c.json", "--state" },
        &.{ "check", "--config", "c.json", "--state", "s.json", "--force" },
        &.{"status"},
    }) |bad| try testing.expectError(error.Usage, parseArgs(bad));
}

test "writeTimestamp" {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeTimestamp(&w, 1763199000);
    try testing.expectEqualStrings("2025-11-15T09:30:00Z", w.buffered());
}

test "writeState names a first run and the stored counters" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeState(&w, null);
    try testing.expectEqualStrings("state: none, first run\n", w.buffered());

    var w2: std.Io.Writer = .fixed(&buf);
    const items = [_]check.ItemState{.{ .item_no = "30630088", .available = false, .restock_announced = true }};
    try writeState(&w2, .{ .consecutive_failures = 2, .last_success_unix = 1763199000, .items = &items });
    try testing.expectEqualStrings(
        "state: 1 articles, failures in a row 2, warned false, last success 2025-11-15T09:30:00Z\n",
        w2.buffered(),
    );
}
