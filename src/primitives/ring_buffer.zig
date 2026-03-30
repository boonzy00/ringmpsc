//! ringmpsc - Core SPSC ring buffer primitive
//!
//! A ring-decomposed implementation where each producer has a dedicated
//! SPSC ring buffer. This eliminates producer-producer contention entirely.
//!
//! Key features:
//! - 128-byte alignment (prefetcher false sharing elimination)
//! - Batch consumption API (single head update for N items)
//! - Zero-copy reserve/commit API
//! - Iterator/drain APIs for ergonomic consumption
//! - SIMD-accelerated memcpy for bulk transfers

const std = @import("std");

comptime {
    // Ring buffer uses u64 head/tail cast to usize. On 32-bit targets,
    // @intCast(u64_wrapping_sub) would overflow after 2^32 messages.
    if (@sizeOf(usize) < 8) @compileError("ringmpsc requires a 64-bit target");
}

pub const backoff = @import("backoff.zig");
pub const metrics = @import("../metrics/collector.zig");
pub const simd = @import("simd.zig");
pub const wait_mod = @import("wait_strategy.zig");
pub const event_notifier_mod = @import("event_notifier.zig");

pub const Backoff = backoff.Backoff;
pub const Metrics = metrics.Metrics;

// ============================================================================
// VERSION
// ============================================================================

pub const version = "2.3.0";
pub const version_major = 2;
pub const version_minor = 3;
pub const version_patch = 0;

// ============================================================================
// CONFIGURATION
// ============================================================================

pub const Config = struct {
    /// Ring buffer size as power of 2 (default: 16 = 64K slots)
    ring_bits: u6 = 16,
    /// Maximum number of producers
    max_producers: usize = 16,
    /// Enable metrics collection (slight overhead)
    enable_metrics: bool = false,
    /// Enable contention tracking (additional overhead)
    track_contention: bool = false,
    /// NUMA node hint (-1 = auto-detect from thread affinity)
    numa_node: i8 = -1,
    /// Enable NUMA-aware allocation (auto-detect thread's node)
    numa_aware: bool = true,
    /// Minimum batch size before prefetching kicks in (0 = disabled)
    prefetch_threshold: usize = 16,
};

pub const default_config = Config{};
pub const low_latency_config = Config{ .ring_bits = 12 }; // 4K slots (fits L1)
pub const high_throughput_config = Config{ .ring_bits = 18, .max_producers = 32 }; // 256K slots
pub const ultra_low_latency_config = Config{ .ring_bits = 10, .max_producers = 4 }; // 1K slots

// ============================================================================
// ZERO-COPY RESERVATION
// ============================================================================

pub fn Reservation(comptime T: type) type {
    return struct {
        slice: []T,
        pos: u64,
    };
}

// ============================================================================
// SPSC RING BUFFER - The Core
// ============================================================================

