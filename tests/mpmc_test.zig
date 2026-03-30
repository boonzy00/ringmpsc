//! ringmpsc - MPMC Test
//!
//! Tests multi-producer multi-consumer functionality with work-stealing.

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const NUM_PRODUCERS = 6;
const NUM_CONSUMERS = 3;
const MESSAGES_PER_PRODUCER = 20_000;

const TestMpmcConfig = ringmpsc.mpmc.MpmcConfig{
    .max_producers = 16,
    .max_consumers = 8,
    .ring_bits = 12,
};

pub fn main() !void {
    std.debug.print("ringmpsc MPMC Test\n", .{});
    std.debug.print("===============\n\n", .{});
    std.debug.print("Config: {} producers, {} consumers, {} msgs/producer\n\n", .{
        NUM_PRODUCERS,
        NUM_CONSUMERS,
        MESSAGES_PER_PRODUCER,
    });

    var channel = ringmpsc.mpmc.MpmcChannel(u64, TestMpmcConfig){};
    defer channel.close();

    var total_sent = std.atomic.Value(usize).init(0);
    var total_received = std.atomic.Value(usize).init(0);

    // Bitmap to track received values (for uniqueness check)
    const TOTAL_MESSAGES = NUM_PRODUCERS * MESSAGES_PER_PRODUCER;
    const received_bitmap = try std.heap.page_allocator.alloc(std.atomic.Value(u8), (TOTAL_MESSAGES + 7) / 8);
    defer std.heap.page_allocator.free(received_bitmap);
    for (received_bitmap) |*byte| {
        byte.* = std.atomic.Value(u8).init(0);
    }

    // Spawn consumers
    var consumer_threads: [NUM_CONSUMERS]std.Thread = undefined;
    for (&consumer_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, consumerFn, .{
            &channel,
            &total_received,
            received_bitmap,
            i,
        });
    }

    // Spawn producers
    var producer_threads: [NUM_PRODUCERS]std.Thread = undefined;
    for (&producer_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, producerFn, .{
            &channel,
            &total_sent,
            i,
        });
    }

    // Wait for producers
    for (&producer_threads) |*thread| {
        thread.join();
    }

    std.debug.print("All producers done\n", .{});

    // Wait for drain
    while (channel.totalPending() > 0) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    channel.close();

    // Wait for consumers
    for (&consumer_threads) |*thread| {
        thread.join();
    }

    // Verify results
    const sent = total_sent.load(.acquire);
    const received = total_received.load(.acquire);

    // Count unique messages
    var unique_count: usize = 0;
    for (received_bitmap) |byte| {
        unique_count += @popCount(byte.load(.acquire));
    }

    const count_match = sent == received;
    const all_unique = unique_count == received;
    const passed = count_match and all_unique;

    std.debug.print("\n===============\n", .{});
    std.debug.print("Results:\n", .{});
    std.debug.print("  Sent:     {}\n", .{sent});
    std.debug.print("  Received: {}\n", .{received});
    std.debug.print("  Unique:   {}\n", .{unique_count});
    std.debug.print("  Status:   {s}\n", .{if (passed) "PASS ✓" else "FAIL ✗"});

    if (!passed) {
        std.process.exit(1);
    }
}

fn producerFn(channel: anytype, total_sent: *std.atomic.Value(usize), id: usize) void {
    const producer = channel.register() catch |err| {
        std.debug.print("Producer {} failed: {}\n", .{ id, err });
        return;
    };

    var sent: usize = 0;
    var backoff = ringmpsc.primitives.Backoff{};

    while (sent < MESSAGES_PER_PRODUCER) {
        const value: u64 = @intCast(id * MESSAGES_PER_PRODUCER + sent);
        if (producer.sendOne(value)) {
            sent += 1;
            backoff.reset();
        } else {
            backoff.snooze();
        }
    }

    _ = total_sent.fetchAdd(sent, .release);
    std.debug.print("Producer {} sent {} messages\n", .{ id, sent });
}

fn consumerFn(
    channel: anytype,
    total_received: *std.atomic.Value(usize),
    received_bitmap: []std.atomic.Value(u8),
    id: usize,
) void {
    var consumer = channel.registerConsumer() catch |err| {
        std.debug.print("Consumer {} failed: {}\n", .{ id, err });
        return;
    };

    var received: usize = 0;
    var buf: [256]u64 = undefined;

    while (!channel.isClosed() or channel.totalPending() > 0) {
        const n = consumer.steal(&buf);
        if (n > 0) {
            for (buf[0..n]) |value| {
                // Mark in bitmap
                const idx = value;
                if (idx < received_bitmap.len * 8) {
                    const byte_idx = idx / 8;
                    const bit_idx: u3 = @intCast(idx % 8);
                    _ = received_bitmap[byte_idx].fetchOr(@as(u8, 1) << bit_idx, .monotonic);
                }
            }
            received += n;
            consumer.consumer_backoff.reset();
        } else {
            consumer.consumer_backoff.snooze();
        }
    }

    _ = total_received.fetchAdd(received, .release);
    std.debug.print("Consumer {} received {} messages\n", .{ id, received });
}
