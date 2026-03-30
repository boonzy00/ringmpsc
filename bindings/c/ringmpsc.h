/*
 * RingMPSC - Lock-Free Multi-Producer Single-Consumer Channel
 *
 * A ring-decomposed MPSC implementation where each producer has a dedicated
 * SPSC ring buffer. This eliminates producer-producer contention entirely.
 *
 * Features:
 * - 128-byte alignment (cache line isolation)
 * - Batch consumption API (single head update for N items)
 * - Zero-copy reserve/commit API
 *
 * Usage:
 *   ring_t ring;
 *   ring_init(&ring);
 *
 *   // Producer
 *   uint64_t *slot = ring_reserve(&ring);
 *   if (slot) { *slot = value; ring_commit(&ring, 1); }
 *
 *   // Consumer
 *   ring_consume_batch(&ring, handler, ctx);
 */

#ifndef RINGMPSC_H
#define RINGMPSC_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Configuration */
#ifndef RING_BITS
#define RING_BITS 16
#endif

#define RING_CAPACITY (1ULL << RING_BITS)
#define RING_MASK     (RING_CAPACITY - 1)

#ifndef MAX_PRODUCERS
#define MAX_PRODUCERS 16
#endif

/* Cache line alignment */
#define CACHE_LINE 128

/* Aligned type wrapper */
#define ALIGNED(n) __attribute__((aligned(n)))

/*
 * SPSC Ring Buffer
 */
typedef struct ring {
    /* Producer hot path - 128-byte aligned */
    ALIGNED(CACHE_LINE) _Atomic uint64_t tail;
    uint64_t cached_head;

    /* Consumer hot path - separate cache line */
    ALIGNED(CACHE_LINE) _Atomic uint64_t head;
    uint64_t cached_tail;

    /* Cold state */
    ALIGNED(CACHE_LINE) _Atomic bool active;
    _Atomic bool closed;

    /* Data buffer - 64-byte aligned */
    ALIGNED(64) uint64_t buffer[RING_CAPACITY];
} ring_t;

/*
 * MPSC Channel (multiple producers, single consumer)
 */
typedef struct channel {
    ring_t rings[MAX_PRODUCERS];
    _Atomic size_t producer_count;
    _Atomic bool closed;
} channel_t;

/*
 * Producer handle
 */
typedef struct producer {
    ring_t *ring;
    size_t id;
} producer_t;

/* Batch handler callback */
typedef void (*consume_handler_t)(const uint64_t *item, void *ctx);

/*
 * Ring API
 */
static inline void ring_init(ring_t *r) {
    memset(r, 0, sizeof(*r));
}

static inline size_t ring_len(const ring_t *r) {
    uint64_t t = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint64_t h = atomic_load_explicit(&r->head, memory_order_relaxed);
    return (size_t)(t - h);
}

static inline bool ring_is_empty(const ring_t *r) {
    return ring_len(r) == 0;
}

static inline bool ring_is_full(const ring_t *r) {
    return ring_len(r) >= RING_CAPACITY;
}

static inline bool ring_is_closed(const ring_t *r) {
    return atomic_load_explicit(&r->closed, memory_order_acquire);
}

/*
 * Reserve a single slot for writing. Returns NULL if full.
 */
static inline uint64_t *ring_reserve(ring_t *r) {
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);

    /* Fast path: check cached head */
    uint64_t space = RING_CAPACITY - (tail - r->cached_head);
    if (space >= 1) {
        size_t idx = tail & RING_MASK;
        return &r->buffer[idx];
    }

    /* Slow path: refresh cache */
    r->cached_head = atomic_load_explicit(&r->head, memory_order_acquire);
    space = RING_CAPACITY - (tail - r->cached_head);
    if (space < 1) return NULL;

    size_t idx = tail & RING_MASK;
    return &r->buffer[idx];
}

/*
 * Reserve n slots for batch writing. Returns pointer to first slot, NULL if not enough space.
 * Note: Caller must handle wrap-around for contiguous access.
 */
static inline uint64_t *ring_reserve_n(ring_t *r, size_t n, size_t *out_contiguous) {
    if (n == 0 || n > RING_CAPACITY) return NULL;

    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);

    /* Fast path: check cached head */
    uint64_t space = RING_CAPACITY - (tail - r->cached_head);
    if (space < n) {
        /* Slow path: refresh cache */
        r->cached_head = atomic_load_explicit(&r->head, memory_order_acquire);
        space = RING_CAPACITY - (tail - r->cached_head);
        if (space < n) return NULL;
    }

    size_t idx = tail & RING_MASK;
    size_t contiguous = RING_CAPACITY - idx;
    if (contiguous > n) contiguous = n;

    if (out_contiguous) *out_contiguous = contiguous;
    return &r->buffer[idx];
}

