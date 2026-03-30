//! ringmpsc — Benchmark Suite
//!
//! Multi-run statistics, competitive baselines, environment capture,
//! regression detection, and a self-contained HTML report with inline SVG charts.
//!
//! Usage:
//!   zig build bench                          # Run full suite
//!   sudo taskset -c 0-15 nice -n -20 zig-out/bin/bench  # Clean run
//!
//! Output:
//!   Console:  Summary table with median ± range
//!   HTML:     benchmarks/results/bench.html
//!   JSON:     benchmarks/results/baseline.json (for regression detection)

const std = @import("std");
const ringmpsc = @import("ringmpsc");
const report = @import("report.zig");

// ============================================================================
// CONFIGURATION
// ============================================================================

const RUNS: usize = 7; // Odd for clean median, enough for stable percentiles
const WARMUP_RUNS: usize = 2; // Discarded before measurement
const COOLDOWN_MS: u64 = 2000; // Between configs to prevent thermal throttle
const CPU_COUNT: usize = 16;
const MAX_PRODUCERS: usize = 8;
const RING_BITS: u6 = 15;
const BATCH_SIZE: usize = 32768;
const BATCH_MSG_COUNT: u64 = 100_000_000; // Per producer, batch mode (needs ≥50M for steady state)
const SINGLE_MSG_COUNT: u64 = 5_000_000; // Total, single-item mode
const LATENCY_WARMUP: u64 = 10_000;
const LATENCY_SAMPLES: u64 = 100_000;

const PRODUCER_COUNTS = [_]usize{ 1, 2, 4, 6, 8 };
const BATCH_SIZES = [_]usize{ 1, 64, 1024, 4096, 32768 };
const RING_BITS_SWEEP = [_]u6{ 10, 12, 14, 15, 16, 18 };

// ============================================================================
// STATISTICS
// ============================================================================

const Stats = struct {
    median: f64,
    min: f64,
    max: f64,
    mean: f64,
    stddev: f64,
    cv: f64, // coefficient of variation (%)
    runs: [RUNS]f64,
};

fn computeStats(values: *[RUNS]f64) Stats {
    // Sort for median
    var sorted: [RUNS]f64 = values.*;
    for (0..RUNS) |i| {
        for (i + 1..RUNS) |j| {
            if (sorted[j] < sorted[i]) {
                const tmp = sorted[i];
                sorted[i] = sorted[j];
                sorted[j] = tmp;
            }
        }
    }

    const median = sorted[RUNS / 2];
    const min_val = sorted[0];
    const max_val = sorted[RUNS - 1];

    var sum: f64 = 0;
    for (sorted) |v| sum += v;
    const mean_val = sum / @as(f64, RUNS);

    var sq_sum: f64 = 0;
    for (sorted) |v| {
        const d = v - mean_val;
        sq_sum += d * d;
    }
    // Bessel's correction: divide by N-1 for sample stddev
    const stddev = @sqrt(sq_sum / @as(f64, RUNS - 1));
    const cv = if (mean_val > 0) stddev / mean_val * 100 else 0;

    return .{
        .median = median,
        .min = min_val,
        .max = max_val,
        .mean = mean_val,
        .stddev = stddev,
        .cv = cv,
        .runs = values.*,
    };
}

fn sortU64(slice: []u64) void {
    std.mem.sort(u64, slice, {}, std.sort.asc(u64));
}

fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const idx: usize = @intFromFloat(p * @as(f64, @floatFromInt(sorted.len - 1)));
    return sorted[@min(idx, sorted.len - 1)];
}

// ============================================================================
// ENVIRONMENT CAPTURE
// ============================================================================

const Environment = struct {
    cpu_model: [128]u8 = .{0} ** 128,
    cpu_model_len: usize = 0,
    kernel: [64]u8 = .{0} ** 64,
    kernel_len: usize = 0,
    governor: [32]u8 = .{0} ** 32,
    governor_len: usize = 0,
    zig_version: []const u8 = @import("builtin").zig_version_string,
    cores: usize = CPU_COUNT,
};

fn captureEnvironment() Environment {
    var env = Environment{};

    // CPU model from /proc/cpuinfo
    if (std.fs.cwd().openFile("/proc/cpuinfo", .{})) |file| {
        defer file.close();
        var buf: [4096]u8 = undefined;
        const n = file.read(&buf) catch 0;
        const content = buf[0..n];
        if (std.mem.indexOf(u8, content, "model name")) |start| {
            if (std.mem.indexOfPos(u8, content, start, ": ")) |colon| {
                const val_start = colon + 2;
                if (std.mem.indexOfPos(u8, content, val_start, "\n")) |end| {
                    const name = content[val_start..end];
                    const len = @min(name.len, env.cpu_model.len);
                    @memcpy(env.cpu_model[0..len], name[0..len]);
                    env.cpu_model_len = len;
                }
            }
        }
    } else |_| {}

    // Kernel version
    if (std.fs.cwd().openFile("/proc/version", .{})) |file| {
        defer file.close();
        var buf: [256]u8 = undefined;
        const n = file.read(&buf) catch 0;
        const content = buf[0..n];
        // First 3 space-delimited tokens: "Linux version X.Y.Z-..."
        var count: usize = 0;
        var end: usize = 0;
        for (content, 0..) |c, i| {
            if (c == ' ') {
                count += 1;
                if (count == 3) {
                    end = i;
                    break;
                }
            }
        }
        if (end > 0) {
            const len = @min(end, env.kernel.len);
            @memcpy(env.kernel[0..len], content[0..len]);
            env.kernel_len = len;
        }
    } else |_| {}

    // CPU governor
    if (std.fs.cwd().openFile("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", .{})) |file| {
        defer file.close();
        var buf: [32]u8 = undefined;
        const n = file.read(&buf) catch 0;
        var len = n;
        while (len > 0 and (buf[len - 1] == '\n' or buf[len - 1] == '\r')) len -= 1;
        const clen = @min(len, env.governor.len);
        @memcpy(env.governor[0..clen], buf[0..clen]);
        env.governor_len = clen;
    } else |_| {}

    return env;
}

fn envStr(buf: anytype, len: usize) []const u8 {
    return if (len > 0) buf[0..len] else "unknown";
}

// ============================================================================
// CPU PINNING
// ============================================================================

fn pin(cpu: usize) void {
    if (comptime @import("builtin").os.tag != .linux) return;
    const actual = cpu % CPU_COUNT;
    var set = std.mem.zeroes(std.os.linux.cpu_set_t);
    set[actual / 64] |= @as(u64, 1) << @as(u6, @intCast(actual % 64));
    std.os.linux.sched_setaffinity(0, &set) catch {};
}

// ============================================================================
// BASELINES
// ============================================================================

fn CachedSpscRing(comptime T: type, comptime bits: u6) type {
    const cap = 1 << bits;
    const mask = cap - 1;
    return struct {
        const Self = @This();
        buf: [cap]T align(64) = undefined,
        head: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        cached_head: usize = 0,
        tail: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        cached_tail: usize = 0,

        fn push(self: *Self, val: T) bool {
            const t = self.tail.load(.monotonic);
            const next = t +% 1;
            if (next == self.cached_head) {
                self.cached_head = self.head.load(.acquire);
                if (next == self.cached_head) return false;
            }
            self.buf[t & mask] = val;
            self.tail.store(next, .release);
            return true;
        }

        fn pop(self: *Self) ?T {
            const h = self.head.load(.monotonic);
            if (h == self.cached_tail) {
                self.cached_tail = self.tail.load(.acquire);
                if (h == self.cached_tail) return null;
            }
            const val = self.buf[h & mask];
            self.head.store(h +% 1, .release);
            return val;
        }

        fn pushBatch(self: *Self, count: usize, val: T) usize {
            const t = self.tail.load(.monotonic);
            var avail = cap - (t -% self.cached_head);
            if (avail == 0) {
                self.cached_head = self.head.load(.acquire);
                avail = cap - (t -% self.cached_head);
                if (avail == 0) return 0;
            }
            const n = @min(count, avail);
            const start = t & mask;
            if (start + n <= cap) {
                @memset(self.buf[start..][0..n], val);
            } else {
                const first = cap - start;
                @memset(self.buf[start..cap], val);
                @memset(self.buf[0 .. n - first], val);
            }
            self.tail.store(t +% n, .release);
            return n;
        }

        fn popBatchCount(self: *Self) usize {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            const avail = t -% h;
            if (avail == 0) return 0;
            self.head.store(t, .release);
            return avail;
        }
    };
}

