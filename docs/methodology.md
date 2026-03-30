# Methodology

This document describes how RingMPSC performance claims are measured, why the measurement process is sound, and how to reproduce results independently.

## 1. Scope

**System Under Test (SUT)**: RingMPSC MPSC channel — the `mpsc.Channel(T, Config)` type with heap-allocated per-producer SPSC rings.

**Properties measured**:
- Sustained throughput (messages/second) across 1–8 producer threads with 1 consumer thread
- Scaling efficiency (throughput at NP relative to 1P)

**Out of scope**: Latency distribution, MPMC/SPMC throughput, blocking API performance, comparison with other implementations. These require separate methodology.

## 2. Metric Definitions

### Throughput

```
throughput = total_messages / elapsed_nanoseconds
```

- **total_messages**: `MSG_PER_PRODUCER × num_producers` (expected count, not actual consumed)
- **elapsed_nanoseconds**: Wall-clock time from start barrier release to consumer drain completion, measured internally by the consumer thread using `std.time.Instant` (backed by `clock_gettime(CLOCK_MONOTONIC)` on Linux)
- **Unit**: Billions of messages per second (B/s). 1 B/s = 10^9 messages/second.
- **Expected count vs. actual count**: We use expected count because the channel guarantees no data loss (verified by correctness tests). Using expected count avoids an extra atomic load in the measurement path.

### Scaling Efficiency

```
efficiency = throughput_NP / (throughput_1P × N)
```

A value of 1.0 indicates perfect linear scaling. Values below 1.0 indicate contention or resource saturation.

## 3. Test Environment

### Hardware

| Component | Specification |
|-----------|--------------|
| CPU | AMD Ryzen 7 5700 (Zen 3, 8 cores / 16 threads) |
| Base / Boost Clock | 3.7 GHz / 4.65 GHz |
| L1 Data Cache | 32 KB per core (8-way) |
| L2 Cache | 512 KB per core (8-way) |
| L3 Cache | 32 MB shared (16-way) |
| Memory | DDR4-3200 dual-channel |
| NUMA | Single socket, 1 NUMA node |

### Software

| Component | Version |
|-----------|---------|
| OS | Linux 6.x (Ubuntu/Pop!_OS) |
| Kernel | Default configuration |
| Compiler | Zig 0.15.2 |
| Optimization | `-O ReleaseFast` (equivalent to `-O3 -DNDEBUG`) |
| CPU Governor | `performance` (verified via `scaling_governor`) |
| SMT | Enabled (16 logical CPUs) |

### Isolation

- Each producer thread is pinned to a dedicated logical CPU (0 through N-1) via `sched_setaffinity`
- Consumer thread is pinned to logical CPU N (adjacent to last producer)
- No explicit IRQ isolation (`taskset` for the process is recommended but not required)
- No other compute-intensive processes during measurement

## 4. Experimental Design

### Independent Variables

| Variable | Values | Rationale |
|----------|--------|-----------|
| `num_producers` | 1, 2, 4, 6, 8 | Covers 1 through all physical cores |
| Message type | `u32` (4B), `u64` (8B) | Demonstrates memory bandwidth dependency |

### Control Variables (Fixed)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `ring_bits` | 15 (32K slots) | Batch + ring fit in L2; large enough to absorb burst |
| `batch_size` | 32,768 | Matches ring capacity — maximizes amortization |
| `msg_per_producer` | 500,000,000 | Long enough to reach steady state (~3–20s per configuration) |
| `enable_metrics` | false | Removes atomic counter overhead from hot path |
| `prefetch_threshold` | 0 | Disables software prefetch (hardware prefetcher sufficient for linear access) |
| Producer fill | `@memset(slice, value)` | Exercises full write bandwidth — every element written |

### What Is Not Varied

Buffer size and batch size are held constant. A parameter sweep of these values is useful but constitutes a separate experiment.

## 5. Measurement Procedure

### Timing

- **Source**: `std.time.Instant.now()` backed by `clock_gettime(CLOCK_MONOTONIC)` on Linux
- **Resolution**: Nanosecond. Typical vDSO overhead: 20–50ns (negligible relative to multi-second runs)
- **Why CLOCK_MONOTONIC**: Not affected by NTP adjustments. Measures elapsed wall-clock time (not CPU time), which is the correct metric for concurrent throughput — all threads contribute simultaneously.

**Precise measurement points** (references to `benchmarks/src/high_perf.zig`):

```
t0 capture (consumer thread, line 123):
    while (!barrier.load(.acquire)) spinLoopHint();  // spin until start
    const t0 = std.time.Instant.now();               // ← START

t1 capture (consumer thread, line 163):
    // ... main consume loop ...
    // ... final drain after producers finish ...
    elapsed_out.store(Instant.now().since(t0));       // ← END
```

