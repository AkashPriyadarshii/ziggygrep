const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Release binaries target x86_64-v3 (AVX2) on x86_64, matching what
    // ripgrep runtime-dispatches to. Debug/test builds stay baseline so
    // `zig build test` runs everywhere including pre-2013 CPUs.
    // Users can still override with -Dtarget explicitly.
    var query = b.standardTargetOptionsQueryOnly(.{});
    // Only when the user did not pass -Dtarget: an explicit target wins.
    if (optimize != .Debug and query.cpu_arch == null and query.cpu_model == .determined_by_arch_os) {
        query.cpu_arch = .x86_64;
        query.cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 };
    }
    const target = b.resolveTargetQuery(query);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ziggygrep",
        .root_module = root_module,
    });
    if (optimize != .Debug) {
        exe.root_module.strip = true;
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run ziggygrep");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
