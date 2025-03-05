const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");
    const benchmark_step = b.step("benchmark", "Run benchmarks");
    const benchmark_option = b.option(Benchmark, "benchmark", "Benchmark to run (default: basic)") orelse .basic;

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

    const lib_mod = b.addModule("ZLib.Jobs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("assert", assert_mod);
    lib_mod.addImport("threading", threading_mod);

    // Tests
    const assert_unit_tests = b.addTest(.{
        .root_module = assert_mod,
    });

    const threading_unit_tests = b.addTest(.{
        .root_module = threading_mod,
    });

    const run_assert_unit_tests = b.addRunArtifact(assert_unit_tests);
    const run_threading_unit_tests = b.addRunArtifact(threading_unit_tests);

    test_step.dependOn(&run_assert_unit_tests.step);
    test_step.dependOn(&run_threading_unit_tests.step);

    // Benchmarks
    const zbench_mod = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    }).module("zbench");

    const benchmark = b.addExecutable(.{
        .name = @tagName(benchmark_option),
        .root_module = b.createModule(.{
            .root_source_file = b.path(
                b.fmt("{s}{s}{s}", .{ benchmark_dir, @tagName(benchmark_option), "/main.zig" }),
            ),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmark.root_module.addImport("zbench", zbench_mod);
    benchmark.root_module.addImport("libz", lib_mod);

    b.installArtifact(benchmark);
    const benchmark_run = b.addRunArtifact(benchmark);
    benchmark_step.dependOn(&benchmark_run.step);
}

const benchmark_dir = "src/benchmarks/";

const Benchmark = enum {
    basic,
    basic_ordered,
    different_job_sizes,
};