pub fn Ring(comptime T: type, comptime config: Config) type {
    const CAPACITY = @as(usize, 1) << config.ring_bits;
    const MASK = CAPACITY - 1;

    return struct {
        const Self = @This();

        // === PRODUCER HOT === (128-byte aligned to avoid prefetcher false sharing)
        tail: std.atomic.Value(u64) align(128) = std.atomic.Value(u64).init(0),
        cached_head: u64 = 0, // Producer's cached view of head

        // === CONSUMER HOT === (separate 128-byte line)
        head: std.atomic.Value(u64) align(128) = std.atomic.Value(u64).init(0),
        cached_tail: u64 = 0, // Consumer's cached view of tail

        // === COLD STATE === (rarely accessed)
        active: std.atomic.Value(bool) align(128) = std.atomic.Value(bool).init(false),
        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        // Waiter counts — only non-zero when someone is futex-blocked.
        // Checked before issuing wake syscalls to avoid overhead on hot path.
        consumer_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        producer_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        /// Optional eventfd notifier for epoll/io_uring integration.
        /// When set, commit() signals the eventfd after advancing tail,
        /// enabling the consumer to sleep in epoll_wait instead of polling.
        /// Set via setEventNotifier(). null = futex-only (default).
        event_notifier: ?*const event_notifier_mod.EventNotifier = null,
        ring_metrics: if (config.enable_metrics) Metrics else void =
            if (config.enable_metrics) .{} else {},

        // === DATA BUFFER === (64-byte aligned for cache efficiency)
        buffer: [CAPACITY]T align(64) = undefined,

        // ---------------------------------------------------------------------
        // CONSTANTS
        // ---------------------------------------------------------------------

        pub fn capacity() usize {
            return CAPACITY;
        }

        pub fn mask() usize {
            return MASK;
        }

        // ---------------------------------------------------------------------
        // STATUS
        // ---------------------------------------------------------------------

        pub inline fn len(self: *const Self) usize {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.monotonic);
            return @intCast(t -% h);
        }

        pub inline fn isEmpty(self: *const Self) bool {
            return self.tail.load(.monotonic) == self.head.load(.monotonic);
        }

        pub inline fn isFull(self: *const Self) bool {
            return self.len() >= CAPACITY;
        }

        pub inline fn isClosed(self: *const Self) bool {
            return self.closed.load(.acquire);
        }

        // ---------------------------------------------------------------------
        // PRODUCER API
        // ---------------------------------------------------------------------

        /// Reserve n slots for zero-copy writing. Returns null if full/closed.
        pub inline fn reserve(self: *Self, n: usize) ?Reservation(T) {
            if (n == 0 or n > CAPACITY) return null;

            const tail_val = self.tail.load(.monotonic);

            // Fast path: check cached head
            var space = CAPACITY -| (tail_val -% self.cached_head);
            if (space >= n) {
                return self.makeReservation(tail_val, n);
            }

            // Slow path: refresh cache with acquire ordering
            self.cached_head = self.head.load(.acquire);
            space = CAPACITY -| (tail_val -% self.cached_head);
            if (space < n) return null;

            return self.makeReservation(tail_val, n);
        }

        /// Reserve with adaptive backoff. Spins, yields, then gives up.
        pub fn reserveWithBackoff(self: *Self, n: usize) ?Reservation(T) {
            var bo = Backoff{};
            while (!bo.isCompleted()) {
                if (self.reserve(n)) |r| return r;
                if (self.isClosed()) return null;
                bo.snooze();
            }
            return null;
        }

        inline fn makeReservation(self: *Self, tail_val: u64, n: usize) Reservation(T) {
            const idx = tail_val & MASK;
            const contiguous = @min(n, CAPACITY - idx);

            // Conservative prefetching for write operations
            if (config.prefetch_threshold > 0 and n >= config.prefetch_threshold) {
                @prefetch(&self.buffer[idx], .{ .rw = .write, .locality = 3, .cache = .data });
            }

            return .{ .slice = self.buffer[idx..][0..contiguous], .pos = tail_val };
        }

        /// Commit n slots after writing.
        /// Wakes any consumer blocked on a futex wait for new data.
        pub inline fn commit(self: *Self, n: usize) void {
            const tail_val = self.tail.load(.monotonic);
            self.tail.store(tail_val +% n, .release);

            // Wake via futex if someone is blocked
            if (self.consumer_waiters.load(.acquire) > 0) {
                wait_mod.wake(wait_mod.futexPtr(&self.tail), 1);
            }

            // Wake via eventfd if registered (epoll/io_uring integration)
            if (self.event_notifier) |en| {
                en.signal();
            }

            if (config.enable_metrics) {
                _ = @atomicRmw(u64, &self.ring_metrics.messages_sent, .Add, n, .monotonic);
                _ = @atomicRmw(u64, &self.ring_metrics.batches_sent, .Add, 1, .monotonic);
            }
        }

        /// Attach an EventNotifier for epoll/io_uring consumer wake.
        /// After this, every commit() will signal the eventfd in addition
        /// to the futex wake. Pass null to disable.
        pub fn setEventNotifier(self: *Self, notifier: ?*const event_notifier_mod.EventNotifier) void {
            self.event_notifier = notifier;
        }

        // ---------------------------------------------------------------------
        // CONSUMER API
        // ---------------------------------------------------------------------

        /// Get readable slice. Returns null if empty.
        pub inline fn readable(self: *Self) ?[]const T {
            const head_val = self.head.load(.monotonic);

            // Fast path: check cached tail
            var avail = self.cached_tail -% head_val;
            if (avail == 0) {
                // Slow path: refresh cache with acquire for correctness
                self.cached_tail = self.tail.load(.acquire);
                avail = self.cached_tail -% head_val;
                if (avail == 0) return null;
            }

            const idx = head_val & MASK;
            const contiguous = @min(avail, CAPACITY - idx);

            // SIMD-aware prefetching for read operations
            if (config.prefetch_threshold > 0) {
                const next_idx = (head_val +% contiguous) & MASK;
                if (avail >= config.prefetch_threshold) {
                    simd.prefetchSimd(&self.buffer[next_idx], .read);
                } else {
                    @prefetch(&self.buffer[next_idx], .{ .rw = .read, .locality = 3, .cache = .data });
                }
            }

            return self.buffer[idx..][0..contiguous];
        }

        /// Advance head after reading n items.
        /// Wakes any producer blocked on a futex wait for free space.
        pub inline fn advance(self: *Self, n: usize) void {
            const head_val = self.head.load(.monotonic);
            self.head.store(head_val +% n, .release);

            if (self.producer_waiters.load(.acquire) > 0) {
                wait_mod.wake(wait_mod.futexPtr(&self.head), 1);
            }

            if (config.enable_metrics) {
                _ = @atomicRmw(u64, &self.ring_metrics.messages_received, .Add, n, .monotonic);
                _ = @atomicRmw(u64, &self.ring_metrics.batches_received, .Add, 1, .monotonic);
            }
        }

        // ---------------------------------------------------------------------
        // BATCH CONSUMPTION (single head update for N items)
        // ---------------------------------------------------------------------

        /// Process ALL available items with a single head update.
        pub fn consumeBatch(self: *Self, handler: anytype) usize {
            const head_val = self.head.load(.monotonic);
            const tail_val = self.tail.load(.acquire);

            const avail = tail_val -% head_val;
            if (avail == 0) return 0;

            const batch_start = if (config.enable_metrics) std.time.nanoTimestamp() else 0;

            var pos = head_val;
            var count: usize = 0;

            while (pos != tail_val) {
                const idx = pos & MASK;
                handler.process(&self.buffer[idx]);
                pos +%= 1;
                count += 1;
            }

            self.head.store(tail_val, .release);
            if (self.producer_waiters.load(.acquire) > 0) {
                wait_mod.wake(wait_mod.futexPtr(&self.head), 1);
            }

            if (config.enable_metrics) {
                _ = @atomicRmw(u64, &self.ring_metrics.messages_received, .Add, count, .monotonic);
                _ = @atomicRmw(u64, &self.ring_metrics.batches_received, .Add, 1, .monotonic);
                const elapsed = @as(u64, @intCast(@max(0, std.time.nanoTimestamp() - batch_start)));
                _ = @atomicRmw(u64, &self.ring_metrics.latency_sum_ns, .Add, elapsed, .monotonic);
                _ = @atomicRmw(u64, &self.ring_metrics.latency_count, .Add, 1, .monotonic);
                _ = @atomicRmw(u64, &self.ring_metrics.latency_max_ns, .Max, elapsed, .monotonic);
                _ = @atomicRmw(u64, &self.ring_metrics.latency_min_ns, .Min, elapsed, .monotonic);
            }

            return count;
        }

        /// Consume ALL available items and just count them (no handler calls) - for max throughput
        pub fn consumeBatchCount(self: *Self) usize {
            const head_val = self.head.load(.monotonic);
            const tail_val = self.tail.load(.acquire);

            const avail = tail_val -% head_val;
            if (avail == 0) return 0;

            self.head.store(tail_val, .release);
            if (self.producer_waiters.load(.acquire) > 0) {
                wait_mod.wake(wait_mod.futexPtr(&self.head), 1);
            }

            if (config.enable_metrics) {
                _ = @atomicRmw(u64, &self.ring_metrics.messages_received, .Add, avail, .monotonic);
                _ = @atomicRmw(u64, &self.ring_metrics.batches_received, .Add, 1, .monotonic);
            }

            return avail;
        }

        /// Consume up to max_items items with a single head update.
        pub fn consumeUpTo(self: *Self, max_items: usize, handler: anytype) usize {
            if (max_items == 0) return 0;

            const head_val = self.head.load(.monotonic);
            const tail_val = self.tail.load(.acquire);

            const avail = tail_val -% head_val;
            if (avail == 0) return 0;

            const to_consume = @min(avail, max_items);

            var pos = head_val;
            var count: usize = 0;

            while (count < to_consume) {
                const idx = pos & MASK;
                handler.process(&self.buffer[idx]);
                pos +%= 1;
                count += 1;
            }

            self.head.store(head_val +% count, .release);

            // Wake blocked producers waiting for space
            if (self.producer_waiters.load(.acquire) > 0) {
                wait_mod.wake(wait_mod.futexPtr(&self.head), 1);
            }

            if (config.enable_metrics) {
                _ = @atomicRmw(u64, &self.ring_metrics.messages_received, .Add, count, .monotonic);
                _ = @atomicRmw(u64, &self.ring_metrics.batches_received, .Add, 1, .monotonic);
            }

            return count;
        }

        /// Consume batch with callback function
        pub fn consumeBatchFn(self: *Self, comptime callback: fn (*const T) void) usize {
            const Handler = struct {
                pub fn process(item: *const T) void {
                    callback(item);
                }
            };
            return self.consumeBatch(Handler);
        }

        // ---------------------------------------------------------------------
        // CONVENIENCE WRAPPERS
        // ---------------------------------------------------------------------

        /// Batch send (convenience)
        pub inline fn send(self: *Self, items: []const T) usize {
            const r = self.reserve(items.len) orelse return 0;

            // Use SIMD-accelerated copy for small types and large batches
            if (comptime @sizeOf(T) <= 8) {
                if (r.slice.len >= 16) {
                    const dst_bytes = std.mem.sliceAsBytes(r.slice);
                    const src_bytes = std.mem.sliceAsBytes(items[0..r.slice.len]);
                    simd.ringMemcpy(dst_bytes.ptr, src_bytes.ptr, dst_bytes.len);
                } else {
                    @memcpy(r.slice, items[0..r.slice.len]);
                }
            } else {
                @memcpy(r.slice, items[0..r.slice.len]);
            }

            self.commit(r.slice.len);
            return r.slice.len;
        }

        /// Batch receive (convenience)
        pub inline fn recv(self: *Self, out: []T) usize {
            const slice = self.readable() orelse return 0;
            const n = @min(slice.len, out.len);

            // Use SIMD-accelerated copy for better performance
            if (@sizeOf(T) <= 8 and n >= 16) {
                const dst_bytes = std.mem.sliceAsBytes(out[0..n]);
                const src_bytes = std.mem.sliceAsBytes(slice[0..n]);
                simd.ringMemcpy(dst_bytes.ptr, src_bytes.ptr, dst_bytes.len);
            } else {
                @memcpy(out[0..n], slice[0..n]);
            }

            self.advance(n);
            return n;
        }

        // ---------------------------------------------------------------------
        // LIFECYCLE
        // ---------------------------------------------------------------------

        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }

        pub fn getMetrics(self: *const Self) Metrics {
            if (config.enable_metrics) {
                return self.ring_metrics;
            }
            return .{};
        }

        // ---------------------------------------------------------------------
        // PEEK API (read without consuming)
        // ---------------------------------------------------------------------

        pub inline fn peek(self: *Self) ?*const T {
            const head_val = self.head.load(.acquire);
            const tail_val = self.tail.load(.acquire);
            if (head_val == tail_val) return null;
            return &self.buffer[head_val & MASK];
        }

        pub inline fn peekMany(self: *Self, n: usize) ?[]const T {
            const head_val = self.head.load(.acquire);
            self.cached_tail = self.tail.load(.acquire);
            const avail = self.cached_tail -% head_val;
            if (avail == 0) return null;

            const idx = head_val & MASK;
            const count = @min(@min(avail, n), CAPACITY - idx);
            return self.buffer[idx..][0..count];
        }

        // ---------------------------------------------------------------------
        // ITERATOR API (ergonomic consumption)
        // ---------------------------------------------------------------------

        pub const Iterator = struct {
            ring: *Self,
            pos: u64,
            end: u64,

            pub fn next(iter: *Iterator) ?*const T {
                if (iter.pos == iter.end) return null;
                const item = &iter.ring.buffer[iter.pos & MASK];
                iter.pos +%= 1;
                return item;
            }

            pub fn finish(iter: *Iterator) usize {
                const consumed = iter.pos -% (iter.ring.head.load(.monotonic));
                if (consumed > 0) {
                    iter.ring.head.store(iter.pos, .release);
                }
                return @intCast(consumed);
            }

            pub fn iterReset(iter: *Iterator) void {
                iter.pos = iter.ring.head.load(.acquire);
            }
        };

        pub fn iterator(self: *Self) Iterator {
            const head_val = self.head.load(.acquire);
            const tail_val = self.tail.load(.acquire);
            return .{ .ring = self, .pos = head_val, .end = tail_val };
        }

        // ---------------------------------------------------------------------
        // MEMORY INTROSPECTION
        // ---------------------------------------------------------------------

        pub fn totalMemory() usize {
            return @sizeOf(Self);
        }

        pub fn bufferMemory() usize {
            return CAPACITY * @sizeOf(T);
        }

        pub fn metadataMemory() usize {
            return totalMemory() - bufferMemory();
        }

        // ---------------------------------------------------------------------
        // ADVANCED API
        // ---------------------------------------------------------------------

        pub inline fn tryRecv(self: *Self) ?T {
            const slice = self.readable() orelse return null;
            const item = slice[0];
            self.advance(1);
            return item;
        }

        pub fn drain(self: *Self, out: []T) usize {
            var total: usize = 0;
            while (total < out.len) {
                const slice = self.readable() orelse break;
                const n = @min(slice.len, out.len - total);
                @memcpy(out[total..][0..n], slice[0..n]);
                self.advance(n);
                total += n;
            }
            return total;
        }

        pub fn skip(self: *Self, n: usize) usize {
            const head_val = self.head.load(.monotonic);
            const tail_val = self.tail.load(.acquire);
            const avail: usize = @intCast(tail_val -% head_val);
            const to_skip = @min(n, avail);
            if (to_skip > 0) {
                self.head.store(head_val +% to_skip, .release);
                // Wake blocked producers waiting for space
                if (self.producer_waiters.load(.acquire) > 0) {
                    wait_mod.wake(wait_mod.futexPtr(&self.head), 1);
                }
            }
            return to_skip;
        }

        pub fn reset(self: *Self) void {
            self.head.store(0, .monotonic);
            self.tail.store(0, .monotonic);
            self.cached_head = 0;
            self.cached_tail = 0;
            self.closed.store(false, .monotonic);
            if (config.enable_metrics) {
                self.ring_metrics = .{};
            }
        }

        // ---------------------------------------------------------------------
        // BLOCKING API (wait-strategy-aware)
        // ---------------------------------------------------------------------

        pub const WaitStrategy = wait_mod.WaitStrategy;
        pub const WaitError = error{ TimedOut, Closed };

        /// Reserve with configurable wait strategy. Blocks until space is
        /// available, the ring is closed, or the strategy times out.
        pub fn reserveBlocking(self: *Self, n: usize, strategy: WaitStrategy) WaitError!Reservation(T) {
            if (n == 0 or n > CAPACITY) return error.Closed; // Impossible reservation
            // Fast path — try without waiting
            if (self.reserve(n)) |r| return r;
            if (self.isClosed()) return error.Closed;

            // Register as a waiting producer so advance/consumeBatch know to wake us
            _ = self.producer_waiters.fetchAdd(1, .acquire);
            defer _ = self.producer_waiters.fetchSub(1, .release);

            var waiter = wait_mod.Waiter.init(strategy);
            while (true) {
                // Load the value we'll futex-wait on BEFORE re-checking availability.
                // This closes the lost-wake window: if head changes between this load
                // and the futex call, the futex sees a different value and returns
                // immediately instead of sleeping.
                const head_val = self.head.load(.acquire);

                // Re-check after loading futex value — if head advanced since our
                // last reserve() attempt, we may now have space.
                if (self.reserve(n)) |r| return r;
                if (self.isClosed()) return error.Closed;

                // head hasn't changed since our load, safe to wait on it.
                waiter.wait(
                    wait_mod.futexPtr(&self.head),
                    wait_mod.futexValue(head_val),
                ) catch return error.TimedOut;

                if (self.reserve(n)) |r| return r;
                if (self.isClosed()) return error.Closed;
            }
        }

        /// Blocking single-item send. Blocks until the item is enqueued.
        pub fn sendOneBlocking(self: *Self, item: T, strategy: WaitStrategy) WaitError!void {
            const r = try self.reserveBlocking(1, strategy);
            r.slice[0] = item;
            self.commit(1);
        }

        /// Blocking batch consume. Waits for data using the given strategy,
        /// then processes all available items in one batch.
        pub fn consumeBatchBlocking(self: *Self, handler: anytype, strategy: WaitStrategy) WaitError!usize {
            // Fast path
            const n = self.consumeBatch(handler);
            if (n > 0) return n;
            if (self.isClosed()) {
                const final = self.consumeBatch(handler);
                return if (final > 0) final else error.Closed;
            }

            // Register as a waiting consumer so commit knows to wake us
            _ = self.consumer_waiters.fetchAdd(1, .acquire);
            defer _ = self.consumer_waiters.fetchSub(1, .release);

            var waiter = wait_mod.Waiter.init(strategy);
            while (true) {
                // Load futex value BEFORE re-checking. Closes the lost-wake window:
                // if tail changes between this load and the futex call, futex returns
                // immediately instead of sleeping on a stale value.
                const tail_val = self.tail.load(.acquire);

                // Re-check after loading futex value
                const consumed_check = self.consumeBatch(handler);
                if (consumed_check > 0) return consumed_check;
                if (self.isClosed()) {
                    const final = self.consumeBatch(handler);
                    return if (final > 0) final else error.Closed;
                }

                waiter.wait(
                    wait_mod.futexPtr(&self.tail),
                    wait_mod.futexValue(tail_val),
                ) catch return error.TimedOut;

                const consumed = self.consumeBatch(handler);
                if (consumed > 0) return consumed;
                if (self.isClosed()) {
                    const final = self.consumeBatch(handler);
                    return if (final > 0) final else error.Closed;
                }
            }
        }
    };
}

// Type aliases
pub const DefaultRing = Ring(u64, default_config);
