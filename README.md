# RingMPSC

A high-performance lock-free Multi-Producer Single-Consumer (MPSC) channel implementation in Zig, achieving **~180 billion messages per second** (u32) and **~93 billion messages per second** (u64) on commodity hardware.

> **Platform**: Linux only. Uses futex, eventfd, epoll, memfd_create, NUMA sysfs, and SCM_RIGHTS — all Linux-specific APIs. macOS and Windows are not supported.

## Performance

Throughput on AMD Ryzen 7 5700 (8 cores, 16 threads, DDR4-3200):

| Config | u32 (4B msg) | u64 (8B msg) |
|--------|-------------|-------------|
| 1P1C | 29 B/s | 15 B/s |
| 2P1C | 58 B/s | 29 B/s |
| 4P1C | 112 B/s | 58 B/s |
| 6P1C | 160 B/s | 85 B/s |
| **8P1C** | **180 B/s** | **93 B/s** |

*B/s = billion messages per second. 500M msgs/producer, 32K batch, 32K ring, @memset fill. Each per-producer ring (128–256 KB) fits within the 512 KB dedicated L2 per Zen 3 core — throughput reflects cache-resident end-to-end message movement. See [docs/methodology.md](docs/methodology.md) for full methodology.*

**How these numbers are achieved:** Each producer calls `reserve(32768)` → `@memset` (fills 128KB for u32) → `commit(32768)`. The consumer advances head pointers. At 1P1C, a single core writes 128KB into L2 cache per batch at near-peak L2 bandwidth (~118 GB/s on Zen 3), yielding ~29 B/s. At 8P, each producer has its own L2 cache (512KB per Zen 3 core) with zero cross-producer contention, scaling to ~180 B/s (~80% efficiency — the ~20% loss is L3 coherency traffic and consumer polling overhead, not lock contention). Ring coordination (`reserve`/`commit`/`consume`) takes <0.1% of total time — 99.9% is the `@memset` write. See [docs/ringmpsc.md](docs/ringmpsc.md) §5.3 for the complete first-principles derivation.

### vs Baselines (single-item, 5M u32)

| Config | ringmpsc | CAS MPSC | Mutex | vs Mutex |
|--------|---------|----------|-------|----------|
| 1P1C | 54 M/s | 115 M/s | 24 M/s | 2x |
| 2P1C | 117 M/s | 23 M/s | 29 M/s | 4x |
| 4P1C | 237 M/s | 20 M/s | 10 M/s | 24x |
| **8P1C** | **514 M/s** | **14 M/s** | **4 M/s** | **129x** |

At 8 producers, both the mutex and CAS queue collapse under contention while ringmpsc scales to 416+ M/s (8x over 1P1C). The CAS MPSC (Vyukov-style bounded array) wins at 1P1C where there is no contention, but degrades from 115 M/s to 14 M/s at 8P — an 8x degradation. See [docs/benchmarks.md](docs/benchmarks.md) for full competitive analysis including batch throughput, latency, and comparison against rigtorp-style queues.

## Algorithm

RingMPSC uses a **ring-decomposed** architecture where each producer has a dedicated SPSC ring buffer, eliminating producer-producer contention entirely.

```
Producer 0 ──► [Ring 0] ──┐
Producer 1 ──► [Ring 1] ──┼──► Consumer (polls all rings)
Producer 2 ──► [Ring 2] ──┤
Producer N ──► [Ring N] ──┘
```

### Key Optimizations

1. **128-byte Cache Line Alignment** — Head and tail pointers separated by 128 bytes to prevent prefetcher-induced false sharing
2. **Cached Sequence Numbers** — Producers cache the consumer's head position, refreshing only when the ring appears full
3. **Batch Operations** — `consumeBatch` processes all available items with a single atomic head update
4. **Adaptive Backoff** — Crossbeam-style exponential backoff (spin -> yield -> park)
5. **Zero-Copy API** — `reserve`/`commit` pattern for direct ring buffer writes
6. **NUMA-Aware Allocation** — Per-ring heap allocation with producer-local NUMA binding
7. **Futex-Based Wait Strategies** — 6 pluggable strategies from busy-spin to futex-blocking with zero CPU when idle
8. **EventNotifier** — Optional eventfd-based consumer wake for epoll/io_uring event loop integration (zero CPU when idle, instant wake on data)
9. **Adaptive Consumer Skip** — Exponential backoff on empty rings, reducing consumer polling from O(P) to O(active_producers)
10. **Zero-Copy BufferPool** — Lock-free slab allocator for large message passing via pointer-ring pattern. Ring carries 4-byte handles; payloads stay in pre-allocated pool with zero copies.
11. **Cross-Process SharedRing** — SPSC ring buffer shared across process boundaries via memfd_create + MAP_SHARED. Automatic cleanup on fd close, heartbeat-based crash detection, cross-process futex wake.
12. **SCM_RIGHTS fd Passing** — Send/receive file descriptors between processes over Unix sockets for SharedRing establishment.
13. **Graceful Shutdown** — Coordinated close with drain and fully-drained detection
14. **Latency Tracking** — Per-batch min/max/avg nanosecond latency (comptime-gated, zero overhead when disabled)
15. **Channel Stats Snapshot** — Single `snapshot()` call returning all health metrics
16. **Thin Event Loop** — Managed consumer loop with automatic drain on stop

