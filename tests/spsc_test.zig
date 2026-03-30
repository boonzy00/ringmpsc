//! ringmpsc - FIFO Order Test
//!
//! Validates that per-producer FIFO ordering is maintained.

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const NUM_PRODUCERS = 4;
const MESSAGES_PER_PRODUCER = 10_000;

const FifoConfig = ringmpsc.mpsc.Config{
    .max_producers = 8,
    .ring_bits = 12,
};

pub fn main() !void {
    std.debug.print("ringmpsc FIFO Order Test\n", .{});
    std.debug.print("=====================\n\n", .{});

    var channel = try ringmpsc.mpsc.Channel(u64, FifoConfig).init(std.heap.page_allocator);
    defer channel.deinit();

    // Track last seen sequence per producer
    var last_seen: [NUM_PRODUCERS]i64 = [_]i64{-1} ** NUM_PRODUCERS;
    var violations: usize = 0;
    var total_received: usize = 0;

    // Spawn producers
    var producer_threads: [NUM_PRODUCERS]std.Thread = undefined;
    for (&producer_threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, producerFn, .{ &channel, i });
    }

    // Consumer: validate FIFO per producer
    var backoff = ringmpsc.primitives.Backoff{};

    while (total_received < NUM_PRODUCERS * MESSAGES_PER_PRODUCER) {
        if (channel.recvOne()) |value| {
            const producer_id: usize = @intCast(value / MESSAGES_PER_PRODUCER);
            const seq: i64 = @intCast(value % MESSAGES_PER_PRODUCER);

            if (producer_id < NUM_PRODUCERS) {
                if (seq <= last_seen[producer_id]) {
                    violations += 1;
                    std.debug.print("FIFO violation: producer {} seq {} <= last {}\n", .{
                        producer_id,
                        seq,
                        last_seen[producer_id],
                    });
                }
                last_seen[producer_id] = seq;
            }

            total_received += 1;
            backoff.reset();
        } else {
            backoff.snooze();
        }
    }

    // Wait for producers
    for (&producer_threads) |*thread| {
        thread.join();
    }

    std.debug.print("Results:\n", .{});
    std.debug.print("  Received:   {}\n", .{total_received});
    std.debug.print("  Violations: {}\n", .{violations});
    std.debug.print("  Status:     {s}\n", .{if (violations == 0) "PASS ✓" else "FAIL ✗"});

    if (violations > 0) {
        std.process.exit(1);
    }
}

fn producerFn(channel: anytype, id: usize) void {
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
}
