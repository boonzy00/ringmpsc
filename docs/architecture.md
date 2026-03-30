# Architecture

## Design Philosophy

RingMPSC decomposes the MPSC problem into N independent SPSC problems. Instead of producers contending on a shared tail pointer, each producer gets a dedicated ring buffer. The consumer polls all rings. This trades memory for throughput — an acceptable tradeoff given modern memory capacities.

## Type Hierarchy

```
primitives.Ring(T, Config)          ← The core. Everything builds on this.
    │
    ├── spsc.Channel(T, Config)     ← Type alias for Ring. Zero overhead.
    │
    ├── mpsc.Channel(T, Config)     ← Array of *Ring (heap-allocated).
    │   ├── Producer                   Producer handle (ring pointer + id).
    │   └── ProducerExt                Extended producer with blocking send.
    │
    ├── spmc.Channel(T, SpmcConfig) ← Single ring, CAS-based head.
    │   └── Consumer                   CAS-based consumer handle.
    │
    └── mpmc.MpmcChannel(T, MpmcConfig) ← Array of MpmcRing (inline).
        ├── MpmcRing                   Ring with CAS head + hotness tracking.
        ├── Producer                   Producer handle.
        └── Consumer                   3-phase work-stealing consumer.

EventLoop(T, ChannelType)              ← Thin managed consumer loop.
    Wraps any channel's consumeAll + drainAll in a spawnable thread.

primitives.EventNotifier               ← eventfd wrapper for epoll/io_uring.
    Attaches to any Ring via setEventNotifier(). commit() auto-signals.
    Consumer sleeps in epoll_wait with zero CPU, wakes on data.

primitives.BufferPool(slab_size, n)    ← Lock-free slab allocator.
    Pre-allocated contiguous memory, CAS-based free list with ABA tag.
    Used with Ring(Handle) for zero-copy large message passing.
    Ownership transfers through the ring — no hazard pointers needed.

primitives.SharedRing(T)               ← Cross-process SPSC ring.
    memfd_create + MAP_SHARED. extern struct header (512 bytes).
    Pass fd via SCM_RIGHTS. Atomics safe on MAP_SHARED (cache coherent).
    Heartbeat for crash detection. Auto-cleanup on fd close.
```

## Ring Buffer Memory Layout

The Ring struct uses 128-byte alignment to isolate producer and consumer cache lines.

### Why 128 Bytes, Not 64?

x86 processors use 64-byte cache lines. Naively, separating variables by 64 bytes should prevent false sharing. However, modern Intel and AMD CPUs have **spatial prefetchers** that detect sequential access patterns and fetch the *next adjacent* cache line automatically:

```
Memory:   [line A: 64 bytes] [line B: 64 bytes] [line C: 64 bytes]
                                  ↑
                         CPU reads line B
                                  ↓
Prefetcher:              automatically fetches line C

If tail is at end of line B and head is at start of line C:
  Producer writes tail → invalidates line B
  Prefetcher pulls line C into producer's cache → now producer has head's line
  Consumer writes head → must invalidate producer's copy of line C
  Result: false sharing through the prefetcher, even though tail and head
          are on different 64-byte lines
```

With 128-byte separation, there is always a full cache line of padding between producer and consumer data. The prefetcher fetches the padding line, not the other thread's data. AMD Zen 3 and Intel Alder Lake both exhibit this behavior.

**Measured impact**: On Zen 3, switching from 64-byte to 128-byte alignment improves 8P1C batch throughput by ~8-12% due to eliminated cross-core invalidation traffic on the hot path.

```
┌─────────────────────────────────────────────────────────────┐
│ PRODUCER HOT (align 128)                                    │
│   tail: AtomicU64          ← Written by producer only       │
│   cached_head: u64         ← Producer-local (never shared)  │
│   [104 bytes padding]                                       │
├─────────────────────────────────────────────────────────────┤  ← offset 128
│ CONSUMER HOT (align 128)                                    │
│   head: AtomicU64          ← Written by consumer only       │
│   cached_tail: u64         ← Consumer-local (never shared)  │
│   [104 bytes padding]                                       │
├─────────────────────────────────────────────────────────────┤  ← offset 256
│ COLD STATE (align 128)                                      │
│   active: AtomicBool       ← Set once during registration   │
│   closed: AtomicBool       ← Set once during shutdown       │
│   consumer_waiters: AtomicU32  ← Futex wait/wake gating     │
│   producer_waiters: AtomicU32  ← Futex wait/wake gating     │
│   metrics: Metrics|void    ← Optional, compile-time gated   │
│   [padding]                                                 │
├─────────────────────────────────────────────────────────────┤  ← offset 384+
│ DATA BUFFER (align 64)                                      │
│   buffer: [CAPACITY]T      ← Power-of-2 sized               │
│                               Indexed via (pos & MASK)      │
└─────────────────────────────────────────────────────────────┘
```

