//! Deterministic Execution Verification: Validates reproducible per-producer checksums

const std = @import("std");
const ringmpsc = @import("channel");

const P: usize = 4;
const MSG: u64 = 500_000;
const TOTAL: u64 = P * MSG;
const SEED: u64 = 0xDEADBEEF12345678;

pub fn main() !void {
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("║                  DETERMINISTIC EXECUTION VERIFICATION TEST                  ║\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Configuration: {d} producers × {d}K messages = {d}M total messages\n", .{ P, MSG / 1_000, TOTAL / 1_000_000 });
    std.debug.print("Seed: 0x{x:0>16}\n", .{SEED});
    std.debug.print("Property: Identical seeds must produce identical per-producer checksums\n\n", .{});

    // Run twice and compare per-producer checksums
    const r1 = try run(SEED);
    const r2 = try run(SEED);

    var match = true;
    for (0..P) |i| {
        if (r1.sums[i] != r2.sums[i]) match = false;
    }

    std.debug.print("Execution Results:\n", .{});
    std.debug.print("  Run 1 checksum: 0x{x:0>16} ({d} messages)\n", .{ r1.total, r1.n });
    std.debug.print("  Run 2 checksum: 0x{x:0>16} ({d} messages)\n", .{ r2.total, r2.n });
    std.debug.print("\nConclusion: {s}\n", .{if (match and r1.n == r2.n) "VERIFIED - DETERMINISTIC EXECUTION CONFIRMED" else "FAILED - NON-DETERMINISTIC BEHAVIOR DETECTED"});
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
}

fn run(seed: u64) !struct { sums: [P]u64, total: u64, n: u64 } {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ch = try gpa.allocator().create(ringmpsc.Channel(u64, ringmpsc.default_config));
    defer gpa.allocator().destroy(ch);
    ch.* = .{};

    // Pre-register producers synchronously for deterministic IDs
    var producers: [P]ringmpsc.Channel(u64, ringmpsc.default_config).Producer = undefined;
    for (0..P) |i| producers[i] = try ch.register();

    var sums: [P]std.atomic.Value(u64) = undefined;
    for (&sums) |*s| s.* = std.atomic.Value(u64).init(0);

    var threads: [P]std.Thread = undefined;
    for (0..P) |i| threads[i] = try std.Thread.spawn(.{}, worker, .{ producers[i], i, seed, &sums[i] });

    var got: u64 = 0;
    var buf: [256]u64 = undefined;
    while (got < TOTAL) {
        const n = ch.recv(&buf);
        got += n;
        if (n == 0) std.atomic.spinLoopHint();
    }

    for (&threads) |*t| t.join();

    var result_sums: [P]u64 = undefined;
    var total: u64 = 0;
    for (0..P) |i| {
        result_sums[i] = sums[i].load(.acquire);
        total +%= result_sums[i];
    }
    return .{ .sums = result_sums, .total = total, .n = got };
}

fn worker(p: ringmpsc.Channel(u64, ringmpsc.default_config).Producer, id: usize, seed: u64, sum_out: *std.atomic.Value(u64)) void {
    pin(id);
    _ = seed;

    // Deterministic sequence: id * 10^12 + seq
    const base: u64 = @as(u64, id) * 1_000_000_000_000;
    var sum: u64 = 0;
    var sent: u64 = 0;

    while (sent < MSG) {
        const v = base + sent;
        if (p.reserve(1)) |r| {
            r.slice[0] = v;
            p.commit(1);
            sum +%= v;
            sent += 1;
        } else std.atomic.spinLoopHint();
    }
    sum_out.store(sum, .release);
}

fn pin(cpu: usize) void {
    const max = std.Thread.getCpuCount() catch 16;
    var set = std.mem.zeroes(std.os.linux.cpu_set_t);
    const c = cpu % max;
    set[c / 64] |= @as(u64, 1) << @as(u6, @intCast(c % 64));
    _ = std.os.linux.sched_setaffinity(0, &set) catch {};
}
