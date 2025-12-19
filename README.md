# RingMPSC

A high-performance lock-free Multi-Producer Single-Consumer (MPSC) channel implementation in Zig, achieving **50+ billion messages per second** on commodity hardware.

## Performance

Throughput benchmark on AMD Ryzen 7 5700 (8 cores, 16 threads, 32MB L3 cache):

| Configuration | Throughput (msg/s) | Scaling |
|---------------|-------------------|---------|
| 1P1C          | 8.6 B/s           | 1.0x    |
| 2P2C          | 13.5 B/s          | 1.6x    |
| 4P4C          | 30.8 B/s          | 3.6x    |
| 6P6C          | 44.2 B/s          | 5.1x    |
| **8P8C**      | **54.3 B/s**      | **6.3x**|

*Measured with 500M messages, batch size 32K, ring size 64K slots.*

## Algorithm

RingMPSC uses a **ring-decomposed** architecture where each producer has a dedicated SPSC (Single-Producer Single-Consumer) ring buffer. This eliminates producer-producer contention entirely.

```
Producer 0 ──► [Ring 0] ──┐
Producer 1 ──► [Ring 1] ──┼──► Consumer (polls all rings)
Producer 2 ──► [Ring 2] ──┤
Producer N ──► [Ring N] ──┘
```

### Key Optimizations

1. **128-byte Cache Line Alignment**: Head and tail pointers are separated by 128 bytes to prevent prefetcher-induced false sharing (Intel/AMD prefetchers may pull adjacent lines).

2. **Cached Sequence Numbers**: Producers cache the consumer's head position to minimize cross-core cache traffic. Cache refresh only occurs when the ring appears full.

3. **Batch Operations**: The `consumeBatch` API processes all available items with a single atomic head update, amortizing synchronization overhead.

4. **Adaptive Backoff**: Crossbeam-style exponential backoff (spin → yield → park) reduces contention without wasting CPU cycles.

5. **Zero-Copy API**: The `reserve`/`commit` pattern allows producers to write directly into the ring buffer without intermediate copies.

### Memory Layout

```
┌──────────────────────────────────────────────────────────────────┐
│ Producer Hot (128B aligned)                                      │
│   tail: AtomicU64        ← Producer writes, Consumer reads       │
│   cached_head: u64       ← Producer-local cache                  │
├──────────────────────────────────────────────────────────────────┤
│ Consumer Hot (128B aligned)                                      │
│   head: AtomicU64        ← Consumer writes, Producer reads       │
│   cached_tail: u64       ← Consumer-local cache                  │
├──────────────────────────────────────────────────────────────────┤
│ Cold State (128B aligned)                                        │
│   active, closed, metrics                                        │
├──────────────────────────────────────────────────────────────────┤
│ Data Buffer (64B aligned)                                        │
│   [CAPACITY]T                                                    │
└──────────────────────────────────────────────────────────────────┘
```

## Usage

```zig
const ringmpsc = @import("src/channel.zig");

// Create channel with default config (64K slots, 16 max producers)
var channel = ringmpsc.Channel(u64, ringmpsc.default_config){};

// Register producer
const producer = try channel.register();

// Send (zero-copy)
if (producer.reserve(1)) |r| {
    r.slice[0] = 42;
    producer.commit(1);
}

// Receive (batch)
var sum: u64 = 0;
const Handler = struct {
    sum: *u64,
    pub fn process(self: @This(), item: *const u64) void {
        self.sum.* += item.*;
    }
};
_ = channel.consumeAll(Handler{ .sum = &sum });
```

## Build & Verify

```bash
# Run all tests and benchmark
./verify.sh

# Build only
zig build -Doptimize=ReleaseFast

# Run benchmark with CPU isolation (recommended)
sudo taskset -c 0-15 nice -n -20 zig-out/bin/bench

# Note: Keep SMT (hyperthreading) ENABLED. The 8P8C config needs 16 threads.
# Producer-consumer pairs benefit from sharing L1/L2 cache on SMT siblings.

# Run unit tests
zig build test
```

## Files

```
ringmpsc/
├── README.md           # This file
├── build.zig           # Build configuration
├── verify.sh           # One-click verification script
└── src/
    ├── channel.zig     # Core implementation
    ├── bench_final.zig # Throughput benchmark
    ├── test_fifo.zig   # FIFO ordering verification
    ├── test_chaos.zig  # Race condition detection
    └── test_determinism.zig # Deterministic execution test
```

## Correctness Properties

RingMPSC guarantees the following properties (verified by included tests):

1. **Per-Producer FIFO**: Messages from a single producer are received in order.
2. **No Data Loss**: All sent messages are eventually received.
3. **Thread Safety**: No data races under concurrent access.
4. **Determinism**: Identical inputs produce identical outputs.

## Configuration

```zig
pub const Config = struct {
    ring_bits: u6 = 16,       // 2^16 = 64K slots per ring
    max_producers: usize = 16,
    enable_metrics: bool = false,
};

// Preset configurations
pub const low_latency_config = Config{ .ring_bits = 12 };     // 4K (L1-resident)
pub const high_throughput_config = Config{ .ring_bits = 18 }; // 256K slots
```

## Related Work

- [LMAX Disruptor](https://github.com/LMAX-Exchange/disruptor) - The original batch-consumption pattern
- [rigtorp/SPSCQueue](https://github.com/rigtorp/SPSCQueue) - High-performance C++ SPSC queue
- [crossbeam-channel](https://github.com/crossbeam-rs/crossbeam) - Rust concurrent channels
- [moodycamel::ConcurrentQueue](https://github.com/cameron314/concurrentqueue) - C++ lock-free queue

## License

MIT
