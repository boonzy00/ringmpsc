// High Performance MPSC Benchmark
//
// Measures peak channel throughput with:
// - CPU pinning (producers + consumer on dedicated cores)
// - Start barriers for synchronized launch
// - Spin-loop backpressure
// - Large batches (32K) to amortize atomics
// - Inlined consumer (direct ring access, no function calls)
// - Broadcast fill (@memset — exercises full memory write bandwidth)
//
// Runs both u32 and u64 message types to show memory bandwidth impact.

const std = @import("std");
const ringmpsc = @import("ringmpsc");

// ============================================================================
// CONFIGURATION
// ============================================================================

const CPU_COUNT: usize = 16;
const MSG_PER_PRODUCER: u64 = 500_000_000;
const MSG_PER_PRODUCER_READ: u64 = 100_000_000; // data-reading consumer reads every element
const BATCH_SIZE: usize = 32768;
const MAX_PRODUCERS: usize = 8;

const BenchConfig = ringmpsc.mpsc.Config{
    .ring_bits = 15,
    .max_producers = MAX_PRODUCERS,
    .enable_metrics = false,
    .prefetch_threshold = 0,
};

// ============================================================================
// MAIN
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("ringmpsc high-perf MPSC benchmark\n", .{});
    std.debug.print("  {}M msgs/producer, {}K batch, {}K ring\n", .{
        MSG_PER_PRODUCER / 1_000_000,
        BATCH_SIZE / 1024,
        @as(u64, 1) << BenchConfig.ring_bits >> 10,
    });
    std.debug.print("\n", .{});

    const producer_counts = [_]usize{ 1, 2, 4, 6, 8 };

    // u32 messages (4 bytes — 128KB per batch write)
    std.debug.print("  u32 messages (4B each)\n", .{});
    std.debug.print("  {s:<10} {s:>12}\n", .{ "config", "throughput" });
    std.debug.print("  {s:<10} {s:>12}\n", .{ "------", "----------" });
    for (producer_counts) |p| {
        const r = try runBench(u32, p);
        std.debug.print("  {}P1C       {:>8.2} B/s\n", .{ p, r.rate });
    }

    std.debug.print("\n", .{});

    // u64 messages (8 bytes — 256KB per batch write)
    std.debug.print("  u64 messages (8B each)\n", .{});
    std.debug.print("  {s:<10} {s:>12}\n", .{ "config", "throughput" });
    std.debug.print("  {s:<10} {s:>12}\n", .{ "------", "----------" });
    for (producer_counts) |p| {
        const r = try runBench(u64, p);
        std.debug.print("  {}P1C       {:>8.2} B/s\n", .{ p, r.rate });
    }

    std.debug.print("\n", .{});

    // u32 with data-reading consumer (checksum every element)
    std.debug.print("  u32 with data-reading consumer ({}M msgs/producer, checksum)\n", .{MSG_PER_PRODUCER_READ / 1_000_000});
    std.debug.print("  {s:<10} {s:>12}\n", .{ "config", "throughput" });
    std.debug.print("  {s:<10} {s:>12}\n", .{ "------", "----------" });
    for (producer_counts) |p| {
        const r = try runBenchWithConsume(u32, p, MSG_PER_PRODUCER_READ);
        std.debug.print("  {}P1C       {:>8.2} B/s\n", .{ p, r.rate });
    }

    std.debug.print("\n", .{});
    std.debug.print("  note: throughput is memory-bandwidth bound per message size\n", .{});
    std.debug.print("  note: data-reading consumer reads+checksums every element\n", .{});
    std.debug.print("  tip: sudo taskset -c 0-15 nice -n -20 ./bench-high-perf\n", .{});
    std.debug.print("\n", .{});
}

// ============================================================================
// GENERIC BENCHMARK RUNNER
// ============================================================================

const Result = struct { rate: f64, total_messages: u64, elapsed_ns: u64 };

