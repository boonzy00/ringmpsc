#!/bin/bash
# Multi-run benchmark with statistical reporting
# Usage: ./scripts/bench-multirun.sh [runs] [binary]
#   runs:   number of runs (default: 7)
#   binary: benchmark binary (default: bench-high-perf)

set -e

RUNS=${1:-7}
BINARY=${2:-bench-high-perf}
BIN_PATH="zig-out/bin/$BINARY"

if [ ! -f "$BIN_PATH" ]; then
    echo "Building $BINARY..."
    zig build -Doptimize=ReleaseFast
fi

if [ ! -f "$BIN_PATH" ]; then
    echo "Error: $BIN_PATH not found"
    exit 1
fi

echo ""
echo "ringmpsc multi-run benchmark"
echo "  binary: $BINARY"
echo "  runs:   $RUNS"
echo "  cooldown: 3s between runs"
echo ""

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

for i in $(seq 1 $RUNS); do
    echo "Run $i/$RUNS..."
    if [ "$EUID" -eq 0 ] || command -v sudo &>/dev/null; then
        taskset -c 0-15 nice -n -20 "$BIN_PATH" > "$TMPDIR/run_$i.txt" 2>&1 || \
        "$BIN_PATH" > "$TMPDIR/run_$i.txt" 2>&1
    else
        "$BIN_PATH" > "$TMPDIR/run_$i.txt" 2>&1
    fi
    if [ $i -lt $RUNS ]; then
        sleep 3
    fi
done

echo ""
echo "=== Results across $RUNS runs ==="
echo ""

# Extract 8P1C u32 batch throughput from each run
echo "8P1C u32 batch throughput (B/s):"
values=()
for i in $(seq 1 $RUNS); do
    val=$(grep -oP '8P1C\s+\K[\d.]+(?=\s*B/s)' "$TMPDIR/run_$i.txt" | head -1)
    if [ -n "$val" ]; then
        values+=("$val")
        printf "  Run %d: %s B/s\n" "$i" "$val"
    fi
done

if [ ${#values[@]} -gt 0 ]; then
    echo ""
    # Sort and compute stats using awk
    sorted=($(printf '%s\n' "${values[@]}" | sort -n))
    n=${#sorted[@]}
    mid=$((n / 2))

    echo "  Median: ${sorted[$mid]} B/s"
    echo "  Min:    ${sorted[0]} B/s"
    echo "  Max:    ${sorted[$((n-1))]} B/s"

    # Compute mean and stddev
    echo "${values[@]}" | tr ' ' '\n' | awk '
    {
        sum += $1
        sumsq += $1 * $1
        n++
    }
    END {
        mean = sum / n
        variance = sumsq / n - mean * mean
        if (variance < 0) variance = 0
        stddev = sqrt(variance)
        printf "  Mean:   %.1f B/s\n", mean
        printf "  Stddev: %.1f B/s (±%.1f%%)\n", stddev, (stddev/mean)*100
    }'
fi

echo ""
echo "Full output from last run:"
echo "---"
cat "$TMPDIR/run_$RUNS.txt"
