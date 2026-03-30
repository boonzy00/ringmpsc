#!/bin/bash
# RingMPSC - Verification Script
# Builds, runs all tests, validates examples, and benchmarks.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Ensure zig is in PATH (zvm installs to user home)
if ! command -v zig &> /dev/null; then
    for p in "$HOME/.zvm"/*/zig /home/*/.zvm/*/zig; do
        if [ -x "$p" ]; then
            export PATH="$(dirname "$p"):$PATH"
            break
        fi
    done
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0

run_step() {
    local name="$1"
    local cmd="$2"
    echo -ne "  ${name}... "
    if eval "$cmd" > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC}"
        FAIL=$((FAIL + 1))
    fi
}

echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}║                       RINGMPSC - VERIFICATION SUITE                        ║${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# Build
echo -e "${YELLOW}[1/5] Build${NC}"
run_step "ReleaseFast build" "zig build -Doptimize=ReleaseFast"
echo ""

# Unit tests
echo -e "${YELLOW}[2/5] Unit Tests${NC}"
run_step "zig build test (all modules)" "zig build test"
echo ""

# Integration tests
echo -e "${YELLOW}[3/5] Integration Tests${NC}"
run_step "SPSC"          "zig build test-spsc"
run_step "MPSC"          "zig build test-mpsc"
run_step "FIFO ordering" "zig build test-fifo"
run_step "Chaos"         "zig build test-chaos"
run_step "Determinism"   "zig build test-determinism"
run_step "Blocking API"  "zig build test-blocking"
run_step "MPMC"          "zig build test-mpmc"
run_step "SPMC"          "zig build test-spmc"
run_step "SIMD"          "zig build test-simd"
run_step "Fuzz"          "zig build test-fuzz"
run_step "Stress"        "zig build test-stress"
echo ""

# Examples
echo -e "${YELLOW}[4/5] Examples${NC}"
run_step "Basic SPSC"         "zig build example-basic"
run_step "MPSC pipeline"      "zig build example-mpsc"
run_step "Backpressure"       "zig build example-backpressure"
run_step "Graceful shutdown"  "zig build example-shutdown"
run_step "Event loop"         "zig build example-event-loop"
echo ""

# Benchmark
echo -e "${YELLOW}[5/5] Benchmark${NC}"
echo ""
if [ "$EUID" -eq 0 ]; then
    echo -e "  ${BLUE}Running with CPU isolation (taskset + nice -20)${NC}"
    taskset -c 0-15 nice -n -20 zig-out/bin/bench-high-perf 2>&1
    BENCH_RC=$?
else
    echo -e "  ${YELLOW}Tip: sudo ./scripts/verify.sh for optimal benchmark results${NC}"
    echo ""
    zig-out/bin/bench-high-perf 2>&1
    BENCH_RC=$?
fi
if [ $BENCH_RC -eq 0 ]; then
    echo -e "  Benchmark... ${GREEN}PASS${NC}"
    PASS=$((PASS + 1))
else
    echo -e "  Benchmark... ${RED}FAIL${NC} (exit code $BENCH_RC)"
    FAIL=$((FAIL + 1))
fi
echo ""

# Summary
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}  ALL $PASS CHECKS PASSED${NC}"
else
    echo -e "${RED}  $FAIL FAILED, $PASS PASSED${NC}"
fi
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"

[ $FAIL -eq 0 ] || exit 1
