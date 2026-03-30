//! ringmpsc — SPMC Channel (Single-Producer Multi-Consumer)
//!
//! A single ring buffer where one producer writes (no CAS needed on tail)
//! and multiple consumers compete for items via CAS on head. Each consumer
//! atomically claims a batch of items before processing them.
//!
//! Design tradeoffs vs MPMC:
//!   - No per-producer ring decomposition (only one producer)
//!   - Simpler memory layout (single contiguous ring)
//!   - Consumer contention on head is the bottleneck
//!   - Best for fan-out patterns: one source, many sinks

const std = @import("std");
const ring_mod = @import("../primitives/ring_buffer.zig");

pub const Backoff = ring_mod.Backoff;

// ============================================================================
// CONFIGURATION
// ============================================================================

pub const SpmcConfig = struct {
    /// Ring buffer size as power of 2
    ring_bits: u6 = 16,
    /// Maximum number of consumers
    max_consumers: usize = 16,
    /// Enable metrics collection
    enable_metrics: bool = false,
    /// Minimum batch size before prefetching kicks in (0 = disabled)
    prefetch_threshold: usize = 16,
};

pub const default_config = SpmcConfig{};
pub const high_throughput_config = SpmcConfig{ .ring_bits = 18, .max_consumers = 32 };
pub const low_latency_config = SpmcConfig{ .ring_bits = 12 };

// ============================================================================
// SPMC CHANNEL
// ============================================================================

