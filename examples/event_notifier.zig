//! Example: EventNotifier + epoll consumer loop
//!
//! Demonstrates how to use ringmpsc with epoll for event-driven consumption.
//! The consumer sleeps in epoll_wait with zero CPU usage until the producer
//! signals via eventfd.
//!
//! Run: zig build example-event-notifier -Doptimize=ReleaseFast

const std = @import("std");
const ringmpsc = @import("ringmpsc");
const EventNotifier = ringmpsc.primitives.EventNotifier;

const linux = std.os.linux;
const posix = std.posix;

pub fn main() !void {
    const stdout = (std.fs.File{ .handle = std.posix.STDOUT_FILENO }).deprecatedWriter();

    // Create ring + notifier
    var ring = ringmpsc.primitives.Ring(u64, .{ .ring_bits = 10 }){};
    var notifier = try EventNotifier.init();
    defer notifier.deinit();

    // Attach notifier to ring — commit() will now signal eventfd
    ring.setEventNotifier(&notifier);

    // Create epoll
    const epoll_fd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
    defer posix.close(epoll_fd);
    try notifier.registerEpoll(epoll_fd);

    // Producer thread
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(r: *@TypeOf(ring)) void {
            for (0..100) |i| {
                _ = r.send(&[_]u64{i});
                // Simulate bursty production
                if (i % 10 == 0) std.Thread.sleep(1_000_000); // 1ms
            }
            r.close();
        }
    }.run, .{&ring});

    // Consumer: epoll event loop
    var total: usize = 0;
    var events: [4]linux.epoll_event = undefined;

    try stdout.print("Consumer waiting on epoll (zero CPU when idle)...\n", .{});

    while (!ring.isClosed() or ring.len() > 0) {
        const n = posix.epoll_wait(epoll_fd, &events, 100); // 100ms timeout
        if (n > 0) {
            _ = notifier.consume(); // Reset eventfd counter
            // Drain all available
            while (ring.readable()) |slice| {
                total += slice.len;
                ring.advance(slice.len);
            }
        }
    }

    // Final drain
    while (ring.readable()) |slice| {
        total += slice.len;
        ring.advance(slice.len);
    }

    producer.join();
    try stdout.print("Done: {d} messages consumed via epoll\n", .{total});
}
