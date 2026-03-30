# Correctness Verification

RingMPSC guarantees four correctness properties, each verified by dedicated test suites.

## Properties

### 1. Per-Producer FIFO Ordering

**Guarantee**: Messages from a single producer are received in the order they were sent.

**Why it holds**: Each producer has a dedicated SPSC ring buffer. The producer writes sequentially to `buffer[tail % CAPACITY]` and increments tail. The consumer reads sequentially from `buffer[head % CAPACITY]` and increments head. No reordering is possible because there is exactly one writer and one reader per ring.

**Test**: `zig build test-fifo`
- 8 producers each send 1M messages
- Each message is a `usize` encoding: `value = producer_id * 1_000_000 + sequence_number`
- Consumer maintains per-producer last-seen sequence counter
- For each received message: extract producer_id and seq, verify `seq > last_seen[producer_id]`
- Any out-of-order delivery increments a violation counter
- Zero violations across 8M total messages = PASS

**Test**: `zig build test-spsc`
- FIFO ordering test with 4 producers × 10K messages
- Validates per-producer monotonic sequence

### 2. No Data Loss

**Guarantee**: Every message sent by a producer (via `commit()`) is eventually received by the consumer, provided:
1. The consumer thread is running and calling `consumeBatch()` or equivalent
2. The ring is not permanently full (i.e., the consumer eventually drains)

**Liveness bound**: If the consumer calls `consumeBatch()` at least once after every `commit()`, all messages are delivered within 2 consumer polling cycles. There is no unbounded delay — messages become visible immediately after `tail.store(.release)`.

**What counts as "sent"**: A message is sent when `commit(n)` is called after `reserve(n)`. Calling `reserve()` alone does not send — the producer can write to the slice but the consumer cannot see it until `commit()` stores the new tail. If the producer crashes between `reserve()` and `commit()`, uncommitted messages are not visible (this is safe — no partial data is exposed).

**Why it holds**: `reserve` returns a slice into the ring buffer. `commit` makes it visible by advancing the tail pointer with release ordering. The consumer's acquire load of the tail pointer synchronizes with the producer's release store, guaranteeing all writes to the buffer are visible before the consumer reads them.

**Test**: `zig build test-mpsc` (concurrent producers test)
- 3 producers each send 10K messages
- Consumer counts total received
- Expected: 30,000. Actual: 30,000. Zero loss.

**Test**: `zig build test-chaos`
- 5 iterations of 8 producers × 50K messages
- Random scheduling perturbations
- Verifies sent == received every iteration

### 3. Thread Safety (No Data Races)

**Guarantee**: Concurrent access by multiple producer threads and one consumer thread produces no data races or undefined behavior.

**Why it holds**: The ring-decomposed architecture eliminates shared mutable state between producers. Each producer writes only to its own ring. The consumer reads from all rings but never writes to producer-owned fields. The only shared variables are:

| Variable | Writer | Reader | Ordering |
|----------|--------|--------|----------|
| `tail` | Producer | Consumer | release/acquire |
| `head` | Consumer | Producer | release/acquire |
| `cached_head` | Producer only | — | monotonic (local) |
| `cached_tail` | Consumer only | — | monotonic (local) |
| `active` | Registration | Consumer | release/acquire |
| `closed` | Close | Both | release/acquire |

No two threads ever write to the same atomic variable, so there are no CAS retries or contention on the MPSC hot path.

**Test**: `zig build test-chaos`
- Runs 5 iterations with random timing perturbations
- Tests for races under concurrent load

**Test**: `zig build test-stress`
- Property-based stress tests: FIFO, no-loss, conservation
- High-contention MPSC and MPMC scenarios

### 4. Determinism

**Guarantee**: Given identical inputs and scheduling, the output is identical across runs.

**Why it holds**: The ring buffer uses no randomization, no timestamps, and no system-dependent ordering. With deterministic scheduling (same thread pinning, same message counts), the output is reproducible.

**Test**: `zig build test-determinism`
- 3 runs with identical configuration
- Verifies per-producer ordering is consistent
- Zero violations across all runs

## Memory Ordering Model

### Definitions

- **Acquire load**: A load operation where all subsequent memory accesses (reads and writes) in the current thread are guaranteed to happen after this load. Used by the reader of shared data.
- **Release store**: A store operation where all preceding memory accesses in the current thread are guaranteed to happen before this store. Used by the writer of shared data.
- **Monotonic**: Only guarantees atomicity (no tearing). No ordering constraints relative to other operations. Used for reading thread-local variables that happen to be atomic.
- **Happens-before**: Operation A *happens-before* operation B if A's effects are guaranteed to be visible to B. In RingMPSC, this is established by release/acquire pairs on the same atomic variable.

### Ordering per operation

