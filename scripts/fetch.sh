#!/bin/sh
# Fetch the pinned sources from sources.env into work/src/.
#
#   scripts/fetch.sh [kernel|musl|xterm]
#
# Each is fetched as a single commit without history (the kernel is ~300 MB
# that way instead of several GB). With KERNEL_DIR / MUSL_DIR set there is
# nothing to fetch for that component.
set -eu
. "$(dirname "$0")/common.sh"

# fetch_commit <name> <pinned?> <dir> <repo> <commit>
fetch_commit() {
	if [ -z "$2" ]; then
		echo "$1: using $3 ($(git -C "$3" rev-parse --short HEAD))"
		return
	fi
	if [ "$(git -C "$3" rev-parse HEAD 2>/dev/null)" = "$5" ]; then
		echo "$1: already at $5"
		return
	fi
	mkdir -p "$3"
	git -C "$3" init -q
	git -C "$3" fetch --depth 1 "$4" "$5"
	git -C "$3" checkout -q --detach FETCH_HEAD
	echo "$1: fetched $5"
}

fetch_kernel() {
	fetch_commit kernel "$KERNEL_PINNED" "$KERNEL_DIR" "$KERNEL_REPO" "$KERNEL_COMMIT"
}

fetch_musl() {
	fetch_commit musl "$MUSL_PINNED" "$MUSL_DIR" "$MUSL_REPO" "$MUSL_COMMIT"
}

# fetch_tarball <name> <url> <sha512, base64>: unpack an npm package into
# work/src/<name>/ (its files are below package/).
fetch_tarball() {
	dir="$WORK/src/$1"
	[ -f "$dir/.fetched" ] && [ "$(cat "$dir/.fetched")" = "$3" ] && return
	rm -rf "$dir"
	mkdir -p "$dir"
	curl -fsSL "$2" -o "$dir/package.tgz"
	sum="$(openssl dgst -sha512 -binary "$dir/package.tgz" | base64 -w0)"
	if [ "$sum" != "$3" ]; then
		echo "$1: checksum mismatch for $2" >&2
		exit 1
	fi
	tar -xzf "$dir/package.tgz" -C "$dir"
	echo "$3" > "$dir/.fetched"
	echo "$1: fetched $2"
}

fetch_xterm() {
	fetch_tarball xterm "$XTERM_URL" "$XTERM_SHA512"
	fetch_tarball xterm-fit "$XTERM_FIT_URL" "$XTERM_FIT_SHA512"
	fetch_tarball xterm-webgl "$XTERM_WEBGL_URL" "$XTERM_WEBGL_SHA512"
}

case "${1:-all}" in
all) fetch_kernel; fetch_musl; fetch_xterm ;;
xterm) fetch_xterm ;;
kernel) fetch_kernel ;;
musl) fetch_musl ;;
*) echo "usage: $0 [kernel|musl|xterm]" >&2; exit 1 ;;
esac
