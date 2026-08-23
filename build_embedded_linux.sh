#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

# Embedded Linux Build Script
# This script builds a minimal Linux system with BusyBox and runs it in QEMU

set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
BUSYBOX_SOURCE_DIR="$SCRIPT_DIR/busybox-1.36.1"
BUSYBOX_BUILD_DIR="$SCRIPT_DIR/.build/busybox"
ROOTFS_DIR="$SCRIPT_DIR/rootfs"
cd "$SCRIPT_DIR"

ROOTFS_ONLY="${ROOTFS_ONLY:-0}"
if [ "$ROOTFS_ONLY" != "0" ] && [ "$ROOTFS_ONLY" != "1" ]; then
    echo "Error: ROOTFS_ONLY must be either 0 or 1."
    exit 1
fi

echo "=== Embedded Linux Build Script ==="
if [ "$ROOTFS_ONLY" = "1" ]; then
    echo "This run will regenerate rootfs using the committed BusyBox configuration"
else
    echo "This script will build a minimal Linux system and run it in QEMU"
fi
echo ""

# Step 0: Install dependencies
if [ "$ROOTFS_ONLY" = "0" ]; then
    echo "Step 0: Installing dependencies..."
    sudo apt update
    sudo apt install -y build-essential
    sudo apt install -y gcc-arm-linux-gnueabi qemu-system-arm
    sudo apt install -y flex bison libncurses5-dev libncursesw5-dev

    echo "Checking installed versions..."
    arm-linux-gnueabi-gcc --version
    qemu-system-arm --version
fi

# Check if required directories exist
if [ "$ROOTFS_ONLY" = "0" ] && [ ! -d "$SCRIPT_DIR/linux-6.13.9" ]; then
    echo "Error: linux-6.13.9 directory not found!"
    echo "Run ./prepare_kernel.sh to download and verify the kernel source."
    exit 1
fi

if [ ! -d "$BUSYBOX_SOURCE_DIR" ]; then
    echo "Error: busybox-1.36.1 directory not found!"
    echo "Please ensure you have the BusyBox source in this directory."
    exit 1
fi

# Step 1-4: Build Linux kernel
if [ "$ROOTFS_ONLY" = "0" ]; then
    echo ""
    echo "Step 1-4: Building Linux kernel..."
    cd "$SCRIPT_DIR/linux-6.13.9"

    echo "Cleaning previous builds..."
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- mrproper

    echo "Configuring kernel..."
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- versatile_defconfig

    echo "Building kernel (this may take a while)..."
    make -j"$(nproc)" ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-

    cd "$SCRIPT_DIR"
fi

# Step 6-13: Build BusyBox in the ignored build directory. This keeps the
# vendored source tree clean and makes ROOTFS_ONLY work from a fresh clone.
echo ""
echo "Step 6-13: Building BusyBox..."
mkdir -p "$BUSYBOX_BUILD_DIR"
cp -a "$BUSYBOX_SOURCE_DIR/." "$BUSYBOX_BUILD_DIR/"
cp "$BUSYBOX_SOURCE_DIR/.config" "$BUSYBOX_BUILD_DIR/.config"
make -C "$BUSYBOX_BUILD_DIR" ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- silentoldconfig
make -C "$BUSYBOX_BUILD_DIR" -j"$(nproc)" ARCH=arm CROSS_COMPILE=arm-linux-gnueabi-

# Step 15-18: Create root filesystem
echo ""
echo "Step 15-18: Creating root filesystem..."
if [ -d "$ROOTFS_DIR" ]; then
    find "$ROOTFS_DIR" -mindepth 1 -delete
fi
mkdir -p "$ROOTFS_DIR"
cd "$ROOTFS_DIR"

# Create init script
echo "Creating init script..."
cat > init << 'EOF'
#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

echo "Hello from Embedded Linux!"
echo "System is booting..."

# Create mount points before mounting the essential filesystems
mkdir -p /dev /proc /sys

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys

# Create device nodes
mknod /dev/console c 5 1
mknod /dev/null c 1 3

echo "Boot complete. Starting shell..."
exec /bin/sh
EOF

chmod +x init

cd "$SCRIPT_DIR"

# Step 20-23: Populate and create initramfs
echo ""
echo "Step 20-23: Creating initramfs..."
make -C "$BUSYBOX_BUILD_DIR" ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- \
    CONFIG_PREFIX="$ROOTFS_DIR" install

cd "$ROOTFS_DIR"

echo "Creating directory structure..."
mkdir -pv {bin,sbin,etc,dev,proc,sys,usr/{bin,sbin}}

echo "Creating initramfs archive..."
rm -f rootfs.cpio.gz
find . -path ./rootfs.cpio.gz -prune -o -print0 | cpio --null -ov --format=newc | gzip -9 > rootfs.cpio.gz

cd "$SCRIPT_DIR"

# Step 25: Run in QEMU
if [ "$ROOTFS_ONLY" = "1" ]; then
    echo ""
    echo "Root filesystem regenerated. Skipping QEMU in rootfs-only mode."
    exit 0
fi

echo ""
echo "Step 25: Starting QEMU..."
echo "The system should boot and display 'Hello from Embedded Linux!'"
echo "To exit QEMU, press Ctrl+A then X"
echo ""
read -p "Press Enter to start QEMU..."

qemu-system-arm \
  -M versatilepb \
  -m 256M \
  -kernel linux-6.13.9/arch/arm/boot/zImage \
  -dtb linux-6.13.9/arch/arm/boot/dts/arm/versatile-pb.dtb \
  -initrd rootfs/rootfs.cpio.gz \
  -nographic \
  -serial mon:stdio \
  -append "console=ttyAMA0 root=/dev/ram0 rw"

echo ""
echo "QEMU session ended. Build script completed!"
