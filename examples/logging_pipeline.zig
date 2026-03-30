//! Real-world example: structured logging pipeline
//!
//! Multiple application threads produce log entries (level + timestamp + message).
//! A single consumer thread batches them and writes to stdout, simulating a
//! high-throughput logging backend (file, network, or database sink).
//!
//! This pattern is common in:
//!   - Application logging (replace println with non-blocking send)
//!   - Metrics/telemetry ingestion pipelines
//!   - Audit trail systems
//!   - Network packet capture (producer = NIC rx, consumer = pcap writer)

const std = @import("std");
const ringmpsc = @import("ringmpsc");

const LogLevel = enum(u8) { debug, info, warn, err };

const LogEntry = struct {
    timestamp_ns: i128,
    level: LogLevel,
    thread_id: usize,
    message: [128]u8,
    message_len: u8,

    fn init(level: LogLevel, thread_id: usize, msg: []const u8) LogEntry {
        var entry: LogEntry = .{
            .timestamp_ns = std.time.nanoTimestamp(),
            .level = level,
            .thread_id = thread_id,
            .message = undefined,
            .message_len = @intCast(@min(msg.len, 128)),
        };
        @memcpy(entry.message[0..entry.message_len], msg[0..entry.message_len]);
        return entry;
    }

    fn levelStr(self: LogEntry) []const u8 {
        return switch (self.level) {
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
        };
    }
};

const ChannelConfig = ringmpsc.mpsc.Config{
    .ring_bits = 14, // 16K entries per producer — ~2.5 MB per ring
    .max_producers = 8,
};
const Channel = ringmpsc.mpsc.Channel(LogEntry, ChannelConfig);

const NUM_THREADS = 4;
const MSGS_PER_THREAD = 50_000;

pub fn main() !void {
    var channel = try Channel.init(std.heap.page_allocator);
    defer channel.deinit();

    // --- Spawn application threads (producers) ---
    var threads: [NUM_THREADS]std.Thread = undefined;
    for (0..NUM_THREADS) |i| {
        const producer = try channel.register();
        threads[i] = try std.Thread.spawn(.{}, applicationThread, .{ producer, i });
    }

    // --- Consumer: logging backend ---
    var entries_written: u64 = 0;
    var bytes_written: u64 = 0;
    const expected = NUM_THREADS * MSGS_PER_THREAD;
    const t0 = std.time.nanoTimestamp();

    const Writer = struct {
        entries: *u64,
        bytes: *u64,

        pub fn process(self: @This(), entry: *const LogEntry) void {
            // In production: write to file, send over network, insert into DB.
            // Here we just count to measure throughput without I/O bottleneck.
            self.entries.* += 1;
            self.bytes.* += entry.message_len;
        }
    };

    while (entries_written < expected) {
        const n = channel.consumeAll(Writer{ .entries = &entries_written, .bytes = &bytes_written });
        if (n == 0) {
            // No data — yield to avoid busy-spinning.
            // In production, use consumeBatchBlocking() with a WaitStrategy instead.
            std.Thread.yield() catch {};
        }
    }

    const elapsed_ns = std.time.nanoTimestamp() - t0;

    // Wait for all producers
    for (&threads) |*t| t.join();

    // Drain any stragglers
    _ = channel.consumeAll(Writer{ .entries = &entries_written, .bytes = &bytes_written });

    // --- Report ---
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const throughput = @as(f64, @floatFromInt(entries_written)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0);

    std.debug.print(
        \\Logging pipeline results:
        \\  Threads:    {d} producers, 1 consumer
        \\  Entries:    {d} logged
        \\  Payload:    {d} KB
        \\  Time:       {d:.1} ms
        \\  Throughput: {d:.1} M entries/s
        \\  Zero dropped, zero contention between producers
        \\
    , .{
        NUM_THREADS,
        entries_written,
        bytes_written / 1024,
        elapsed_ms,
        throughput / 1_000_000.0,
    });
}

fn applicationThread(producer: Channel.Producer, thread_id: usize) void {
    var bo = ringmpsc.primitives.Backoff{};
    var buf: [64]u8 = undefined;

    for (0..MSGS_PER_THREAD) |seq| {
        // Simulate real application log calls at varying levels
        const level: LogLevel = switch (seq % 20) {
            0 => .err,
            1, 2 => .warn,
            3, 4, 5, 6 => .debug,
            else => .info,
        };

        const msg = std.fmt.bufPrint(&buf, "thread {d} op #{d}", .{ thread_id, seq }) catch "?";
        const entry = LogEntry.init(level, thread_id, msg);

        while (!producer.sendOne(entry)) {
            // Ring full — back off. In production this is the backpressure signal.
            bo.snooze();
        }
        bo.reset();
    }
}
