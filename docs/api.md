# API Reference

Complete API surface for ringmpsc. All types are comptime-generic over element type `T` and a `Config` struct.

## Module Structure

```
ringmpsc
├── primitives
│   ├── Ring(T, Config)          # Core SPSC ring buffer
│   ├── Config                   # Shared configuration
│   ├── Reservation(T)           # Zero-copy write handle
│   ├── Backoff                  # Adaptive spin/yield/park
│   ├── EventNotifier            # eventfd wrapper for epoll/io_uring
│   ├── BufferPool(size, n)      # Lock-free slab allocator for zero-copy
│   ├── Handle                   # u32 slab handle (passed through Ring)
│   ├── SharedRing(T)            # Cross-process SPSC via memfd + MAP_SHARED
│   ├── SharedRingHeader         # extern struct header (512 bytes)
│   ├── simd                     # SIMD memcpy/memset utilities
│   └── blocking                 # Blocking wrappers with timeout
├── spsc
│   └── Channel(T, Config)       # Type alias for Ring (zero overhead)
├── mpsc
│   ├── Channel(T, Config)       # Multi-producer channel (heap-allocated rings)
│   ├── Channel.Producer         # Per-producer handle
│   └── Channel.ProducerExt      # Extended producer with blocking send
├── spmc
│   ├── Channel(T, SpmcConfig)   # Single ring, CAS-based multi-consumer
│   └── Channel.Consumer         # CAS-based consumer handle
├── mpmc
│   ├── MpmcChannel(T, MpmcConfig)  # Per-producer rings + work-stealing
│   ├── MpmcChannel.Producer     # Producer handle
│   ├── MpmcChannel.Consumer     # Work-stealing consumer handle
│   └── MpmcRing(T, MpmcConfig)  # CAS-enabled ring (internal)
├── platform.numa               # NUMA detection and binding
└── metrics.Metrics             # Optional throughput counters
```

---

## Configuration

### `primitives.Config`

Shared by SPSC and MPSC channels.

```zig
pub const Config = struct {
    ring_bits: u6 = 16,            // Ring capacity = 2^ring_bits
    max_producers: usize = 16,     // Max producer count (MPSC only)
    enable_metrics: bool = false,   // Track send/recv counters (adds atomic overhead)
    track_contention: bool = false, // Track reserve spin counts
    numa_node: i8 = -1,            // -1 = auto-detect, >= 0 = explicit node
    numa_aware: bool = true,        // Enable NUMA binding on init
    prefetch_threshold: usize = 16, // Min batch size for software prefetch (0 = disabled)
};
```

**Preset configs:**

| Name | ring_bits | Capacity | Use case |
|------|-----------|----------|----------|
| `default_config` | 16 | 64K | General purpose |
| `low_latency_config` | 12 | 4K | L1-resident, minimal latency |
| `high_throughput_config` | 18 | 256K | Maximum buffering |
| `ultra_low_latency_config` | 10 | 1K | Extreme latency sensitivity |

---

## Core Ring Buffer — `primitives.Ring(T, Config)`

The foundational SPSC ring buffer. All other channel types are built on this.

**Memory layout** (128-byte aligned regions):

```
Offset 0:     [Producer Hot]   tail: AtomicU64, cached_head: u64, [padding]
Offset 128:   [Consumer Hot]   head: AtomicU64, cached_tail: u64, [padding]
Offset 256:   [Cold State]     active, closed, consumer_waiters, producer_waiters, metrics (optional)
Offset 384+:  [Data Buffer]    [CAPACITY]T (64-byte aligned)
```

**Thread safety**: Exactly one producer thread and one consumer thread. No CAS operations — pure load/store with release/acquire ordering.

### Producer API

