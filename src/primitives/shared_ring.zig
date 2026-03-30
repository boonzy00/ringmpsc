//! SharedRing — Cross-process SPSC ring buffer via mmap'd shared memory.
//!
//! Enables lock-free message passing between separate processes using
//! memfd_create + MAP_SHARED. Atomics on MAP_SHARED memory are safe on
//! x86/ARM because cache coherence operates at the physical page level.
//!
//! Architecture:
//!   Process A (creator):  memfd_create → ftruncate → mmap → init header
//!                         Pass fd to Process B via Unix socket (SCM_RIGHTS)
//!   Process B (attacher): receive fd → mmap → verify magic → use ring
//!
//! The ring uses extern struct for deterministic layout across compilations.
//! All pointers are stored as offsets from the base — position-independent.
//!
//! Crash recovery: If the producer dies between reserve and commit, the
//! tail never advances and the consumer never sees incomplete data. The
//! consumer detects producer death via the heartbeat timestamp.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Magic number for shared ring validation: "RNGSHRD\0"
const MAGIC: u64 = 0x0044524853474E52;
const VERSION: u32 = 1;

/// Shared ring header — extern struct for deterministic cross-process layout.
/// Total header size: 512 bytes (4 cache-line-isolated sections).
pub const SharedRingHeader = extern struct {
    // ── Section 0: Identification (128 bytes) ──
    magic: u64 align(128) = MAGIC,
    version: u32 = VERSION,
    ring_bits: u32 = 0,
    capacity: u64 = 0,
    capacity_mask: u64 = 0,
    slot_size: u32 = 0,
    header_size: u32 = @sizeOf(SharedRingHeader),
    total_size: u64 = 0,
    creator_pid: u32 = 0,
    generation: u32 = 0,
    _pad0: [64]u8 = [_]u8{0} ** 64, // Pad to 128-byte cache line boundary

    // ── Section 1: Producer hot line (128 bytes) ──
    tail: std.atomic.Value(u64) align(128) = std.atomic.Value(u64).init(0),
    cached_head: u64 = 0,
    heartbeat_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad1: [104]u8 = [_]u8{0} ** 104, // Pad to 128-byte cache line boundary

    // ── Section 2: Consumer hot line (128 bytes) ──
    head: std.atomic.Value(u64) align(128) = std.atomic.Value(u64).init(0),
    cached_tail: u64 = 0,
    _pad2: [112]u8 = [_]u8{0} ** 112, // Pad to 128-byte cache line boundary

    // ── Section 3: Wake coordination (128 bytes) ──
    consumer_waiters: std.atomic.Value(u32) align(128) = std.atomic.Value(u32).init(0),
    producer_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    closed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    _pad3: [116]u8 = [_]u8{0} ** 116, // Pad to 128-byte cache line boundary
};

comptime {
    // Verify header is exactly 512 bytes for predictable buffer offset
    if (@sizeOf(SharedRingHeader) != 512) {
        @compileError("SharedRingHeader must be exactly 512 bytes");
    }
}

