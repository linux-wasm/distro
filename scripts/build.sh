#!/bin/sh
# Build the distro, or one component of it.
#
#   scripts/build.sh            # everything, in dependency order
#   scripts/build.sh toolchain  # the container image (from the kernel tree)
#   scripts/build.sh musl       # libc -> work/sysroot/
#   scripts/build.sh user       # this repository's programs (user/)
#   scripts/build.sh initramfs  # what goes into the kernel image
#   scripts/build.sh kernel     # kernel with that initramfs built in
#   scripts/build.sh site       # the web page -> work/site/
#   scripts/build.sh busybox    (not implemented yet)
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
			CFLAGS='-fPIC -matomics -mbulk-memory -O2' LIBCC=' ' \
			/musl/configure --target=wasm32 --prefix=/ \
				--disable-shared --srcdir=/musl
		fi
		make -s -j\$(nproc)
		make -s install DESTDIR=/work/sysroot
	"
	echo "musl: $SYSROOT"
}

# Programs from user/: one .c file each, linked against musl.
build_user() {
	mkdir -p "$USER_OUT"
	container_run sh -ec "
		for src in /distro/user/*.c; do
			name=\$(basename \$src .c)
			$LLVM/clang $USER_CFLAGS -Wall --sysroot=/work/sysroot \
				-isystem /work/sysroot/include \
				-c \$src -o /work/build/user/\$name.o
			$LLVM/wasm-ld $USER_LDFLAGS /work/sysroot/lib/crt1.o \
				/work/build/user/\$name.o $USER_LIBS \
				-o /work/build/user/\$name.wasm
		done
	"
	echo "user: $USER_OUT"
}

# The initramfs is built into the kernel image (CONFIG_INITRAMFS_SOURCE),
# so it is assembled inside the kernel's output directory, which the kernel
# build container sees as /out. The list is in usr/gen_init_cpio format.
build_initramfs() {
	mkdir -p "$KERNEL_OUT/initramfs"
	cp "$USER_OUT/init.wasm" "$DISTRO/user/motd" "$KERNEL_OUT/initramfs/"
	cat > "$KERNEL_OUT/initramfs/list" <<-'LIST'
	dir /dev 0755 0 0
	nod /dev/console 0600 0 0 c 5 1
	dir /etc 0755 0 0
	file /etc/motd /out/initramfs/motd 0644 0 0
	file /init /out/initramfs/init.wasm 0755 0 0
	LIST
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
		--set-str INITRAMFS_SOURCE /out/initramfs/list
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

build_busybox() {
	not_implemented busybox "its shell and init call vfork(), which this system cannot provide; needs patches"
}

case "${1:-all}" in
all)
	build_toolchain
	build_musl
	build_user
	build_initramfs
	build_kernel
	build_site
	echo "skipped: busybox (not implemented yet, see README.md)"
	;;
toolchain|musl|user|initramfs|kernel|site|busybox) "build_$1" ;;
*) echo "usage: $0 [all|toolchain|musl|user|initramfs|kernel|site|busybox]" >&2; exit 1 ;;
esac