| Function | Signature | Hot Path | Description |
|----------|-----------|----------|-------------|
| `reserve` | `(n: usize) ?Reservation(T)` | **Yes** (inline) | Reserve `n` contiguous slots. Returns slice + position. Null if full. Fast path checks cached head; slow path does acquire load. |
| `commit` | `(n: usize) void` | **Yes** (inline) | Publish `n` slots by advancing tail with release store. Wakes blocked consumers (conditional — zero overhead when no waiters). |
| `reserveWithBackoff` | `(n: usize) ?Reservation(T)` | No | Reserve with spin/yield/give-up backoff. |
| `reserveBlocking` | `(n: usize, WaitStrategy) !Reservation(T)` | No | Reserve with configurable wait strategy. Blocks via futex when ring is full. Returns `error.TimedOut` or `error.Closed`. |
| `sendOneBlocking` | `(item: T, WaitStrategy) !void` | No | Blocking single-item send. |
| `send` | `(items: []const T) usize` | Yes (inline) | Convenience: reserve + SIMD copy + commit. Returns count sent. |

### Consumer API

| Function | Signature | Hot Path | Description |
|----------|-----------|----------|-------------|
| `readable` | `() ?[]const T` | **Yes** (inline) | Get contiguous readable slice. Null if empty. Uses cached tail. |
| `advance` | `(n: usize) void` | **Yes** (inline) | Consume `n` items by advancing head with release store. |
| `consumeBatch` | `(handler: anytype) usize` | **Yes** | Process all available items via `handler.process(*T)`, single head update. |
| `consumeBatchCount` | `() usize` | **Yes** | Count-only consume — advance head, no per-item callback. Maximum throughput path. |
| `consumeBatchBlocking` | `(handler, WaitStrategy) !usize` | No | Blocking consume. Waits via futex when ring is empty. Returns `error.TimedOut` or `error.Closed`. |
| `consumeBatchFn` | `(comptime callback: fn(*const T) void) usize` | Yes | Batch consume with comptime function pointer instead of handler struct. |
| `consumeUpTo` | `(max: usize, handler: anytype) usize` | Yes | Bounded batch consume. |
| `recv` | `(out: []T) usize` | Yes (inline) | Convenience: readable + SIMD copy + advance. |
| `tryRecv` | `() ?T` | Yes (inline) | Single-item receive. |
| `peek` | `() ?*const T` | Yes (inline) | Read next item without consuming. |
| `peekMany` | `(n: usize) ?[]const T` | Yes (inline) | Read up to n items without consuming. |
| `drain` | `(out: []T) usize` | No | Drain all items into output buffer. |
| `skip` | `(n: usize) usize` | No | Discard up to n items. |
| `iterator` | `() Iterator` | No | Ergonomic iterator with manual `finish()` to commit. |

### Lifecycle

| Function | Description |
|----------|-------------|
| `close()` | Signal closed state (release store). |
| `isClosed()` | Check closed state (acquire load). |
| `reset()` | Reset all state to initial. Not thread-safe. |
| `getMetrics()` | Return metrics snapshot (if `enable_metrics`). |
| `setEventNotifier(notifier)` | Attach EventNotifier for epoll/io_uring wake. Pass `null` to detach. After this, every `commit()` writes to eventfd. |

### Status

| Function | Description |
|----------|-------------|
| `len()` | Current item count (two monotonic loads). |
| `isEmpty()` | True if head == tail. |
| `isFull()` | True if len >= capacity. |
| `capacity()` | Compile-time ring capacity. |
| `totalMemory()` | Compile-time struct size in bytes. |
| `bufferMemory()` | Compile-time data buffer size in bytes. |

### Reservation

```zig
pub fn Reservation(comptime T: type) type {
    return struct {
        slice: []T,   // Writable slice into ring buffer (contiguous portion)
        pos: u64,     // Tail position at time of reservation
    };
}
```

The slice may be shorter than requested if the reservation wraps around the ring boundary. Call `commit(slice.len)` after writing.

**Wrap-around behavior:**
```
Ring buffer (capacity=8, MASK=7):
  Positions: [0][1][2][3][4][5][6][7]

  If tail=6, reserve(4):
    Available contiguous from index 6: only slots 6,7 (2 slots before wrap)
    Returns: slice of length 2 (not 4)
    Caller must commit(2), then call reserve() again for remaining items

  If tail=0, reserve(4):
    Available contiguous from index 0: slots 0,1,2,3 (4 slots)
    Returns: slice of length 4 (full request satisfied)
```

**Important contract:**
- `commit(n)` where `n > slice.len` is undefined behavior — never commit more than you reserved
- `commit(n)` where `n < slice.len` is valid — partially commit a reservation
- Calling `commit()` without a prior `reserve()` is undefined behavior
- Only one reservation can be active per ring at a time (no nested reserves)