**What is included between t0 and t1:**
- All producer writes (@memset into ring buffers)
- All consumer head advancements
- Final drain of in-flight messages after producers signal completion
- Spin-loop hints when rings are empty

**What is excluded:**
- Thread spawning and CPU pinning (before barrier)
- Channel allocation and ring registration (before barrier)
- `channel.close()` (called by main thread after producers join, but before consumer drain completes)

- **Overhead accounting**: Not subtracted. At 100M messages × 8 producers, the two timing calls contribute <100ns to a run lasting billions of nanoseconds.

### Warmup

No explicit warmup run. The first configuration (1P1C) serves as implicit warmup for cache warming and branch predictor training. If thermal throttling is a concern, insert a 3–5 second cooldown between configurations.

### Synchronization

```
Timeline:
─────────────────────────────────────────────────────────────────────────────
Main thread:   spawn consumers → spawn producers → barrier.store(true, seq_cst)
                                                         │
                                                         ▼
Producers:     [spin on barrier] ─────────────── barrier fires ──────────────
               pin(cpu_0..N-1)                   │
                                                 ▼
                                          reserve → @memset → commit (×15,259)
                                                 │
                                                 ▼
                                          p_done.fetchAdd(1, release)
                                                 │
Consumer:      [spin on barrier] ─────────────── barrier fires ──────────────
               pin(cpu_N)                        │
                                           t0 = Instant.now()     ← START
                                                 │
                                                 ▼
                                          poll all rings, advance heads
                                                 │
                                          (idle > 64 && all producers done?)
                                                 │
                                                 ▼
                                          final drain of all rings
                                                 │
                                           t1 = Instant.now()     ← END
─────────────────────────────────────────────────────────────────────────────
Main thread:                              join producers → close() → join consumer
```

Detailed sequence:

1. All threads (producers + consumer) are spawned and pinned before measurement begins
2. A shared `start_barrier` (atomic bool with `seq_cst` store) synchronizes launch
3. All threads spin-wait on the barrier — no yield, no syscall — ensuring near-simultaneous start (~100ns jitter across cores, measured by TSC comparison)
4. Producers signal completion via `fetchAdd` on a shared counter
5. The main thread calls `channel.close()` after all producers join
6. Consumer detects (a) all producers done AND (b) channel closed, then performs final drain of each ring, then records elapsed time

### Drain Correctness

The consumer performs a final drain loop after producers complete:
```
for each ring:
    read remaining = tail - head
    advance head to tail
    accumulate count
```
This ensures all in-flight messages are counted even if the consumer was behind when producers finished.

### Memory Allocation

All rings are heap-allocated during `channel.init()` **before** measurement begins. No allocation occurs during the timed region. Ring pointers are cached in a stack-local array in the consumer thread to avoid dereferencing the channel's allocator-managed slice on every iteration.

## 6. Statistical Reporting

### Current Practice

The benchmark reports a single run per configuration. This is a known limitation. The primary metric is throughput from the most recent run.

### Recommended Practice for Publication

Run each configuration 7 times with 3-second cooldown between runs. Report:
- **Median** throughput (robust to outliers)
- **Min and max** (shows variance)
- **Standard deviation**

Example:
```bash
for i in $(seq 1 7); do
    sleep 3
    zig-out/bin/bench-high-perf 2>&1 | grep "8P1C"
done
```

Observed variance on the test hardware: ±5–8% between runs, attributable to OS scheduler interference and thermal fluctuation.

### Outlier Policy

No outliers are removed. All runs are reported. If a run is anomalously low (>2 standard deviations below median), the likely cause is documented (e.g., "background process spike", "thermal throttle").

## 7. Threats to Validity

### Internal Validity

| Threat | Assessment | Mitigation |
|--------|-----------|------------|
| **Thermal throttling** | AMD Ryzen 7 5700 may reduce boost clock under sustained all-core load | Performance governor + short runs (2–10s). First-run numbers may be higher than subsequent. |
| **OS scheduler interference** | Kernel threads, interrupts, and other processes steal cycles | CPU pinning + `nice -n -20`. Process-level `taskset` recommended. |
| **Memory controller contention** | 8 producers writing 256KB each saturate effective write bandwidth (L2 + coherency traffic) | Documented as the primary bottleneck. Halving message size doubles throughput (u32 vs u64). |
| **Compiler optimization artifacts** | Dead code elimination could inflate numbers | All writes use `@memset` which the compiler cannot eliminate (the buffer is read by the consumer via atomic tail advancement). Verified by comparing with sequential fill. |
| **Measurement overhead** | Timing calls in the measurement path | Two calls total (<100ns) vs. multi-second runs. Negligible. |