fn CasMpscQueue(comptime T: type, comptime bits: u6) type {
    const cap = 1 << bits;
    const mask = cap - 1;
    return struct {
        const Self = @This();
        const Cell = struct {
            seq: std.atomic.Value(usize) align(64),
            data: T,
        };
        cells: [cap]Cell = init: {
            @setEvalBranchQuota(cap * 4);
            var c: [cap]Cell = undefined;
            for (0..cap) |i| {
                c[i] = .{ .seq = std.atomic.Value(usize).init(i), .data = undefined };
            }
            break :init c;
        },
        enqueue_pos: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        dequeue_pos: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),

        fn push(self: *Self, val: T) bool {
            var pos = self.enqueue_pos.load(.monotonic);
            while (true) {
                const cell = &self.cells[pos & mask];
                const seq = cell.seq.load(.acquire);
                const diff = @as(isize, @bitCast(seq -% pos));
                if (diff == 0) {
                    if (self.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |new_pos| {
                        pos = new_pos;
                        continue;
                    }
                    cell.data = val;
                    cell.seq.store(pos +% 1, .release);
                    return true;
                } else if (diff < 0) {
                    return false;
                } else {
                    pos = self.enqueue_pos.load(.monotonic);
                }
            }
        }

        fn pop(self: *Self) ?T {
            const pos = self.dequeue_pos.load(.monotonic);
            const cell = &self.cells[pos & mask];
            const seq = cell.seq.load(.acquire);
            const diff = @as(isize, @bitCast(seq -% (pos +% 1)));
            if (diff == 0) {
                self.dequeue_pos.store(pos +% 1, .monotonic);
                const val = cell.data;
                cell.seq.store(pos +% cap, .release);
                return val;
            }
            return null;
        }
    };
}

fn MutexQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        buf: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        mutex: std.Thread.Mutex = .{},

        fn push(self: *Self, item: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count >= capacity) return false;
            self.buf[self.tail % capacity] = item;
            self.tail +%= 1;
            self.count += 1;
            return true;
        }

        fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count == 0) return null;
            const item = self.buf[self.head % capacity];
            self.head +%= 1;
            self.count -= 1;
            return item;
        }

        fn pushBatch(self: *Self, count: usize, val: T) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            const avail = capacity - self.count;
            if (avail == 0) return 0;
            const n = @min(count, avail);
            const start = self.tail % capacity;
            if (start + n <= capacity) {
                @memset(self.buf[start..][0..n], val);
            } else {
                const first = capacity - start;
                @memset(self.buf[start..capacity], val);
                @memset(self.buf[0 .. n - first], val);
            }
            self.tail +%= n;
            self.count += n;
            return n;
        }

        fn popBatchCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            const n = self.count;
            self.head +%= n;
            self.count = 0;
            return n;
        }
    };
}

// ============================================================================
// RESULT TYPES
// ============================================================================

const BatchScalingResult = struct {
    ringmpsc: [PRODUCER_COUNTS.len]Stats,
    cached: [PRODUCER_COUNTS.len]Stats,
    mutex: [PRODUCER_COUNTS.len]Stats,
};

const MpscScalingResult = struct {
    ringmpsc: [PRODUCER_COUNTS.len]Stats,
    cas: [PRODUCER_COUNTS.len]Stats,
    mutex: [PRODUCER_COUNTS.len]Stats,
};

const LatencyStats = struct {
    p50: u64,
    p90: u64,
    p99: u64,
    p999: u64,
    min: u64,
    max: u64,
    avg: u64,
};

const BatchSweepResult = struct {
    stats: [BATCH_SIZES.len]Stats,
};

const RingSweepResult = struct {
    stats: [RING_BITS_SWEEP.len]Stats,
};

// ============================================================================
// MAIN
// ============================================================================

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const env = captureEnvironment();

    std.debug.print("\n", .{});
    std.debug.print("ringmpsc benchmark suite\n", .{});
    std.debug.print("========================\n", .{});
    std.debug.print("  Zig {s}, ReleaseFast, {d} runs per benchmark\n", .{ env.zig_version, RUNS });
    std.debug.print("  CPU: {s}\n", .{envStr(&env.cpu_model, env.cpu_model_len)});
    std.debug.print("  Governor: {s}\n", .{envStr(&env.governor, env.governor_len)});
    std.debug.print("\n", .{});

    // ── 1. Batch Throughput Scaling (u32) ────────────────────────────────
    std.debug.print("1. Batch Throughput Scaling (u32, {d}M msgs/producer, {d} runs)\n", .{
        BATCH_MSG_COUNT / 1_000_000, RUNS,
    });
    const batch_u32 = try benchBatchScaling(u32);
    printBatchScaling(&batch_u32);

    // ── 2. Batch Throughput Scaling (u64) ────────────────────────────────
    std.debug.print("2. Batch Throughput Scaling (u64, {d}M msgs/producer, {d} runs)\n", .{
        BATCH_MSG_COUNT / 1_000_000, RUNS,
    });
    const batch_u64 = try benchBatchScaling(u64);
    printBatchScaling(&batch_u64);

    // ── 3. MPSC Single-Item Scaling ─────────────────────────────────────
    std.debug.print("3. MPSC Single-Item Scaling ({d}M msgs total, {d} runs)\n", .{
        SINGLE_MSG_COUNT / 1_000_000, RUNS,
    });
    const mpsc = try benchMpscScaling();
    printMpscScaling(&mpsc);

    // ── 4. SPSC Latency ─────────────────────────────────────────────────
    std.debug.print("4. SPSC Round-Trip Latency ({d}K samples)\n", .{LATENCY_SAMPLES / 1000});
    const latency = try benchSpscLatency();
    std.debug.print("   ringmpsc   p50={d}ns  p99={d}ns  min={d}ns  max={d}ns\n", .{
        latency.p50, latency.p99, latency.min, latency.max,
    });
    std.debug.print("\n", .{});

    // ── 5. Batch Size Sweep ─────────────────────────────────────────────
    std.debug.print("5. Batch Size Sweep (1P1C u32, {d} runs)\n", .{RUNS});
    const batch_sweep = try benchBatchSizeSweep();
    printBatchSweep(&batch_sweep);

    // ── 6. Ring Size Sweep ──────────────────────────────────────────────
    std.debug.print("6. Ring Size Sweep (1P1C u32, batch={d}, {d} runs)\n", .{ BATCH_SIZE, RUNS });
    const ring_sweep = try benchRingSizeSweep();
    printRingSweep(&ring_sweep);

    // ── Generate Report ─────────────────────────────────────────────────
    std.debug.print("Generating report...\n", .{});
    try generateReport(allocator, &env, &batch_u32, &batch_u64, &mpsc, &latency, &batch_sweep, &ring_sweep);

    // ── Save Baseline JSON ──────────────────────────────────────────────
    try saveBaseline(allocator, &batch_u32, &batch_u64, &mpsc, &latency);

    std.debug.print("\nDone. Report: benchmarks/results/bench.html\n", .{});
    std.debug.print("           Baseline: benchmarks/results/baseline.json\n\n", .{});
}

// ============================================================================
// CONSOLE OUTPUT
// ============================================================================

fn printBatchScaling(result: *const BatchScalingResult) void {
    std.debug.print("   {s:<12}", .{""});
    for (PRODUCER_COUNTS) |p| {
        std.debug.print(" {d}P1C    ", .{p});
    }
    std.debug.print("\n", .{});
    printStatsRow("ringmpsc", &result.ringmpsc, "B/s");
    printStatsRow("Cached SPSC", &result.cached, "B/s");
    printStatsRow("Mutex", &result.mutex, "B/s");
    std.debug.print("\n", .{});
}

