// ringmpsc SIMD Performance Benchmarks
//
// Comprehensive benchmarks to validate SIMD optimization performance gains.

const std = @import("std");
const time = std.time;
const ringmpsc = @import("ringmpsc");
const simd = ringmpsc.primitives.simd;

// Benchmark configuration
const BENCHMARK_SIZES = [_]usize{ 64, 256, 1024, 4096, 16384, 65536, 262144 };
const ITERATIONS = 1000;

// Timer utility - simplified for Zig 0.15.2
pub const Timer = struct {
    timer: time.Timer,
    start_time: u64,

    pub fn start(self: *Timer) void {
        self.start_time = self.timer.read();
    }

    pub fn elapsed(self: *Timer) u64 {
        return self.timer.read() - self.start_time;
    }
};

pub fn createTimer() Timer {
    return Timer{ .timer = time.Timer.start() catch unreachable, .start_time = 0 };
}

// Benchmark memcpy performance
pub fn benchmarkMemcpy() !void {
    std.debug.print("\n=== SIMD memcpy Performance Benchmark ===\n", .{});
    std.debug.print("Size (bytes)\tScalar (ns)\tSIMD (ns)\tSpeedup\n", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (BENCHMARK_SIZES) |size| {
        const src = try allocator.alloc(u8, size);
        const dst_scalar = try allocator.alloc(u8, size);
        const dst_simd = try allocator.alloc(u8, size);

        // Initialize source data
        for (src, 0..) |*b, i| {
            b.* = @intCast(i % 256);
        }

        // Benchmark scalar memcpy
        var scalar_time: u64 = 0;
        for (0..ITERATIONS) |_| {
            var timer = createTimer();
            timer.start();
            @memcpy(dst_scalar[0..size], src[0..size]);
            scalar_time += timer.elapsed();
        }
        scalar_time /= ITERATIONS;

        // Benchmark SIMD memcpy
        var simd_time: u64 = 0;
        for (0..ITERATIONS) |_| {
            var timer = createTimer();
            timer.start();
            simd.ringMemcpy(dst_simd.ptr, src.ptr, size);
            simd_time += timer.elapsed();
        }
        simd_time /= ITERATIONS;

        // Calculate speedup
        const speedup = @as(f64, @floatFromInt(scalar_time)) / @as(f64, @floatFromInt(simd_time));

        std.debug.print("{}\t\t{}\t\t{}\t\t{d:.2}\n", .{ size, scalar_time, simd_time, speedup });

        // Verify correctness
        for (dst_scalar, dst_simd, 0..) |s, v, i| {
            if (s != v) {
                std.debug.print("ERROR: SIMD memcpy incorrect at index {}\n", .{i});
                return error.IncorrectResult;
            }
        }
    }
}

// Benchmark memset performance
pub fn benchmarkMemset() !void {
    std.debug.print("\n=== SIMD memset Performance Benchmark ===\n", .{});
    std.debug.print("Size (bytes)\tScalar (ns)\tSIMD (ns)\tSpeedup\n", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (BENCHMARK_SIZES) |size| {
        const dst_scalar = try allocator.alloc(u8, size);
        const dst_simd = try allocator.alloc(u8, size);
        const value: u8 = 0xAA;

        // Benchmark scalar memset
        var scalar_time: u64 = 0;
        for (0..ITERATIONS) |_| {
            var timer = createTimer();
            timer.start();
            @memset(dst_scalar[0..size], value);
            scalar_time += timer.elapsed();
        }
        scalar_time /= ITERATIONS;

        // Benchmark SIMD memset
        var simd_time: u64 = 0;
        for (0..ITERATIONS) |_| {
            var timer = createTimer();
            timer.start();
            simd.ringMemset(dst_simd.ptr, value, size);
            simd_time += timer.elapsed();
        }
        simd_time /= ITERATIONS;

        // Calculate speedup
        const speedup = @as(f64, @floatFromInt(scalar_time)) / @as(f64, @floatFromInt(simd_time));

        std.debug.print("{}\t\t{}\t\t{}\t\t{d:.2}\n", .{ size, scalar_time, simd_time, speedup });

        // Verify correctness
        for (dst_scalar, dst_simd) |s, v| {
            if (s != v) {
                std.debug.print("ERROR: SIMD memset incorrect\n", .{});
                return error.IncorrectResult;
            }
        }
    }
}

// Benchmark SIMD feature detection
pub fn benchmarkFeatureDetection() !void {
    std.debug.print("\n=== SIMD Feature Detection ===\n", .{});

    const features = simd.SimdFeatures.detect();
    std.debug.print("AVX2 Support: {}\n", .{features.has_avx2});
    std.debug.print("AVX-512 Support: {}\n", .{features.has_avx512});
    std.debug.print("Vector sizes - u8: {}, u32: {}, f32: {}\n", .{ features.vector_size_u8, features.vector_size_u32, features.vector_size_f32 });
}

// Run all benchmarks
pub fn main() !void {
    std.debug.print("ringmpsc SIMD Performance Benchmarks\n", .{});
    std.debug.print("=================================\n", .{});

    try benchmarkFeatureDetection();
    try benchmarkMemcpy();
    try benchmarkMemset();

    std.debug.print("\nBenchmarks completed successfully!\n", .{});
}