---

## SPSC Channel — `spsc.Channel(T, Config)`

```zig
pub fn Channel(comptime T: type, comptime config: Config) type {
    return Ring(T, config);  // Direct type alias — zero overhead
}
```

Zero-cost abstraction. `spsc.Channel` IS the Ring. No wrapper struct, no extra indirection.

**Usage:**
```zig
var ch = ringmpsc.spsc.Channel(u64, .{}){};
_ = ch.send(&[_]u64{1, 2, 3});
```

---

## MPSC Channel — `mpsc.Channel(T, Config)`

Multi-producer single-consumer channel. Each producer gets a dedicated SPSC ring, eliminating producer-producer contention.

**Allocation**: Heap-allocated via `init(allocator)`. Rings are individually allocated for NUMA-local placement.

### Channel API

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `(allocator) !Self` | Allocate rings, bind to NUMA node. |
| `deinit` | `() void` | Free all rings. |
| `register` | `() !Producer` | Register a new producer. Grows ring array dynamically if capacity exceeded (mutex-protected, lock-free hot path). Returns `Closed` or `OutOfMemory`. |
| `deregister` | `(Producer) void` | Deregister a producer. Marks ring inactive/closed. Remaining messages are drained by the consumer's next `consumeAll()`. |
| `registerExt` | `() !ProducerExt` | Register with extended (blocking) API. Returns `Closed` or `OutOfMemory`. |
| `consumeAll` | `(handler) usize` | Batch consume from all rings with **adaptive skip** — exponentially backs off on empty rings. **Primary fast path.** |
| `consumeAllCount` | `() usize` | Count-only consume with adaptive skip. **Maximum throughput.** |
| `consumeAllUpTo` | `(max, handler) usize` | Bounded batch consume across all rings. |
| `resetAdaptiveSkip` | `() void` | Reset all skip counters. Call when workload changes. |
| `recv` | `(out: []T) usize` | Round-robin receive into buffer. |
| `recvOne` | `() ?T` | Single-item receive (scans all rings). |
| `tryRecv` | `() ?T` | Single-item receive (scans all rings). Equivalent to `recvOne`. |
| `drain` | `(out: []T) usize` | Drain all rings into buffer. |
| `close` | `() void` | Close channel and all rings. |
| `shutdown` | `() void` | Alias for close. Signal producers to stop. |
| `isClosed` | `() bool` | Check closed state. |
| `drainAll` | `(handler) usize` | Consume all remaining messages. Call after producers join. |
| `drainAllCount` | `() usize` | Count-only drain of all remaining messages. |
| `isFullyDrained` | `() bool` | True when closed AND all rings are empty. |
| `snapshot` | `() ChannelStats` | Point-in-time health metrics (pending, throughput, latency). |
| `totalPending` | `() usize` | Sum of len() across all rings. |
| `isEmpty` | `() bool` | True if all rings are empty. |
| `hottestRing` | `() ?*Ring` | Ring with most pending items. |
| `getRing` | `(id: usize) ?*Ring` | Direct ring access by producer ID. |
| `reset` | `() void` | Reset all rings. Not thread-safe. |

### Producer

Lightweight handle (ring pointer + ID). Copy-safe.

| Function | Signature | Description |
|----------|-----------|-------------|
| `reserve` | `(n) ?Reservation(T)` | Inline delegation to ring.reserve. |
| `commit` | `(n) void` | Inline delegation to ring.commit. |
| `send` | `(items) usize` | Inline delegation to ring.send. |
| `sendOne` | `(item) bool` | Reserve 1 + write + commit. |
| `reserveWithBackoff` | `(n) ?Reservation(T)` | Reserve with adaptive backoff. |

### ProducerExt

Extended producer with blocking operations.

| Function | Signature | Description |
|----------|-----------|-------------|
| `sendOne` | `(item) bool` | Same as Producer.sendOne. |
| `sendBlocking` | `(items) usize` | Blocking batch send with SIMD copy and backoff. Stops on close or backoff exhaustion. |
| `availableCapacity` | `() usize` | Ring capacity minus current length. |

---

## SPMC Channel — `spmc.Channel(T, SpmcConfig)`

