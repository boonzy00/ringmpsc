// MPSC Integration Tests
// Tests for Multi-Producer Single-Consumer channel

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const Config = ringmpsc.mpsc.Config{
    .ring_bits = 10, // 1K slots for faster tests
    .max_producers = 8,
    .enable_metrics = true,
};

const Channel = ringmpsc.mpsc.Channel(u64, Config);

var passed: usize = 0;
var failed: usize = 0;

pub fn main() !void {
    std.debug.print("\nMPSC Integration Tests\n", .{});
    std.debug.print("======================\n\n", .{});

    try runTest("register producers", registerProducers);
    try runTest("multi-producer send", multiProducerSend);
    try runTest("consumeAll", consumeAll);
    try runTest("consumeAllUpTo", consumeAllUpTo);
    try runTest("consumeAllCount", consumeAllCount);
    try runTest("close all rings", closeAllRings);
    try runTest("concurrent producers", concurrentProducers);

    std.debug.print("\n", .{});
    std.debug.print("Results: {d} passed, {d} failed\n", .{ passed, failed });
    std.debug.print("\n", .{});

    if (failed > 0) std.process.exit(1);
}

fn runTest(name: []const u8, test_fn: *const fn () anyerror!void) !void {
    std.debug.print("  {s:<25} ", .{name});
    test_fn() catch |err| {
        std.debug.print("FAILED: {}\n", .{err});
        failed += 1;
        return;
    };
    std.debug.print("PASSED\n", .{});
    passed += 1;
}

fn registerProducers() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    const p1 = try channel.register();
    const p2 = try channel.register();
    const p3 = try channel.register();

    try std.testing.expectEqual(@as(usize, 0), p1.id);
    try std.testing.expectEqual(@as(usize, 1), p2.id);
    try std.testing.expectEqual(@as(usize, 2), p3.id);

    try std.testing.expectEqual(@as(usize, 3), channel.producerCount());
}

fn multiProducerSend() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    const p1 = try channel.register();
    const p2 = try channel.register();
    const p3 = try channel.register();

    // Each producer sends
    _ = p1.send(&[_]u64{ 1, 2, 3 });
    _ = p2.send(&[_]u64{ 10, 20, 30 });
    _ = p3.send(&[_]u64{ 100, 200, 300 });

    // Consumer receives from all
    var buf: [20]u64 = undefined;
    const n = channel.recv(&buf);
    try std.testing.expectEqual(@as(usize, 9), n);
}

fn consumeAll() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    const p1 = try channel.register();
    const p2 = try channel.register();

    _ = p1.send(&[_]u64{ 1, 2, 3 });
    _ = p2.send(&[_]u64{ 10, 20, 30 });

    var sum: u64 = 0;
    const Handler = struct {
        sum: *u64,
        pub fn process(self: @This(), item: *const u64) void {
            self.sum.* += item.*;
        }
    };
    const consumed = channel.consumeAll(Handler{ .sum = &sum });

    try std.testing.expectEqual(@as(usize, 6), consumed);
    try std.testing.expectEqual(@as(u64, 66), sum); // 1+2+3+10+20+30
}

fn consumeAllUpTo() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    const p1 = try channel.register();
    const p2 = try channel.register();

    _ = p1.send(&[_]u64{ 1, 2, 3, 4, 5 });
    _ = p2.send(&[_]u64{ 10, 20, 30, 40, 50 });

    var sum: u64 = 0;
    const Handler = struct {
        sum: *u64,
        pub fn process(self: @This(), item: *const u64) void {
            self.sum.* += item.*;
        }
    };

    // Consume up to 7 items
    const consumed = channel.consumeAllUpTo(7, Handler{ .sum = &sum });
    try std.testing.expectEqual(@as(usize, 7), consumed);

    // Remaining should be 3
    const remaining = channel.consumeAll(Handler{ .sum = &sum });
    try std.testing.expectEqual(@as(usize, 3), remaining);
}

fn consumeAllCount() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    const p1 = try channel.register();
    const p2 = try channel.register();

    _ = p1.send(&[_]u64{ 1, 2, 3, 4, 5 });
    _ = p2.send(&[_]u64{ 10, 20, 30 });

    // Count without processing
    const count = channel.consumeAllCount();
    try std.testing.expectEqual(@as(usize, 8), count);
}

fn closeAllRings() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    const p1 = try channel.register();
    _ = try channel.register();

    _ = p1.send(&[_]u64{ 1, 2, 3 });

    channel.close();
    try std.testing.expect(channel.isClosed());

    // Can't register new producers
    try std.testing.expectError(error.Closed, channel.register());

    // Can still consume
    var buf: [10]u64 = undefined;
    const n = channel.recv(&buf);
    try std.testing.expectEqual(@as(usize, 3), n);
}

fn concurrentProducers() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    const p1 = try channel.register();
    const p2 = try channel.register();
    const p3 = try channel.register();

    var total_consumed: std.atomic.Value(u64) = .init(0);
    var done: std.atomic.Value(bool) = .init(false);

    const MSG_PER_PRODUCER: u64 = 10000;

    // Start consumer
    const consumer = try std.Thread.spawn(.{}, consumerFn, .{
        &channel,
        &total_consumed,
        &done,
    });

    // Start producers
    var threads: [3]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, producerFn, .{ p1, MSG_PER_PRODUCER });
    threads[1] = try std.Thread.spawn(.{}, producerFn, .{ p2, MSG_PER_PRODUCER });
    threads[2] = try std.Thread.spawn(.{}, producerFn, .{ p3, MSG_PER_PRODUCER });

    // Wait for producers
    for (threads) |t| t.join();

    done.store(true, .release);
    consumer.join();

    const expected = MSG_PER_PRODUCER * 3;
    const actual = total_consumed.load(.acquire);
    try std.testing.expectEqual(expected, actual);
}

fn producerFn(producer: Channel.Producer, count: u64) void {
    var sent: u64 = 0;
    var bo = ringmpsc.primitives.Backoff{};

    while (sent < count) {
        if (producer.sendOne(sent)) {
            sent += 1;
            bo.reset();
        } else {
            bo.snooze();
        }
    }
}

fn consumerFn(
    channel: *Channel,
    total: *std.atomic.Value(u64),
    done: *std.atomic.Value(bool),
) void {
    var count: u64 = 0;
    while (true) {
        const consumed = channel.consumeAllCount();
        if (consumed > 0) {
            count += consumed;
        } else if (done.load(.acquire)) {
            // Drain remaining
            while (true) {
                const final = channel.consumeAllCount();
                if (final == 0) break;
                count += final;
            }
            break;
        }
    }
    total.store(count, .release);
}
