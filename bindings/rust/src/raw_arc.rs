//! Custom "Thin" Arc optimized for HFT ring buffer use case.
//!
//! Key differences from std::sync::Arc:
//! - Single indirection: RawArc<T> -> T (no ArcInner wrapper)
//! - No Weak support (unused in this codebase)
//! - 128-byte aligned allocation for cache-friendliness
//! - Intrusive ref-counting embedded in allocation

use std::alloc::{alloc, dealloc, Layout};
use std::marker::PhantomData;
use std::ops::Deref;
use std::ptr::NonNull;
use std::sync::atomic::{AtomicUsize, Ordering};

/// The inner allocation containing refcount and data.
/// Using repr(C) ensures predictable layout: refcount first, then data.
#[repr(C)]
#[repr(align(128))]
struct RawArcInner<T> {
    refcount: AtomicUsize,
    data: T,
}

/// A thin, single-indirection Arc optimized for HFT.
///
/// Unlike std::sync::Arc which has:
///   Ptr -> ArcInner { strong, weak, data: T }
///
/// RawArc has:
///   Ptr -> RawArcInner { refcount, data: T }
///
/// This eliminates one level of pointer chasing on the hot path.
pub struct RawArc<T> {
    ptr: NonNull<RawArcInner<T>>,
    _marker: PhantomData<RawArcInner<T>>,
}

unsafe impl<T: Send + Sync> Send for RawArc<T> {}
unsafe impl<T: Send + Sync> Sync for RawArc<T> {}

impl<T> RawArc<T> {
    /// Create a new RawArc with the given value.
    pub fn new(data: T) -> Self {
        let layout = Layout::new::<RawArcInner<T>>();

        unsafe {
            let ptr = alloc(layout) as *mut RawArcInner<T>;
            if ptr.is_null() {
                std::alloc::handle_alloc_error(layout);
            }

            // Initialize the inner structure
            ptr.write(RawArcInner {
                refcount: AtomicUsize::new(1),
                data,
            });

            RawArc {
                ptr: NonNull::new_unchecked(ptr),
                _marker: PhantomData,
            }
        }
    }

    /// Get a raw pointer to the inner data.
    /// This is useful for performance-critical code that needs direct access.
    #[inline(always)]
    pub fn as_ptr(&self) -> *const T {
        unsafe { &(*self.ptr.as_ptr()).data as *const T }
    }

    /// Get a mutable raw pointer to the inner data.
    /// SAFETY: Caller must ensure exclusive access.
    #[inline(always)]
    pub fn as_mut_ptr(&self) -> *mut T {
        unsafe { &mut (*self.ptr.as_ptr()).data as *mut T }
    }

    /// Get the current reference count.
    #[inline]
    pub fn ref_count(&self) -> usize {
        unsafe { (*self.ptr.as_ptr()).refcount.load(Ordering::Relaxed) }
    }
}

impl<T> Clone for RawArc<T> {
    #[inline]
    fn clone(&self) -> Self {
        // Increment refcount with Relaxed ordering.
        // This is safe because:
        // - We already have a valid reference (self)
        // - Any thread that decrements will use Release
        // - Any thread that needs to observe the decrement will use Acquire
        unsafe {
            let old = (*self.ptr.as_ptr())
                .refcount
                .fetch_add(1, Ordering::Relaxed);

            // Overflow check (same as std::sync::Arc)
            if old > isize::MAX as usize {
                std::process::abort();
            }
        }

        RawArc {
            ptr: self.ptr,
            _marker: PhantomData,
        }
    }
}

impl<T> Deref for RawArc<T> {
    type Target = T;

    #[inline(always)]
    fn deref(&self) -> &Self::Target {
        unsafe { &(*self.ptr.as_ptr()).data }
    }
}

impl<T> Drop for RawArc<T> {
    fn drop(&mut self) {
        unsafe {
            // Decrement with Release ordering to ensure all writes are visible
            // before potential deallocation.
            if (*self.ptr.as_ptr())
                .refcount
                .fetch_sub(1, Ordering::Release)
                != 1
            {
                return;
            }

            // Acquire fence to ensure we see all writes from other threads
            // before we deallocate.
            std::sync::atomic::fence(Ordering::Acquire);

            // Drop the inner value and deallocate
            let layout = Layout::new::<RawArcInner<T>>();
            std::ptr::drop_in_place(self.ptr.as_ptr());
            dealloc(self.ptr.as_ptr() as *mut u8, layout);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_usage() {
        let arc = RawArc::new(42u64);
        assert_eq!(*arc, 42);
        assert_eq!(arc.ref_count(), 1);
    }

    #[test]
    fn test_clone() {
        let arc1 = RawArc::new(42u64);
        let arc2 = arc1.clone();
        assert_eq!(*arc1, 42);
        assert_eq!(*arc2, 42);
        assert_eq!(arc1.ref_count(), 2);
        drop(arc2);
        assert_eq!(arc1.ref_count(), 1);
    }

    #[test]
    fn test_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<RawArc<u64>>();
    }
}