fn printMpscScaling(result: *const MpscScalingResult) void {
    std.debug.print("   {s:<12}", .{""});
    for (PRODUCER_COUNTS) |p| {
        std.debug.print(" {d}P1C    ", .{p});
    }
    std.debug.print("\n", .{});
    printStatsRow("ringmpsc", &result.ringmpsc, "M/s");
    printStatsRow("CAS MPSC", &result.cas, "M/s");
    printStatsRow("Mutex", &result.mutex, "M/s");
    std.debug.print("\n", .{});
}

fn printStatsRow(name: []const u8, stats: anytype, unit: []const u8) void {
    std.debug.print("   {s:<12}", .{name});
    for (stats) |s| {
        std.debug.print(" {:>5.1}{s}", .{ s.median, unit });
    }
    std.debug.print("  (CV: {d:.1}%)\n", .{stats[stats.len - 1].cv});
}

fn printBatchSweep(result: *const BatchSweepResult) void {
    for (BATCH_SIZES, 0..) |bs, i| {
        const s = result.stats[i];
        std.debug.print("   batch={d:<6}  {d:.2} B/s  (±{d:.2}, CV {d:.1}%)\n", .{
            bs, s.median, s.max - s.min, s.cv,
        });
    }
    std.debug.print("\n", .{});
}

fn printRingSweep(result: *const RingSweepResult) void {
    for (RING_BITS_SWEEP, 0..) |bits, i| {
        const s = result.stats[i];
        const size_kb = (@as(u64, 1) << bits) * 4 / 1024;
        std.debug.print("   bits={d:<3} ({d}KB)  {d:.2} B/s  (±{d:.2}, CV {d:.1}%)\n", .{
            bits, size_kb, s.median, s.max - s.min, s.cv,
        });
    }
    std.debug.print("\n", .{});
}

// ============================================================================
// BENCHMARK: BATCH THROUGHPUT SCALING
// ============================================================================

fn benchBatchScaling(comptime T: type) !BatchScalingResult {
    var result: BatchScalingResult = undefined;

    for (PRODUCER_COUNTS, 0..) |p, pi| {
        var ringmpsc_runs: [RUNS]f64 = undefined;
        var cached_runs: [RUNS]f64 = undefined;
        var mutex_runs: [RUNS]f64 = undefined;

        // Warmup runs (discarded — JIT-equivalent: populates caches, TLB, branch predictors)
        for (0..WARMUP_RUNS) |_| {
            _ = try runRingmpscBatch(T, p);
            _ = try runCachedBatch(T, p);
            _ = try runMutexBatch(T, p);
        }

        for (0..RUNS) |r| {
            ringmpsc_runs[r] = try runRingmpscBatch(T, p);
            cached_runs[r] = try runCachedBatch(T, p);
            mutex_runs[r] = try runMutexBatch(T, p);
        }

        result.ringmpsc[pi] = computeStats(&ringmpsc_runs);
        result.cached[pi] = computeStats(&cached_runs);
        result.mutex[pi] = computeStats(&mutex_runs);

        // Cooldown between configs to prevent thermal throttle
        std.Thread.sleep(COOLDOWN_MS * 1_000_000);
    }

    return result;
}

fn runRingmpscBatch(comptime T: type, num_producers: usize) !f64 {
    const Config = ringmpsc.mpsc.Config{
        .ring_bits = RING_BITS,
        .max_producers = MAX_PRODUCERS,
        .enable_metrics = false,
        .prefetch_threshold = 0,
    };
    const Chan = ringmpsc.mpsc.Channel(T, Config);
    const RingType = ringmpsc.primitives.Ring(T, Config);

    var channel = try Chan.init(std.heap.page_allocator);
    defer channel.deinit();

    var producers: [MAX_PRODUCERS]Chan.Producer = undefined;
    var threads: [MAX_PRODUCERS]std.Thread = undefined;
    var start_barrier = std.atomic.Value(bool).init(false);
    var producers_done = std.atomic.Value(usize).init(0);
    var consumer_elapsed = std.atomic.Value(u64).init(0);

    for (0..num_producers) |i| {
        producers[i] = try channel.register();
    }

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(ch: *Chan, elapsed_out: *std.atomic.Value(u64), n_prod: usize, p_done: *std.atomic.Value(usize), barrier: *std.atomic.Value(bool)) void {
            pin(n_prod);
            while (!barrier.load(.acquire)) std.atomic.spinLoopHint();
            const t0 = std.time.Instant.now() catch unreachable;

            var rings: [MAX_PRODUCERS]*RingType = undefined;
            for (0..n_prod) |i| rings[i] = ch.rings[i];
            var count: u64 = 0;
            var idle: u32 = 0;

            while (true) {
                var batch: usize = 0;
                for (rings[0..n_prod]) |ring| {
                    const h = ring.head.load(.monotonic);
                    const t = ring.tail.load(.acquire);
                    const avail = t -% h;
                    if (avail == 0) continue;
                    ring.head.store(t, .release);
                    batch += avail;
                }
                count += batch;
                if (batch == 0) {
                    idle += 1;
                    if (idle > 64) {
                        if (p_done.load(.acquire) >= n_prod and ch.isClosed()) {
                            for (rings[0..n_prod]) |ring| {
                                const h = ring.head.load(.monotonic);
                                const t = ring.tail.load(.acquire);
                                count += t -% h;
                                ring.head.store(t, .release);
                            }
                            break;
                        }
                        idle = 0;
                    }
                    std.atomic.spinLoopHint();
                } else idle = 0;
            }
            elapsed_out.store((std.time.Instant.now() catch unreachable).since(t0), .release);
        }
    }.run, .{ &channel, &consumer_elapsed, num_producers, &producers_done, &start_barrier });

    for (0..num_producers) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(prod: *Chan.Producer, cpu: usize, barrier: *std.atomic.Value(bool), p_done: *std.atomic.Value(usize)) void {
                pin(cpu);
                while (!barrier.load(.acquire)) std.atomic.spinLoopHint();
                const ring = prod.ring;
                var sent: u64 = 0;
                while (sent < BATCH_MSG_COUNT) {
                    const want = @min(BATCH_SIZE, BATCH_MSG_COUNT - sent);
                    if (ring.reserve(want)) |r| {
                        @memset(r.slice, @as(T, @truncate(sent)));
                        ring.commit(r.slice.len);
                        sent += r.slice.len;
                    } else std.atomic.spinLoopHint();
                }
                _ = p_done.fetchAdd(1, .release);
            }
        }.run, .{ &producers[i], i, &start_barrier, &producers_done });
    }

    start_barrier.store(true, .seq_cst);
    for (0..num_producers) |i| threads[i].join();
    channel.close();
    consumer.join();

    const elapsed_ns = consumer_elapsed.load(.acquire);
    const total = BATCH_MSG_COUNT * num_producers;
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(elapsed_ns));
}