Single-producer multi-consumer. One ring buffer, CAS-based consumer head advancement.

**Config**: `SpmcConfig` (separate from SPSC/MPSC Config — has `max_consumers` instead of `max_producers`).

### Producer API

Same as SPSC Ring: `reserve`, `commit`, `send`, `sendOne`. Single producer, no CAS on tail.

### Consumer API

Consumers compete via `cmpxchgWeak` on the shared head.

| Function | Signature | Description |
|----------|-----------|-------------|
| `steal` | `(out: []T) usize` | Speculative copy + CAS claim. Retries on CAS failure. |
| `stealOne` | `() ?T` | Single-item steal. |
| `consumeBatch` | `(Handler, handler) usize` | Copy to stack buffer, CAS claim, then process. Max 4096 items per steal. |

### Channel Lifecycle

| Function | Description |
|----------|-------------|
| `registerConsumer()` | Register consumer. Returns `TooManyConsumers` or `Closed`. |
| `close()` | Signal closed. |
| `isClosed()` | Check closed. |
| `len()` / `isEmpty()` | Status queries. |

---

## MPMC Channel — `mpmc.MpmcChannel(T, MpmcConfig)`

Multi-producer multi-consumer with progressive work-stealing.

**Config**: `MpmcConfig` — has both `max_producers`, `max_consumers`, and `rings_per_shard`.

**Architecture**: Inline array of `MpmcRing` (one per producer). Each `MpmcRing` uses CAS on head (unlike the SPSC Ring which uses plain stores). Producers write to their dedicated ring. Consumers steal from any ring using a 3-phase strategy.

### MpmcRing

Like SPSC Ring but with CAS-based consumer head and `hotness` tracking.

| Field | Purpose |
|-------|---------|
| `hotness: AtomicU32` | Tracks recent throughput. Incremented on commit, decremented on steal. Used for load balancing. |
| `owner_consumer: AtomicI32` | Reserved for future consumer affinity. |

### Consumer Work-Stealing Strategy

```
Phase 1: stealFromShard()     — Try assigned local rings (locality)
Phase 2: stealFromHottest()   — Find ring with highest hotness score (load balance)
Phase 3: stealRandom()        — xorshift random ring (starvation prevention)
```

Each phase calls `consumeSteal()` which does: speculative copy to stack buffer -> CAS claim -> process from stack buffer.

### Consumer API

| Function | Signature | Description |
|----------|-----------|-------------|
| `stealBatch` | `(Handler, handler) usize` | Full 3-phase progressive steal. |
| `steal` | `(out: []T) usize` | Raw steal: try shard, then fallback to all rings. |

---

## Blocking Wrappers — `primitives.blocking`

Convenience wrappers that turn try-or-fail operations into blocking operations with timeout.

```zig
pub const Timeout = union(enum) {
    unlimited,     // Block forever
    ns: u64,       // Block for N nanoseconds
};

pub const BlockingError = error{ TimedOut, Closed };
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `sendBlocking` | `(sender, item, Timeout) !void` | Retry sendOne with backoff + 1us sleep cycles. |
| `recvBlocking` | `(T, receiver, Timeout) !T` | Retry recvOne/tryRecv with backoff + 1us sleep. |
| `stealBlocking` | `(T, consumer, out, channel, Timeout) !usize` | Retry steal with backoff + 1us sleep. |

These work with any type that has the appropriate methods (`sendOne`, `recvOne`/`tryRecv`, `steal`, `isClosed`) via Zig's comptime duck typing.

---

## Wait Strategies — `primitives.WaitStrategy`

Pluggable strategies controlling how threads wait when a ring is empty (consumer) or full (producer).

```zig
pub const WaitStrategy = union(enum) {
    busy_spin,                              // Spin loop. Lowest latency, highest CPU.
    yielding,                               // Spin, then yield. Good balance.
    sleeping: struct { sleep_ns: u64 },     // Spin, yield, then sleep.
    blocking,                               // Spin, yield, then futex. Zero CPU when idle.
    timed_blocking: struct { timeout_ns: u64 }, // Blocking with deadline.
    phased_backoff: struct {                 // Configurable spin -> yield -> futex.
        spin_iterations: u32,
        yield_iterations: u32,
    },
};
```

**Usage**:
```zig
// Producer blocks until space is available (or 100ms timeout)
const r = try ring.reserveBlocking(1024, .{ .timed_blocking = .{ .timeout_ns = 100_000_000 } });

