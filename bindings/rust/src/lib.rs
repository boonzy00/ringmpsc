use std::alloc::{alloc, dealloc, Layout};
use std::cell::UnsafeCell;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

pub mod atomics;
pub mod raw_arc;
pub mod stack_ring;

use atomics::{prefetch_ahead, prefetch_ahead_write};
use raw_arc::RawArc;

pub const DEFAULT_RING_BITS: u8 = 16;
pub const DEFAULT_MAX_PRODUCERS: usize = 16;

pub struct Config {
    pub ring_bits: u8,
    pub max_producers: usize,
    pub enable_metrics: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            ring_bits: DEFAULT_RING_BITS,
            max_producers: DEFAULT_MAX_PRODUCERS,
            enable_metrics: false,
        }
    }
}

pub struct Reservation {
    pub ptr: *mut u8,
    pub len: usize,
}

#[repr(C)]
#[repr(align(128))]
struct ProducerHot {
    tail: AtomicU64,
    cached_head: UnsafeCell<u64>,
}

#[repr(C)]
#[repr(align(128))]
struct ConsumerHot {
    head: AtomicU64,
    cached_tail: UnsafeCell<u64>,
}

#[repr(C)]
#[repr(align(128))]
pub struct Ring<T> {
    producer: ProducerHot,
    consumer: ConsumerHot,

    // Cold fields - further separated
    active: AtomicBool,
    closed: AtomicBool,

    capacity: usize,
    mask: usize,

    buffer_ptr: *mut T,
    layout: Layout,
}

unsafe impl<T: Send> Send for Ring<T> {}
unsafe impl<T: Sync> Sync for Ring<T> {}

impl<T: Default> Ring<T> {
    pub fn new(ring_bits: u8) -> Self {
        let capacity = 1 << ring_bits;
        let mask = capacity - 1;

        // Align to 128 bytes for buffer start
        let layout = Layout::array::<T>(capacity)
            .expect("failed layout")
            .align_to(128)
            .expect("failed align");

        let buffer_ptr = unsafe {
            let ptr = alloc(layout) as *mut T;
            if ptr.is_null() {
                std::alloc::handle_alloc_error(layout);
            }
            for i in 0..capacity {
                ptr.add(i).write(T::default());
            }
            ptr
        };

        Self {
            producer: ProducerHot {
                tail: AtomicU64::new(0),
                cached_head: UnsafeCell::new(0),
            },
            consumer: ConsumerHot {
                head: AtomicU64::new(0),
                cached_tail: UnsafeCell::new(0),
            },
            active: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            capacity,
            mask,
            buffer_ptr,
            layout,
        }
    }
}

impl<T> Ring<T> {
    #[inline(always)]
    pub unsafe fn reserve(&self, n: usize) -> Option<Reservation> {
        let tail = self.producer.tail.load(Ordering::Relaxed);

        // UnsafeCell access is generally only safe if we follow the SPSC contract.
        // Producer owns cached_head.
        let cached_head_ptr = self.producer.cached_head.get();
        let mut head = *cached_head_ptr;

        // space = capacity - (tail - head)
        // If tail - head == capacity, full.
        // We use wrapping arithmetic.
        // used = tail - head.
        // free = capacity - used.
        let used = tail.wrapping_sub(head);
        let mut free = (self.capacity as u64).wrapping_sub(used);

        if free < (n as u64) {
            head = self.consumer.head.load(Ordering::Acquire);
            *cached_head_ptr = head;
            let used = tail.wrapping_sub(head);
            free = (self.capacity as u64).wrapping_sub(used);

            if free < (n as u64) {
                return None;
            }
        }

        let idx = (tail as usize) & self.mask;
        let contiguous = n.min(self.capacity - idx);

        // Prefetch next slot to hide memory latency (use write hint for producer)
        prefetch_ahead_write(self.buffer_ptr, (idx + n) & self.mask);

        Some(Reservation {
            ptr: self.buffer_ptr.add(idx) as *mut u8,
            len: contiguous,
        })
    }

