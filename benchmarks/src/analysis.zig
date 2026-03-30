// Bottleneck Analysis Benchmark
//
// Runs isolated tests to identify where time is spent:
// 1. Pure producer throughput (no consumer — fill until full, measure reserve+commit+memset)
// 2. Pure consumer throughput (pre-filled ring — measure head advancement)
// 3. Producer-only with no memset (just reserve+commit)
// 4. Full pipeline (producer + consumer)

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const RING_BITS: u6 = 15;
const CAPACITY: usize = 1 << RING_BITS;
const BATCH: usize = 32768;
const ITERATIONS: usize = 100_000;

const RingConfig = ringmpsc.primitives.Config{
    .ring_bits = RING_BITS,
    .max_producers = 1,
    .enable_metrics = false,
    .prefetch_threshold = 0,
};
const Ring = ringmpsc.primitives.Ring(u64, RingConfig);

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("ringmpsc Bottleneck Analysis\n", .{});
    std.debug.print("============================\n\n", .{});

    // Test 1: reserve + memset + commit (producer hot path)
    {
        var ring = Ring{};
        const t0 = std.time.Instant.now() catch unreachable;
        var total_msgs: u64 = 0;

        for (0..ITERATIONS) |iter| {
            _ = iter;
            if (ring.reserve(BATCH)) |r| {
                @memset(r.slice, @as(u64, 42));
                ring.commit(r.slice.len);
                total_msgs += r.slice.len;
            }
            // Drain to make space
            const h = ring.head.load(.monotonic);
            const t = ring.tail.load(.monotonic);
            ring.head.store(t, .release);
            _ = h;
        }

        const ns = (std.time.Instant.now() catch unreachable).since(t0);
        const rate = @as(f64, @floatFromInt(total_msgs)) / @as(f64, @floatFromInt(ns));
        std.debug.print("  reserve + memset + commit:     {d:>8.2} B/s  ({d}M msgs)\n", .{ rate, total_msgs / 1_000_000 });
    }

    // Test 2: reserve + commit only (no memset)
    {
        var ring = Ring{};
        const t0 = std.time.Instant.now() catch unreachable;
        var total_msgs: u64 = 0;

        for (0..ITERATIONS) |_| {
            if (ring.reserve(BATCH)) |r| {
                r.slice[0] = 42; // touch one element
                ring.commit(r.slice.len);
                total_msgs += r.slice.len;
            }
            // Drain
            const t = ring.tail.load(.monotonic);
            ring.head.store(t, .release);
        }

        const ns = (std.time.Instant.now() catch unreachable).since(t0);
        const rate = @as(f64, @floatFromInt(total_msgs)) / @as(f64, @floatFromInt(ns));
        std.debug.print("  reserve + commit (no fill):    {d:>8.2} B/s  ({d}M msgs)\n", .{ rate, total_msgs / 1_000_000 });
    }

    // Test 3: memset only (no ring ops)
    {
        var buf: [BATCH]u64 = undefined;
        const t0 = std.time.Instant.now() catch unreachable;
        var total_msgs: u64 = 0;

        for (0..ITERATIONS) |_| {
            @memset(&buf, @as(u64, 42));
            total_msgs += BATCH;
        }

        const ns = (std.time.Instant.now() catch unreachable).since(t0);
        const rate = @as(f64, @floatFromInt(total_msgs)) / @as(f64, @floatFromInt(ns));
        std.debug.print("  memset only (no ring):         {d:>8.2} B/s  ({d}M msgs)\n", .{ rate, total_msgs / 1_000_000 });
    }

    // Test 4: sequential fill only (no ring ops)
    {
        var buf: [BATCH]u64 = undefined;
        const t0 = std.time.Instant.now() catch unreachable;
        var total_msgs: u64 = 0;

        for (0..ITERATIONS) |iter| {
            const base = @as(u64, @intCast(iter)) * BATCH;
            for (&buf, 0..) |*slot, i| {
                slot.* = base + i;
            }
            total_msgs += BATCH;
        }

        const ns = (std.time.Instant.now() catch unreachable).since(t0);
        const rate = @as(f64, @floatFromInt(total_msgs)) / @as(f64, @floatFromInt(ns));
        std.debug.print("  sequential fill (no ring):     {d:>8.2} B/s  ({d}M msgs)\n", .{ rate, total_msgs / 1_000_000 });
    }

    // Test 5: consumer drain only (pre-filled)
    {
        var ring = Ring{};
        const t0 = std.time.Instant.now() catch unreachable;
        var total_msgs: u64 = 0;

        for (0..ITERATIONS) |_| {
            // Fill
            ring.tail.store(ring.tail.load(.monotonic) +% BATCH, .release);
            // Drain (inlined consumeBatchCount)
            const h = ring.head.load(.monotonic);
            const t = ring.tail.load(.acquire);
            const avail = t -% h;
            ring.head.store(t, .release);
            total_msgs += avail;
        }

        const ns = (std.time.Instant.now() catch unreachable).since(t0);
        const rate = @as(f64, @floatFromInt(total_msgs)) / @as(f64, @floatFromInt(ns));
        std.debug.print("  consumer drain only:           {d:>8.2} B/s  ({d}M msgs)\n", .{ rate, total_msgs / 1_000_000 });
    }

    // Test 6: full pipeline 1P1C with memset
    {
        var ring = Ring{};
        var done = std.atomic.Value(bool).init(false);
        var consumer_count = std.atomic.Value(u64).init(0);

        const consumer = try std.Thread.spawn(.{}, struct {
            fn run(r: *Ring, cnt: *std.atomic.Value(u64), d: *std.atomic.Value(bool)) void {
                var c: u64 = 0;
                while (true) {
                    const h = r.head.load(.monotonic);
                    const t = r.tail.load(.acquire);
                    const avail = t -% h;
                    if (avail > 0) {
                        r.head.store(t, .release);
                        c += avail;
                    } else if (d.load(.acquire)) {
                        // final drain
                        const fh = r.head.load(.monotonic);
                        const ft = r.tail.load(.acquire);
                        c += ft -% fh;
                        r.head.store(ft, .release);
                        break;
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
                cnt.store(c, .release);
            }
        }.run, .{ &ring, &consumer_count, &done });

        const MSG_COUNT: u64 = 500_000_000;
        const t0 = std.time.Instant.now() catch unreachable;

        var sent: u64 = 0;
        while (sent < MSG_COUNT) {
            const want = @min(BATCH, MSG_COUNT - sent);
            if (ring.reserve(want)) |r| {
                @memset(r.slice, sent);
                ring.commit(r.slice.len);
                sent += r.slice.len;
            } else {
                std.atomic.spinLoopHint();
            }
        }

        done.store(true, .release);
        consumer.join();

        const ns = (std.time.Instant.now() catch unreachable).since(t0);
        const rate = @as(f64, @floatFromInt(sent)) / @as(f64, @floatFromInt(ns));
        std.debug.print("  1P1C pipeline (memset):        {d:>8.2} B/s  ({d}M msgs)\n", .{ rate, sent / 1_000_000 });
    }

    std.debug.print("\n", .{});
    std.debug.print("  Analysis:\n", .{});
    std.debug.print("  - If memset >> reserve+commit: memory bandwidth is the bottleneck\n", .{});
    std.debug.print("  - If reserve+commit >> memset: atomic ops are the bottleneck\n", .{});
    std.debug.print("  - 8P1C theoretical max = 1P1C × 8 (if consumer keeps up)\n", .{});
    std.debug.print("\n", .{});
}