```
PRODUCER                          CONSUMER
========                          ========
tail.load(.monotonic)             head.load(.acquire)
  ↓ (own variable, fast)            ↓ (synchronizes with producer's head.load path)
cached_head check                 tail.load(.acquire)
  ↓                                 ↓ (synchronizes with producer's release)
[slow path only]                  read buffer[head..tail]
head.load(.acquire)                 ↓
  ↓ (synchronizes with             head.store(new_head, .release)
     consumer's release)             ↓ (makes consumed slots available)
write buffer[tail..tail+n]
  ↓
tail.store(new_tail, .release)
  ↓ (makes written data visible)
```

### Happens-before chains (proof sketch)

**Chain 1: Producer writes are visible to consumer**
```
1. Producer writes buffer[tail..tail+n]         (ordinary stores)
2. Producer does tail.store(new_tail, .release)  (release fence before store)
   ─── happens-before ───
3. Consumer does tail.load(.acquire)             (acquire fence after load)
4. Consumer reads buffer[head..tail]             (ordinary loads)

By the release/acquire contract: all stores before (2) are visible after (3).
Therefore buffer writes in (1) are visible when consumer reads in (4). ✓
```

**Chain 2: Consumer frees slots for producer**
```
1. Consumer finishes reading buffer[head..old_head+n]
2. Consumer does head.store(old_head+n, .release)
   ─── happens-before ───
3. Producer does head.load(.acquire)             (slow path: ring appeared full)
4. Producer sees new head, knows slots [old_head..new_head) are safe to overwrite

By the release/acquire contract: the consumer's reads in (1) completed before (2).
The producer's writes after (3) will not overlap with in-progress reads. ✓
```

**Why monotonic is safe for `tail.load` (producer) and formerly `head.load` (consumer)**:
- The producer's `tail.load(.monotonic)` reads its *own* variable. Only this thread writes to `tail`. A monotonic load of a variable written only by the current thread always returns the most recent value — no synchronization is needed with itself.
- The consumer's `head.load` in peek/iterator operations uses `.acquire` to synchronize with any prior `head.store(.release)` from `advance()` or `consumeBatch()` — ensuring visibility of consumed slot state.

**Why `cached_head` / `cached_tail` need no atomic ordering**:
- `cached_head` is read and written only by the producer thread. It is never shared.
- `cached_tail` is read and written only by the consumer thread. It is never shared.
- These are plain `u64` fields, not atomic. They exist purely as a thread-local cache to avoid cross-core reads.

## Running All Correctness Tests

```bash
# Unit tests (compile-time verification of all module imports)
zig build test

# Integration tests
zig build test-spsc          # SPSC FIFO + basic operations
zig build test-mpsc          # MPSC register, send, consume, concurrent
zig build test-fifo          # Large-scale FIFO ordering (8P × 1M msgs)
zig build test-chaos         # Race condition detection (5 iterations)
zig build test-determinism   # Reproducibility verification (3 runs)

# Extended tests
zig build test-stress        # Property-based stress tests
zig build test-fuzz          # Fuzz testing
zig build test-mpmc          # MPMC work-stealing tests
zig build test-spmc          # SPMC CAS-based consumer tests
zig build test-simd          # SIMD correctness tests
zig build test-blocking      # Blocking API, wait strategies, graceful shutdown
zig build test-wraparound    # u64 position wraparound at MAX boundary
```

All tests are deterministic and run in under 30 seconds on commodity hardware.

## What The Tests Do NOT Cover

For transparency, these areas have limited or no test coverage:

- **Allocation failure paths**: No tests inject `OutOfMemory` during `init()` or `register()`
- **NUMA binding**: No multi-node tests (requires multi-socket hardware)
- **All 6 wait strategies under contention**: Only `blocking` and `busy_spin` are thoroughly tested
- **Consumer reading stale data**: The memory ordering model is verified by design, not by targeted fault injection (removing a fence and checking if tests catch it)

## Adaptive Consumer Skip Correctness

The adaptive skip mechanism in `consumeAll` does NOT affect correctness:
- **No message loss**: Skip only delays CHECKING an empty ring, never skips a non-empty ring. The skip counter resets to 0 immediately when a ring is found non-empty.
- **FIFO preserved**: Skip tracking is per-ring, not per-message. When a ring IS checked, the full `consumeBatch` path runs, preserving per-ring FIFO.
- **Bounded staleness**: Maximum skip is 64 rounds. A ring that becomes non-empty will be checked within 64 consumer polls. For typical poll intervals of microseconds, this is <100us worst-case detection latency.
- **Reset on workload change**: `resetAdaptiveSkip()` clears all counters, ensuring immediate responsiveness after pattern changes.

## EventNotifier Correctness

