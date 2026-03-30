//! Stack-Allocated Ring Buffer for HFT
//!
//! Eliminates heap indirection by embedding the buffer directly in the struct.
//! The buffer offset is constant-folded by the compiler, removing a pointer load.

use std::cell::UnsafeCell;
use std::mem::MaybeUninit;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

// Prefetch intrinsics - kept for potential use in batched operations
#[allow(unused_imports)]
use crate::atomics::{prefetch_read, prefetch_write};

/// A stack-allocated SPSC ring buffer with embedded storage.
///
/// Unlike `Ring<T>` which uses a heap-allocated buffer via `buffer_ptr`,
/// `StackRing` embeds the buffer directly, making `buffer[idx]` a simple
/// base+offset calculation that the compiler can constant-fold.
#[repr(C)]
pub struct StackRing<T, const N: usize> {
    // === Producer hot path (cache line 1) ===
    tail: AtomicU64,
    cached_head: UnsafeCell<u64>,

    // === Consumer hot path (cache line 2) ===
    head: CacheLinePadded<AtomicU64>,
    cached_tail: UnsafeCell<u64>,

    // === Cold state ===
    closed: AtomicBool,

    // === Buffer (inline, no pointer indirection) ===
    buffer: [UnsafeCell<MaybeUninit<T>>; N],
}

/// Wrapper to force cache line alignment
#[repr(C)]
#[repr(align(128))]
struct CacheLinePadded<T>(T);

impl<T> std::ops::Deref for CacheLinePadded<T> {
    type Target = T;
    #[inline(always)]
    fn deref(&self) -> &T {
        &self.0
    }
}

unsafe impl<T: Send, const N: usize> Send for StackRing<T, N> {}
unsafe impl<T: Send, const N: usize> Sync for StackRing<T, N> {}

impl<T, const N: usize> StackRing<T, N> {
    /// Mask for wrapping indices (N must be power of 2)
    const MASK: usize = N - 1;

    /// Create a new stack-allocated ring.
    ///
    /// # Panics
    /// Panics if N is not a power of 2.
    pub const fn new() -> Self {
        // Compile-time check that N is power of 2
        assert!(N > 0 && (N & (N - 1)) == 0, "N must be a power of 2");

        Self {
            tail: AtomicU64::new(0),
            cached_head: UnsafeCell::new(0),
            head: CacheLinePadded(AtomicU64::new(0)),
            cached_tail: UnsafeCell::new(0),
            closed: AtomicBool::new(false),
            // SAFETY: MaybeUninit doesn't require initialization
            buffer: unsafe { MaybeUninit::uninit().assume_init() },
        }
    }

    /// Reserve space for writing n elements.
    /// Returns a pointer to the start of the reserved region and its length.
    /// Note: Software prefetch is intentionally disabled as A/B testing showed
    /// the hardware prefetcher handles sequential access patterns better on
    /// modern AMD Zen 4 cores.
    #[inline(always)]
    pub unsafe fn reserve(&self, n: usize) -> Option<(*mut T, usize)> {
        let tail = self.tail.load(Ordering::Relaxed);

        let cached_head_ptr = self.cached_head.get();
        let mut head = *cached_head_ptr;

        let used = tail.wrapping_sub(head);
        let mut free = (N as u64).wrapping_sub(used);

        if free < (n as u64) {
            head = self.head.load(Ordering::Acquire);
            *cached_head_ptr = head;
            let used = tail.wrapping_sub(head);
            free = (N as u64).wrapping_sub(used);

            if free < (n as u64) {
                return None;
            }
        }

        let idx = (tail as usize) & Self::MASK;
        let contiguous = n.min(N - idx);

        let ptr = (*self.buffer.as_ptr().add(idx)).get() as *mut T;
        Some((ptr, contiguous))
    }

    /// Commit n elements that were written.
    #[inline(always)]
    pub fn commit(&self, n: usize) {
        let tail = self.tail.load(Ordering::Relaxed);
        self.tail
            .store(tail.wrapping_add(n as u64), Ordering::Release);
    }

    /// Peek at available data for reading.
    /// Returns a pointer to readable data and its length.
    #[inline(always)]
    pub unsafe fn peek(&self) -> (*const T, usize) {
        let head = self.head.load(Ordering::Relaxed);

        let cached_tail_ptr = self.cached_tail.get();
        let mut tail = *cached_tail_ptr;

        if head == tail {
            tail = self.tail.load(Ordering::Acquire);
            *cached_tail_ptr = tail;
            if head == tail {
                return (std::ptr::null(), 0);
            }
        }

        let idx = (head as usize) & Self::MASK;
        let avail = tail.wrapping_sub(head) as usize;
        let contiguous = avail.min(N - idx);

        let ptr = (*self.buffer.as_ptr().add(idx)).get() as *const T;
        (ptr, contiguous)
    }

    /// Consume all available items in batch.
    /// This amortizes the cost of the atomic head update.
    #[inline(always)]
    pub unsafe fn consume_batch<F>(&self, mut handler: F) -> usize
    where
        F: FnMut(&T),
    {
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Acquire);

        let avail = tail.wrapping_sub(head);
        if avail == 0 {
            return 0;
        }

        let mut pos = head;
        while pos != tail {
            let idx = (pos as usize) & Self::MASK;
            let ptr = (*self.buffer.as_ptr().add(idx)).get() as *const T;
            handler(&*ptr);
            pos = pos.wrapping_add(1);
        }

        self.head.store(pos, Ordering::Release);
        // Update cached tail since we have a fresh value
        *self.cached_tail.get() = tail;

        avail as usize
    }

    /// Advance the read pointer by n elements.
    #[inline(always)]
    pub fn advance(&self, n: usize) {
        let head = self.head.load(Ordering::Relaxed);
        self.head
            .store(head.wrapping_add(n as u64), Ordering::Release);
    }

    /// Check if the ring is closed.
    #[inline(always)]
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    /// Check if the ring is empty.
    #[inline(always)]
    pub fn is_empty(&self) -> bool {
        self.tail.load(Ordering::Relaxed) == self.head.load(Ordering::Relaxed)
    }

    /// Close the ring (signals consumers).
    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
    }
}

impl<T, const N: usize> Default for StackRing<T, N> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new() {
        let ring: StackRing<u64, 64> = StackRing::new();
        assert!(ring.is_empty());
        assert!(!ring.is_closed());
    }

    #[test]
    fn test_reserve_commit_peek_advance() {
        let ring: StackRing<u32, 64> = StackRing::new();

        unsafe {
            // Reserve and write
            let (ptr, len) = ring.reserve(1).unwrap();
            assert_eq!(len, 1);
            *ptr = 42;
            ring.commit(1);

            // Peek and read
            let (ptr, len) = ring.peek();
            assert_eq!(len, 1);
            assert_eq!(*ptr, 42);
            ring.advance(1);

            // Should be empty
            assert!(ring.is_empty());
        }
    }

    #[test]
    fn test_full_ring() {
        let ring: StackRing<u32, 4> = StackRing::new();

        unsafe {
            // Fill the ring
            for i in 0..4 {
                let (ptr, _) = ring.reserve(1).unwrap();
                *ptr = i;
                ring.commit(1);
            }

            // Should be full now
            assert!(ring.reserve(1).is_none());

            // Drain one
            let (ptr, _) = ring.peek();
            assert_eq!(*ptr, 0);
            ring.advance(1);

            // Now we can write again
            assert!(ring.reserve(1).is_some());
        }
    }
}
