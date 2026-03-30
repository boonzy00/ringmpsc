# Language Bindings

Native implementations of the RingMPSC algorithm in other languages.

These are **not** FFI wrappers around the Zig library — they are standalone re-implementations of the same ring-decomposed SPSC/MPSC design. For a lock-free ring buffer, native implementations in each language outperform cross-language FFI.

## C

Single-header library in [`c/ringmpsc.h`](c/ringmpsc.h). Drop into any C/C++ project.

```c
#include "ringmpsc.h"

ring_t ring;
ring_init(&ring);

// Producer: zero-copy reserve/commit
uint64_t *slot = ring_reserve(&ring);
if (slot) { *slot = value; ring_commit(&ring, 1); }

// Consumer: batch consume
ring_consume_batch(&ring, handler, ctx);
```

## Rust

Full Rust port in [`rust/`](rust/).

```bash
cd bindings/rust
cargo build --release
```

## Adding a New Binding

To add a binding for another language:

1. Create a directory under `bindings/` (e.g., `bindings/go/`)
2. Implement the core SPSC ring with 128-byte aligned head/tail, cached sequence numbers, and batch consumption
3. Add a benchmark that matches the methodology in `docs/methodology.md`
4. Add a README with usage examples
