//! ringmpsc — Thin event loop for managed consumption.
//!
//! Packages the standard consumer while-loop into a spawnable thread.
//! Not a framework — just the loop. No error recovery, no lifecycle
//! callbacks, no dependency graphs.
//!
//! Usage:
//!   var loop = EventLoop(u64, Config).init(&channel, handler, .blocking);
//!   const thread = try loop.spawn();
//!   // ... later ...
//!   loop.stop();
//!   thread.join();

const std = @import("std");
const wait_mod = @import("primitives/wait_strategy.zig");

pub fn EventLoop(comptime T: type, comptime ChannelType: type) type {
    return struct {
        const Self = @This();

        channel: *ChannelType,
        handler: *const fn (*const T) void,
        wait_strategy: wait_mod.WaitStrategy,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        total_processed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        /// Create an event loop bound to a channel.
        pub fn init(
            channel: *ChannelType,
            handler: *const fn (*const T) void,
            strategy: wait_mod.WaitStrategy,
        ) Self {
            return .{
                .channel = channel,
                .handler = handler,
                .wait_strategy = strategy,
            };
        }

        /// Spawn the consumer loop on a new thread.
        pub fn spawn(self: *Self) !std.Thread {
            self.running.store(true, .release);
            return std.Thread.spawn(.{}, run, .{self});
        }

        /// Signal the loop to stop. It will finish the current batch,
        /// drain remaining messages, then exit.
        pub fn stop(self: *Self) void {
            self.running.store(false, .release);
            self.channel.shutdown();
        }

        /// Total messages processed across all batches.
        pub fn processed(self: *const Self) u64 {
            return self.total_processed.load(.acquire);
        }

        fn run(self: *Self) void {
            const Handler = struct {
                callback: *const fn (*const T) void,
                count: *std.atomic.Value(u64),

                pub fn process(h: @This(), item: *const T) void {
                    h.callback(item);
                    _ = h.count.fetchAdd(1, .monotonic);
                }
            };

            const handler = Handler{
                .callback = self.handler,
                .count = &self.total_processed,
            };

            var waiter = wait_mod.Waiter.init(self.wait_strategy);

            while (self.running.load(.acquire)) {
                const n = self.channel.consumeAll(handler);
                if (n > 0) {
                    waiter.reset();
                } else {
                    // Check if channel is closed
                    if (self.channel.isClosed()) break;

                    // Wait using configured strategy
                    waiter.wait(null, 0) catch break;
                }
            }

            // Drain remaining messages after stop
            _ = self.channel.drainAll(handler);
        }
    };
}
