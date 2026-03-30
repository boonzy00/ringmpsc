//! ringmpsc — Benchmark Suite
//!
//! Outputs JSON to stdout and writes an HTML report with inline SVG charts
//! to benchmarks/results/report.html.
//!
//! Benchmarks:
//!   1. SPSC latency       — single-item round-trip (p50/p99/p999)
//!   2. SPSC throughput     — batch-size sweep (1, 64, 1K, 32K)
//!   3. Ring size sweep     — throughput vs ring_bits (10..18)
//!   4. MPSC scaling        — 1P..8P producer throughput
//!   5. MPMC scaling        — P x C matrix with work-stealing
//!   6. Batch size sweep    — how batch size affects throughput

const std = @import("std");
const ringmpsc = @import("ringmpsc");
const report = @import("report.zig");

// ============================================================================
// CONFIGURATION
// ============================================================================

const WARMUP_NS: u64 = 50 * std.time.ns_per_ms;
const CPU_COUNT: usize = 16;

// ============================================================================
// JSON WRITER
// ============================================================================

const JsonWriter = struct {
    buf: std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    depth: usize = 0,
    needs_comma: bool = false,

    fn init(allocator: std.mem.Allocator) JsonWriter {
        return .{ .buf = .{}, .allocator = allocator };
    }

    fn deinit(self: *JsonWriter) void {
        self.buf.deinit(self.allocator);
    }

    fn w(self: *JsonWriter, bytes: []const u8) void {
        self.buf.appendSlice(self.allocator, bytes) catch {};
    }

    fn indent(self: *JsonWriter) void {
        for (0..self.depth) |_| self.w("  ");
    }

    fn comma(self: *JsonWriter) void {
        if (self.needs_comma) self.w(",");
        self.w("\n");
        self.needs_comma = false;
    }

    fn beginObject(self: *JsonWriter) void {
        self.w("{");
        self.depth += 1;
        self.needs_comma = false;
    }

    fn endObject(self: *JsonWriter) void {
        self.depth -= 1;
        self.w("\n");
        self.indent();
        self.w("}");
        self.needs_comma = true;
    }

    fn beginArray(self: *JsonWriter) void {
        self.w("[");
        self.depth += 1;
        self.needs_comma = false;
    }

    fn endArray(self: *JsonWriter) void {
        self.depth -= 1;
        self.w("\n");
        self.indent();
        self.w("]");
        self.needs_comma = true;
    }

    fn key(self: *JsonWriter, name: []const u8) void {
        self.comma();
        self.indent();
        self.w("\"");
        self.w(name);
        self.w("\": ");
        self.needs_comma = false;
    }

    fn valStr(self: *JsonWriter, val: []const u8) void {
        self.w("\"");
        self.w(val);
        self.w("\"");
        self.needs_comma = true;
    }

    fn valInt(self: *JsonWriter, val: anytype) void {
        std.fmt.format(self.buf.writer(self.allocator), "{}", .{val}) catch {};
        self.needs_comma = true;
    }

    fn valFloat(self: *JsonWriter, val: f64) void {
        std.fmt.format(self.buf.writer(self.allocator), "{d:.4}", .{val}) catch {};
        self.needs_comma = true;
    }

    fn arrayElement(self: *JsonWriter) void {
        self.comma();
        self.indent();
        self.needs_comma = false;
    }

    fn output(self: *JsonWriter) []const u8 {
        return self.buf.items;
    }
};

// ============================================================================
// STATISTICS
// ============================================================================

fn sortU64(slice: []u64) void {
    std.mem.sort(u64, slice, {}, std.sort.asc(u64));
}

fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const idx_f = p * @as(f64, @floatFromInt(sorted.len - 1));
    const idx: usize = @intFromFloat(idx_f);
    return sorted[@min(idx, sorted.len - 1)];
}

fn mean(slice: []const u64) f64 {
    if (slice.len == 0) return 0;
    var sum: u128 = 0;
    for (slice) |v| sum += v;
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(slice.len));
}

// ============================================================================
// CPU PINNING (Linux)
// ============================================================================

fn pin(cpu: usize) void {
    const actual = cpu % CPU_COUNT;
    var set = std.mem.zeroes(std.os.linux.cpu_set_t);
    set[actual / 64] |= @as(u64, 1) << @as(u6, @intCast(actual % 64));
    std.os.linux.sched_setaffinity(0, &set) catch {};
}

// ============================================================================
// 1. SPSC LATENCY
// ============================================================================