**Size example** (u64, ring_bits=15): 384 bytes metadata + 32768 × 8 = 256KB data = ~256KB per ring.

## Data Flow

### Zero-Copy Pattern (BufferPool + Ring)

For messages larger than a cache line (64 bytes), the pointer-ring pattern eliminates payload copies:

```
Producer                                    Consumer
────────                                    ────────
handle = pool.alloc()                       handle = ring.recvOne()
buf = pool.getWritable(handle)              payload = pool.get(handle)  ← SAME memory
write payload into buf                      read payload (zero copy)
pool.setLen(handle, len)                    pool.free(handle)
ring.send(&[_]Handle{handle})  ──────────►
         4 bytes through ring
         payload never moves
```

The ring carries `Handle` (u32, 4 bytes) instead of the payload. For 2KB messages, this is a 512x reduction in ring bandwidth. Ownership transfers through the ring — only the current owner (producer before send, consumer after recv) accesses the slab. No hazard pointers or epoch-based reclamation needed.

### Cross-Process (SharedRing)

For IPC between separate processes without Unix sockets or pipes:

```
Process A (creator)                     Process B (attacher)
───────────────────                     ────────────────────
memfd_create("ringmpsc_shared")         receive fd via SCM_RIGHTS
ftruncate(fd, size)                     mmap(MAP_SHARED, fd)
mmap(MAP_SHARED, fd)                    verify magic + version
init header (extern struct)             cast to SharedRingHeader
                                        ↕
              ┌─────────────────────────────────────────┐
              │     Physical memory (memfd-backed)       │
              │  ┌──────────┬───────────────────────┐   │
              │  │ Header   │ Data buffer            │   │
              │  │ (512B)   │ T[capacity]            │   │
              │  │ tail ←P  │                        │   │
              │  │ head ←C  │                        │   │
              │  └──────────┴───────────────────────┘   │
              └─────────────────────────────────────────┘
                        ↕ cache coherence (MESI)
```

Both processes access the same physical pages. Atomics (acquire/release) are safe across MAP_SHARED because cache coherence operates at the physical address level. Cross-process futex uses `FUTEX_WAKE` (global hash table) instead of `FUTEX_WAKE_PRIVATE` (process-local).

**Crash recovery**: If the producer dies between `reserve` and `commit`, the tail never advances — consumer never sees incomplete data. `isProducerAlive(timeout_ns)` checks the heartbeat timestamp for liveness detection.

**Cleanup**: memfd_create memory is automatically freed when all file descriptors are closed. No `shm_unlink` or filesystem cleanup needed.

### SPSC (single ring)

```
Producer                              Consumer
────────                              ────────
reserve(n) → slice into buffer        readable() → slice from buffer
write to slice                        read from slice
commit(n) → tail.store(.release)      advance(n) → head.store(.release)
```

One acquire load per operation on the slow path (when cached value is stale). Zero CAS.

### MPSC (N rings)

```
Producer 0 ──[reserve/commit]──► Ring 0 ──┐
Producer 1 ──[reserve/commit]──► Ring 1 ──┼──► Consumer scans all rings
Producer 2 ──[reserve/commit]──► Ring 2 ──┤    consumeAll() / consumeAllCount()
    ...                                   │
Producer N ──[reserve/commit]──► Ring N ──┘
```

Each producer operates independently. Zero contention between producers. The consumer's `consumeAll` uses **adaptive exponential backoff** to avoid polling consistently-empty rings:

```
for each ring:
    if skip_counter[i] > 0:          ← exponential backoff on empty rings
        skip_phase[i]++
        if skip_phase[i] < skip_counter[i]: continue   ← skip this ring
        skip_phase[i] = 0            ← time to re-check
    if ring.isEmpty():
        skip_counter[i] = min(skip_counter[i] * 2, 64) ← double backoff
        continue
    skip_counter[i] = 0              ← non-empty: reset immediately
    count += ring.consumeBatch()     ← 1 acquire load + 1 release store
```

This reduces consumer polling from O(P) per round to O(active_producers). Polling empty queues wastes cycles without reducing wait time — adaptive backoff eliminates this overhead for inactive producers.

#### Consumer Wake Modes

The consumer can be woken via two mechanisms:

| Mode | Mechanism | CPU Idle | Event Loop | Use When |
|------|-----------|----------|------------|----------|
| **Futex** (default) | `consumer_waiters` + futex | Yes | No | Dedicated consumer thread |
| **EventNotifier** | eventfd + epoll/io_uring | Yes | Yes | Consumer in event loop |

