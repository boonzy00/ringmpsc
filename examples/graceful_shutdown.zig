//! Graceful shutdown — zero message loss during coordinated close.

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const Channel = ringmpsc.mpsc.Channel(u64, .{ .ring_bits = 12, .max_producers = 2 });

pub fn main() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    var consumer_count = std.atomic.Value(u64).init(0);

    // Spawn consumer
    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(ch: *Channel, count: *std.atomic.Value(u64)) void {
            var c: u64 = 0;
            while (true) {
                const n = ch.consumeAllCount();
                c += n;
                if (n == 0 and ch.isClosed()) {
                    // Drain remaining
                    c += ch.drainAllCount();
                    break;
                }
            }
            count.store(c, .release);
        }
    }.run, .{ &channel, &consumer_count });

    // Spawn producers
    const p1 = try channel.register();
    const p2 = try channel.register();

    const t1 = try std.Thread.spawn(.{}, struct {
        fn run(p: Channel.Producer) void {
            var bo = ringmpsc.primitives.Backoff{};
            for (0..50_000) |i| {
                while (!p.sendOne(@intCast(i))) bo.snooze();
                bo.reset();
            }
        }
    }.run, .{p1});

    const t2 = try std.Thread.spawn(.{}, struct {
        fn run(p: Channel.Producer) void {
            var bo = ringmpsc.primitives.Backoff{};
            for (0..50_000) |i| {
                while (!p.sendOne(@intCast(i))) bo.snooze();
                bo.reset();
            }
        }
    }.run, .{p2});

    // Wait for producers to finish
    t1.join();
    t2.join();
    std.debug.print("Producers done (100,000 messages sent)\n", .{});

    // Graceful shutdown
    channel.shutdown();
    consumer.join();

    const received = consumer_count.load(.acquire);
    std.debug.print("Consumer received: {d}\n", .{received});
    std.debug.print("Fully drained: {}\n", .{channel.isFullyDrained()});
    std.debug.print("Status: {s}\n", .{if (received == 100_000) "PASS" else "FAIL — messages lost!"});
}