fn runCachedBatch(comptime T: type, num_producers: usize) !f64 {
    const Ring = CachedSpscRing(T, RING_BITS);

    var rings: [MAX_PRODUCERS]Ring = undefined;
    for (0..num_producers) |i| rings[i] = Ring{};
    var ring_ptrs: [MAX_PRODUCERS]*Ring = undefined;
    for (0..num_producers) |i| ring_ptrs[i] = &rings[i];

    var threads: [MAX_PRODUCERS]std.Thread = undefined;
    var start_barrier = std.atomic.Value(bool).init(false);
    var producers_done = std.atomic.Value(usize).init(0);
    var consumer_elapsed = std.atomic.Value(u64).init(0);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(ptrs: []const *Ring, elapsed_out: *std.atomic.Value(u64), p_done: *std.atomic.Value(usize), barrier: *std.atomic.Value(bool)) void {
            pin(ptrs.len);
            while (!barrier.load(.acquire)) std.atomic.spinLoopHint();
            const t0 = std.time.Instant.now() catch unreachable;
            var count: u64 = 0;
            var idle: u32 = 0;
            while (true) {
                var batch: usize = 0;
                for (ptrs) |ring| batch += ring.popBatchCount();
                count += batch;
                if (batch == 0) {
                    idle += 1;
                    if (idle > 64) {
                        if (p_done.load(.acquire) >= ptrs.len) {
                            for (ptrs) |ring| count += ring.popBatchCount();
                            break;
                        }
                        idle = 0;
                    }
                    std.atomic.spinLoopHint();
                } else idle = 0;
            }
            elapsed_out.store((std.time.Instant.now() catch unreachable).since(t0), .release);
        }
    }.run, .{ ring_ptrs[0..num_producers], &consumer_elapsed, &producers_done, &start_barrier });

    for (0..num_producers) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(ring: *Ring, cpu: usize, barrier: *std.atomic.Value(bool), p_done: *std.atomic.Value(usize)) void {
                pin(cpu);
                while (!barrier.load(.acquire)) std.atomic.spinLoopHint();
                var sent: u64 = 0;
                while (sent < BATCH_MSG_COUNT) {
                    const want = @min(BATCH_SIZE, BATCH_MSG_COUNT - sent);
                    const n = ring.pushBatch(want, 0);
                    if (n > 0) sent += n else std.atomic.spinLoopHint();
                }
                _ = p_done.fetchAdd(1, .release);
            }
        }.run, .{ &rings[i], i, &start_barrier, &producers_done });
    }

    start_barrier.store(true, .seq_cst);
    for (0..num_producers) |i| threads[i].join();
    consumer.join();

    const elapsed_ns = consumer_elapsed.load(.acquire);
    const total = BATCH_MSG_COUNT * num_producers;
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(elapsed_ns));
}

fn runMutexBatch(comptime T: type, num_producers: usize) !f64 {
    const cap = 1 << RING_BITS;
    const Q = MutexQueue(T, cap);

    var queues: [MAX_PRODUCERS]Q = undefined;
    for (0..num_producers) |i| queues[i] = Q{};
    var queue_ptrs: [MAX_PRODUCERS]*Q = undefined;
    for (0..num_producers) |i| queue_ptrs[i] = &queues[i];

    var threads: [MAX_PRODUCERS]std.Thread = undefined;
    var start_barrier = std.atomic.Value(bool).init(false);
    var producers_done = std.atomic.Value(usize).init(0);
    var consumer_elapsed = std.atomic.Value(u64).init(0);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(ptrs: []const *Q, elapsed_out: *std.atomic.Value(u64), p_done: *std.atomic.Value(usize), barrier: *std.atomic.Value(bool)) void {
            pin(ptrs.len);
            while (!barrier.load(.acquire)) std.atomic.spinLoopHint();
            const t0 = std.time.Instant.now() catch unreachable;
            var count: u64 = 0;
            var idle: u32 = 0;
            while (true) {
                var batch: usize = 0;
                for (ptrs) |queue| batch += queue.popBatchCount();
                count += batch;
                if (batch == 0) {
                    idle += 1;
                    if (idle > 64) {
                        if (p_done.load(.acquire) >= ptrs.len) {
                            for (ptrs) |queue| count += queue.popBatchCount();
                            break;
                        }
                        idle = 0;
                    }
                    std.atomic.spinLoopHint();
                } else idle = 0;
            }
            elapsed_out.store((std.time.Instant.now() catch unreachable).since(t0), .release);
        }
    }.run, .{ queue_ptrs[0..num_producers], &consumer_elapsed, &producers_done, &start_barrier });

    for (0..num_producers) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(queue: *Q, cpu: usize, barrier: *std.atomic.Value(bool), p_done: *std.atomic.Value(usize)) void {
                pin(cpu);
                while (!barrier.load(.acquire)) std.atomic.spinLoopHint();
                var sent: u64 = 0;
                while (sent < BATCH_MSG_COUNT) {
                    const want = @min(BATCH_SIZE, BATCH_MSG_COUNT - sent);
                    const n = queue.pushBatch(want, 0);
                    if (n > 0) sent += n else std.atomic.spinLoopHint();
                }
                _ = p_done.fetchAdd(1, .release);
            }
        }.run, .{ &queues[i], i, &start_barrier, &producers_done });
    }

    start_barrier.store(true, .seq_cst);
    for (0..num_producers) |i| threads[i].join();
    consumer.join();

    const elapsed_ns = consumer_elapsed.load(.acquire);
    const total = BATCH_MSG_COUNT * num_producers;
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(elapsed_ns));
}

// ============================================================================
// BENCHMARK: MPSC SINGLE-ITEM SCALING
// ============================================================================

fn benchMpscScaling() !MpscScalingResult {
    var result: MpscScalingResult = undefined;

    for (PRODUCER_COUNTS, 0..) |p, pi| {
        var ring_runs: [RUNS]f64 = undefined;
        var cas_runs: [RUNS]f64 = undefined;
        var mutex_runs: [RUNS]f64 = undefined;

        // Warmup runs (discarded)
        for (0..WARMUP_RUNS) |_| {
            _ = try runMpscRingmpsc(p);
            _ = try runMpscCas(p);
            _ = try runMpscMutex(p);
        }

        for (0..RUNS) |r| {
            ring_runs[r] = try runMpscRingmpsc(p);
            cas_runs[r] = try runMpscCas(p);
            mutex_runs[r] = try runMpscMutex(p);
        }

        result.ringmpsc[pi] = computeStats(&ring_runs);
        result.cas[pi] = computeStats(&cas_runs);
        result.mutex[pi] = computeStats(&mutex_runs);

        // Cooldown between configs
        std.Thread.sleep(COOLDOWN_MS * 1_000_000);
    }

    return result;
}

fn runMpscRingmpsc(num_producers: usize) !f64 {
    const Config = ringmpsc.mpsc.Config{ .ring_bits = RING_BITS, .max_producers = MAX_PRODUCERS, .enable_metrics = false };
    var channel = try ringmpsc.mpsc.Channel(u32, Config).init(std.heap.page_allocator);
    defer channel.deinit();
    const msgs_per_producer = SINGLE_MSG_COUNT / num_producers;
    var consumer_count = std.atomic.Value(u64).init(0);
    var producer_done = std.atomic.Value(usize).init(0);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(ch: anytype, count: *std.atomic.Value(u64), p_done: *std.atomic.Value(usize), n_prod: usize) void {
            pin(@intCast(n_prod));
            var c: u64 = 0;
            while (true) {
                const n = ch.consumeAllCount();
                c += n;
                if (n == 0 and p_done.load(.acquire) >= n_prod) {
                    while (true) {
                        const f = ch.consumeAllCount();
                        if (f == 0) break;
                        c += f;
                    }
                    break;
                }
            }
            count.store(c, .release);
        }
    }.run, .{ &channel, &consumer_count, &producer_done, num_producers });

    const t0 = std.time.Instant.now() catch unreachable;
    var threads: [MAX_PRODUCERS]std.Thread = undefined;
    for (0..num_producers) |i| {
        const producer = try channel.register();
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(p: anytype, count: u64, cpu: usize, done: *std.atomic.Value(usize)) void {
                pin(cpu);
                var bo = ringmpsc.primitives.Backoff{};
                var sent: u64 = 0;
                while (sent < count) {
                    if (p.sendOne(@truncate(sent))) {
                        sent += 1;
                        bo.reset();
                    } else bo.snooze();
                }
                _ = done.fetchAdd(1, .release);
            }
        }.run, .{ producer, msgs_per_producer, i, &producer_done });
    }
    for (0..num_producers) |i| threads[i].join();
    channel.shutdown();
    consumer.join();
    const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
    return @as(f64, @floatFromInt(consumer_count.load(.acquire))) / @as(f64, @floatFromInt(elapsed)) * 1000;
}