// Consumer blocks until data arrives (zero CPU when idle)
const n = try ring.consumeBatchBlocking(handler, .blocking);
```

**`Waiter`**: Stateful executor for a wait strategy. Maintains step counter and optional start timestamp. Call `wait()` in a loop, `reset()` after success.

**Futex integration**: Uses `std.Thread.Futex` (cross-platform: Linux futex, Windows WaitOnAddress, macOS ulock). Wake calls in `commit()`/`advance()` are conditional on `consumer_waiters`/`producer_waiters` counters — zero overhead when nobody is blocking.

---

## EventNotifier — `primitives.EventNotifier`

Linux eventfd wrapper enabling ring buffer consumers to participate in epoll/io_uring event loops. When attached to a ring, `commit()` automatically signals the eventfd, waking any consumer blocked in `epoll_wait`.

```zig
pub const EventNotifier = struct {
    efd: posix.fd_t,

    pub fn init() !EventNotifier;
    pub fn deinit(self: *EventNotifier) void;

    /// Producer: signal after commit (coalescing — multiple signals accumulate)
    pub fn signal(self: *const EventNotifier) void;

    /// Producer: conditional signal (zero syscall when no waiters)
    pub fn signalIfWaiting(self: *const EventNotifier, waiters: *const std.atomic.Value(u32)) void;

    /// Consumer: reset counter before re-entering epoll_wait
    pub fn consume(self: *const EventNotifier) u64;

    /// Register with epoll instance (edge-triggered)
    pub fn registerEpoll(self: *const EventNotifier, epoll_fd: posix.fd_t) !void;

    /// Unregister from epoll
    pub fn unregisterEpoll(self: *const EventNotifier, epoll_fd: posix.fd_t) void;

    /// Raw fd for custom event loop integration (io_uring, libxev)
    pub fn fd(self: *const EventNotifier) posix.fd_t;
};
```

**Usage pattern**:
```zig
var notifier = try ringmpsc.primitives.EventNotifier.init();
defer notifier.deinit();
ring.setEventNotifier(&notifier);
try notifier.registerEpoll(epoll_fd);

// Producer (automatic — commit() signals eventfd)
_ = ring.send(&items);

// Consumer (in epoll loop)
_ = notifier.consume();
while (ring.readable()) |slice| { process(slice); ring.advance(slice.len); }
```

**When to use**: Consumer thread also handles socket I/O, timers, or signals via epoll. For dedicated consumer threads, the default futex wake is faster (zero syscall when no waiters).

---

## Adaptive Consumer Skip — MPSC Channel

The MPSC consumer uses adaptive exponential backoff on consistently-empty producer rings. This reduces consumer polling cost from O(P) to O(active_producers).

| Function | Description |
|----------|-------------|
| `consumeAll(handler)` | Batch consume with adaptive skip. Empty rings are polled exponentially less often (1, 2, 4, 8, 16, 32, 64 rounds between checks). Resets immediately on non-empty. |
| `consumeAllCount()` | Same adaptive skip, count-only (no handler calls). |
| `resetAdaptiveSkip()` | Reset all skip counters. Call when workload pattern changes (new producers, burst expected). |

**Rationale**: Polling empty queues wastes cycles without reducing queue wait time. Adaptive exponential backoff eliminates this overhead for inactive producers while resetting immediately when data arrives.

---

## BufferPool — `primitives.BufferPool`

Lock-free slab allocator for zero-copy large message passing. Pre-allocates a contiguous memory region divided into fixed-size slabs. Handles (u32) are passed through the ring instead of payloads.

```zig
pub fn BufferPool(comptime slab_size: comptime_int, comptime num_slabs: comptime_int) type {
    return struct {
        pub const SLAB_SIZE = slab_size;
        pub const NUM_SLABS = num_slabs;

        /// Lock-free allocate. Returns handle or null if pool exhausted.
        pub fn alloc(self: *Self) ?Handle;

        /// Lock-free free. Caller must not access slab after this.
        pub fn free(self: *Self, handle: Handle) void;

        /// Readable slice of payload (len set by setLen). Zero copy.
        pub fn get(self: *Self, handle: Handle) []const u8;

        /// Writable pointer to full slab. Write payload here after alloc.
        pub fn getWritable(self: *Self, handle: Handle) *[slab_size]u8;

        /// Set payload length (release ordering for consumer visibility).
        pub fn setLen(self: *Self, handle: Handle, len: u32) void;

        /// Count free slabs (O(n), diagnostics only).
        pub fn availableCount(self: *Self) usize;

        /// Compile-time capacity.
        pub fn capacity() usize;

        /// Compile-time total memory footprint.
        pub fn totalMemory() usize;
    };
}
```

**Usage with Ring (pointer-ring pattern)**:
```zig
const Pool = ringmpsc.primitives.BufferPool(4096, 256); // 4KB slabs, 256 of them
var pool: Pool = .{};
var ring = ringmpsc.primitives.Ring(ringmpsc.primitives.Handle, .{ .ring_bits = 10 }){};