/*
 * Commit n slots after writing
 */
static inline void ring_commit(ring_t *r, size_t n) {
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    atomic_store_explicit(&r->tail, tail + n, memory_order_release);
}

/*
 * Consume all available items with a single head update.
 * Returns number of items consumed.
 */
static inline size_t ring_consume_batch(ring_t *r, consume_handler_t handler, void *ctx) {
    uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);

    uint64_t avail = tail - head;
    if (avail == 0) return 0;

    uint64_t pos = head;
    size_t count = 0;

    while (pos != tail) {
        size_t idx = pos & RING_MASK;
        handler(&r->buffer[idx], ctx);
        pos++;
        count++;
    }

    /* Single atomic update for entire batch */
    atomic_store_explicit(&r->head, tail, memory_order_release);
    return count;
}

/*
 * Consume up to max_items items.
 */
static inline size_t ring_consume_up_to(ring_t *r, size_t max_items,
                                         consume_handler_t handler, void *ctx) {
    if (max_items == 0) return 0;

    uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);

    uint64_t avail = tail - head;
    if (avail == 0) return 0;

    size_t to_consume = avail < max_items ? (size_t)avail : max_items;
    uint64_t pos = head;
    size_t count = 0;

    while (count < to_consume) {
        size_t idx = pos & RING_MASK;
        handler(&r->buffer[idx], ctx);
        pos++;
        count++;
    }

    atomic_store_explicit(&r->head, head + count, memory_order_release);
    return count;
}

static inline void ring_close(ring_t *r) {
    atomic_store_explicit(&r->closed, true, memory_order_release);
}

/*
 * Channel API
 */
static inline void channel_init(channel_t *ch) {
    memset(ch, 0, sizeof(*ch));
    for (size_t i = 0; i < MAX_PRODUCERS; i++) {
        ring_init(&ch->rings[i]);
    }
}

static inline int channel_register(channel_t *ch, producer_t *out) {
    if (atomic_load_explicit(&ch->closed, memory_order_acquire)) {
        return -1; /* Closed */
    }

    size_t id = atomic_fetch_add_explicit(&ch->producer_count, 1, memory_order_relaxed);
    if (id >= MAX_PRODUCERS) {
        atomic_fetch_sub_explicit(&ch->producer_count, 1, memory_order_relaxed);
        return -2; /* Too many producers */
    }

    atomic_store_explicit(&ch->rings[id].active, true, memory_order_release);
    out->ring = &ch->rings[id];
    out->id = id;
    return 0;
}

static inline size_t channel_consume_all(channel_t *ch, consume_handler_t handler, void *ctx) {
    size_t total = 0;
    size_t count = atomic_load_explicit(&ch->producer_count, memory_order_acquire);
    for (size_t i = 0; i < count; i++) {
        total += ring_consume_batch(&ch->rings[i], handler, ctx);
    }
    return total;
}

static inline void channel_close(channel_t *ch) {
    atomic_store_explicit(&ch->closed, true, memory_order_release);
    size_t count = atomic_load_explicit(&ch->producer_count, memory_order_acquire);
    for (size_t i = 0; i < count; i++) {
        ring_close(&ch->rings[i]);
    }
}

static inline bool channel_is_closed(const channel_t *ch) {
    return atomic_load_explicit(&ch->closed, memory_order_acquire);
}

static inline size_t channel_producer_count(const channel_t *ch) {
    return atomic_load_explicit(&ch->producer_count, memory_order_acquire);
}

/*
 * Producer convenience functions
 */
static inline uint64_t *producer_reserve(producer_t *p) {
    return ring_reserve(p->ring);
}

static inline void producer_commit(producer_t *p, size_t n) {
    ring_commit(p->ring, n);
}

static inline bool producer_send(producer_t *p, uint64_t value) {
    uint64_t *slot = ring_reserve(p->ring);
    if (!slot) return false;
    *slot = value;
    ring_commit(p->ring, 1);
    return true;
}

#ifdef __cplusplus
}
#endif

#endif /* RINGMPSC_H */
