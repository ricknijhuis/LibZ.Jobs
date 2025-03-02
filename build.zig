const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const assert_mod = b.createModule(.{
        .root_source_file = b.path("src/asserts/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const threading_mod = b.createModule(.{
        .root_source_file = b.path("src/threading/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    threading_mod.addImport("assert", assert_mod);

    const lib_mod = b.addModule("threading", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("assert", assert_mod);
    lib_mod.addImport("threading", threading_mod);

    const assert_unit_tests = b.addTest(.{
        .root_module = assert_mod,
    });

    const threading_unit_tests = b.addTest(.{
        .root_module = threading_mod,
    });

    const run_assert_unit_tests = b.addRunArtifact(assert_unit_tests);
    const run_threading_unit_tests = b.addRunArtifact(threading_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_assert_unit_tests.step);
    test_step.dependOn(&run_threading_unit_tests.step);
}