**EventNotifier** (new): Attach via `ring.setEventNotifier(&notifier)`. After this, every `commit()` writes u64(1) to the eventfd, which wakes the consumer in `epoll_wait`. Multiple signals coalesce. The consumer calls `notifier.consume()` to reset the counter, then drains the ring.

```zig
var notifier = try ringmpsc.primitives.EventNotifier.init();
ring.setEventNotifier(&notifier);
try notifier.registerEpoll(epoll_fd);

// In epoll loop:
_ = notifier.consume();  // reset eventfd counter
while (ring.readable()) |slice| { ... }
```

### MPMC (N rings, M consumers)

```
Producer 0 ──► MpmcRing 0 ──┐
Producer 1 ──► MpmcRing 1 ──┼──► Consumer 0 (shard: rings 0-1)
Producer 2 ──► MpmcRing 2 ──┤    Consumer 1 (shard: rings 2-3)
Producer 3 ──► MpmcRing 3 ──┘    Consumer 2 (shard: rings 4-5, fallback to all)
```

Consumers use CAS (`cmpxchgWeak`) on ring heads. The 3-phase steal strategy:

1. **Local shard** — Try assigned rings first (cache locality)
2. **Hottest ring** — Find ring with highest `hotness` score (load balance)
3. **Random** — xorshift-selected ring (starvation prevention)

### SPMC (1 ring, M consumers)

Single ring, single producer (no CAS on tail). Multiple consumers compete via CAS on head. Simpler than MPMC but head contention is the bottleneck.

## Memory Ordering Model

Every atomic operation uses the weakest sufficient ordering:

### SPSC Ring (no CAS)

| Operation | Ordering | Who | Why |
|-----------|----------|-----|-----|
| `tail.load` | monotonic | Producer | Reading own variable |
| `tail.store` | **release** | Producer | Makes buffer writes visible to consumer |
| `head.load` (by producer) | **acquire** | Producer | Synchronizes with consumer's release |
| `cached_head` read | plain | Producer | Thread-local, never shared |
| `head.load` | monotonic | Consumer | Reading own variable |
| `head.store` | **release** | Consumer | Makes consumed slots available to producer |
| `tail.load` (by consumer) | **acquire** | Consumer | Synchronizes with producer's release |
| `cached_tail` read | plain | Consumer | Thread-local, never shared |

**Happens-before chains:**
- Producer `tail.store(.release)` → Consumer `tail.load(.acquire)`: buffer writes are visible
- Consumer `head.store(.release)` → Producer `head.load(.acquire)`: consumed slots are reusable

### MPMC Ring (CAS on head)

Same as SPSC for the producer side. Consumer side uses:

| Operation | Ordering | Why |
|-----------|----------|-----|
| `head.load` | acquire | Read before speculative copy |
| `head.cmpxchgWeak` | acq_rel / monotonic | Claim items atomically. acq_rel on success ensures copy happened before claim. |
| `hotness.fetchAdd/fetchSub` | monotonic | Advisory counter, no correctness dependency |

## Channel Comparison

| Property | SPSC | MPSC | SPMC | MPMC |
|----------|------|------|------|------|
| Rings | 1 | N (per producer) | 1 | N (per producer) |
| Producer sync | None | None (isolated rings) | None | None (isolated rings) |
| Consumer sync | None | None (single consumer) | CAS on head | CAS on head |
| Allocation | Stack/inline | Heap (NUMA-bindable) | Stack/inline | Stack/inline |
| Memory per ring | ~256KB (u64, 32K) | Same | Same | Same + hotness metadata |
| Best for | Pipe between 2 threads | Fan-in (many → one) | Fan-out (one → many) | Work distribution |

## NUMA Architecture

### Topology Discovery

On init, the MPSC channel discovers the full NUMA topology by reading Linux sysfs:

```
/sys/devices/system/node/node0/cpulist    → "0-7"
/sys/devices/system/node/node0/meminfo    → "MemTotal: 16384000 kB"
/sys/devices/system/node/node0/distance   → "10 21"
/sys/devices/system/node/node1/cpulist    → "8-15"
/sys/devices/system/node/node1/distance   → "21 10"
```

This yields a `NumaTopology` struct with per-node CPU lists, memory sizes, and an inter-node distance matrix. On single-node systems or non-Linux, it falls back to a single uniform node.

### Producer-Local Allocation Strategy

Rings are **not** bound at `init()` time. Instead, binding happens at `register()` on the **producer's thread**:

```
init(allocator):
    1. Allocate all rings (unbound)
    2. Discover NUMA topology from sysfs

register() — called by each producer thread:
    1. Detect calling thread's CPU via sched_getaffinity
    2. Map CPU → NUMA node via topology.nodeOfCpu()
    3. mbind(ring_ptr, MPOL_BIND, producer's node)
```

