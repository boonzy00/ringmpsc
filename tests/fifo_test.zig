// FIFO Ordering Tests
// Verifies per-producer FIFO ordering is maintained

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const MSG_PER_PRODUCER: u64 = 1_000_000;
const NUM_PRODUCERS: usize = 8;

const Config = ringmpsc.mpsc.Config{
    .ring_bits = 16,
    .max_producers = NUM_PRODUCERS,
};

const Channel = ringmpsc.mpsc.Channel(u64, Config);

pub fn main() !void {
    std.debug.print("\nFIFO Ordering Tests\n", .{});
    std.debug.print("====================\n\n", .{});
    std.debug.print("Testing {} producers × {} messages\n\n", .{ NUM_PRODUCERS, MSG_PER_PRODUCER });

    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();
    var producers: [NUM_PRODUCERS]Channel.Producer = undefined;

    for (0..NUM_PRODUCERS) |i| {
        producers[i] = try channel.register();
    }

    var consumer_data: std.ArrayListUnmanaged(u64) = .empty;
    defer consumer_data.deinit(std.heap.page_allocator);

    var done: std.atomic.Value(bool) = .init(false);

    const consumer = try std.Thread.spawn(.{}, consumerFn, .{
        &channel,
        &consumer_data,
        &done,
    });

    // Start producers
    var threads: [NUM_PRODUCERS]std.Thread = undefined;
    for (0..NUM_PRODUCERS) |i| {
        threads[i] = try std.Thread.spawn(.{}, producerFn, .{ producers[i], i, MSG_PER_PRODUCER });
    }

    // Wait for producers
    for (threads) |t| t.join();

    done.store(true, .release);
    consumer.join();

    // Verify FIFO order per producer
    std.debug.print("Verifying FIFO order...\n", .{});

    var producer_seqs: [NUM_PRODUCERS]u64 = [_]u64{0} ** NUM_PRODUCERS;
    var violations: usize = 0;

    for (consumer_data.items) |msg| {
        const producer_id = msg >> 32;
        const seq = msg & 0xFFFFFFFF;

        if (producer_id < NUM_PRODUCERS) {
            if (seq != producer_seqs[producer_id]) {
                violations += 1;
                if (violations <= 10) {
                    std.debug.print("  Violation: P{} expected {} got {}\n", .{
                        producer_id,
                        producer_seqs[producer_id],
                        seq,
                    });
                }
            }
            producer_seqs[producer_id] = seq + 1;
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("Total messages: {d}\n", .{consumer_data.items.len});
    std.debug.print("FIFO violations: {d}\n", .{violations});

    if (violations == 0) {
        std.debug.print("\n✓ PASSED - All producers maintained FIFO order\n", .{});
    } else {
        std.debug.print("\n✗ FAILED - FIFO violations detected\n", .{});
        std.process.exit(1);
    }
}

fn producerFn(producer: Channel.Producer, id: usize, count: u64) void {
    var sent: u64 = 0;
    var bo = ringmpsc.primitives.Backoff{};

    while (sent < count) {
        const msg = (@as(u64, @intCast(id)) << 32) | sent;
        if (producer.sendOne(msg)) {
            sent += 1;
            bo.reset();
        } else {
            bo.snooze();
        }
    }
}

fn consumerFn(
    channel: *Channel,
    data: *std.ArrayListUnmanaged(u64),
    done: *std.atomic.Value(bool),
) void {
    const Handler = struct {
        data: *std.ArrayListUnmanaged(u64),
        pub fn process(self: @This(), item: *const u64) void {
            self.data.append(std.heap.page_allocator, item.*) catch {};
        }
    };

    while (true) {
        const n = channel.consumeAll(Handler{ .data = data });
        if (n == 0 and done.load(.acquire)) {
            // Drain remaining
            while (channel.consumeAll(Handler{ .data = data }) > 0) {}
            break;
        }
    }
}
