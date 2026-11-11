const std = @import("std");

pub fn build(b: *std.Build) void {
    // Define the target and optimization options for the build.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_mod = b.addModule("zig_hyve_cli", .{
        .target = target,
        .root_source_file = b.path("src/root.zig"),
    });

    // Define the main executable for the project.
    const exe = b.addExecutable(.{
        .name = "zig_hyve_cli",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "zig_hyve_cli", .module = app_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Define a top level step for running the application.
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
}