fn runBench(comptime T: type, num_producers: usize) !Result {
    const Chan = ringmpsc.mpsc.Channel(T, BenchConfig);
    const RingType = ringmpsc.primitives.Ring(T, BenchConfig);

    var channel = try Chan.init(std.heap.page_allocator);
    defer channel.deinit();

    var producer_threads: [MAX_PRODUCERS]std.Thread = undefined;
    var producers: [MAX_PRODUCERS]Chan.Producer = undefined;
    var start_barrier = std.atomic.Value(bool).init(false);
    var producers_done = std.atomic.Value(usize).init(0);
    var consumer_elapsed = std.atomic.Value(u64).init(0);

    for (0..num_producers) |i| {
        producers[i] = try channel.register();
    }

    // Consumer thread
    const consumer_thread = try std.Thread.spawn(.{}, struct {
        fn run(
            ch: *Chan,
            elapsed_out: *std.atomic.Value(u64),
            n_prod: usize,
            p_done: *std.atomic.Value(usize),
            barrier: *std.atomic.Value(bool),
        ) void {
            pin(n_prod);

            while (!barrier.load(.acquire)) std.atomic.spinLoopHint();

            const t0 = std.time.Instant.now() catch unreachable;

            var rings: [MAX_PRODUCERS]*RingType = undefined;
            for (0..n_prod) |i| rings[i] = ch.rings[i];

            var count: u64 = 0;
            var idle: u32 = 0;

            while (true) {
                var batch: usize = 0;
                for (rings[0..n_prod]) |ring| {
                    const h = ring.head.load(.monotonic);
                    const t = ring.tail.load(.acquire);
                    const avail = t -% h;
                    if (avail == 0) continue;
                    ring.head.store(t, .release);
                    batch += avail;
                }
                count += batch;

                if (batch == 0) {
                    idle += 1;
                    if (idle > 64) {
                        if (p_done.load(.acquire) >= n_prod and ch.isClosed()) {
                            for (rings[0..n_prod]) |ring| {
                                const h = ring.head.load(.monotonic);
                                const t = ring.tail.load(.acquire);
                                count += t -% h;
                                ring.head.store(t, .release);
                            }
                            break;
                        }
                        idle = 0;
                    }
                    std.atomic.spinLoopHint();
                } else {
                    idle = 0;
                }
            }

            elapsed_out.store((std.time.Instant.now() catch unreachable).since(t0), .release);
        }
    }.run, .{ &channel, &consumer_elapsed, num_producers, &producers_done, &start_barrier });

    // Producer threads
    for (0..num_producers) |i| {
        producer_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(
                prod: *Chan.Producer,
                cpu: usize,
                barrier: *std.atomic.Value(bool),
                p_done: *std.atomic.Value(usize),
            ) void {
                pin(cpu);
                while (!barrier.load(.acquire)) std.atomic.spinLoopHint();

                const ring = prod.ring;
                var sent: u64 = 0;
                while (sent < MSG_PER_PRODUCER) {
                    const want = @min(BATCH_SIZE, MSG_PER_PRODUCER - sent);
                    if (ring.reserve(want)) |r| {
                        @memset(r.slice, @as(T, @truncate(sent)));
                        ring.commit(r.slice.len);
                        sent += r.slice.len;
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
                _ = p_done.fetchAdd(1, .release);
            }
        }.run, .{ &producers[i], i, &start_barrier, &producers_done });
    }

    start_barrier.store(true, .seq_cst);

    for (0..num_producers) |i| producer_threads[i].join();
    channel.close();
    consumer_thread.join();

    const elapsed_ns = consumer_elapsed.load(.acquire);
    const total = MSG_PER_PRODUCER * num_producers;

    return .{
        .rate = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(elapsed_ns)),
        .total_messages = total,
        .elapsed_ns = elapsed_ns,
    };
}