### External Validity

| Limitation | Impact |
|-----------|--------|
| Single hardware platform | Results on Intel or ARM may differ due to cache coherency protocol differences (MOESI vs MESIF) |
| Single NUMA node | Multi-socket systems may show different scaling due to cross-socket coherency traffic |
| Synthetic workload | Real applications perform work per message, reducing effective throughput |
| DDR4 only | DDR5 systems (~2x bandwidth) would show proportionally higher throughput |

### Construct Validity

The benchmark measures **channel throughput inclusive of producer write bandwidth**. This is intentional — in real workloads, producers write data. However, this means the reported number is bounded by memory bandwidth, not synchronization overhead.

**What "180 B/s" includes:**
- Producer `@memset` writes filling 128 KB of ring buffer per batch (the dominant cost — 99.9% of time)
- Ring coordination: `reserve()` bounds check, `commit()` tail store, consumer `head.store()`
- Spin-loop hints during brief ring-full/ring-empty periods

**What "180 B/s" does NOT include:**
- Per-message application processing (parsing, computation, I/O)
- Consumer reading the message data (primary benchmark only advances the head pointer)
- Memory allocation (all pre-allocated before timing)
- Cross-NUMA traffic (single-socket test hardware)

**The consumer does not read data in the primary benchmark.** The consumer loads `tail.load(.acquire)` to see how many messages are available, then stores `head.store(tail, .release)` to free those slots. It never dereferences `buffer[i]`. This means the 180 B/s number measures **write bandwidth + ring coordination**, not read bandwidth. A separate `runBenchWithConsume` variant reads every element with a checksum accumulator — throughput drops because the consumer now competes for memory bandwidth.

**Why this is still meaningful:** The producer's `@memset` writes are real writes that fill the buffer. The compiler cannot eliminate them because the tail pointer (stored with `.release`) creates a data dependency — the consumer observes the tail advancement and could read the data. Assembly inspection confirms `call memset` is present in the hot loop (verified via `objdump`).

To isolate synchronization overhead, run with a single-element write per batch (see `bench-analysis`). This shows ~28,000 B/s per producer — the theoretical ceiling if message production were free.

## 8. Reproducibility

### Build

```bash
git clone https://github.com/boonzy00/ringmpsc.git
cd ringmpsc
zig build -Doptimize=ReleaseFast
```

### Run

```bash
# Standard run (no root required)
zig-out/bin/bench-high-perf

# Clean run (root required, recommended for publication)
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
sudo taskset -c 0-15 nice -n -20 zig-out/bin/bench-high-perf
```

### Configuration

All benchmark parameters are compile-time constants in `benchmarks/src/high_perf.zig`. Modify `CPU_COUNT` to match your system's logical CPU count.

### Competitive Benchmarks

The benchmark suite (`benchmarks/src/bench.zig`) compares ringmpsc against three baseline implementations across multiple dimensions with multi-run statistics. Generates a self-contained HTML report at `benchmarks/results/bench.html` with inline SVG charts.

**Baselines** (all implemented in the same file, same compiler, same hardware):
- **Rigtorp-style Cached SPSC** — cached head/tail, power-of-2 masking (matches rigtorp/SPSCQueue algorithm). Used in batch throughput comparison.
- **CAS MPSC Queue** — Vyukov-style bounded array with CAS enqueue (standard lock-free MPSC approach). Used in single-item MPSC comparison.
- **Mutex + buffer** — `std.Thread.Mutex` protected ring. Used in both batch and single-item comparisons.

**Dimensions measured:**
1. **Batch throughput** (u32 + u64) — 500M msgs/producer, 32K batch, 32K ring, @memset fill. All baselines use the same ring-decomposed architecture (separate ring per producer) to isolate the ring algorithm.
2. **MPSC scaling** (1/2/4/8 producers) — 5M u32 total, single-item sendOne/consumeAll. ringmpsc vs CAS MPSC vs Mutex.
3. **SPSC round-trip latency** — 100K ping-pong iterations after 10K warmup, sorted samples for min/p50/p90/p99/p999/max percentiles.
4. **Batch size sweep** — 1P1C u32, varying batch sizes from 1 to 32K.
5. **Ring size sweep** — 1P1C u32, varying ring_bits from 10 to 18.

The batch benchmark (`high_perf.zig`) and the benchmark suite (`bench.zig`) measure different things:

