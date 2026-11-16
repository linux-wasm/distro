# Shared settings for the distro scripts. Sourced, not executed.
#
#   WORK         everything fetched or built goes here (default ./work)
#   KERNEL_DIR   use an existing kernel checkout instead of fetching the
#                pinned commit. This is how kernel and distro are developed
#                side by side:
#                    KERNEL_DIR=~/src/linux scripts/build.sh kernel

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
KERNEL_OUT="$WORK/build/kernel"
KERNEL_TOOLS="$KERNEL_DIR/tools/wasm"

# The kernel's own scripts read KOUT.
export KOUT="$KERNEL_OUT"

not_implemented() {
	echo "$1: not implemented yet ($2)" >&2
	return 1
}
