#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# L1: Dual-Backend Memory Mapping Verification
#
# Creates two files (fdA=0xAA, fdB=0xBB) and verifies:
#   1. Single backend with fdA  -> entire memory = 0xAA
#   2. Single backend with fdB  -> entire memory = 0xBB
#   3. Dual backend [0..half->fdA, half..end->fdB] -> first half=0xAA, second half=0xBB
#   4. Dual backend [0..half->fdB, half..end->fdA] -> first half=0xBB, second half=0xAA
#   5. Dual backend alternating 4MB blocks [A,B,A,B,...]
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKDIR="/tmp/l1_test"
VERIFY="$SCRIPT_DIR/verify_mem.py"

FC_BIN="${FC_BIN:-$FC_ROOT/build/cargo_target/aarch64-unknown-linux-gnu/debug/firecracker}"
KERNEL="${KERNEL:-$FC_ROOT/vmlinux}"
INITRD="${INITRD:-/tmp/initrd.cpio.gz}"

MEM_MIB=128
MEM_SIZE=$((MEM_MIB * 1024 * 1024))
HALF=$((MEM_SIZE / 2))
BLOCK=$((4 * 1024 * 1024))

PASS_COUNT=0
FAIL_COUNT=0

ok()   { echo "  PASS $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

start_fc() {
    local sock="$1"
    local log="$2"
    "$FC_BIN" --api-sock "$sock" --no-seccomp > "$log" 2>&1 &
    local pid=$!
    sleep 1
    echo "$pid"
}

stop_fc() {
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

verify() {
    local dump="$1"
    local offset="$2"
    local size="$3"
    local pattern="$4"
    local label="$5"
    if python3 "$VERIFY" "$dump" "$offset" "$size" "$pattern" "$label"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ── Phase 0: Prepare ──

echo ""
echo "=========================================="
echo "L1: Dual-Backend Memory Mapping Test"
echo "=========================================="
echo ""

mkdir -p "$WORKDIR"
rm -f "$WORKDIR"/*.bin "$WORKDIR"/*.sock "$WORKDIR"/*.log

if [ ! -x "$FC_BIN" ]; then
    echo "Firecracker binary not found: $FC_BIN"
    exit 1
fi
if [ ! -f "$KERNEL" ]; then
    echo "Kernel not found: $KERNEL"
    exit 1
fi
if [ ! -f "$INITRD" ]; then
    echo "Initrd not found: $INITRD"
    exit 1
fi

echo "Config:"
echo "  FC_BIN:   $FC_BIN"
echo "  KERNEL:   $KERNEL"
echo "  INITRD:   $INITRD"
echo "  MEM:      ${MEM_MIB}MB"
echo "  SPLIT:    ${HALF} bytes"
echo "  FC version: $("$FC_BIN" --version 2>&1 | head -1)"
echo ""

# ── Phase 1: Create synthetic backend files ──

echo "== Phase 1: Creating synthetic backend files =="
echo "  Creating fdA (all 0xAA)..."
python3 -c "
size = $MEM_SIZE
chunk = 1024 * 1024
with open('$WORKDIR/fdA.bin', 'wb') as f:
    w = 0
    while w < size:
        n = min(chunk, size - w)
        f.write(b'\xAA' * n)
        w += n
print(f'  fdA: {size} bytes')
"

echo "  Creating fdB (all 0xBB)..."
python3 -c "
size = $MEM_SIZE
chunk = 1024 * 1024
with open('$WORKDIR/fdB.bin', 'wb') as f:
    w = 0
    while w < size:
        n = min(chunk, size - w)
        f.write(b'\xBB' * n)
        w += n
print(f'  fdB: {size} bytes')
"

# ── Phase 2: Create baseline snapshot ──

echo ""
echo "== Phase 2: Creating baseline snapshot =="
echo "  Starting Firecracker..."
PID=$(start_fc "$WORKDIR/fc0.sock" "$WORKDIR/fc0.log")

echo "  Configuring VM..."
curl -s --unix-socket "$WORKDIR/fc0.sock" -X PUT "http://localhost/boot-source" \
    -H "Content-Type: application/json" \
    -d "{\"kernel_image_path\": \"$KERNEL\", \"initrd_path\": \"$INITRD\", \"boot_args\": \"console=ttyS0 reboot=k panic=-1 rdinit=/init\"}" > /dev/null

curl -s --unix-socket "$WORKDIR/fc0.sock" -X PUT "http://localhost/machine-config" \
    -H "Content-Type: application/json" \
    -d "{\"vcpu_count\": 1, \"mem_size_mib\": $MEM_MIB}" > /dev/null

echo "  Starting VM..."
curl -s --unix-socket "$WORKDIR/fc0.sock" -X PUT "http://localhost/actions" \
    -H "Content-Type: application/json" \
    -d '{"action_type": "InstanceStart"}' > /dev/null

sleep 3

echo "  Pausing VM..."
curl -s --unix-socket "$WORKDIR/fc0.sock" -X PATCH "http://localhost/vm" \
    -H "Content-Type: application/json" \
    -d '{"state": "Paused"}' > /dev/null

echo "  Creating snapshot..."
curl -s --unix-socket "$WORKDIR/fc0.sock" -X PUT "http://localhost/snapshot/create" \
    -H "Content-Type: application/json" \
    -d "{\"snapshot_path\": \"$WORKDIR/vm_state.bin\", \"mem_file_path\": \"$WORKDIR/mem_orig.bin\", \"snapshot_type\": \"Full\"}" > /dev/null

stop_fc "$PID"

if [ ! -f "$WORKDIR/vm_state.bin" ]; then
    echo "  FAIL: Snapshot creation failed"
    cat "$WORKDIR/fc0.log" | tail -20
    exit 1
fi
echo "  Baseline snapshot created"

VM_STATE="$WORKDIR/vm_state.bin"

# ── Helper: load snapshot and dump memory ──

load_and_dump() {
    local sock="$1"
    local mem_backend_json="$2"
    local dump_mem="$3"
    local dump_state="$4"
    local resume="${5:-false}"

    local resp
    resp=$(curl -s --unix-socket "$sock" -X PUT "http://localhost/snapshot/load" \
        -H "Content-Type: application/json" \
        -d "{\"snapshot_path\": \"$VM_STATE\", \"mem_backend\": $mem_backend_json, \"resume_vm\": $resume}" 2>&1)

    if echo "$resp" | grep -qi "error"; then
        echo "  LoadSnapshot error: $resp"
        return 1
    fi

    if [ "$resume" = "true" ]; then
        sleep 1
        curl -s --unix-socket "$sock" -X PATCH "http://localhost/vm" \
            -H "Content-Type: application/json" \
            -d '{"state": "Paused"}' > /dev/null 2>&1 || true
    fi

    curl -s --unix-socket "$sock" -X PUT "http://localhost/snapshot/create" \
        -H "Content-Type: application/json" \
        -d "{\"snapshot_path\": \"$dump_state\", \"mem_file_path\": \"$dump_mem\", \"snapshot_type\": \"Full\"}" > /dev/null 2>&1

    if [ -f "$dump_mem" ]; then
        return 0
    else
        echo "  Dump file not created"
        return 1
    fi
}

# ── Phase 3: Single backend tests ──

echo ""
echo "== Phase 3: Single backend tests =="

# 3a: fdA -> all 0xAA
echo ""
echo "[3a] Single backend = fdA (0xAA)"
PID=$(start_fc "$WORKDIR/fc1a.sock" "$WORKDIR/fc1a.log")
SINGLE_A="{\"backend_type\": \"File\", \"backend_path\": \"$WORKDIR/fdA.bin\"}"
if load_and_dump "$WORKDIR/fc1a.sock" "$SINGLE_A" "$WORKDIR/dump_3a.bin" "$WORKDIR/dump_3a_state.bin"; then
    verify "$WORKDIR/dump_3a.bin" 0 "$MEM_SIZE" "AA" "Single-fdA entire range"
else
    fail "3a: load_and_dump failed"
fi
stop_fc "$PID"

# 3b: fdB -> all 0xBB
echo ""
echo "[3b] Single backend = fdB (0xBB)"
PID=$(start_fc "$WORKDIR/fc1b.sock" "$WORKDIR/fc1b.log")
SINGLE_B="{\"backend_type\": \"File\", \"backend_path\": \"$WORKDIR/fdB.bin\"}"
if load_and_dump "$WORKDIR/fc1b.sock" "$SINGLE_B" "$WORKDIR/dump_3b.bin" "$WORKDIR/dump_3b_state.bin"; then
    verify "$WORKDIR/dump_3b.bin" 0 "$MEM_SIZE" "BB" "Single-fdB entire range"
else
    fail "3b: load_and_dump failed"
fi
stop_fc "$PID"

# ── Phase 4: Dual backend tests ──

echo ""
echo "== Phase 4: Dual backend tests =="

# 4a: first half->fdA, second half->fdB
echo ""
echo "[4a] Dual: first half->fdA(0xAA), second half->fdB(0xBB)"
PID=$(start_fc "$WORKDIR/fc2a.sock" "$WORKDIR/fc2a.log")
DUAL_AB="{\"backend_type\": \"File\", \"backend_path\": \"$WORKDIR/fdA.bin\", \"region_backends\": [{\"file_offset\": 0, \"size\": $HALF, \"backend_path\": \"$WORKDIR/fdA.bin\"}, {\"file_offset\": $HALF, \"size\": $HALF, \"backend_path\": \"$WORKDIR/fdB.bin\"}]}"
if load_and_dump "$WORKDIR/fc2a.sock" "$DUAL_AB" "$WORKDIR/dump_4a.bin" "$WORKDIR/dump_4a_state.bin"; then
    verify "$WORKDIR/dump_4a.bin" 0 "$HALF" "AA" "Dual-AB first half (fdA)"
    verify "$WORKDIR/dump_4a.bin" "$HALF" "$HALF" "BB" "Dual-AB second half (fdB)"
else
    fail "4a: load_and_dump failed"
fi
stop_fc "$PID"

# 4b: first half->fdB, second half->fdA (swapped)
echo ""
echo "[4b] Dual: first half->fdB(0xBB), second half->fdA(0xAA) [swapped]"
PID=$(start_fc "$WORKDIR/fc2b.sock" "$WORKDIR/fc2b.log")
DUAL_BA="{\"backend_type\": \"File\", \"backend_path\": \"$WORKDIR/fdB.bin\", \"region_backends\": [{\"file_offset\": 0, \"size\": $HALF, \"backend_path\": \"$WORKDIR/fdB.bin\"}, {\"file_offset\": $HALF, \"size\": $HALF, \"backend_path\": \"$WORKDIR/fdA.bin\"}]}"
if load_and_dump "$WORKDIR/fc2b.sock" "$DUAL_BA" "$WORKDIR/dump_4b.bin" "$WORKDIR/dump_4b_state.bin"; then
    verify "$WORKDIR/dump_4b.bin" 0 "$HALF" "BB" "Dual-BA first half (fdB)"
    verify "$WORKDIR/dump_4b.bin" "$HALF" "$HALF" "AA" "Dual-BA second half (fdA)"
else
    fail "4b: load_and_dump failed"
fi
stop_fc "$PID"

# 4c: alternating 4MB blocks [A,B,A,B,...]
echo ""
echo "[4c] Dual: alternating 4MB blocks [A,B,A,B,...]"
PID=$(start_fc "$WORKDIR/fc2c.sock" "$WORKDIR/fc2c.log")

NUM_BLOCKS=$((MEM_SIZE / BLOCK))
RBS="["
for i in $(seq 0 $((NUM_BLOCKS - 1))); do
    off=$((i * BLOCK))
    if [ $((i % 2)) -eq 0 ]; then
        path="$WORKDIR/fdA.bin"
    else
        path="$WORKDIR/fdB.bin"
    fi
    [ $i -gt 0 ] && RBS+=","
    RBS+="{\"file_offset\": $off, \"size\": $BLOCK, \"backend_path\": \"$path\"}"
done
RBS+="]"

DUAL_ALT="{\"backend_type\": \"File\", \"backend_path\": \"$WORKDIR/fdA.bin\", \"region_backends\": $RBS}"
if load_and_dump "$WORKDIR/fc2c.sock" "$DUAL_ALT" "$WORKDIR/dump_4c.bin" "$WORKDIR/dump_4c_state.bin"; then
    for i in $(seq 0 $((NUM_BLOCKS - 1))); do
        off=$((i * BLOCK))
        if [ $((i % 2)) -eq 0 ]; then
            pat="AA"
        else
            pat="BB"
        fi
        verify "$WORKDIR/dump_4c.bin" "$off" "$BLOCK" "$pat" "Block $i at offset $off"
    done
else
    fail "4c: load_and_dump failed"
fi
stop_fc "$PID"

# ── Summary ──

echo ""
echo "=========================================="
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi
echo "=========================================="
echo ""

exit $FAIL_COUNT
