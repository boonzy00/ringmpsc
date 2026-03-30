//! ringmpsc - MPSC Channel (Multi-Producer Single-Consumer)
//!
//! High-level channel API wrapping per-producer SPSC rings.

const std = @import("std");
const ring_mod = @import("../primitives/ring_buffer.zig");
const numa_mod = @import("../platform/numa.zig");

pub const Ring = ring_mod.Ring;
pub const Config = ring_mod.Config;
pub const Reservation = ring_mod.Reservation;
pub const Backoff = ring_mod.Backoff;
pub const Metrics = ring_mod.Metrics;

pub const default_config = ring_mod.default_config;
pub const low_latency_config = ring_mod.low_latency_config;
pub const high_throughput_config = ring_mod.high_throughput_config;

// ============================================================================
// MPSC CHANNEL
// ============================================================================

pub fn Channel(comptime T: type, comptime config: Config) type {
    const RingType = Ring(T, config);

    return struct {
        const Self = @This();
        const initial_capacity = config.max_producers;

        allocator: std.mem.Allocator,
        rings: []*RingType,
        capacity: usize,
        topology: ?numa_mod.NumaTopology = null,
        producer_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        grow_mutex: std.Thread.Mutex = .{},
        // Retired ring slices from grow operations — freed at deinit to avoid
        // use-after-free when consumers hold a reference to the old slice.
        retired_slices: [8][]*RingType = [_][]*RingType{&.{}} ** 8,
        retired_count: usize = 0,
        // Adaptive consumer skip tracking (exponential backoff):
        // Exponentially backs off on consistently-empty rings to
        // reduce O(P) polling to O(active_producers).
        // NOT thread-safe: MPSC has a single consumer by design.
        // If you call consumeAll() from multiple threads, use
        // external synchronization (mutex) around the call.
        skip_counters: [256]u8 = [_]u8{0} ** 256,
        skip_phase: [256]u8 = [_]u8{0} ** 256,

        pub fn init(allocator: std.mem.Allocator) !Self {
            const cap = initial_capacity;
            const rings = try allocator.alloc(*RingType, cap);
            errdefer allocator.free(rings);

            var allocated: usize = 0;
            errdefer for (rings[0..allocated]) |ring_ptr| {
                allocator.destroy(ring_ptr);
            };

            for (0..cap) |i| {
                const ring_ptr = try allocator.create(RingType);
                ring_ptr.* = .{};
                rings[i] = ring_ptr;
                allocated += 1;
            }

            // Discover NUMA topology if enabled. Rings are not bound here —
            // binding happens at register() time on the producer's thread,
            // so each ring is physically local to its producer (producer-local
            // allocation strategy).
            var topology: ?numa_mod.NumaTopology = null;
            if (config.numa_aware) {
                topology = numa_mod.NumaTopology.init(allocator) catch null;
            }

            return .{
                .allocator = allocator,
                .rings = rings,
                .capacity = cap,
                .topology = topology,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.topology) |*topo| topo.deinit();
            for (self.rings[0..self.capacity]) |ring_ptr| {
                self.allocator.destroy(ring_ptr);
            }
            self.allocator.free(self.rings);
            // Free retired slices from grow operations
            for (self.retired_slices[0..self.retired_count]) |slice| {
                if (slice.len > 0) self.allocator.free(slice);
            }
        }

        pub const Producer = struct {
            ring: *RingType,
            id: usize,

            pub inline fn reserve(self: Producer, n: usize) ?Reservation(T) {
                return self.ring.reserve(n);
            }

            pub inline fn reserveWithBackoff(self: Producer, n: usize) ?Reservation(T) {
                return self.ring.reserveWithBackoff(n);
            }

            pub inline fn commit(self: Producer, n: usize) void {
                self.ring.commit(n);
            }

            pub inline fn send(self: Producer, items: []const T) usize {
                return self.ring.send(items);
            }

            /// Convenience: send a single item
            pub inline fn sendOne(self: Producer, item: T) bool {
                const r = self.reserve(1) orelse return false;
                r.slice[0] = item;
                self.commit(1);
                return true;
            }
        };

        pub fn register(self: *Self) error{ Closed, OutOfMemory }!Producer {
            if (self.closed.load(.acquire)) return error.Closed;

            const id = self.producer_count.fetchAdd(1, .monotonic);

            // Grow if needed — lock only held during allocation, never on hot path
            if (id >= self.capacity) {
                self.grow_mutex.lock();
                defer self.grow_mutex.unlock();

                // Double-check after acquiring lock (another thread may have grown)
                if (id >= self.capacity) {
                    try self.growCapacity(id + 1);
                }
            }

            const ring_ptr = self.rings[id];
            ring_ptr.active.store(true, .release);

            // Producer-local NUMA binding
            if (self.topology) |*topo| {
                if (topo.isNuma()) {
                    const node = if (config.numa_node >= 0)
                        @as(usize, @intCast(config.numa_node))
                    else
                        numa_mod.currentNode(topo);

                    numa_mod.bindMemoryToNode(
                        @as([*]u8, @ptrCast(ring_ptr)),
                        @sizeOf(RingType),
                        node,
                    );
                }
            }

            return .{ .ring = ring_ptr, .id = id };
        }

        /// Deregister a producer. Marks the ring as inactive and closed.
        /// Does NOT drain — the consumer's next consumeAll() will drain
        /// any remaining messages from this ring before skipping it.
        ///
        /// SAFE PATTERN:
        ///   1. Producer stops sending (returns from its thread)
        ///   2. Call deregister(producer) — marks ring inactive+closed
        ///   3. Consumer's next consumeAll() drains any remaining items
        ///
        /// This is safe because consumeAll() checks isEmpty() before
        /// consumeBatch(), and deregister() does not touch head/tail.
        /// No double-processing is possible.
        pub fn deregister(_: *Self, producer: Producer) void {
            const ring_ptr = producer.ring;
            ring_ptr.active.store(false, .release);
            ring_ptr.close();
            // Remaining messages are drained by the consumer's next
            // consumeAll() call — no separate drain here avoids the
            // race condition where both deregister and consumeAll
            // drain the same ring simultaneously.
        }

        fn growCapacity(self: *Self, min_capacity: usize) !void {
            const new_cap = @max(min_capacity, self.capacity * 2);
            const new_rings = try self.allocator.alloc(*RingType, new_cap);

            // Copy existing ring pointers
            @memcpy(new_rings[0..self.capacity], self.rings[0..self.capacity]);

            // Allocate new rings for the expanded slots
            for (self.capacity..new_cap) |i| {
                const ring_ptr = try self.allocator.create(RingType);
                ring_ptr.* = .{};
                new_rings[i] = ring_ptr;
            }

            // Swap — consumers reading self.rings[0..old_count] see identical
            // pointers at identical indices. The new slots are beyond old_count
            // and won't be accessed until producer_count advances.
            const old_rings = self.rings;
            // Swap pointer. Consumers may still hold the old pointer for the
            // current iteration — that's safe because we retire (not free) it.
            self.rings = new_rings;
            self.capacity = new_cap;

            // Retire old slice instead of freeing — a concurrent consumer may
            // still hold a reference to it. Freed at deinit().
            if (self.retired_count < self.retired_slices.len) {
                self.retired_slices[self.retired_count] = old_rings;
                self.retired_count += 1;
            } else {
                // Overflow: too many grows. Free oldest (least likely still referenced).
                self.allocator.free(self.retired_slices[0]);
                var i: usize = 0;
                while (i < self.retired_slices.len - 1) : (i += 1) {
                    self.retired_slices[i] = self.retired_slices[i + 1];
                }
                self.retired_slices[self.retired_slices.len - 1] = old_rings;
            }
        }

        /// Round-robin receive from all active producers
        pub fn recv(self: *Self, out: []T) usize {
            var total: usize = 0;
            const count = self.producer_count.load(.acquire);
            for (self.rings[0..count]) |ring_ptr| {
                if (total >= out.len) break;
                total += ring_ptr.recv(out[total..]);
            }
            return total;
        }

        /// Single-item receive (returns null if empty)
        pub fn recvOne(self: *Self) ?T {
            const count = self.producer_count.load(.acquire);
            for (self.rings[0..count]) |ring_ptr| {
                var buf: [1]T = undefined;
                if (ring_ptr.recv(&buf) == 1) {
                    return buf[0];
                }
            }
            return null;
        }

        /// Batch consume from all producers - THE FAST PATH
        /// Uses adaptive exponential backoff to avoid polling consistently-empty
        /// rings. Polling empty rings wastes cycles without reducing queue wait
        /// time, so we skip them with geometrically increasing intervals.
        pub fn consumeAll(self: *Self, handler: anytype) usize {
            var total: usize = 0;
            const count = self.producer_count.load(.acquire);
            for (0..count) |i| {
                // Adaptive skip: if this ring has been empty for consecutive
                // polls, skip it with exponential backoff
                if (i < 256 and self.skip_counters[i] > 0) {
                    self.skip_phase[i] +%= 1;
                    if (self.skip_phase[i] < self.skip_counters[i]) continue;
                    self.skip_phase[i] = 0; // Time to re-check
                }

                const ring_ptr = self.rings[i];

                // Quick empty check before calling consumeBatch
                if (ring_ptr.isEmpty()) {
                    // Exponential backoff: double skip counter (max 64)
                    if (i < 256) {
                        const cur = self.skip_counters[i];
                        self.skip_counters[i] = if (cur == 0) 1 else @min(cur *| 2, 64);
                    }
                    continue;
                }

                // Non-empty: reset skip counter immediately
                if (i < 256) {
                    self.skip_counters[i] = 0;
                    self.skip_phase[i] = 0;
                }
                total += ring_ptr.consumeBatch(handler);
            }
            return total;
        }

        /// Batch consume from all producers and just count (no handler calls) - MAX THROUGHPUT
        pub fn consumeAllCount(self: *Self) usize {
            var total: usize = 0;
            const count = self.producer_count.load(.acquire);

            for (0..count) |i| {
                // Same adaptive skip as consumeAll
                if (i < 256 and self.skip_counters[i] > 0) {
                    self.skip_phase[i] +%= 1;
                    if (self.skip_phase[i] < self.skip_counters[i]) continue;
                    self.skip_phase[i] = 0;
                }

                const ring_ptr = self.rings[i];
                if (ring_ptr.isEmpty()) {
                    if (i < 256) {
                        const cur = self.skip_counters[i];
                        self.skip_counters[i] = if (cur == 0) 1 else @min(cur *| 2, 64);
                    }
                    continue;
                }

                if (i < 256) {
                    self.skip_counters[i] = 0;
                    self.skip_phase[i] = 0;
                }
                total += ring_ptr.consumeBatchCount();
            }
            return total;
        }

        /// Reset all adaptive skip counters. Call when workload pattern changes
        /// (e.g., new producers registered, burst expected after idle period).
        pub fn resetAdaptiveSkip(self: *Self) void {
            @memset(&self.skip_counters, 0);
            @memset(&self.skip_phase, 0);
        }

        /// Consume up to max_total items from all producers
        pub fn consumeAllUpTo(self: *Self, max_total: usize, handler: anytype) usize {
            var total: usize = 0;
            const count = self.producer_count.load(.acquire);
            for (0..count) |i| {
                if (total >= max_total) break;
                const remaining = max_total - total;
                total += self.rings[i].consumeUpTo(remaining, handler);
            }
            return total;
        }

        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
            const count = self.producer_count.load(.acquire);
            for (self.rings[0..count]) |ring_ptr| {
                ring_ptr.close();
            }
        }

        pub fn isClosed(self: *const Self) bool {
            return self.closed.load(.acquire);
        }

        // ---------------------------------------------------------------------
        // GRACEFUL SHUTDOWN
        // ---------------------------------------------------------------------

        /// Signal shutdown: close the channel and all rings. Producers will
        /// see isClosed() on their next reserve attempt. After all producer
        /// threads have joined, call drainAll() to consume remaining messages.
        pub fn shutdown(self: *Self) void {
            self.close();
        }

        /// Drain all remaining messages across all rings. Call after all
        /// producer threads have joined. Returns total messages drained.
        pub fn drainAll(self: *Self, handler: anytype) usize {
            var total: usize = 0;
            const count = self.producer_count.load(.acquire);
            for (0..count) |i| {
                const ring_ptr = self.rings[i];
                while (true) {
                    const n = ring_ptr.consumeBatch(handler);
                    if (n == 0) break;
                    total += n;
                }
            }
            return total;
        }

        /// Drain all remaining messages (count only, no handler). Call after
        /// all producer threads have joined. Returns total messages drained.
        pub fn drainAllCount(self: *Self) usize {
            var total: usize = 0;
            const count = self.producer_count.load(.acquire);
            for (0..count) |i| {
                const ring_ptr = self.rings[i];
                while (true) {
                    const n = ring_ptr.consumeBatchCount();
                    if (n == 0) break;
                    total += n;
                }
            }
            return total;
        }

        /// True when the channel is closed AND all rings are empty.
        pub fn isFullyDrained(self: *const Self) bool {
            if (!self.isClosed()) return false;
            return self.isEmpty();
        }

        pub fn producerCount(self: *const Self) usize {
            return self.producer_count.load(.acquire);
        }

        pub fn getMetrics(self: *const Self) Metrics {
            var m = Metrics{};
            const count = self.producer_count.load(.acquire);
            for (self.rings[0..count]) |ring_ptr| {
                const rm = ring_ptr.getMetrics();
                m.merge(rm);
            }
            return m;
        }

        // ---------------------------------------------------------------------
        // OBSERVABILITY
        // ---------------------------------------------------------------------

        pub const ChannelStats = struct {
            producer_count: usize,
            total_pending: usize,
            closed: bool,

            // Throughput (from Metrics, requires enable_metrics)
            total_sent: u64,
            total_received: u64,
            batches_sent: u64,
            batches_received: u64,

            // Backpressure
            reserve_failures: u64,
            total_wait_ns: u64,

            // Latency (per-batch, nanoseconds)
            latency_min_ns: u64,
            latency_max_ns: u64,
            latency_avg_ns: f64,
            latency_count: u64,
        };

        /// Point-in-time snapshot of all channel health metrics.
        /// Requires `Config.enable_metrics = true` for throughput and latency
        /// fields; otherwise those fields are zero.
        pub fn snapshot(self: *const Self) ChannelStats {
            const m = self.getMetrics();
            return .{
                .producer_count = self.producerCount(),
                .total_pending = self.totalPending(),
                .closed = self.isClosed(),
                .total_sent = m.messages_sent,
                .total_received = m.messages_received,
                .batches_sent = m.batches_sent,
                .batches_received = m.batches_received,
                .reserve_failures = m.reserve_failures,
                .total_wait_ns = m.total_wait_ns,
                .latency_min_ns = if (m.latency_count > 0) m.latency_min_ns else 0,
                .latency_max_ns = m.latency_max_ns,
                .latency_avg_ns = m.avgLatencyNs(),
                .latency_count = m.latency_count,
            };
        }

        // ---------------------------------------------------------------------
        // ENHANCED CHANNEL API
        // ---------------------------------------------------------------------

        pub fn totalPending(self: *const Self) usize {
            var total: usize = 0;
            const count = self.producer_count.load(.acquire);
            for (self.rings[0..count]) |ring_ptr| {
                total += ring_ptr.len();
            }
            return total;
        }

        /// Alias for totalPending
        pub fn pending(self: *const Self) usize {
            return self.totalPending();
        }

        pub fn isEmpty(self: *const Self) bool {
            const count = self.producer_count.load(.acquire);
            for (self.rings[0..count]) |ring_ptr| {
                if (!ring_ptr.isEmpty()) return false;
            }
            return true;
        }

        pub fn hottestRing(self: *Self) ?*RingType {
            const count = self.producer_count.load(.acquire);
            if (count == 0) return null;

            var hottest: *RingType = self.rings[0];
            var max_len = hottest.len();

            for (self.rings[1..count]) |ring_ptr| {
                const ring_len = ring_ptr.len();
                if (ring_len > max_len) {
                    max_len = ring_len;
                    hottest = ring_ptr;
                }
            }
            return if (max_len > 0) hottest else null;
        }

        pub fn tryRecv(self: *Self) ?T {
            const count = self.producer_count.load(.acquire);
            for (self.rings[0..count]) |ring_ptr| {
                if (ring_ptr.tryRecv()) |item| return item;
            }
            return null;
        }

        pub fn drain(self: *Self, out: []T) usize {
            var total: usize = 0;
            const count = self.producer_count.load(.acquire);
            for (self.rings[0..count]) |ring_ptr| {
                if (total >= out.len) break;
                total += ring_ptr.drain(out[total..]);
            }
            return total;
        }

        pub fn totalMemory() usize {
            return @sizeOf(Self);
        }

        pub fn ringCapacity() usize {
            return RingType.capacity();
        }

        pub fn maxCapacity() usize {
            return config.max_producers * RingType.capacity();
        }

        pub fn reset(self: *Self) void {
            const count = self.producer_count.load(.acquire);
            for (self.rings[0..count]) |ring_ptr| {
                ring_ptr.reset();
            }
            self.closed.store(false, .monotonic);
        }

        pub fn getRing(self: *Self, producer_id: usize) ?*RingType {
            if (producer_id >= self.producer_count.load(.acquire)) return null;
            return self.rings[producer_id];
        }

        // ---------------------------------------------------------------------
        // PRODUCER EXTENSIONS
        // ---------------------------------------------------------------------

        pub const ProducerExt = struct {
            base: Producer,

            pub inline fn sendOne(self: ProducerExt, item: T) bool {
                if (self.base.reserve(1)) |r| {
                    r.slice[0] = item;
                    self.base.commit(1);
                    return true;
                }
                return false;
            }

            pub fn sendBlocking(self: ProducerExt, items: []const T) usize {
                var sent: usize = 0;
                var bo = Backoff{};

                while (sent < items.len) {
                    const remaining = items.len - sent;
                    if (self.base.reserve(remaining)) |r| {
                        // Use SIMD-accelerated copy for better performance
                        if (comptime @sizeOf(T) <= 8 and r.slice.len >= 16) {
                            const dst_bytes = std.mem.sliceAsBytes(r.slice);
                            const src_bytes = std.mem.sliceAsBytes(items[sent..][0..r.slice.len]);
                            ring_mod.simd.ringMemcpy(dst_bytes.ptr, src_bytes.ptr, dst_bytes.len);
                        } else {
                            @memcpy(r.slice, items[sent..][0..r.slice.len]);
                        }
                        self.base.commit(r.slice.len);
                        sent += r.slice.len;
                        bo.reset();
                    } else {
                        if (self.base.ring.isClosed()) break;
                        bo.snooze();
                        if (bo.isCompleted()) break;
                    }
                }
                return sent;
            }

            pub fn availableCapacity(self: ProducerExt) usize {
                return RingType.capacity() - self.base.ring.len();
            }
        };

        pub fn registerExt(self: *Self) error{ Closed, OutOfMemory }!ProducerExt {
            const producer = try self.register();
            return .{ .base = producer };
        }
    };
}

// Type alias
pub const DefaultChannel = Channel(u64, default_config);
