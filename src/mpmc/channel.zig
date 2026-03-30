//! ringmpsc - MPMC Channel (Multi-Producer Multi-Consumer)
//!
//! Progressive work-stealing architecture:
//! - Phase 1: Local shards (primary locality)
//! - Phase 2: Hot rings (load balancing)
//! - Phase 3: Random fallback (starvation prevention)

const std = @import("std");
const ring_mod = @import("../primitives/ring_buffer.zig");

pub const Reservation = ring_mod.Reservation;
pub const Backoff = ring_mod.Backoff;

// ============================================================================
// MPMC CONFIGURATION
// ============================================================================

pub const MpmcConfig = struct {
    /// Ring buffer size as power of 2
    ring_bits: u6 = 14,
    /// Maximum number of producers
    max_producers: usize = 16,
    /// Maximum number of consumers
    max_consumers: usize = 16,
    /// Enable metrics collection
    enable_metrics: bool = false,
    /// Rings per consumer shard (locality tuning)
    rings_per_shard: usize = 2,
    /// NUMA node hint (-1 = auto-detect from thread affinity)
    numa_node: i8 = -1,
    /// Enable NUMA-aware allocation (auto-detect thread's node)
    numa_aware: bool = true,
};

pub const default_mpmc_config = MpmcConfig{};
pub const high_throughput_mpmc_config = MpmcConfig{
    .ring_bits = 16,
    .max_producers = 32,
    .max_consumers = 16,
    .rings_per_shard = 4,
};

// ============================================================================
// MPMC RING (with atomic head for work-stealing)
// ============================================================================

pub fn MpmcRing(comptime T: type, comptime config: MpmcConfig) type {
    const CAPACITY = @as(usize, 1) << config.ring_bits;
    const MASK = CAPACITY - 1;

    return struct {
        const Self = @This();

        // === PRODUCER HOT === (128-byte aligned)
        tail: std.atomic.Value(u64) align(128) = std.atomic.Value(u64).init(0),
        cached_head: u64 = 0,

        // === CONSUMER HOT === (128-byte aligned, atomic for stealing)
        head: std.atomic.Value(u64) align(128) = std.atomic.Value(u64).init(0),
        cached_tail: u64 = 0,

        // === STEALING METADATA ===
        hotness: std.atomic.Value(u32) align(64) = std.atomic.Value(u32).init(0),
        owner_consumer: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

        // === STATE ===
        active: std.atomic.Value(bool) align(64) = std.atomic.Value(bool).init(false),
        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        // === DATA BUFFER ===
        buffer: [CAPACITY]T align(64) = undefined,

        pub fn capacity() usize {
            return CAPACITY;
        }

        /// Producer: Reserve slots
        pub inline fn reserve(self: *Self, n: usize) ?Reservation(T) {
            if (n == 0 or n > CAPACITY) return null;
            if (self.closed.load(.acquire)) return null;

            const t = self.tail.load(.monotonic);
            var avail: usize = CAPACITY -% @as(usize, @intCast(t -% self.cached_head));

            if (avail < n) {
                self.cached_head = self.head.load(.acquire);
                avail = CAPACITY -% @as(usize, @intCast(t -% self.cached_head));
                if (avail < n) return null;
            }

            const start: usize = @intCast(t & MASK);
            const end = start + n;

            if (end <= CAPACITY) {
                return .{ .slice = self.buffer[start..end], .pos = t };
            } else {
                return .{ .slice = self.buffer[start..CAPACITY], .pos = t };
            }
        }

        /// Producer: Commit reserved slots
        pub inline fn commit(self: *Self, n: usize) void {
            const new_tail = self.tail.load(.monotonic) +% n;
            self.tail.store(new_tail, .release);

            const h = @as(u32, @intCast(@min(n, 255)));
            _ = self.hotness.fetchAdd(h, .monotonic);
        }

        /// Consumer: Try to steal items (CAS-based for MPMC safety)
        pub fn trySteal(self: *Self, out: []T) usize {
            if (out.len == 0) return 0;
            var retries: u32 = 0;

            while (true) {
                const head_val = self.head.load(.acquire);
                const tail_val = self.tail.load(.acquire);
                const raw_avail: usize = @intCast(tail_val -% head_val);
                const avail = @min(raw_avail, CAPACITY);

                if (avail == 0) return 0;

                const n = @min(out.len, avail);
                const start: usize = @intCast(head_val & MASK);

                // Copy data first (before CAS)
                if (start + n <= CAPACITY) {
                    @memcpy(out[0..n], self.buffer[start..][0..n]);
                } else {
                    const first = CAPACITY - start;
                    @memcpy(out[0..first], self.buffer[start..CAPACITY]);
                    @memcpy(out[first..n], self.buffer[0 .. n - first]);
                }

                // CAS to claim the items
                const new_head = head_val +% n;
                if (self.head.cmpxchgWeak(head_val, new_head, .acq_rel, .monotonic)) |_| {
                    // Backoff on CAS contention
                    retries += 1;
                    if (retries < 8) {
                        var spins: u32 = @as(u32, 1) << @min(retries, 6);
                        while (spins > 0) : (spins -= 1) std.atomic.spinLoopHint();
                    } else {
                        std.Thread.yield() catch {};
                    }
                    continue;
                }

                const h = @as(u32, @intCast(@min(n, 255)));
                _ = self.hotness.fetchSub(h, .monotonic);

                return n;
            }
        }

        /// Consumer: Consume with handler (CAS-first for correctness)
        pub fn consumeSteal(self: *Self, comptime Handler: type, handler: Handler) usize {
            const head_val = self.head.load(.acquire);
            const tail_val = self.tail.load(.acquire);
            const raw_avail: usize = @intCast(tail_val -% head_val);

            if (raw_avail == 0) return 0;

            const MAX_STEAL = 4096;
            const avail = @min(raw_avail, MAX_STEAL);
            const start: usize = @intCast(head_val & MASK);

            // Stack buffer - must copy BEFORE CAS for correctness
            var temp_buf: [MAX_STEAL]T = undefined;
            if (start + avail <= CAPACITY) {
                @memcpy(temp_buf[0..avail], self.buffer[start..][0..avail]);
            } else {
                const first = CAPACITY - start;
                @memcpy(temp_buf[0..first], self.buffer[start..CAPACITY]);
                @memcpy(temp_buf[first..avail], self.buffer[0 .. avail - first]);
            }

            // CAS to claim
            const new_head = head_val +% avail;
            if (self.head.cmpxchgWeak(head_val, new_head, .acq_rel, .monotonic)) |_| {
                return 0;
            }

            // Process from temp buffer
            for (temp_buf[0..avail]) |*item| {
                handler.process(item);
            }

            const h = @as(u32, @intCast(@min(avail, 255)));
            _ = self.hotness.fetchSub(h, .monotonic);

            return avail;
        }

        pub inline fn available(self: *const Self) usize {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.monotonic);
            return @intCast(t -% h);
        }

        pub inline fn getHotness(self: *const Self) u32 {
            return self.hotness.load(.monotonic);
        }

        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }

        pub fn isClosed(self: *const Self) bool {
            return self.closed.load(.acquire);
        }
    };
}

