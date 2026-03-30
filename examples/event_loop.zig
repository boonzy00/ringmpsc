//! Event loop — managed consumer with automatic shutdown and drain.

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const Config = ringmpsc.mpsc.Config{ .ring_bits = 12, .max_producers = 2 };
const Channel = ringmpsc.mpsc.Channel(u64, Config);

var message_sum: u64 = 0;

fn handleMessage(item: *const u64) void {
    message_sum += item.*;
}

pub fn main() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    // Create event loop with blocking wait strategy (zero CPU when idle)
    var loop = ringmpsc.EventLoop(u64, Channel).init(
        &channel,
        handleMessage,
        .blocking,
    );

    // Spawn consumer thread
    const thread = try loop.spawn();
    std.debug.print("Event loop running\n", .{});

    // Send some messages
    const p = try channel.register();
    var bo = ringmpsc.primitives.Backoff{};
    for (0..10_000) |i| {
        while (!p.sendOne(@intCast(i))) bo.snooze();
        bo.reset();
    }

    // Let consumer process
    std.Thread.sleep(10_000_000); // 10ms

    // Stop and drain
    loop.stop();
    thread.join();

    std.debug.print("Processed: {d} messages\n", .{loop.processed()});
    std.debug.print("Sum: {d}\n", .{message_sum});
    std.debug.print("Expected sum: {d}\n", .{@as(u64, 10_000) * 9_999 / 2});
}