The EventNotifier does NOT affect ring buffer correctness:
- **Supplementary wake**: eventfd signal is in ADDITION to futex wake, not a replacement. Even if the eventfd signal is lost (should never happen, but defense in depth), the futex path still wakes blocked consumers.
- **Coalescing is safe**: Multiple `signal()` calls between consumer wakes accumulate in the u64 counter. The consumer reads/resets the counter and drains ALL available ring data regardless of the counter value.
- **Edge-triggered safety**: Consumer calls `consume()` (eventfd read) BEFORE re-entering `epoll_wait`, preventing missed wakes from edge-triggered mode.

## Formal Verification (Planned)

See [UPGRADE_PLAN.md](UPGRADE_PLAN.md) for the TLA+ and CDSChecker verification strategy. The SPSC ring buffer is amenable to formal verification because:
- Acquire/release ordering on head/tail provides sequential consistency between exactly two threads (producer and consumer)
- The cached head/tail pattern satisfies `cached_head ≤ head` and `cached_tail ≤ tail` as invariants
- The ring is wait-free on the non-blocking path (bounded number of atomic operations)

## BufferPool Correctness

### Lock-Free Free-List

The BufferPool uses a CAS-based free-list with ABA prevention:
- **Head** is a packed u64: `(tag:u32 << 32 | index:u32)`
- Each `alloc()` increments the tag, so even if the same slab index reappears at the head, the tag differs and stale CAS attempts fail
- `cmpxchgWeak` with `acq_rel` ordering ensures the free-list link is visible before the head update

### Ownership Transfer

The pointer-ring pattern provides memory safety WITHOUT garbage collection or reference counting:
- After `alloc()`: producer owns the slab exclusively
- After `ring.send(handle)`: ownership transfers to the ring (producer must NOT access)
- After `ring.recv()`: consumer owns the slab exclusively
- After `pool.free(handle)`: slab returns to pool (consumer must NOT access)

At no point do two threads access the same slab concurrently. The ring IS the ownership boundary.

### setLen Release Ordering

`setLen()` uses `.release` ordering to ensure all payload writes are visible before the length is published. The consumer's `get()` uses `.acquire` on the length load, creating a happens-before relationship that guarantees the consumer sees the complete payload.

### No Use-After-Free

The free-list is a stack (LIFO). A freed slab goes to the top of the free list. The next `alloc()` returns it. Between `free()` and the next `alloc()`, no thread holds a reference. The ABA tag prevents the pathological case where a CAS succeeds on a recycled slab.

## SharedRing Cross-Process Correctness

### Atomic Safety Across MAP_SHARED

Atomic operations on MAP_SHARED memory are safe on x86/ARM because:
- Cache coherence (MESI/MOESI) operates at the physical page level, below the MMU
- Both processes map the same physical pages, so coherence traffic is identical to thread-shared memory
- x86 Total Store Ordering (TSO) means acquire/release compile to plain MOV instructions — no extra fences needed
- `std.atomic.Value(u64)` with `.load(.acquire)` and `.store(val, .release)` generates correct x86 instructions for cross-process visibility

**Critical requirement**: Atomics must be lock-free. On x86, all aligned loads/stores up to 8 bytes are lock-free. All SharedRingHeader atomics are naturally aligned.

### extern struct Determinism

`SharedRingHeader` is `extern struct` (not `struct`) to guarantee identical memory layout across separate compilations. Zig's default `struct` can reorder fields. The `extern struct` uses C ABI layout: fields in declaration order, natural alignment, explicit padding.

### Cross-Process Futex

Uses `FUTEX_WAKE` (opcode 1) instead of `FUTEX_WAKE_PRIVATE` (opcode 0x80|1). The difference:
- `FUTEX_WAKE_PRIVATE` uses a process-local hash table — futexes at the same virtual address in different processes are NOT matched
- `FUTEX_WAKE` uses a global hash table keyed on (physical page, offset) — futexes on the same MAP_SHARED page ARE matched across processes

### Crash Recovery

If the producer process dies between `reserve()` and `commit()`:
- The tail pointer was never advanced (tail.store only happens in commit)
- The consumer sees no new data — the ring appears unchanged
- Partially written data sits in buffer slots beyond the tail — invisible to the consumer
- `isProducerAlive(timeout_ns)` detects dead producers via heartbeat staleness

If the consumer process dies:
- The head pointer stops advancing — ring fills up
- Producer's `reserve()` returns null (ring full)
- Producer can detect via `isProducerAlive`-style heartbeat (not yet implemented on consumer side)

### Magic Number Validation

`attach()` verifies the magic number (`0x0044524853474E52` = "RNGSHRD\0"), version, and slot_size before using the shared memory. This prevents:
- Attaching to unrelated memfd (wrong magic)
- Attaching to incompatible version (version mismatch)
- Attaching with wrong type T (slot_size mismatch)
