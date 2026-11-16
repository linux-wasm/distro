#!/bin/sh
# Fetch the pinned sources from sources.env into work/src/.
#
#   scripts/fetch.sh [kernel]
#
# The kernel is fetched as a single commit (no history, ~300 MB instead of
# several GB). With KERNEL_DIR set there is nothing to fetch.
set -eu
. "$(dirname "$0")/common.sh"

fetch_kernel() {
	if [ -z "$KERNEL_PINNED" ]; then
		echo "kernel: using KERNEL_DIR=$KERNEL_DIR ($(git -C "$KERNEL_DIR" rev-parse --short HEAD))"
		return
	fi
	if [ "$(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null)" = "$KERNEL_COMMIT" ]; then
		echo "kernel: already at $KERNEL_COMMIT"
		return
	fi
	mkdir -p "$KERNEL_DIR"
	git -C "$KERNEL_DIR" init -q
	git -C "$KERNEL_DIR" fetch --depth 1 "$KERNEL_REPO" "$KERNEL_COMMIT"
	git -C "$KERNEL_DIR" checkout -q --detach FETCH_HEAD
	echo "kernel: fetched $KERNEL_COMMIT"
}

case "${1:-all}" in
all|kernel) fetch_kernel ;;
*) echo "usage: $0 [kernel]" >&2; exit 1 ;;
esac
