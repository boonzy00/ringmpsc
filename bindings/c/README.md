# C Implementation

Header-only lock-free MPSC ring buffer. Same algorithm as the Zig implementation.

## Build & Run

```bash
# Benchmark
gcc -O3 -march=native -pthread bench.c -o bench
./bench

# With clang
clang -O3 -march=native -pthread bench.c -o bench
./bench
```

## Usage

```c
#include "ringmpsc.h"

// Single ring (SPSC)
ring_t ring;
ring_init(&ring);

// Producer
uint64_t *slot = ring_reserve(&ring);
if (slot) {
    *slot = 42;
    ring_commit(&ring, 1);
}

// Consumer (batch)
void handler(const uint64_t *item, void *ctx) {
    printf("Got: %llu\n", *item);
}
ring_consume_batch(&ring, handler, NULL);
```

### Multi-Producer Channel

```c
channel_t channel;
channel_init(&channel);

// Register producers (thread-safe)
producer_t p1, p2;
channel_register(&channel, &p1);
channel_register(&channel, &p2);

// Producers send
producer_send(&p1, 100);
producer_send(&p2, 200);

// Consumer drains all
channel_consume_all(&channel, handler, NULL);
```

## Configuration

Override at compile time:

```bash
gcc -DRING_BITS=12 -DMAX_PRODUCERS=32 -O3 bench.c -o bench
```

- `RING_BITS`: Log2 of ring capacity (default: 16 = 64K slots)
- `MAX_PRODUCERS`: Maximum number of producers (default: 16)

## License

Same as parent project.
