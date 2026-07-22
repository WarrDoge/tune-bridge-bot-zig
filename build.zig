const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tune-bridge-bot",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link system libs for TLS support (std.http needs libssl + libcrypto)
    exe.linkSystemLibrary("ssl");
    exe.linkSystemLibrary("crypto");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the bot");
    run_step.dependOn(&run_cmd.step);

    // Tests - point to root.zig which re-exports all modules
    const exe_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_tests.linkSystemLibrary("ssl");
    exe_tests.linkSystemLibrary("crypto");

    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
