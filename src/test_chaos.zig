//! Race Condition Detection: Validates thread safety under chaotic scheduling

const std = @import("std");
const ringmpsc = @import("channel");

const P: usize = 8;
const MSG: u64 = 100_000;
const TOTAL: u64 = P * MSG;
const ITERS: u32 = 10;

pub fn main() !void {
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("║                        RACE CONDITION DETECTION TEST                        ║\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Configuration: {d} iterations × {d} producers × {d}K messages\n", .{ ITERS, P, MSG / 1_000 });
    std.debug.print("Property: Thread safety under random delays and scheduling perturbations\n\n", .{});

    var pass: u32 = 0;
    for (0..ITERS) |i| {
        if (try iteration(i)) {
            pass += 1;
            std.debug.print("  Iteration {d:>2}: ✓ PASS\n", .{i + 1});
        } else {
            std.debug.print("  Iteration {d:>2}: ✗ FAIL\n", .{i + 1});
        }
    }

    const ok = pass == ITERS;
    std.debug.print("\nResults: {d}/{d} iterations passed\n", .{ pass, ITERS });
    std.debug.print("\nConclusion: {s}\n", .{if (ok) "NONE DETECTED - THREAD SAFETY VERIFIED" else "RACES FOUND - THREAD SAFETY VIOLATIONS DETECTED"});
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
}

fn iteration(iter: usize) !bool {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ch = try gpa.allocator().create(ringmpsc.Channel(u64, ringmpsc.default_config));
    defer gpa.allocator().destroy(ch);
    ch.* = .{};

    var sums: [P]std.atomic.Value(u64) = undefined;
    for (&sums) |*s| s.* = std.atomic.Value(u64).init(0);

    var threads: [P]std.Thread = undefined;
    for (0..P) |i| threads[i] = try std.Thread.spawn(.{}, worker, .{ ch, i, iter, &sums[i] });

    var rng = std.Random.DefaultPrng.init(@as(u64, iter) *% 0x123456789ABCDEF);
    var sum: u64 = 0;
    var got: u64 = 0;
    var buf: [64]u64 = undefined;

    while (got < TOTAL) {
        for (0..rng.random().intRangeAtMost(u32, 0, 100)) |_| std.atomic.spinLoopHint();
        const n = ch.recv(&buf);
        for (buf[0..n]) |v| sum +%= v;
        got += n;
        if (n == 0) std.atomic.spinLoopHint();
    }

    for (&threads) |*t| t.join();
    var expected: u64 = 0;
    for (&sums) |*s| expected +%= s.load(.acquire);
    return sum == expected;
}

fn worker(ch: *ringmpsc.Channel(u64, ringmpsc.default_config), id: usize, iter: usize, sum_out: *std.atomic.Value(u64)) void {
    const max = std.Thread.getCpuCount() catch 16;
    pin((id + iter) % max);
    const p = ch.register() catch return;

    var rng = std.Random.DefaultPrng.init(@as(u64, id) *% @as(u64, iter + 1));
    var sum: u64 = 0;
    const base: u64 = @as(u64, id) << 48;
    var sent: u64 = 0;

    while (sent < MSG) {
        for (0..rng.random().intRangeAtMost(u32, 0, 50)) |_| std.atomic.spinLoopHint();
        const v = base | sent;
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
