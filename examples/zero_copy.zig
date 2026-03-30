//! Example: Zero-copy large message passing with BufferPool + Ring
//!
//! Demonstrates the pointer-ring pattern: the ring carries small handles (u32),
//! while payloads live in a pre-allocated BufferPool. No payload copies occur —
//! the producer writes directly to the pool slab, and the consumer reads from
//! the same memory address.
//!
//! Run: zig build example-zero-copy -Doptimize=ReleaseFast

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const BufferPool = ringmpsc.primitives.BufferPool;
const Handle = ringmpsc.primitives.Handle;
const INVALID_HANDLE = ringmpsc.primitives.INVALID_HANDLE;

// 4KB slabs, 256 of them = 1MB pool
const Pool = BufferPool(4096, 256);

const stderr = (std.fs.File{ .handle = std.posix.STDERR_FILENO }).deprecatedWriter();

pub fn main() !void {
    // The ring carries handles (u32), not payloads
    var ring = ringmpsc.primitives.Ring(Handle, .{ .ring_bits = 10 }){};

    // Pre-allocated buffer pool — all memory is inline, no heap
    var pool: Pool = .{};

    const num_messages = 1000;
    const payload_size = 2048; // 2KB per message

    // Producer thread
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(r: *@TypeOf(ring), p: *Pool) void {
            for (0..num_messages) |i| {
                // 1. Allocate a slab from the pool
                const handle = p.alloc() orelse {
                    // Pool exhausted — backpressure. In production, retry with backoff.
                    continue;
                };

                // 2. Write directly into the pool slab (ZERO COPY)
                const buf = p.getWritable(handle);
                // Fill with a pattern we can verify
                const tag: u8 = @truncate(i);
                @memset(buf[0..payload_size], tag);

                // 3. Publish the length
                p.setLen(handle, payload_size);

                // 4. Send the HANDLE through the ring (4 bytes, not 2048)
                _ = r.send(&[_]Handle{handle});
            }
            r.close();
        }
    }.run, .{ &ring, &pool });

    // Consumer
    var received: usize = 0;
    var verified: usize = 0;

    while (!ring.isClosed() or ring.len() > 0) {
        if (ring.readable()) |slice| {
            for (slice) |handle| {
                if (handle == INVALID_HANDLE) continue;

                // Read directly from pool slab (ZERO COPY)
                const payload = pool.get(handle);
                received += 1;

                // Verify the pattern
                const expected: u8 = @truncate(received - 1);
                var ok = true;
                for (payload) |byte| {
                    if (byte != expected) {
                        ok = false;
                        break;
                    }
                }
                if (ok) verified += 1;

                // Return slab to pool
                pool.free(handle);
            }
            ring.advance(slice.len);
        }
    }

    // Final drain
    while (ring.readable()) |slice| {
        for (slice) |handle| {
            if (handle == INVALID_HANDLE) continue;
            _ = pool.get(handle);
            received += 1;
            pool.free(handle);
        }
        ring.advance(slice.len);
    }

    producer.join();

    try stderr.print("Zero-copy large message passing:\n", .{});
    try stderr.print("  Messages: {d} sent, {d} received, {d} verified\n", .{ num_messages, received, verified });
    try stderr.print("  Payload: {d} bytes/msg, ring carried {d}-byte handles\n", .{ payload_size, @sizeOf(Handle) });
    try stderr.print("  Pool: {d} slabs × {d} bytes = {d} KB total\n", .{ Pool.NUM_SLABS, Pool.SLAB_SIZE, Pool.NUM_SLABS * Pool.SLAB_SIZE / 1024 });
    try stderr.print("  Copies: 0 (producer wrote directly to pool, consumer read from same address)\n", .{});
}
