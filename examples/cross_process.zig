//! Example: True cross-process IPC via SharedRing + fd passing
//!
//! Demonstrates the full cross-process flow:
//!   1. Server creates SharedRing + listens on Unix socket
//!   2. Client connects + receives ring fd via SCM_RIGHTS
//!   3. Producer (server) and consumer (client) communicate lock-free
//!
//! This example uses threads to simulate two processes, but the fd
//! passing over Unix socket is real and works identically across
//! separate process boundaries.
//!
//! Run: zig build example-cross-process

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const SharedRing = ringmpsc.primitives.SharedRing;
const fd_passing = ringmpsc.platform.fd_passing;
const stderr = (std.fs.File{ .handle = std.posix.STDERR_FILENO }).deprecatedWriter();

const SOCKET_PATH = "/tmp/ringmpsc-example.sock";
const NUM_MESSAGES = 50_000;

pub fn main() !void {
    // Server: create ring + listen
    var ring = try SharedRing(u64).create(14); // 16384 slots
    defer ring.deinit();

    var server = try fd_passing.FdServer.listen(SOCKET_PATH);
    defer server.deinit();

    try stderr.print("Server: ring created (fd={d}, {d} slots)\n", .{ ring.getFd(), ring.capacity });
    try stderr.print("Server: listening on {s}\n", .{SOCKET_PATH});

    // Spawn "client process" (thread simulating separate process)
    const client_thread = try std.Thread.spawn(.{}, clientProcess, .{});

    // Accept connection + send ring fd
    const conn = try server.accept();
    defer std.posix.close(conn);
    try fd_passing.sendFd(conn, ring.getFd());
    try stderr.print("Server: sent ring fd to client\n", .{});

    // Produce messages
    for (0..NUM_MESSAGES) |i| {
        while (ring.send(&[_]u64{@intCast(i)}) == 0) {
            std.atomic.spinLoopHint();
        }
    }
    ring.close();
    try stderr.print("Server: sent {d} messages, closed\n", .{NUM_MESSAGES});

    client_thread.join();
}

fn clientProcess() void {
    // Small delay for server to start listening
    std.Thread.sleep(10_000_000); // 10ms

    // Connect to server
    const conn = fd_passing.connectUnix(SOCKET_PATH) catch {
        stderr.print("Client: connect failed\n", .{}) catch {};
        return;
    };
    defer std.posix.close(conn);

    // Receive ring fd
    const ring_fd = fd_passing.recvFd(conn) catch {
        stderr.print("Client: recvFd failed\n", .{}) catch {};
        return;
    };

    // Attach to shared ring
    var ring = SharedRing(u64).attach(ring_fd) catch {
        stderr.print("Client: attach failed\n", .{}) catch {};
        return;
    };
    defer ring.deinit();

    stderr.print("Client: attached to ring (fd={d})\n", .{ring_fd}) catch {};

    // Consume
    var received: usize = 0;
    var last: u64 = 0;
    var fifo_ok = true;

    while (!ring.isClosed() or !ring.isEmpty()) {
        if (ring.readable()) |slice| {
            for (slice) |val| {
                if (val < last and received > 0) fifo_ok = false;
                last = val;
                received += 1;
            }
            ring.advance(slice.len);
        } else {
            std.atomic.spinLoopHint();
        }
    }

    // Final drain
    while (ring.readable()) |slice| {
        received += slice.len;
        ring.advance(slice.len);
    }

    stderr.print("Client: received {d} messages, FIFO={s}\n", .{
        received,
        if (fifo_ok) "PASS" else "FAIL",
    }) catch {};
}
