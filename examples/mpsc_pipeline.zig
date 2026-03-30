//! MPSC pipeline — multiple producers, single consumer with handler.

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const Config = ringmpsc.mpsc.Config{
    .ring_bits = 12,
    .max_producers = 4,
};
const Channel = ringmpsc.mpsc.Channel(u64, Config);

pub fn main() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    const NUM_PRODUCERS = 4;
    const MSG_PER_PRODUCER = 100_000;

    // Spawn producers
    var threads: [NUM_PRODUCERS]std.Thread = undefined;
    for (0..NUM_PRODUCERS) |i| {
        const producer = try channel.register();
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(p: Channel.Producer, id: usize) void {
                var bo = ringmpsc.primitives.Backoff{};
                for (0..MSG_PER_PRODUCER) |seq| {
                    const msg = @as(u64, @intCast(id)) * MSG_PER_PRODUCER + seq;
                    while (!p.sendOne(msg)) bo.snooze();
                    bo.reset();
                }
            }
        }.run, .{ producer, i });
    }

    // Consumer: sum all messages
    var total: u64 = 0;
    var count: u64 = 0;
    const expected = NUM_PRODUCERS * MSG_PER_PRODUCER;

    const Handler = struct {
        total: *u64,
        count: *u64,
        pub fn process(self: @This(), item: *const u64) void {
            self.total.* += item.*;
            self.count.* += 1;
        }
    };

    while (count < expected) {
        _ = channel.consumeAll(Handler{ .total = &total, .count = &count });
    }

    // Wait for producers
    for (&threads) |*t| t.join();

    std.debug.print("Received {d} messages, sum = {d}\n", .{ count, total });
}
