# Shared settings for the distro scripts. Sourced, not executed.
#
#   WORK         everything fetched or built goes here (default ./work)
#   KERNEL_DIR   use an existing kernel checkout instead of fetching the
#   MUSL_DIR     pinned commit (same for musl). This is how the
#                repositories are developed side by side:
#                    KERNEL_DIR=~/src/linux scripts/build.sh kernel
#   CONTAINER    docker (default) or podman

DISTRO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$DISTRO/work}"
. "$DISTRO/sources.env"

KERNEL_PINNED=1
if [ -n "${KERNEL_DIR:-}" ]; then
	KERNEL_PINNED=
	KERNEL_DIR="$(cd "$KERNEL_DIR" && pwd)"
else
	KERNEL_DIR="$WORK/src/linux"
fi
MUSL_PINNED=1
if [ -n "${MUSL_DIR:-}" ]; then
	MUSL_PINNED=
	MUSL_DIR="$(cd "$MUSL_DIR" && pwd)"
else
	MUSL_DIR="$WORK/src/musl"
fi

KERNEL_OUT="$WORK/build/kernel"
KERNEL_TOOLS="$KERNEL_DIR/tools/wasm"
MUSL_OUT="$WORK/build/musl"
SYSROOT="$WORK/sysroot"
USER_OUT="$WORK/build/user"
SITE_OUT="$WORK/site"

# The kernel's own scripts read KOUT.
export KOUT="$KERNEL_OUT"

CONTAINER="${CONTAINER:-docker}"
# The toolchain image built by the kernel's tools/wasm/scripts/build-env.sh.
IMAGE="${LINUX_WASM_IMAGE:-linux-wasm-build:llvm19}"

# Run a command in the toolchain container, as the calling user, with
#   /distro  this repository (read-only use)
#   /work    $WORK
#   /musl    the musl source tree
container_run() {
	mkdir -p "$WORK"
	"$CONTAINER" run --rm \
		--security-opt label=disable \
		--user "$(id -u):$(id -g)" \
		-e HOME=/tmp \
		-v "$DISTRO:/distro" -v "$WORK:/work" -v "$MUSL_DIR:/musl" \
		-w /work "$IMAGE" "$@"
}

# Compiler and linker flags of a user program; the ABI is defined by the
# kernel (arch/wasm/kernel/binfmt_wasm.c). Paths are container paths.
LLVM=/usr/lib/llvm-19/bin
#  -mexception-handling -mllvm -wasm-enable-sjlj: how setjmp/longjmp work
#      on wasm (see src/setjmp/wasm32/setjmp.c in musl).
WASM_CFLAGS="-fPIC -matomics -mbulk-memory -mexception-handling -O2"
USER_CFLAGS="--target=wasm32-unknown-unknown $WASM_CFLAGS -mllvm -wasm-enable-sjlj"
USER_LDFLAGS="-pie --experimental-pic --no-entry --export=_start \
--export-if-defined=__clone_entry --import-memory --shared-memory \
--max-memory=4294967296"
USER_LIBS="/work/sysroot/lib/libc.a \
/usr/lib/llvm-19/lib/clang/19/lib/wasi/libclang_rt.builtins-wasm32.a"

not_implemented() {
	echo "$1: not implemented yet ($2)" >&2
	return 1
}