fn runMpscCas(num_producers: usize) !f64 {
    const Q = CasMpscQueue(u32, RING_BITS);
    var q = Q{};
    const msgs_per_producer = SINGLE_MSG_COUNT / num_producers;
    var consumer_count = std.atomic.Value(u64).init(0);
    var producers_done = std.atomic.Value(usize).init(0);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(queue: *Q, count: *std.atomic.Value(u64), p_done: *std.atomic.Value(usize), n_prod: usize) void {
            pin(@intCast(n_prod));
            var c: u64 = 0;
            while (true) {
                if (queue.pop() != null) {
                    c += 1;
                } else if (p_done.load(.acquire) >= n_prod) {
                    while (queue.pop() != null) c += 1;
                    break;
                } else std.atomic.spinLoopHint();
            }
            count.store(c, .release);
        }
    }.run, .{ &q, &consumer_count, &producers_done, num_producers });

    const t0 = std.time.Instant.now() catch unreachable;
    var threads: [MAX_PRODUCERS]std.Thread = undefined;
    for (0..num_producers) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(queue: *Q, count: u64, cpu: usize, done: *std.atomic.Value(usize)) void {
                pin(cpu);
                var sent: u64 = 0;
                while (sent < count) {
                    if (queue.push(@truncate(sent))) sent += 1 else std.atomic.spinLoopHint();
                }
                _ = done.fetchAdd(1, .release);
            }
        }.run, .{ &q, msgs_per_producer, i, &producers_done });
    }
    for (0..num_producers) |i| threads[i].join();
    consumer.join();
    const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
    return @as(f64, @floatFromInt(consumer_count.load(.acquire))) / @as(f64, @floatFromInt(elapsed)) * 1000;
}

fn runMpscMutex(num_producers: usize) !f64 {
    const Q = MutexQueue(u32, 1 << RING_BITS);
    var q = Q{};
    const msgs_per_producer = SINGLE_MSG_COUNT / num_producers;
    var consumer_count = std.atomic.Value(u64).init(0);
    var producers_done = std.atomic.Value(usize).init(0);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(queue: *Q, count: *std.atomic.Value(u64), p_done: *std.atomic.Value(usize), n_prod: usize) void {
            pin(@intCast(n_prod));
            var c: u64 = 0;
            while (true) {
                if (queue.pop() != null) {
                    c += 1;
                } else if (p_done.load(.acquire) >= n_prod) {
                    while (queue.pop() != null) c += 1;
                    break;
                } else std.atomic.spinLoopHint();
            }
            count.store(c, .release);
        }
    }.run, .{ &q, &consumer_count, &producers_done, num_producers });

    const t0 = std.time.Instant.now() catch unreachable;
    var threads: [MAX_PRODUCERS]std.Thread = undefined;
    for (0..num_producers) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(queue: *Q, count: u64, cpu: usize, done: *std.atomic.Value(usize)) void {
                pin(cpu);
                var sent: u64 = 0;
                while (sent < count) {
                    if (queue.push(@truncate(sent))) sent += 1 else std.atomic.spinLoopHint();
                }
                _ = done.fetchAdd(1, .release);
            }
        }.run, .{ &q, msgs_per_producer, i, &producers_done });
    }
    for (0..num_producers) |i| threads[i].join();
    consumer.join();
    const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
    return @as(f64, @floatFromInt(consumer_count.load(.acquire))) / @as(f64, @floatFromInt(elapsed)) * 1000;
}

// ============================================================================
// BENCHMARK: SPSC LATENCY
// ============================================================================

fn benchSpscLatency() !LatencyStats {
    const Config = ringmpsc.spsc.Config{ .ring_bits = 12 };
    const Ring = ringmpsc.spsc.Channel(u32, Config);
    var q1 = Ring{};
    var q2 = Ring{};

    const responder = try std.Thread.spawn(.{}, struct {
        fn run(from: *Ring, to: *Ring) void {
            pin(1);
            for (0..LATENCY_WARMUP + LATENCY_SAMPLES) |_| {
                while (true) {
                    if (from.tryRecv()) |v| {
                        while (to.send(&[_]u32{v}) == 0) std.atomic.spinLoopHint();
                        break;
                    }
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.run, .{ &q1, &q2 });

    pin(0);
    // Warmup
    for (0..LATENCY_WARMUP) |i| {
        while (q1.send(&[_]u32{@truncate(i)}) == 0) std.atomic.spinLoopHint();
        while (q2.tryRecv() == null) std.atomic.spinLoopHint();
    }

    // Measure
    var samples: [LATENCY_SAMPLES]u64 = undefined;
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    for (0..LATENCY_SAMPLES) |i| {
        const t0 = std.time.Instant.now() catch unreachable;
        while (q1.send(&[_]u32{@truncate(i)}) == 0) std.atomic.spinLoopHint();
        while (q2.tryRecv() == null) std.atomic.spinLoopHint();
        const ns = (std.time.Instant.now() catch unreachable).since(t0);
        samples[i] = ns;
        total_ns += ns;
        min_ns = @min(min_ns, ns);
        max_ns = @max(max_ns, ns);
    }

    responder.join();
    sortU64(&samples);

    return .{
        .p50 = percentile(&samples, 0.50),
        .p90 = percentile(&samples, 0.90),
        .p99 = percentile(&samples, 0.99),
        .p999 = percentile(&samples, 0.999),
        .min = min_ns,
        .max = max_ns,
        .avg = total_ns / LATENCY_SAMPLES,
    };
}

// ============================================================================
// BENCHMARK: BATCH SIZE SWEEP
// ============================================================================

fn benchBatchSizeSweep() !BatchSweepResult {
    var result: BatchSweepResult = undefined;

    for (BATCH_SIZES, 0..) |bs, bi| {
        var runs: [RUNS]f64 = undefined;
        // Warmup
        for (0..WARMUP_RUNS) |_| _ = try runBatchSizeSingle(bs);
        for (0..RUNS) |r| {
            runs[r] = try runBatchSizeSingle(bs);
        }
        result.stats[bi] = computeStats(&runs);
        std.Thread.sleep(COOLDOWN_MS * 1_000_000);
    }

    return result;
}

fn runBatchSizeSingle(batch_size: usize) !f64 {
    const Config = ringmpsc.mpsc.Config{
        .ring_bits = RING_BITS,
        .max_producers = MAX_PRODUCERS,
        .enable_metrics = false,
        .prefetch_threshold = 0,
    };
    const Chan = ringmpsc.mpsc.Channel(u32, Config);
    const RingType = ringmpsc.primitives.Ring(u32, Config);
    const msg_count: u64 = 100_000_000;

    var channel = try Chan.init(std.heap.page_allocator);
    defer channel.deinit();

    var producer_obj = try channel.register();
    var start_barrier = std.atomic.Value(bool).init(false);
    var producer_done_flag = std.atomic.Value(bool).init(false);
    var consumer_elapsed = std.atomic.Value(u64).init(0);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(ch: *Chan, elapsed_out: *std.atomic.Value(u64), p_done: *std.atomic.Value(bool), barrier: *std.atomic.Value(bool)) void {
            pin(1);
            while (!barrier.load(.acquire)) std.atomic.spinLoopHint();
            const t0 = std.time.Instant.now() catch unreachable;
            const ring: *RingType = ch.rings[0];
            var count: u64 = 0;
            var idle: u32 = 0;
            while (true) {
                const h = ring.head.load(.monotonic);
                const t = ring.tail.load(.acquire);
                const avail = t -% h;
                if (avail > 0) {
                    ring.head.store(t, .release);
                    count += avail;
                    idle = 0;
                } else {
                    idle += 1;
                    if (idle > 64) {
                        if (p_done.load(.acquire)) {
                            const fh = ring.head.load(.monotonic);
                            const ft = ring.tail.load(.acquire);
                            count += ft -% fh;
                            ring.head.store(ft, .release);
                            break;
                        }
                        idle = 0;
                    }
                    std.atomic.spinLoopHint();
                }
            }
            elapsed_out.store((std.time.Instant.now() catch unreachable).since(t0), .release);
        }
    }.run, .{ &channel, &consumer_elapsed, &producer_done_flag, &start_barrier });

    const producer = try std.Thread.spawn(.{}, struct {
        fn run(prod: *Chan.Producer, bs: usize, barrier: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
            pin(0);
            while (!barrier.load(.acquire)) std.atomic.spinLoopHint();
            const ring = prod.ring;
            var sent: u64 = 0;
            while (sent < msg_count) {
                const want = @min(bs, msg_count - sent);
                if (ring.reserve(want)) |r| {
                    @memset(r.slice, 0);
                    ring.commit(r.slice.len);
                    sent += r.slice.len;
                } else std.atomic.spinLoopHint();
            }
            done.store(true, .release);
        }
    }.run, .{ &producer_obj, batch_size, &start_barrier, &producer_done_flag });

    start_barrier.store(true, .seq_cst);
    producer.join();
    consumer.join();

    const elapsed_ns = consumer_elapsed.load(.acquire);
    return @as(f64, @floatFromInt(msg_count)) / @as(f64, @floatFromInt(elapsed_ns));
}

// ============================================================================
// BENCHMARK: RING SIZE SWEEP
// ============================================================================

fn benchRingSizeSweep() !RingSweepResult {
    var result: RingSweepResult = undefined;

    inline for (RING_BITS_SWEEP, 0..) |bits, bi| {
        var runs: [RUNS]f64 = undefined;
        // Warmup
        for (0..WARMUP_RUNS) |_| _ = try runRingSizeSingle(bits);
        for (0..RUNS) |r| {
            runs[r] = try runRingSizeSingle(bits);
        }
        result.stats[bi] = computeStats(&runs);
        std.Thread.sleep(COOLDOWN_MS * 1_000_000);
    }

    return result;
}

fn runRingSizeSingle(comptime bits: u6) !f64 {
    const Config = ringmpsc.mpsc.Config{
        .ring_bits = bits,
        .max_producers = MAX_PRODUCERS,
        .enable_metrics = false,
        .prefetch_threshold = 0,
    };
    const Chan = ringmpsc.mpsc.Channel(u32, Config);
    const RingType = ringmpsc.primitives.Ring(u32, Config);
    const msg_count: u64 = 100_000_000;
    const bs: usize = @min(BATCH_SIZE, @as(usize, 1) << bits);

    var channel = try Chan.init(std.heap.page_allocator);
    defer channel.deinit();

    var producer_obj = try channel.register();
    var start_barrier = std.atomic.Value(bool).init(false);
    var producer_done_flag = std.atomic.Value(bool).init(false);
    var consumer_elapsed = std.atomic.Value(u64).init(0);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(ch: *Chan, elapsed_out: *std.atomic.Value(u64), p_done: *std.atomic.Value(bool), barrier: *std.atomic.Value(bool)) void {
            pin(1);
            while (!barrier.load(.acquire)) std.atomic.spinLoopHint();
            const t0 = std.time.Instant.now() catch unreachable;
            const ring: *RingType = ch.rings[0];
            var count: u64 = 0;
            var idle: u32 = 0;
            while (true) {
                const h = ring.head.load(.monotonic);
                const t = ring.tail.load(.acquire);
                const avail = t -% h;
                if (avail > 0) {
                    ring.head.store(t, .release);
                    count += avail;
                    idle = 0;
                } else {
                    idle += 1;
                    if (idle > 64) {
                        if (p_done.load(.acquire)) {
                            const fh = ring.head.load(.monotonic);
                            const ft = ring.tail.load(.acquire);
                            count += ft -% fh;
                            ring.head.store(ft, .release);
                            break;
                        }
                        idle = 0;
                    }
                    std.atomic.spinLoopHint();
                }
            }
            elapsed_out.store((std.time.Instant.now() catch unreachable).since(t0), .release);
        }
    }.run, .{ &channel, &consumer_elapsed, &producer_done_flag, &start_barrier });

    const producer = try std.Thread.spawn(.{}, struct {
        fn run(prod: *Chan.Producer, batch: usize, barrier: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
            pin(0);
            while (!barrier.load(.acquire)) std.atomic.spinLoopHint();
            const ring = prod.ring;
            var sent: u64 = 0;
            while (sent < msg_count) {
                const want = @min(batch, msg_count - sent);
                if (ring.reserve(want)) |r| {
                    @memset(r.slice, 0);
                    ring.commit(r.slice.len);
                    sent += r.slice.len;
                } else std.atomic.spinLoopHint();
            }
            done.store(true, .release);
        }
    }.run, .{ &producer_obj, bs, &start_barrier, &producer_done_flag });

    start_barrier.store(true, .seq_cst);
    producer.join();
    consumer.join();

    const elapsed_ns = consumer_elapsed.load(.acquire);
    return @as(f64, @floatFromInt(msg_count)) / @as(f64, @floatFromInt(elapsed_ns));
}

