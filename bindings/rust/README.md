# RingMPSC - Rust Implementation

Rust port of the RingMPSC lock-free MPSC channel. Same algorithm as the Zig implementation.

## Performance

Benchmarked on AMD Ryzen 7 PRO 8840U (Zen 4):

| Config | Zig | Rust | Diff |
|--------|-----|------|------|
| 1P1C | ~0.49 B/s | ~0.55 B/s | +12% |
| 2P2C | ~0.44 B/s | ~0.78 B/s | +77% |
| 4P4C | ~0.80 B/s | ~1.35 B/s | +69% |
| 6P6C | ~1.04 B/s | ~1.50 B/s | +44% |
| 8P8C | ~1.02 B/s | ~1.38 B/s | +35% |

*B/s = billion messages per second. Results vary by hardware.*

## Features

- **Stack-allocated ring buffer** - Buffer embedded in struct, zero heap indirection
- **Batch consumption API** - Single atomic update for N items
- **Conditional CPU pinning** - Enabled only for 1P1C based on A/B testing
- **No software prefetch** - Hardware prefetcher handles sequential access on Zen 4

## Architecture

```
rust_impl/
├── src/
│   ├── lib.rs            # Ring + Channel implementation
│   ├── atomics.rs        # x86_64 prefetch intrinsics
│   ├── stack_ring.rs     # Zero-indirection ring with consume_batch()
│   └── bin/
│       ├── bench.rs          # Main benchmark
│       ├── bench_ab.rs       # A/B test: pinning strategies
│       └── bench_prefetch.rs # A/B test: prefetch effectiveness
└── Cargo.toml            # LTO=fat, codegen-units=1, opt-level=3
```

## Building & Running

```bash
# Build with native CPU optimizations
RUSTFLAGS="-C target-cpu=native" cargo build --release

# Run main benchmark
RUSTFLAGS="-C target-cpu=native" cargo run --release

# Run A/B tests
RUSTFLAGS="-C target-cpu=native" cargo run --release --bin bench_ab
RUSTFLAGS="-C target-cpu=native" cargo run --release --bin bench_prefetch
```

## Design Decisions

### Why No Software Prefetch?

A/B testing revealed that software prefetch **hurts** performance on AMD Zen 4:
- With prefetch: 0.52 B/s
- Without prefetch: 0.60 B/s (+15%)

Modern AMD cores have excellent hardware prefetchers for sequential access patterns.

### Conditional CPU Pinning

A/B testing showed pinning is situational:
- 1P1C with pinning: +30% improvement
- 4P4C with pinning: -41% regression

The scheduler does a better job for multi-producer scenarios.

### Batch Consumption

Instead of per-item `peek()` + `advance()`, we use `consume_batch()`:
- Single `head.store()` for entire batch
- Amortizes atomic overhead across N items
- Same approach as the LMAX Disruptor

## Dependencies

- `core_affinity` - CPU pinning
- `libc` - Low-level system calls

## License

Same as parent project.