This ensures each ring's memory is physically local to its producer. The rationale:

- **Producer writes are the hot path** — 256KB+ per batch of buffer writes. NUMA-local writes avoid cache-line ownership transfers across the interconnect.
- **Consumer reads take the cross-node penalty** — but reads only require Shared cache state (no invalidation), making them ~2x cheaper than cross-node writes which require Exclusive state with invalidation round-trips.
- **On single-node systems** — binding is skipped entirely (detected via `topology.isNuma()`). Zero overhead.

### Cross-Node Latency Impact

On a dual-socket EPYC system, the penalty for NUMA-remote access:

```
Local DRAM:        ~80ns
Remote DRAM:       ~140-180ns  (1.8-2.2x penalty)
Local atomic:      ~20-50ns
Remote atomic:     ~100-800ns  (contention dependent)
```

With producer-local binding, the producer's `tail.store(.release)` and buffer writes are always local (~80ns). The consumer's `tail.load(.acquire)` crosses the interconnect (~140ns) but this is amortized across the entire batch:

```
Cross-node penalty per batch:   ~140ns (one tail.load(.acquire))
Messages per batch:             32,768
Amortized penalty per message:  140ns / 32,768 = 0.004ns per message

For comparison, local atomic load:  ~5ns
So cross-node amortized overhead:   0.004ns / 5ns = 0.08% — negligible
```

The key insight: **batch consumption amortizes NUMA penalties to near-zero.** Even on a 4-socket system with 300ns cross-node latency, the per-message cost is 300/32K ≈ 0.01ns.

### Distance-Aware Optimizations

The topology includes an inter-node distance matrix (`NumaTopology.nearestNode(from)`). This enables future optimizations:

- **MPMC consumer shard assignment** — prefer rings on the consumer's local node
- **Consumer ring scan order** — scan nearest-node rings first to minimize cross-node reads
- **Work-stealing** — steal from nearest neighbor before random fallback

## Wait Strategy Layer

The ring buffer supports pluggable wait strategies via `WaitStrategy` (6 variants from busy-spin to futex-blocking). The implementation uses a conditional wake pattern to avoid syscall overhead on the hot path:

```
commit() / advance() / consumeBatch():
    store new value (.release)
    if (waiters.load(.monotonic) > 0):   ← cheap: monotonic load, almost always 0
        Futex.wake(ptr, 1)               ← only when someone is actually blocked
```

The `consumer_waiters` and `producer_waiters` atomic counters live in the cold state region (offset 256). They are only non-zero when a thread is in `reserveBlocking()` or `consumeBatchBlocking()`. On the normal non-blocking hot path, the overhead is a single monotonic load (free on x86 — no memory fence, no cache miss since the cold region is prefetched).

The futex wait/wake operates on the low 32 bits of the 64-bit tail/head pointer. This is safe because any change to the u64 necessarily changes the low 32 bits (ring sizes are < 2^32).

### Wait Strategy Selection Guide

| Strategy | CPU Usage | Wake Latency | Best For |
|----------|-----------|-------------|----------|
| `busy_spin` | 100% | <100ns | Ultra-low latency (trading, gaming) |
| `yielding` | ~50-80% | 1-10µs | Low latency with some CPU savings |
| `sleeping` | ~10-20% | 10-100µs | Moderate latency tolerance |
| `blocking` | 0% when idle | 1-10µs | General purpose (futex-based) |
| `timed_blocking` | 0% when idle | 1-10µs | Blocking with deadline |
| `phased_backoff` | Adaptive | <100ns-10µs | Best default — spins briefly, then blocks |

**Decision tree:**
```
Is latency critical (sub-microsecond)?
  YES → busy_spin (accepts 100% CPU cost)
  NO  →
    Is the producer/consumer always active?
      YES → yielding (saves some CPU, stays responsive)
      NO  →
        Is idle CPU usage acceptable?
          YES → phased_backoff (best tradeoff)
          NO  → blocking (zero CPU when idle, ~1-10µs wake penalty)
```

---

## Compile-Time Configuration

All configuration is resolved at compile time via Zig's comptime system:

- `Config.enable_metrics`: When false, metrics fields are `void` (zero size) and all metrics code is eliminated
- `Config.prefetch_threshold`: When 0, prefetch branches are eliminated
- `Config.max_producers`: Determines ring array size (MPMC) or allocation count (MPSC)
- `CAPACITY` and `MASK` are comptime constants — indexing uses bitwise AND, never modulo

No runtime branching on configuration. No vtables. No dynamic dispatch. The compiler generates specialized code for each `(T, Config)` instantiation.
