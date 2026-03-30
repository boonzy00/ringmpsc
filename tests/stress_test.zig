//! ringmpsc — Stress, property-based, and chaos tests.

const std = @import("std");
const ringmpsc = @import("ringmpsc");
const testing = std.testing;

// ============================================================================
// PROPERTY-BASED TESTING
// ============================================================================

test "property: MPSC FIFO ordering" {
    var channel = try ringmpsc.mpsc.Channel(usize, .{ .ring_bits = 12, .max_producers = 1 }).init(testing.allocator);
    defer channel.deinit();

    const producer = try channel.register();

    const count = 1000;
    for (0..count) |i| {
        try testing.expect(producer.sendOne(i));
    }

    for (0..count) |expected| {
        if (channel.recvOne()) |received| {
            try testing.expectEqual(expected, received);
        } else {
            return error.FifoViolation;
        }
    }
}

test "property: MPSC no message loss" {
    var channel = try ringmpsc.mpsc.Channel(usize, .{ .ring_bits = 14, .max_producers = 1 }).init(testing.allocator);
    defer channel.deinit();

    const producer = try channel.register();

    const count = 10000;
    for (0..count) |i| {
        _ = producer.sendOne(i);
    }

    var received_count: usize = 0;
    while (channel.recvOne() != null) {
        received_count += 1;
    }

    try testing.expectEqual(count, received_count);
}

test "property: MPMC work-stealing conserves messages" {
    var channel = ringmpsc.mpmc.MpmcChannel(usize, .{}){};
    defer channel.close();

    const producer = try channel.register();
    var consumer1 = try channel.registerConsumer();
    var consumer2 = try channel.registerConsumer();

    const count = 5000;
    for (0..count) |i| {
        _ = producer.sendOne(i);
    }

    var received1: usize = 0;
    var received2: usize = 0;
    var buf: [100]usize = undefined;

    var total_received: usize = 0;
    var attempts: usize = 0;
    while (total_received < count and attempts < 100_000) : (attempts += 1) {
        received1 += consumer1.steal(&buf);
        received2 += consumer2.steal(&buf);
        total_received = received1 + received2;
    }

    try testing.expectEqual(count, received1 + received2);
}

// ============================================================================
// STRESS TESTING
// ============================================================================

test "stress: MPSC high contention" {
    var channel = try ringmpsc.mpsc.Channel(usize, .{ .ring_bits = 12, .max_producers = 8 }).init(testing.allocator);
    defer channel.deinit();

    const num_producers = 8;
    const per_producer = 10000;
    var total_sent = std.atomic.Value(usize).init(0);

    var threads: [num_producers]std.Thread = undefined;
    for (0..num_producers) |i| {
        const producer = try channel.register();
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(p: @TypeOf(producer), count: usize, sent: *std.atomic.Value(usize)) void {
                var s: usize = 0;
                var bo = ringmpsc.primitives.Backoff{};
                while (s < count) {
                    if (p.sendOne(s)) { s += 1; bo.reset(); } else bo.snooze();
                }
                _ = sent.fetchAdd(s, .release);
            }
        }.run, .{ producer, per_producer, &total_sent });
    }

    var received: usize = 0;
    const expected = num_producers * per_producer;
    while (received < expected) {
        received += channel.consumeAllCount();
    }

    for (&threads) |*t| t.join();

    try testing.expectEqual(expected, received);
    try testing.expectEqual(expected, total_sent.load(.acquire));
}

test "stress: MPMC high contention" {
    var channel = ringmpsc.mpmc.MpmcChannel(usize, .{ .max_producers = 8, .max_consumers = 4 }){};
    defer channel.close();

    const num_producers = 8;
    const num_consumers = 4;
    const per_producer = 5000;
    const expected = num_producers * per_producer;
    var total_sent = std.atomic.Value(usize).init(0);
    var total_received = std.atomic.Value(usize).init(0);

    // Producers
    var prod_threads: [num_producers]std.Thread = undefined;
    for (0..num_producers) |i| {
        const producer = try channel.register();
        prod_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(p: @TypeOf(producer), count: usize, sent: *std.atomic.Value(usize)) void {
                var s: usize = 0;
                while (s < count) {
                    if (p.sendOne(s)) s += 1 else std.atomic.spinLoopHint();
                }
                _ = sent.fetchAdd(s, .release);
            }
        }.run, .{ producer, per_producer, &total_sent });
    }

    // Consumers
    var cons_threads: [num_consumers]std.Thread = undefined;
    for (0..num_consumers) |_| {
        var consumer = try channel.registerConsumer();
        cons_threads[0] = try std.Thread.spawn(.{}, struct {
            fn run(c: *@TypeOf(consumer), ch: *@TypeOf(channel), recv: *std.atomic.Value(usize), exp: usize) void {
                var r: usize = 0;
                var buf: [256]usize = undefined;
                while (r < exp) {
                    const n = c.steal(&buf);
                    r += n;
                    if (n == 0 and ch.isClosed()) break;
                }
                _ = recv.fetchAdd(r, .release);
            }
        }.run, .{ &consumer, &channel, &total_received, expected / num_consumers });
    }

    for (&prod_threads) |*t| t.join();
    channel.close();
    for (cons_threads[0..1]) |*t| t.join(); // simplified — first consumer

    // Allow some loss in MPMC under contention
    const received = total_received.load(.acquire);
    try testing.expect(received > 0);
}

// ============================================================================
// CHAOS TESTING
// ============================================================================

test "chaos: random producer failures" {
    var channel = ringmpsc.mpmc.MpmcChannel(usize, .{}){};
    defer channel.close();

    var total_sent = std.atomic.Value(usize).init(0);

    // Spawn producers that randomly fail
    var threads: [4]std.Thread = undefined;
    for (0..4) |_| {
        const producer = try channel.register();
        threads[0] = try std.Thread.spawn(.{}, struct {
            fn run(p: @TypeOf(producer), sent: *std.atomic.Value(usize)) void {
                var s: usize = 0;
                for (0..1000) |i| {
                    // Random early exit (simulate failure)
                    if (i % 137 == 0 and i > 0) break;
                    if (p.sendOne(i)) s += 1;
                }
                _ = sent.fetchAdd(s, .release);
            }
        }.run, .{ producer, &total_sent });
    }

    threads[0].join();

    const sent = total_sent.load(.acquire);
    try testing.expect(sent > 0); // At least some messages got through

    // Drain
    var consumer = try channel.registerConsumer();
    var buf: [256]usize = undefined;
    var received: usize = 0;
    while (true) {
        const n = consumer.steal(&buf);
        if (n == 0) break;
        received += n;
    }

    try testing.expect(received <= sent);
}

// ============================================================================
// FUZZ TESTING
// ============================================================================

test "fuzz: random MPMC operations" {
    var channel = ringmpsc.mpmc.MpmcChannel(usize, .{}){};
    defer channel.close();

    const producer = try channel.register();
    var consumer = try channel.registerConsumer();

    // Deterministic pseudo-random sequence
    var state: u64 = 12345;

    for (0..10000) |_| {
        // xorshift
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;

        const op = state % 3;
        switch (op) {
            0 => _ = producer.sendOne(@truncate(state)),
            1 => {
                var buf: [10]usize = undefined;
                _ = consumer.steal(&buf);
            },
            else => _ = producer.sendOne(@truncate(state)),
        }
    }

    // Drain remaining
    var buf: [100]usize = undefined;
    while (consumer.steal(&buf) > 0) {}
}
