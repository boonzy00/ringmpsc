// SPSC Latency Benchmark
// Measures single-producer single-consumer latency and throughput

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const MSG_COUNT: u64 = 100_000_000;
const BATCH_SIZE: usize = 1024;

const Config = ringmpsc.spsc.Config{
    .ring_bits = 16,
    .enable_metrics = false,
};

const Channel = ringmpsc.spsc.Channel(u64, Config);

pub fn main() !void {
    std.debug.print("\nSPSC Latency Benchmark\n", .{});
    std.debug.print("======================\n\n", .{});

    // Warmup
    _ = try runTest(10_000_000);

    // Benchmark
    const result = try runTest(MSG_COUNT);

    std.debug.print("Messages:     {d}M\n", .{MSG_COUNT / 1_000_000});
    std.debug.print("Total time:   {d:.2}s\n", .{@as(f64, @floatFromInt(result.elapsed_ns)) / 1e9});
    std.debug.print("Throughput:   {d:.2} B/s\n", .{result.throughput_bps});
    std.debug.print("Latency/msg:  {d:.1}ns\n", .{result.latency_ns});
    std.debug.print("\n", .{});
}

const Result = struct {
    throughput_bps: f64,
    latency_ns: f64,
    elapsed_ns: u64,
};

fn runTest(msg_count: u64) !Result {
    var channel = Channel{};

    var done = std.atomic.Value(bool).init(false);
    var consumer_count: std.atomic.Value(u64) = .init(0);

    const consumer = try std.Thread.spawn(.{}, consumerFn, .{
        &channel,
        msg_count,
        &consumer_count,
        &done,
    });

    const t0 = std.time.Instant.now() catch unreachable;

    // Producer sends all messages
    var buf: [BATCH_SIZE]u64 = undefined;
    var sent: u64 = 0;

    while (sent < msg_count) {
        const batch = @min(BATCH_SIZE, msg_count - sent);
        for (0..batch) |i| {
            buf[i] = sent + i;
        }

        while (channel.send(buf[0..batch]) != batch) {
            std.atomic.spinLoopHint();
        }
        sent += batch;
    }

    done.store(true, .release);
    consumer.join();

    const t1 = std.time.Instant.now() catch unreachable;
    const elapsed = t1.since(t0);
    const total = consumer_count.load(.acquire);

    const throughput = @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) / 1e9;
    const latency = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(total));

    return .{
        .throughput_bps = throughput,
        .latency_ns = latency,
        .elapsed_ns = elapsed,
    };
}

fn consumerFn(
    channel: *Channel,
    expected: u64,
    count: *std.atomic.Value(u64),
    done: *std.atomic.Value(bool),
) void {
    const Handler = struct {
        count: *std.atomic.Value(u64),

        pub fn process(self: @This(), _: *const u64) void {
            _ = self.count.fetchAdd(1, .monotonic);
        }
    };

    while (true) {
        _ = channel.consumeBatch(Handler{ .count = count });
        if (count.load(.acquire) >= expected) break;
        if (done.load(.acquire) and count.load(.acquire) >= expected) break;
    }
}