fn benchSpscLatency(j: *JsonWriter) void {
    const Config = ringmpsc.primitives.Config{ .ring_bits = 12, .max_producers = 1 };
    var ring = ringmpsc.primitives.Ring(u64, Config){};

    const SAMPLES = 100_000;
    var latencies: [SAMPLES]u64 = undefined;

    // Warmup
    for (0..1000) |i| {
        if (ring.reserve(1)) |r| {
            r.slice[0] = i;
            ring.commit(1);
        }
        _ = ring.tryRecv();
    }

    // Measure
    for (&latencies) |*lat| {
        const t0 = std.time.Instant.now() catch unreachable;

        if (ring.reserve(1)) |r| {
            r.slice[0] = 42;
            ring.commit(1);
        }
        _ = ring.tryRecv();

        lat.* = (std.time.Instant.now() catch unreachable).since(t0);
    }

    sortU64(&latencies);

    j.key("spsc_latency");
    j.beginObject();
    {
        j.key("unit");
        j.valStr("ns");
        j.key("samples");
        j.valInt(SAMPLES);
        j.key("p50");
        j.valInt(percentile(&latencies, 0.50));
        j.key("p90");
        j.valInt(percentile(&latencies, 0.90));
        j.key("p99");
        j.valInt(percentile(&latencies, 0.99));
        j.key("p999");
        j.valInt(percentile(&latencies, 0.999));
        j.key("min");
        j.valInt(latencies[0]);
        j.key("max");
        j.valInt(latencies[SAMPLES - 1]);
        j.key("mean");
        j.valFloat(mean(&latencies));
    }
    j.endObject();
}

// ============================================================================
// 2. SPSC THROUGHPUT (batch size sweep)
// ============================================================================

fn benchSpscThroughput(j: *JsonWriter) void {
    j.key("spsc_throughput");
    j.beginArray();

    const batch_sizes = [_]usize{ 1, 8, 64, 512, 1024, 4096, 32768 };

    inline for (batch_sizes) |bs| {
        const Config = ringmpsc.primitives.Config{ .ring_bits = 16, .max_producers = 1 };
        var ring = ringmpsc.primitives.Ring(u64, Config){};

        const TOTAL: u64 = 10_000_000;
        var buf: [bs]u64 = undefined;
        for (&buf, 0..) |*b, i| b.* = i;

        // Warmup
        {
            var warmup_sent: u64 = 0;
            while (warmup_sent < 100_000) {
                const n = ring.send(&buf);
                warmup_sent += n;
                var out: [bs]u64 = undefined;
                _ = ring.recv(&out);
            }
        }
        ring.reset();

        const t0 = std.time.Instant.now() catch unreachable;
        var sent: u64 = 0;
        var recvd: u64 = 0;

        while (sent < TOTAL or recvd < sent) {
            if (sent < TOTAL) {
                sent += ring.send(&buf);
            }
            var out: [bs]u64 = undefined;
            recvd += ring.recv(&out);
        }

        const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
        const rate = @as(f64, @floatFromInt(recvd)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);

        j.arrayElement();
        j.beginObject();
        {
            j.key("batch_size");
            j.valInt(bs);
            j.key("messages");
            j.valInt(recvd);
            j.key("elapsed_ns");
            j.valInt(elapsed);
            j.key("msgs_per_sec");
            j.valFloat(rate);
        }
        j.endObject();
    }

    j.endArray();
}

// ============================================================================
// 3. RING SIZE SWEEP
// ============================================================================

fn benchRingSizeSweep(j: *JsonWriter) void {
    j.key("ring_size_sweep");
    j.beginArray();

    inline for (.{ 10, 12, 14, 15, 16, 18 }) |bits| {
        const Config = ringmpsc.primitives.Config{ .ring_bits = bits, .max_producers = 1 };
        var ring = ringmpsc.primitives.Ring(u64, Config){};

        const BATCH: usize = @min(1024, (@as(usize, 1) << bits) / 2);
        const TOTAL: u64 = 5_000_000;
        var buf: [BATCH]u64 = undefined;
        for (&buf, 0..) |*b, i| b.* = i;

        ring.reset();

        const t0 = std.time.Instant.now() catch unreachable;
        var sent: u64 = 0;
        var recvd: u64 = 0;

        while (recvd < TOTAL) {
            if (sent < TOTAL) {
                sent += ring.send(buf[0..BATCH]);
            }
            var out: [BATCH]u64 = undefined;
            recvd += ring.recv(&out);
        }

        const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
        const rate = @as(f64, @floatFromInt(recvd)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);

        j.arrayElement();
        j.beginObject();
        {
            j.key("ring_bits");
            j.valInt(bits);
            j.key("capacity");
            j.valInt(@as(usize, 1) << bits);
            j.key("batch_size");
            j.valInt(BATCH);
            j.key("messages");
            j.valInt(recvd);
            j.key("elapsed_ns");
            j.valInt(elapsed);
            j.key("msgs_per_sec");
            j.valFloat(rate);
        }
        j.endObject();
    }

    j.endArray();
}

// ============================================================================
// 4. MPSC SCALING
// ============================================================================

// (mpsc scaling is inline in main to collect results for charts)

const MPSC_MSG_PER_PRODUCER: u64 = 500_000_000;
const MPSC_BATCH: usize = 32768;
const MPSC_MAX_P: usize = 8;

