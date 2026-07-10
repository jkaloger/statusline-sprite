const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "statusline-sprite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // std.c.setsid (daemon session detach) is reachable only via libc.
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const integration = b.addSystemCommand(&.{"tests/integration.sh"});
    integration.step.dependOn(b.getInstallStep());
    const integration_step = b.step("integration", "Run the integration test script");
    integration_step.dependOn(&integration.step);

    const daemon_test = b.addSystemCommand(&.{"tests/daemon.sh"});
    daemon_test.step.dependOn(b.getInstallStep());
    const daemon_step = b.step("daemon", "Run the daemon spawn/detach/singleton integration harness");
    daemon_step.dependOn(&daemon_test.step);
}
