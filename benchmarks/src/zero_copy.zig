//! BufferPool Zero-Copy Benchmark
//!
//! Compares inline Ring(T) copy vs BufferPool handle-ring at various
//! message sizes to quantify the zero-copy advantage.
//!
//! Run: zig build bench-zero-copy -Doptimize=ReleaseFast

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const BufferPool = ringmpsc.primitives.BufferPool;
const Handle = ringmpsc.primitives.Handle;

const RUNS: usize = 5;
const MSG_COUNT: u64 = 5_000_000;

const stderr = (std.fs.File{ .handle = std.posix.STDERR_FILENO }).deprecatedWriter();

pub fn main() !void {
    try stderr.print("\nBufferPool Zero-Copy Benchmark\n", .{});
    try stderr.print("===============================\n\n", .{});
    try stderr.print("  {s:<12} {s:>14} {s:>14} {s:>10}\n", .{ "msg_size", "inline_copy", "zero_copy", "speedup" });
    try stderr.print("  {s:<12} {s:>14} {s:>14} {s:>10}\n", .{ "--------", "-----------", "---------", "-------" });

    // Can only benchmark sizes that are comptime-known for inline Ring(T)
    try benchSize(64, "64B");
    try benchSize(256, "256B");
    try benchSize(1024, "1KB");
    try benchSize(4096, "4KB");

    try stderr.print("\n  note: inline copies T into ring slots; zero-copy sends 4-byte handle\n", .{});
    try stderr.print("  note: zero-copy adds alloc/free CAS overhead (~10-50ns each)\n", .{});
    try stderr.print("\n", .{});
}

fn benchSize(comptime size: comptime_int, label: []const u8) !void {
    const T = [size]u8;
    const Pool = BufferPool(size, 8192);

    // Inline copy: Ring([size]u8)
    var inline_results: [RUNS]f64 = undefined;
    for (0..RUNS) |r| {
        inline_results[r] = try benchInline(T);
    }

    // Zero-copy: Ring(Handle) + BufferPool
    var zc_results: [RUNS]f64 = undefined;
    for (0..RUNS) |r| {
        zc_results[r] = try benchZeroCopy(Pool);
    }

    std.mem.sort(f64, &inline_results, {}, std.sort.asc(f64));
    std.mem.sort(f64, &zc_results, {}, std.sort.asc(f64));
    const inline_med = inline_results[RUNS / 2];
    const zc_med = zc_results[RUNS / 2];
    const speedup = zc_med / inline_med;

    try stderr.print("  {s:<12} {d:>11.1} M/s {d:>11.1} M/s {d:>8.1}x\n", .{
        label, inline_med / 1e6, zc_med / 1e6, speedup,
    });
}

fn benchInline(comptime T: type) !f64 {
    const Config = ringmpsc.primitives.ring_buffer.Config{ .ring_bits = 12 };
    var ring = ringmpsc.primitives.Ring(T, Config){};
    var done = std.atomic.Value(bool).init(false);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *ringmpsc.primitives.Ring(T, Config), d: *std.atomic.Value(bool)) void {
            var count: u64 = 0;
            while (count < MSG_COUNT) {
                if (r.readable()) |slice| {
                    // Read one byte to prevent DCE
                    std.mem.doNotOptimizeAway(slice[0][0]);
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
    var msg: T = undefined;
    @memset(&msg, 0xAB);
    var sent: u64 = 0;
    while (sent < MSG_COUNT) {
        if (ring.reserve(1)) |r| {
            r.slice[0] = msg;
            ring.commit(1);
            sent += 1;
        } else {
            std.atomic.spinLoopHint();
        }
    }
    consumer.join();
    const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
    return @as(f64, @floatFromInt(MSG_COUNT)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);
}

fn benchZeroCopy(comptime Pool: type) !f64 {
    const Config = ringmpsc.primitives.ring_buffer.Config{ .ring_bits = 12 };
    var ring = ringmpsc.primitives.Ring(Handle, Config){};
    var pool: Pool = .{};
    var done = std.atomic.Value(bool).init(false);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *ringmpsc.primitives.Ring(Handle, Config), p: *Pool, d: *std.atomic.Value(bool)) void {
            var count: u64 = 0;
            while (count < MSG_COUNT) {
                if (r.readable()) |slice| {
                    for (slice) |handle| {
                        const data = p.get(handle);
                        std.mem.doNotOptimizeAway(data[0]);
                        p.free(handle);
                    }
                    count += slice.len;
                    r.advance(slice.len);
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            d.store(true, .release);
        }
    }.run, .{ &ring, &pool, &done });

    const t0 = std.time.Instant.now() catch unreachable;
    var sent: u64 = 0;
    while (sent < MSG_COUNT) {
        const handle = pool.alloc() orelse {
            std.atomic.spinLoopHint();
            continue;
        };
        const buf = pool.getWritable(handle);
        @memset(buf, 0xAB);
        pool.setLen(handle, Pool.SLAB_SIZE);
        if (ring.reserve(1)) |r| {
            r.slice[0] = handle;
            ring.commit(1);
            sent += 1;
        } else {
            pool.free(handle);
            std.atomic.spinLoopHint();
        }
    }
    consumer.join();
    const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
    return @as(f64, @floatFromInt(MSG_COUNT)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);
}
