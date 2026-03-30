//! ringmpsc - Metrics primitives for throughput and latency tracking.
//!
//! All fields are updated atomically (via @atomicRmw in ring_buffer.zig)
//! when Config.enable_metrics is true. When disabled, the Metrics struct
//! is comptime-eliminated to void — zero overhead.

pub const Metrics = struct {
    // Throughput counters
    messages_sent: u64 = 0,
    messages_received: u64 = 0,
    batches_sent: u64 = 0,
    batches_received: u64 = 0,

    // Backpressure counters
    reserve_spins: u64 = 0,
    reserve_failures: u64 = 0,
    total_wait_ns: u64 = 0,
    max_batch_size: u64 = 0,

    // Latency tracking (per-batch, nanoseconds)
    // Updated in consumeBatch: elapsed = now - batch_start
    latency_sum_ns: u64 = 0,
    latency_count: u64 = 0,
    latency_min_ns: u64 = ~@as(u64, 0), // max value sentinel = "no samples yet"
    latency_max_ns: u64 = 0,

    /// Average batch latency in nanoseconds. Returns 0 if no samples.
    pub fn avgLatencyNs(self: Metrics) f64 {
        if (self.latency_count == 0) return 0;
        return @as(f64, @floatFromInt(self.latency_sum_ns)) / @as(f64, @floatFromInt(self.latency_count));
    }

    /// Minimum batch latency. Returns 0 if no samples collected
    /// (avoids returning the u64 max sentinel value).
    pub fn minLatencyNs(self: Metrics) u64 {
        if (self.latency_count == 0) return 0;
        return self.latency_min_ns;
    }

    /// Average batch size (messages per batch).
    pub fn avgBatchSize(self: Metrics) f64 {
        if (self.batches_received == 0) return 0;
        return @as(f64, @floatFromInt(self.messages_received)) / @as(f64, @floatFromInt(self.batches_received));
    }

    /// Throughput in messages per second given elapsed nanoseconds.
    pub fn throughputPerSecond(self: Metrics, elapsed_ns: u64) f64 {
        if (elapsed_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.messages_received)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);
    }

    /// Merge metrics from another ring (used by MPSC channel).
    pub fn merge(self: *Metrics, other: Metrics) void {
        self.messages_sent += other.messages_sent;
        self.messages_received += other.messages_received;
        self.batches_sent += other.batches_sent;
        self.batches_received += other.batches_received;
        self.reserve_spins += other.reserve_spins;
        self.reserve_failures += other.reserve_failures;
        self.total_wait_ns += other.total_wait_ns;
        self.max_batch_size = @max(self.max_batch_size, other.max_batch_size);
        self.latency_sum_ns += other.latency_sum_ns;
        self.latency_count += other.latency_count;
        self.latency_min_ns = @min(self.latency_min_ns, other.latency_min_ns);
        self.latency_max_ns = @max(self.latency_max_ns, other.latency_max_ns);
    }

    /// Reset all counters.
    pub fn reset(self: *Metrics) void {
        self.* = .{};
    }
};
