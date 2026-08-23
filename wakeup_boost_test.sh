#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
MODULE_BUILD_DIR="$SCRIPT_DIR/.build/module"
WORKLOAD_BUILD_DIR="$SCRIPT_DIR/.build/workloads"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/.build/results}"
BEFORE_OUTPUT="$RESULTS_DIR/before_output.txt"
AFTER_OUTPUT="$RESULTS_DIR/after_output.txt"
GRAPH_DATA_FILE="$RESULTS_DIR/results.dat"
GRAPH_FILE="$RESULTS_DIR/benchmark_comparison.png"
HOST_CPUS="${HOST_CPUS:-2,3}"
FORK_COUNTS="${FORK_COUNTS:-6}"
MAIN_ITERATIONS="${MAIN_ITERATIONS:-3}"
CALLING_USER="${SUDO_USER:-}"
CALLING_UID="${SUDO_UID:-}"
CALLING_GID="${SUDO_GID:-}"
cd "$SCRIPT_DIR"

if [ "$EUID" -ne 0 ]; then
    echo "Error: run the complete benchmark with sudo; chrt requires real-time scheduling privileges."
    exit 1
fi

if ! [[ "$MAIN_ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: MAIN_ITERATIONS must be a positive integer."
    exit 1
fi

for forks in $FORK_COUNTS; do
    if ! [[ "$forks" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: every FORK_COUNTS value must be a positive integer."
        exit 1
    fi
done

# Check directories
for dir in "$SCRIPT_DIR/linux-6.13.9" "$SCRIPT_DIR/busybox-1.36.1" "$SCRIPT_DIR/patches" "$SCRIPT_DIR/C_files"; do
    if [ ! -d "$dir" ]; then
        echo "Error: Directory $dir not found!"
        if [ "$dir" = "$SCRIPT_DIR/linux-6.13.9" ]; then
            echo "Run ./prepare_kernel.sh to download and verify Linux 6.13.9."
        fi
        exit 1
    fi
done

mkdir -p "$RESULTS_DIR" "$WORKLOAD_BUILD_DIR"
ROOTFS_ONLY=1 "$SCRIPT_DIR/build_embedded_linux.sh"

# Creating executable files
echo "Compiling cpu_load, io_load, kill_cpu_loads"
for forks in $FORK_COUNTS; do
    echo "  - Compiling cpu_load for $forks children..."
    arm-linux-gnueabi-gcc -static -DNUM_CHILDREN=$forks "$SCRIPT_DIR/C_files/cpu_load.c" -o "$WORKLOAD_BUILD_DIR/cpu_load_$forks" -lm
done
arm-linux-gnueabi-gcc -static "$SCRIPT_DIR/C_files/kill_cpu_loads.c" -o "$WORKLOAD_BUILD_DIR/kill_cpu_loads"
arm-linux-gnueabi-gcc -static "$SCRIPT_DIR/C_files/io_load.c" -o "$WORKLOAD_BUILD_DIR/io_load"



# Copy executables into rootfs/bin
for forks in $FORK_COUNTS; do
    cp "$WORKLOAD_BUILD_DIR/cpu_load_$forks" "$SCRIPT_DIR/rootfs/bin/"
done
cp "$WORKLOAD_BUILD_DIR/io_load" "$SCRIPT_DIR/rootfs/bin/"
cp "$WORKLOAD_BUILD_DIR/kill_cpu_loads" "$SCRIPT_DIR/rootfs/bin/"


#Creating the tmp directory
mkdir -p "$SCRIPT_DIR/rootfs/tmp"


# Determine patches to apply
if [ "$#" -eq 1 ]; then
    PATCH_FILE="$SCRIPT_DIR/patches/$1"
    if [ ! -f "$PATCH_FILE" ]; then
        echo "Error: Specified patch file $PATCH_FILE not found!"
        exit 1
    fi
else
    echo "Error: exactly one patch filename is required."
    exit 1
fi

# A normal git apply is atomic. Check the complete patch before the long run,
# and refuse to start if the local source is not in the expected vanilla state.
if ! git -C "$SCRIPT_DIR" apply --check "$PATCH_FILE"; then
    if git -C "$SCRIPT_DIR" apply --reverse --check "$PATCH_FILE"; then
        echo "Error: the wakeup boost patch is already applied to linux-6.13.9."
        echo "Reverse it or extract a fresh source tree before starting the benchmark."
    else
        echo "Error: the patch does not apply cleanly to the local Linux 6.13.9 source."
    fi
    exit 1
fi

PATCH_APPLIED=0
restore_user_ownership() {
    if [[ "$CALLING_UID" =~ ^[0-9]+$ ]] && [[ "$CALLING_GID" =~ ^[0-9]+$ ]]; then
        chown -R "$CALLING_UID:$CALLING_GID" \
            "$SCRIPT_DIR/.build" "$SCRIPT_DIR/rootfs" "$SCRIPT_DIR/linux-6.13.9"
    fi
}

restore_kernel_source() {
    original_status=$?
    restore_failed=0
    trap - EXIT

    if [ "$PATCH_APPLIED" -eq 1 ]; then
        echo "Restoring the vanilla Linux 6.13.9 source..."
        if git -C "$SCRIPT_DIR" apply --reverse --check "$PATCH_FILE"; then
            git -C "$SCRIPT_DIR" apply --reverse "$PATCH_FILE"
            PATCH_APPLIED=0
            echo "The benchmark patch was reversed successfully."
        else
            echo "Error: the benchmark finished, but the patch could not be reversed automatically."
            restore_failed=1
        fi
    fi

    restore_user_ownership
    if [ "$restore_failed" -eq 1 ]; then
        exit 1
    fi
    exit "$original_status"
}
trap restore_kernel_source EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


# Add benchmark script in rootfs
BENCH_SCRIPT="$SCRIPT_DIR/rootfs/bench.sh"
BENCH_CONFIG="$SCRIPT_DIR/rootfs/benchmark.conf"
printf "FORK_COUNTS='%s'\nMAIN_ITERATIONS='%s'\n" "$FORK_COUNTS" "$MAIN_ITERATIONS" > "$BENCH_CONFIG"
cat > "$BENCH_SCRIPT" << 'EOF'
#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

. /benchmark.conf

# Create mount point directories
mkdir -p /proc /sys /dev /tmp

# Mount filesystems
mount -t proc proc /proc || true
mount -t sysfs sysfs /sys || true
mount -t devtmpfs devtmpfs /dev || true  # Explicitly mount /dev for initramfs
mount -t tmpfs tmpfs /tmp || true

sleep 10

echo "Starting benchmark..."

run_test_scenario(){
    echo 0 > /proc/sys/kernel/randomize_va_space
    echo 1 > /proc/sys/kernel/sched_schedstats

    local cpu_load_prog=$1
    local num_children=$2
    
    echo ""
    echo "-----------------------------------------------------"
    echo "Starting test scenario with $num_children CPU children"
    echo "-----------------------------------------------------"

    # Pin both workloads to vCPU 1: sharing one runqueue creates contention.
    taskset -c 1 "$cpu_load_prog"

    RESULTS_FILE="/tmp/results.txt"
    rm -f "$RESULTS_FILE"

    echo "Starting benchmark with $MAIN_ITERATIONS main iterations..."
    echo "I/O task will be pinned to vCPU 1."

    for iter in $(seq 1 $MAIN_ITERATIONS); do
        insmod /bin/mychardev.ko sleep_us=2000
        
        # Run io_load pinned to vCPU 1 and append its output to a file
        # This is much lower overhead than calling awk in a loop
        taskset -c 1 /bin/io_load >> "$RESULTS_FILE"
        
        rmmod mychardev
    done

    # Process all results at once with a single awk command
    AVERAGE_WAIT_SUM=$(awk '/TOTAL_WAIT_SUM/ {sum+=$2; count++} END {if (count>0) print sum/count; else print "N/A"}' "$RESULTS_FILE")
    
    echo "Main Iterations complete. Results from $RESULTS_FILE:"
    cat "$RESULTS_FILE"

    echo "AVERAGE_IO_TASK_WAIT_SUM_${num_children}_CHILDREN: $AVERAGE_WAIT_SUM"

    /bin/kill_cpu_loads
}

# --- Main script execution ---
echo "Starting multi-scenario benchmark..."

for forks in $FORK_COUNTS; do
    run_test_scenario /bin/cpu_load_$forks $forks
done

echo "All Benchmarks complete."
poweroff -f

EOF
chmod +x "$BENCH_SCRIPT"
ln -sf /bench.sh "$SCRIPT_DIR/rootfs/init"

# Function to recreate initramfs
recreate_initramfs() {
    cd "$SCRIPT_DIR/rootfs"
    rm -f rootfs.cpio.gz
    find . -path ./rootfs.cpio.gz -prune -o -print0 | cpio --null -ov --format=newc | gzip -9 > rootfs.cpio.gz
    cd "$SCRIPT_DIR"
}

# Build outside rootfs so compiler metadata and intermediate files are never
# copied into the initramfs. Prefix maps also keep the local checkout path out
# of the module's debug information.
build_test_module() {
    mkdir -p "$MODULE_BUILD_DIR"
    cp "$SCRIPT_DIR/C_files/mychardev.c" "$MODULE_BUILD_DIR/"
    cp "$SCRIPT_DIR/C_files/Makefile" "$MODULE_BUILD_DIR/"
    make -C "$SCRIPT_DIR/linux-6.13.9" \
      M="$MODULE_BUILD_DIR" \
      ARCH=arm \
      CROSS_COMPILE=arm-linux-gnueabi- \
      KCFLAGS="-fdebug-prefix-map=$SCRIPT_DIR=." \
      modules
    cp "$MODULE_BUILD_DIR/mychardev.ko" "$SCRIPT_DIR/rootfs/bin/"
}

# Function to compile kernel
compile_kernel() {
    cd "$SCRIPT_DIR/linux-6.13.9"
    
    rm -f .config  # Clean previous config
    echo "Generating default config for Vexpress A9..."
    make vexpress_defconfig ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
    make olddefconfig ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
    
    echo "Enabling necessary configs for devtmpfs, proc, sysfs"
    scripts/config -e TMPFS
    scripts/config -e DEVTMPFS
    scripts/config -e DEVTMPFS_MOUNT
    scripts/config -e PROC_FS
    scripts/config -e SYSFS
    scripts/config -e HZ_1000
    scripts/config -e HIGH_RES_TIMERS
    scripts/config -e DEBUG_KERNEL
    scripts/config -e DEBUG_FS
    scripts/config -e SCHEDSTATS
    scripts/config -d PREEMPT_RT
    scripts/config -e SCHED_DEBUG
    scripts/config --set-val NR_CPUS 2
    scripts/config -d PREEMPT_NONE
    scripts/config -d PREEMPT_VOLUNTARY
    scripts/config -e PREEMPT # Enable Full Preemption
    make olddefconfig ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
    make -j"$(nproc)" ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-
    cd "$SCRIPT_DIR"
}

# Function to run QEMU and capture output
run_qemu_capture() {
    local output_file=$1
    # Pin to host CPUs 2,3, use 2 emulated CPUs for contention
    chrt -r 99 taskset -c "$HOST_CPUS" qemu-system-arm -M vexpress-a9 -m 256M -smp 2 \
      -kernel "$SCRIPT_DIR/linux-6.13.9/arch/arm/boot/zImage" \
      -dtb "$SCRIPT_DIR/linux-6.13.9/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb" \
      -initrd "$SCRIPT_DIR/rootfs/rootfs.cpio.gz" \
      -nographic -serial mon:stdio \
      -append "console=ttyAMA0 root=/dev/ram0 rw nokaslr isolcpus=1" \
      -accel tcg,thread=multi \
      -rtc base=utc,clock=vm \
      -no-reboot \
      -cpu cortex-a9 > "$output_file" 2>&1
}

# Step 1: Benchmark before patch
echo "Step 1: Running benchmark with unpatched kernel..."
compile_kernel

build_test_module

recreate_initramfs

run_qemu_capture "$BEFORE_OUTPUT"

# Step 2: Apply patches
echo ""
echo "Step 2: Applying patches..."
echo "Applying $PATCH_FILE..."
git -C "$SCRIPT_DIR" apply "$PATCH_FILE"
PATCH_APPLIED=1

# Step 3: Recompile and benchmark after patch
echo ""
echo "Step 3: Running benchmark with patched kernel..."
compile_kernel

build_test_module

recreate_initramfs
run_qemu_capture "$AFTER_OUTPUT"

# Step 4: Generate report
echo ""
echo "Step 4: Generating comparison report and graph data..."

# Create data file for gnuplot
echo "# Forks  Before_Avg_Wait_ms  After_Avg_Wait_ms" > "$GRAPH_DATA_FILE"

for forks in $FORK_COUNTS; do
    BEFORE_TIME=$(awk -F': ' "/AVERAGE_IO_TASK_WAIT_SUM_${forks}_CHILDREN/ {print \$2}" "$BEFORE_OUTPUT" | tr -d '\r' || echo "N/A")
    AFTER_TIME=$(awk -F': ' "/AVERAGE_IO_TASK_WAIT_SUM_${forks}_CHILDREN/ {print \$2}" "$AFTER_OUTPUT" | tr -d '\r' || echo "N/A")
    BEFORE_TIME=${BEFORE_TIME:-N/A}
    AFTER_TIME=${AFTER_TIME:-N/A}
    
    echo "Results for $forks children:"
    echo "  - Before Patch: ${BEFORE_TIME} ms"
    echo "  - After Patch:  ${AFTER_TIME} ms"
    
    if [ "$BEFORE_TIME" != "N/A" ] && [ "$AFTER_TIME" != "N/A" ]; then
        IMPROVEMENT=$(awk "BEGIN {print $BEFORE_TIME - $AFTER_TIME}")
        PERCENT=$(awk "BEGIN {print (($BEFORE_TIME - $AFTER_TIME) * 100) / $BEFORE_TIME}")
        echo "  - Improvement: $IMPROVEMENT ms ($PERCENT%)"
        echo "$forks $BEFORE_TIME $AFTER_TIME" >> "$GRAPH_DATA_FILE"
    fi
    echo ""
done

# Call the analyzer with the output logs
if [ -n "$CALLING_USER" ]; then
    chown -R "$CALLING_UID:$CALLING_GID" "$RESULTS_DIR"
    USER_SHELL=$(getent passwd "$CALLING_USER" | awk -F: '{print $7}')
    ANALYZER_PYTHON=$(sudo -u "$CALLING_USER" -H "$USER_SHELL" -lc 'command -v python3' | tail -n 1)
    sudo -u "$CALLING_USER" -H "$ANALYZER_PYTHON" \
        "$SCRIPT_DIR/benchmark_analyzer.py" "$BEFORE_OUTPUT" "$AFTER_OUTPUT" --output "$GRAPH_FILE"
else
    python3 "$SCRIPT_DIR/benchmark_analyzer.py" \
        "$BEFORE_OUTPUT" "$AFTER_OUTPUT" --output "$GRAPH_FILE"
fi

echo "Test completed! Review $BEFORE_OUTPUT and $AFTER_OUTPUT for full logs."
echo "Graph data has been saved to '$GRAPH_DATA_FILE'."
echo "You can now generate a graph."
