//! Custom atomic primitives with x86_64 prefetch intrinsics.
//!
//! Provides prefetch hints for the CPU to load data into cache
//! before it's needed, hiding memory latency.

/// Prefetch data for reading into L1 cache.
/// This is a hint to the CPU - it may be ignored.
#[inline(always)]
#[cfg(target_arch = "x86_64")]
pub unsafe fn prefetch_read<T>(ptr: *const T) {
    use core::arch::x86_64::{_mm_prefetch, _MM_HINT_T0};
    _mm_prefetch(ptr as *const i8, _MM_HINT_T0);
}

/// Prefetch data for reading into L1 cache (no-op on non-x86_64).
#[inline(always)]
#[cfg(not(target_arch = "x86_64"))]
pub unsafe fn prefetch_read<T>(_ptr: *const T) {
    // No-op on non-x86_64 platforms
}

/// Prefetch data for writing into L1 cache with exclusive ownership.
/// Uses PREFETCHW instruction which brings line into Modified/Exclusive state,
/// avoiding the RFO (Read-For-Ownership) penalty on subsequent writes.
#[inline(always)]
#[cfg(target_arch = "x86_64")]
pub unsafe fn prefetch_write<T>(ptr: *mut T) {
    use core::arch::x86_64::{_mm_prefetch, _MM_HINT_ET0};
    // ET0 = Exclusive hint for T0, generates PREFETCHW instruction
    // This brings the cache line into M/E state (exclusive ownership)
    _mm_prefetch(ptr as *const i8, _MM_HINT_ET0);
}

/// Prefetch data for writing into L1 cache (no-op on non-x86_64).
#[inline(always)]
#[cfg(not(target_arch = "x86_64"))]
pub unsafe fn prefetch_write<T>(_ptr: *mut T) {
    // No-op on non-x86_64 platforms
}

/// Prefetch multiple cache lines ahead for reading.
/// Useful for sequential access patterns like ring buffers.
#[inline(always)]
pub unsafe fn prefetch_ahead<T>(base: *const T, slots_ahead: usize) {
    let ptr = base.add(slots_ahead);
    prefetch_read(ptr);
}

/// Prefetch multiple cache lines ahead for writing with exclusive ownership.
/// Useful for producer paths in ring buffers.
#[inline(always)]
pub unsafe fn prefetch_ahead_write<T>(base: *mut T, slots_ahead: usize) {
    let ptr = base.add(slots_ahead);
    prefetch_write(ptr);
}

/// Compiler memory barrier hint (stronger than necessary but ensures ordering).
#[inline(always)]
pub fn compiler_fence_acquire() {
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::Acquire);
}

/// Compiler memory barrier hint.
#[inline(always)]
pub fn compiler_fence_release() {
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::Release);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_prefetch_compiles() {
        let data: [u64; 4] = [1, 2, 3, 4];
        unsafe {
            prefetch_read(data.as_ptr());
            prefetch_ahead(data.as_ptr(), 2);
        }
    }
}
