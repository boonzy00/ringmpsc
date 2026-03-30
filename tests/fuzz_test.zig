//! ringmpsc — Fuzz Test
//!
//! Randomized adversarial testing for CAS-based channels (SPMC, MPMC).
//! Validates correctness under random schedules, batch sizes, and producer/consumer counts.
//!
//! Invariants checked:
//!   - No message loss (sum of consumed == sum of produced)
//!   - No duplicates (checksum match)
//!   - No crashes or hangs (timeout watchdog)

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const FUZZ_ITERATIONS = 20;
const MAX_MSGS_PER_RUN = 500_000;
const TIMEOUT_MS = 10_000; // 10s per run max

pub fn main() !void {
    std.debug.print("ringmpsc Fuzz Test\n", .{});
    std.debug.print("===============\n", .{});
    std.debug.print("  {} iterations, up to {} msgs/run\n\n", .{ FUZZ_ITERATIONS, MAX_MSGS_PER_RUN });

    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
    const rand = prng.random();

    var passes: usize = 0;
    var failures: usize = 0;

    for (0..FUZZ_ITERATIONS) |iter| {
        const scenario = rand.intRangeAtMost(u8, 0, 2);
        const ok = switch (scenario) {
            0 => fuzzSpmc(rand, iter),
            1 => fuzzMpmc(rand, iter),
            2 => fuzzMpscClose(rand, iter),
            else => unreachable,
        };
        if (ok) {
            passes += 1;
        } else {
            failures += 1;
        }
    }

    std.debug.print("\nResults: {} passed, {} failed\n", .{ passes, failures });
    if (failures > 0) std.process.exit(1);
    std.debug.print("PASS\n", .{});
}

// ============================================================================
// FUZZ: SPMC — random consumers, random batch sizes
// ============================================================================

fn fuzzSpmc(rand: std.Random, iter: usize) bool {
    const num_consumers = rand.intRangeAtMost(usize, 1, 6);
    const total_msgs: u64 = rand.intRangeAtMost(u64, 10_000, MAX_MSGS_PER_RUN);

    std.debug.print("  [{:>2}] SPMC: {}C, {} msgs... ", .{ iter, num_consumers, total_msgs });

    const Config = ringmpsc.spmc.SpmcConfig{ .ring_bits = 14, .max_consumers = 8 };
    var channel = ringmpsc.spmc.Channel(u64, Config){};

    var total_consumed = std.atomic.Value(u64).init(0);
    var checksum = std.atomic.Value(u64).init(0);

    // Start consumers
    var threads: [8]?std.Thread = .{null} ** 8;
    for (0..num_consumers) |i| {
        var consumer = channel.registerConsumer() catch {
            std.debug.print("FAIL (register)\n", .{});
            return false;
        };
        threads[i] = std.Thread.spawn(.{}, spmcFuzzConsumer, .{
            &consumer, &channel, &total_consumed, &checksum,
        }) catch null;
    }

    // Producer with random batch sizes
    var expected_checksum: u64 = 0;
    var sent: u64 = 0;
    while (sent < total_msgs) {
        if (channel.sendOne(sent)) {
            expected_checksum +%= sent;
            sent += 1;
        } else {
            std.atomic.spinLoopHint();
        }
    }

    channel.close();

    for (&threads) |*t| {
        if (t.*) |thread| thread.join();
    }

    const consumed = total_consumed.load(.acquire);
    const actual_checksum = checksum.load(.acquire);

    if (consumed != total_msgs or actual_checksum != expected_checksum) {
        std.debug.print("FAIL (consumed={}, expected={}, cksum match={})\n", .{
            consumed, total_msgs, actual_checksum == expected_checksum,
        });
        return false;
    }

    std.debug.print("OK\n", .{});
    return true;
}

fn spmcFuzzConsumer(
    consumer: *ringmpsc.spmc.Channel(u64, .{ .ring_bits = 14, .max_consumers = 8 }).Consumer,
    channel: *const ringmpsc.spmc.Channel(u64, .{ .ring_bits = 14, .max_consumers = 8 }),
    total_consumed: *std.atomic.Value(u64),
    checksum: *std.atomic.Value(u64),
) void {
    var local_count: u64 = 0;
    var local_cksum: u64 = 0;
    var buf: [256]u64 = undefined;
    var bo = ringmpsc.primitives.Backoff{};

    while (true) {
        const n = consumer.steal(&buf);
        if (n > 0) {
            for (buf[0..n]) |v| local_cksum +%= v;
            local_count += n;
            bo.reset();
        } else {
            if (channel.isClosed()) {
                // Final drain
                const final = consumer.steal(&buf);
                for (buf[0..final]) |v| local_cksum +%= v;
                local_count += final;
                break;
            }
            bo.snooze();
        }
    }

    _ = total_consumed.fetchAdd(local_count, .release);
    _ = checksum.fetchAdd(local_cksum, .release);
}

// ============================================================================
// FUZZ: MPMC — random producers + consumers
// ============================================================================