const MpscConfig = ringmpsc.mpsc.Config{
    .ring_bits = 15,
    .max_producers = MPSC_MAX_P,
    .enable_metrics = false,
};
const MpscChannelType = ringmpsc.mpsc.Channel(u64, MpscConfig);

fn runMpscTest(allocator: std.mem.Allocator, num_producers: usize) !f64 {
    var channel = try MpscChannelType.init(allocator);
    defer channel.deinit();

    var producer_threads: [MPSC_MAX_P]std.Thread = undefined;
    var producers: [MPSC_MAX_P]MpscChannelType.Producer = undefined;
    var start_barrier = std.atomic.Value(bool).init(false);
    var producers_done = std.atomic.Value(usize).init(0);

    for (0..num_producers) |i| {
        producers[i] = try channel.register();
    }

    const t0 = std.time.Instant.now() catch unreachable;

    // Consumer thread
    const consumer_thread = try std.Thread.spawn(.{}, mpscConsumerFn, .{
        &channel,
        num_producers,
        &producers_done,
    });

    // Producer threads
    for (0..num_producers) |i| {
        producer_threads[i] = try std.Thread.spawn(.{}, mpscProducerFn, .{
            &producers[i],
            i,
            &start_barrier,
            &producers_done,
        });
    }

    start_barrier.store(true, .release);

    for (0..num_producers) |i| producer_threads[i].join();
    channel.close();
    consumer_thread.join();

    const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
    const total = MPSC_MSG_PER_PRODUCER * num_producers;
    return @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);
}

fn mpscProducerFn(
    producer: *MpscChannelType.Producer,
    cpu: usize,
    start_barrier: *std.atomic.Value(bool),
    producers_done: *std.atomic.Value(usize),
) void {
    pin(cpu);
    while (!start_barrier.load(.acquire)) std.atomic.spinLoopHint();

    var sent: u64 = 0;
    while (sent < MPSC_MSG_PER_PRODUCER) {
        const want = @min(MPSC_BATCH, MPSC_MSG_PER_PRODUCER - sent);
        if (producer.reserve(want)) |r| {
            for (r.slice, 0..) |*slot, i| slot.* = sent + i;
            producer.commit(r.slice.len);
            sent += r.slice.len;
        } else {
            std.atomic.spinLoopHint();
        }
    }
    _ = producers_done.fetchAdd(1, .release);
}

fn mpscConsumerFn(
    channel: *MpscChannelType,
    num_producers: usize,
    producers_done: *std.atomic.Value(usize),
) void {
    pin(num_producers);

    const NoOp = struct {
        pub inline fn process(_: @This(), _: *u64) void {}
    };

    var done = false;
    while (!done or !channel.isClosed()) {
        const n = channel.consumeAll(NoOp{});
        if (n == 0) {
            done = producers_done.load(.acquire) >= num_producers;
            if (done and channel.isClosed()) break;
            std.atomic.spinLoopHint();
        }
    }
}

// ============================================================================
// 5. MPMC SCALING
// ============================================================================

// (mpmc scaling is inline in main to collect results for charts)

const MPMC_MSG_PER_PRODUCER: u64 = 100_000_000;
const MPMC_BATCH: usize = 16384;
const MPMC_MAX_P: usize = 8;
const MPMC_MAX_C: usize = 8;

const MpmcConfig = ringmpsc.mpmc.MpmcConfig{
    .ring_bits = 15,
    .max_producers = MPMC_MAX_P,
    .max_consumers = MPMC_MAX_C,
};
const MpmcChannelType = ringmpsc.mpmc.MpmcChannel(u64, MpmcConfig);

fn runMpmcTest(num_producers: usize, num_consumers: usize) !f64 {
    var channel = MpmcChannelType{};
    defer channel.close();

    var producer_threads: [MPMC_MAX_P]std.Thread = undefined;
    var consumer_threads: [MPMC_MAX_C]std.Thread = undefined;
    var total_consumed = std.atomic.Value(u64).init(0);
    var start_barrier = std.atomic.Value(bool).init(false);
    var producers_done = std.atomic.Value(usize).init(0);

    const t0 = std.time.Instant.now() catch unreachable;

    // Consumers first
    for (0..num_consumers) |i| {
        consumer_threads[i] = try std.Thread.spawn(.{}, mpmcConsumerFn, .{
            &channel,
            &total_consumed,
            num_producers + i,
            &producers_done,
            num_producers,
            &start_barrier,
        });
    }

    // Producers
    for (0..num_producers) |i| {
        producer_threads[i] = try std.Thread.spawn(.{}, mpmcProducerFn, .{
            &channel,
            i,
            &start_barrier,
            &producers_done,
        });
    }

    start_barrier.store(true, .release);

    for (0..num_producers) |i| producer_threads[i].join();

    // Drain
    var spin: usize = 0;
    while (channel.totalPending() > 0 and spin < 100_000_000) : (spin += 1) {
        std.atomic.spinLoopHint();
    }

    const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
    channel.close();

    for (0..num_consumers) |i| consumer_threads[i].join();

    const count = total_consumed.load(.acquire);
    return @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);
}

