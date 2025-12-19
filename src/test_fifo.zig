//! FIFO Ordering Test: Verifies sequential consistency per producer

const std = @import("std");
const ringmpsc = @import("channel");

const P: usize = 8;
const MSG: u64 = 1_000_000;
const TOTAL: u64 = P * MSG;

var channel: ringmpsc.Channel(u64, ringmpsc.default_config) = .{};

pub fn main() !void {
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("║                       FIFO ORDERING VERIFICATION TEST                       ║\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
    std.debug.print("Configuration: {d} producers × {d}M messages = {d}M total messages\n", .{ P, MSG / 1_000_000, TOTAL / 1_000_000 });
    std.debug.print("Property: Per-producer FIFO ordering must be maintained\n\n", .{});

    var threads: [P]std.Thread = undefined;
    for (0..P) |i| threads[i] = try std.Thread.spawn(.{}, producer, .{i});

    var expected: [P]u64 = [_]u64{0} ** P;
    var received: [P]u64 = [_]u64{0} ** P;
    var violations: u64 = 0;
    var duplicates: u64 = 0;
    var total: u64 = 0;
    var buf: [256]u64 = undefined;

    const t0 = std.time.nanoTimestamp();
    while (total < TOTAL) {
        const n = channel.recv(&buf);
        for (buf[0..n]) |msg| {
            const pid: usize = @intCast(msg >> 56);
            const seq: u64 = msg & 0x00FFFFFFFFFFFFFF;
            if (pid >= P) continue;

            if (seq != expected[pid]) {
                if (seq < expected[pid]) duplicates += 1 else violations += 1;
            }
            expected[pid] = seq + 1;
            received[pid] += 1;
            total += 1;
        }
        if (n == 0) std.atomic.spinLoopHint();
    }
    const ns: u64 = @intCast(std.time.nanoTimestamp() - t0);

    for (&threads) |*t| t.join();

    var missing: u64 = 0;
    for (received) |r| missing += MSG - r;

    const ok = violations == 0 and duplicates == 0 and missing == 0;
    std.debug.print("Results:\n", .{});
    std.debug.print("  Order violations:     {d}\n", .{violations});
    std.debug.print("  Duplicate messages:   {d}\n", .{duplicates});
    std.debug.print("  Missing messages:     {d}\n", .{missing});
    std.debug.print("  Throughput:           {d:.0} M/s\n", .{@as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(ns)) * 1000});
    std.debug.print("\nConclusion: {s}\n", .{if (ok) "ALL PROPERTIES VERIFIED" else "FAILED - CORRECTNESS VIOLATIONS DETECTED"});
    std.debug.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
}

fn producer(id: usize) void {
    pin(id);
    const p = channel.register() catch return;

    const tag: u64 = @as(u64, id) << 56;
    var seq: u64 = 0;
    while (seq < MSG) {
        if (p.reserve(1)) |r| {
            r.slice[0] = tag | seq;
            p.commit(1);
            seq += 1;
        } else std.atomic.spinLoopHint();
    }
}

fn pin(cpu: usize) void {
    const max = std.Thread.getCpuCount() catch 16;
    var set = std.mem.zeroes(std.os.linux.cpu_set_t);
    const c = cpu % max;
    set[c / 64] |= @as(u64, 1) << @as(u6, @intCast(c % 64));
    _ = std.os.linux.sched_setaffinity(0, &set) catch {};
}
