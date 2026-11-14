//! ikea-checker: watch the stock of a shopping list in one IKEA store and push changes
//! through ntfy. One run per call; a scheduler (launchd) calls it regularly.

const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");
const ikea = @import("ikea.zig");
const check = @import("check.zig");
const state_file = @import("state.zig");
const ntfy = @import("ntfy.zig");

/// Failed runs in a row before one warning push.
pub const failure_threshold = 3;

const user_agent = "ikea-checker/" ++ build_options.version;

const usage =
    \\Usage: ikea-checker check --config FILE --state FILE [--dry-run]
    \\       ikea-checker --version
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
            try out.print("ikea-checker {s}\n", .{build_options.version});
            return 0;
        },
        .help => {
            try out.writeAll(usage);
            return 0;
        },
        .check => |opts| {
            var ctx: Run = .{ .gpa = init.gpa, .arena = arena, .io = io, .opts = opts, .out = out, .log = log };
            return ctx.run();
        },
    }
}

const Sender = struct {
    server: []const u8,
    topic: []const u8,
    auth: []const u8,
};

const Run = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    opts: CheckOptions,
    out: *std.Io.Writer,
    log: *std.Io.Writer,

    fn run(r: *Run) !u8 {
        const now = std.Io.Clock.real.now(r.io).toSeconds();
        // A header per run, flushed before anything goes to stderr (launchd writes both to one log).
        try writeTimestamp(r.out, now);
        try r.out.print(" ikea-checker {s}{s}\n", .{ build_options.version, if (r.opts.dry_run) " --dry-run" else "" });
        try r.out.flush();

        const cwd = std.Io.Dir.cwd();
        const cfg_text = cwd.readFileAlloc(r.io, r.opts.config_path, r.arena, .limited(1 << 20)) catch |err| {
            try r.log.print("config {s}: {t}\n", .{ r.opts.config_path, err });
            return 1;
        };
        var problem: []const u8 = "";
        const cfg = config.parse(r.arena, cfg_text, &problem) catch |err| switch (err) {
            error.InvalidConfig => {
                try r.log.print("config {s}: {s}\n", .{ r.opts.config_path, problem });
                return 1;
            },
            error.OutOfMemory => return err,
        };
        const previous = state_file.load(r.arena, r.io, r.opts.state_path) catch |err| {
            // A broken state file needs a look; overwriting it would hide that.
            try r.log.print("state {s}: {t}\n", .{ r.opts.state_path, err });
            return 1;
        };

        var sender: ?Sender = null;
        if (!r.opts.dry_run) {
            const n = cfg.ntfy orelse {
                try r.log.writeAll("config: a real run needs the ntfy section (or use --dry-run)\n");
                return 1;
            };
            const auth = ntfy.loadAuthorization(r.arena, r.io, n.credentials_file) catch |err| {
                try r.log.print("ntfy credentials {s}: {t}\n", .{ n.credentials_file, err });
                return 1;
            };
            sender = .{ .server = n.url, .topic = n.topic, .auth = auth };
        }

        var client: std.http.Client = .{ .allocator = r.gpa, .io = r.io };
        defer client.deinit();

        const observations = r.fetchObservations(&client, cfg) catch |err| {
            return r.failed(&client, sender, previous, err);
        };
        const outcome = try check.evaluate(r.arena, cfg.items, observations, previous);
        try report(r.out, cfg, outcome);

        const msg = try check.compose(r.arena, cfg.store_name, cfg.market, outcome);
        const was_warned = if (previous) |p| p.failure_warned else false;
        if (r.opts.dry_run) {
            if (msg) |m| {
                try r.out.print("\nPush (nicht gesendet): {s}\n{s}\n", .{ m.title, m.body });
            } else try r.out.writeAll("\nKein Push.\n");
            if (was_warned) try r.out.print("Push (nicht gesendet): {s}\n", .{check.recovery_message.title});
            return 0;
        }

        const s = sender.?;
        var next: check.State = .{ .items = outcome.items, .last_success_unix = now };
        if (msg) |m| {
            r.send(&client, s, m) catch {
                // Keep the old item states, so the next run finds the same change and tries again.
                var st = previous orelse check.State{};
                st.consecutive_failures +|= 1;
                try r.saveState(st);
                return 1;
            };
            try r.out.print("Push gesendet: {s}\n", .{m.title});
        }
        // A failed recovery push is tried again next time.
        if (was_warned) next.failure_warned = if (r.send(&client, s, check.recovery_message)) |_| false else |_| true;
        try r.saveState(next);
        return 0;
    }

    fn fetchObservations(r: *Run, client: *std.http.Client, cfg: config.Config) ![]const ikea.Observation {
        const url = try ikea.availabilityUrl(r.arena, cfg.api_url, cfg.store_id, cfg.items);
        var status: u16 = 0;
        const body = ikea.fetch(client, r.gpa, url, cfg.client_id, user_agent, &status) catch |err| {
            if (err == error.HttpStatus)
                try r.log.print("IKEA: HTTP {d}\n", .{status})
            else
                try r.log.print("IKEA: {t}\n", .{err});
            return err;
        };
        defer r.gpa.free(body);
        return ikea.parseAvailability(r.arena, body, cfg.store_id) catch |err| {
            try r.log.print("IKEA: unexpected answer ({t})\n", .{err});
            return err;
        };
    }

    /// Counts the failed run; the third in a row sends one warning.
    fn failed(r: *Run, client: *std.http.Client, sender: ?Sender, previous: ?check.State, err: anyerror) !u8 {
        const s = sender orelse return 1; // --dry-run
        var st = previous orelse check.State{};
        st.consecutive_failures +|= 1;
        if (st.consecutive_failures >= failure_threshold and !st.failure_warned) {
            const m = try check.failureMessage(r.arena, st.consecutive_failures, @errorName(err));
            st.failure_warned = if (r.send(client, s, m)) |_| true else |_| false;
        }
        try r.saveState(st);
        return 1;
    }

    fn send(r: *Run, client: *std.http.Client, s: Sender, msg: check.Message) !void {
        var status: u16 = 0;
        ntfy.publish(client, r.arena, s.server, s.auth, user_agent, s.topic, msg, &status) catch |err| {
            if (err == error.HttpStatus)
                try r.log.print("ntfy: HTTP {d}\n", .{status})
            else
                try r.log.print("ntfy: {t}\n", .{err});
            return err;
        };
    }

    fn saveState(r: *Run, st: check.State) !void {
        state_file.save(r.gpa, r.io, r.opts.state_path, st) catch |err| {
            try r.log.print("state {s}: not saved ({t})\n", .{ r.opts.state_path, err });
        };
    }
};

fn report(w: *std.Io.Writer, cfg: config.Config, outcome: check.Outcome) !void {
    try w.print("IKEA {s} ({s}): {d} von {d} verfügbar\n", .{
        cfg.store_name,
        cfg.store_id,
        outcome.availableCount(),
        outcome.results.len,
    });
    for (outcome.results) |res| {
        const label = switch (res.status) {
            .available => "ok   ",
            .short => "knapp",
            .out => "fehlt",
            .unknown => "?    ",
        };
        var qbuf: [24]u8 = undefined;
        const q = try std.mem.print(&qbuf, "{f}/{d}", .{ check.fmtQuantity(res.quantity), res.item.quantity });
        try w.print("  {s}  {s}  {s:>9}  {s}", .{ label, res.item.item_no, q, res.item.name });
        if (res.restock) |rs| {
            if (res.status != .available) try w.print("  (Nachlieferung {f})", .{check.fmtRange(rs)});
        }
        if (res.became_available) try w.writeAll("  NEU");
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