fn mpmcProducerFn(
    channel: *MpmcChannelType,
    cpu: usize,
    start_barrier: *std.atomic.Value(bool),
    producers_done: *std.atomic.Value(usize),
) void {
    pin(cpu);
    const producer = channel.register() catch return;
    while (!start_barrier.load(.acquire)) std.atomic.spinLoopHint();

    var sent: u64 = 0;
    while (sent < MPMC_MSG_PER_PRODUCER) {
        const want = @min(MPMC_BATCH, MPMC_MSG_PER_PRODUCER - sent);
        if (producer.reserve(want)) |r| {
            for (r.slice, 0..) |*slot, i| slot.* = sent + i;
            producer.commit(r.slice.len);
            sent += r.slice.len;
        } else {
            std.atomic.spinLoopHint();
        }
    }
    _ = producers_done.fetchAdd(1, .release);
}

fn mpmcConsumerFn(
    channel: *MpmcChannelType,
    total_consumed: *std.atomic.Value(u64),
    cpu: usize,
    producers_done: *std.atomic.Value(usize),
    num_producers: usize,
    start_barrier: *std.atomic.Value(bool),
) void {
    pin(cpu);
    var consumer = channel.registerConsumer() catch return;
    var count: u64 = 0;

    while (!start_barrier.load(.acquire)) std.atomic.spinLoopHint();

    const Handler = struct {
        cnt: *u64,
        pub fn process(self: @This(), _: *u64) void {
            self.cnt.* += 1;
        }
    };

    var idle: usize = 0;
    while (true) {
        const n = consumer.stealBatch(Handler, Handler{ .cnt = &count });
        if (n > 0) {
            idle = 0;
        } else {
            idle += 1;
            if (channel.isClosed()) break;
            if (producers_done.load(.acquire) >= num_producers) {
                // Drain remaining
                var attempts: usize = 0;
                while (attempts < 1000) : (attempts += 1) {
                    const d = consumer.stealBatch(Handler, Handler{ .cnt = &count });
                    if (d == 0) {
                        if (channel.totalPending() == 0) break;
                        std.atomic.spinLoopHint();
                    }
                }
                break;
            }
            if (idle > 1000) std.atomic.spinLoopHint();
        }
    }

    _ = total_consumed.fetchAdd(count, .release);
}

// ============================================================================
// 6. BATCH SIZE SWEEP (MPSC)
// ============================================================================

// (batch size sweep is inline in main to collect results for charts)

fn runBatchSweepTest(num_producers: usize, batch_size: usize, msgs_per_producer: u64) !f64 {
    const Config = ringmpsc.mpsc.Config{
        .ring_bits = 16,
        .max_producers = 8,
        .enable_metrics = false,
    };
    const ChanType = ringmpsc.mpsc.Channel(u64, Config);

    var channel = try ChanType.init(std.heap.page_allocator);
    defer channel.deinit();

    var threads: [8]std.Thread = undefined;
    var producers: [8]ChanType.Producer = undefined;
    var start = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(usize).init(0);

    for (0..num_producers) |i| {
        producers[i] = try channel.register();
    }

    const t0 = std.time.Instant.now() catch unreachable;

    const consumer = try std.Thread.spawn(.{}, struct {
        fn f(ch: *ChanType, np: usize, d: *std.atomic.Value(usize)) void {
            pin(np);
            const NoOp = struct {
                pub inline fn process(_: @This(), _: *u64) void {}
            };
            var finished = false;
            while (!finished or !ch.isClosed()) {
                const n = ch.consumeAll(NoOp{});
                if (n == 0) {
                    finished = d.load(.acquire) >= np;
                    if (finished and ch.isClosed()) break;
                    std.atomic.spinLoopHint();
                }
            }
        }
    }.f, .{ &channel, num_producers, &done });

    for (0..num_producers) |i| {
        const ctx = .{ &producers[i], i, &start, &done, batch_size, msgs_per_producer };
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn f(
                prod: *ChanType.Producer,
                cpu: usize,
                barrier: *std.atomic.Value(bool),
                d: *std.atomic.Value(usize),
                bs: usize,
                total: u64,
            ) void {
                pin(cpu);
                while (!barrier.load(.acquire)) std.atomic.spinLoopHint();
                var sent: u64 = 0;
                while (sent < total) {
                    const want = @min(bs, total - sent);
                    if (prod.reserve(want)) |r| {
                        for (r.slice, 0..) |*slot, idx| slot.* = sent + idx;
                        prod.commit(r.slice.len);
                        sent += r.slice.len;
                    } else {
                        std.atomic.spinLoopHint();
                    }
                }
                _ = d.fetchAdd(1, .release);
            }
        }.f, ctx);
    }

    start.store(true, .release);
    for (0..num_producers) |i| threads[i].join();
    channel.close();
    consumer.join();

    const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
    const total = msgs_per_producer * num_producers;
    return @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);
}

