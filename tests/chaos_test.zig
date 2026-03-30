//! ringmpsc - Chaos Test
//!
//! Stress test with random producer/consumer timing and varying batch sizes.

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const NUM_PRODUCERS = 8;
const MESSAGES_PER_PRODUCER = 50_000;
const CHAOS_ITERATIONS = 5;

pub fn main() !void {
    std.debug.print("ringmpsc Chaos Test\n", .{});
    std.debug.print("================\n\n", .{});

    var all_passed = true;

    for (0..CHAOS_ITERATIONS) |iteration| {
        std.debug.print("Iteration {}...\n", .{iteration + 1});

        const passed = try runChaosIteration();
        if (!passed) {
            all_passed = false;
        }
    }

    std.debug.print("\n================\n", .{});
    std.debug.print("Status: {s}\n", .{if (all_passed) "ALL PASSED ✓" else "SOME FAILED ✗"});

    if (!all_passed) {
        std.process.exit(1);
    }
}

fn runChaosIteration() !bool {
    const ChaosConfig = ringmpsc.mpsc.Config{
        .max_producers = 16,
        .ring_bits = 12,
    };

    var channel = try ringmpsc.mpsc.Channel(u64, ChaosConfig).init(std.heap.page_allocator);
    defer channel.deinit();

    var total_sent = std.atomic.Value(usize).init(0);
    var total_received = std.atomic.Value(usize).init(0);

    // Spawn chaotic producers
    var producer_threads: [NUM_PRODUCERS]std.Thread = undefined;
    for (&producer_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, chaoticProducer, .{
            &channel,
            &total_sent,
            i,
        });
    }

    // Chaotic consumer
    const consumer_thread = try std.Thread.spawn(.{}, chaoticConsumer, .{
        &channel,
        &total_received,
    });

    // Wait for producers
    for (&producer_threads) |*thread| {
        thread.join();
    }

    // Give time to drain
    std.Thread.sleep(200 * std.time.ns_per_ms);
    channel.close();

    consumer_thread.join();

    const sent = total_sent.load(.acquire);
    const received = total_received.load(.acquire);
    const passed = sent == received;

    std.debug.print("  Sent: {}, Received: {}, {s}\n", .{
        sent,
        received,
        if (passed) "OK" else "MISMATCH",
    });

    return passed;
}

fn chaoticProducer(channel: anytype, total_sent: *std.atomic.Value(usize), id: usize) void {
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(id)) ^ @as(u64, @intCast(std.time.nanoTimestamp())));
    const rand = prng.random();

    const producer = channel.register() catch return;
    var sent: usize = 0;
    var backoff = ringmpsc.primitives.Backoff{};

    while (sent < MESSAGES_PER_PRODUCER) {
        // Random batch size 1-16
        const batch_size = rand.intRangeAtMost(usize, 1, 16);
        var batch_sent: usize = 0;

        for (0..batch_size) |_| {
            if (sent >= MESSAGES_PER_PRODUCER) break;

            if (producer.sendOne(@intCast(sent))) {
                sent += 1;
                batch_sent += 1;
                backoff.reset();
            } else {
                backoff.snooze();
            }
        }

        // Random delay 0-100us
        if (rand.boolean()) {
            std.Thread.sleep(rand.intRangeAtMost(u64, 0, 100) * std.time.ns_per_us);
        }
    }

    _ = total_sent.fetchAdd(sent, .release);
}

fn chaoticConsumer(channel: anytype, total_received: *std.atomic.Value(usize)) void {
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
    const rand = prng.random();

    var received: usize = 0;
    var backoff = ringmpsc.primitives.Backoff{};
    var empty_count: usize = 0;

    while (!channel.isClosed() or channel.pending() > 0) {
        const Handler = struct {
            count: *usize,
            pub fn process(self: @This(), _: *u64) void {
                self.count.* += 1;
            }
        };

        var batch: usize = 0;
        const max_batch = rand.intRangeAtMost(usize, 1, 128);
        _ = channel.consumeAllUpTo(max_batch, Handler{ .count = &batch });
        received += batch;

        if (batch > 0) {
            empty_count = 0;
            backoff.reset();
        } else {
            empty_count += 1;
            if (empty_count > 1000 and channel.isClosed()) break;
            backoff.snooze();
        }
    }

    _ = total_received.fetchAdd(received, .release);
}