pub fn Channel(comptime T: type, comptime config: SpmcConfig) type {
    const CAPACITY = @as(usize, 1) << config.ring_bits;
    const MASK = CAPACITY - 1;

    return struct {
        const Self = @This();

        // === PRODUCER HOT === (128-byte aligned)
        tail: std.atomic.Value(u64) align(128) = std.atomic.Value(u64).init(0),
        cached_head: u64 = 0,

        // === CONSUMER HOT === (128-byte aligned, contested via CAS)
        head: std.atomic.Value(u64) align(128) = std.atomic.Value(u64).init(0),

        // === COLD STATE ===
        closed: std.atomic.Value(bool) align(128) = std.atomic.Value(bool).init(false),
        consumer_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        // === DATA BUFFER ===
        buffer: [CAPACITY]T align(64) = undefined,

        // -----------------------------------------------------------------
        // CONSTANTS
        // -----------------------------------------------------------------

        pub fn capacity() usize {
            return CAPACITY;
        }

        // -----------------------------------------------------------------
        // PRODUCER API (single producer — no CAS needed)
        // -----------------------------------------------------------------

        pub const Reservation = ring_mod.Reservation(T);

        /// Reserve n slots for zero-copy writing. Returns null if full/closed.
        pub inline fn reserve(self: *Self, n: usize) ?Reservation {
            if (n == 0 or n > CAPACITY) return null;
            if (self.closed.load(.acquire)) return null;

            const tail_val = self.tail.load(.monotonic);

            // Fast path: check cached head
            var space = CAPACITY -| @as(usize, @intCast(tail_val -% self.cached_head));
            if (space >= n) {
                return self.makeReservation(tail_val, n);
            }

            // Slow path: refresh cached head
            self.cached_head = self.head.load(.acquire);
            space = CAPACITY -| @as(usize, @intCast(tail_val -% self.cached_head));
            if (space < n) return null;

            return self.makeReservation(tail_val, n);
        }

        inline fn makeReservation(self: *Self, tail_val: u64, n: usize) Reservation {
            const idx = tail_val & MASK;
            const contiguous = @min(n, CAPACITY - idx);

            if (config.prefetch_threshold > 0 and n >= config.prefetch_threshold) {
                @prefetch(&self.buffer[idx], .{ .rw = .write, .locality = 3, .cache = .data });
            }

            return .{ .slice = self.buffer[idx..][0..contiguous], .pos = tail_val };
        }

        /// Commit n slots after writing.
        pub inline fn commit(self: *Self, n: usize) void {
            const tail_val = self.tail.load(.monotonic);
            self.tail.store(tail_val +% n, .release);
        }

        /// Convenience: send a single item.
        pub inline fn sendOne(self: *Self, item: T) bool {
            const r = self.reserve(1) orelse return false;
            r.slice[0] = item;
            self.commit(1);
            return true;
        }

        /// Convenience: batch send.
        pub inline fn send(self: *Self, items: []const T) usize {
            const r = self.reserve(items.len) orelse return 0;
            @memcpy(r.slice, items[0..r.slice.len]);
            self.commit(r.slice.len);
            return r.slice.len;
        }

        // -----------------------------------------------------------------
        // CONSUMER API (multi-consumer — CAS on head)
        // -----------------------------------------------------------------

        pub const Consumer = struct {
            channel: *Self,
            id: usize,
            consumer_backoff: Backoff = .{},

            /// Try to steal up to `out.len` items. Returns count stolen.
            /// Uses CAS to atomically claim items from head.
            /// Includes exponential backoff on CAS contention to prevent
            /// CPU waste and live-lock under high consumer counts.
            pub fn steal(self: *Consumer, out: []T) usize {
                if (out.len == 0) return 0;
                var retries: u32 = 0;

                while (true) {
                    const head_val = self.channel.head.load(.acquire);
                    const tail_val = self.channel.tail.load(.acquire);
                    const avail: usize = @intCast(tail_val -% head_val);

                    if (avail == 0) return 0;

                    const n = @min(out.len, @min(avail, CAPACITY));
                    const start: usize = @intCast(head_val & MASK);

                    // Copy data before CAS (speculatively)
                    if (start + n <= CAPACITY) {
                        @memcpy(out[0..n], self.channel.buffer[start..][0..n]);
                    } else {
                        const first = CAPACITY - start;
                        @memcpy(out[0..first], self.channel.buffer[start..CAPACITY]);
                        @memcpy(out[first..n], self.channel.buffer[0 .. n - first]);
                    }

                    // CAS to claim
                    const new_head = head_val +% n;
                    if (self.channel.head.cmpxchgWeak(head_val, new_head, .acq_rel, .monotonic)) |_| {
                        // Another consumer won — backoff before retry
                        retries += 1;
                        if (retries < 8) {
                            // Spin with PAUSE hints
                            var spins: u32 = @as(u32, 1) << @min(retries, 6);
                            while (spins > 0) : (spins -= 1) {
                                std.atomic.spinLoopHint();
                            }
                        } else {
                            // Yield after 8 retries to prevent live-lock
                            std.Thread.yield() catch {};
                        }
                        continue;
                    }

                    return n;
                }
            }

            /// Steal a single item. Returns null if empty.
            pub fn stealOne(self: *Consumer) ?T {
                var buf: [1]T = undefined;
                if (self.steal(&buf) == 1) return buf[0];
                return null;
            }

            /// Consume with handler callback (CAS-first, then process).
            pub fn consumeBatch(self: *Consumer, comptime Handler: type, handler: Handler) usize {
                const head_val = self.channel.head.load(.acquire);
                const tail_val = self.channel.tail.load(.acquire);
                const raw_avail: usize = @intCast(tail_val -% head_val);

                if (raw_avail == 0) return 0;

                const MAX_STEAL = 4096;
                const avail = @min(raw_avail, MAX_STEAL);
                const start: usize = @intCast(head_val & MASK);

                // Copy to stack before CAS for correctness
                var temp_buf: [MAX_STEAL]T = undefined;
                if (start + avail <= CAPACITY) {
                    @memcpy(temp_buf[0..avail], self.channel.buffer[start..][0..avail]);
                } else {
                    const first = CAPACITY - start;
                    @memcpy(temp_buf[0..first], self.channel.buffer[start..CAPACITY]);
                    @memcpy(temp_buf[first..avail], self.channel.buffer[0 .. avail - first]);
                }

                // CAS to claim
                const new_head = head_val +% avail;
                if (self.channel.head.cmpxchgWeak(head_val, new_head, .acq_rel, .monotonic)) |_| {
                    return 0; // Lost race
                }

                // Process from stack buffer
                for (temp_buf[0..avail]) |*item| {
                    handler.process(item);
                }

                return avail;
            }
        };

        pub fn registerConsumer(self: *Self) error{ TooManyConsumers, Closed }!Consumer {
            if (self.closed.load(.acquire)) return error.Closed;

            const id = self.consumer_count.fetchAdd(1, .monotonic);
            if (id >= config.max_consumers) {
                _ = self.consumer_count.fetchSub(1, .monotonic);
                return error.TooManyConsumers;
            }

            return .{ .channel = self, .id = id };
        }

        // -----------------------------------------------------------------
        // STATUS
        // -----------------------------------------------------------------

        pub inline fn len(self: *const Self) usize {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.monotonic);
            return @intCast(t -% h);
        }

        pub inline fn isEmpty(self: *const Self) bool {
            return self.tail.load(.monotonic) == self.head.load(.monotonic);
        }

        pub inline fn isClosed(self: *const Self) bool {
            return self.closed.load(.acquire);
        }

        pub fn totalPending(self: *const Self) usize {
            return self.len();
        }

        // -----------------------------------------------------------------
        // LIFECYCLE
        // -----------------------------------------------------------------

        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }
    };
}

// Type alias
pub const DefaultChannel = Channel(u64, default_config);