See [docs/ringmpsc.md](docs/ringmpsc.md) for the full algorithm writeup with memory ordering analysis.

## Quick Start

```zig
const ringmpsc = @import("ringmpsc");

// SPSC ring buffer (zero-overhead, type alias for Ring)
var ring = ringmpsc.spsc.Channel(u64, .{}){};
_ = ring.send(&[_]u64{1, 2, 3});

// MPSC channel (multi-producer, heap-allocated rings)
var channel = try ringmpsc.mpsc.Channel(u64, .{}).init(allocator);
defer channel.deinit();
const producer = try channel.register();
_ = producer.sendOne(42);

// MPMC channel (work-stealing consumers)
var mpmc = ringmpsc.mpmc.MpmcChannel(u64, .{}){};
const prod = try mpmc.register();
var cons = try mpmc.registerConsumer();
_ = prod.sendOne(42);
var buf: [16]u64 = undefined;
_ = cons.steal(&buf);
```

## Build

```bash
# Build
zig build -Doptimize=ReleaseFast

# Unit tests
zig build test

# Integration tests
zig build test-spsc
zig build test-mpsc
zig build test-fifo
zig build test-chaos
zig build test-determinism
zig build test-stress
zig build test-fuzz
zig build test-mpmc
zig build test-spmc
zig build test-simd
zig build test-blocking
zig build test-wraparound

# Benchmarks
zig build bench-high-perf    # Primary throughput benchmark (u32 + u64)
zig build bench-mpsc         # MPSC baseline
zig build bench-spsc         # SPSC latency
zig build bench-simd         # SIMD operations
zig build bench-suite        # Full benchmark suite with HTML report
zig build bench-analysis     # Bottleneck analysis
zig build bench-cross-process # SharedRing vs in-process (4.6% overhead)
zig build bench-zero-copy    # BufferPool crossover analysis by message size
zig build bench-wake-latency # Spin vs eventfd wake latency (110ns vs 6us p50)
zig build bench              # Full suite: multi-run stats, baselines, HTML report

# Examples
zig build example-basic          # SPSC send/recv + reserve/commit
zig build example-mpsc           # Multi-producer pipeline with handler
zig build example-backpressure   # Blocking send with timeout
zig build example-shutdown       # Graceful shutdown with drain
zig build example-event-loop     # Managed consumer loop
zig build example-event-notifier # eventfd + epoll consumer
zig build example-zero-copy      # Zero-copy large messages via BufferPool
zig build example-shared-memory  # Cross-process ring via memfd + mmap
zig build example-cross-process  # Full IPC with fd passing over Unix socket
zig build example-logging        # Structured logging pipeline (real-world pattern)

# Clean benchmark run (recommended)
sudo taskset -c 0-15 nice -n -20 zig-out/bin/bench-high-perf
```

## Documentation

- [docs/architecture.md](docs/architecture.md) — System architecture: type hierarchy, memory layout, data flow, memory ordering model
- [docs/api.md](docs/api.md) — Complete API reference for all channel types, primitives, and utilities
- [docs/ringmpsc.md](docs/ringmpsc.md) — Algorithm design: ring decomposition, cache layout, batch consumption
- [docs/methodology.md](docs/methodology.md) — Benchmark methodology: measurement procedure, threats to validity, reproducibility
- [docs/benchmarks.md](docs/benchmarks.md) — Results and analysis: scaling, bottleneck breakdown, configuration sensitivity
- [docs/correctness.md](docs/correctness.md) — Correctness properties, memory ordering model, test coverage

For clean benchmark runs:
```bash
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
sudo taskset -c 0-15 nice -n -20 zig-out/bin/bench-high-perf
```

## Channel Types

| | Single-Consumer | Multi-Consumer |
|---|---|---|
| **Single-Producer** | `spsc.Channel` | `spmc.Channel` |
| **Multi-Producer** | `mpsc.Channel` | `mpmc.MpmcChannel` |

- **SPSC** — Zero-overhead type alias for the core Ring. Fastest possible path.
- **MPSC** — Heap-allocated per-producer rings with NUMA support. Dynamic producer registration (grow at runtime). The primary use case.
- **SPMC** — Single ring, CAS-based multi-consumer stealing.
- **MPMC** — Per-producer rings with progressive work-stealing (local shard -> hottest ring -> random fallback).

