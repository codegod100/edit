const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Option to enable readline support (requires libreadline-dev or libedit-dev)
    const use_readline = b.option(bool, "readline", "Enable readline library support") orelse false;

    const refresh_models = b.addSystemCommand(&.{ "sh", "-c", "test -f src/models.dev.json || curl -fsSL https://models.dev/api.json -o src/models.dev.json || true" });

    const exe = b.addExecutable(.{
        .name = "zagent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.step.dependOn(&refresh_models.step);

    // Optionally link against readline/editline library for better terminal input
    // Install with: sudo apt-get install libreadline-dev (or libedit-dev)
    if (use_readline) {
        exe.linkSystemLibrary("readline");
        exe.root_module.addCMacro("USE_READLINE", "1");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zagent");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.step.dependOn(&refresh_models.step);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
