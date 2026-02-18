const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zagent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

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

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const bench_cmd = b.addSystemCommand(&.{ "/usr/bin/env", "bash", "scripts/import-terminal-bench.sh", "--sample", "--run", "1" });
    const bench_step = b.step("bench", "Import Terminal-Bench tasks and run a sample Harbor trial");
    bench_step.dependOn(&bench_cmd.step);

    // Web server executable
    const web_exe = b.addExecutable(.{
        .name = "zagent-web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(web_exe);

    const web_run_cmd = b.addRunArtifact(web_exe);
    web_run_cmd.step.dependOn(b.getInstallStep());

    const web_step = b.step("web", "Run zagent web server");
    web_step.dependOn(&web_run_cmd.step);
}