## Configuration

```zig
pub const Config = struct {
    ring_bits: u6 = 16,            // 2^16 = 64K slots per ring
    max_producers: usize = 16,
    enable_metrics: bool = false,
    track_contention: bool = false,
    prefetch_threshold: usize = 16,
    numa_aware: bool = true,
    numa_node: i8 = -1,           // -1 = auto-detect
};
```

## Correctness

Four properties verified by the test suite. See [docs/correctness.md](docs/correctness.md) for details.

1. **Per-Producer FIFO** — Messages from a single producer are received in order
2. **No Data Loss** — All sent messages are eventually received
3. **Thread Safety** — No data races under concurrent access
4. **Determinism** — Identical inputs produce identical outputs

## Project Structure

```
ringmpsc/
├── src/
│   ├── ringmpsc.zig          # Public API root module
│   ├── primitives/
│   │   ├── ring_buffer.zig   # Core SPSC ring buffer
│   │   ├── wait_strategy.zig  # Futex-based wait strategies
│   │   ├── event_notifier.zig  # eventfd for epoll/io_uring integration
│   │   ├── buffer_pool.zig    # Lock-free slab allocator for zero-copy
│   │   ├── shared_ring.zig    # Cross-process ring via memfd + MAP_SHARED
│   │   ├── backoff.zig        # Exponential backoff
│   │   ├── simd.zig           # SIMD batch operations
│   │   └── blocking.zig       # Blocking wrappers with timeout
│   ├── platform/
│   │   ├── numa.zig           # NUMA topology + allocation
│   │   └── fd_passing.zig     # SCM_RIGHTS fd send/recv over Unix socket
│   ├── mpsc/channel.zig      # MPSC channel (ring-decomposed)
│   ├── spsc/channel.zig      # SPSC channel (Ring type alias)
│   ├── mpmc/channel.zig      # MPMC channel (work-stealing)
│   ├── spmc/channel.zig      # SPMC channel (CAS consumers)
│   ├── event_loop.zig        # Thin managed consumer loop
│   └── metrics/collector.zig # Throughput + latency metrics
├── tests/                    # Integration, stress, fuzz, blocking tests
├── benchmarks/src/           # Benchmark suite + analysis
├── examples/                 # Usage examples (basic, pipeline, logging, backpressure, shutdown, event loop, eventfd+epoll)
├── bindings/
│   ├── c/                    # C header-only implementation
│   └── rust/                 # Rust port
├── docs/
│   ├── architecture.md       # System architecture
│   ├── api.md                # API reference
│   ├── ringmpsc.md           # Algorithm writeup
│   ├── methodology.md        # Benchmark methodology
│   ├── benchmarks.md         # Results and analysis
│   └── correctness.md        # Correctness verification
└── scripts/
    ├── verify.sh              # One-click verification (19 checks)
    └── bench-multirun.sh      # Multi-run statistics (median, stddev)
```

## Bindings

- **C** — Header-only library in `bindings/c/ringmpsc.h`
- **Rust** — Full port in `bindings/rust/`

## Glossary

| Term | Definition |
|------|-----------|
| **MPSC** | Multi-Producer Single-Consumer — many threads send, one thread receives |
| **SPSC** | Single-Producer Single-Consumer — one sender, one receiver (fastest possible) |
| **B/s** | Billion messages per second (10⁹ messages/sec) |
| **M/s** | Million messages per second (10⁶ messages/sec) |
| **Ring decomposition** | Giving each producer its own SPSC ring instead of sharing one queue |
| **Batch consumption** | Processing many messages with a single atomic head update (amortizes sync cost) |
| **Cache-resident** | Data fits in CPU cache (L1/L2/L3), not main memory — much faster access |
| **False sharing** | Two threads' data on the same cache line causing spurious invalidations |
| **Acquire/Release** | Memory ordering that ensures writes before a release-store are visible after an acquire-load |
| **CAS** | Compare-And-Swap — atomic read-modify-write, fails under contention |
| **Futex** | Fast userspace mutex — OS-level sleep/wake with zero overhead when uncontested |

## Related Work

- [LMAX Disruptor](https://github.com/LMAX-Exchange/disruptor) — Original batch-consumption pattern
- [rigtorp/SPSCQueue](https://github.com/rigtorp/SPSCQueue) — High-performance C++ SPSC queue
- [crossbeam-channel](https://github.com/crossbeam-rs/crossbeam) — Rust concurrent channels
- [moodycamel::ConcurrentQueue](https://github.com/cameron314/concurrentqueue) — C++ lock-free queue

## License

[MIT](LICENSE)