/// Same as runBench but the consumer actually reads every element and
/// accumulates a checksum. This measures real end-to-end throughput
/// including read bandwidth, not just pointer advancement.
fn runBenchWithConsume(comptime T: type, num_producers: usize, msgs_per_producer: u64) !Result {
    const Chan = ringmpsc.mpsc.Channel(T, BenchConfig);
    const RingType = ringmpsc.primitives.Ring(T, BenchConfig);
    const MASK = (@as(usize, 1) << BenchConfig.ring_bits) - 1;

    var channel = try Chan.init(std.heap.page_allocator);
    defer channel.deinit();

    var producer_threads: [MAX_PRODUCERS]std.Thread = undefined;
    var producers: [MAX_PRODUCERS]Chan.Producer = undefined;
    var start_barrier = std.atomic.Value(bool).init(false);
    var producers_done = std.atomic.Value(usize).init(0);
    var consumer_elapsed = std.atomic.Value(u64).init(0);
    var consumer_checksum = std.atomic.Value(u64).init(0);

    for (0..num_producers) |i| {
        producers[i] = try channel.register();
    }

    // Consumer thread — reads every element and accumulates checksum
    const consumer_thread = try std.Thread.spawn(.{}, struct {
        fn run(
            ch: *Chan,
            elapsed_out: *std.atomic.Value(u64),
            checksum_out: *std.atomic.Value(u64),
            n_prod: usize,
            p_done: *std.atomic.Value(usize),
            barrier: *std.atomic.Value(bool),
        ) void {
            pin(n_prod);
            while (!barrier.load(.acquire)) std.atomic.spinLoopHint();

            const t0 = std.time.Instant.now() catch unreachable;

            var rings: [MAX_PRODUCERS]*RingType = undefined;
            for (0..n_prod) |i| rings[i] = ch.rings[i];

            var count: u64 = 0;
            var checksum: u64 = 0;
            var idle: u32 = 0;

            while (true) {
                var batch: usize = 0;
                for (rings[0..n_prod]) |ring| {
                    const h = ring.head.load(.monotonic);
                    const t = ring.tail.load(.acquire);
                    const avail = t -% h;
                    if (avail == 0) continue;
                    // Read every element via direct buffer pointer
                    const buf: [*]const T = &ring.buffer;
                    var pos = h;
                    while (pos != t) : (pos +%= 1) {
                        checksum +%= buf[@as(usize, @intCast(pos & MASK))];
                    }
                    ring.head.store(t, .release);
                    batch += avail;
                }
                count += batch;

                if (batch == 0) {
                    idle += 1;
                    if (idle > 64) {
                        if (p_done.load(.acquire) >= n_prod and ch.isClosed()) {
                            for (rings[0..n_prod]) |ring| {
                                const h = ring.head.load(.monotonic);
                                const t = ring.tail.load(.acquire);
                                const buf: [*]const T = &ring.buffer;
                                var pos = h;
                                while (pos != t) : (pos +%= 1) {
                                    checksum +%= buf[@as(usize, @intCast(pos & MASK))];
                                }
                                count += t -% h;
                                ring.head.store(t, .release);
                            }
                            break;
                        }
                        idle = 0;
                    }
                    std.atomic.spinLoopHint();
                } else {
                    idle = 0;
                }
            }

            checksum_out.store(checksum, .release);
            elapsed_out.store((std.time.Instant.now() catch unreachable).since(t0), .release);
        }
    }.run, .{ &channel, &consumer_elapsed, &consumer_checksum, num_producers, &producers_done, &start_barrier });

    // Producer threads (same as runBench but with parameterized count)
    for (0..num_producers) |i| {
        producer_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(
                prod: *Chan.Producer,
                cpu: usize,
                barrier: *std.atomic.Value(bool),
                p_done: *std.atomic.Value(usize),
                target: u64,
            ) void {
                pin(cpu);
                while (!barrier.load(.acquire)) std.atomic.spinLoopHint();

                const ring = prod.ring;
                var sent: u64 = 0;
                while (sent < target) {
                    const want = @min(BATCH_SIZE, target - sent);
                    if (ring.reserve(want)) |r| {
                        @memset(r.slice, @as(T, @truncate(sent)));
                        ring.commit(r.slice.len);
                        sent += r.slice.len;
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
                _ = p_done.fetchAdd(1, .release);
            }
        }.run, .{ &producers[i], i, &start_barrier, &producers_done, msgs_per_producer });
    }

    start_barrier.store(true, .seq_cst);

    for (0..num_producers) |i| producer_threads[i].join();
    channel.close();
    consumer_thread.join();

    const elapsed_ns = consumer_elapsed.load(.acquire);
    const total = msgs_per_producer * num_producers;

    // Use checksum to prevent DCE (volatile sink)
    const cs = consumer_checksum.load(.acquire);
    if (cs == 0 and total > 0) {
        // Checksum is zero only if all values were zero — possible but unlikely.
        // This branch prevents the compiler from optimizing away the reads.
        std.debug.print("    (checksum: {})\n", .{cs});
    }

    return .{
        .rate = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(elapsed_ns)),
        .total_messages = total,
        .elapsed_ns = elapsed_ns,
    };
}

fn pin(cpu: usize) void {
    const actual = cpu % CPU_COUNT;
    var set = std.mem.zeroes(std.os.linux.cpu_set_t);
    set[actual / 64] |= @as(u64, 1) << @as(u6, @intCast(actual % 64));
    std.os.linux.sched_setaffinity(0, &set) catch {};
}