// Producer:
const handle = pool.alloc() orelse return error.PoolExhausted;
const buf = pool.getWritable(handle);
@memcpy(buf[0..data.len], data);         // write directly to pool (zero copy)
pool.setLen(handle, @intCast(data.len));
_ = ring.send(&[_]Handle{handle});        // 4 bytes through ring, not 4096

// Consumer:
const h = ring.recvOne() orelse continue;
const payload = pool.get(h);              // read from same address (zero copy)
process(payload);
pool.free(h);                             // return to pool
```

**Thread safety**: `alloc()` and `free()` are lock-free (CAS with ABA-safe tagged pointers). `get()`/`getWritable()`/`setLen()` are NOT thread-safe on the same handle — but this is correct because ownership is exclusive.

**ABA prevention**: The free-list head packs a 32-bit tag counter alongside the 32-bit index in a single u64 atomic. Each alloc/free increments the tag, preventing ABA even if the same slab is recycled between a thread's read and CAS.

---

## SharedRing — `primitives.SharedRing`

Cross-process SPSC ring buffer via memfd_create + MAP_SHARED. Enables lock-free message passing between separate processes.

```zig
pub fn SharedRing(comptime T: type) type {
    return struct {
        // ── Creation / Attachment ──
        pub fn create(ring_bits: u6) !Self;           // Creator: memfd + mmap + init
        pub fn attach(fd: posix.fd_t) !Self;          // Attacher: mmap + validate
        pub fn deinit(self: *Self) void;              // Unmap (creator also closes fd)
        pub fn getFd(self: *const Self) posix.fd_t;   // fd for SCM_RIGHTS passing

        // ── Producer API ──
        pub fn reserve(self: *Self, n: usize) ?[]T;   // Reserve slots
        pub fn commit(self: *Self, n: usize) void;    // Publish + heartbeat + futex wake
        pub fn send(self: *Self, items: []const T) usize; // reserve + copy + commit

        // ── Consumer API ──
        pub fn readable(self: *Self) ?[]const T;       // Get readable slice
        pub fn advance(self: *Self, n: usize) void;    // Advance head
        pub fn len(self: *const Self) usize;
        pub fn isEmpty(self: *const Self) bool;

        // ── Lifecycle ──
        pub fn close(self: *Self) void;
        pub fn isClosed(self: *const Self) bool;
        pub fn isProducerAlive(self: *const Self, timeout_ns: u64) bool;
    };
}
```

**SharedRingHeader** (extern struct, 512 bytes):

| Offset | Section | Fields |
|--------|---------|--------|
| 0x000 | Identification (128B) | magic, version, ring_bits, capacity, slot_size, creator_pid, generation |
| 0x080 | Producer hot (128B) | tail (atomic), cached_head, heartbeat_ns (atomic) |
| 0x100 | Consumer hot (128B) | head (atomic), cached_tail |
| 0x180 | Wake coordination (128B) | consumer_waiters, producer_waiters, closed (all atomic) |

128-byte alignment between sections prevents prefetcher-induced false sharing across processes.

**Usage**:
```zig
// Process A (creator):
var ring = try SharedRing(u64).create(12); // 4096 slots
defer ring.deinit();
// Pass ring.getFd() to Process B via Unix socket SCM_RIGHTS
_ = ring.send(&[_]u64{ 1, 2, 3 });

