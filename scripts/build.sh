#!/bin/sh
# Build the distro, or one component of it.
#
#   scripts/build.sh            # everything, in dependency order
#   scripts/build.sh toolchain  # the container image (from the kernel tree)
#   scripts/build.sh musl       # libc -> work/sysroot/
#   scripts/build.sh headers    # kernel headers for user space
#   scripts/build.sh user       # this repository's programs (user/)
#   scripts/build.sh ports      # packages: busybox, bash, coreutils, ... (linux-wasm/ports)
#   scripts/build.sh rootfs     # the root file system -> work/base.erofs, work/data.img
#   scripts/build.sh kernel     # the kernel
#   scripts/build.sh site       # the web page -> work/site/
#
# Each step assumes the ones before it have run.
set -eu
. "$(dirname "$0")/common.sh"

build_toolchain() {
	"$DISTRO/scripts/fetch.sh" kernel
	"$KERNEL_TOOLS/scripts/build-env.sh"
}

build_musl() {
	"$DISTRO/scripts/fetch.sh" musl
	mkdir -p "$MUSL_OUT"
	container_run sh -ec "
		cd /work/build/musl
		if [ ! -f config.mak ]; then
			CC='$LLVM/clang --target=wasm32-unknown-unknown' \
			AR=$LLVM/llvm-ar RANLIB=$LLVM/llvm-ranlib \
			CFLAGS='$WASM_CFLAGS' LIBCC=' ' \
			/musl/configure --target=wasm32 --prefix=/ \
				--disable-shared --srcdir=/musl
		fi
		make -s -j\$(nproc)
		make -s install DESTDIR=/work/sysroot
	"
	echo "musl: $SYSROOT"
}

# Kernel headers (linux/*.h) for programs that include them, installed
# next to libc's in the sysroot.
build_headers() {
	"$KERNEL_TOOLS/scripts/kmake.sh" tinyconfig
	"$KERNEL_TOOLS/scripts/kmake.sh" headers_install INSTALL_HDR_PATH=/out/headers
	cp -R "$KERNEL_OUT/headers/include/." "$SYSROOT/include/"
}

# Programs from user/: one .c file each, linked against musl.
build_user() {
	mkdir -p "$USER_OUT"
	container_run sh -ec '
		for src in /distro/user/*.c; do
			/distro/scripts/wasm-cc -O2 -Wall "$src" \
				-o "/work/build/user/$(basename "$src" .c).wasm"
		done
	'
	echo "user: $USER_OUT"
}

# Packages from linux-wasm/ports, built with this repository's compiler
# driver against the sysroot -> work/ports/out/*.tar.gz.
build_ports() {
	"$DISTRO/scripts/fetch.sh" ports
	TOOLCHAIN="$DISTRO/scripts" SYSROOT="$SYSROOT" WORK="$WORK/ports" \
		CONTAINER="$CONTAINER" IMAGE="$IMAGE" "$PORTS_DIR/build.sh"
}

# The root file system has two layers, joined by overlayfs at boot
# (rootfs/sbin/overlay-init):
#
#   base.erofs  read-only: everything the distro ships. Built here from a
#               directory tree; all files belong to root, and extended
#               attributes of the build machine (SELinux labels) are
#               left out (-x -1).
#   data.img    an empty ext4 file system for what the user adds, changes
#               and deletes. The host keeps it (the browser: in the origin
#               private file system); a new base does not replace it.
build_rootfs() {
	tree="$WORK/build/rootfs"
	rm -rf "$tree"
	mkdir -p "$tree"
	(
		cd "$tree"
		mkdir -p bin sbin usr/bin usr/sbin etc dev proc sys run tmp root \
			home mnt var/log overlay/base overlay/data overlay/root
		chmod 1777 tmp
		chmod 700 root
		cp -R "$DISTRO"/rootfs/. .
		for src in "$USER_OUT"/*.wasm; do
			cp "$src" "bin/$(basename "$src" .wasm)"
		done
		chmod 755 bin/* sbin/*
		# The packages. BusyBox first: it has an applet for many of
		# the programs that other packages bring, and where both
		# install to the same path the real program replaces the
		# applet. (Elsewhere PATH decides, with /usr/bin first.)
		tar -xzf "$WORK"/ports/out/busybox-*.tar.gz
		for package in "$WORK"/ports/out/*.tar.gz; do
			case "$package" in */busybox-*) continue ;; esac
			tar -xzf "$package"
		done
		ln -s /usr/bin/bash bin/bash
	)
	rm -f "$WORK/base.erofs" "$WORK/data.img"
	container_run sh -ec "
		mkfs.erofs --quiet --all-root -T 0 -x -1 \
			-U 00000000-0000-0000-0000-000000000001 \
			/work/base.erofs /work/build/rootfs
		mke2fs -q -t ext4 -L data -m 0 /work/data.img ${DATA_SIZE_MIB}M
	"
	echo "rootfs: $WORK/base.erofs, $WORK/data.img"
}