// ============================================================================
// MPMC CHANNEL
// ============================================================================

pub fn MpmcChannel(comptime T: type, comptime config: MpmcConfig) type {
    const RingType = MpmcRing(T, config);

    return struct {
        const Self = @This();

        rings: [config.max_producers]RingType = [_]RingType{.{}} ** config.max_producers,
        producer_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        consumer_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        consumer_rng: [config.max_consumers]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** config.max_consumers,

        pub const Producer = struct {
            ring: *RingType,
            id: usize,

            pub inline fn reserve(self: Producer, n: usize) ?Reservation(T) {
                return self.ring.reserve(n);
            }

            pub inline fn commit(self: Producer, n: usize) void {
                self.ring.commit(n);
            }

            pub inline fn send(self: Producer, items: []const T) usize {
                const r = self.reserve(items.len) orelse return 0;

                // Use SIMD-accelerated copy for better performance
                if (comptime @sizeOf(T) <= 8 and items.len >= 16) {
                    const dst_bytes = std.mem.sliceAsBytes(r.slice);
                    const src_bytes = std.mem.sliceAsBytes(items[0..r.slice.len]);
                    ring_mod.simd.ringMemcpy(dst_bytes.ptr, src_bytes.ptr, dst_bytes.len);
                } else {
                    @memcpy(r.slice, items[0..r.slice.len]);
                }

                self.commit(r.slice.len);
                return r.slice.len;
            }

            pub inline fn sendOne(self: Producer, item: T) bool {
                const r = self.reserve(1) orelse return false;
                r.slice[0] = item;
                self.commit(1);
                return true;
            }
        };

        pub const Consumer = struct {
            channel: *Self,
            id: usize,
            shard_start: usize,
            shard_end: usize,
            consumer_backoff: Backoff = .{},
            last_productive_ring: usize = 0,

            /// Progressive stealing: local → hot → random
            pub fn stealBatch(self: *Consumer, comptime Handler: type, handler: Handler) usize {
                var total: usize = 0;

                total += self.stealFromShard(Handler, handler);
                if (total > 0) {
                    self.consumer_backoff.reset();
                    return total;
                }

                total += self.stealFromHottest(Handler, handler);
                if (total > 0) {
                    self.consumer_backoff.reset();
                    return total;
                }

                total += self.stealRandom(Handler, handler);
                if (total > 0) {
                    self.consumer_backoff.reset();
                    return total;
                }

                self.consumer_backoff.snooze();
                return 0;
            }

            fn stealFromShard(self: *Consumer, comptime Handler: type, handler: Handler) usize {
                var total: usize = 0;
                const count = self.channel.producer_count.load(.acquire);
                if (count == 0) return 0;

                const start = @min(self.shard_start, count);
                const end = @min(self.shard_end, count);

                if (start < end) {
                    for (self.channel.rings[start..end]) |*ring_ptr| {
                        if (ring_ptr.active.load(.acquire)) {
                            total += ring_ptr.consumeSteal(Handler, handler);
                        }
                    }
                }
                return total;
            }

            fn stealFromHottest(self: *Consumer, comptime Handler: type, handler: Handler) usize {
                const count = self.channel.producer_count.load(.acquire);
                if (count == 0) return 0;

                var hottest_idx: usize = 0;
                var hottest_score: u32 = 0;

                for (self.channel.rings[0..count], 0..) |*ring_ptr, i| {
                    if (i >= self.shard_start and i < self.shard_end) continue;

                    if (ring_ptr.active.load(.acquire)) {
                        const score = ring_ptr.getHotness();
                        if (score > hottest_score) {
                            hottest_score = score;
                            hottest_idx = i;
                        }
                    }
                }

                if (hottest_score > 0) {
                    return self.channel.rings[hottest_idx].consumeSteal(Handler, handler);
                }
                return 0;
            }

            fn stealRandom(self: *Consumer, comptime Handler: type, handler: Handler) usize {
                const count = self.channel.producer_count.load(.acquire);
                if (count == 0) return 0;

                var rng = self.channel.consumer_rng[self.id].load(.monotonic);
                if (rng == 0) rng = @as(u64, @intCast(self.id)) + 1;
                rng ^= rng << 13;
                rng ^= rng >> 7;
                rng ^= rng << 17;
                self.channel.consumer_rng[self.id].store(rng, .monotonic);

                const idx = rng % count;
                const ring_ptr = &self.channel.rings[idx];

                if (ring_ptr.active.load(.acquire)) {
                    return ring_ptr.consumeSteal(Handler, handler);
                }
                return 0;
            }

            pub fn steal(self: *Consumer, out: []T) usize {
                var total: usize = 0;

                const count = self.channel.producer_count.load(.acquire);
                if (count == 0) return 0;

                // Start from last productive ring (affinity token)
                const hint = @min(self.last_productive_ring, count - 1);

                // Scan from hint, wrapping around
                for (0..count) |offset| {
                    if (total >= out.len) break;
                    const idx = (hint + offset) % count;
                    const ring_ptr = &self.channel.rings[idx];
                    if (ring_ptr.active.load(.acquire)) {
                        const n = ring_ptr.trySteal(out[total..]);
                        if (n > 0) {
                            total += n;
                            self.last_productive_ring = idx;
                        }
                    }
                }

                return total;
            }
        };

        pub fn init() Self {
            return .{};
        }

        pub fn register(self: *Self) error{ TooManyProducers, Closed }!Producer {
            if (self.closed.load(.acquire)) return error.Closed;

            const id = self.producer_count.fetchAdd(1, .monotonic);
            if (id >= config.max_producers) {
                _ = self.producer_count.fetchSub(1, .monotonic);
                return error.TooManyProducers;
            }

            self.rings[id].active.store(true, .release);
            return .{ .ring = &self.rings[id], .id = id };
        }

        pub fn registerConsumer(self: *Self) error{ TooManyConsumers, Closed }!Consumer {
            if (self.closed.load(.acquire)) return error.Closed;

            const id = self.consumer_count.fetchAdd(1, .monotonic);
            if (id >= config.max_consumers) {
                _ = self.consumer_count.fetchSub(1, .monotonic);
                return error.TooManyConsumers;
            }

            const shard_size = (config.max_producers + config.max_consumers - 1) / config.max_consumers;
            const shard_start = id * shard_size;
            const shard_end = @min(shard_start + shard_size, config.max_producers);

            self.consumer_rng[id].store(@as(u64, @intCast(id + 1)) * 2654435761, .monotonic);

            return .{
                .channel = self,
                .id = id,
                .shard_start = shard_start,
                .shard_end = shard_end,
            };
        }

        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
            for (&self.rings) |*ring_ptr| {
                ring_ptr.close();
            }
        }

        pub fn isClosed(self: *const Self) bool {
            return self.closed.load(.acquire);
        }

        pub fn totalPending(self: *const Self) usize {
            var total: usize = 0;
            const count = self.producer_count.load(.acquire);
            for (self.rings[0..count]) |ring_val| {
                if (ring_val.active.load(.acquire)) {
                    total += ring_val.available();
                }
            }
            return total;
        }
    };
}

// Type alias
pub const DefaultMpmcChannel = MpmcChannel(u64, default_mpmc_config);