// Process B (attacher):
var ring = try SharedRing(u64).attach(received_fd);
defer ring.deinit();
if (ring.readable()) |slice| { process(slice); ring.advance(slice.len); }
```

**Crash recovery**: `isProducerAlive(timeout_ns)` checks the heartbeat timestamp. If the producer dies mid-write (between reserve and commit), the tail never advances — consumer never sees incomplete data.

**Cleanup**: memfd_create memory disappears when all fds close. No `shm_unlink` needed.

---

## Backoff — `primitives.Backoff`

Crossbeam-style adaptive backoff.

```zig
pub const Backoff = struct {
    step: u32 = 0,

    pub fn spin(self: *Backoff) void;       // 2^step PAUSE instructions (up to 64)
    pub fn snooze(self: *Backoff) void;     // spin phase, then yield phase
    pub fn isCompleted(self: *const Backoff) bool; // Past yield stage?
    pub fn reset(self: *Backoff) void;      // Reset for next wait cycle
};
```

**Phases**: Spin (steps 0–6: 1→64 PAUSE instructions) → Yield (steps 7–10: `sched_yield`) → Completed.

---

## Metrics — `metrics.Metrics`

Optional per-ring counters. Enabled via `Config.enable_metrics = true`.

```zig
pub const Metrics = struct {
    // Throughput
    messages_sent: u64,
    messages_received: u64,
    batches_sent: u64,
    batches_received: u64,

    // Backpressure
    reserve_spins: u64,
    reserve_failures: u64,
    total_wait_ns: u64,
    max_batch_size: u64,

    // Latency (per-batch, nanoseconds)
    latency_sum_ns: u64,
    latency_count: u64,
    latency_min_ns: u64,
    latency_max_ns: u64,

    pub fn avgLatencyNs(self: Metrics) f64;
    pub fn avgBatchSize(self: Metrics) f64;
    pub fn throughputPerSecond(self: Metrics, elapsed_ns: u64) f64;
    pub fn merge(self: *Metrics, other: Metrics) void;
    pub fn reset(self: *Metrics) void;
};
```

Latency is recorded in `consumeBatch` via `nanoTimestamp()` — two calls per batch when enabled.

**Overhead**: When `enable_metrics = true`:
- **Per send**: 1 atomic increment (`messages_sent`) + 1 atomic increment (`batches_sent`) = ~10ns
- **Per consume batch**: 2 `nanoTimestamp()` calls (~40-100ns total) + 2 atomic increments
- **Estimated throughput impact**: ~5-15% reduction in batch throughput, ~20-30% in single-item throughput
- When `enable_metrics = false` (default): metrics fields are `void` (zero size), all metrics code is comptime-eliminated. **Zero overhead.**

---

## Event Loop — `EventLoop(T, ChannelType)`

Thin managed consumer loop. Not a framework — just the 15-line while-loop every user writes, packaged as a spawnable thread.

```zig
var loop = ringmpsc.EventLoop(u64, Channel).init(&channel, handleMessage, .blocking);
const thread = try loop.spawn();
// ... producer sends messages ...
loop.stop();     // signals stop + shutdown
thread.join();   // waits for drain to complete
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `(*Channel, *const fn(*const T) void, WaitStrategy) Self` | Create loop bound to channel with handler and wait strategy. |
| `spawn` | `() !std.Thread` | Start consumer thread. |
| `stop` | `() void` | Signal stop. Calls `channel.shutdown()`. |
| `processed` | `() u64` | Total messages processed across all batches. |

The loop runs `consumeAll(handler)` in a tight loop, applies the wait strategy when idle, checks `isClosed()` for termination, and calls `drainAll(handler)` on exit. Zero message loss.

---

## NUMA — `platform.numa`

Full NUMA topology discovery, per-node allocation, and CPU affinity. Linux-specific with graceful fallback on other platforms.

### NumaTopology

Discovers the system's NUMA layout from `/sys/devices/system/node/`.

