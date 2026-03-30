// ringmpsc SIMD Optimizations
//
// SIMD-accelerated operations for high-performance ring buffers.
// Provides drop-in replacements for memcpy and other operations.

const std = @import("std");
const builtin = @import("builtin");

// Preferred SIMD element type - follows Zig standard library pattern
const PreferredElement = element: {
    if (std.simd.suggestVectorLength(u8)) |vec_size| {
        const Vec = @Vector(vec_size, u8);
        if (@sizeOf(Vec) == vec_size and std.math.isPowerOfTwo(vec_size)) {
            break :element Vec;
        }
    }
    break :element usize;
};

// SIMD-accelerated memory copy optimized for ring buffer operations
pub inline fn ringMemcpy(noalias dst: [*]u8, noalias src: [*]const u8, len: usize) void {
    // Use standard library approach with PreferredElement
    const vec_size = @sizeOf(PreferredElement);

    if (len < vec_size * 4) {
        // Too small for SIMD overhead, use scalar
        @memcpy(dst[0..len], src[0..len]);
        return;
    }

    // Handle unaligned prefix
    const alignment_offset = @intFromPtr(src) % vec_size;
    if (alignment_offset != 0) {
        const prefix_len = @min(vec_size - alignment_offset, len);
        @memcpy(dst[0..prefix_len], src[0..prefix_len]);
        if (prefix_len >= len) return;

        const dst_adj = dst + prefix_len;
        const src_adj = src + prefix_len;
        const remaining = len - prefix_len;

        // Main SIMD loop for aligned data
        copyBlocksAligned(@ptrCast(@alignCast(dst_adj)), @ptrCast(@alignCast(src_adj)), remaining);
        return;
    }

    // Source is aligned, use optimized path
    copyBlocksAligned(@ptrCast(@alignCast(dst)), @ptrCast(@alignCast(src)), len);
}

// SIMD-accelerated copy for u64 slices (ring buffer data)
pub inline fn ringMemcpyU64(noalias dst: [*]u64, noalias src: [*]const u64, count: usize) void {
    // For u64, we can use AVX2/AVX-512 vectors
    const vec_len = std.simd.suggestVectorLength(u64) orelse 4; // AVX2: 4 u64s = 256 bits
    const VecU64 = @Vector(vec_len, u64);

    if (count < vec_len * 2) {
        // Too small for SIMD, use scalar
        @memcpy(@as([*]u8, @ptrCast(dst))[0..count * 8], @as([*]const u8, @ptrCast(src))[0..count * 8]);
        return;
    }

    // Handle unaligned prefix (if any)
    const dst_ptr = @intFromPtr(dst);
    const src_ptr = @intFromPtr(src);
    const alignment_offset = @min(dst_ptr, src_ptr) % @sizeOf(VecU64);

    if (alignment_offset != 0) {
        // Handle unaligned case
        const prefix_count = @min(vec_len - (alignment_offset / @sizeOf(u64)), count);
        @memcpy(@as([*]u8, @ptrCast(dst))[0..prefix_count * 8], @as([*]const u8, @ptrCast(src))[0..prefix_count * 8]);

        if (prefix_count >= count) return;

        const dst_adj = dst + prefix_count;
        const src_adj = src + prefix_count;
        const remaining = count - prefix_count;

        copyBlocksU64Aligned(@ptrCast(@alignCast(dst_adj)), @ptrCast(@alignCast(src_adj)), remaining);
        return;
    }

    // Fully aligned SIMD copy
    copyBlocksU64Aligned(@ptrCast(@alignCast(dst)), @ptrCast(@alignCast(src)), count);
}

