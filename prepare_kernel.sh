#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

SCRIPT_DIR=$(dirname "$(realpath "$0")")
KERNEL_VERSION="6.13.9"
KERNEL_DIR="$SCRIPT_DIR/linux-$KERNEL_VERSION"
KERNEL_ARCHIVE="$SCRIPT_DIR/linux-$KERNEL_VERSION.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
KERNEL_SHA256="53e7a3f028b6119ba499245bde0fa10275752817408a4a36b5a34ad74a4727b2"

if [ -d "$KERNEL_DIR" ]; then
	echo "Linux $KERNEL_VERSION is already available at $KERNEL_DIR"
	exit 0
fi

if [ ! -f "$KERNEL_ARCHIVE" ]; then
	echo "Downloading Linux $KERNEL_VERSION from kernel.org..."
	if command -v curl >/dev/null 2>&1; then
		curl --fail --location --output "$KERNEL_ARCHIVE" "$KERNEL_URL"
	elif command -v wget >/dev/null 2>&1; then
		wget --output-document="$KERNEL_ARCHIVE" "$KERNEL_URL"
	else
		echo "Error: curl or wget is required to download the kernel source."
		exit 1
	fi
fi

echo "$KERNEL_SHA256  $KERNEL_ARCHIVE" | sha256sum --check --status || {
	echo "Error: the Linux $KERNEL_VERSION archive failed its SHA-256 check."
	exit 1
}

echo "Extracting Linux $KERNEL_VERSION..."
tar -xJf "$KERNEL_ARCHIVE" -C "$SCRIPT_DIR"
echo "Kernel source is ready at $KERNEL_DIR"

