//! EventNotifier — eventfd-based consumer wake for epoll/io_uring integration.
//!
//! Enables ringmpsc consumers to participate in event loops that multiplex
//! ring buffer readiness with socket I/O, timers, and signals.
//!
//! IMPORTANT: Edge-triggered epoll requires a specific consume pattern to
//! prevent lost wakes. The correct loop is:
//!
//!   while (true) {
//!       const n = posix.epoll_wait(epoll_fd, &events, -1);
//!       for (events[0..n]) |ev| {
//!           if (ev.data.fd == notifier.fd()) {
//!               // MUST drain ring completely before re-entering epoll_wait
//!               _ = notifier.consume();
//!               while (ring.readable()) |slice| {
//!                   process(slice);
//!                   ring.advance(slice.len);
//!               }
//!               // If a signal arrived during drain, the ring is non-empty
//!               // and the next epoll_wait will return immediately (ET re-arms
//!               // because eventfd counter went 0→N during our drain).
//!           }
//!       }
//!   }
//!
//! The key safety property: consume() reads the eventfd counter to 0.
//! Any signal() AFTER that read creates a new 0→1 edge transition,
//! which ET mode WILL report on the next epoll_wait. Lost wakes only
//! happen if the consumer does work between consume() and epoll_wait
//! that allows a signal to arrive AND be consumed before epoll sees it.
//! Since we read the counter exactly once (in consume()), this cannot
//! happen — the eventfd stays readable until we call consume() again.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const EventNotifier = struct {
    efd: posix.fd_t,

    pub fn init() !EventNotifier {
        const flags: u32 = linux.EFD.NONBLOCK | linux.EFD.CLOEXEC;
        const raw = linux.eventfd(0, flags);
        const efd: posix.fd_t = switch (posix.errno(raw)) {
            .SUCCESS => @intCast(raw),
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        };
        return .{ .efd = efd };
    }

    pub fn deinit(self: *EventNotifier) void {
        posix.close(self.efd);
    }

    /// Producer calls this after commit(). Writes u64(1) to eventfd.
    /// Multiple signals coalesce — consumer treats it as "check ring now."
    /// Cost: one write() syscall (~1us).
    ///
    /// Note: write() to a non-blocking eventfd can only fail if the counter
    /// would overflow u64-1 (practically impossible). We ignore the error
    /// because the consumer's drain loop will catch any pending data
    /// regardless of whether this specific signal was delivered.
    pub inline fn signal(self: *const EventNotifier) void {
        const val: u64 = 1;
        _ = posix.write(self.efd, std.mem.asBytes(&val)) catch {};
    }

    /// Conditional signal: only write to eventfd if the consumer is likely
    /// waiting. Pass the consumer_waiters atomic from the ring buffer.
    /// When no waiters, this is a single atomic load (no syscall).
    pub inline fn signalIfWaiting(self: *const EventNotifier, waiters: *const std.atomic.Value(u32)) void {
        if (waiters.load(.acquire) > 0) {
            self.signal();
        }
    }

    /// Consumer calls this to reset the eventfd counter.
    /// After this call, any NEW signal() creates a 0→1 edge transition
    /// that edge-triggered epoll WILL report.
    ///
    /// MUST be followed by a complete ring drain before re-entering
    /// epoll_wait. See module-level docs for the safe pattern.
    ///
    /// Returns the accumulated signal count (informational — the actual
    /// number of pending items is determined by the ring, not this counter).
    pub inline fn consume(self: *const EventNotifier) u64 {
        var val: u64 = 0;
        _ = posix.read(self.efd, std.mem.asBytes(&val)) catch return 0;
        return val;
    }

    /// Register with an epoll instance for edge-triggered notification.
    pub fn registerEpoll(self: *const EventNotifier, epoll_fd: posix.fd_t) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET,
            .data = .{ .fd = self.efd },
        };
        try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, self.efd, &event);
    }

    /// Unregister from an epoll instance.
    /// Errors are silently ignored because this is typically called during
    /// cleanup when the epoll fd may already be closed.
    pub fn unregisterEpoll(self: *const EventNotifier, epoll_fd: posix.fd_t) void {
        posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_DEL, self.efd, null) catch {};
    }

    /// Get the raw fd for custom event loop integration (io_uring, etc).
    pub fn fd(self: *const EventNotifier) posix.fd_t {
        return self.efd;
    }
};
