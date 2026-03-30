//! ringmpsc - Determinism Test
//!
//! Verifies that:
//! 1. All messages from all producers are received
//! 2. Per-producer FIFO ordering is maintained
//! 3. Results are consistent across multiple runs
//!
//! Note: Global ordering across producers is NOT deterministic (expected).

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const NUM_PRODUCERS = 4;
const MESSAGES_PER_PRODUCER = 1_000;
const NUM_RUNS = 3;

pub fn main() !void {
    std.debug.print("ringmpsc Determinism Test\n", .{});
    std.debug.print("======================\n\n", .{});

    var all_passed = true;

    for (0..NUM_RUNS) |run| {
        const result = try runDeterministicTest();
        std.debug.print("Run {}: received={}, order_violations={}, {s}\n", .{
            run + 1,
            result.received,
            result.violations,
            if (result.passed) "PASS" else "FAIL",
        });
        if (!result.passed) all_passed = false;
    }

    std.debug.print("\n======================\n", .{});
    std.debug.print("Status: {s}\n", .{if (all_passed) "DETERMINISTIC ✓" else "FAILED ✗"});

    if (!all_passed) {
        std.process.exit(1);
    }
}

const TestResult = struct {
    received: usize,
    violations: usize,
    passed: bool,
};

fn runDeterministicTest() !TestResult {
    const DetConfig = ringmpsc.mpsc.Config{
        .max_producers = 8,
        .ring_bits = 10,
    };

    var channel = try ringmpsc.mpsc.Channel(u64, DetConfig).init(std.heap.page_allocator);
    defer channel.deinit();

    var received = std.atomic.Value(usize).init(0);
    var violations = std.atomic.Value(usize).init(0);
    var last_seq: [NUM_PRODUCERS]std.atomic.Value(i64) = undefined;
    for (&last_seq) |*v| {
        v.* = std.atomic.Value(i64).init(-1);
    }

    // Spawn producers
    var producer_threads: [NUM_PRODUCERS]std.Thread = undefined;
    for (&producer_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, deterministicProducer, .{
            &channel,
            i,
        });
    }

    // Consumer
    const consumer_thread = try std.Thread.spawn(.{}, deterministicConsumer, .{
        &channel,
        &received,
        &violations,
        &last_seq,
    });

    // Wait for producers
    for (&producer_threads) |*thread| {
        thread.join();
    }

    // Drain
    std.Thread.sleep(100 * std.time.ns_per_ms);
    channel.close();
    consumer_thread.join();

    const total_received = received.load(.acquire);
    const total_violations = violations.load(.acquire);
    const expected = NUM_PRODUCERS * MESSAGES_PER_PRODUCER;

    return .{
        .received = total_received,
        .violations = total_violations,
        .passed = (total_received == expected and total_violations == 0),
    };
}

fn deterministicProducer(channel: anytype, id: usize) void {
    const producer = channel.register() catch return;
    var sent: usize = 0;
    var backoff = ringmpsc.primitives.Backoff{};

    while (sent < MESSAGES_PER_PRODUCER) {
        // Encode producer id and sequence number
        const value: u64 = (@as(u64, @intCast(id)) << 48) | @as(u64, @intCast(sent));

        if (producer.sendOne(value)) {
            sent += 1;
            backoff.reset();
        } else {
            backoff.snooze();
        }
    }
}

fn deterministicConsumer(
    channel: anytype,
    received: *std.atomic.Value(usize),
    violations: *std.atomic.Value(usize),
    last_seq: *[NUM_PRODUCERS]std.atomic.Value(i64),
) void {
    var backoff = ringmpsc.primitives.Backoff{};

    while (!channel.isClosed() or channel.pending() > 0) {
        if (channel.recvOne()) |value| {
            const producer_id: usize = @intCast(value >> 48);
            const seq: i64 = @intCast(value & 0xFFFFFFFFFFFF);

            // Check per-producer FIFO ordering
            if (producer_id < NUM_PRODUCERS) {
                const prev = last_seq[producer_id].load(.acquire);
                if (seq <= prev) {
                    // Out of order!
                    _ = violations.fetchAdd(1, .monotonic);
                }
                last_seq[producer_id].store(seq, .release);
            }

            _ = received.fetchAdd(1, .monotonic);
            backoff.reset();
        } else {
            backoff.snooze();
        }
    }
}
