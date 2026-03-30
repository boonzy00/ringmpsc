//! Wait Strategies, Blocking API, and Graceful Shutdown Tests

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const Config = ringmpsc.mpsc.Config{
    .ring_bits = 10, // 1K slots — small ring to trigger backpressure easily
    .max_producers = 4,
    .enable_metrics = false,
};
const Channel = ringmpsc.mpsc.Channel(u64, Config);
const Ring = ringmpsc.primitives.Ring(u64, Config);
const WaitStrategy = ringmpsc.primitives.WaitStrategy;

var passed: usize = 0;
var failed: usize = 0;

pub fn main() !void {
    std.debug.print("\nBlocking API + Graceful Shutdown Tests\n", .{});
    std.debug.print("======================================\n\n", .{});

    try runTest("blocking reserve (ring full)", blockingReserveFull);
    try runTest("blocking consume (ring empty)", blockingConsumeEmpty);
    try runTest("timed blocking timeout", timedBlockingTimeout);
    try runTest("sendOneBlocking", sendOneBlocking);
    try runTest("graceful shutdown drains all", gracefulShutdownDrain);
    try runTest("isFullyDrained", isFullyDrained);
    try runTest("blocking producer + consumer", blockingProducerConsumer);

    std.debug.print("\n", .{});
    std.debug.print("Results: {d} passed, {d} failed\n", .{ passed, failed });
    std.debug.print("\n", .{});
    if (failed > 0) std.process.exit(1);
}

fn runTest(name: []const u8, test_fn: *const fn () anyerror!void) !void {
    std.debug.print("  {s:<40} ", .{name});
    test_fn() catch |err| {
        std.debug.print("FAILED: {}\n", .{err});
        failed += 1;
        return;
    };
    std.debug.print("PASSED\n", .{});
    passed += 1;
}

// ============================================================================
// TESTS
// ============================================================================

fn blockingReserveFull() !void {
    // Fill a ring, then reserveBlocking from another thread.
    // A consumer thread frees space after a short delay.
    var ring = Ring{};

    // Fill it up
    for (0..1024) |i| {
        _ = ring.send(&[_]u64{@intCast(i)});
    }
    try std.testing.expect(ring.isFull());

    // Consumer thread: wait, then drain
    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *Ring) void {
            std.Thread.sleep(5_000_000); // 5ms
            _ = r.consumeBatchCount();
        }
    }.run, .{&ring});

    // Producer: blocking reserve should succeed after consumer drains
    const reservation = try ring.reserveBlocking(1, .{ .timed_blocking = .{ .timeout_ns = 100_000_000 } }); // 100ms timeout
    reservation.slice[0] = 42;
    ring.commit(1);

    consumer.join();
}

fn blockingConsumeEmpty() !void {
    // Empty ring, consumeBatchBlocking from one thread.
    // Producer sends after a delay.
    var ring = Ring{};
    try std.testing.expect(ring.isEmpty());

    // Producer thread: wait, then send
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(r: *Ring) void {
            std.Thread.sleep(5_000_000); // 5ms
            _ = r.send(&[_]u64{ 1, 2, 3 });
        }
    }.run, .{&ring});

    // Consumer: blocking consume should succeed after producer sends
    var sum: u64 = 0;
    const Handler = struct {
        sum: *u64,
        pub fn process(self: @This(), item: *const u64) void {
            self.sum.* += item.*;
        }
    };
    const n = try ring.consumeBatchBlocking(Handler{ .sum = &sum }, .{ .timed_blocking = .{ .timeout_ns = 100_000_000 } });
    try std.testing.expect(n >= 1);
    try std.testing.expect(sum > 0);

    producer.join();
}

fn timedBlockingTimeout() !void {
    // Empty ring, timed blocking consume should timeout.
    var ring = Ring{};

    const result = ring.consumeBatchBlocking(
        struct {
            pub fn process(_: @This(), _: *const u64) void {}
        }{},
        .{ .timed_blocking = .{ .timeout_ns = 1_000_000 } }, // 1ms timeout
    );

    try std.testing.expectError(error.TimedOut, result);
}

fn sendOneBlocking() !void {
    var ring = Ring{};

    // Should succeed immediately on empty ring
    try ring.sendOneBlocking(42, .busy_spin);
    try ring.sendOneBlocking(43, .yielding);

    // Verify
    var buf: [2]u64 = undefined;
    const n = ring.recv(&buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 42), buf[0]);
    try std.testing.expectEqual(@as(u64, 43), buf[1]);
}

fn gracefulShutdownDrain() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    const p1 = try channel.register();
    const p2 = try channel.register();

    // Send data
    _ = p1.send(&[_]u64{ 1, 2, 3 });
    _ = p2.send(&[_]u64{ 10, 20, 30 });

    // Shutdown
    channel.shutdown();
    try std.testing.expect(channel.isClosed());

    // Drain
    var sum: u64 = 0;
    const Handler = struct {
        sum: *u64,
        pub fn process(self: @This(), item: *const u64) void {
            self.sum.* += item.*;
        }
    };
    const drained = channel.drainAll(Handler{ .sum = &sum });
    try std.testing.expectEqual(@as(usize, 6), drained);
    try std.testing.expectEqual(@as(u64, 66), sum); // 1+2+3+10+20+30
}

fn isFullyDrained() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    const p = try channel.register();
    _ = p.send(&[_]u64{ 1, 2, 3 });

    // Not drained yet
    try std.testing.expect(!channel.isFullyDrained());

    channel.shutdown();
    // Closed but not empty
    try std.testing.expect(!channel.isFullyDrained());

    // Drain
    _ = channel.drainAllCount();
    try std.testing.expect(channel.isFullyDrained());
}

fn blockingProducerConsumer() !void {
    // Full end-to-end: producer sends 10K messages via sendOneBlocking,
    // consumer receives via consumeBatchBlocking, graceful shutdown.
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    const MSG_COUNT: u64 = 10_000;
    var consumer_total = std.atomic.Value(u64).init(0);

    const p = try channel.register();
    const ring = p.ring;

    // Consumer thread
    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *Ring, total: *std.atomic.Value(u64)) void {
            var count: u64 = 0;
            const Handler = struct {
                count: *u64,
                pub fn process(self: @This(), _: *const u64) void {
                    self.count.* += 1;
                }
            };

            while (true) {
                const n = r.consumeBatchBlocking(Handler{ .count = &count }, .{ .timed_blocking = .{ .timeout_ns = 50_000_000 } }) catch |err| switch (err) {
                    error.TimedOut => continue,
                    error.Closed => break,
                };
                _ = n;
            }
            // Final drain
            while (true) {
                const n = r.consumeBatch(Handler{ .count = &count });
                if (n == 0) break;
            }
            total.store(count, .release);
        }
    }.run, .{ ring, &consumer_total });

    // Producer: send all messages
    var sent: u64 = 0;
    while (sent < MSG_COUNT) {
        ring.sendOneBlocking(sent, .{ .sleeping = .{ .sleep_ns = 100 } }) catch break;
        sent += 1;
    }

    // Shutdown
    channel.shutdown();
    consumer.join();

    const received = consumer_total.load(.acquire);
    try std.testing.expectEqual(MSG_COUNT, received);
}