/// A shared SPSC ring buffer backed by mmap'd memory.
/// Can be used within a single process or shared across processes
/// via fd passing (SCM_RIGHTS over Unix socket).
pub fn SharedRing(comptime T: type) type {
    return struct {
        const Self = @This();

        header: *SharedRingHeader,
        buffer: [*]T,
        capacity: usize,
        capacity_mask: usize,
        fd: posix.fd_t,
        mapped: []align(std.heap.page_size_min) u8,
        is_creator: bool,

        /// Create a new shared ring buffer.
        /// Returns the ring and a file descriptor that can be passed
        /// to another process via Unix socket (SCM_RIGHTS).
        pub fn create(ring_bits: u6) !Self {
            const capacity: usize = @as(usize, 1) << ring_bits;
            const buffer_size = capacity * @sizeOf(T);
            const total_size = @sizeOf(SharedRingHeader) + buffer_size;

            // Round up to page size
            const page_size = std.heap.page_size_min;
            const mapped_size = (total_size + page_size - 1) & ~(page_size - 1);

            // Create anonymous shared memory
            const fd = try memfd_create("ringmpsc_shared");

            // Set size
            posix.ftruncate(fd, @intCast(mapped_size)) catch |err| {
                posix.close(fd);
                return err;
            };

            // Map with MAP_SHARED
            const ptr = posix.mmap(
                null,
                mapped_size,
                linux.PROT.READ | linux.PROT.WRITE,
                .{ .TYPE = .SHARED, .POPULATE = true },
                fd,
                0,
            ) catch |err| {
                posix.close(fd);
                return err;
            };

            // Initialize header
            const header: *SharedRingHeader = @ptrCast(@alignCast(ptr.ptr));
            header.* = .{};
            header.ring_bits = ring_bits;
            header.capacity = capacity;
            header.capacity_mask = capacity - 1;
            header.slot_size = @sizeOf(T);
            header.total_size = mapped_size;
            header.creator_pid = @intCast(linux.getpid());
            header.generation = 1;
            // Initialize heartbeat so isProducerAlive works before first commit
            const now_raw = std.time.nanoTimestamp();
            header.heartbeat_ns.store(if (now_raw > 0) @intCast(now_raw) else 1, .release);

            // Buffer starts after header
            const buffer: [*]T = @ptrCast(@alignCast(ptr.ptr + @sizeOf(SharedRingHeader)));

            return .{
                .header = header,
                .buffer = buffer,
                .capacity = capacity,
                .capacity_mask = capacity - 1,
                .fd = fd,
                .mapped = ptr,
                .is_creator = true,
            };
        }

        /// Attach to an existing shared ring buffer using a file descriptor
        /// received from another process (via SCM_RIGHTS or fork).
        pub fn attach(fd: posix.fd_t) !Self {
            // First, map just the header to read metadata
            const header_map = try posix.mmap(
                null,
                @sizeOf(SharedRingHeader),
                linux.PROT.READ | linux.PROT.WRITE,
                .{ .TYPE = .SHARED },
                fd,
                0,
            );

            const header: *SharedRingHeader = @ptrCast(@alignCast(header_map.ptr));

            // Validate
            if (header.magic != MAGIC) {
                posix.munmap(header_map);
                return error.InvalidMagic;
            }
            if (header.version != VERSION) {
                posix.munmap(header_map);
                return error.VersionMismatch;
            }
            if (header.slot_size != @sizeOf(T)) {
                posix.munmap(header_map);
                return error.SlotSizeMismatch;
            }

            const mapped_size = header.total_size;
            const capacity = header.capacity;
            const capacity_mask = header.capacity_mask;

            // Unmap header-only mapping
            posix.munmap(header_map);

            // Remap full size
            const ptr = try posix.mmap(
                null,
                mapped_size,
                linux.PROT.READ | linux.PROT.WRITE,
                .{ .TYPE = .SHARED },
                fd,
                0,
            );

            const full_header: *SharedRingHeader = @ptrCast(@alignCast(ptr.ptr));
            const buffer: [*]T = @ptrCast(@alignCast(ptr.ptr + @sizeOf(SharedRingHeader)));

            return .{
                .header = full_header,
                .buffer = buffer,
                .capacity = capacity,
                .capacity_mask = capacity_mask,
                .fd = fd,
                .mapped = ptr,
                .is_creator = false,
            };
        }

        pub fn deinit(self: *Self) void {
            posix.munmap(self.mapped);
            if (self.is_creator) {
                posix.close(self.fd);
            }
        }

        /// Get the fd for passing to another process via SCM_RIGHTS.
        pub fn getFd(self: *const Self) posix.fd_t {
            return self.fd;
        }

        // ── Producer API ──

        pub fn reserve(self: *Self, n: usize) ?[]T {
            const h = self.header;
            const tail = h.tail.load(.monotonic);
            var space = self.capacity -| (tail -% h.cached_head);
            if (space < n) {
                h.cached_head = h.head.load(.acquire);
                space = self.capacity -| (tail -% h.cached_head);
                if (space < n) return null;
            }
            const start = tail & self.capacity_mask;
            const contiguous = @min(n, self.capacity - start);
            return self.buffer[start..][0..contiguous];
        }

        pub fn commit(self: *Self, n: usize) void {
            const h = self.header;
            const tail = h.tail.load(.monotonic);
            h.tail.store(tail +% n, .release);

            // Update heartbeat for liveness detection
            h.heartbeat_ns.store(@intCast(std.time.nanoTimestamp()), .monotonic);

            // Cross-process futex wake (FUTEX_WAKE, not FUTEX_WAKE_PRIVATE)
            if (h.consumer_waiters.load(.acquire) > 0) {
                futexWakeShared(&h.consumer_waiters, 1);
            }
        }

        pub fn send(self: *Self, items: []const T) usize {
            const slice = self.reserve(items.len) orelse return 0;
            const n = slice.len;
            @memcpy(slice, items[0..n]);
            self.commit(n);
            return n;
        }

        // ── Consumer API ──

        pub fn readable(self: *Self) ?[]const T {
            const h = self.header;
            const head = h.head.load(.monotonic);
            var avail = h.cached_tail -% head;
            if (avail == 0) {
                h.cached_tail = h.tail.load(.acquire);
                avail = h.cached_tail -% head;
                if (avail == 0) return null;
            }
            const start = head & self.capacity_mask;
            const contiguous = @min(avail, self.capacity - start);
            return self.buffer[start..][0..contiguous];
        }

        pub fn advance(self: *Self, n: usize) void {
            const h = self.header;
            const head = h.head.load(.monotonic);
            h.head.store(head +% n, .release);

            if (h.producer_waiters.load(.acquire) > 0) {
                futexWakeShared(&h.producer_waiters, 1);
            }
        }

        pub fn len(self: *const Self) usize {
            const t = self.header.tail.load(.monotonic);
            const h = self.header.head.load(.monotonic);
            return @intCast(t -% h);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.header.tail.load(.monotonic) == self.header.head.load(.monotonic);
        }

        pub fn close(self: *Self) void {
            self.header.closed.store(1, .release);
        }

        pub fn isClosed(self: *const Self) bool {
            return self.header.closed.load(.acquire) != 0;
        }

        /// Check if the producer process is still alive by inspecting
        /// the heartbeat timestamp. Returns false if heartbeat is older
        /// than timeout_ns nanoseconds.
        /// Check if the producer process is still alive by inspecting
        /// the heartbeat timestamp. Returns false if:
        /// - Heartbeat was never written (producer never committed)
        /// - Heartbeat is older than timeout_ns nanoseconds
        pub fn isProducerAlive(self: *const Self, timeout_ns: u64) bool {
            const last = self.header.heartbeat_ns.load(.acquire);
            if (last == 0) return false; // Never committed — assume dead
            const now_raw = std.time.nanoTimestamp();
            if (now_raw < 0) return false; // Clock error
            const now: u64 = @intCast(now_raw);
            if (now < last) return true; // Clock went backwards — assume alive
            return (now - last) < timeout_ns;
        }
    };
}

// ── Platform helpers ──

fn memfd_create(name: [*:0]const u8) !posix.fd_t {
    const raw = linux.memfd_create(name, linux.MFD.CLOEXEC);
    return switch (posix.errno(raw)) {
        .SUCCESS => @intCast(raw),
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

/// Cross-process futex wake (FUTEX_WAKE, not FUTEX_WAKE_PRIVATE).
/// Uses the global hash table keyed on physical page + offset,
/// enabling wake across processes sharing the same mmap'd page.
fn futexWakeShared(ptr: *const std.atomic.Value(u32), count: u32) void {
    _ = linux.syscall4(
        .futex,
        @intFromPtr(&ptr.raw),
        1, // FUTEX_WAKE (not FUTEX_WAKE_PRIVATE = 0x80 | 1)
        count,
        0,
    );
}
