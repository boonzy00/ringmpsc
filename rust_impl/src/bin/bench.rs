use rust_impl::stack_ring::StackRing;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

const MSG: u64 = 500_000_000; // 500M messages per producer
const BATCH: usize = 32768; // Batch size for amortizing atomic ops
const RING_SIZE: usize = 1 << 16; // 64K slots

fn main() {
    println!();
    println!("═══════════════════════════════════════════════════════════════════════════════");
    println!("║                       RINGMPSC - RUST BENCHMARK                             ║");
    println!("═══════════════════════════════════════════════════════════════════════════════");
    println!(
        "Config:   {}M msgs/producer, batch={}K, ring={}K slots",
        MSG / 1_000_000,
        BATCH / 1024,
        RING_SIZE >> 10
    );

    println!();
    println!("┌─────────────────────────────────────────────────────────────┐");
    println!("│ STACK RING (embedded buffer, zero heap indirection)        │");
    println!("├─────────────┬───────────────┬─────────┐");
    println!("│ Config      │ Throughput    │ Status  │");
    println!("├─────────────┼───────────────┼─────────┤");

    // Warmup
    let _ = run_test(4, false);

    let counts = [1, 2, 4, 6, 8];
    for p in counts {
        // Pin only for 1P1C (A/B test showed improvement)
        let use_pinning = p == 1;
        let rate = run_test(p, use_pinning);
        let status = if rate >= 5.0 {
            "✓ PASS"
        } else if rate >= 2.0 {
            "○ OK  "
        } else {
            "✗ LOW "
        };
        println!("│ {}P{}C        │ {:>8.2} B/s  │ {} │", p, p, rate, status);
    }

    println!("└─────────────┴───────────────┴─────────┘");
    println!("\nB/s = billion messages per second");
    println!("═══════════════════════════════════════════════════════════════════════════════\n");
}

/// Run NP NC test using N StackRings (one per producer-consumer pair)
fn run_test(num_pairs: usize, use_pinning: bool) -> f64 {
    // Allocate rings - one per producer/consumer pair
    let rings: Vec<&'static StackRing<u32, RING_SIZE>> = (0..num_pairs)
        .map(|_| &*Box::leak(Box::new(StackRing::new())))
        .collect();

    let counts: Arc<Vec<AtomicU64>> = Arc::new((0..num_pairs).map(|_| AtomicU64::new(0)).collect());

    let t0 = Instant::now();

    // Start consumers
    let mut consumer_threads = Vec::with_capacity(num_pairs);
    for i in 0..num_pairs {
        let ring = rings[i];
        let counts_clone = counts.clone();
        let cpu_id = num_pairs + i;
        consumer_threads.push(thread::spawn(move || {
            if use_pinning {
                pin_to_cpu(cpu_id);
            }
            let mut count = 0u64;
            loop {
                unsafe {
                    let n = ring.consume_batch(|_| {});
                    if n > 0 {
                        count += n as u64;
                    } else if ring.is_closed() && ring.is_empty() {
                        break;
                    } else {
                        std::hint::spin_loop();
                    }
                }
            }
            counts_clone[i].store(count, Ordering::Release);
        }));
    }

    // Start producers
    let mut producer_threads = Vec::with_capacity(num_pairs);
    for i in 0..num_pairs {
        let ring = rings[i];
        producer_threads.push(thread::spawn(move || {
            if use_pinning {
                pin_to_cpu(i);
            }
            let mut sent = 0u64;
            while sent < MSG {
                let want = (BATCH as u64).min(MSG - sent) as usize;
                unsafe {
                    if let Some((ptr, len)) = ring.reserve(want) {
                        for j in 0..len {
                            *ptr.add(j) = (sent + j as u64) as u32;
                        }
                        ring.commit(len);
                        sent += len as u64;
                    } else {
                        std::hint::spin_loop();
                    }
                }
            }
            ring.close();
        }));
    }

    // Wait for all threads
    for t in producer_threads {
        t.join().unwrap();
    }
    for t in consumer_threads {
        t.join().unwrap();
    }

    let elapsed = t0.elapsed();
    let ns = elapsed.as_nanos() as f64;

    let total: u64 = counts.iter().map(|c| c.load(Ordering::Acquire)).sum();
    total as f64 / ns
}

fn pin_to_cpu(cpu_id: usize) {
    if let Some(core_ids) = core_affinity::get_core_ids() {
        if cpu_id < core_ids.len() {
            core_affinity::set_for_current(core_ids[cpu_id]);
        }
    }
}
