//! RingMPSC - Throughput Benchmark
//! Target: 50+ billion messages per second on AMD Ryzen 7 5700

const std = @import("std");
const ringmpsc = @import("channel");

// Configuration
const MSG: u64 = 500_000_000;  // 500M messages per producer
const BATCH: usize = 32768;    // Batch size for zero-copy operations
const RING_BITS: u6 = 16;      // 64K slots per ring
const MAX_PRODUCERS: usize = 8;
const CPU_COUNT: usize = 16;   // Ryzen 7 5700: 8 cores, 16 threads

const config = ringmpsc.Config{ .ring_bits = RING_BITS, .max_producers = MAX_PRODUCERS };
const ChannelType = ringmpsc.Channel(u32, config);
const RingType = ringmpsc.Ring(u32, config);

// No-op consumer handler (compiler optimizes away the loop body)
const Consumer = struct {
    pub fn process(_: Consumer, _: *const u32) void {}
};

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("║                       RINGMPSC - THROUGHPUT BENCHMARK                       ║\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Platform: AMD Ryzen 7 5700 (8C/16T, 32MB L3)\n", .{});
    std.debug.print("Config:   {d}M msgs/producer, batch={d}, ring={d}K slots\n\n", .{ MSG / 1_000_000, BATCH, @as(u64, 1) << RING_BITS >> 10 });
    std.debug.print("┌─────────────┬───────────────┬─────────┐\n", .{});
    std.debug.print("│ Config      │ Throughput    │ Status  │\n", .{});
    std.debug.print("├─────────────┼───────────────┼─────────┤\n", .{});

    // Warmup run
    _ = try runTest(4);

    // Benchmark configurations
    const counts = [_]usize{ 1, 2, 4, 6, 8 };
    for (counts) |p| {
        const r = try runTest(p);
        const status = if (r.rate >= 50.0) "✓ PASS" else if (r.rate >= 30.0) "○ OK  " else "✗ LOW ";
        std.debug.print("│ {d}P{d}C        │ {d:>8.2} B/s  │ {s} │\n", .{ p, p, r.rate, status });
    }

    std.debug.print("└─────────────┴───────────────┴─────────┘\n", .{});
    std.debug.print("\nB/s = billion messages per second\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n\n", .{});
}

fn runTest(num_producers: usize) !struct { rate: f64 } {
    var channel: ChannelType = .{};

    var producer_threads: [MAX_PRODUCERS]std.Thread = undefined;
    var consumer_threads: [MAX_PRODUCERS]std.Thread = undefined;
    var producers: [MAX_PRODUCERS]ChannelType.Producer = undefined;
    var counts_c: [MAX_PRODUCERS]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** MAX_PRODUCERS;

    for (0..num_producers) |i| producers[i] = channel.register() catch unreachable;

    const t0 = std.time.nanoTimestamp();

    // Start consumer threads (pin to CPUs after producers)
    for (0..num_producers) |i| {
        consumer_threads[i] = try std.Thread.spawn(.{}, consumer, .{ &channel.rings[i], &counts_c[i], num_producers + i });
    }

    // Start producer threads (pin to first N CPUs)
    for (0..num_producers) |i| {
        producer_threads[i] = try std.Thread.spawn(.{}, producer, .{ &producers[i], i });
    }

    // Wait for producers
    for (0..num_producers) |i| producer_threads[i].join();

    // Close rings to signal consumers
    for (0..num_producers) |i| channel.rings[i].close();

    // Wait for consumers
    for (0..num_producers) |i| consumer_threads[i].join();

    const ns = @as(u64, @intCast(std.time.nanoTimestamp() - t0));

    var count_c: u64 = 0;
    for (0..num_producers) |i| count_c += counts_c[i].load(.acquire);

    return .{ .rate = @as(f64, @floatFromInt(count_c)) / @as(f64, @floatFromInt(ns)) };
}

fn producer(p: *ChannelType.Producer, cpu: usize) void {
    pin(cpu);
    var sent: u64 = 0;

    while (sent < MSG) {
        const want = @min(BATCH, MSG - sent);
        if (p.reserve(want)) |r| {
            // Write pattern (optimized 4-way unroll)
            var i: usize = 0;
            while (i + 4 <= r.slice.len) : (i += 4) {
                r.slice[i] = @truncate(sent + i);
                r.slice[i + 1] = @truncate(sent + i + 1);
                r.slice[i + 2] = @truncate(sent + i + 2);
                r.slice[i + 3] = @truncate(sent + i + 3);
            }
            while (i < r.slice.len) : (i += 1) {
                r.slice[i] = @truncate(sent + i);
            }
            p.commit(r.slice.len);
            sent += r.slice.len;
        } else {
            std.atomic.spinLoopHint();
        }
    }
}

fn consumer(ring: *RingType, count_out: *std.atomic.Value(u64), cpu: usize) void {
    pin(cpu);
    var count: u64 = 0;

    while (true) {
        const consumed = ring.consumeBatch(Consumer{});
        count += consumed;
        if (consumed == 0) {
            if (ring.isClosed() and ring.isEmpty()) break;
            std.atomic.spinLoopHint();
        }
    }

    count_out.store(count, .release);
}

fn pin(cpu: usize) void {
    const actual = cpu % CPU_COUNT;
    var set = std.mem.zeroes(std.os.linux.cpu_set_t);
    set[actual / 64] |= @as(u64, 1) << @as(u6, @intCast(actual % 64));
    std.os.linux.sched_setaffinity(0, &set) catch {};
}