// ============================================================================
// BASELINE JSON (REGRESSION DETECTION)
// ============================================================================

fn saveBaseline(
    allocator: std.mem.Allocator,
    batch_u32: *const BatchScalingResult,
    batch_u64: *const BatchScalingResult,
    mpsc: *const MpscScalingResult,
    latency: *const LatencyStats,
) !void {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\n");
    try w.writeAll("  \"batch_u32_8p\": ");
    try std.fmt.format(w, "{d:.4}", .{batch_u32.ringmpsc[4].median});
    try w.writeAll(",\n  \"batch_u64_8p\": ");
    try std.fmt.format(w, "{d:.4}", .{batch_u64.ringmpsc[4].median});
    try w.writeAll(",\n  \"mpsc_8p\": ");
    try std.fmt.format(w, "{d:.4}", .{mpsc.ringmpsc[4].median});
    try w.writeAll(",\n  \"latency_p50\": ");
    try std.fmt.format(w, "{d}", .{latency.p50});
    try w.writeAll(",\n  \"latency_p99\": ");
    try std.fmt.format(w, "{d}", .{latency.p99});
    try w.writeAll("\n}\n");

    std.fs.cwd().makePath("benchmarks/results") catch {};
    var file = try std.fs.cwd().createFile("benchmarks/results/baseline.json", .{});
    defer file.close();
    try file.writeAll(buf.items);
}

// ============================================================================
// HTML REPORT
// ============================================================================

