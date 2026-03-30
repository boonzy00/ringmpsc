//! BufferPool — Lock-free slab allocator for zero-copy large message passing.
//!
//! Companion to Ring for the pointer-ring pattern: the ring carries small
//! handles (u32), while payloads live in a pre-allocated buffer pool.
//! This eliminates payload copies for messages larger than a cache line.
//!
//! Usage:
//!   var pool = BufferPool(4096, 1024).init();
//!   const handle = pool.alloc() orelse return error.PoolExhausted;
//!   const buf = pool.getWritable(handle);
//!   @memcpy(buf[0..data.len], data);
//!   pool.setLen(handle, @intCast(data.len));
//!   _ = ring.send(&[_]Handle{handle});   // ownership transfers here
//!
//!   // Consumer:
//!   const h = ring.recvOne() orelse continue;
//!   const payload = pool.get(h);         // zero-copy read
//!   process(payload);
//!   pool.free(h);                        // return to pool
//!
//! Thread safety:
//!   alloc() and free() are lock-free (CAS on tagged free-list head).
//!   get()/getWritable()/setLen() are NOT thread-safe on the same handle —
//!   but this is correct because ownership is exclusive: only the current
//!   owner (producer before send, consumer after recv) accesses the slab.

const std = @import("std");

/// A handle to a slab in the buffer pool. Passed through a ring buffer
/// to transfer ownership of the underlying payload without copying it.
pub const Handle = u32;

/// Sentinel value indicating no slab / pool exhausted.
pub const INVALID_HANDLE: Handle = std.math.maxInt(Handle);

/// Lock-free slab-based buffer pool.
///
/// `slab_size`: bytes per slab (e.g., 4096 for page-sized messages).
/// `num_slabs`: number of pre-allocated slabs.
///
/// Total memory: `num_slabs * (slab_size + @sizeOf(SlabMeta))`.
/// All memory is inline (no heap allocation). Use as a struct field
/// or allocate on the heap if the total size is large.
pub fn BufferPool(comptime slab_size: comptime_int, comptime num_slabs: comptime_int) type {
    comptime {
        if (slab_size == 0) @compileError("slab_size must be > 0");
        if (num_slabs == 0) @compileError("num_slabs must be > 0");
        if (num_slabs > std.math.maxInt(Handle) - 1) @compileError("num_slabs too large for Handle type");
    }

    return struct {
        const Self = @This();
        pub const SLAB_SIZE = slab_size;
        pub const NUM_SLABS = num_slabs;

        /// Pre-allocated contiguous data region.
        /// Each slab is `slab_size` bytes at offset `handle * slab_size`.
        data: [num_slabs * slab_size]u8 align(64) = undefined,

        /// Per-slab metadata: free-list link + payload length.
        meta: [num_slabs]SlabMeta = blk: {
            @setEvalBranchQuota(num_slabs * 10 + 1000);
            // Build initial free list: 0 -> 1 -> 2 -> ... -> INVALID
            var m: [num_slabs]SlabMeta = undefined;
            for (0..num_slabs) |i| {
                m[i] = .{
                    .next_free = if (i + 1 < num_slabs) @intCast(i + 1) else INVALID_HANDLE,
                    .len = std.atomic.Value(u32).init(0),
                };
            }
            break :blk m;
        },

        /// Lock-free free-list head. Packed as (tag:u32 << 32 | index:u32)
        /// to prevent ABA problem on CAS.
        free_head: std.atomic.Value(u64) = std.atomic.Value(u64).init(packTagged(0, 0)),

        const SlabMeta = struct {
            next_free: Handle,
            len: std.atomic.Value(u32),
        };

        /// Allocate a slab. Returns handle or null if pool is exhausted.
        /// Lock-free: CAS pop from free-list head.
        pub fn alloc(self: *Self) ?Handle {
            while (true) {
                const head = self.free_head.load(.acquire);
                const idx = unpackIndex(head);
                if (idx == INVALID_HANDLE) return null;

                const tag = unpackTag(head);
                const next = self.meta[idx].next_free;
                const new_head = packTagged(next, tag +% 1);

                if (self.free_head.cmpxchgWeak(
                    head,
                    new_head,
                    .acq_rel,
                    .acquire,
                ) == null) {
                    // CAS succeeded — we own this slab
                    self.meta[idx].len.store(0, .monotonic);
                    return idx;
                }
                // CAS failed — retry
            }
        }

        /// Return a slab to the pool. The caller must not access the
        /// slab data after this call.
        /// Lock-free: CAS push onto free-list head.
        pub fn free(self: *Self, handle: Handle) void {
            if (handle >= num_slabs) return; // invalid handle guard

            while (true) {
                const head = self.free_head.load(.acquire);
                const tag = unpackTag(head);
                self.meta[handle].next_free = unpackIndex(head);
                const new_head = packTagged(handle, tag +% 1);

                if (self.free_head.cmpxchgWeak(
                    head,
                    new_head,
                    .acq_rel,
                    .acquire,
                ) == null) {
                    return; // CAS succeeded
                }
                // CAS failed — retry
            }
        }

        /// Get readable slice of the slab's payload (up to setLen bytes).
        /// Only call when you own the handle (after recv, before free).
        pub fn get(self: *Self, handle: Handle) []const u8 {
            const offset = @as(usize, handle) * slab_size;
            const len = self.meta[handle].len.load(.acquire);
            return self.data[offset..][0..len];
        }

        /// Get writable pointer to the full slab. Write your payload here
        /// after alloc(), then call setLen() with the actual payload size.
        pub fn getWritable(self: *Self, handle: Handle) *[slab_size]u8 {
            const offset = @as(usize, handle) * slab_size;
            return @ptrCast(&self.data[offset]);
        }

        /// Set the payload length after writing data. Must be ≤ slab_size.
        /// Release ordering ensures payload writes are visible to consumer.
        pub fn setLen(self: *Self, handle: Handle, len: u32) void {
            std.debug.assert(len <= slab_size);
            self.meta[handle].len.store(len, .release);
        }

        /// Number of currently available (free) slabs.
        /// Walks the free list — O(n), use for diagnostics only.
        pub fn availableCount(self: *Self) usize {
            var count: usize = 0;
            var idx = unpackIndex(self.free_head.load(.acquire));
            while (idx != INVALID_HANDLE and count < num_slabs) {
                count += 1;
                idx = self.meta[idx].next_free;
            }
            return count;
        }

        /// Total pool capacity (compile-time constant).
        pub fn capacity() usize {
            return num_slabs;
        }

        /// Total memory footprint in bytes (compile-time constant).
        pub fn totalMemory() usize {
            return @sizeOf(Self);
        }

        // ── Tagged pointer helpers (ABA prevention) ──
        // The tag is 32 bits, so ABA protection holds for up to 2^32
        // (~4 billion) alloc/free cycles. At 1 billion alloc/free per
        // second, this is ~4 seconds before wrap. For long-running
        // systems with extreme churn, consider using a 64-bit tag
        // with a separate atomic counter (at the cost of a wider CAS).

        fn packTagged(index: Handle, tag: u32) u64 {
            return @as(u64, tag) << 32 | @as(u64, index);
        }

        fn unpackIndex(tagged: u64) Handle {
            return @truncate(tagged);
        }

        fn unpackTag(tagged: u64) u32 {
            return @truncate(tagged >> 32);
        }
    };
}