// SIMD copy for aligned u64 data
inline fn copyBlocksU64Aligned(noalias dst: [*]align(1) @Vector(std.simd.suggestVectorLength(u64) orelse 4, u64), noalias src: [*]const @Vector(std.simd.suggestVectorLength(u64) orelse 4, u64), max_count: usize) void {
    const vec_len = std.simd.suggestVectorLength(u64) orelse 4;

    const loop_count = max_count / vec_len;
    for (dst[0..loop_count], src[0..loop_count]) |*d, s| {
        d.* = s;
    }

    // Handle remainder
    const bytes_copied = loop_count * vec_len * @sizeOf(u64);
    const total_bytes = max_count * @sizeOf(u64);
    if (bytes_copied < total_bytes) {
        const remainder_bytes = total_bytes - bytes_copied;
        const dst_u8 = @as([*]u8, @ptrCast(dst)) + bytes_copied;
        const src_u8 = @as([*]const u8, @ptrCast(src)) + bytes_copied;
        @memcpy(dst_u8[0..remainder_bytes], src_u8[0..remainder_bytes]);
    }
}

// Copy blocks using SIMD vectors (aligned)
inline fn copyBlocksAligned(noalias dst: [*]align(1) PreferredElement, noalias src: [*]const PreferredElement, max_bytes: usize) void {
    const loop_count = max_bytes / @sizeOf(PreferredElement);
    for (dst[0..loop_count], src[0..loop_count]) |*d, s| {
        d.* = s;
    }

    // Handle remainder
    const bytes_copied = loop_count * @sizeOf(PreferredElement);
    if (bytes_copied < max_bytes) {
        const remainder = max_bytes - bytes_copied;
        const dst_u8 = @as([*]u8, @ptrCast(dst)) + bytes_copied;
        const src_u8 = @as([*]const u8, @ptrCast(src)) + bytes_copied;
        @memcpy(dst_u8[0..remainder], src_u8[0..remainder]);
    }
}

// SIMD-accelerated copy for typed slices
pub inline fn ringMemcpyTyped(comptime T: type, dst: []T, src: []const T) void {
    const dst_bytes = std.mem.sliceAsBytes(dst);
    const src_bytes = std.mem.sliceAsBytes(src);
    const len = @min(dst_bytes.len, src_bytes.len);
    ringMemcpy(dst_bytes.ptr, src_bytes.ptr, len);
}

// SIMD-accelerated ring buffer initialization (zeroing)
pub inline fn ringMemset(noalias dst: [*]u8, value: u8, len: usize) void {
    const vec_size = @sizeOf(PreferredElement);

    if (len < vec_size * 4) {
        @memset(dst[0..len], value);
        return;
    }

    // Create SIMD vector filled with value
    const fill_vec: PreferredElement = @splat(value);

    var i: usize = 0;
    // Main SIMD loop - handle unaligned access
    while (i + vec_size <= len) : (i += vec_size) {
        @as(*align(1) PreferredElement, @ptrCast(&dst[i])).* = fill_vec;
    }

    // Handle remainder
    if (i < len) {
        @memset(dst[i..len], value);
    }
}

// SIMD-accelerated data generation for ring buffer producers
pub inline fn ringFillSequentialU64(noalias dst: [*]u64, start_value: u64, count: usize) void {
    const vec_len = std.simd.suggestVectorLength(u64) orelse 4;
    const VecU64 = @Vector(vec_len, u64);

    if (count < vec_len * 2) {
        // Too small for SIMD, use scalar
        for (0..count) |i| {
            dst[i] = start_value + i;
        }
        return;
    }

    // Generate base vector
    const base_vec: VecU64 = switch (vec_len) {
        2 => .{ start_value, start_value + 1 },
        4 => .{ start_value, start_value + 1, start_value + 2, start_value + 3 },
        8 => .{ start_value, start_value + 1, start_value + 2, start_value + 3,
                start_value + 4, start_value + 5, start_value + 6, start_value + 7 },
        else => @splat(start_value), // Fallback
    };

    const loop_count = count / vec_len;
    for (0..loop_count) |i| {
        const offset_vec: VecU64 = @splat(@as(u64, i * vec_len));
        @as(*align(1) VecU64, @ptrCast(&dst[i * vec_len])).* = base_vec + offset_vec;
    }

    // Handle remainder
    const remainder_start = loop_count * vec_len;
    for (remainder_start..count) |i| {
        dst[i] = start_value + i;
    }
}
pub inline fn ringZero(noalias dst: [*]u8, len: usize) void {
    ringMemset(dst, 0, len);
}

