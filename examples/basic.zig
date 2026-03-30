//! Basic SPSC usage — single producer, single consumer.

const std = @import("std");
const ringmpsc = @import("ringmpsc");

pub fn main() !void {
    // SPSC channel is a zero-overhead type alias for Ring
    var ring = ringmpsc.spsc.Channel(u64, .{}){};

    // Send a batch
    const sent = ring.send(&[_]u64{ 10, 20, 30, 40, 50 });
    std.debug.print("Sent {d} messages\n", .{sent});

    // Receive
    var buf: [10]u64 = undefined;
    const received = ring.recv(&buf);
    std.debug.print("Received {d} messages: ", .{received});
    for (buf[0..received]) |v| std.debug.print("{d} ", .{v});
    std.debug.print("\n", .{});

    // Zero-copy reserve/commit
    if (ring.reserve(3)) |r| {
        r.slice[0] = 100;
        r.slice[1] = 200;
        r.slice[2] = 300;
        ring.commit(3);
    }

    // Single-item receive
    if (ring.tryRecv()) |v| {
        std.debug.print("Got: {d}\n", .{v});
    }
}