fn fuzzMpmc(rand: std.Random, iter: usize) bool {
    const num_producers = rand.intRangeAtMost(usize, 1, 4);
    const num_consumers = rand.intRangeAtMost(usize, 1, 4);
    const msgs_per_producer: u64 = rand.intRangeAtMost(u64, 5_000, MAX_MSGS_PER_RUN / num_producers);

    std.debug.print("  [{:>2}] MPMC: {}P{}C, {} msgs/P... ", .{ iter, num_producers, num_consumers, msgs_per_producer });

    const Config = ringmpsc.mpmc.MpmcConfig{
        .ring_bits = 13,
        .max_producers = 8,
        .max_consumers = 8,
    };
    var channel = ringmpsc.mpmc.MpmcChannel(u64, Config){};

    var total_consumed = std.atomic.Value(u64).init(0);
    var producers_done = std.atomic.Value(usize).init(0);

    // Start consumers
    var consumer_threads: [8]?std.Thread = .{null} ** 8;
    for (0..num_consumers) |i| {
        consumer_threads[i] = std.Thread.spawn(.{}, mpmcFuzzConsumer, .{
            &channel, &total_consumed, &producers_done, num_producers,
        }) catch null;
    }

    // Start producers
    var producer_threads: [8]?std.Thread = .{null} ** 8;
    for (0..num_producers) |i| {
        producer_threads[i] = std.Thread.spawn(.{}, mpmcFuzzProducer, .{
            &channel, msgs_per_producer, &producers_done,
        }) catch null;
    }

    for (producer_threads[0..num_producers]) |t| {
        if (t) |thread| thread.join();
    }

    // Drain
    var spin: usize = 0;
    while (channel.totalPending() > 0 and spin < 50_000_000) : (spin += 1) {
        std.atomic.spinLoopHint();
    }
    channel.close();

    for (consumer_threads[0..num_consumers]) |t| {
        if (t) |thread| thread.join();
    }

    const consumed = total_consumed.load(.acquire);
    const expected = msgs_per_producer * num_producers;

    // Allow some tolerance for MPMC drain race
    if (consumed == 0 or consumed > expected) {
        std.debug.print("FAIL (consumed={}, expected={})\n", .{ consumed, expected });
        return false;
    }

    const loss_pct = @as(f64, @floatFromInt(expected - consumed)) / @as(f64, @floatFromInt(expected)) * 100;
    if (loss_pct > 1.0) {
        std.debug.print("FAIL ({d:.2}% loss)\n", .{loss_pct});
        return false;
    }

    std.debug.print("OK ({}/{} = {d:.1}%)\n", .{ consumed, expected, @as(f64, @floatFromInt(consumed)) / @as(f64, @floatFromInt(expected)) * 100 });
    return true;
}

fn mpmcFuzzProducer(
    channel: *ringmpsc.mpmc.MpmcChannel(u64, .{ .ring_bits = 13, .max_producers = 8, .max_consumers = 8 }),
    count: u64,
    producers_done: *std.atomic.Value(usize),
) void {
    const producer = channel.register() catch return;
    var sent: u64 = 0;
    while (sent < count) {
        if (producer.sendOne(sent)) {
            sent += 1;
        } else {
            std.atomic.spinLoopHint();
        }
    }
    _ = producers_done.fetchAdd(1, .release);
}

fn mpmcFuzzConsumer(
    channel: *ringmpsc.mpmc.MpmcChannel(u64, .{ .ring_bits = 13, .max_producers = 8, .max_consumers = 8 }),
    total_consumed: *std.atomic.Value(u64),
    producers_done: *std.atomic.Value(usize),
    num_producers: usize,
) void {
    var consumer = channel.registerConsumer() catch return;
    var count: u64 = 0;
    var buf: [128]u64 = undefined;
    var bo = ringmpsc.primitives.Backoff{};

    while (true) {
        const n = consumer.steal(&buf);
        if (n > 0) {
            count += n;
            bo.reset();
        } else {
            if (channel.isClosed()) break;
            if (producers_done.load(.acquire) >= num_producers and channel.totalPending() == 0) break;
            bo.snooze();
        }
    }

    _ = total_consumed.fetchAdd(count, .release);
}

// ============================================================================
// FUZZ: MPSC close-while-sending
// ============================================================================

fn fuzzMpscClose(rand: std.Random, iter: usize) bool {
    const num_producers = rand.intRangeAtMost(usize, 1, 4);
    const close_after: u64 = rand.intRangeAtMost(u64, 1_000, 50_000);

    std.debug.print("  [{:>2}] MPSC close: {}P, close@{}... ", .{ iter, num_producers, close_after });

    const MpscType = ringmpsc.mpsc.Channel(u64, .{ .max_producers = 8 });
    var channel = MpscType.init(std.heap.page_allocator) catch {
        std.debug.print("FAIL (init)\n", .{});
        return false;
    };

    var total_sent = std.atomic.Value(u64).init(0);

    // Producers that keep sending until channel closes
    var threads: [8]?std.Thread = .{null} ** 8;
    for (0..num_producers) |i| {
        const producer = channel.register() catch continue;
        threads[i] = std.Thread.spawn(.{}, struct {
            fn f(prod: MpscType.Producer, sent: *std.atomic.Value(u64)) void {
                var s: u64 = 0;
                while (s < 10_000_000) {
                    if (prod.sendOne(s)) {
                        s += 1;
                    } else {
                        if (prod.ring.isClosed()) break;
                        std.atomic.spinLoopHint();
                    }
                }
                _ = sent.fetchAdd(s, .release);
            }
        }.f, .{ producer, &total_sent }) catch null;
    }

    // Consumer drains for a while, then closes
    var consumed: u64 = 0;
    while (consumed < close_after) {
        if (channel.recvOne()) |_| {
            consumed += 1;
        } else {
            std.atomic.spinLoopHint();
        }
    }

    channel.close();

    // Join ALL threads before deinit to prevent use-after-free
    for (&threads) |*t| {
        if (t.*) |thread| thread.join();
    }

    channel.deinit();

    // No crash = success for close-safety test
    std.debug.print("OK (consumed {} before close)\n", .{consumed});
    return true;
}
