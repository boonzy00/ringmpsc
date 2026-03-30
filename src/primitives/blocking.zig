//! ringmpsc — Blocking wrappers with timeout
//!
//! Provides blocking send/recv operations that spin, yield, then sleep
//! until the operation succeeds or the timeout expires. Built on top of
//! the lock-free try-or-fail primitives.
//!
//! These are convenience wrappers — the core channels remain lock-free.

const std = @import("std");
const Backoff = @import("backoff.zig").Backoff;

pub const Timeout = union(enum) {
    /// Block forever until success or channel close
    unlimited,
    /// Block for at most this many nanoseconds
    ns: u64,
};

pub const BlockingError = error{
    TimedOut,
    Closed,
};

/// Blocking send: retries with adaptive backoff until success, timeout, or close.
/// Works with any type that has `sendOne(item) bool` and `isClosed() bool`.
pub fn sendBlocking(sender: anytype, item: anytype, timeout: Timeout) BlockingError!void {
    var bo = Backoff{};
    var elapsed: u64 = 0;
    const t0 = std.time.Instant.now() catch unreachable;

    while (true) {
        if (sender.sendOne(item)) return;

        if (@hasDecl(@TypeOf(sender.*), "isClosed")) {
            if (sender.isClosed()) return error.Closed;
        }

        switch (timeout) {
            .unlimited => {},
            .ns => |ns| {
                elapsed = (std.time.Instant.now() catch unreachable).since(t0);
                if (elapsed >= ns) return error.TimedOut;
            },
        }

        if (bo.isCompleted()) {
            // Past yield stage — short sleep to avoid burning CPU
            std.Thread.sleep(1_000); // 1us
            bo.reset();
        } else {
            bo.snooze();
        }
    }
}

/// Blocking receive: retries with adaptive backoff until an item is available,
/// timeout expires, or channel closes.
/// Works with any type that has a `recvOne() ?T` or `tryRecv() ?T` method,
/// plus `isClosed() bool`.
pub fn recvBlocking(comptime T: type, receiver: anytype, timeout: Timeout) BlockingError!T {
    var bo = Backoff{};
    var elapsed: u64 = 0;
    const t0 = std.time.Instant.now() catch unreachable;

    while (true) {
        // Try recvOne (MPSC) or tryRecv (SPSC ring)
        const maybe_item = if (@hasDecl(@TypeOf(receiver.*), "recvOne"))
            receiver.recvOne()
        else if (@hasDecl(@TypeOf(receiver.*), "tryRecv"))
            receiver.tryRecv()
        else
            @compileError("receiver must have recvOne() or tryRecv()");

        if (maybe_item) |item| return item;

        if (receiver.isClosed()) return error.Closed;

        switch (timeout) {
            .unlimited => {},
            .ns => |ns| {
                elapsed = (std.time.Instant.now() catch unreachable).since(t0);
                if (elapsed >= ns) return error.TimedOut;
            },
        }

        if (bo.isCompleted()) {
            std.Thread.sleep(1_000); // 1us
            bo.reset();
        } else {
            bo.snooze();
        }
    }
}

/// Blocking steal: retries until items are available or timeout.
/// Works with SPMC/MPMC Consumer types that have `steal(buf) usize`.
pub fn stealBlocking(comptime T: type, consumer: anytype, out: []T, channel: anytype, timeout: Timeout) BlockingError!usize {
    var bo = Backoff{};
    var elapsed: u64 = 0;
    const t0 = std.time.Instant.now() catch unreachable;

    while (true) {
        const n = consumer.steal(out);
        if (n > 0) return n;

        if (channel.isClosed()) return error.Closed;

        switch (timeout) {
            .unlimited => {},
            .ns => |ns| {
                elapsed = (std.time.Instant.now() catch unreachable).since(t0);
                if (elapsed >= ns) return error.TimedOut;
            },
        }

        if (bo.isCompleted()) {
            std.Thread.sleep(1_000); // 1us
            bo.reset();
        } else {
            bo.snooze();
        }
    }
}
