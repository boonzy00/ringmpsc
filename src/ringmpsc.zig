//! ringmpsc - High-Performance Lock-Free Ring Buffer Channels
//!
//! A Zig library providing lock-free SPSC, MPSC, and MPMC ring buffer channels
//! featuring ring-decomposed architecture, NUMA-aware allocation, SIMD-accelerated
//! batch operations, and progressive work-stealing.
//!
//! ## Architecture
//!
//! Channels are built on dedicated per-producer SPSC ring buffers, eliminating
//! producer-producer contention entirely. The cardinality matrix:
//!
//! | | Single-Consumer | Multi-Consumer |
//! |---|---|---|
//! | **Single-Producer** | `spsc.Channel` | — |
//! | **Multi-Producer** | `mpsc.Channel` | `mpmc.MpmcChannel` |
//!
//! ## Quick Start
//!
//! ```zig
//! const ringmpsc = @import("ringmpsc");
//!
//! // SPSC ring buffer (zero-overhead)
//! var ring = ringmpsc.spsc.Channel(u64, .{}){};
//! _ = ring.send(&[_]u64{1, 2, 3});
//!
//! // MPSC channel (multi-producer)
//! var channel = try ringmpsc.mpsc.Channel(u64, .{}).init(allocator);
//! defer channel.deinit();
//! const producer = try channel.register();
//! _ = producer.sendOne(42);
//!
//! // MPMC channel (work-stealing consumers)
//! var mpmc = ringmpsc.mpmc.MpmcChannel(u64, .{}){};
//! const prod = try mpmc.register();
//! const cons = try mpmc.registerConsumer();
//! _ = prod.sendOne(42);
//! var buf: [16]u64 = undefined;
//! const n = cons.steal(&buf);
//! _ = n;
//! ```

pub const version = .{ .major = 2, .minor = 3, .patch = 0 };

// ============================================================================
// PRIMITIVES — shared building blocks
// ============================================================================

pub const primitives = struct {
    pub const ring_buffer = @import("primitives/ring_buffer.zig");
    pub const backoff = @import("primitives/backoff.zig");
    pub const simd = @import("primitives/simd.zig");
    pub const blocking = @import("primitives/blocking.zig");
    pub const wait_strategy = @import("primitives/wait_strategy.zig");
    pub const event_notifier = @import("primitives/event_notifier.zig");
    pub const buffer_pool = @import("primitives/buffer_pool.zig");
    pub const shared_ring = @import("primitives/shared_ring.zig");

    // Re-export common types
    pub const Ring = ring_buffer.Ring;
    pub const Config = ring_buffer.Config;
    pub const Reservation = ring_buffer.Reservation;
    pub const Backoff = backoff.Backoff;
    pub const WaitStrategy = wait_strategy.WaitStrategy;
    pub const Waiter = wait_strategy.Waiter;
    pub const Timeout = blocking.Timeout;
    pub const BlockingError = blocking.BlockingError;
    pub const sendBlocking = blocking.sendBlocking;
    pub const recvBlocking = blocking.recvBlocking;
    pub const stealBlocking = blocking.stealBlocking;
    pub const EventNotifier = event_notifier.EventNotifier;
    pub const BufferPool = buffer_pool.BufferPool;
    pub const Handle = buffer_pool.Handle;
    pub const INVALID_HANDLE = buffer_pool.INVALID_HANDLE;
    pub const SharedRing = shared_ring.SharedRing;
    pub const SharedRingHeader = shared_ring.SharedRingHeader;
};

// ============================================================================
// CHANNELS — organized by producer/consumer cardinality
// ============================================================================

pub const spsc = struct {
    const channel_mod = @import("spsc/channel.zig");

    pub const Channel = channel_mod.Channel;
    pub const Config = channel_mod.Config;
    pub const default_config = channel_mod.default_config;
    pub const low_latency_config = channel_mod.low_latency_config;
    pub const high_throughput_config = channel_mod.high_throughput_config;
    pub const ultra_low_latency_config = channel_mod.ultra_low_latency_config;
};

pub const spmc = struct {
    const channel_mod = @import("spmc/channel.zig");

    pub const Channel = channel_mod.Channel;
    pub const SpmcConfig = channel_mod.SpmcConfig;
    pub const default_config = channel_mod.default_config;
    pub const high_throughput_config = channel_mod.high_throughput_config;
    pub const low_latency_config = channel_mod.low_latency_config;
};

pub const mpsc = struct {
    const channel_mod = @import("mpsc/channel.zig");

    pub const Channel = channel_mod.Channel;
    pub const Config = channel_mod.Config;
    pub const default_config = channel_mod.default_config;
    pub const low_latency_config = channel_mod.low_latency_config;
    pub const high_throughput_config = channel_mod.high_throughput_config;
};

pub const mpmc = struct {
    const channel_mod = @import("mpmc/channel.zig");

    pub const MpmcChannel = channel_mod.MpmcChannel;
    pub const MpmcRing = channel_mod.MpmcRing;
    pub const MpmcConfig = channel_mod.MpmcConfig;
    pub const default_mpmc_config = channel_mod.default_mpmc_config;
    pub const high_throughput_mpmc_config = channel_mod.high_throughput_mpmc_config;
};

// ============================================================================
// EVENT LOOP — thin managed consumer
// ============================================================================

pub const EventLoop = @import("event_loop.zig").EventLoop;

// ============================================================================
// PLATFORM — OS-specific functionality
// ============================================================================

pub const platform = struct {
    pub const numa = @import("platform/numa.zig");
    pub const NumaTopology = numa.NumaTopology;
    pub const NumaAllocator = numa.NumaAllocator;
    pub const NumaNode = numa.NumaNode;
    pub const bindToCpu = numa.bindToCpu;
    pub const bindToNode = numa.bindToNode;
    pub const currentCpu = numa.currentCpu;
    pub const currentNode = numa.currentNode;

    pub const fd_passing = @import("platform/fd_passing.zig");
    pub const sendFd = fd_passing.sendFd;
    pub const recvFd = fd_passing.recvFd;
    pub const connectUnix = fd_passing.connectUnix;
    pub const FdServer = fd_passing.FdServer;
};

// ============================================================================
// METRICS — observability
// ============================================================================

pub const metrics = struct {
    pub const collector = @import("metrics/collector.zig");
    pub const Metrics = collector.Metrics;
};

// ============================================================================
// CONVENIENCE ALIASES
// ============================================================================

/// Default SPSC channel with u64 items
pub const DefaultSpscChannel = spsc.Channel(u64, spsc.default_config);

/// Default SPMC channel with u64 items
pub const DefaultSpmcChannel = spmc.Channel(u64, spmc.default_config);

/// Default MPSC channel with u64 items
pub const DefaultChannel = mpsc.Channel(u64, mpsc.default_config);

/// Default MPMC channel with u64 items
pub const DefaultMpmcChannel = mpmc.MpmcChannel(u64, mpmc.default_mpmc_config);

// ============================================================================
// TESTS
// ============================================================================

test {
    @import("std").testing.refAllDecls(@This());
}
