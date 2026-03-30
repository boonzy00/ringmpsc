//! Backpressure — blocking send with timeout on a slow consumer.

const std = @import("std");
const ringmpsc = @import("ringmpsc");

pub fn main() !void {
    // Small ring to trigger backpressure quickly
    var ring = ringmpsc.primitives.Ring(u64, .{ .ring_bits = 8 }){}; // 256 slots

    // Fill the ring
    for (0..256) |i| _ = ring.send(&[_]u64{@intCast(i)});
    std.debug.print("Ring full ({d} items)\n", .{ring.len()});

    // Blocking send with 10ms timeout — will fail because ring is full
    // and nobody is consuming
    if (ring.reserveBlocking(1, .{ .timed_blocking = .{ .timeout_ns = 10_000_000 } })) |_| {
        std.debug.print("Got reservation (unexpected)\n", .{});
    } else |err| switch (err) {
        error.TimedOut => std.debug.print("Timed out after 10ms (expected — no consumer)\n", .{}),
        error.Closed => std.debug.print("Channel closed\n", .{}),
    }

    // Now consume some items and retry
    _ = ring.consumeBatchCount();
    std.debug.print("Drained ring, now empty ({d} items)\n", .{ring.len()});

    // Blocking send succeeds immediately now
    try ring.sendOneBlocking(42, .busy_spin);
    std.debug.print("Sent 42 successfully\n", .{});

    // Blocking consume with futex (zero CPU when idle)
    const Handler = struct {
        pub fn process(_: @This(), item: *const u64) void {
            std.debug.print("Received: {d}\n", .{item.*});
        }
    };
    _ = try ring.consumeBatchBlocking(Handler{}, .{ .timed_blocking = .{ .timeout_ns = 1_000_000 } });
}