# The kernel is built with its own tooling (tools/wasm/scripts in the
# kernel tree); this only chooses the output directory and the configuration.
build_kernel() {
	"$KERNEL_TOOLS/scripts/kmake.sh" tinyconfig
	# Runs in the kernel build container: repository at /linux, KOUT at /out.
	"$CONTAINER" run --rm --security-opt label=disable \
		--user "$(id -u):$(id -g)" \
		-v "$KERNEL_DIR:/linux" -v "$KERNEL_OUT:/out" -w /linux "$IMAGE" \
		scripts/config --file /out/.config \
		--set-str CMDLINE "$KERNEL_CMDLINE" \
		$(grep -v '^#' "$DISTRO/kernel.config" | sed '/^$/d; s/^/--enable /')
	"$KERNEL_TOOLS/scripts/kmake.sh" olddefconfig
	"$KERNEL_TOOLS/scripts/kmake.sh" -j"$(nproc)"
	echo "kernel: $KERNEL_OUT/vmlinux.wasm"
}

# The static web site: this repository's page (site/), the kernel's
# reference host scripts and the kernel image. Deployable as-is to any
# static host; site/sw.js supplies the COOP/COEP headers where the host
# cannot. Both disk images are compressed: programs shrink to a third, and
# the empty data image is mostly zeros.
build_site() {
	rm -rf "$SITE_OUT"
	mkdir -p "$SITE_OUT"
	cp "$DISTRO"/site/* "$SITE_OUT/"
	# The host code shared with node; the node-*.mjs files stay behind.
	cp "$KERNEL_TOOLS"/host/*.js "$SITE_OUT/"
	cp "$KERNEL_OUT/vmlinux.wasm" "$SITE_OUT/"
	# The terminal emulator (MIT, see sources.env).
	"$DISTRO/scripts/fetch.sh" xterm
	cp "$WORK/src/xterm/package/lib/xterm.js" \
		"$WORK/src/xterm/package/css/xterm.css" \
		"$WORK/src/xterm-fit/package/lib/addon-fit.js" \
		"$WORK/src/xterm-webgl/package/lib/addon-webgl.js" "$SITE_OUT/"
	gzip -9 -n -c "$WORK/base.erofs" > "$SITE_OUT/base.erofs.gz"
	gzip -9 -n -c "$WORK/data.img" > "$SITE_OUT/data.img.gz"
	printf '{"kernel_repo": "%s", "kernel_commit": "%s", "base_bytes": %s, "data_bytes": %s}\n' \
		"${KERNEL_REPO%.git}" "$(git -C "$KERNEL_DIR" rev-parse HEAD)" \
		"$(wc -c < "$WORK/base.erofs")" "$(wc -c < "$WORK/data.img")" \
		> "$SITE_OUT/build.json"
	echo "site: $SITE_OUT"
}

case "${1:-all}" in
all)
	build_toolchain
	build_musl
	build_headers
	build_user
	build_ports
	build_rootfs
	build_kernel
	build_site
	;;
toolchain|musl|headers|user|ports|rootfs|kernel|site) "build_$1" ;;
*) echo "usage: $0 [all|toolchain|musl|headers|user|ports|rootfs|kernel|site]" >&2; exit 1 ;;
esac