// ============================================================================
// 7. SPMC SCALING
// ============================================================================

const SPMC_TOTAL_MSGS: u64 = 100_000_000;
const SPMC_MAX_C: usize = 8;

const SpmcConfig = ringmpsc.spmc.SpmcConfig{
    .ring_bits = 16,
    .max_consumers = SPMC_MAX_C,
};
const SpmcChannelType = ringmpsc.spmc.Channel(u64, SpmcConfig);

fn runSpmcTest(num_consumers: usize) !f64 {
    var channel = SpmcChannelType{};
    defer channel.close();

    var consumer_threads: [SPMC_MAX_C]std.Thread = undefined;
    var total_consumed = std.atomic.Value(u64).init(0);
    var start_barrier = std.atomic.Value(bool).init(false);

    // Start consumers
    for (0..num_consumers) |i| {
        var consumer = try channel.registerConsumer();
        consumer_threads[i] = try std.Thread.spawn(.{}, spmcConsumerFn, .{
            &consumer,
            &channel,
            &total_consumed,
            1 + i, // pin after producer
            &start_barrier,
        });
    }

    const t0 = std.time.Instant.now() catch unreachable;
    start_barrier.store(true, .release);

    // Producer on CPU 0
    pin(0);
    var sent: u64 = 0;
    const BATCH: usize = 32768;
    while (sent < SPMC_TOTAL_MSGS) {
        const want = @min(BATCH, SPMC_TOTAL_MSGS - sent);
        if (channel.reserve(want)) |r| {
            for (r.slice, 0..) |*slot, i| slot.* = sent + i;
            channel.commit(r.slice.len);
            sent += r.slice.len;
        } else {
            std.atomic.spinLoopHint();
        }
    }

    channel.close();

    for (0..num_consumers) |i| consumer_threads[i].join();

    const elapsed = (std.time.Instant.now() catch unreachable).since(t0);
    const count = total_consumed.load(.acquire);
    return @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(elapsed)) / 1e9);
}

fn spmcConsumerFn(
    consumer: *SpmcChannelType.Consumer,
    channel: *const SpmcChannelType,
    total_consumed: *std.atomic.Value(u64),
    cpu: usize,
    start_barrier: *std.atomic.Value(bool),
) void {
    pin(cpu);
    while (!start_barrier.load(.acquire)) std.atomic.spinLoopHint();

    var count: u64 = 0;
    var buf: [1024]u64 = undefined;
    var backoff = ringmpsc.primitives.Backoff{};

    while (true) {
        const n = consumer.steal(&buf);
        if (n > 0) {
            count += n;
            backoff.reset();
        } else {
            if (channel.isClosed()) {
                const final = consumer.steal(&buf);
                count += final;
                break;
            }
            backoff.snooze();
        }
    }

    _ = total_consumed.fetchAdd(count, .release);
}

// ============================================================================
// COLLECTED RESULTS (for chart generation)
// ============================================================================

const Results = struct {
    // Latency
    lat_p50: u64 = 0,
    lat_p90: u64 = 0,
    lat_p99: u64 = 0,
    lat_p999: u64 = 0,
    lat_min: u64 = 0,
    lat_max: u64 = 0,
    lat_mean: f64 = 0,

    // SPSC throughput (batch sizes)
    spsc_batch_labels: [7][]const u8 = .{ "1", "8", "64", "512", "1K", "4K", "32K" },
    spsc_batch_rates: [7]f64 = .{0} ** 7,

    // Ring size sweep
    ring_labels: [6][]const u8 = .{ "1K", "4K", "16K", "32K", "64K", "256K" },
    ring_rates: [6]f64 = .{0} ** 6,

    // MPSC scaling
    mpsc_labels: [5][]const u8 = .{ "1P", "2P", "4P", "6P", "8P" },
    mpsc_rates: [5]f64 = .{0} ** 5,

    // MPMC scaling
    mpmc_labels: [7][]const u8 = .{ "1P1C", "2P1C", "4P1C", "4P2C", "8P1C", "8P2C", "8P4C" },
    mpmc_rates: [7]f64 = .{0} ** 7,

    // SPMC scaling
    spmc_labels: [5][]const u8 = .{ "1C", "2C", "4C", "6C", "8C" },
    spmc_rates: [5]f64 = .{0} ** 5,

    // Batch size sweep
    bsweep_labels: [8][]const u8 = .{ "1", "16", "256", "1K", "4K", "8K", "16K", "32K" },
    bsweep_rates: [8]f64 = .{0} ** 8,
};

// ============================================================================
// HTML REPORT GENERATION
// ============================================================================

