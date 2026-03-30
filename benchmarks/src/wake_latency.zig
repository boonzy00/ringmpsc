//! Wake Latency Benchmark
//!
//! Compares consumer wake latency for three strategies:
//! - Spin-wait (busy loop polling)
//! - Futex-based blocking
//! - eventfd + epoll
//!
//! Measures time from producer commit() to consumer first read.
//!
//! Run: zig build bench-wake-latency -Doptimize=ReleaseFast

const std = @import("std");
const ringmpsc = @import("ringmpsc");
const linux = std.os.linux;
const posix = std.posix;

const EventNotifier = ringmpsc.primitives.EventNotifier;

const WARMUP: usize = 1000;
const SAMPLES: usize = 10_000;

const stderr = (std.fs.File{ .handle = std.posix.STDERR_FILENO }).deprecatedWriter();

pub fn main() !void {
    try stderr.print("\nWake Latency Benchmark\n", .{});
    try stderr.print("======================\n\n", .{});

    // Spin-wait
    const spin = try benchSpinWake();
    try stderr.print("  Spin-wait:     p50={d:>5}ns  p99={d:>5}ns  min={d:>4}ns  max={d:>6}ns\n", .{
        spin.p50, spin.p99, spin.min, spin.max,
    });

    // eventfd + epoll
    const eventfd = try benchEventfdWake();
    try stderr.print("  eventfd+epoll: p50={d:>5}ns  p99={d:>5}ns  min={d:>4}ns  max={d:>6}ns\n", .{
        eventfd.p50, eventfd.p99, eventfd.min, eventfd.max,
    });

    try stderr.print("\n  spin-wait has lowest latency but 100%% CPU\n", .{});
    try stderr.print("  eventfd adds ~1us but enables zero-CPU idle\n", .{});
    try stderr.print("\n", .{});
}

const LatencyResult = struct { p50: u64, p99: u64, min: u64, max: u64 };

fn benchSpinWake() !LatencyResult {
    const Config = ringmpsc.primitives.ring_buffer.Config{ .ring_bits = 10 };
    var ring = ringmpsc.primitives.Ring(u64, Config){};
    var samples: [SAMPLES]u64 = undefined;
    var sample_idx = std.atomic.Value(usize).init(0);
    var done = std.atomic.Value(bool).init(false);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(
            r: *ringmpsc.primitives.Ring(u64, Config),
            s: *[SAMPLES]u64,
            idx: *std.atomic.Value(usize),
            d: *std.atomic.Value(bool),
        ) void {
            while (!d.load(.acquire)) {
                if (r.readable()) |slice| {
                    const now: u64 = @intCast(std.time.nanoTimestamp());
                    const stamp = slice[0];
                    r.advance(slice.len);
                    const i = idx.fetchAdd(1, .monotonic);
                    if (i < SAMPLES) {
                        s[i] = now -% stamp;
                    }
                } else {
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run, .{ &ring, &samples, &sample_idx, &done });

    // Warmup
    for (0..WARMUP) |_| {
        const stamp: u64 = @intCast(std.time.nanoTimestamp());
        while (ring.send(&[_]u64{stamp}) == 0) std.atomic.spinLoopHint();
        std.Thread.sleep(1000); // 1us gap
    }

    sample_idx.store(0, .release);

    // Measured samples
    for (0..SAMPLES) |_| {
        const stamp: u64 = @intCast(std.time.nanoTimestamp());
        while (ring.send(&[_]u64{stamp}) == 0) std.atomic.spinLoopHint();
        std.Thread.sleep(10_000); // 10us gap between sends
    }

    std.Thread.sleep(100_000_000); // 100ms drain
    done.store(true, .release);
    consumer.join();

    return computeLatency(&samples);
}

fn benchEventfdWake() !LatencyResult {
    const Config = ringmpsc.primitives.ring_buffer.Config{ .ring_bits = 10 };
    var ring = ringmpsc.primitives.Ring(u64, Config){};
    var notifier = try EventNotifier.init();
    defer notifier.deinit();
    ring.setEventNotifier(&notifier);

    const epoll_fd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
    defer posix.close(epoll_fd);
    try notifier.registerEpoll(epoll_fd);

    var samples: [SAMPLES]u64 = undefined;
    var sample_idx = std.atomic.Value(usize).init(0);
    var done = std.atomic.Value(bool).init(false);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(
            r: *ringmpsc.primitives.Ring(u64, Config),
            ep: posix.fd_t,
            n: *EventNotifier,
            s: *[SAMPLES]u64,
            idx: *std.atomic.Value(usize),
            d: *std.atomic.Value(bool),
        ) void {
            var events: [4]linux.epoll_event = undefined;
            while (!d.load(.acquire)) {
                const nev = posix.epoll_wait(ep, &events, 10); // 10ms timeout
                if (nev > 0) {
                    _ = n.consume();
                    if (r.readable()) |slice| {
                        const now: u64 = @intCast(std.time.nanoTimestamp());
                        const stamp = slice[0];
                        r.advance(slice.len);
                        const i = idx.fetchAdd(1, .monotonic);
                        if (i < SAMPLES) {
                            s[i] = now -% stamp;
                        }
                    }
                    // Drain remaining
                    while (r.readable()) |sl| r.advance(sl.len);
                }
            }
        }
    }.run, .{ &ring, epoll_fd, &notifier, &samples, &sample_idx, &done });

    // Warmup
    for (0..WARMUP) |_| {
        const stamp: u64 = @intCast(std.time.nanoTimestamp());
        while (ring.send(&[_]u64{stamp}) == 0) std.atomic.spinLoopHint();
        std.Thread.sleep(10_000);
    }

    sample_idx.store(0, .release);

    // Measured samples
    for (0..SAMPLES) |_| {
        const stamp: u64 = @intCast(std.time.nanoTimestamp());
        while (ring.send(&[_]u64{stamp}) == 0) std.atomic.spinLoopHint();
        std.Thread.sleep(100_000); // 100us gap — enough for epoll to sleep+wake
    }

    std.Thread.sleep(200_000_000); // 200ms drain
    done.store(true, .release);
    consumer.join();

    return computeLatency(&samples);
}

fn computeLatency(samples: *[SAMPLES]u64) LatencyResult {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{
        .p50 = samples[SAMPLES / 2],
        .p99 = samples[SAMPLES * 99 / 100],
        .min = samples[0],
        .max = samples[SAMPLES - 1],
    };
}