// SIMD feature detection with runtime CPU detection
pub const SimdFeatures = struct {
    has_avx2: bool,
    has_avx512: bool,
    vector_size_u8: usize,
    vector_size_u32: usize,
    vector_size_f32: usize,

    pub fn detect() SimdFeatures {
        var features = SimdFeatures{
            .has_avx2 = false,
            .has_avx512 = false,
            .vector_size_u8 = std.simd.suggestVectorLength(u8) orelse 16,
            .vector_size_u32 = std.simd.suggestVectorLength(u32) orelse 4,
            .vector_size_f32 = std.simd.suggestVectorLength(f32) orelse 4,
        };

        // Runtime CPU feature detection
        const cpu_features = builtin.target.cpu.features;

        // Check for AVX-512 support
        if (builtin.target.cpu.arch == .x86_64 and cpu_features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx512f))) {
            features.has_avx512 = true;
            // AVX-512 can handle 512-bit vectors (64 bytes for u8)
            features.vector_size_u8 = @max(features.vector_size_u8, 64);
        }

        // Check for AVX2 support
        if (builtin.target.cpu.arch == .x86_64 and cpu_features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2))) {
            features.has_avx2 = true;
            // AVX2 can handle 256-bit vectors (32 bytes for u8)
            features.vector_size_u8 = @max(features.vector_size_u8, 32);
        }

        return features;
    }
};

// Get optimal SIMD vector size for a type at runtime
pub inline fn getOptimalVectorSize(comptime T: type) usize {
    return std.simd.suggestVectorLength(T) orelse @sizeOf(T);
}

// Check if SIMD is beneficial for a given size
pub inline fn shouldUseSimd(len: usize, comptime element_size: usize) bool {
    const vec_size = std.simd.suggestVectorLength(u8) orelse 16;
    const min_simd_len = vec_size * 4; // 4 vectors minimum for SIMD overhead
    return len * element_size >= min_simd_len;
}

// Advanced prefetching with SIMD awareness
pub inline fn prefetchSimd(noalias ptr: *const anyopaque, comptime rw: enum { read, write }) void {
    // Prefetch multiple cache lines for SIMD operations
    const cache_line_size = 64;
    const ptr_u8 = @as([*]const u8, @ptrCast(ptr));

    // Prefetch current cache line
    @prefetch(ptr_u8, .{ .rw = if (rw == .read) .read else .write, .locality = 3, .cache = .data });

    // Prefetch next cache line (for SIMD operations that span lines)
    @prefetch(ptr_u8 + cache_line_size, .{ .rw = if (rw == .read) .read else .write, .locality = 2, .cache = .data });
}

// SIMD-accelerated batch processing for ring buffers
pub inline fn processBatch(comptime T: type, items: []T, start_idx: usize, count: usize, comptime processFn: fn (*T) void) void {
    if (count == 0) return;

    // For small batches, use scalar processing
    if (count < 8) {
        for (0..count) |i| {
            processFn(&items[start_idx + i]);
        }
        return;
    }

    // For larger batches, use SIMD-aware processing
    const vec_size = std.simd.suggestVectorLength(T) orelse 4;
    const vec_count = count / vec_size;

    // Process vector-sized chunks
    var i: usize = 0;
    while (i < vec_count * vec_size) : (i += vec_size) {
        // Prefetch next chunk
        if (i + vec_size + vec_size < count) {
            @prefetch(&items[start_idx + i + vec_size], .{ .rw = .read, .locality = 2, .cache = .data });
        }

        // Process current chunk
        inline for (0..vec_size) |j| {
            processFn(&items[start_idx + i + j]);
        }
    }

    // Handle remainder
    const remainder_start = vec_count * vec_size;
    for (remainder_start..count) |j| {
        processFn(&items[start_idx + j]);
    }
}