fn generateReport(allocator: std.mem.Allocator, r: *const Results) !void {
    var h = report.HtmlWriter.init(allocator);
    defer h.deinit();

    report.writeHtmlHeader(&h);

    // Header
    h.w("<h1>ringmpsc Benchmark Report</h1>\n");

    const features = ringmpsc.primitives.simd.SimdFeatures.detect();
    h.print("<p class=\"subtitle\">{s} &middot; AVX2: {s} &middot; AVX-512: {s}</p>\n", .{
        @tagName(@import("builtin").target.cpu.arch),
        if (features.has_avx2) "yes" else "no",
        if (features.has_avx512) "yes" else "no",
    });

    // Key metrics
    h.w("<div class=\"metrics-row\">\n");
    h.print("<div class=\"metric\"><div class=\"value\">{d:.2} B/s</div><div class=\"label\">Peak MPSC (8P)</div></div>\n", .{r.mpsc_rates[4]});
    h.print("<div class=\"metric\"><div class=\"value\">{d:.2} B/s</div><div class=\"label\">Peak SPMC (1P8C)</div></div>\n", .{r.spmc_rates[4]});
    h.print("<div class=\"metric\"><div class=\"value\">{d:.2} B/s</div><div class=\"label\">Peak MPMC (8P1C)</div></div>\n", .{r.mpmc_rates[4]});
    h.print("<div class=\"metric\"><div class=\"value\">{}ns</div><div class=\"label\">SPSC p50 latency</div></div>\n", .{r.lat_p50});
    h.print("<div class=\"metric\"><div class=\"value\">{}ns</div><div class=\"label\">SPSC p99 latency</div></div>\n", .{r.lat_p99});
    h.w("</div>\n");

    // Section 1: Latency
    h.w("<h2>1. SPSC Latency</h2>\n");
    h.w("<div class=\"card\">\n");
    report.latencyBoxChart(&h, r.lat_p50, r.lat_p90, r.lat_p99, r.lat_p999, r.lat_min, r.lat_max, 600, 300);
    h.w("</div>\n");

    // Section 2-3: SPSC + Ring Size
    h.w("<h2>2. SPSC Throughput &amp; Ring Size</h2>\n");
    h.w("<div class=\"chart-grid\">\n");
    h.w("<div class=\"card\">\n");
    report.barChart(&h, "SPSC Throughput by Batch Size", &r.spsc_batch_labels, &r.spsc_batch_rates, "M msgs/sec (millions)", 560, 320);
    h.w("</div>\n");
    h.w("<div class=\"card\">\n");
    report.barChart(&h, "Throughput by Ring Capacity", &r.ring_labels, &r.ring_rates, "M msgs/sec (millions)", 560, 320);
    h.w("</div>\n");
    h.w("</div>\n");

    // Section 4: MPSC Scaling
    h.w("<h2>3. MPSC Producer Scaling</h2>\n");
    h.w("<div class=\"card\">\n");
    report.barChart(&h, "MPSC Throughput vs Producer Count", &r.mpsc_labels, &r.mpsc_rates, "B msgs/sec (billions)", 700, 350);
    h.w("</div>\n");

    // Section 5: SPMC + MPMC Scaling
    h.w("<h2>4. Multi-Consumer Scaling</h2>\n");
    h.w("<div class=\"chart-grid\">\n");
    h.w("<div class=\"card\">\n");
    report.barChart(&h, "SPMC (1 Producer, N Consumers)", &r.spmc_labels, &r.spmc_rates, "B msgs/sec (billions)", 560, 320);
    h.w("</div>\n");
    h.w("<div class=\"card\">\n");
    report.barChart(&h, "MPMC (Work-Stealing)", &r.mpmc_labels, &r.mpmc_rates, "B msgs/sec (billions)", 560, 320);
    h.w("</div>\n");
    h.w("</div>\n");

    // Section 6: Batch Size Sweep
    h.w("<h2>5. Batch Size Impact (4P MPSC)</h2>\n");
    h.w("<div class=\"card\">\n");
    report.barChart(&h, "MPSC Throughput vs Batch Size", &r.bsweep_labels, &r.bsweep_rates, "B msgs/sec (billions)", 700, 350);
    h.w("</div>\n");

    // Tables
    h.w("<h2>6. Detailed Results</h2>\n");
    h.w("<div class=\"card\">\n");
    h.w("<table><tr><th>Benchmark</th><th>Configuration</th><th>Throughput</th></tr>\n");
    for (r.mpsc_labels, 0..) |label, i| {
        h.print("<tr><td>MPSC</td><td>{s}</td><td>{d:.2} B/s</td></tr>\n", .{ label, r.mpsc_rates[i] });
    }
    for (r.mpmc_labels, 0..) |label, i| {
        h.print("<tr><td>MPMC</td><td>{s}</td><td>{d:.2} B/s</td></tr>\n", .{ label, r.mpmc_rates[i] });
    }
    h.w("</table>\n");
    h.w("</div>\n");

    report.writeHtmlFooter(&h);

    // Write to file
    std.fs.cwd().makePath("benchmarks/results") catch {};
    var file = try std.fs.cwd().createFile("benchmarks/results/report.html", .{});
    defer file.close();
    try file.writeAll(h.output());
}

