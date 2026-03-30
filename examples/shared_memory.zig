//! Example: Cross-process shared memory ring buffer
//!
//! Demonstrates SharedRing using memfd_create + MAP_SHARED.
//! In this example, producer and consumer run as threads (simulating
//! separate processes). In production, the fd would be passed via
//! Unix socket SCM_RIGHTS to a separate process.
//!
//! Run: zig build example-shared-memory -Doptimize=ReleaseFast

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const SharedRing = ringmpsc.primitives.SharedRing;
const stderr = (std.fs.File{ .handle = std.posix.STDERR_FILENO }).deprecatedWriter();

pub fn main() !void {
    // Creator process: create shared ring
    var ring = try SharedRing(u64).create(12); // 4096 slots
    defer ring.deinit();

    try stderr.print("Shared ring created:\n", .{});
    try stderr.print("  fd: {d}\n", .{ring.getFd()});
    try stderr.print("  capacity: {d} slots\n", .{ring.capacity});
    try stderr.print("  mapped size: {d} bytes\n", .{ring.mapped.len});
    try stderr.print("  header size: {d} bytes\n", .{@sizeOf(ringmpsc.primitives.SharedRingHeader)});
    try stderr.print("\n", .{});

    const num_messages: usize = 100_000;

    // Simulate "other process" attaching via same fd
    // In production: pass ring.getFd() via Unix socket SCM_RIGHTS
    var consumer_ring = try SharedRing(u64).attach(ring.getFd());
    defer consumer_ring.deinit();

    // Producer thread (simulating Process A)
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(r: *SharedRing(u64), n: usize) void {
            for (0..n) |i| {
                // Spin until space available
                while (r.send(&[_]u64{@intCast(i)}) == 0) {
                    std.atomic.spinLoopHint();
                }
            }
            r.close();
        }
    }.run, .{ &ring, num_messages });

    // Consumer thread (simulating Process B using the attached ring)
    var received: usize = 0;
    var last_val: u64 = 0;
    var order_ok = true;

    while (!consumer_ring.isClosed() or !consumer_ring.isEmpty()) {
        if (consumer_ring.readable()) |slice| {
            for (slice) |val| {
                if (val < last_val and received > 0) order_ok = false;
                last_val = val;
                received += 1;
            }
            consumer_ring.advance(slice.len);
        } else {
            std.atomic.spinLoopHint();
        }
    }

    // Final drain
    while (consumer_ring.readable()) |slice| {
        received += slice.len;
        consumer_ring.advance(slice.len);
    }

    producer.join();

    try stderr.print("Cross-process shared memory ring:\n", .{});
    try stderr.print("  Messages: {d} sent, {d} received\n", .{ num_messages, received });
    try stderr.print("  FIFO order: {s}\n", .{if (order_ok) "PASS" else "FAIL"});
    try stderr.print("  Producer alive: {}\n", .{ring.isProducerAlive(1_000_000_000)});
    try stderr.print("  Backed by: memfd_create + MAP_SHARED (no filesystem)\n", .{});
    try stderr.print("  Cleanup: automatic on fd close (no shm_unlink needed)\n", .{});
}
