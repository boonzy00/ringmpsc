const std = @import("std");
const ringmpsc = @import("ringmpsc");

pub fn main() void {
    std.debug.print("u64 Wraparound Tests\n", .{});
    std.debug.print("====================\n\n", .{});

    var passed: u32 = 0;
    var failed: u32 = 0;

    // Test 1: Basic SPSC send/recv near u64 MAX
    {
        const Ring = ringmpsc.primitives.Ring(u32, .{ .ring_bits = 4 }); // 16 slots
        var ring = Ring{};

        // Manually set head and tail near u64 MAX to simulate wraparound
        ring.head.store(std.math.maxInt(u64) - 8, .monotonic);
        ring.tail.store(std.math.maxInt(u64) - 8, .monotonic);
        ring.cached_head = std.math.maxInt(u64) - 8;
        ring.cached_tail = std.math.maxInt(u64) - 8;

        // Send 12 items across the u64 boundary
        var sent: u32 = 0;
        for (0..12) |i| {
            const val: u32 = @intCast(100 + i);
            if (ring.send(&[_]u32{val}) == 1) {
                sent += 1;
            }
        }

        // Receive and verify FIFO order
        var recv_count: u32 = 0;
        var order_ok = true;
        for (0..12) |i| {
            if (ring.tryRecv()) |val| {
                const expected: u32 = @intCast(100 + i);
                if (val != expected) order_ok = false;
                recv_count += 1;
            }
        }

        if (sent == 12 and recv_count == 12 and order_ok) {
            std.debug.print("  u64 wraparound FIFO (SPSC)        PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  u64 wraparound FIFO (SPSC)        FAILED (sent={}, recv={}, order={})\n", .{ sent, recv_count, order_ok });
            failed += 1;
        }
    }

    // Test 2: Fill and drain across wraparound boundary
    {
        const Ring = ringmpsc.primitives.Ring(u64, .{ .ring_bits = 3 }); // 8 slots
        var ring = Ring{};

        ring.head.store(std.math.maxInt(u64) - 3, .monotonic);
        ring.tail.store(std.math.maxInt(u64) - 3, .monotonic);
        ring.cached_head = std.math.maxInt(u64) - 3;
        ring.cached_tail = std.math.maxInt(u64) - 3;

        // Fill the ring completely (capacity - 1 = 7 items)
        var fill_count: usize = 0;
        for (0..8) |i| {
            if (ring.send(&[_]u64{@intCast(i + 1000)}) == 1) {
                fill_count += 1;
            }
        }

        // Ring should be full (7 items, 1 slot reserved)
        const full_ok = ring.isFull() or fill_count == 7;

        // Drain all
        var drain_count: usize = 0;
        while (ring.tryRecv() != null) {
            drain_count += 1;
        }

        if (fill_count == drain_count and full_ok) {
            std.debug.print("  u64 wraparound fill/drain          PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  u64 wraparound fill/drain          FAILED (fill={}, drain={}, full_ok={})\n", .{ fill_count, drain_count, full_ok });
            failed += 1;
        }
    }

    // Test 3: Multiple reserve/commit cycles across u64 boundary
    {
        const Ring = ringmpsc.primitives.Ring(u32, .{ .ring_bits = 5 }); // 32 slots
        var ring = Ring{};

        ring.head.store(std.math.maxInt(u64) - 10, .monotonic);
        ring.tail.store(std.math.maxInt(u64) - 10, .monotonic);
        ring.cached_head = std.math.maxInt(u64) - 10;
        ring.cached_tail = std.math.maxInt(u64) - 10;

        // Send 20 items one-by-one across the u64 boundary
        var sent: usize = 0;
        for (0..20) |i| {
            const val: u32 = @intCast(i * 7 + 42);
            if (ring.send(&[_]u32{val}) == 1) sent += 1;
        }

        // Verify via recv
        var out: [20]u32 = undefined;
        var recvd: usize = 0;
        while (recvd < 20) {
            const n = ring.recv(out[recvd..]);
            if (n == 0) break;
            recvd += n;
        }

        var data_ok = true;
        for (0..recvd) |i| {
            const expected: u32 = @intCast(i * 7 + 42);
            if (out[i] != expected) { data_ok = false; break; }
        }

        if (sent == 20 and recvd == 20 and data_ok) {
            std.debug.print("  u64 wraparound reserve/commit      PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  u64 wraparound reserve/commit      FAILED (sent={}, recvd={}, data_ok={})\n", .{ sent, recvd, data_ok });
            failed += 1;
        }
    }

    // Test 4: MPSC channel across wraparound (concurrent)
    {
        var channel = ringmpsc.mpsc.Channel(u32, .{ .ring_bits = 6, .max_producers = 4 }).init(std.heap.page_allocator) catch {
            std.debug.print("  u64 wraparound MPSC concurrent     FAILED (init)\n", .{});
            failed += 1;
            printSummary(passed, failed);
            return;
        };
        defer channel.deinit();

        // Set ring positions near u64 MAX
        const count = channel.producer_count.load(.acquire);
        for (channel.rings[0..@max(count, 4)]) |ring_ptr| {
            ring_ptr.head.store(std.math.maxInt(u64) - 100, .monotonic);
            ring_ptr.tail.store(std.math.maxInt(u64) - 100, .monotonic);
            ring_ptr.cached_head = std.math.maxInt(u64) - 100;
            ring_ptr.cached_tail = std.math.maxInt(u64) - 100;
        }

        const msgs_per_producer = 500;
        const num_producers = 2;
        var threads: [num_producers]std.Thread = undefined;

        for (0..num_producers) |i| {
            const producer = channel.register() catch {
                std.debug.print("  u64 wraparound MPSC concurrent     FAILED (register)\n", .{});
                failed += 1;
                printSummary(passed, failed);
                return;
            };
            threads[i] = std.Thread.spawn(.{}, struct {
                fn run(p: anytype, n: usize) void {
                    var bo = ringmpsc.primitives.Backoff{};
                    var sent: usize = 0;
                    while (sent < n) {
                        if (p.sendOne(@truncate(sent))) {
                            sent += 1;
                            bo.reset();
                        } else bo.snooze();
                    }
                }
            }.run, .{ producer, msgs_per_producer }) catch {
                std.debug.print("  u64 wraparound MPSC concurrent     FAILED (spawn)\n", .{});
                failed += 1;
                printSummary(passed, failed);
                return;
            };
        }

        // Consume
        var total_recv: usize = 0;
        var idle: u32 = 0;
        while (total_recv < msgs_per_producer * num_producers) {
            const n = channel.consumeAllCount();
            total_recv += n;
            if (n == 0) {
                idle += 1;
                if (idle > 1_000_000) break;
                std.atomic.spinLoopHint();
            } else {
                idle = 0;
            }
        }

        for (0..num_producers) |i| threads[i].join();

        if (total_recv == msgs_per_producer * num_producers) {
            std.debug.print("  u64 wraparound MPSC concurrent     PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  u64 wraparound MPSC concurrent     FAILED (expected={}, got={})\n", .{ msgs_per_producer * num_producers, total_recv });
            failed += 1;
        }
    }

    std.debug.print("\n", .{});
    printSummary(passed, failed);
}

fn printSummary(passed: u32, failed: u32) void {
    std.debug.print("Results: {} passed, {} failed\n", .{ passed, failed });
    if (failed > 0) std.process.exit(1);
}