// ============================================================================
// MAIN
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var j = JsonWriter.init(allocator);
    defer j.deinit();

    var r = Results{};

    // Progress goes to stderr via std.debug.print
    _ = &r;

    j.beginObject();

    j.key("version");
    j.valStr("1.0");
    j.key("library");
    j.valStr("ringmpsc");

    j.key("system");
    j.beginObject();
    {
        j.key("cpu_count");
        j.valInt(CPU_COUNT);
        j.key("arch");
        j.valStr(@tagName(@import("builtin").target.cpu.arch));

        const features = ringmpsc.primitives.simd.SimdFeatures.detect();
        j.key("avx2");
        if (features.has_avx2) j.valStr("true") else j.valStr("false");
        j.key("avx512");
        if (features.has_avx512) j.valStr("true") else j.valStr("false");
    }
    j.endObject();

    j.key("benchmarks");
    j.beginObject();

    // 1. SPSC latency
    std.debug.print("[1/7] SPSC latency...\n", .{});
    benchSpscLatency(&j);
    // Collect latency results (re-run cheaply for the report)
    {
        const Config = ringmpsc.primitives.Config{ .ring_bits = 12, .max_producers = 1 };
        var ring = ringmpsc.primitives.Ring(u64, Config){};
        const N = 50_000;
        var lats: [N]u64 = undefined;
        for (0..500) |i| {
            if (ring.reserve(1)) |rv| { rv.slice[0] = i; ring.commit(1); }
            _ = ring.tryRecv();
        }
        for (&lats) |*lat| {
            const t0 = std.time.Instant.now() catch unreachable;
            if (ring.reserve(1)) |rv| { rv.slice[0] = 42; ring.commit(1); }
            _ = ring.tryRecv();
            lat.* = (std.time.Instant.now() catch unreachable).since(t0);
        }
        sortU64(&lats);
        r.lat_p50 = percentile(&lats, 0.50);
        r.lat_p90 = percentile(&lats, 0.90);
        r.lat_p99 = percentile(&lats, 0.99);
        r.lat_p999 = percentile(&lats, 0.999);
        r.lat_min = lats[0];
        r.lat_max = lats[N - 1];
        r.lat_mean = mean(&lats);
    }

    // 2. SPSC throughput — collect for charts
    std.debug.print("[2/7] SPSC throughput (batch sweep)...\n", .{});
    benchSpscThroughput(&j);
    // Collect SPSC throughput values for chart (run quick single-threaded measurement)
    {
        const batch_sizes_chart = [_]usize{ 1, 8, 64, 512, 1024, 4096, 32768 };
        inline for (batch_sizes_chart, 0..) |bs, idx| {
            const Cfg = ringmpsc.primitives.Config{ .ring_bits = 16, .max_producers = 1 };
            var cring = ringmpsc.primitives.Ring(u64, Cfg){};
            var cbuf: [bs]u64 = undefined;
            for (&cbuf, 0..) |*b, i| b.* = i;
            const CTOTAL: u64 = 2_000_000;
            const ct0 = std.time.Instant.now() catch unreachable;
            var csent: u64 = 0;
            var crecvd: u64 = 0;
            while (csent < CTOTAL or crecvd < csent) {
                if (csent < CTOTAL) csent += cring.send(&cbuf);
                var cout: [bs]u64 = undefined;
                crecvd += cring.recv(&cout);
            }
            const celapsed = (std.time.Instant.now() catch unreachable).since(ct0);
            r.spsc_batch_rates[idx] = @as(f64, @floatFromInt(crecvd)) / (@as(f64, @floatFromInt(celapsed)) / 1e9) / 1e6;
        }
    }

    // 3. Ring size sweep — collect for charts
    std.debug.print("[3/7] Ring size sweep...\n", .{});
    benchRingSizeSweep(&j);
    // Collect ring size values for chart
    {
        const ring_bits_chart = [_]comptime_int{ 10, 12, 14, 15, 16, 18 };
        inline for (ring_bits_chart, 0..) |bits, idx| {
            const Cfg = ringmpsc.primitives.Config{ .ring_bits = bits, .max_producers = 1 };
            var rring = ringmpsc.primitives.Ring(u64, Cfg){};
            const RBATCH: usize = @min(1024, (@as(usize, 1) << bits) / 2);
            const RTOTAL: u64 = 2_000_000;
            var rbuf: [RBATCH]u64 = undefined;
            for (&rbuf, 0..) |*b, i| b.* = i;
            rring.reset();
            const rt0 = std.time.Instant.now() catch unreachable;
            var rsent: u64 = 0;
            var rrecvd: u64 = 0;
            while (rrecvd < RTOTAL) {
                if (rsent < RTOTAL) rsent += rring.send(rbuf[0..RBATCH]);
                var rout: [RBATCH]u64 = undefined;
                rrecvd += rring.recv(&rout);
            }
            const relapsed = (std.time.Instant.now() catch unreachable).since(rt0);
            r.ring_rates[idx] = @as(f64, @floatFromInt(rrecvd)) / (@as(f64, @floatFromInt(relapsed)) / 1e9) / 1e6;
        }
    }

    // 4. MPSC scaling — collect results
    std.debug.print("[4/7] MPSC scaling (1-8 producers)...\n", .{});
    {
        j.key("mpsc_scaling");
        j.beginArray();
        const counts = [_]usize{ 1, 2, 4, 6, 8 };
        for (counts, 0..) |np, idx| {
            const rate = runMpscTest(allocator, np) catch 0;
            r.mpsc_rates[idx] = rate / 1e9;

            j.arrayElement();
            j.beginObject();
            j.key("producers"); j.valInt(np);
            j.key("msgs_per_sec"); j.valFloat(rate);
            j.key("billions_per_sec"); j.valFloat(rate / 1e9);
            j.endObject();
        }
        j.endArray();
    }

    // 5. MPMC scaling — collect results
    std.debug.print("[5/7] MPMC scaling (P x C matrix)...\n", .{});
    {
        j.key("mpmc_scaling");
        j.beginArray();
        const configs = [_]struct { p: usize, c: usize }{
            .{ .p = 1, .c = 1 }, .{ .p = 2, .c = 1 }, .{ .p = 4, .c = 1 },
            .{ .p = 4, .c = 2 }, .{ .p = 8, .c = 1 }, .{ .p = 8, .c = 2 },
            .{ .p = 8, .c = 4 },
        };
        for (configs, 0..) |cfg, idx| {
            const rate = runMpmcTest(cfg.p, cfg.c) catch 0;
            r.mpmc_rates[idx] = rate / 1e9;

            j.arrayElement();
            j.beginObject();
            j.key("producers"); j.valInt(cfg.p);
            j.key("consumers"); j.valInt(cfg.c);
            j.key("msgs_per_sec"); j.valFloat(rate);
            j.key("billions_per_sec"); j.valFloat(rate / 1e9);
            j.endObject();
        }
        j.endArray();
    }

    // 6. SPMC scaling — collect results
    std.debug.print("[6/7] SPMC scaling (1-8 consumers)...\n", .{});
    {
        j.key("spmc_scaling");
        j.beginArray();
        const consumer_counts = [_]usize{ 1, 2, 4, 6, 8 };
        for (consumer_counts, 0..) |nc, idx| {
            const rate = runSpmcTest(nc) catch 0;
            r.spmc_rates[idx] = rate / 1e9;

            j.arrayElement();
            j.beginObject();
            j.key("consumers"); j.valInt(nc);
            j.key("msgs_per_sec"); j.valFloat(rate);
            j.key("billions_per_sec"); j.valFloat(rate / 1e9);
            j.endObject();
        }
        j.endArray();
    }

    // 7. Batch size sweep — collect results
    std.debug.print("[7/7] Batch size sweep...\n", .{});
    {
        j.key("batch_size_sweep");
        j.beginArray();
        const sizes = [_]usize{ 1, 16, 256, 1024, 4096, 8192, 16384, 32768 };
        for (sizes, 0..) |bs, idx| {
            const rate = runBatchSweepTest(4, bs, 20_000_000) catch 0;
            r.bsweep_rates[idx] = rate / 1e9;

            j.arrayElement();
            j.beginObject();
            j.key("batch_size"); j.valInt(bs);
            j.key("producers"); j.valInt(4);
            j.key("msgs_per_sec"); j.valFloat(rate);
            j.key("billions_per_sec"); j.valFloat(rate / 1e9);
            j.endObject();
        }
        j.endArray();
    }

    j.endObject(); // benchmarks
    j.endObject(); // root

    // JSON to file
    std.fs.cwd().makePath("benchmarks/results") catch {};
    {
        var json_file = try std.fs.cwd().createFile("benchmarks/results/results.json", .{});
        defer json_file.close();
        try json_file.writeAll(j.output());
        try json_file.writeAll("\n");
    }

    // HTML report
    std.debug.print("\nGenerating HTML report...\n", .{});
    try generateReport(allocator, &r);
    std.debug.print("Report: benchmarks/results/report.html\n", .{});

    // Append to history (JSONL — one JSON object per line)
    {
        var history_file = std.fs.cwd().openFile("benchmarks/results/history.jsonl", .{ .mode = .write_only }) catch |err| blk: {
            if (err == error.FileNotFound) {
                break :blk try std.fs.cwd().createFile("benchmarks/results/history.jsonl", .{});
            }
            return err;
        };
        defer history_file.close();
        // Seek to end for append
        history_file.seekFromEnd(0) catch {};
        try history_file.writeAll(j.output());
        try history_file.writeAll("\n");
    }
    std.debug.print("History: benchmarks/results/history.jsonl\n", .{});
}
