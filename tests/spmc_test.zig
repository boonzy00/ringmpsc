//! ringmpsc — SPMC Integration Test
//!
//! Validates single-producer multi-consumer correctness:
//! - All messages are consumed exactly once (no loss, no duplication)
//! - Works under contention with multiple consumers

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const NUM_CONSUMERS = 4;
const MESSAGES = 2_000_000;

const TestConfig = ringmpsc.spmc.SpmcConfig{
    .ring_bits = 14,
    .max_consumers = 8,
};
const ChannelType = ringmpsc.spmc.Channel(u64, TestConfig);

pub fn main() !void {
    std.debug.print("ringmpsc SPMC Test\n", .{});
    std.debug.print("===============\n", .{});
    std.debug.print("  {} messages, {} consumers\n\n", .{ MESSAGES, NUM_CONSUMERS });

    var channel = ChannelType{};
    defer channel.close();

    var total_consumed = std.atomic.Value(u64).init(0);
    var checksum = std.atomic.Value(u64).init(0);

    // Start consumers
    var consumer_threads: [NUM_CONSUMERS]std.Thread = undefined;
    for (0..NUM_CONSUMERS) |i| {
        var consumer = try channel.registerConsumer();
        consumer_threads[i] = try std.Thread.spawn(.{}, consumerFn, .{
            &consumer,
            &channel,
            &total_consumed,
            &checksum,
        });
    }

    // Producer: send all messages
    var expected_checksum: u64 = 0;
    var sent: u64 = 0;
    while (sent < MESSAGES) {
        if (channel.sendOne(sent)) {
            expected_checksum +%= sent;
            sent += 1;
        } else {
            std.atomic.spinLoopHint();
        }
    }

    // Close and wait for drain
    std.debug.print("  Producer done ({} sent). Waiting for consumers...\n", .{sent});
    channel.close();

    for (&consumer_threads) |*t| t.join();

    // Validate
    const actual_consumed = total_consumed.load(.acquire);
    const actual_checksum = checksum.load(.acquire);

    std.debug.print("  Consumed: {} / {} expected\n", .{ actual_consumed, MESSAGES });
    std.debug.print("  Checksum: {} / {} expected\n", .{ actual_checksum, expected_checksum });

    if (actual_consumed != MESSAGES) {
        std.debug.print("  FAIL: message count mismatch\n", .{});
        std.process.exit(1);
    }

    if (actual_checksum != expected_checksum) {
        std.debug.print("  FAIL: checksum mismatch (duplicate or corruption)\n", .{});
        std.process.exit(1);
    }

    std.debug.print("  PASS\n", .{});
}

fn consumerFn(
    consumer: *ChannelType.Consumer,
    channel: *const ChannelType,
    total_consumed: *std.atomic.Value(u64),
    checksum: *std.atomic.Value(u64),
) void {
    var count: u64 = 0;
    var local_checksum: u64 = 0;
    var buf: [256]u64 = undefined;
    var backoff = ringmpsc.primitives.Backoff{};

    while (true) {
        const n = consumer.steal(&buf);
        if (n > 0) {
            for (buf[0..n]) |val| {
                local_checksum +%= val;
            }
            count += n;
            backoff.reset();
        } else {
            if (channel.isClosed()) {
                // One more drain attempt
                const final = consumer.steal(&buf);
                for (buf[0..final]) |val| {
                    local_checksum +%= val;
                }
                count += final;
                break;
            }
            backoff.snooze();
        }
    }

    _ = total_consumed.fetchAdd(count, .release);
    _ = checksum.fetchAdd(local_checksum, .release);
}