fn generateReport(
    allocator: std.mem.Allocator,
    env: *const Environment,
    batch_u32: *const BatchScalingResult,
    batch_u64: *const BatchScalingResult,
    mpsc: *const MpscScalingResult,
    latency: *const LatencyStats,
    batch_sweep: *const BatchSweepResult,
    ring_sweep: *const RingSweepResult,
) !void {
    var h = report.HtmlWriter.init(allocator);

    report.writeHtmlHeader(&h);

    // Title
    h.w("<h1>ringmpsc &mdash; Benchmark Report</h1>\n");
    h.w("<p class=\"subtitle\">Zig ");
    h.w(env.zig_version);
    h.w(" &middot; ReleaseFast &middot; ");
    h.print("{d} runs/benchmark &middot; ", .{RUNS});
    h.w(envStr(&env.cpu_model, env.cpu_model_len));
    h.w(" &middot; governor: ");
    h.w(envStr(&env.governor, env.governor_len));
    h.w("</p>\n");

    // Hero metrics
    h.w("<div class=\"metrics-row\">\n");
    h.print("<div class=\"metric\"><div class=\"value\">{d:.1} B/s</div><div class=\"label\">Peak Batch u32 (8P1C)</div></div>\n", .{batch_u32.ringmpsc[4].median});
    h.print("<div class=\"metric\"><div class=\"value\">{d:.1} B/s</div><div class=\"label\">Peak Batch u64 (8P1C)</div></div>\n", .{batch_u64.ringmpsc[4].median});
    h.print("<div class=\"metric\"><div class=\"value\">{d:.1} M/s</div><div class=\"label\">Peak MPSC (8P1C)</div></div>\n", .{mpsc.ringmpsc[4].median});
    h.print("<div class=\"metric\"><div class=\"value\">{d}ns</div><div class=\"label\">SPSC p50 RTT</div></div>\n", .{latency.p50});
    h.print("<div class=\"metric\"><div class=\"value\">{d}ns</div><div class=\"label\">SPSC p99 RTT</div></div>\n", .{latency.p99});
    h.w("</div>\n");

    // ── Section 1: Batch Throughput ──────────────────────────────────────
    h.w("<h2>1. Batch Throughput Scaling</h2>\n");
    h.w("<p style=\"color: var(--muted); font-size: 0.85rem; margin-bottom: 1rem;\">");
    h.print("32K-batch reserve/commit with @memset fill. {d}M msgs/producer. ", .{BATCH_MSG_COUNT / 1_000_000});
    h.print("{d} runs per data point, showing median with min/max error bars. ", .{RUNS});
    h.w("All baselines use ring-decomposed architecture (separate ring per producer).</p>\n");

    // u32 chart with error bars
    h.w("<div class=\"card\">\n");
    {
        const labels = [_][]const u8{ "1P1C", "2P1C", "4P1C", "6P1C", "8P1C" };
        const series_names = [_][]const u8{ "ringmpsc", "Cached SPSC", "Mutex" };
        var med: [3][PRODUCER_COUNTS.len]f64 = undefined;
        var mn: [3][PRODUCER_COUNTS.len]f64 = undefined;
        var mx: [3][PRODUCER_COUNTS.len]f64 = undefined;
        for (0..PRODUCER_COUNTS.len) |i| {
            med[0][i] = batch_u32.ringmpsc[i].median;
            mn[0][i] = batch_u32.ringmpsc[i].min;
            mx[0][i] = batch_u32.ringmpsc[i].max;
            med[1][i] = batch_u32.cached[i].median;
            mn[1][i] = batch_u32.cached[i].min;
            mx[1][i] = batch_u32.cached[i].max;
            med[2][i] = batch_u32.mutex[i].median;
            mn[2][i] = batch_u32.mutex[i].min;
            mx[2][i] = batch_u32.mutex[i].max;
        }
        const med_slices = [_][]const f64{ &med[0], &med[1], &med[2] };
        const mn_slices = [_][]const f64{ &mn[0], &mn[1], &mn[2] };
        const mx_slices = [_][]const f64{ &mx[0], &mx[1], &mx[2] };
        report.groupedBarChartWithErrors(&h, "Batch Throughput u32 (B/s)", &labels, &series_names, &med_slices, &mn_slices, &mx_slices, "B/s", 900, 400);
    }
    h.w("</div>\n");

    // u32 table
    h.w("<div class=\"card\">\n");
    h.w("<table><tr><th>u32</th>");
    for (PRODUCER_COUNTS) |p| h.print("<th>{d}P1C</th>", .{p});
    h.w("<th>CV</th></tr>\n");
    writeStatsTableRow(&h, "ringmpsc", &batch_u32.ringmpsc, "B/s");
    writeStatsTableRow(&h, "Cached SPSC", &batch_u32.cached, "B/s");
    writeStatsTableRow(&h, "Mutex", &batch_u32.mutex, "B/s");
    h.w("</table></div>\n");

    // u64 chart with error bars
    h.w("<div class=\"card\">\n");
    {
        const labels = [_][]const u8{ "1P1C", "2P1C", "4P1C", "6P1C", "8P1C" };
        const series_names = [_][]const u8{ "ringmpsc", "Cached SPSC", "Mutex" };
        var med: [3][PRODUCER_COUNTS.len]f64 = undefined;
        var mn: [3][PRODUCER_COUNTS.len]f64 = undefined;
        var mx: [3][PRODUCER_COUNTS.len]f64 = undefined;
        for (0..PRODUCER_COUNTS.len) |i| {
            med[0][i] = batch_u64.ringmpsc[i].median;
            mn[0][i] = batch_u64.ringmpsc[i].min;
            mx[0][i] = batch_u64.ringmpsc[i].max;
            med[1][i] = batch_u64.cached[i].median;
            mn[1][i] = batch_u64.cached[i].min;
            mx[1][i] = batch_u64.cached[i].max;
            med[2][i] = batch_u64.mutex[i].median;
            mn[2][i] = batch_u64.mutex[i].min;
            mx[2][i] = batch_u64.mutex[i].max;
        }
        const med_slices = [_][]const f64{ &med[0], &med[1], &med[2] };
        const mn_slices = [_][]const f64{ &mn[0], &mn[1], &mn[2] };
        const mx_slices = [_][]const f64{ &mx[0], &mx[1], &mx[2] };
        report.groupedBarChartWithErrors(&h, "Batch Throughput u64 (B/s)", &labels, &series_names, &med_slices, &mn_slices, &mx_slices, "B/s", 900, 400);
    }
    h.w("</div>\n");

    // u64 table
    h.w("<div class=\"card\">\n");
    h.w("<table><tr><th>u64</th>");
    for (PRODUCER_COUNTS) |p| h.print("<th>{d}P1C</th>", .{p});
    h.w("<th>CV</th></tr>\n");
    writeStatsTableRow(&h, "ringmpsc", &batch_u64.ringmpsc, "B/s");
    writeStatsTableRow(&h, "Cached SPSC", &batch_u64.cached, "B/s");
    writeStatsTableRow(&h, "Mutex", &batch_u64.mutex, "B/s");
    h.w("</table></div>\n");

    // ── Section 2: MPSC Scaling ─────────────────────────────────────────
    h.w("<h2>2. MPSC Single-Item Scaling</h2>\n");
    h.w("<p style=\"color: var(--muted); font-size: 0.85rem; margin-bottom: 1rem;\">");
    h.print("{d}M u32 total, single-item sendOne/consumeAll. ", .{SINGLE_MSG_COUNT / 1_000_000});
    h.w("ringmpsc: ring-decomposed (zero producer contention). ");
    h.w("CAS MPSC: Vyukov bounded array. Mutex: std.Thread.Mutex.</p>\n");

    // Scaling line chart with error bands
    h.w("<div class=\"card\">\n");
    {
        const labels = [_][]const u8{ "1P1C", "2P1C", "4P1C", "6P1C", "8P1C" };
        const series_names = [_][]const u8{ "ringmpsc", "CAS MPSC", "Mutex" };
        var med: [3][PRODUCER_COUNTS.len]f64 = undefined;
        var mn: [3][PRODUCER_COUNTS.len]f64 = undefined;
        var mx: [3][PRODUCER_COUNTS.len]f64 = undefined;
        for (0..PRODUCER_COUNTS.len) |i| {
            med[0][i] = mpsc.ringmpsc[i].median;
            mn[0][i] = mpsc.ringmpsc[i].min;
            mx[0][i] = mpsc.ringmpsc[i].max;
            med[1][i] = mpsc.cas[i].median;
            mn[1][i] = mpsc.cas[i].min;
            mx[1][i] = mpsc.cas[i].max;
            med[2][i] = mpsc.mutex[i].median;
            mn[2][i] = mpsc.mutex[i].min;
            mx[2][i] = mpsc.mutex[i].max;
        }
        const med_slices = [_][]const f64{ &med[0], &med[1], &med[2] };
        const mn_slices = [_][]const f64{ &mn[0], &mn[1], &mn[2] };
        const mx_slices = [_][]const f64{ &mx[0], &mx[1], &mx[2] };
        report.lineChartWithErrors(&h, "MPSC Scaling (M msg/s)", &labels, &series_names, &med_slices, &mn_slices, &mx_slices, "M msg/s", 900, 400);
    }
    h.w("</div>\n");

    // MPSC table
    h.w("<div class=\"card\">\n");
    h.w("<table><tr><th>MPSC</th>");
    for (PRODUCER_COUNTS) |p| h.print("<th>{d}P1C</th>", .{p});
    h.w("<th>CV</th></tr>\n");
    writeStatsTableRow(&h, "ringmpsc", &mpsc.ringmpsc, "M/s");
    writeStatsTableRow(&h, "CAS MPSC", &mpsc.cas, "M/s");
    writeStatsTableRow(&h, "Mutex", &mpsc.mutex, "M/s");
    h.w("</table></div>\n");

    // ── Section 3: Latency ──────────────────────────────────────────────
    h.w("<h2>3. SPSC Round-Trip Latency</h2>\n");
    h.w("<p style=\"color: var(--muted); font-size: 0.85rem; margin-bottom: 1rem;\">");
    h.print("Ping-pong RTT on ring_bits=12. {d}K warmup, {d}K samples.</p>\n", .{
        LATENCY_WARMUP / 1000, LATENCY_SAMPLES / 1000,
    });

    h.w("<div class=\"chart-grid\">\n");
    h.w("<div class=\"card\">\n");
    report.latencyBoxChart(&h, latency.p50, latency.p90, latency.p99, latency.p999, latency.min, latency.max, 500, 300);
    h.w("</div>\n");
    h.w("<div class=\"card\">\n");
    h.w("<table><tr><th>Metric</th><th>Value</th></tr>\n");
    h.print("<tr><td>min</td><td>{d} ns</td></tr>\n", .{latency.min});
    h.print("<tr><td>p50</td><td>{d} ns</td></tr>\n", .{latency.p50});
    h.print("<tr><td>p90</td><td>{d} ns</td></tr>\n", .{latency.p90});
    h.print("<tr><td>p99</td><td>{d} ns</td></tr>\n", .{latency.p99});
    h.print("<tr><td>p99.9</td><td>{d} ns</td></tr>\n", .{latency.p999});
    h.print("<tr><td>max</td><td>{d} ns</td></tr>\n", .{latency.max});
    h.print("<tr><td>avg</td><td>{d} ns</td></tr>\n", .{latency.avg});
    h.w("</table></div>\n");
    h.w("</div>\n");

    // ── Section 4: Batch Size Sweep ─────────────────────────────────────
    h.w("<h2>4. Batch Size Sensitivity</h2>\n");
    h.w("<p style=\"color: var(--muted); font-size: 0.85rem; margin-bottom: 1rem;\">");
    h.w("1P1C u32, varying batch size from 1 to 32K. Shows amortization of atomic operations.</p>\n");

    h.w("<div class=\"card\">\n");
    {
        const labels = [_][]const u8{ "1", "64", "1K", "4K", "32K" };
        var med: [BATCH_SIZES.len]f64 = undefined;
        var mn: [BATCH_SIZES.len]f64 = undefined;
        var mx: [BATCH_SIZES.len]f64 = undefined;
        for (0..BATCH_SIZES.len) |i| {
            med[i] = batch_sweep.stats[i].median;
            mn[i] = batch_sweep.stats[i].min;
            mx[i] = batch_sweep.stats[i].max;
        }
        report.barChartWithErrors(&h, "Throughput by Batch Size (B/s)", &labels, &med, &mn, &mx, "B/s", 700, 350);
    }
    h.w("</div>\n");

    // Batch sweep table
    h.w("<div class=\"card\">\n");
    h.w("<table><tr><th>Batch Size</th><th>Median</th><th>Min</th><th>Max</th><th>CV</th></tr>\n");
    for (BATCH_SIZES, 0..) |bs, i| {
        const s = batch_sweep.stats[i];
        h.print("<tr><td>{d}</td><td>{d:.3} B/s</td><td>{d:.3} B/s</td><td>{d:.3} B/s</td><td>{d:.1}%</td></tr>\n", .{
            bs, s.median, s.min, s.max, s.cv,
        });
    }
    h.w("</table></div>\n");

    // ── Section 5: Ring Size Sweep ──────────────────────────────────────
    h.w("<h2>5. Ring Size Sensitivity</h2>\n");
    h.w("<p style=\"color: var(--muted); font-size: 0.85rem; margin-bottom: 1rem;\">");
    h.w("1P1C u32, batch=32K (capped at ring capacity). Shows cache residency effect: ");
    h.w("ring sizes that fit in L2 (512KB on Zen 3) perform best.</p>\n");

    h.w("<div class=\"card\">\n");
    {
        var labels: [RING_BITS_SWEEP.len][]const u8 = undefined;
        const label_strs = [_][]const u8{ "1K", "4K", "16K", "32K", "64K", "256K" };
        for (0..RING_BITS_SWEEP.len) |i| labels[i] = label_strs[i];
        var med: [RING_BITS_SWEEP.len]f64 = undefined;
        var mn: [RING_BITS_SWEEP.len]f64 = undefined;
        var mx: [RING_BITS_SWEEP.len]f64 = undefined;
        for (0..RING_BITS_SWEEP.len) |i| {
            med[i] = ring_sweep.stats[i].median;
            mn[i] = ring_sweep.stats[i].min;
            mx[i] = ring_sweep.stats[i].max;
        }
        report.barChartWithErrors(&h, "Throughput by Ring Size (B/s)", &labels, &med, &mn, &mx, "B/s", 700, 350);
    }
    h.w("</div>\n");

    // Ring sweep table
    h.w("<div class=\"card\">\n");
    h.w("<table><tr><th>Ring Bits</th><th>Slots</th><th>Size (u32)</th><th>Median</th><th>CV</th></tr>\n");
    for (RING_BITS_SWEEP, 0..) |bits, i| {
        const s = ring_sweep.stats[i];
        const slots = @as(u64, 1) << bits;
        const size_kb = slots * 4 / 1024;
        h.print("<tr><td>{d}</td><td>{d}</td><td>{d}KB</td><td>{d:.3} B/s</td><td>{d:.1}%</td></tr>\n", .{
            bits, slots, size_kb, s.median, s.cv,
        });
    }
    h.w("</table></div>\n");

    // ── Section 6: Methodology ──────────────────────────────────────────
    h.w("<h2>6. Methodology</h2>\n");
    h.w("<div class=\"card\">\n");
    h.w("<p style=\"line-height: 1.6;\">");
    h.print("<strong>Runs:</strong> {d} per data point. Median reported as primary metric. ", .{RUNS});
    h.w("Error bars show min/max across runs. CV (coefficient of variation) indicates stability.<br><br>");
    h.w("<strong>Batch mode:</strong> Each producer calls <code>reserve(N)</code> &rarr; <code>@memset</code> &rarr; <code>commit(N)</code>. ");
    h.w("Consumer advances head pointers (does not read data). Throughput is memory-bandwidth bound.<br><br>");
    h.w("<strong>Single-item:</strong> <code>sendOne</code>/<code>consumeAll</code> with exponential backoff. ");
    h.w("Measures synchronization overhead, not memory bandwidth.<br><br>");
    h.w("<strong>Latency:</strong> Ping-pong round-trip. Producer sends one item, waits for consumer echo. ");
    h.w("Measures 2x ring traversal + 2x atomic synchronization.<br><br>");
    h.w("<strong>Environment:</strong> All threads are CPU-pinned. ReleaseFast optimization. ");
    h.w("For cleanest results: <code>sudo taskset -c 0-15 nice -n -20 zig-out/bin/bench</code>");
    h.w("</p></div>\n");

    // ── Footer ──────────────────────────────────────────────────────────
    h.w("<div style=\"margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--border); color: var(--muted); font-size: 0.75rem;\">");
    h.w("Generated by <code>zig build bench</code> &middot; pure Zig, zero dependencies &middot; ");
    h.w("<a href=\"https://github.com/boonzy00/ringmpsc/blob/main/docs/methodology.md\" style=\"color: var(--accent);\">Full methodology</a>");
    h.w("</div>\n");
    h.w("</body></html>\n");

    // Write file
    std.fs.cwd().makePath("benchmarks/results") catch {};
    var file = try std.fs.cwd().createFile("benchmarks/results/bench.html", .{});
    defer file.close();
    try file.writeAll(h.output());
}

fn writeStatsTableRow(h: *report.HtmlWriter, name: []const u8, stats: anytype, unit: []const u8) void {
    h.print("<tr><td>{s}</td>", .{name});
    for (stats) |s| {
        h.print("<td>{d:.2} {s}</td>", .{ s.median, unit });
    }
    h.print("<td>{d:.1}%</td></tr>\n", .{stats[stats.len - 1].cv});
}