```zig
var topo = try ringmpsc.platform.NumaTopology.init(allocator);
defer topo.deinit();
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `(allocator) !NumaTopology` | Discover topology from sysfs. Falls back to single uniform node. |
| `deinit` | `() void` | Free all allocated node data. |
| `nodeOfCpu` | `(cpu: usize) usize` | Map a CPU ID to its NUMA node. |
| `nearestNode` | `(from: usize) usize` | Find closest neighbor via distance matrix. |
| `isNuma` | `() bool` | True if system has multiple NUMA nodes. |

**NumaNode** fields: `id`, `cpus: []usize`, `memory_bytes: u64`, `distances: []u32`.

### NumaAllocator

Per-node arena allocators with mbind for physical placement.

```zig
var na = try ringmpsc.platform.NumaAllocator.init(allocator, &topo);
defer na.deinit();
const ring = try na.allocOnNode(RingType, node_id);
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `init` | `(backing, *NumaTopology) !NumaAllocator` | Create per-node arenas. |
| `deinit` | `() void` | Free all arenas. |
| `allocOnNode` | `(T, node_id) !*T` | Allocate + zero-init + mbind on specific node. |
| `allocForCpu` | `(T, cpu) !*T` | Allocate on the NUMA node that owns the given CPU. |

### CPU Affinity

| Function | Signature | Description |
|----------|-----------|-------------|
| `bindToCpu` | `(cpu: usize) !void` | Pin calling thread to a CPU via `sched_setaffinity`. |
| `bindToNode` | `(node_id, *NumaTopology) !void` | Pin calling thread to first CPU of a NUMA node. |
| `currentCpu` | `() ?usize` | Detect which CPU the calling thread is on. |
| `currentNode` | `(*NumaTopology) usize` | Detect the calling thread's NUMA node. |
| `bindMemoryToNode` | `(addr, len, node) void` | Apply `mbind(MPOL_BIND)` to a memory region. Graceful no-op on failure. (Internal — used by MPSC channel, not re-exported from root module.) |

### MPSC Integration

NUMA is automatic when `Config.numa_aware = true` (the default):

- `Channel.init()` discovers topology once
- `Channel.register()` detects calling producer thread's NUMA node and binds that ring to it
- Skipped entirely on single-node systems (`topology.isNuma() == false`)

---

## fd Passing — `platform.fd_passing`

Send/receive file descriptors between processes via Unix domain sockets using SCM_RIGHTS ancillary messages. Required for establishing SharedRing connections between separate processes.

| Function | Signature | Description |
|----------|-----------|-------------|
| `sendFd` | `(socket: fd_t, fd_to_send: fd_t) !void` | Send a file descriptor over a connected Unix socket |
| `recvFd` | `(socket: fd_t) !fd_t` | Receive a file descriptor from a connected Unix socket |
| `connectUnix` | `(path: []const u8) !fd_t` | Connect to a Unix domain socket (client side) |

### FdServer

Simple Unix domain socket server for fd exchange during SharedRing establishment.

| Function | Signature | Description |
|----------|-----------|-------------|
| `listen` | `(path: []const u8) !FdServer` | Create and bind a Unix socket, listen for connections |
| `accept` | `() !fd_t` | Accept one connection |
| `deinit` | `() void` | Close socket and remove socket file |

**Full cross-process flow**:
```zig
// Process A (server + producer):
var ring = try SharedRing(u64).create(14);
var server = try platform.fd_passing.FdServer.listen("/tmp/ring.sock");
const conn = try server.accept();
try platform.fd_passing.sendFd(conn, ring.getFd());
_ = ring.send(&items);

// Process B (client + consumer):
const conn = try platform.fd_passing.connectUnix("/tmp/ring.sock");
const fd = try platform.fd_passing.recvFd(conn);
var ring = try SharedRing(u64).attach(fd);
while (ring.readable()) |slice| { process(slice); ring.advance(slice.len); }
```

---

## Default Type Aliases

```zig
pub const DefaultSpscChannel  = spsc.Channel(u64, spsc.default_config);
pub const DefaultChannel      = mpsc.Channel(u64, mpsc.default_config);   // MPSC
pub const DefaultSpmcChannel  = spmc.Channel(u64, spmc.default_config);
pub const DefaultMpmcChannel  = mpmc.MpmcChannel(u64, mpmc.default_mpmc_config);
```
