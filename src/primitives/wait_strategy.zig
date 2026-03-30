//! Pluggable wait strategies for consumers and producers.
//!
//! Controls how threads wait when a ring is empty (consumer) or full (producer).
//! Strategies range from lowest-latency (busy spin) to most CPU-efficient
//! (futex-based blocking with zero CPU usage when idle).

const std = @import("std");
const Futex = std.Thread.Futex;

// ============================================================================
// WAIT STRATEGY
// ============================================================================

pub const WaitStrategy = union(enum) {
    /// Spin loop with PAUSE hints. Lowest latency, highest CPU burn.
    /// Use when: dedicated cores, sub-microsecond latency required.
    busy_spin,

    /// Spin briefly, then yield. Good general-purpose balance.
    /// Use when: shared cores, low-latency but not extreme.
    yielding,

    /// Spin, yield, then sleep for configurable duration.
    /// Use when: moderate latency tolerance, CPU efficiency matters.
    sleeping: SleepingConfig,

    /// Spin, yield, then block on futex. Zero CPU when idle.
    /// Use when: bursty workloads, CPU efficiency is critical.
    blocking,

    /// Blocking with a deadline. Returns error.TimedOut if exceeded.
    /// Use when: you need bounded wait times.
    timed_blocking: TimedBlockingConfig,

    /// Phased: spin -> yield -> futex. Escalating strategy.
    /// Use when: you want low latency for bursts, zero CPU for idle.
    phased_backoff: PhasedConfig,

    pub const SleepingConfig = struct {
        sleep_ns: u64 = 1_000, // 1 microsecond default
    };

    pub const TimedBlockingConfig = struct {
        timeout_ns: u64,
    };

    pub const PhasedConfig = struct {
        spin_iterations: u32 = 100,
        yield_iterations: u32 = 10,
    };
};

// ============================================================================
// WAITER — stateful wait loop executor
// ============================================================================

/// A Waiter executes a wait strategy, maintaining state across iterations.
/// Create one per wait loop. Call `wait()` repeatedly until your condition
/// is met, or it returns `error.TimedOut`.
pub const Waiter = struct {
    strategy: WaitStrategy,
    step: u32 = 0,
    start_ns: ?u64 = null,

    pub fn init(strategy: WaitStrategy) Waiter {
        return .{ .strategy = strategy };
    }

    /// Execute one iteration of the wait strategy.
    /// `futex_ptr` is the 32-bit atomic to futex-wait on (typically a
    /// truncated tail or head pointer). `futex_expect` is the value
    /// we expect it to still hold.
    /// Returns `error.TimedOut` if a timed strategy exceeds its deadline.
    pub fn wait(self: *Waiter, futex_ptr: ?*const std.atomic.Value(u32), futex_expect: u32) error{TimedOut}!void {
        switch (self.strategy) {
            .busy_spin => {
                std.atomic.spinLoopHint();
            },

            .yielding => {
                if (self.step < 10) {
                    std.atomic.spinLoopHint();
                } else {
                    std.Thread.yield() catch {};
                }
                self.step +|= 1;
            },

            .sleeping => |cfg| {
                if (self.step < 10) {
                    std.atomic.spinLoopHint();
                } else if (self.step < 20) {
                    std.Thread.yield() catch {};
                } else {
                    std.Thread.sleep(cfg.sleep_ns);
                }
                self.step +|= 1;
            },

            .blocking => {
                if (self.step < 10) {
                    std.atomic.spinLoopHint();
                } else if (self.step < 20) {
                    std.Thread.yield() catch {};
                } else {
                    // Block on futex — zero CPU while waiting
                    if (futex_ptr) |ptr| {
                        Futex.wait(ptr, futex_expect);
                    } else {
                        std.Thread.sleep(1_000); // fallback if no futex ptr
                    }
                }
                self.step +|= 1;
            },

            .timed_blocking => |cfg| {
                // Record start time on first iteration
                if (self.start_ns == null) {
                    self.start_ns = timestampNs();
                }

                // Check deadline
                const elapsed = timestampNs() - self.start_ns.?;
                if (elapsed >= cfg.timeout_ns) return error.TimedOut;

                if (self.step < 10) {
                    std.atomic.spinLoopHint();
                } else if (self.step < 20) {
                    std.Thread.yield() catch {};
                } else {
                    const remaining = cfg.timeout_ns - elapsed;
                    if (futex_ptr) |ptr| {
                        Futex.timedWait(ptr, futex_expect, remaining) catch |err| switch (err) {
                            error.Timeout => return error.TimedOut,
                        };
                    } else {
                        std.Thread.sleep(@min(remaining, 1_000));
                    }
                }
                self.step +|= 1;
            },

            .phased_backoff => |cfg| {
                if (self.step < cfg.spin_iterations) {
                    std.atomic.spinLoopHint();
                } else if (self.step < cfg.spin_iterations + cfg.yield_iterations) {
                    std.Thread.yield() catch {};
                } else {
                    // Block on futex
                    if (futex_ptr) |ptr| {
                        Futex.wait(ptr, futex_expect);
                    } else {
                        std.Thread.sleep(1_000);
                    }
                }
                self.step +|= 1;
            },
        }
    }

    /// Reset state for next wait cycle (after successfully getting data).
    pub fn reset(self: *Waiter) void {
        self.step = 0;
        self.start_ns = null;
    }
};

// ============================================================================
// FUTEX HELPERS
// ============================================================================

/// Wake up to `max_waiters` threads blocked on a futex pointer.
/// This is the counterpart to `Waiter.wait()` — call it after
/// producing data (commit) or consuming data (advance).
pub fn wake(futex_ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
    Futex.wake(futex_ptr, max_waiters);
}

/// Get a pointer to the low 32 bits of a u64 atomic, suitable for futex ops.
/// Futex only works on 32-bit values, so we use the low half of the 64-bit
/// tail/head pointer. This is safe because any change to the u64 will also
/// change the low 32 bits (unless exactly 2^32 items are added between checks,
/// which is impossible with ring sizes < 2^32).
pub fn futexPtr(atomic_u64: *const std.atomic.Value(u64)) *const std.atomic.Value(u32) {
    const byte_ptr: [*]const u8 = @ptrCast(atomic_u64);
    // On little-endian (x86), low 32 bits are at offset 0
    // On big-endian, they'd be at offset 4
    const offset: usize = if (comptime @import("builtin").cpu.arch.endian() == .little) 0 else 4;
    return @ptrCast(@alignCast(byte_ptr + offset));
}

/// Get the low 32 bits of a u64 value (for futex expect comparison).
pub fn futexValue(val: u64) u32 {
    return @truncate(val);
}

fn timestampNs() u64 {
    // Use nanoTimestamp for wall-clock elapsed time measurement.
    // Safe for timeout computation (not for benchmarking).
    return @intCast(@max(0, std.time.nanoTimestamp()));
}
