// MPSC Ring Buffer Benchmark
//
// Measures throughput of single-producer, single-consumer ring buffer operations.

const std = @import("std");
const ringmpsc = @import("ringmpsc");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create a MPSC channel (1M capacity per producer)
    const config = ringmpsc.mpsc.Config{ .ring_bits = 20 }; // 1M capacity
    var channel = try ringmpsc.mpsc.Channel(u64, config).init(allocator);
    defer channel.deinit();

    // Register producer
    const producer = try channel.register();

    // Benchmark configuration
    const num_messages: usize = 10_000_000; // 10M messages
    const num_iterations: usize = 5;

    var total_time: u64 = 0;

    std.debug.print("Benchmarking MPSC channel with {} messages...\n", .{num_messages});

    for (0..num_iterations) |iter| {
        const start_time = std.time.nanoTimestamp();

        // Producer: send messages
        const producer_thread = try std.Thread.spawn(.{}, producerFn, .{ producer, num_messages });
        defer producer_thread.join();

        // Consumer: receive messages
        var received: usize = 0;
        while (received < num_messages) {
            if (channel.recvOne()) |msg| {
                received += 1;
                // Process message (just count)
                _ = msg;
            } else {
                // Yield to allow producer to run
                std.Thread.yield() catch {};
            }
        }

        const end_time = std.time.nanoTimestamp();
        const duration_ns = @as(u64, @intCast(end_time - start_time));
        total_time += duration_ns;

        std.debug.print("Iteration {}: {} ns\n", .{ iter + 1, duration_ns });
    }

    const avg_time_ns = total_time / num_iterations;
    const throughput = (num_messages * 1_000_000_000) / avg_time_ns; // messages per second

    std.debug.print("\nResults:\n", .{});
    std.debug.print("Average time: {} ns\n", .{avg_time_ns});
    std.debug.print("Throughput: {} msg/s\n", .{throughput});
}

fn producerFn(producer: anytype, num_messages: usize) !void {
    for (0..num_messages) |i| {
        while (!producer.sendOne(@intCast(i))) {
            std.Thread.yield() catch {};
        }
    }
}
