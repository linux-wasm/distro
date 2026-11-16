#!/bin/sh
# Build the distro, or one component of it.
#
#   scripts/build.sh            # everything that can be built today
#   scripts/build.sh kernel
#   scripts/build.sh musl | busybox | initramfs    (not implemented yet)
#
# The kernel is built with its own tooling (tools/wasm/scripts in the
# kernel tree: toolchain container + kbuild wrapper); this script only
# decides where the output goes.
set -eu
. "$(dirname "$0")/common.sh"

build_kernel() {
	"$DISTRO/scripts/fetch.sh" kernel
	"$KERNEL_TOOLS/scripts/build-env.sh"
	"$KERNEL_TOOLS/scripts/kmake.sh" tinyconfig
	"$KERNEL_TOOLS/scripts/kmake.sh" -j"$(nproc)"
	echo "kernel: $KERNEL_OUT/vmlinux.wasm"
}

build_musl() {
	not_implemented musl "the kernel has no user-space ABI to port it to"
}

build_busybox() {
	not_implemented busybox "needs musl"
}

build_initramfs() {
	not_implemented initramfs "needs busybox, and CONFIG_BLK_DEV_INITRD plus a way to hand the image to the kernel"
}

case "${1:-all}" in
all)
	build_kernel
	echo "skipped: musl, busybox, initramfs (not implemented yet, see README.md)"
	;;
kernel) build_kernel ;;
musl) build_musl ;;
busybox) build_busybox ;;
initramfs) build_initramfs ;;
*) echo "usage: $0 [all|kernel|musl|busybox|initramfs]" >&2; exit 1 ;;
esac
