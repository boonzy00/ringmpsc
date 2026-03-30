//! ringmpsc - Adaptive backoff helper (spin → yield → park)
//!
//! Crossbeam-style exponential backoff for contention handling.

const std = @import("std");

pub const Backoff = struct {
    step: u32 = 0,

    const SPIN_LIMIT: u5 = 6; // 2^6 = 64 spins max before yielding
    const YIELD_LIMIT: u5 = 10; // Then park

    /// Light spin with PAUSE hints
    pub inline fn spin(self: *Backoff) void {
        const spins = @as(u32, 1) << @min(self.step, SPIN_LIMIT);
        for (0..spins) |_| {
            std.atomic.spinLoopHint();
        }
        if (self.step <= SPIN_LIMIT) self.step += 1;
    }

    /// Heavier backoff: spin then yield
    pub inline fn snooze(self: *Backoff) void {
        if (self.step <= SPIN_LIMIT) {
            self.spin();
        } else {
            std.Thread.yield() catch {};
            if (self.step <= YIELD_LIMIT) self.step += 1;
        }
    }

    /// Check if we've exhausted patience
    pub inline fn isCompleted(self: *const Backoff) bool {
        return self.step > YIELD_LIMIT;
    }

    /// Reset for next wait cycle
    pub inline fn reset(self: *Backoff) void {
        self.step = 0;
    }
};
