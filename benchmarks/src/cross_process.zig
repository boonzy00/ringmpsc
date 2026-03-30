//! SharedRing Cross-Process Benchmark
//!
//! Compares SharedRing (mmap'd) vs in-process Ring throughput and latency
//! to quantify the cross-process overhead.
//!
//! Run: zig build bench-cross-process -Doptimize=ReleaseFast

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const SharedRing = ringmpsc.primitives.SharedRing;
const Ring = ringmpsc.primitives.Ring;

const WARMUP: usize = 2;
const RUNS: usize = 5;
const MSG_COUNT: u64 = 50_000_000;
const BATCH: usize = 4096;

const stderr = (std.fs.File{ .handle = std.posix.STDERR_FILENO }).deprecatedWriter();

pub fn main() !void {
    try stderr.print("\nSharedRing vs In-Process Ring Benchmark\n", .{});
    try stderr.print("========================================\n\n", .{});

    // In-process Ring (baseline)
    try stderr.print("In-process Ring(u64):\n", .{});
    var inproc_results: [RUNS]f64 = undefined;
    for (0..WARMUP) |_| _ = try benchInProcess();
    for (0..RUNS) |r| {
        inproc_results[r] = try benchInProcess();
        try stderr.print("  run {d}: {d:.2} M/s\n", .{ r + 1, inproc_results[r] / 1e6 });
    }

    try stderr.print("\nSharedRing(u64) (mmap'd):\n", .{});
    var shared_results: [RUNS]f64 = undefined;
    for (0..WARMUP) |_| _ = try benchShared();
    for (0..RUNS) |r| {
        shared_results[r] = try benchShared();
        try stderr.print("  run {d}: {d:.2} M/s\n", .{ r + 1, shared_results[r] / 1e6 });
    }

    // Compute medians
    std.mem.sort(f64, &inproc_results, {}, std.sort.asc(f64));
    std.mem.sort(f64, &shared_results, {}, std.sort.asc(f64));
    const inproc_median = inproc_results[RUNS / 2];
    const shared_median = shared_results[RUNS / 2];

    try stderr.print("\nResults (median of {d} runs):\n", .{RUNS});
    try stderr.print("  In-process Ring: {d:.1} M/s\n", .{inproc_median / 1e6});
    try stderr.print("  SharedRing:      {d:.1} M/s\n", .{shared_median / 1e6});
    try stderr.print("  Overhead:        {d:.1}%\n", .{(1.0 - shared_median / inproc_median) * 100});
    try stderr.print("\n", .{});
}

fn benchInProcess() !f64 {
    const Config = ringmpsc.primitives.ring_buffer.Config{ .ring_bits = 14 };
    var ring = Ring(u64, Config){};
    var done = std.atomic.Value(bool).init(false);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *Ring(u64, Config), d: *std.atomic.Value(bool)) void {
            var count: u64 = 0;
            while (count < MSG_COUNT) {
                if (r.readable()) |slice| {
                    count += slice.len;
                    r.advance(slice.len);
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            d.store(true, .release);
        }
    }.run, .{ &ring, &done });

    const t0 = std.time.Instant.now() catch unreachable;
    var buf: [BATCH]u64 = undefined;
    @memset(&buf, 42);
    var sent: u64 = 0;
    while (sent < MSG_COUNT) {
        const n = ring.send(buf[0..@min(BATCH, MSG_COUNT - sent)]);
        sent += n;
        if (n == 0) std.atomic.spinLoopHint();
    }
    consumer.join();
    const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
    return @as(f64, @floatFromInt(MSG_COUNT)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);
}

fn benchShared() !f64 {
    var ring = try SharedRing(u64).create(14);
    defer ring.deinit();
    var done = std.atomic.Value(bool).init(false);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *SharedRing(u64), d: *std.atomic.Value(bool)) void {
            var count: u64 = 0;
            while (count < MSG_COUNT) {
                if (r.readable()) |slice| {
                    count += slice.len;
                    r.advance(slice.len);
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            d.store(true, .release);
        }
    }.run, .{ &ring, &done });

    const t0 = std.time.Instant.now() catch unreachable;
    var buf: [BATCH]u64 = undefined;
    @memset(&buf, 42);
    var sent: u64 = 0;
    while (sent < MSG_COUNT) {
        const n = ring.send(buf[0..@min(BATCH, MSG_COUNT - sent)]);
        sent += n;
        if (n == 0) std.atomic.spinLoopHint();
    }
    consumer.join();
    const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
    return @as(f64, @floatFromInt(MSG_COUNT)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);
}