    #[inline(always)]
    pub fn commit(&self, n: usize) {
        let tail = self.producer.tail.load(Ordering::Relaxed);
        self.producer
            .tail
            .store(tail.wrapping_add(n as u64), Ordering::Release);
    }

    #[inline(always)]
    pub unsafe fn peek(&self) -> (*const T, usize) {
        let head = self.consumer.head.load(Ordering::Relaxed);
        let cached_tail_ptr = self.consumer.cached_tail.get();
        let mut tail = *cached_tail_ptr;

        if head == tail {
            tail = self.producer.tail.load(Ordering::Acquire);
            *cached_tail_ptr = tail;
            if head == tail {
                return (ptr::null(), 0);
            }
        }

        let idx = (head as usize) & self.mask;
        let avail = tail.wrapping_sub(head) as usize;
        let contiguous = avail.min(self.capacity - idx);

        // Prefetch next read slot to hide memory latency
        prefetch_ahead(self.buffer_ptr, (idx + contiguous) & self.mask);

        (self.buffer_ptr.add(idx), contiguous)
    }

    #[inline(always)]
    pub fn advance(&self, n: usize) {
        let head = self.consumer.head.load(Ordering::Relaxed);
        self.consumer
            .head
            .store(head.wrapping_add(n as u64), Ordering::Release);
    }

    /// Consume all available items in batch.
    #[inline(always)]
    pub unsafe fn consume_batch<F>(&self, mut handler: F) -> usize
    where
        F: FnMut(&T),
    {
        let head = self.consumer.head.load(Ordering::Relaxed);
        let tail = self.producer.tail.load(Ordering::Acquire);

        let avail = tail.wrapping_sub(head);
        if avail == 0 {
            return 0;
        }

        let mut pos = head;
        while pos != tail {
            let idx = (pos as usize) & self.mask;
            let ptr = self.buffer_ptr.add(idx);
            handler(&*ptr);
            pos = pos.wrapping_add(1);
        }

        self.consumer.head.store(pos, Ordering::Release);

        // Update cached tail
        *self.consumer.cached_tail.get() = tail;

        avail as usize
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    pub fn is_empty(&self) -> bool {
        self.producer.tail.load(Ordering::Relaxed) == self.consumer.head.load(Ordering::Relaxed)
    }

    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
    }
}

impl<T> Drop for Ring<T> {
    fn drop(&mut self) {
        unsafe {
            dealloc(self.buffer_ptr as *mut u8, self.layout);
        }
    }
}

pub struct Channel<T> {
    rings: Vec<RawArc<Ring<T>>>,
    producer_count: AtomicU64,
    closed: AtomicBool,
    max_producers: usize,
}

pub struct Producer<T> {
    ring: RawArc<Ring<T>>,
    #[allow(dead_code)]
    id: usize,
}

impl<T> Producer<T> {
    #[inline(always)]
    pub unsafe fn reserve(&self, n: usize) -> Option<Reservation> {
        self.ring.reserve(n)
    }
    #[inline(always)]
    pub fn commit(&self, n: usize) {
        self.ring.commit(n)
    }
}

impl<T: Default> Channel<T> {
    pub fn new(config: Config) -> Self {
        let mut rings = Vec::new();
        for _ in 0..config.max_producers {
            rings.push(RawArc::new(Ring::new(config.ring_bits)));
        }
        Self {
            rings,
            producer_count: AtomicU64::new(0),
            closed: AtomicBool::new(false),
            max_producers: config.max_producers,
        }
    }
}

impl<T> Channel<T> {
    pub fn register(&self) -> Result<Producer<T>, &'static str> {
        let id = self.producer_count.fetch_add(1, Ordering::Relaxed);
        if id >= self.max_producers as u64 {
            return Err("TooMany");
        }
        Ok(Producer {
            ring: self.rings[id as usize].clone(),
            id: id as usize,
        })
    }

    pub fn get_ring(&self, id: usize) -> Option<RawArc<Ring<T>>> {
        self.rings.get(id).map(|r| r.clone())
    }

    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
        for r in &self.rings {
            r.close();
        }
    }
}
