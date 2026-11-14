const std = @import("std");

/// The one place the version is written.
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The version for `--version` and the User-Agent header (src/main.zig).
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{ .name = "ikea-checker", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run ikea-checker (zig build run -- check --config ... --dry-run)").dependOn(&run.step);

    // Fixed fixtures, no network.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    tests.root_module.addOptions("build_options", options);
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
