const std = @import("std");
const ringmpsc = @import("ringmpsc");
const simd = ringmpsc.primitives.simd;

pub fn main() void {
    std.debug.print("SIMD Functional Tests\n", .{});
    std.debug.print("=====================\n\n", .{});

    var passed: u32 = 0;
    var failed: u32 = 0;

    // Test 1: ringMemcpy — basic copy correctness
    {
        var src: [256]u8 = undefined;
        var dst: [256]u8 = undefined;
        @memset(&dst, 0);
        for (&src, 0..) |*b, i| b.* = @truncate(i *% 37 +% 13);

        simd.ringMemcpy(@ptrCast(&dst), @ptrCast(&src), 256);

        var ok = true;
        for (0..256) |i| {
            if (dst[i] != src[i]) { ok = false; break; }
        }
        if (ok) {
            std.debug.print("  ringMemcpy (256 bytes)             PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ringMemcpy (256 bytes)             FAILED\n", .{});
            failed += 1;
        }
    }

    // Test 2: ringMemcpy — small sizes (below SIMD threshold)
    {
        var ok = true;
        for ([_]usize{ 0, 1, 3, 7, 15, 16, 31 }) |size| {
            var src: [64]u8 = undefined;
            var dst: [64]u8 = undefined;
            @memset(&dst, 0xFF);
            for (src[0..size], 0..) |*b, i| b.* = @truncate(i +% 1);

            simd.ringMemcpy(@ptrCast(&dst), @ptrCast(&src), size);

            for (0..size) |i| {
                if (dst[i] != src[i]) { ok = false; break; }
            }
        }
        if (ok) {
            std.debug.print("  ringMemcpy (small sizes)           PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ringMemcpy (small sizes)           FAILED\n", .{});
            failed += 1;
        }
    }

    // Test 3: ringMemcpyU64 — u64 slice copy
    {
        var src: [64]u64 = undefined;
        var dst: [64]u64 = undefined;
        @memset(&dst, 0);
        for (&src, 0..) |*v, i| v.* = i * 1000 + 42;

        simd.ringMemcpyU64(@ptrCast(&dst), @ptrCast(&src), 64);

        var ok = true;
        for (0..64) |i| {
            if (dst[i] != src[i]) { ok = false; break; }
        }
        if (ok) {
            std.debug.print("  ringMemcpyU64 (64 elements)        PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ringMemcpyU64 (64 elements)        FAILED\n", .{});
            failed += 1;
        }
    }

    // Test 4: ringMemcpyTyped — typed copy
    {
        var src: [32]u32 = undefined;
        var dst: [32]u32 = undefined;
        @memset(&dst, 0);
        for (&src, 0..) |*v, i| v.* = @intCast(i * 7 + 99);

        simd.ringMemcpyTyped(u32, &dst, &src);

        var ok = true;
        for (0..32) |i| {
            if (dst[i] != src[i]) { ok = false; break; }
        }
        if (ok) {
            std.debug.print("  ringMemcpyTyped (u32, 32 elems)    PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ringMemcpyTyped (u32, 32 elems)    FAILED\n", .{});
            failed += 1;
        }
    }

    // Test 5: ringMemset — fill with value
    {
        var buf: [128]u8 = undefined;
        @memset(&buf, 0);
        simd.ringMemset(@ptrCast(&buf), 0xAB, 128);

        var ok = true;
        for (buf) |b| {
            if (b != 0xAB) { ok = false; break; }
        }
        if (ok) {
            std.debug.print("  ringMemset (128 bytes, 0xAB)       PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ringMemset (128 bytes, 0xAB)       FAILED\n", .{});
            failed += 1;
        }
    }

    // Test 6: ringZero — zero fill
    {
        var buf: [256]u8 = undefined;
        @memset(&buf, 0xFF);
        simd.ringZero(@ptrCast(&buf), 256);

        var ok = true;
        for (buf) |b| {
            if (b != 0) { ok = false; break; }
        }
        if (ok) {
            std.debug.print("  ringZero (256 bytes)               PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ringZero (256 bytes)               FAILED\n", .{});
            failed += 1;
        }
    }

    // Test 7: SIMD copy through actual ring buffer send/recv
    {
        const Ring = ringmpsc.primitives.Ring(u64, .{ .ring_bits = 8 }); // 256 slots
        var ring = Ring{};

        // Send 100 items
        var data: [100]u64 = undefined;
        for (&data, 0..) |*v, i| v.* = i * 13 + 7;
        const sent = ring.send(&data);

        // Recv into output
        var out: [100]u64 = undefined;
        @memset(&out, 0);
        const recvd = ring.recv(&out);

        var ok = sent == 100 and recvd == 100;
        if (ok) {
            for (0..100) |i| {
                if (out[i] != data[i]) { ok = false; break; }
            }
        }
        if (ok) {
            std.debug.print("  SIMD through ring send/recv        PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  SIMD through ring send/recv        FAILED (sent={}, recvd={})\n", .{ sent, recvd });
            failed += 1;
        }
    }

    // Test 8: Large copy (4KB) — exercises main SIMD loop
    {
        var src: [4096]u8 = undefined;
        var dst: [4096]u8 = undefined;
        @memset(&dst, 0);
        for (&src, 0..) |*b, i| b.* = @truncate(i);

        simd.ringMemcpy(@ptrCast(&dst), @ptrCast(&src), 4096);

        var ok = true;
        for (0..4096) |i| {
            if (dst[i] != src[i]) { ok = false; break; }
        }
        if (ok) {
            std.debug.print("  ringMemcpy (4KB)                   PASSED\n", .{});
            passed += 1;
        } else {
            std.debug.print("  ringMemcpy (4KB)                   FAILED\n", .{});
            failed += 1;
        }
    }

    std.debug.print("\nResults: {} passed, {} failed\n", .{ passed, failed });
    if (failed > 0) std.process.exit(1);
}
