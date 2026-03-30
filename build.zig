const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================================
    // LIBRARY MODULE
    // ========================================================================

    const ringmpsc_mod = b.addModule("ringmpsc", .{
        .root_source_file = b.path("src/ringmpsc.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Benchmarks need the library compiled with ReleaseFast regardless of
    // the user-selected optimize mode, otherwise the hot-path ring buffer
    // code runs unoptimised and benchmarks are ~50,000x slower.
    const ringmpsc_fast = b.addModule("ringmpsc_fast", .{
        .root_source_file = b.path("src/ringmpsc.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });

    // ========================================================================
    // UNIT TESTS
    // ========================================================================

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/ringmpsc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // ========================================================================
    // INTEGRATION TESTS
    // ========================================================================

    inline for (.{
        .{ "test-spsc", "tests/spsc_test.zig", "Run SPSC integration tests" },
        .{ "test-mpsc", "tests/mpsc_test.zig", "Run MPSC integration tests" },
        .{ "test-fifo", "tests/fifo_test.zig", "Run FIFO ordering tests" },
        .{ "test-chaos", "tests/chaos_test.zig", "Run chaos/concurrency tests" },
        .{ "test-determinism", "tests/determinism_test.zig", "Run determinism tests" },
        .{ "test-fuzz", "tests/fuzz_test.zig", "Run fuzz tests" },
        .{ "test-mpmc", "tests/mpmc_test.zig", "Run MPMC tests" },
        .{ "test-spmc", "tests/spmc_test.zig", "Run SPMC tests" },
        .{ "test-simd", "tests/simd_test.zig", "Run SIMD tests" },
        .{ "test-blocking", "tests/blocking_test.zig", "Run blocking/wait strategy tests" },
        .{ "test-wraparound", "tests/wraparound_test.zig", "Run u64 wraparound tests" },
    }) |entry| {
        const exe = b.addExecutable(.{
            .name = entry[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry[1]),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "ringmpsc", .module = ringmpsc_fast }},
            }),
        });

        const run = b.addRunArtifact(exe);
        const step = b.step(entry[0], entry[2]);
        step.dependOn(&run.step);
    }

    // stress_test.zig uses Zig test blocks (no main), so it needs addTest
    {
        const stress_mod = b.createModule(.{
            .root_source_file = b.path("tests/stress_test.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "ringmpsc", .module = ringmpsc_fast }},
        });
        const stress_tests = b.addTest(.{ .root_module = stress_mod });
        const run_stress = b.addRunArtifact(stress_tests);
        const stress_step = b.step("test-stress", "Run stress tests");
        stress_step.dependOn(&run_stress.step);
    }

    // ========================================================================
    // BENCHMARKS
    // ========================================================================

    inline for (.{
        .{ "bench-high-perf", "benchmarks/src/high_perf.zig", "Run high performance MPSC benchmark" },
        .{ "bench-mpsc", "benchmarks/src/mpsc.zig", "Run MPSC throughput benchmark" },
        .{ "bench-spsc", "benchmarks/src/spsc.zig", "Run SPSC latency benchmark" },
        .{ "bench-simd", "benchmarks/src/simd_bench.zig", "Run SIMD performance benchmarks" },
        .{ "bench-analysis", "benchmarks/src/analysis.zig", "Run bottleneck analysis" },
        .{ "bench-cross-process", "benchmarks/src/cross_process.zig", "SharedRing vs in-process Ring" },
        .{ "bench-zero-copy", "benchmarks/src/zero_copy.zig", "BufferPool zero-copy vs inline copy" },
        .{ "bench-wake-latency", "benchmarks/src/wake_latency.zig", "Spin vs futex vs eventfd wake latency" },
    }) |entry| {
        const exe = b.addExecutable(.{
            .name = entry[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry[1]),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "ringmpsc", .module = ringmpsc_fast }},
            }),
        });

        const install = b.addInstallArtifact(exe, .{});
        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        const step = b.step(entry[0], entry[2]);
        step.dependOn(&run.step);
    }

    // Bench suite and full bench import report.zig as a file dependency
    inline for (.{
        .{ "bench-suite", "benchmarks/src/suite.zig", "Run full benchmark suite" },
        .{ "bench", "benchmarks/src/bench.zig", "Run benchmark suite with multi-run statistics and HTML report" },
    }) |entry| {
        const exe = b.addExecutable(.{
            .name = entry[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry[1]),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "ringmpsc", .module = ringmpsc_fast }},
            }),
        });

        const install = b.addInstallArtifact(exe, .{});
        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        const step = b.step(entry[0], entry[2]);
        step.dependOn(&run.step);
    }

    // ========================================================================
    // EXAMPLES
    // ========================================================================

    inline for (.{
        .{ "example-basic", "examples/basic.zig", "Run basic SPSC example" },
        .{ "example-mpsc", "examples/mpsc_pipeline.zig", "Run MPSC pipeline example" },
        .{ "example-backpressure", "examples/backpressure.zig", "Run backpressure example" },
        .{ "example-shutdown", "examples/graceful_shutdown.zig", "Run graceful shutdown example" },
        .{ "example-event-loop", "examples/event_loop.zig", "Run event loop example" },
        .{ "example-event-notifier", "examples/event_notifier.zig", "Run eventfd + epoll example" },
        .{ "example-zero-copy", "examples/zero_copy.zig", "Run zero-copy BufferPool example" },
        .{ "example-shared-memory", "examples/shared_memory.zig", "Run cross-process shared memory example" },
        .{ "example-cross-process", "examples/cross_process.zig", "Run full cross-process IPC with fd passing" },
        .{ "example-logging", "examples/logging_pipeline.zig", "Run structured logging pipeline example" },
    }) |entry| {
        const exe = b.addExecutable(.{
            .name = entry[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(entry[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "ringmpsc", .module = ringmpsc_mod }},
            }),
        });

        const run = b.addRunArtifact(exe);
        const step = b.step(entry[0], entry[2]);
        step.dependOn(&run.step);
    }
}