| Benchmark | Measures | Best for |
|-----------|----------|----------|
| `bench-high-perf` | Batch throughput (32K items/batch) | Maximum sustained throughput claims |
| `bench` | Batch + single-item + latency vs 3 baselines, multi-run stats | Fair comparison, HTML report |

### Source

All results in this document were produced from the `main` branch. Exact commit hash should be recorded alongside published results.

---

## Appendix: Recent Optimizations (v2.3.0)

### Adaptive Consumer Skip (Exponential Backoff)

The MPSC consumer now tracks which producer rings have been empty for consecutive polls and exponentially backs off on them (skip 1, 2, 4, 8, 16, 32, 64 rounds). This reduces consumer-side polling from O(P) to O(active_producers).

**Rationale**: Polling empty rings wastes cycles without reducing queue wait time. Adaptive exponential backoff eliminates this overhead for inactive producers while resetting immediately when data arrives.

**Measurement impact**: For workloads with sparse producers (e.g., 8 registered producers, 2 active), consumer overhead drops proportionally. Batch throughput is unaffected (the ring-level `consumeBatch` path is unchanged).

### EventNotifier (eventfd + epoll)

Optional Linux eventfd-based consumer wake. When attached to a ring via `setEventNotifier()`, every `commit()` writes u64(1) to the eventfd. The consumer sleeps in `epoll_wait` with zero CPU and wakes instantly on data.

**Measurement notes**: eventfd adds ~1us per signal (write syscall). For high-throughput batch workloads where commit() is called once per batch of 32K messages, this is negligible. For single-item sends, the overhead is measurable but acceptable for event-loop integration where the alternative is polling.

**When NOT to use**: Dedicated consumer threads with futex-based blocking. The futex path has a zero-syscall fast path (check `consumer_waiters` counter) that eventfd cannot match.

### BufferPool Zero-Copy (Phase 2)

For messages larger than a cache line (64 bytes), the pointer-ring pattern avoids copying payloads through the ring. Instead, the ring carries 4-byte handles pointing to slabs in a pre-allocated `BufferPool`.

**Measurement notes**: The performance win is proportional to message size. For 64-byte messages, the copy cost is one cache line — negligible. For 2KB+ messages, the copy dominates. With BufferPool:
- Ring bandwidth drops by `payload_size / 4` (e.g., 512x for 2KB messages)
- Ring stays cache-resident regardless of payload size (handles are always 4 bytes)
- The payload write (producer → pool slab) and read (consumer ← pool slab) are the same physical memory — zero copies total

**Overhead**: Lock-free `alloc()`/`free()` use CAS with tagged pointers. Each CAS costs ~10-50ns under contention. For single-threaded alloc/free (typical: one producer allocates, one consumer frees), this is effectively a single atomic store — no contention, no retry.

**When to use**: Messages ≥ 4KB where copy cost exceeds CAS overhead. Measured crossover: at 4KB, zero-copy is 1.5x faster than inline copy. Below 4KB, inline Ring(T) is faster because the CAS alloc/free overhead (~10-50ns) exceeds the copy cost. See bench-zero-copy for exact numbers.

### SharedRing Cross-Process (Phase 3)

Cross-process SPSC ring via memfd_create + MAP_SHARED. Same SPSC algorithm as the in-process Ring, but backed by shared memory that both processes mmap.

**Measurement notes**:
- Atomic operations on MAP_SHARED memory have identical performance to thread-shared memory on x86 (both use MESI cache coherence at the physical page level)
- Cross-process futex uses `FUTEX_WAKE` (global hash table) instead of `FUTEX_WAKE_PRIVATE` (process-local). This adds ~50-100ns per wake due to the global lookup, but only occurs when someone is actually blocked.
- `extern struct` header (512 bytes) ensures deterministic layout across separate compilations
- memfd_create has negligible overhead vs shm_open (~2us for creation), but provides automatic cleanup on fd close

**Overhead vs in-process Ring**: Near-zero for the data path. The only additional cost is the heartbeat timestamp store on each `commit()` (~1ns, monotonic ordering). The cross-process futex wake is identical cost to the in-process futex wake when there are waiters.

**When to use**: IPC between separate processes. For same-process communication, use the standard Ring (slightly simpler, no mmap overhead on creation).

### fd Passing (SCM_RIGHTS)

The `sendFd`/`recvFd` utilities transmit file descriptors between processes via Unix domain socket ancillary messages. This is a one-time setup cost (~10us) at channel establishment — after that, the data path is pure shared memory with zero syscalls.

**Implementation**: Uses `sendmsg`/`recvmsg` with `SOL_SOCKET` + `SCM_RIGHTS` cmsg type. The kernel duplicates the file descriptor into the receiving process's fd table, granting it access to the same memfd-backed memory.
