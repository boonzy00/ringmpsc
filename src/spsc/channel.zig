//! ringmpsc - SPSC Channel (Single-Producer Single-Consumer)
//!
//! Thin wrapper over the core ring buffer providing a channel-style API
//! consistent with MPSC and MPMC channels.

const ring_mod = @import("../primitives/ring_buffer.zig");

pub const Ring = ring_mod.Ring;
pub const Config = ring_mod.Config;
pub const Reservation = ring_mod.Reservation;
pub const Backoff = ring_mod.Backoff;
pub const Metrics = ring_mod.Metrics;

pub const default_config = ring_mod.default_config;
pub const low_latency_config = ring_mod.low_latency_config;
pub const high_throughput_config = ring_mod.high_throughput_config;
pub const ultra_low_latency_config = ring_mod.ultra_low_latency_config;

/// SPSC Channel — a single-producer single-consumer ring buffer channel.
///
/// This is the fundamental building block. MPSC and MPMC channels
/// are composed from arrays of these.
pub fn Channel(comptime T: type, comptime config: Config) type {
    return Ring(T, config);
}

/// Default SPSC channel with u64 items
pub const DefaultChannel = Channel(u64, default_config);
