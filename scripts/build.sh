#!/bin/sh
# Build the distro, or one component of it.
#
#   scripts/build.sh            # everything, in dependency order
#   scripts/build.sh toolchain  # the container image (from the kernel tree)
#   scripts/build.sh musl       # libc -> work/sysroot/
#   scripts/build.sh headers    # kernel headers for user space
#   scripts/build.sh user       # this repository's programs (user/)
#   scripts/build.sh busybox    # shell, init and the usual commands
#   scripts/build.sh initramfs  # what goes into the kernel image
#   scripts/build.sh kernel     # kernel with that initramfs built in
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

# Kernel headers (linux/*.h) for programs that include them: BusyBox.
build_headers() {
	"$KERNEL_TOOLS/scripts/kmake.sh" tinyconfig
	"$KERNEL_TOOLS/scripts/kmake.sh" headers_install INSTALL_HDR_PATH=/out/headers
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

# BusyBox: upstream release, configured from busybox/config, built with
# scripts/wasm-cc as its compiler. busybox.links lists the applet paths.
build_busybox() {
	src="$WORK/src/busybox"
	if [ ! -d "$src" ]; then
		git clone -q --depth 1 -b "$BUSYBOX_TAG" "$BUSYBOX_REPO" "$src"
		for patch in "$DISTRO"/patches/busybox/*.patch; do
			[ -f "$patch" ] && git -C "$src" apply "$patch"
		done
	fi
	"$CONTAINER" run --rm --security-opt label=disable \
		--user "$(id -u):$(id -g)" -e HOME=/tmp \
		-v "$DISTRO:/distro" -v "$WORK:/work" \
		-v "$KERNEL_OUT/headers:/kernel-headers" \
		-w /work/src/busybox "$IMAGE" sh -ec '
		export PATH=/distro/scripts:$PATH
		M="make CC=wasm-cc HOSTCC=gcc AR=/usr/lib/llvm-19/bin/llvm-ar \
			NM=/usr/lib/llvm-19/bin/llvm-nm STRIP=true SKIP_STRIP=y"
		$M allnoconfig >/dev/null
		grep -v "^#" /distro/busybox/config | while read -r opt; do
			[ -n "$opt" ] || continue
			grep -q "^# CONFIG_$opt is not set" .config ||
				{ echo "busybox/config: unknown option $opt" >&2; exit 1; }
			sed -i "s/^# CONFIG_$opt is not set/CONFIG_$opt=y/" .config
		done
		sed -i "s/^CONFIG_SH_IS_NONE=y/# CONFIG_SH_IS_NONE is not set/" .config
		# hush re-executes itself for $(...) and pipelines of builtins;
		# the default, /proc/self/exe, needs /proc to be mounted.
		sed -i "s|^CONFIG_BUSYBOX_EXEC_PATH=.*|CONFIG_BUSYBOX_EXEC_PATH=\"/bin/busybox\"|" .config
		sed -i "s|^CONFIG_EXTRA_CFLAGS=.*|CONFIG_EXTRA_CFLAGS=\"-isystem /kernel-headers/include\"|" .config
		yes "" | $M oldconfig >/dev/null
		$M -s -j"$(nproc)" busybox busybox.links 2>&1 |
			grep -v "is not supported \[-Wignored-optimization-argument\]" || true
		test -f busybox
	'
	echo "busybox: $src/busybox"
}

# The initramfs is built into the kernel image (CONFIG_INITRAMFS_SOURCE),
# so it is assembled inside the kernel's output directory, which the kernel
# build container sees as /out. The list is in usr/gen_init_cpio format.
build_initramfs() {
	mkdir -p "$KERNEL_OUT/initramfs"
	out="$KERNEL_OUT/initramfs"
	rm -rf "$out"
	mkdir -p "$out"
	cp "$USER_OUT"/*.wasm "$DISTRO/user/motd" "$DISTRO/user/inittab" "$out/"
	cp "$WORK/src/busybox/busybox" "$out/busybox.wasm"
	{
		cat <<-'LIST'
		dir /dev 0755 0 0
		nod /dev/console 0600 0 0 c 5 1
		dir /etc 0755 0 0
		file /etc/motd /out/initramfs/motd 0644 0 0
		file /etc/inittab /out/initramfs/inittab 0644 0 0
		dir /tmp 1777 0 0
		dir /root 0700 0 0
		dir /proc 0555 0 0
		dir /bin 0755 0 0
		dir /sbin 0755 0 0
		dir /usr 0755 0 0
		dir /usr/bin 0755 0 0
		dir /usr/sbin 0755 0 0
		file /bin/busybox /out/initramfs/busybox.wasm 0755 0 0
		file /bin/selftest /out/initramfs/selftest.wasm 0755 0 0
		slink /init /bin/busybox 0777 0 0
		LIST
		# One symlink per applet, as "busybox --install -s" would make.
		sed 's|.*|slink & /bin/busybox 0777 0 0|' "$WORK/src/busybox/busybox.links"
	} > "$out/list"
	echo "initramfs: $KERNEL_OUT/initramfs/list"
}

# The kernel is built with its own tooling (tools/wasm/scripts in the
# kernel tree); this only chooses the output directory and the initramfs.
build_kernel() {
	"$KERNEL_TOOLS/scripts/kmake.sh" tinyconfig
	# Runs in the kernel build container: repository at /linux, KOUT at /out.
	"$CONTAINER" run --rm --security-opt label=disable \
		--user "$(id -u):$(id -g)" \
		-v "$KERNEL_DIR:/linux" -v "$KERNEL_OUT:/out" -w /linux "$IMAGE" \
		scripts/config --file /out/.config \
		--set-str INITRAMFS_SOURCE /out/initramfs/list \
		$(grep -v '^#' "$DISTRO/kernel.config" | sed '/^$/d; s/^/--enable /')
	"$KERNEL_TOOLS/scripts/kmake.sh" olddefconfig
	"$KERNEL_TOOLS/scripts/kmake.sh" -j"$(nproc)"
	echo "kernel: $KERNEL_OUT/vmlinux.wasm"
}

# The static web site: this repository's page (site/), the kernel's
# reference host scripts and the kernel image. Deployable as-is to any
# static host; site/sw.js supplies the COOP/COEP headers where the host
# cannot.
build_site() {
	rm -rf "$SITE_OUT"
	mkdir -p "$SITE_OUT"
	cp "$DISTRO"/site/* "$SITE_OUT/"
	# Everything the browser needs; the node-*.mjs files are for node.
	cp "$KERNEL_TOOLS"/host/*.js "$SITE_OUT/"
	cp "$KERNEL_OUT/vmlinux.wasm" "$SITE_OUT/"
	printf '{"kernel_repo": "%s", "kernel_commit": "%s"}\n' \
		"${KERNEL_REPO%.git}" "$(git -C "$KERNEL_DIR" rev-parse HEAD)" \
		> "$SITE_OUT/build.json"
	echo "site: $SITE_OUT"
}

case "${1:-all}" in
all)
	build_toolchain
	build_musl
	build_headers
	build_user
	build_busybox
	build_initramfs
	build_kernel
	build_site
	;;
toolchain|musl|headers|user|busybox|initramfs|kernel|site) "build_$1" ;;
*) echo "usage: $0 [all|toolchain|musl|headers|user|busybox|initramfs|kernel|site]" >&2; exit 1 ;;
esac
